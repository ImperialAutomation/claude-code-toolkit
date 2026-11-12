#!/usr/bin/env python3
"""
Standalone tests for pre-merge-post.py (/pre-merge --post, #296).

Run directly: python3 bin/tests/test-pre-merge-post.py

Hermetic: `gh` is a stub first on PATH and the token script is a stub named
by PRE_MERGE_TOKEN_SCRIPT, so nothing reaches GitHub and no app credentials
are read. The gh stub records every call (arguments, GH_TOKEN, the --input
body) and answers from fixtures; STUB_FAIL=files|review|label makes that call
fail, STUB_NO_TOKEN makes the token stub fail like a missing app.
PRE_MERGE_FINDINGS_LOG points at a temp file, which posting must not write.

Covers the verdict-to-review-event mapping (APPROVE, REQUEST_CHANGES,
COMMENT), the needs-human label on the PR and every linked issue for HUMAN,
the question/options/recommendation in the review body, inline comments for
findings on a diff line (the rest in the body), one review per run, and every
post failure as a distinct result that carries no verdict.

When adding a case, check it actually constrains the script: break the rule
in pre-merge-post.py, confirm THIS test goes red, then revert.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent
SCRIPT_PATH = BIN / "pre-merge-post.py"
VERDICT_PATH = BIN / "pre-merge-verdict.py"

passed = 0
failed = 0


def check(name, condition):
    global passed, failed
    if condition:
        print(f"PASS: {name}")
        passed += 1
    else:
        print(f"FAIL: {name}")
        failed += 1


tmp = tempfile.TemporaryDirectory()
TMP = Path(tmp.name)
STUB = TMP / "stub"
STUBBIN = TMP / "stubbin"
STUB.mkdir()
STUBBIN.mkdir()
LOG = TMP / "pre-merge-findings.tsv"
APP_TOKEN = "stub-app-token"

GH_STUB = r'''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
stub = Path(os.environ["STUB"])
args = sys.argv[1:]
body = None
if "--input" in args:
    body = json.loads(Path(args[args.index("--input") + 1]).read_text())
with (stub / "calls.jsonl").open("a") as fh:
    fh.write(json.dumps({"args": args, "gh_token": os.environ.get("GH_TOKEN"), "input": body}) + "\n")
fail = os.environ.get("STUB_FAIL", "")
path = next((a for a in args if a.startswith("repos/")), "")
if re.search(r"/pulls/\d+/files", path):
    if fail == "files":
        print("gh: Not Found (HTTP 404)", file=sys.stderr); sys.exit(1)
    sys.stdout.write((stub / "files.out").read_text())
elif path.endswith("/reviews"):
    if fail == "review":
        print("gh: Unprocessable Entity (HTTP 422)", file=sys.stderr); sys.exit(1)
    print(json.dumps({"id": 9001, "state": "COMMENTED",
                      "html_url": "https://github.com/owner/repo/pull/42#pullrequestreview-9001"}))
elif path.endswith("/labels"):
    if fail == "label":
        print("gh: Resource not accessible by integration (HTTP 403)", file=sys.stderr); sys.exit(1)
    print(json.dumps([{"name": "needs-human"}]))
else:
    print(f"gh stub: unexpected call {args}", file=sys.stderr); sys.exit(1)
'''

TOKEN_STUB = r'''#!/bin/bash
echo "$*" >> "$STUB/token.log"
if [[ -n "${STUB_NO_TOKEN:-}" ]]; then
    echo "gh-app-token.sh: no GitHub App for owner owner: app-id is missing or unreadable" >&2
    exit 1
fi
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
GH_TOKEN=stub-app-token exec "$@"
'''

(STUBBIN / "gh").write_text(GH_STUB)
(STUBBIN / "gh").chmod(0o755)
TOKEN_SCRIPT = TMP / "gh-app-token-stub.sh"
TOKEN_SCRIPT.write_text(TOKEN_STUB)
TOKEN_SCRIPT.chmod(0o755)

# Two pages, as `gh api --paginate` prints them: concatenated arrays.
# bin/x.sh: right-side lines 1-4; a.py: lines 10-12; img.png has no patch.
PAGE1 = [{"filename": "bin/x.sh", "patch": "@@ -1,3 +1,4 @@\n line1\n+line2\n line3\n-old\n+line4"}]
PAGE2 = [{"filename": "a.py", "patch": "@@ -10,2 +10,3 @@\n ctx\n+new\n ctx2"},
         {"filename": "img.png"}]
(STUB / "files.out").write_text(json.dumps(PAGE1) + json.dumps(PAGE2) + "\n")

REPORT = "## Pre-Merge Quality Gate\n\nthe Phase 9 report\n"
REPORT_FILE = TMP / "report.md"
REPORT_FILE.write_text(REPORT)

HUMAN_Q = [{"question": "Should bin/old.sh be deleted, given other repos call it?",
            "options": ["A: delete it", "B: keep a wrapper for one release"],
            "recommendation": "B, because two projects still call it"}]
HUMAN_FILE = TMP / "human.json"
HUMAN_FILE.write_text(json.dumps(HUMAN_Q))

ESC_HIT = {"category": "interface", "file": "bin/old.sh", "reason": "deleted"}


def gates(**sections):
    payload = {"repo": "owner/repo", "pr": 42, "branch": "issue-1-x"}
    payload.update(sections)
    return payload


def finding(path="bin/x.sh", line=2, shadow="MEDIUM", summary="off by one"):
    return {"file": path, "line": line, "summary": summary,
            "failure_scenario": "loop skips the last item", "shadow_severity": shadow}


def reset_stub():
    for name in ("calls.jsonl", "token.log"):
        (STUB / name).unlink(missing_ok=True)


def calls():
    path = STUB / "calls.jsonl"
    return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []


def review_calls():
    return [c for c in calls() if any(a.endswith("/reviews") for a in c["args"])]


def label_calls():
    return [c for c in calls() if any(a.endswith("/labels") for a in c["args"])]


def run(payload, *extra, human=True, env_extra=None, raw_args=None):
    """Run the poster; returns (CompletedProcess, parsed stdout)."""
    reset_stub()
    gates_file = TMP / "gates.json"
    gates_file.write_text(json.dumps(payload))
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    env.update(PATH=f"{STUBBIN}:{env['PATH']}", STUB=str(STUB), HOME=str(TMP / "home"),
               PRE_MERGE_TOKEN_SCRIPT=str(TOKEN_SCRIPT), PRE_MERGE_FINDINGS_LOG=str(LOG))
    env.update(env_extra or {})
    args = raw_args if raw_args is not None else (
        ["--gates", str(gates_file), "--body", str(REPORT_FILE)]
        + (["--human", str(HUMAN_FILE)] if human else []) + list(extra))
    r = subprocess.run([sys.executable, str(SCRIPT_PATH), *args], env=env,
                       capture_output=True, text=True)
    try:
        out = json.loads(r.stdout)
    except ValueError:
        out = {}
    return r, out


# --- the mapping itself, where #295's verdict rules live --------------------

print("--- verdict -> review event mapping ---")
spec = importlib.util.spec_from_file_location("pre_merge_verdict", VERDICT_PATH)
verdict_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verdict_mod)
check("APPROVE -> APPROVE", verdict_mod.REVIEW_EVENTS.get("APPROVE") == "APPROVE")
check("BLOCKING -> REQUEST_CHANGES", verdict_mod.REVIEW_EVENTS.get("BLOCKING") == "REQUEST_CHANGES")
check("HUMAN -> COMMENT", verdict_mod.REVIEW_EVENTS.get("HUMAN") == "COMMENT")
check("every verdict has exactly one review event",
      set(verdict_mod.REVIEW_EVENTS) == {verdict_mod.APPROVE, verdict_mod.BLOCKING, verdict_mod.HUMAN})
check("the HUMAN label is needs-human", verdict_mod.HUMAN_LABEL == "needs-human")

# --- APPROVE ----------------------------------------------------------------

print("--- APPROVE ---")
r, out = run(gates(tests={"passed": 3, "failed": 0, "skipped": 0}), human=False)
rc = review_calls()
check("APPROVE: exit 0, status posted", r.returncode == 0 and out.get("status") == "posted")
check("APPROVE: one review with event APPROVE",
      len(rc) == 1 and rc[0]["input"]["event"] == "APPROVE")
check("APPROVE: output names verdict and event",
      out.get("verdict") == "APPROVE" and out.get("event") == "APPROVE")
check("APPROVE: no label added", label_calls() == [] and out.get("labeled") == [])
check("APPROVE: the review goes to the PR of the gates file",
      len(rc) == 1 and "repos/owner/repo/pulls/42/reviews" in rc[0]["args"])
check("every gh call carries the app token (went through the token script)",
      calls() and all(c["gh_token"] == APP_TOKEN for c in calls()))
token_log = (STUB / "token.log").read_text() if (STUB / "token.log").exists() else ""
check("the token script is asked for the repo of the gates file",
      token_log and all(l.startswith("--repo owner/repo -- gh ") for l in token_log.splitlines()))
check("the report body is in the review body",
      len(rc) == 1 and REPORT.strip() in rc[0]["input"]["body"])
check("the review URL is reported", out.get("review_url", "").endswith("pullrequestreview-9001"))
check("posting writes no findings-log row (the verdict run already did)", not LOG.exists())

# --- BLOCKING with inline comments --------------------------------------------

print("--- BLOCKING and inline comments ---")
r, out = run(gates(
    correctness_findings=[finding(line=2), finding(line=50, summary="outside the diff"),
                          finding(line=None, summary="file only")],
    review_findings=[{"severity": "HIGH", "finding": "uncaught error", "location": "a.py:11"},
                     {"severity": "MEDIUM", "finding": "magic number", "location": "a.py:3"},
                     {"severity": "LOW", "finding": "no location", "location": "-"}]),
    human=False)
rc = review_calls()
review = rc[0]["input"] if len(rc) == 1 else {}
comments = review.get("comments", [])
check("BLOCKING: exit 0, event REQUEST_CHANGES",
      r.returncode == 0 and review.get("event") == "REQUEST_CHANGES" and out.get("event") == "REQUEST_CHANGES")
check("BLOCKING: one review per run, comments in the same review", len(rc) == 1)
check("finding on a diff line -> inline comment on that path and line, right side",
      any(c.get("path") == "bin/x.sh" and c.get("line") == 2 and c.get("side") == "RIGHT"
          and "off by one" in c.get("body", "") for c in comments))
check("/review finding with file:line on the diff -> inline comment",
      any(c.get("path") == "a.py" and c.get("line") == 11 and "uncaught error" in c.get("body", "")
          for c in comments))
check("only the two diff-line findings are inline", len(comments) == 2)
body = review.get("body", "")
check("a finding on a line outside the diff goes into the body",
      "outside the diff" in body and "bin/x.sh:50" in body and "magic number" in body)
check("a correctness finding without a line goes into the body", "file only" in body)
check("output counts inline and body findings",
      out.get("inline_comments") == 2 and out.get("body_findings") == 3)
check("the PR files are read with pagination",
      any("--paginate" in c["args"]
          and any(a.startswith("repos/owner/repo/pulls/42/files") for a in c["args"]) for c in calls()))
check("BLOCKING: no label", label_calls() == [])

# --- HUMAN --------------------------------------------------------------------

print("--- HUMAN ---")
r, out = run(gates(escalation={"hits": [ESC_HIT], "linked_issues": [{"number": 7, "labels": []},
                                                                    {"number": 8, "labels": []}]},
                   correctness_findings=[finding(line=4, summary="still blocking")],
                   tests={"passed": 1, "failed": 1, "skipped": 0}))
rc = review_calls()
review = rc[0]["input"] if len(rc) == 1 else {}
body = review.get("body", "")
check("HUMAN (with BLOCKING findings too): event COMMENT",
      r.returncode == 0 and review.get("event") == "COMMENT" and out.get("verdict") == "HUMAN")
check("HUMAN: question, options and recommendation in the body",
      HUMAN_Q[0]["question"] in body and "A: delete it" in body
      and "B: keep a wrapper for one release" in body and HUMAN_Q[0]["recommendation"] in body)
check("HUMAN: the human reasons are in the body", "bin/old.sh" in body and "interface" in body)
check("HUMAN: the BLOCKING reasons stay listed in the body", "1 failed" in body)
check("HUMAN: the BLOCKING finding is still an inline comment",
      any(c.get("line") == 4 and "still blocking" in c.get("body", "") for c in review.get("comments", [])))
targets = sorted(next((a for a in c["args"] if a.endswith("/labels")), "") for c in label_calls())
check("HUMAN: needs-human on the PR and on every linked issue",
      targets == ["repos/owner/repo/issues/42/labels", "repos/owner/repo/issues/7/labels",
                  "repos/owner/repo/issues/8/labels"])
check("HUMAN: the label added is needs-human",
      label_calls() and all(c["input"] == {"labels": ["needs-human"]} for c in label_calls()))
kinds = ["review" if any(a.endswith("/reviews") for a in c["args"])
         else "label" if any(a.endswith("/labels") for a in c["args"]) else "other" for c in calls()]
check("HUMAN: the labels go on after the review",
      "label" in kinds and kinds.index("review") < kinds.index("label"))
check("HUMAN: output lists the labeled numbers", out.get("labeled") == [42, 7, 8])

r, out = run(gates(escalation={"hits": [ESC_HIT], "linked_issues": [{"number": 42, "labels": []}]}))
check("a linked issue equal to the PR number is labeled once",
      len(label_calls()) == 1 and out.get("labeled") == [42])

r, out = run(gates(escalation={"hits": [ESC_HIT]}), human=False)
check("HUMAN without --human: exit 2, nothing posted", r.returncode == 2 and calls() == [])
check("HUMAN without --human: the error names --human", "--human" in r.stderr)

for name, content in [("an empty list", []),
                      ("a question with one option",
                       [{"question": "q", "options": ["A"], "recommendation": "A"}]),
                      ("no recommendation", [{"question": "q", "options": ["A", "B"]}]),
                      ("not JSON", None)]:
    bad = TMP / "bad-human.json"
    bad.write_text("{nope" if content is None else json.dumps(content))
    r, out = run(gates(escalation={"hits": [ESC_HIT]}), raw_args=[
        "--gates", str(TMP / "gates.json"), "--body", str(REPORT_FILE), "--human", str(bad)])
    check(f"--human with {name}: exit 2, nothing posted", r.returncode == 2 and calls() == [])

# --- post failures: distinct, never a verdict ---------------------------------

print("--- post failures ---")
r, out = run(gates(), human=False, env_extra={"STUB_NO_TOKEN": "1"})
check("no token: exit 3, status post_failed", r.returncode == 3 and out.get("status") == "post_failed")
check("no token: the error carries the token script's message",
      "no GitHub App for owner" in out.get("error", ""))
check("no token: no verdict and no event in the result", "verdict" not in out and "event" not in out)
check("no token: review_posted false", out.get("review_posted") is False)
check("no token: gh never ran", calls() == [])

r, out = run(gates(), human=False, env_extra={"STUB_FAIL": "files"})
check("PR files unreadable: exit 3, stage files, no review posted",
      r.returncode == 3 and out.get("stage") == "files" and review_calls() == []
      and out.get("review_posted") is False)

r, out = run(gates(), human=False, env_extra={"STUB_FAIL": "review"})
check("review API error: exit 3, stage review, review_posted false",
      r.returncode == 3 and out.get("stage") == "review" and out.get("review_posted") is False)
check("review API error: the gh error is reported", "HTTP 422" in out.get("error", ""))
check("review API error: no verdict in the result", "verdict" not in out)

r, out = run(gates(escalation={"hits": [ESC_HIT], "linked_issues": [{"number": 7, "labels": []}]}),
             env_extra={"STUB_FAIL": "label"})
check("label error after the review: exit 3, stage label",
      r.returncode == 3 and out.get("stage") == "label")
check("label error after the review: review_posted true with its URL",
      out.get("review_posted") is True and out.get("review_url", "").endswith("pullrequestreview-9001"))
check("label error: no verdict in the result", "verdict" not in out)

# --- invalid input --------------------------------------------------------------

print("--- invalid input ---")
r, out = run({"repo": "owner/repo", "pr": None, "branch": "issue-1-x"}, human=False)
check("no PR number: exit 2, nothing posted", r.returncode == 2 and calls() == [])
r, out = run({"pr": 42}, human=False)
check("no repo: exit 2, nothing posted", r.returncode == 2 and calls() == [])
r, out = run(gates(acceptence=[]), human=False)
check("gates invalid for the verdict helper: exit 2, nothing posted",
      r.returncode == 2 and calls() == [])
r, out = run(gates(), raw_args=["--gates", str(TMP / "gates.json")])
check("missing --body: exit 2", r.returncode == 2 and calls() == [])
r, out = run(gates(), raw_args=["--gates", str(TMP / "none.json"), "--body", str(REPORT_FILE)])
check("unreadable gates file: exit 2", r.returncode == 2 and calls() == [])

# --- CLI ------------------------------------------------------------------------

print("--- CLI ---")
r = subprocess.run([sys.executable, str(SCRIPT_PATH), "--help"], capture_output=True, text=True)
check("--help exits 0", r.returncode == 0)
check("--help documents the exit codes and the result statuses",
      "Exit codes" in r.stdout and "post_failed" in r.stdout and "needs-human" in r.stdout)

tmp.cleanup()

print(f"\nResults: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
