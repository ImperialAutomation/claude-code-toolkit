#!/usr/bin/env python3
"""
/pre-merge --post: submit the gate report as one PR review under the review
GitHub App of the repo's owner (#296).

Usage:
  pre-merge-post.py --gates <file> --body <file> [--human <file>]

  --gates  the input of pre-merge-verdict.py (repo and pr required). The
           verdict is recomputed from it with that helper's own rules, so the
           posted review cannot disagree with the report. Nothing is appended
           to the findings log: the verdict run already did that.
  --body   the gate report (markdown) that becomes the review body
  --human  required when the verdict is HUMAN: a JSON list of decisions,
           [{"question": "...", "options": ["A: ...", "B: ..."],
             "recommendation": "..."}], at least one, two options or more each

Every GitHub call runs as `gh-app-token.sh --repo <repo> -- gh api ...`
(PRE_MERGE_TOKEN_SCRIPT overrides the script path), so the review shows as
`<app-name>[bot]`, never as the user.

What one run does:
  1. read the PR's changed files (paginated) to learn which lines are on the diff
  2. submit ONE review: event from REVIEW_EVENTS of pre-merge-verdict.py
     (APPROVE -> APPROVE, BLOCKING -> REQUEST_CHANGES, HUMAN -> COMMENT).
     Every finding with a file and a line on the diff (a /code-review finding,
     or a /review finding whose location is file:line) is an inline comment of
     that review; findings with a file but no diff line are listed in the body,
     because GitHub rejects the whole review for one comment off the diff.
  3. HUMAN only: add the label needs-human to the PR and to every linked issue
     (escalation.linked_issues of the gates file), after the review is in.

Result, one JSON object on stdout (exit 0 and 3):

  posted:      {"status": "posted", "verdict": "APPROVE|BLOCKING|HUMAN",
                "event": "APPROVE|REQUEST_CHANGES|COMMENT", "review_id": 1,
                "review_url": "...", "inline_comments": N, "body_findings": N,
                "labeled": [<PR>, <issue>, ...]}
  post_failed: {"status": "post_failed", "stage": "files|review|label",
                "error": "...", "review_posted": false|true,
                "review_url": "..." (only when review_posted)}

A post failure is never a verdict: post_failed carries no "verdict" or
"event", so a caller cannot mistake it for one. review_posted true means the
review is on the PR but a label is missing (stage label). A missing app or
token surfaces as a failure of the first call (stage files), with the token
script's message in "error".

Exit codes:
  0  posted: the review is on the PR, and for HUMAN every label is set
  2  usage error or invalid input (no PR number, invalid gates, HUMAN without
     a valid --human); nothing was sent, stderr says why, stdout is empty
  3  post_failed: no token, or a GitHub API error; see the JSON result
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
VERDICT_SCRIPT = BIN_DIR / "pre-merge-verdict.py"
TOKEN_SCRIPT_ENV = "PRE_MERGE_TOKEN_SCRIPT"
DEFAULT_TOKEN_SCRIPT = BIN_DIR / "gh-app-token.sh"

STATUS_POSTED = "posted"
STATUS_POST_FAILED = "post_failed"
STAGE_FILES = "files"
STAGE_REVIEW = "review"
STAGE_LABEL = "label"

EXIT_POSTED = 0
EXIT_INVALID = 2
EXIT_POST_FAILED = 3

DIFF_SIDE = "RIGHT"
MIN_OPTIONS = 2
# GitHub refuses a review body above 65536 characters; keep room for the
# truncation note.
MAX_BODY = 65000
ERROR_LINES = 5
HUNK_HEADER = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")
LOCATION = re.compile(r"^(?P<path>.+?):(?P<line>\d+)$")


def _load_verdict_module():
    spec = importlib.util.spec_from_file_location("pre_merge_verdict", VERDICT_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


V = _load_verdict_module()


class PostFailed(Exception):
    def __init__(self, stage, error, review=None):
        super().__init__(error)
        self.stage, self.error, self.review = stage, error, review


# --- input ----------------------------------------------------------------------

def load_json(path, what):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as exc:
        raise V.Invalid(f"cannot read {what} '{path}': {exc}")
    except ValueError as exc:
        raise V.Invalid(f"{what} '{path}' is not valid JSON: {exc}")


def validate_target(gates):
    repo = gates.get("repo")
    if not isinstance(repo, str) or "/" not in repo:
        raise V.Invalid("'repo' (owner/name) is required to post")
    pr = gates.get("pr")
    if not isinstance(pr, int) or isinstance(pr, bool) or pr <= 0:
        raise V.Invalid("'pr' (a PR number) is required to post; without a PR there is nothing to review")
    numbers = []
    for issue in gates.get("escalation", {}).get("linked_issues", []):
        number = issue.get("number")
        if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
            raise V.Invalid("linked issue: 'number' must be a positive integer")
        numbers.append(number)
    return repo, pr, numbers


def validate_human(decisions):
    if not isinstance(decisions, list) or not decisions:
        raise V.Invalid("--human must be a non-empty JSON list of decisions")
    for d in decisions:
        if not isinstance(d, dict):
            raise V.Invalid("--human: each decision must be an object")
        for key in ("question", "recommendation"):
            if not isinstance(d.get(key), str) or not d[key].strip():
                raise V.Invalid(f"--human: each decision needs a non-empty '{key}'")
        options = d.get("options")
        if (not isinstance(options, list) or len(options) < MIN_OPTIONS
                or not all(isinstance(o, str) and o.strip() for o in options)):
            raise V.Invalid(f"--human: each decision needs at least {MIN_OPTIONS} options")


# --- findings and the diff --------------------------------------------------------

def _line(value):
    try:
        line = int(value)
    except (TypeError, ValueError):
        return None
    return line if line > 0 else None


def collect_findings(gates):
    """Every finding with a file: (path, line or None, inline text, list text)."""
    found = []
    for f in gates.get("correctness_findings", []):
        line = _line(f.get("line"))
        text = (f"**Correctness** (`/code-review`, shadow severity {f['shadow_severity']}): "
                f"{f.get('summary', '')}")
        if f.get("failure_scenario"):
            text += f"\n\nFailure scenario: {f['failure_scenario']}"
        found.append((f["file"], line, text, f"correctness: {f.get('summary', '')}"))
    for f in gates.get("review_findings", []):
        match = LOCATION.match(str(f.get("location") or ""))
        if match:
            found.append((match["path"], int(match["line"]),
                          f"**/review {f['severity']}**: {f.get('finding', '')}",
                          f"/review {f['severity']}: {f.get('finding', '')}"))
    return found


def parse_pages(text):
    """The items of `gh api --paginate`: one or more JSON arrays, concatenated."""
    decoder, items, pos = json.JSONDecoder(), [], 0
    while True:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            return items
        value, pos = decoder.raw_decode(text, pos)
        items.extend(value if isinstance(value, list) else [value])


def diff_lines(files):
    """{path: set of right-side line numbers a review comment may point at}."""
    lines = {}
    for f in files:
        right, current = set(), None
        for row in (f.get("patch") or "").splitlines():
            header = HUNK_HEADER.match(row)
            if header:
                current = int(header.group(1))
            elif current is None or row.startswith("-") or row.startswith("\\"):
                continue
            else:
                right.add(current)
                current += 1
        lines[f.get("filename")] = right
    return lines


# --- review body ------------------------------------------------------------------

def bullet_list(items):
    return "\n".join(f"- {i}" for i in items)


def human_section(decisions, reasons):
    parts = ["### Needs a human decision", ""]
    for n, d in enumerate(decisions, 1):
        parts += [f"**Question {n}:** {d['question']}", "", "Options:",
                  bullet_list(d["options"]), "", f"**Recommendation:** {d['recommendation']}", ""]
    if reasons:
        parts += ["Why:", bullet_list(reasons), ""]
    return "\n".join(parts)


def build_body(result, report, decisions, off_diff):
    verdict, event = result["verdict"], V.REVIEW_EVENTS[result["verdict"]]
    head = [f"**/pre-merge verdict: {verdict}** (review event `{event}`)", ""]
    if verdict == V.HUMAN:
        head.append(human_section(decisions, result["human_reasons"]))
    if result["blocking_reasons"]:
        head += ["### Blocking", bullet_list(result["blocking_reasons"]), ""]
    tail = []
    if off_diff:
        tail = ["", "### Findings not on a line of the diff", bullet_list(off_diff)]
    fixed = "\n".join(head) + "\n---\n\n"
    tail_text = "\n".join(tail)
    room = MAX_BODY - len(fixed) - len(tail_text)
    note = "\n\n(report truncated: GitHub limits the review body)"
    if len(report) > room:
        report = report[:max(room - len(note), 0)] + note
    return fixed + report.rstrip() + "\n" + tail_text


# --- GitHub -----------------------------------------------------------------------

def gh_api(repo, stage, *args, payload=None):
    """Run `gh api <args>` under the app token; returns stdout or raises PostFailed."""
    token_script = os.environ.get(TOKEN_SCRIPT_ENV) or str(DEFAULT_TOKEN_SCRIPT)
    with tempfile.TemporaryDirectory(prefix="pre-merge-post.") as work:
        cmd = [token_script, "--repo", repo, "--", "gh", "api", *args]
        if payload is not None:
            body_file = Path(work) / "request.json"
            body_file.write_text(json.dumps(payload), encoding="utf-8")
            cmd += ["--input", str(body_file)]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True)
        except OSError as exc:
            raise PostFailed(stage, f"cannot run {token_script}: {exc}")
    if r.returncode != 0:
        lines = [l for l in r.stderr.splitlines() if l.strip()]
        error = " | ".join(lines[-ERROR_LINES:]) or f"exit {r.returncode}, no message"
        raise PostFailed(stage, error)
    return r.stdout


def post(repo, pr, issues, result, report, decisions, gates):
    try:
        files = parse_pages(gh_api(repo, STAGE_FILES, "--paginate",
                                   f"repos/{repo}/pulls/{pr}/files?per_page=100"))
    except ValueError as exc:
        raise PostFailed(STAGE_FILES, f"unreadable answer for the PR files: {exc}")
    on_diff = diff_lines(files)

    comments, off_diff = [], []
    for path, line, inline, listed in collect_findings(gates):
        if line is not None and line in on_diff.get(path, ()):
            comments.append({"path": path, "line": line, "side": DIFF_SIDE, "body": inline})
        else:
            off_diff.append(f"`{path}{f':{line}' if line else ''}` {listed}")

    event = V.REVIEW_EVENTS[result["verdict"]]
    request = {"event": event, "body": build_body(result, report, decisions, off_diff),
               "comments": comments}
    answer = gh_api(repo, STAGE_REVIEW, "-X", "POST", f"repos/{repo}/pulls/{pr}/reviews",
                    payload=request)
    try:
        review = json.loads(answer)
    except ValueError:
        review = {}

    labeled = []
    if result["verdict"] == V.HUMAN:
        for number in dict.fromkeys([pr, *issues]):
            try:
                gh_api(repo, STAGE_LABEL, "-X", "POST", f"repos/{repo}/issues/{number}/labels",
                       payload={"labels": [V.HUMAN_LABEL]})
            except PostFailed as exc:
                exc.review = review
                raise
            labeled.append(number)

    return {"status": STATUS_POSTED, "verdict": result["verdict"], "event": event,
            "review_id": review.get("id"), "review_url": review.get("html_url", ""),
            "inline_comments": len(comments), "body_findings": len(off_diff),
            "labeled": labeled}


# --- CLI ----------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gates", required=True, help="input file of pre-merge-verdict.py")
    parser.add_argument("--body", required=True, help="gate report (markdown), the review body")
    parser.add_argument("--human", help="JSON decisions; required for a HUMAN verdict")
    args = parser.parse_args(argv)

    try:
        gates = load_json(args.gates, "gates file")
        V.validate(gates)
        repo, pr, issues = validate_target(gates)
        try:
            report = Path(args.body).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise V.Invalid(f"cannot read the report '{args.body}': {exc}")
        result = V.evaluate(gates)
        decisions = []
        if result["verdict"] == V.HUMAN:
            if not args.human:
                raise V.Invalid("the verdict is HUMAN: --human with question, options and "
                                "recommendation is required")
            decisions = load_json(args.human, "--human file")
            validate_human(decisions)
    except V.Invalid as exc:
        print(f"pre-merge-post: invalid input: {exc}", file=sys.stderr)
        return EXIT_INVALID

    try:
        out = post(repo, pr, issues, result, report, decisions, gates)
    except PostFailed as exc:
        out = {"status": STATUS_POST_FAILED, "stage": exc.stage, "error": exc.error,
               "review_posted": exc.review is not None}
        if exc.review is not None:
            out["review_url"] = exc.review.get("html_url", "")
        print(json.dumps(out, indent=2))
        return EXIT_POST_FAILED
    print(json.dumps(out, indent=2))
    return EXIT_POSTED


if __name__ == "__main__":
    sys.exit(main())
