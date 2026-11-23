#!/usr/bin/env python3
"""
Out-of-scope review findings of a PR as follow-up issues (#379): file the
issue once, list it in the PR body's Follow-ups section, and answer the
finding's review thread.

Usage:
  pr-followup.py file --repo <owner/name> --pr <N> --key <key> --title <text>
                      --body-file <file> [--thread <id>] [--app]
  pr-followup.py list --repo <owner/name> --pr <N> [--app]

  --key        what identifies the finding across rounds: its review thread
               id when it has one, else a short slug such as
               `bin/x.sh:redirect-gap` (letters, digits and `_.:/-`, at most
               100). A later round that sees the same finding passes the
               same key, as listed by `list`
  --title      the follow-up issue's title
  --body-file  the finding as the issue should describe it (markdown)
  --thread     the finding's open review thread (pr-review-threads.py list)
  --app        run gh under the review GitHub App of the repo's owner
               (gh-app-token.sh; PR_FOLLOWUP_TOKEN_SCRIPT overrides the
               path); without it gh runs as the logged-in user

file, idempotent, so a retried round or a re-review never files twice:
  1. the issue: a key already in the PR body's Follow-ups section, or an
     open issue whose body carries the key's marker line, is reused
     (status "exists"); else one issue is created (status "created"), with
     no label, so the queue never claims it before a human triages it. Its
     body starts with
       <!-- queue-runner:followup pr=<N> key=<key> -->
       Found in the review of #<N> (<pr url>): out of the scope of that PR,
       so it is tracked here instead of blocking it.
     and then the --body-file text. The PR is referenced, never closed: a
     closing keyword before an issue or PR reference (Closes/Fixes/Resolves
     #N, or such a keyword before a GitHub URL) in the title or the body
     file is a usage error.
  2. the PR body: a Follow-ups section between the lines
     `<!-- queue-runner:followups -->` and `<!-- /queue-runner:followups -->`
     is added at the end, or gets one line per new key:
       - #<issue>: <title> <!-- key=<key> -->
     A key that is already listed leaves the body as it is.
  3. --thread: when the thread is still open, one reply
     "followup: out of scope for this PR, tracked in #<issue>" with the
     `<!-- queue-runner -->` marker (pr-review-threads.py), then the thread
     is resolved. A thread that already has that reply is only resolved; a
     thread that is no longer open is left alone.

  Result on stdout:
    {"status": "created|exists", "issue": 123, "issue_url": "...",
     "key": "...", "pr_body": "updated|unchanged",
     "thread": null | {"id": "...", "replied": true, "resolved": true,
                       "reply_url": "..."}}

list: the Follow-ups section of the PR body as JSON, [] when there is none:
    [{"issue": 123, "title": "...", "key": "..."}]

A GitHub failure prints {"status": "failed", "stage":
"pr|issues|create|pr_body|threads|reply|resolve", "error": "...",
"issue": <number or null>} on stdout; "issue" is set once the issue exists,
so a retry reuses it.

Exit codes:
  0  filed (or found) and listed, or listed
  2  usage error (bad --repo, --pr or --key, empty title or body, a
     closing keyword); nothing was sent, stderr says why
  3  a gh or GitHub error; see the JSON result
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
POST_SCRIPT = BIN_DIR / "pre-merge-post.py"
TOKEN_SCRIPT_ENV = "PR_FOLLOWUP_TOKEN_SCRIPT"
DEFAULT_TOKEN_SCRIPT = BIN_DIR / "gh-app-token.sh"

SECTION_START = "<!-- queue-runner:followups -->"
SECTION_END = "<!-- /queue-runner:followups -->"
SECTION_HEAD = ("### Follow-ups\n\nOut-of-scope review findings, tracked in their own issues; "
                "this PR leaves them open.\n")
ENTRY = re.compile(r"^- #(\d+): (.*?) <!-- key=(\S+) -->\s*$")
KEY = re.compile(r"^[A-Za-z0-9_.:/-]{1,100}$")
# A closing keyword right before an issue or PR reference closes it on merge.
CLOSING = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b[\s:]*"
    r"(?:[\w.-]+/[\w.-]+)?#\d+"
    r"|\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b[\s:]*https?://github\.com/\S+/(?:issues|pull)/\d+",
    re.IGNORECASE)

STATUS_CREATED = "created"
STATUS_EXISTS = "exists"
STATUS_FAILED = "failed"
BODY_UPDATED = "updated"
BODY_UNCHANGED = "unchanged"
STAGE_PR = "pr"
STAGE_ISSUES = "issues"
STAGE_CREATE = "create"
STAGE_PR_BODY = "pr_body"
STAGE_THREADS = "threads"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_FAILED = 3

PAGE_SIZE = 100
ERROR_LINES = 5


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


P = _load_module("pre_merge_post", POST_SCRIPT)
T = P.T


class Usage(Exception):
    pass


class FollowupFailed(Exception):
    def __init__(self, stage, error, issue=None):
        super().__init__(error)
        self.stage, self.error, self.issue = stage, error, issue


# --- texts --------------------------------------------------------------------------

def issue_marker(pr, key):
    return f"<!-- queue-runner:followup pr={pr} key={key} -->"


def check_no_closing(what, text):
    match = CLOSING.search(text)
    if match:
        raise Usage(f"{what} must not close anything, found {match.group(0)!r}; "
                    "reference with a non-closing verb (see #N, found in #N)")


def issue_body(pr, pr_url, key, text):
    return (f"{issue_marker(pr, key)}\n"
            f"Found in the review of #{pr} ({pr_url}): out of the scope of that PR, "
            f"so it is tracked here instead of blocking it.\n\n{text.strip()}\n")


def section_entries(body):
    """The entries of the Follow-ups section: [{"issue", "title", "key"}]."""
    lines = (body or "").replace("\r\n", "\n").split("\n")
    entries, inside = [], False
    for line in lines:
        if line.strip() == SECTION_START:
            inside = True
        elif line.strip() == SECTION_END:
            inside = False
        elif inside:
            match = ENTRY.match(line.strip())
            if match:
                entries.append({"issue": int(match.group(1)), "title": match.group(2),
                                "key": match.group(3)})
    return entries


def with_entry(body, issue, title, key):
    """The PR body with the entry in its Follow-ups section (added at the end when missing)."""
    body = (body or "").replace("\r\n", "\n")
    line = f"- #{issue}: {' '.join(title.split())} <!-- key={key} -->"
    lines = body.split("\n")
    ends = [i for i, l in enumerate(lines) if l.strip() == SECTION_END]
    starts = [i for i, l in enumerate(lines) if l.strip() == SECTION_START]
    if starts and ends and ends[-1] > starts[0]:
        lines.insert(ends[-1], line)
        return "\n".join(lines)
    section = f"{SECTION_START}\n{SECTION_HEAD}\n{line}\n{SECTION_END}"
    return f"{body.rstrip()}\n\n{section}\n" if body.strip() else f"{section}\n"


# --- gh -----------------------------------------------------------------------------

def gh_runner(repo, app):
    """run(stage, args, payload=None) -> stdout of `gh <args>`, under the app token when app."""
    def run(stage, args, payload=None):
        with tempfile.TemporaryDirectory(prefix="pr-followup.") as work:
            cmd = ["gh", *args]
            if payload is not None:
                request = Path(work) / "request.json"
                request.write_text(json.dumps(payload), encoding="utf-8")
                cmd += ["--input", str(request)]
            if app:
                token_script = os.environ.get(TOKEN_SCRIPT_ENV) or str(DEFAULT_TOKEN_SCRIPT)
                cmd = [token_script, "--repo", repo, "--", *cmd]
            try:
                r = subprocess.run(cmd, capture_output=True, text=True)
            except OSError as exc:
                raise FollowupFailed(stage, f"cannot run {cmd[0]}: {exc}")
        if r.returncode != 0:
            # A GraphQL error comes as JSON on stdout; T.graphql reads it.
            if args[:2] == ["api", "graphql"] and r.stdout.strip().startswith("{"):
                return r.stdout
            lines = [l for l in r.stderr.splitlines() if l.strip()]
            raise FollowupFailed(stage, " | ".join(lines[-ERROR_LINES:])
                                 or f"exit {r.returncode}, no message")
        return r.stdout
    return run


def json_of(stage, text):
    try:
        return json.loads(text)
    except ValueError as exc:
        raise FollowupFailed(stage, f"unreadable answer: {exc}")


def pages_of(stage, text):
    try:
        return P.parse_pages(text)
    except ValueError as exc:
        raise FollowupFailed(stage, f"unreadable answer: {exc}")


def read_pr(run, repo, pr):
    return json_of(STAGE_PR, run(STAGE_PR, ["api", f"repos/{repo}/pulls/{pr}"]))


def find_open_issue(run, repo, pr, key):
    """An open issue whose body carries the key's marker line, or None."""
    marker = issue_marker(pr, key)
    issues = pages_of(STAGE_ISSUES, run(STAGE_ISSUES, [
        "api", "--paginate", f"repos/{repo}/issues?state=open&per_page={PAGE_SIZE}"]))
    for issue in sorted(issues, key=lambda i: i.get("number") or 0):
        if "pull_request" not in issue and marker in (issue.get("body") or "").splitlines():
            return issue
    return None


def graphql_runner(run):
    """run(stage, payload) for pr-review-threads.py; its list stage is ours "threads"."""
    def graphql(stage, payload):
        own = STAGE_THREADS if stage == T.STAGE_LIST else stage
        return run(own, ["api", "graphql"], payload)
    return graphql


def answer_thread(run, repo, pr, thread, issue):
    """Reply followup on the thread and resolve it; see step 3 of --help."""
    gql = graphql_runner(run)
    text = T.outcome_text(T.OUTCOME_FOLLOWUP, f"#{issue}")
    try:
        open_threads = {t["id"]: t for t in T.list_open_threads(gql, repo, pr)}
        if thread not in open_threads:
            return {"id": thread, "replied": False, "resolved": False, "reply_url": None}
        if any((c.get("body") or "").replace("\r\n", "\n") == T.marked(text)
               for c in open_threads[thread]["comments"]):
            T.graphql(gql, T.STAGE_RESOLVE, T.RESOLVE_MUTATION, {"thread": thread})
            return {"id": thread, "replied": False, "resolved": True, "reply_url": None}
        result = T.reply(gql, thread, text, resolve=True)
    except T.ThreadsFailed as exc:
        stage = STAGE_THREADS if exc.stage == T.STAGE_LIST else exc.stage
        raise FollowupFailed(stage, exc.error, issue)
    except FollowupFailed as exc:
        exc.issue = issue
        raise
    return {"id": thread, "replied": True, "resolved": True, "reply_url": result["reply_url"]}


def file_followup(run, repo, pr, key, title, text, thread=None):
    pull = read_pr(run, repo, pr)
    body, pr_url = pull.get("body") or "", pull.get("html_url", "")
    listed = next((e for e in section_entries(body) if e["key"] == key), None)
    if listed:
        status, number = STATUS_EXISTS, listed["issue"]
        issue_url = f"https://github.com/{repo}/issues/{number}"
    else:
        found = find_open_issue(run, repo, pr, key)
        if found:
            status, number, issue_url = STATUS_EXISTS, found["number"], found.get("html_url", "")
        else:
            created = json_of(STAGE_CREATE, run(STAGE_CREATE, [
                "api", "-X", "POST", f"repos/{repo}/issues"],
                payload={"title": title, "body": issue_body(pr, pr_url, key, text)}))
            status, number, issue_url = STATUS_CREATED, created.get("number"), created.get("html_url", "")
            if not isinstance(number, int):
                raise FollowupFailed(STAGE_CREATE, "the created issue has no number")

    pr_body = BODY_UNCHANGED
    if not listed:
        try:
            run(STAGE_PR_BODY, ["api", "-X", "PATCH", f"repos/{repo}/pulls/{pr}"],
                payload={"body": with_entry(body, number, title, key)})
        except FollowupFailed as exc:
            exc.issue = number
            raise
        pr_body = BODY_UPDATED

    answered = answer_thread(run, repo, pr, thread, number) if thread else None
    return {"status": status, "issue": number, "issue_url": issue_url, "key": key,
            "pr_body": pr_body, "thread": answered}


# --- CLI ----------------------------------------------------------------------------

def repo_arg(value):
    if not re.match(r"^[^/\s]+/[^/\s]+$", value or ""):
        raise argparse.ArgumentTypeError(f"--repo must be owner/name, got {value!r}")
    return value


def pr_arg(value):
    try:
        number = int(value)
    except ValueError:
        number = 0
    if number <= 0:
        raise argparse.ArgumentTypeError(f"--pr must be a positive PR number, got {value!r}")
    return number


def file_inputs(args):
    """(title, text) of `file`; raises Usage before anything is sent."""
    if not KEY.match(args.key or ""):
        raise Usage(f"--key must be 1 to 100 of letters, digits and _.:/-, got {args.key!r}")
    title = " ".join((args.title or "").split())
    if not title:
        raise Usage("--title must not be empty")
    try:
        text = Path(args.body_file).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise Usage(f"cannot read --body-file '{args.body_file}': {exc}")
    if not text.strip():
        raise Usage("--body-file is empty")
    if args.thread is not None and not args.thread.strip():
        raise Usage("--thread must not be empty")
    check_no_closing("--title", title)
    check_no_closing("--body-file", text)
    return title, text


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_file = sub.add_parser("file", help="file (or find) the follow-up issue of a finding")
    p_file.add_argument("--repo", required=True, type=repo_arg)
    p_file.add_argument("--pr", required=True, type=pr_arg)
    p_file.add_argument("--key", required=True)
    p_file.add_argument("--title", required=True)
    p_file.add_argument("--body-file", required=True)
    p_file.add_argument("--thread")
    p_file.add_argument("--app", action="store_true")
    p_list = sub.add_parser("list", help="the Follow-ups section of the PR body")
    p_list.add_argument("--repo", required=True, type=repo_arg)
    p_list.add_argument("--pr", required=True, type=pr_arg)
    p_list.add_argument("--app", action="store_true")
    args = parser.parse_args(argv)

    try:
        inputs = file_inputs(args) if args.command == "file" else None
    except Usage as exc:
        print(f"pr-followup: {exc}", file=sys.stderr)
        return EXIT_USAGE

    run = gh_runner(args.repo, args.app)
    try:
        if args.command == "list":
            result = section_entries(read_pr(run, args.repo, args.pr).get("body"))
        else:
            title, text = inputs
            result = file_followup(run, args.repo, args.pr, args.key, title, text, args.thread)
    except FollowupFailed as exc:
        print(json.dumps({"status": STATUS_FAILED, "stage": exc.stage, "error": exc.error,
                          "issue": exc.issue}, indent=2))
        return EXIT_FAILED
    print(json.dumps(result, indent=2))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
