#!/usr/bin/env python3
"""
Standalone tests for pr-followup.py (out-of-scope findings as follow-up
issues, #379).

Run directly: python3 bin/tests/test-pr-followup.py

Hermetic: `gh` is a stub first on PATH and the token script is a stub named
by PR_FOLLOWUP_TOKEN_SCRIPT, so nothing reaches GitHub and no issue is ever
created. The stub keeps a small fake repo in files (the PR, the open
issues, the review threads), records every call, and STUB_FAIL=<kind> makes
that kind of call fail like gh does on an HTTP error.

Covers: the follow-up issue references the PR and never closes it (and a
closing keyword in the input is refused before anything is sent); no label;
idempotency (a retry, a re-review, a crash between filing and the PR body);
the Follow-ups section of the PR body is added once and extended per key;
the thread reply carries the marker, the follow-up text and resolves; list.

When adding a case, check it actually constrains the script: break the rule
in pr-followup.py, confirm THIS test goes red, then revert.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent
SCRIPT = BIN / "pr-followup.py"
MARKER = "<!-- queue-runner -->"
REPO = "owner/repo"
PR_URL = "https://github.com/owner/repo/pull/42"
CLOSING = re.compile(r"\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b[\s:]*(#\d+|https://github\.com/\S+)",
                     re.IGNORECASE)

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
APP_TOKEN = "stub-app-token"

GH_STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
stub = Path(os.environ["STUB"])
args = sys.argv[1:]
req = json.loads(Path(args[args.index("--input") + 1]).read_text()) if "--input" in args else None
path = next((a for a in args if a.startswith("repos/")), "")
method = args[args.index("-X") + 1] if "-X" in args else "GET"
if args[:2] == ["api", "graphql"]:
    q = req["query"]
    kind = ("threads" if "reviewThreads" in q else "resolve" if "resolveReviewThread" in q
            else "reply" if "addPullRequestReviewThreadReply" in q else "other")
elif path.startswith("repos/owner/repo/pulls/"):
    kind = "pr_body" if method == "PATCH" else "pr"
elif path.startswith("repos/owner/repo/issues"):
    kind = "create" if method == "POST" else "issues"
else:
    kind = "other"
with (stub / "calls.jsonl").open("a") as fh:
    fh.write(json.dumps({"kind": kind, "args": args, "gh_token": os.environ.get("GH_TOKEN"),
                         "input": req}) + "\n")
if os.environ.get("STUB_FAIL") == kind:
    print("gh: Something went wrong (HTTP 502)", file=sys.stderr); sys.exit(1)
def load(name):
    return json.loads((stub / name).read_text())
def save(name, data):
    (stub / name).write_text(json.dumps(data))
if kind == "pr":
    print(json.dumps(load("pr.json")))
elif kind == "pr_body":
    pr = load("pr.json"); pr["body"] = req["body"]; save("pr.json", pr); print(json.dumps(pr))
elif kind == "issues":
    issues = load("issues.json")
    print(json.dumps(issues[:1])); print(json.dumps(issues[1:]))   # two pages
elif kind == "create":
    issues = load("issues.json")
    number = 500 + len([i for i in issues if i["number"] >= 500])
    issue = {"number": number, "html_url": f"https://github.com/owner/repo/issues/{number}",
             "title": req["title"], "body": req["body"]}
    save("issues.json", issues + [issue]); print(json.dumps(issue))
elif kind == "threads":
    nodes = load("threads.json")
    print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {
        "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}}}))
elif kind == "reply":
    nodes = load("threads.json")
    for n in nodes:
        if n["id"] == req["variables"]["thread"]:
            n["comments"]["nodes"].append({"databaseId": 900, "url": "u", "body": req["variables"]["body"],
                                           "author": {"login": "me"}})
    save("threads.json", nodes)
    print(json.dumps({"data": {"addPullRequestReviewThreadReply": {"comment": {
        "url": "https://github.com/owner/repo/pull/42#discussion_r900"}}}}))
elif kind == "resolve":
    nodes = load("threads.json")
    for n in nodes:
        if n["id"] == req["variables"]["thread"]:
            n["isResolved"] = True
    save("threads.json", nodes)
    print(json.dumps({"data": {"resolveReviewThread": {"thread": {"id": req["variables"]["thread"],
                                                                  "isResolved": True}}}}))
else:
    print(f"gh stub: unexpected call {args}", file=sys.stderr); sys.exit(1)
'''

TOKEN_STUB = r'''#!/bin/bash
echo "$*" >> "$STUB/token.log"
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
GH_TOKEN=stub-app-token exec "$@"
'''

(STUBBIN / "gh").write_text(GH_STUB)
(STUBBIN / "gh").chmod(0o755)
TOKEN_SCRIPT = TMP / "gh-app-token-stub.sh"
TOKEN_SCRIPT.write_text(TOKEN_STUB)
TOKEN_SCRIPT.chmod(0o755)

PR_BODY = "## Summary\n\nPart of #379.\n"
OTHER_ISSUE = {"number": 7, "html_url": "https://github.com/owner/repo/issues/7",
               "title": "unrelated", "body": "nothing to see"}
A_PR = {"number": 8, "html_url": "https://github.com/owner/repo/pull/8", "title": "a PR",
        "body": "<!-- queue-runner:followup pr=42 key=k-pr -->", "pull_request": {}}


def thread(tid, comments=()):
    return {"id": tid, "isResolved": False, "isOutdated": False, "path": "lib/live-checkout.sh",
            "line": 9, "originalLine": 9,
            "comments": {"nodes": [{"databaseId": 1, "url": "u", "author": {"login": "review-app[bot]"},
                                    "body": "**Correctness**: redirect gap"}, *comments]}}


def reset_repo(pr_body=PR_BODY, threads=()):
    for name in ("calls.jsonl", "token.log"):
        (STUB / name).unlink(missing_ok=True)
    (STUB / "pr.json").write_text(json.dumps({"number": 42, "html_url": PR_URL, "body": pr_body}))
    (STUB / "issues.json").write_text(json.dumps([OTHER_ISSUE, A_PR]))
    (STUB / "threads.json").write_text(json.dumps(list(threads)))


def calls(kind=None):
    path = STUB / "calls.jsonl"
    rows = [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []
    return [c for c in rows if kind is None or c["kind"] == kind]


def pr_body():
    return json.loads((STUB / "pr.json").read_text())["body"]


def issues():
    return json.loads((STUB / "issues.json").read_text())


def run(*args, env_extra=None, fresh=False):
    if fresh:
        (STUB / "calls.jsonl").unlink(missing_ok=True)
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    env.update(PATH=f"{STUBBIN}:{env['PATH']}", STUB=str(STUB), HOME=str(TMP / "home"),
               PR_FOLLOWUP_TOKEN_SCRIPT=str(TOKEN_SCRIPT))
    env.update(env_extra or {})
    r = subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True)
    try:
        out = json.loads(r.stdout)
    except ValueError:
        out = None
    return r, out


BODY_FILE = TMP / "finding.md"
BODY_FILE.write_text("`lib/live-checkout.sh:9` follows a redirect without the live-checkout check.\n")
TITLE = "live-checkout.sh: redirect bypasses the live-checkout check"


def file_args(key="lib/live-checkout.sh:redirect", title=TITLE, body=BODY_FILE, extra=()):
    return ["file", "--repo", REPO, "--pr", "42", "--key", key, "--title", title,
            "--body-file", str(body), *extra]


# --- create ---------------------------------------------------------------------------

print("--- create ---")
reset_repo()
r, out = run(*file_args())
created = calls("create")
issue = created[0]["input"] if created else {}
check("file: exit 0, status created, the new issue's number and url",
      r.returncode == 0 and out and out.get("status") == "created" and out.get("issue") == 500
      and out.get("issue_url", "").endswith("/issues/500"))
check("file: exactly one issue is created, with the given title", len(created) == 1
      and issue.get("title") == TITLE)
check("file: the issue body starts with the follow-up marker of PR and key",
      issue.get("body", "").startswith("<!-- queue-runner:followup pr=42 key=lib/live-checkout.sh:redirect -->\n"))
check("file: the issue body references the PR (found in the review of #42, with its url)",
      f"Found in the review of #42 ({PR_URL})" in issue.get("body", ""))
check("file: the issue body carries the finding text", "follows a redirect" in issue.get("body", ""))
check("file: the issue body has no closing keyword", issue and not CLOSING.search(issue["body"]))
check("file: the issue gets no label (the queue never claims it untriaged)", "labels" not in issue)
body = pr_body()
check("file: the PR body keeps its text and gets the Follow-ups section",
      body.startswith(PR_BODY.rstrip()) and "<!-- queue-runner:followups -->" in body
      and "### Follow-ups" in body and "<!-- /queue-runner:followups -->" in body)
check("file: the section lists the issue with its title and key",
      f"- #500: {TITLE} <!-- key=lib/live-checkout.sh:redirect -->" in body)
check("file: the PR body has no closing keyword", not CLOSING.search(body))
check("file: result says pr_body updated, no thread", out and out.get("pr_body") == "updated"
      and out.get("thread") is None)
check("file: without --app gh runs as the user", not (STUB / "token.log").exists()
      and all(c["gh_token"] is None for c in calls()))

# --- idempotency ------------------------------------------------------------------------

print("--- no duplicate on retry ---")
r, out = run(*file_args(), fresh=True)
check("retry: exit 0, status exists, the same issue", r.returncode == 0 and out
      and out.get("status") == "exists" and out.get("issue") == 500)
check("retry: no issue created, the PR body left alone",
      calls("create") == [] and calls("pr_body") == [] and out.get("pr_body") == "unchanged")
check("retry: the issue is found from the PR body, without scanning the issues", calls("issues") == [])

r, out = run(*file_args(key="bin/hint.sh:edge", title="hint.sh: old edge case"), fresh=True)
body = pr_body()
check("a second key: a second issue, appended to the same section",
      r.returncode == 0 and out and out.get("issue") == 501 and body.count("### Follow-ups") == 1
      and body.count("<!-- queue-runner:followups -->") == 1
      and body.index("#500:") < body.index("#501:") < body.index("<!-- /queue-runner:followups -->"))

print("--- crash between filing and the PR body ---")
reset_repo()
r, out = run(*file_args(), env_extra={"STUB_FAIL": "pr_body"})
check("PR body edit fails: exit 3, stage pr_body, the issue number is in the result",
      r.returncode == 3 and out and out.get("stage") == "pr_body" and out.get("issue") == 500)
r, out = run(*file_args(), fresh=True)
check("the retry finds the open issue by its marker and creates none",
      r.returncode == 0 and out and out.get("status") == "exists" and out.get("issue") == 500
      and calls("create") == [] and len(issues()) == 3)
check("the issue scan reads every page (--paginate) and skips pull requests",
      calls("issues") and "--paginate" in calls("issues")[0]["args"])
check("the retry then adds the PR body entry", "- #500: " in pr_body() and out.get("pr_body") == "updated")

reset_repo()
r, out = run(*file_args(key="k-pr"))
check("a pull request carrying the marker is not taken for the issue",
      r.returncode == 0 and out and out.get("status") == "created")

# --- thread ----------------------------------------------------------------------------

print("--- thread ---")
reset_repo(threads=[thread("PRRT_a")])
r, out = run(*file_args(extra=["--thread", "PRRT_a"]))
replies, resolves = calls("reply"), calls("resolve")
reply_body = replies[0]["input"]["variables"]["body"] if replies else ""
check("--thread: one reply with the marker and the follow-up issue",
      r.returncode == 0 and len(replies) == 1
      and reply_body == f"{MARKER}\nfollowup: out of scope for this PR, tracked in #500")
check("--thread: the thread is resolved after the reply",
      len(resolves) == 1 and calls().index(replies[0]) < calls().index(resolves[0]))
check("--thread: the result names the thread, replied and resolved",
      out and out.get("thread", {}).get("id") == "PRRT_a" and out["thread"].get("replied") is True
      and out["thread"].get("resolved") is True)
r, out = run(*file_args(extra=["--thread", "PRRT_a"]), fresh=True)
check("--thread retry: the thread is no longer open, no second reply",
      r.returncode == 0 and calls("reply") == [] and calls("resolve") == []
      and out["thread"] == {"id": "PRRT_a", "replied": False, "resolved": False, "reply_url": None})

answered = {"databaseId": 2, "url": "u", "author": {"login": "me"},
            "body": f"{MARKER}\nfollowup: out of scope for this PR, tracked in #500"}
reset_repo(pr_body=PR_BODY + "\n<!-- queue-runner:followups -->\n- #500: t <!-- key=PRRT_b -->\n"
           "<!-- /queue-runner:followups -->\n", threads=[thread("PRRT_b", [answered])])
r, out = run(*file_args(key="PRRT_b", extra=["--thread", "PRRT_b"]))
check("a thread that already has the follow-up reply is only resolved",
      r.returncode == 0 and calls("reply") == [] and len(calls("resolve")) == 1
      and out["thread"]["resolved"] is True and out["thread"]["replied"] is False)

reset_repo(threads=[thread("PRRT_c")])
r, out = run(*file_args(extra=["--thread", "PRRT_c"]), env_extra={"STUB_FAIL": "reply"})
check("a failed thread reply: exit 3, stage reply, the issue number kept for the retry",
      r.returncode == 3 and out and out.get("stage") == "reply" and out.get("issue") == 500)
r, out = run(*file_args(extra=["--thread", "PRRT_c"]), env_extra={"STUB_FAIL": "threads"}, fresh=True)
check("unreadable threads: exit 3, stage threads", r.returncode == 3 and out
      and out.get("stage") == "threads" and out.get("issue") == 500)

# --- --app and list --------------------------------------------------------------------------

print("--- --app and list ---")
reset_repo()
r, out = run(*file_args(extra=["--app"]))
token_log = (STUB / "token.log").read_text() if (STUB / "token.log").exists() else ""
check("--app: every gh call carries the app token, asked for the repo",
      r.returncode == 0 and calls() and all(c["gh_token"] == APP_TOKEN for c in calls())
      and all(l.startswith("--repo owner/repo -- gh api") for l in token_log.splitlines()))
r, out = run("list", "--repo", REPO, "--pr", "42")
check("list: the Follow-ups section as JSON",
      r.returncode == 0 and out == [{"issue": 500, "title": TITLE, "key": "lib/live-checkout.sh:redirect"}])
reset_repo()
r, out = run("list", "--repo", REPO, "--pr", "42")
check("list: [] without a section", r.returncode == 0 and out == [])
r, out = run("list", "--repo", REPO, "--pr", "42", env_extra={"STUB_FAIL": "pr"})
check("list: gh error -> exit 3, stage pr", r.returncode == 3 and out and out.get("stage") == "pr")

# --- usage errors send nothing ------------------------------------------------------------

print("--- usage errors ---")
closing_body = TMP / "closing.md"
closing_body.write_text("This fixes #42 for good.\n")
closing_url = TMP / "closing-url.md"
closing_url.write_text("Resolves: https://github.com/owner/repo/pull/42\n")
empty_body = TMP / "empty.md"
empty_body.write_text("  \n")
for name, args in [("closing keyword in the body file", file_args(body=closing_body)),
                   ("closing keyword before a URL", file_args(body=closing_url)),
                   ("closing keyword in the title", file_args(title="Closes #42 leftovers")),
                   ("cross-repo closing keyword", file_args(title="fixes owner/repo#42")),
                   ("empty body file", file_args(body=empty_body)),
                   ("missing body file", file_args(body=TMP / "none.md")),
                   ("empty title", file_args(title="  ")),
                   ("key with a space", file_args(key="a b")),
                   ("key with a hash", file_args(key="see#42")),
                   ("empty thread", file_args(extra=["--thread", " "])),
                   ("bad --repo", ["list", "--repo", "repo", "--pr", "42"]),
                   ("bad --pr", ["list", "--repo", REPO, "--pr", "0"])]:
    reset_repo()
    r, out = run(*args)
    check(f"{name}: exit 2, nothing sent", r.returncode == 2 and calls() == [])
reset_repo()
r, out = run(*file_args(body=closing_body))
check("the closing-keyword refusal names the non-closing alternative", "non-closing" in r.stderr)

# --- CLI ----------------------------------------------------------------------------------

print("--- CLI ---")
r = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True)
check("--help exits 0", r.returncode == 0)
check("--help documents the markers, idempotency and the exit codes",
      "queue-runner:followups" in r.stdout and "idempotent" in r.stdout and "Exit codes" in r.stdout)
check("--help has no em-dash", "—" not in r.stdout)

tmp.cleanup()

print(f"\nResults: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
