#!/usr/bin/env python3
"""
Review threads of a PR for the queue runner (#378): list the open ones, and
reply on one with the queue-runner marker, resolving it when it was fixed or
moved to a follow-up issue (#379).

Usage:
  pr-review-threads.py list  --repo <owner/name> --pr <N> [--app]
  pr-review-threads.py reply --repo <owner/name> --thread <id> [--app] fixed <sha>
  pr-review-threads.py reply --repo <owner/name> --thread <id> [--app] rejected <reason>
  pr-review-threads.py reply --repo <owner/name> --thread <id> [--app] left
  pr-review-threads.py reply --repo <owner/name> --thread <id> [--app] followup <#N|issue url>

  --app     run gh under the review GitHub App of the repo's owner
            (gh-app-token.sh; PR_THREADS_TOKEN_SCRIPT overrides the path),
            so the call shows as `<app-name>[bot]`; without it gh runs as the
            logged-in user

list: every unresolved review thread of the PR, outdated ones included, as
one JSON list on stdout:

  [{"id": "PRRT_...", "path": "bin/x.sh", "line": 12, "original_line": 10,
    "outdated": false,
    "comments": [{"id": 123, "author": "login", "url": "...#discussion_r123",
                  "body": "..."}]}]

  "id" is what reply --thread takes. A comment's "id" is the number in a
  `#discussion_r<id>` URL, so a review comment maps to its thread. "line" is
  null on an outdated thread.

reply: one reply on the thread; its body always starts with the line
`<!-- queue-runner -->`, so rework (R3 of skills/queue-run/references/
rework.md) never reads it as review input. The outcome fixes the text:

  fixed <sha>        "fixed in <sha>", then the thread is resolved
  rejected <reason>  "rejected: <reason>", the thread stays open
  left               "left: see decision card", the thread stays open
  followup <#N|url>  "followup: out of scope for this PR, tracked in <#N|url>",
                     then the thread is resolved (#379): the follow-up issue
                     owns the finding now, not the PR. Only an outcome that
                     ends the PR's part resolves (fixed, followup); rejected
                     and left wait for a human, so they stay open

  Result on stdout:
    {"status": "replied", "thread": "...", "outcome": "fixed",
     "reply_url": "...", "resolved": true}

A GitHub failure prints {"status": "failed", "stage": "list|reply|resolve",
"error": "...", "reply_posted": false|true} on stdout ("reply_url" too when
the reply is on the thread but the resolve failed).

Exit codes:
  0  listed, or replied (and resolved for fixed and followup)
  2  usage error (unknown outcome, sha not hex, empty reason, followup
     without an issue, bad --repo or --pr); nothing was sent, stderr says why
  3  a gh or GitHub GraphQL error; see the JSON result
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
TOKEN_SCRIPT_ENV = "PR_THREADS_TOKEN_SCRIPT"
DEFAULT_TOKEN_SCRIPT = BIN_DIR / "gh-app-token.sh"

# The marker every queue-runner comment starts with; rework.md R3 skips it.
MARKER = "<!-- queue-runner -->"

OUTCOME_FIXED = "fixed"
OUTCOME_REJECTED = "rejected"
OUTCOME_LEFT = "left"
OUTCOME_FOLLOWUP = "followup"
OUTCOMES = (OUTCOME_FIXED, OUTCOME_REJECTED, OUTCOME_LEFT, OUTCOME_FOLLOWUP)
# After these the PR no longer owns the finding, so the thread is resolved.
RESOLVING_OUTCOMES = (OUTCOME_FIXED, OUTCOME_FOLLOWUP)
LEFT_TEXT = "left: see decision card"
FOLLOWUP_PREFIX = "followup: out of scope for this PR, tracked in"
# A follow-up issue: "#123" or its GitHub issue URL.
ISSUE_REF = re.compile(r"^(#\d+|https://github\.com/[^/\s]+/[^/\s]+/issues/\d+)$")

STATUS_REPLIED = "replied"
STATUS_FAILED = "failed"
STAGE_LIST = "list"
STAGE_REPLY = "reply"
STAGE_RESOLVE = "resolve"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_FAILED = 3

PAGE_SIZE = 100
ERROR_LINES = 5
SHA = re.compile(r"^[0-9a-f]{7,40}$")

THREADS_QUERY = """
query($owner: String!, $name: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: %d, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line originalLine
          comments(first: %d) {
            nodes { databaseId url body author { login } }
          }
        }
      }
    }
  }
}
""" % (PAGE_SIZE, PAGE_SIZE)

REPLY_MUTATION = """
mutation($thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) {
    comment { url }
  }
}
"""

RESOLVE_MUTATION = """
mutation($thread: ID!) {
  resolveReviewThread(input: {threadId: $thread}) { thread { id isResolved } }
}
"""


class Usage(Exception):
    pass


class ThreadsFailed(Exception):
    def __init__(self, stage, error, reply_url=None):
        super().__init__(error)
        self.stage, self.error, self.reply_url = stage, error, reply_url


# --- reply text ---------------------------------------------------------------------

def marked(text):
    """The body of a queue-runner reply: the marker line, then the text."""
    return f"{MARKER}\n{text.strip()}"


def outcome_text(outcome, value=None):
    """The reply text of a fix-round outcome; raises Usage on a bad value."""
    value = (value or "").strip()
    if outcome == OUTCOME_FIXED:
        if not SHA.match(value):
            raise Usage(f"fixed needs a commit sha (7 to 40 lowercase hex), got {value!r}")
        return f"fixed in {value}"
    if outcome == OUTCOME_REJECTED:
        if not value:
            raise Usage("rejected needs a reason")
        return f"rejected: {value}"
    if outcome == OUTCOME_LEFT:
        if value:
            raise Usage("left takes no text: the question goes on the decision card")
        return LEFT_TEXT
    if outcome == OUTCOME_FOLLOWUP:
        if not ISSUE_REF.match(value):
            raise Usage(f"followup needs the follow-up issue as #N or its issue URL, got {value!r}")
        return f"{FOLLOWUP_PREFIX} {value}"
    raise Usage(f"unknown outcome {outcome!r}; one of {', '.join(OUTCOMES)}")


# --- GraphQL ------------------------------------------------------------------------

def graphql(run, stage, query, variables):
    """Send one GraphQL request through run(stage, payload) -> stdout; returns its data."""
    try:
        answer = json.loads(run(stage, {"query": query, "variables": variables}))
    except ValueError as exc:
        raise ThreadsFailed(stage, f"unreadable GraphQL answer: {exc}")
    if not isinstance(answer, dict):
        raise ThreadsFailed(stage, "unreadable GraphQL answer: not an object")
    if answer.get("errors"):
        messages = [str(e.get("message", e)) for e in answer["errors"] if isinstance(e, dict)]
        raise ThreadsFailed(stage, " | ".join(messages) or "GraphQL error")
    return answer.get("data") or {}


def list_open_threads(run, repo, pr):
    """Every unresolved review thread of the PR, in the list shape of --help."""
    owner, name = repo.split("/", 1)
    threads, cursor = [], None
    while True:
        data = graphql(run, STAGE_LIST, THREADS_QUERY,
                       {"owner": owner, "name": name, "pr": pr, "cursor": cursor})
        pull = ((data.get("repository") or {}).get("pullRequest"))
        if pull is None:
            raise ThreadsFailed(STAGE_LIST, f"no pull request #{pr} in {repo}")
        page = pull["reviewThreads"]
        for node in page["nodes"]:
            if node.get("isResolved"):
                continue
            threads.append({
                "id": node["id"], "path": node.get("path"), "line": node.get("line"),
                "original_line": node.get("originalLine"), "outdated": bool(node.get("isOutdated")),
                "comments": [{"id": c.get("databaseId"),
                              "author": (c.get("author") or {}).get("login"),
                              "url": c.get("url"), "body": c.get("body", "")}
                             for c in node["comments"]["nodes"]],
            })
        info = page["pageInfo"]
        if not info.get("hasNextPage"):
            return threads
        cursor = info["endCursor"]


def reply(run, thread, text, resolve=False):
    """Reply on a thread with the marker; resolve it after when asked."""
    data = graphql(run, STAGE_REPLY, REPLY_MUTATION, {"thread": thread, "body": marked(text)})
    url = (((data.get("addPullRequestReviewThreadReply") or {}).get("comment")) or {}).get("url", "")
    if resolve:
        try:
            graphql(run, STAGE_RESOLVE, RESOLVE_MUTATION, {"thread": thread})
        except ThreadsFailed as exc:
            exc.reply_url = url
            raise
    return {"thread": thread, "reply_url": url, "resolved": resolve}


# --- gh -----------------------------------------------------------------------------

def gh_runner(repo, app):
    """run(stage, payload) -> stdout of `gh api graphql`, under the app token when app."""
    def run(stage, payload):
        with tempfile.TemporaryDirectory(prefix="pr-review-threads.") as work:
            body = Path(work) / "request.json"
            body.write_text(json.dumps(payload), encoding="utf-8")
            cmd = ["gh", "api", "graphql", "--input", str(body)]
            if app:
                token_script = os.environ.get(TOKEN_SCRIPT_ENV) or str(DEFAULT_TOKEN_SCRIPT)
                cmd = [token_script, "--repo", repo, "--", *cmd]
            try:
                r = subprocess.run(cmd, capture_output=True, text=True)
            except OSError as exc:
                raise ThreadsFailed(stage, f"cannot run {cmd[0]}: {exc}")
        if r.returncode != 0:
            # gh exits non-zero on a GraphQL error and prints the answer on
            # stdout; graphql() reads the error messages from it.
            if r.stdout.strip().startswith("{"):
                return r.stdout
            lines = [l for l in r.stderr.splitlines() if l.strip()]
            raise ThreadsFailed(stage, " | ".join(lines[-ERROR_LINES:])
                                or f"exit {r.returncode}, no message")
        return r.stdout
    return run


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


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_list = sub.add_parser("list", help="the unresolved review threads of a PR")
    p_list.add_argument("--repo", required=True, type=repo_arg)
    p_list.add_argument("--pr", required=True, type=pr_arg)
    p_list.add_argument("--app", action="store_true")
    p_reply = sub.add_parser("reply", help="reply on a thread with the queue-runner marker")
    p_reply.add_argument("--repo", required=True, type=repo_arg)
    p_reply.add_argument("--thread", required=True)
    p_reply.add_argument("--app", action="store_true")
    p_reply.add_argument("outcome", choices=OUTCOMES)
    p_reply.add_argument("value", nargs="*", help="the sha (fixed), the reason (rejected) or the issue (followup)")
    args = parser.parse_args(argv)

    run = gh_runner(args.repo, args.app)
    try:
        if args.command == "list":
            print(json.dumps(list_open_threads(run, args.repo, args.pr), indent=2))
            return EXIT_OK
        if not args.thread.strip():
            raise Usage("--thread must not be empty")
        text = outcome_text(args.outcome, " ".join(args.value))
        result = reply(run, args.thread, text, resolve=args.outcome in RESOLVING_OUTCOMES)
    except Usage as exc:
        print(f"pr-review-threads: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except ThreadsFailed as exc:
        out = {"status": STATUS_FAILED, "stage": exc.stage, "error": exc.error,
               "reply_posted": exc.reply_url is not None}
        if exc.reply_url is not None:
            out["reply_url"] = exc.reply_url
        print(json.dumps(out, indent=2))
        return EXIT_FAILED
    print(json.dumps({"status": STATUS_REPLIED, "outcome": args.outcome, **result}, indent=2))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
