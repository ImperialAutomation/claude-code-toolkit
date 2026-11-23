#!/usr/bin/env python3
"""
Standalone tests for pr-review-threads.py (review thread replies, #378).

Run directly: python3 bin/tests/test-pr-review-threads.py

Hermetic: `gh` is a stub first on PATH and the token script is a stub named
by PR_THREADS_TOKEN_SCRIPT, so nothing reaches GitHub. The gh stub records
every call (arguments, GH_TOKEN, the GraphQL request of --input) and answers
from fixtures; STUB_FAIL=list|reply|resolve makes that call fail like gh does
on an HTTP error, STUB_GQL_ERROR=reply answers with a GraphQL "errors" list.

Covers: list returns only unresolved threads (outdated included) over every
page; each reply body starts with the queue-runner marker; the outcome texts;
resolve only for fixed; --app goes through the token script; usage errors
send nothing; failures are a JSON result with exit 3.

When adding a case, check it actually constrains the script: break the rule
in pr-review-threads.py, confirm THIS test goes red, then revert.
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent
SCRIPT = BIN / "pr-review-threads.py"
MARKER = "<!-- queue-runner -->"

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
with (stub / "calls.jsonl").open("a") as fh:
    fh.write(json.dumps({"args": args, "gh_token": os.environ.get("GH_TOKEN"), "input": req}) + "\n")
fail = os.environ.get("STUB_FAIL", "")
gql_error = os.environ.get("STUB_GQL_ERROR", "")
if args[:2] != ["api", "graphql"] or req is None:
    print(f"gh stub: unexpected call {args}", file=sys.stderr); sys.exit(1)
q = req["query"]
if "reviewThreads" in q:
    kind = "list"
elif "resolveReviewThread" in q:
    kind = "resolve"
elif "addPullRequestReviewThreadReply" in q:
    kind = "reply"
else:
    kind = "other"
if fail == kind:
    print("gh: Something went wrong (HTTP 502)", file=sys.stderr); sys.exit(1)
if gql_error == kind:
    print(json.dumps({"data": None, "errors": [{"message": "Could not resolve to a node"}]}))
    print("gh: Could not resolve to a node", file=sys.stderr); sys.exit(1)
if kind == "list":
    pages = json.loads((stub / "pages.json").read_text())
    cursor = req["variables"].get("cursor")
    page = pages[0] if cursor is None else pages[int(cursor)]
    print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": page}}}}))
elif kind == "reply":
    print(json.dumps({"data": {"addPullRequestReviewThreadReply": {"comment": {
        "url": "https://github.com/owner/repo/pull/42#discussion_r777"}}}}))
elif kind == "resolve":
    print(json.dumps({"data": {"resolveReviewThread": {"thread": {"id": req["variables"]["thread"],
                                                                  "isResolved": True}}}}))
else:
    print(f"gh stub: unexpected query {q}", file=sys.stderr); sys.exit(1)
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


def thread(tid, resolved=False, outdated=False, line=12, comment_id=101):
    return {"id": tid, "isResolved": resolved, "isOutdated": outdated, "path": "bin/x.sh",
            "line": None if outdated else line, "originalLine": line,
            "comments": {"nodes": [{"databaseId": comment_id, "author": {"login": "review-app[bot]"},
                                    "url": f"https://github.com/owner/repo/pull/42#discussion_r{comment_id}",
                                    "body": "**Correctness**: off by one"}]}}


# Two pages: the stub answers cursor "1" with the second one.
PAGES = [
    {"pageInfo": {"hasNextPage": True, "endCursor": "1"},
     "nodes": [thread("PRRT_open", comment_id=101), thread("PRRT_done", resolved=True, comment_id=102)]},
    {"pageInfo": {"hasNextPage": False, "endCursor": None},
     "nodes": [thread("PRRT_old", outdated=True, comment_id=103)]},
]
(STUB / "pages.json").write_text(json.dumps(PAGES))


def reset_stub():
    for name in ("calls.jsonl", "token.log"):
        (STUB / name).unlink(missing_ok=True)


def calls():
    path = STUB / "calls.jsonl"
    return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []


def of_kind(kind):
    needle = {"list": "reviewThreads", "reply": "addPullRequestReviewThreadReply",
              "resolve": "resolveReviewThread"}[kind]
    return [c for c in calls() if needle in (c["input"] or {}).get("query", "")]


def run(*args, env_extra=None):
    reset_stub()
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    env.update(PATH=f"{STUBBIN}:{env['PATH']}", STUB=str(STUB), HOME=str(TMP / "home"),
               PR_THREADS_TOKEN_SCRIPT=str(TOKEN_SCRIPT))
    env.update(env_extra or {})
    r = subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True)
    try:
        out = json.loads(r.stdout)
    except ValueError:
        out = None
    return r, out


REPLY = ["reply", "--repo", "owner/repo", "--thread", "PRRT_open"]

# --- list -----------------------------------------------------------------------

print("--- list ---")
r, out = run("list", "--repo", "owner/repo", "--pr", "42")
ids = [t["id"] for t in out] if isinstance(out, list) else []
check("list: exit 0", r.returncode == 0)
check("list: only unresolved threads, outdated included, over both pages",
      ids == ["PRRT_open", "PRRT_old"])
check("list: both pages were read (second with the first page's cursor)",
      [c["input"]["variables"].get("cursor") for c in of_kind("list")] == [None, "1"])
check("list: owner, name and PR number are the query variables",
      of_kind("list") and of_kind("list")[0]["input"]["variables"]
      | {"cursor": None} == {"owner": "owner", "name": "repo", "pr": 42, "cursor": None})
first = out[0] if ids else {}
check("list: a thread carries path, line, outdated and its comments with ids and urls",
      first.get("path") == "bin/x.sh" and first.get("line") == 12 and first.get("outdated") is False
      and first.get("comments", [{}])[0].get("id") == 101
      and first["comments"][0].get("url", "").endswith("#discussion_r101")
      and first["comments"][0].get("author") == "review-app[bot]")
check("list: an outdated thread has line null and outdated true",
      len(out or []) == 2 and out[1]["line"] is None and out[1]["outdated"] is True
      and out[1]["original_line"] == 12)
check("list: no mutation sent", of_kind("reply") == [] and of_kind("resolve") == [])
check("list without --app runs gh as the user (no token script)",
      not (STUB / "token.log").exists() and all(c["gh_token"] is None for c in calls()))

r, out = run("list", "--repo", "owner/repo", "--pr", "42", env_extra={"STUB_FAIL": "list"})
check("list: gh error -> exit 3, status failed, stage list",
      r.returncode == 3 and out and out.get("status") == "failed" and out.get("stage") == "list"
      and "HTTP 502" in out.get("error", ""))

# --- reply: fixed ------------------------------------------------------------------

print("--- reply fixed ---")
r, out = run(*REPLY, "fixed", "abc1234")
replies, resolves = of_kind("reply"), of_kind("resolve")
body = replies[0]["input"]["variables"]["body"] if replies else ""
check("fixed: exit 0, status replied", r.returncode == 0 and out and out.get("status") == "replied")
check("fixed: the reply starts with the queue-runner marker line",
      body.startswith(MARKER + "\n"))
check("fixed: the reply says 'fixed in <sha>'", body == f"{MARKER}\nfixed in abc1234")
check("fixed: the reply goes to the named thread",
      replies and replies[0]["input"]["variables"]["thread"] == "PRRT_open")
check("fixed: the thread is resolved, after the reply",
      len(resolves) == 1 and resolves[0]["input"]["variables"]["thread"] == "PRRT_open"
      and calls().index(replies[0]) < calls().index(resolves[0]))
check("fixed: the result says resolved and carries the reply url",
      out and out.get("resolved") is True and out.get("reply_url", "").endswith("discussion_r777")
      and out.get("outcome") == "fixed")

# --- reply: rejected and left --------------------------------------------------------

print("--- reply rejected / left ---")
r, out = run(*REPLY, "rejected", "the", "loop", "never", "reaches", "it")
replies = of_kind("reply")
body = replies[0]["input"]["variables"]["body"] if replies else ""
check("rejected: exit 0, reply with the marker and the reason",
      r.returncode == 0 and body == f"{MARKER}\nrejected: the loop never reaches it")
check("rejected: the thread stays open (no resolve)", of_kind("resolve") == [])
check("rejected: the result says not resolved", out and out.get("resolved") is False)

r, out = run(*REPLY, "left")
replies = of_kind("reply")
body = replies[0]["input"]["variables"]["body"] if replies else ""
check("left: exit 0, reply 'left: see decision card' with the marker",
      r.returncode == 0 and body == f"{MARKER}\nleft: see decision card")
check("left: the thread stays open (no resolve)", of_kind("resolve") == [])

# --- --app ----------------------------------------------------------------------------

print("--- --app ---")
r, out = run(*REPLY, "--app", "fixed", "abc1234")
token_log = (STUB / "token.log").read_text() if (STUB / "token.log").exists() else ""
check("--app: every gh call carries the app token", calls() and all(c["gh_token"] == APP_TOKEN
                                                                    for c in calls()))
check("--app: the token script is asked for the repo",
      token_log and all(l.startswith("--repo owner/repo -- gh api graphql") for l in token_log.splitlines()))

# --- usage errors send nothing ---------------------------------------------------------

print("--- usage errors ---")
for name, args in [("fixed without sha", [*REPLY, "fixed"]),
                   ("fixed with a non-hex sha", [*REPLY, "fixed", "HEAD"]),
                   ("rejected without reason", [*REPLY, "rejected"]),
                   ("left with text", [*REPLY, "left", "why"]),
                   ("unknown outcome", [*REPLY, "resolved"]),
                   ("empty thread", ["reply", "--repo", "owner/repo", "--thread", " ", "left"]),
                   ("bad --repo", ["list", "--repo", "repo", "--pr", "42"]),
                   ("bad --pr", ["list", "--repo", "owner/repo", "--pr", "0"]),
                   ("no subcommand", [])]:
    r, out = run(*args)
    check(f"{name}: exit 2, nothing sent", r.returncode == 2 and calls() == [])

# --- failures ----------------------------------------------------------------------------

print("--- failures ---")
r, out = run(*REPLY, "fixed", "abc1234", env_extra={"STUB_FAIL": "reply"})
check("reply gh error: exit 3, stage reply, reply_posted false, no resolve",
      r.returncode == 3 and out and out.get("stage") == "reply" and out.get("reply_posted") is False
      and of_kind("resolve") == [])

r, out = run(*REPLY, "fixed", "abc1234", env_extra={"STUB_GQL_ERROR": "reply"})
check("reply GraphQL error: exit 3, the GraphQL message is the error",
      r.returncode == 3 and out and out.get("stage") == "reply"
      and "Could not resolve to a node" in out.get("error", ""))

r, out = run(*REPLY, "fixed", "abc1234", env_extra={"STUB_FAIL": "resolve"})
check("resolve error after the reply: exit 3, stage resolve, reply_posted true with its url",
      r.returncode == 3 and out and out.get("stage") == "resolve" and out.get("reply_posted") is True
      and out.get("reply_url", "").endswith("discussion_r777"))

# --- CLI --------------------------------------------------------------------------------

print("--- CLI ---")
r = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True)
check("--help exits 0", r.returncode == 0)
check("--help documents the marker, the outcomes and the exit codes",
      MARKER in r.stdout and "fixed in <sha>" in r.stdout and "left: see decision card" in r.stdout
      and "Exit codes" in r.stdout)

tmp.cleanup()

print(f"\nResults: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
