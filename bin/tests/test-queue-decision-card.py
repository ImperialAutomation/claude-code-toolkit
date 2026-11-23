#!/usr/bin/env python3
"""
Standalone tests for queue-decision-card.py (decision card per PR, #376).

Run directly: python3 bin/tests/test-queue-decision-card.py

Hermetic: `gh` is a stub first on PATH, so nothing reaches GitHub. The stub
keeps the PR comments in a JSON file per PR, so a POST adds one and a PATCH
edits one, and a second post can be checked against the first. It records
every call; STUB_FAIL=comments|create|update|issues|prs makes that call fail
like gh does on an HTTP error.

Covers: the card render (markers, numbered questions, lettered options,
recommendation, answer line, data block); upsert creates when absent, edits
when present and never creates a second card, also across rounds; a quoted
card in a human reply is not the card; the derived question for BLOCKING
with rejected findings; the `go` fallback; the "Waiting on you" block rows and
counts; the handback rows and the answer check (#377); usage errors send nothing; failures exit 3 with a JSON result.

When adding a case, check it actually constrains the script: break the rule
in queue-decision-card.py, confirm THIS test goes red, then revert.
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent
SCRIPT = BIN / "queue-decision-card.py"
MARKER = "<!-- queue-runner -->"
CARD_MARKER = "<!-- queue-runner:decisions -->"
DATA_PREFIX = "<!-- queue-runner:decisions-data "
REPO = "owner/repo"

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

GH_STUB = r'''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
stub = Path(os.environ["STUB"])
args = sys.argv[1:]
req = json.loads(Path(args[args.index("--input") + 1]).read_text()) if "--input" in args else None
with (stub / "calls.jsonl").open("a") as fh:
    fh.write(json.dumps({"args": args, "input": req}) + "\n")
fail = os.environ.get("STUB_FAIL", "")
def die(kind):
    if fail == kind:
        print("gh: Something went wrong (HTTP 502)", file=sys.stderr); sys.exit(1)
def comments_file(pr):
    return stub / f"comments-{pr}.json"
def load(pr):
    f = comments_file(pr)
    return json.loads(f.read_text()) if f.exists() else []
def html(pr, cid):
    return f"https://github.com/owner/repo/pull/{pr}#issuecomment-{cid}"
if args[:2] == ["pr", "list"]:
    die("prs")
    print((stub / "prs.json").read_text() if (stub / "prs.json").exists() else "[]")
    sys.exit(0)
if args[:1] != ["api"]:
    print(f"gh stub: unexpected call {args}", file=sys.stderr); sys.exit(1)
path = [a for a in args[1:] if a.startswith("repos/")][0]
method = args[args.index("-X") + 1] if "-X" in args else "GET"
m = re.match(r"repos/owner/repo/issues/(\d+)/comments", path)
if m and method == "GET":
    die("comments")
    items = load(m.group(1))
    # Two pages, as gh --paginate prints them: concatenated arrays.
    half = len(items) // 2
    print(json.dumps(items[:half])); print(json.dumps(items[half:]))
elif m and method == "POST":
    die("create")
    pr = m.group(1)
    items = load(pr)
    counter = stub / "next-id"
    cid = int(counter.read_text()) if counter.exists() else 1000
    counter.write_text(str(cid + 1))
    item = {"id": cid, "html_url": html(pr, cid), "body": req["body"],
            "user": {"login": "jan"}}
    items.append(item)
    comments_file(pr).write_text(json.dumps(items))
    print(json.dumps(item))
elif method == "PATCH":
    die("update")
    cid = int(re.match(r"repos/owner/repo/issues/comments/(\d+)", path).group(1))
    for f in stub.glob("comments-*.json"):
        items = json.loads(f.read_text())
        for item in items:
            if item["id"] == cid:
                item["body"] = req["body"]
                f.write_text(json.dumps(items))
                print(json.dumps(item)); sys.exit(0)
    print("gh: Not Found (HTTP 404)", file=sys.stderr); sys.exit(1)
elif path.startswith("repos/owner/repo/issues?"):
    die("issues")
    print((stub / "issues.json").read_text() if (stub / "issues.json").exists() else "[]")
else:
    print(f"gh stub: unexpected api call {args}", file=sys.stderr); sys.exit(1)
'''

(STUBBIN / "gh").write_text(GH_STUB)
(STUBBIN / "gh").chmod(0o755)


def reset_stub():
    for f in STUB.iterdir():
        f.unlink()


def calls():
    path = STUB / "calls.jsonl"
    return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []


def of_method(method):
    return [c for c in calls() if c["args"][:1] == ["api"]
            and (c["args"][c["args"].index("-X") + 1] if "-X" in c["args"] else "GET") == method]


def comments(pr=42):
    f = STUB / f"comments-{pr}.json"
    return json.loads(f.read_text()) if f.exists() else []


def cards(pr=42):
    return [c for c in comments(pr) if c["body"].startswith(f"{MARKER}\n{CARD_MARKER}")]


def write_json(name, data):
    path = TMP / name
    path.write_text(json.dumps(data))
    return str(path)


def data_block(body):
    for line in body.splitlines():
        if line.startswith(DATA_PREFIX) and line.endswith(" -->"):
            return json.loads(line[len(DATA_PREFIX):-len(" -->")])
    return None


def run(*args, env_extra=None, keep=False):
    if not keep:
        reset_stub()
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    env.update(PATH=f"{STUBBIN}:{env['PATH']}", STUB=str(STUB), HOME=str(TMP / "home"))
    env.update(env_extra or {})
    r = subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True)
    try:
        out = json.loads(r.stdout)
    except ValueError:
        out = None
    return r, out


REVIEW_URL = "https://github.com/owner/repo/pull/42#pullrequestreview-9"
HUMAN_INPUT = {
    "reason": "first review HUMAN",
    "review_url": REVIEW_URL,
    "questions": [
        {"question": "Change the public flag name?",
         "options": ["A: keep --foo", "B: rename to --bar"], "recommendation": "B: callers are new"},
        {"question": "Scope: also update the docs site?",
         "options": ["yes, in this PR", "no, follow-up issue", "drop it"],
         "recommendation": "no, follow-up issue"},
    ],
}

# --- render ---------------------------------------------------------------------------

print("--- render ---")
r, _ = run("render", "--input", write_json("human.json", HUMAN_INPUT))
body = r.stdout
lines = body.splitlines()
check("render: exit 0, no gh call", r.returncode == 0 and calls() == [])
check("render: first line is the queue-runner marker, second the card marker",
      lines[:2] == [MARKER, CARD_MARKER])
check("render: numbered questions", "### 1. Change the public flag name?" in body
      and "### 2. Scope: also update the docs site?" in body)
check("render: options are re-lettered without a doubled prefix",
      "- **A**: keep --foo" in body and "- **B**: rename to --bar" in body
      and "A: A:" not in body and "**A**: A:" not in body)
check("render: plain options get letters A, B, C",
      "- **A**: yes, in this PR" in body and "- **C**: drop it" in body)
check("render: the recommended option is marked (letter prefix and full text match)",
      "- **B**: rename to --bar (recommended)" in body
      and "- **B**: no, follow-up issue (recommended)" in body)
check("render: the recommendation line per question",
      "Recommendation: B: callers are new" in body and "Recommendation: no, follow-up issue" in body)
check("render: the answer line, example from the recommendations",
      "reply on this PR with the number and letter of your choice per question, e.g. `1B 2B`" in body)
check("render: links the review and says why", REVIEW_URL in body and "first review HUMAN" in body)
data = data_block(body)
check("render: machine-readable data block",
      data == {"version": 1, "answer": "choices",
               "questions": [{"n": 1, "options": ["A", "B"], "recommendation": "B"},
                             {"n": 2, "options": ["A", "B", "C"], "recommendation": "B"}]})
check("render: no em-dash in the card", "—" not in body)

r, _ = run("render", "--input", write_json("unknown-rec.json", {
    "reason": "x", "questions": [{"question": "Q?", "options": ["one", "two"],
                                  "recommendation": "depends on the budget"}]}))
data = data_block(r.stdout)
check("render: a recommendation that names no option has no letter, no marked option",
      r.returncode == 0 and data and data["questions"][0]["recommendation"] is None
      and "(recommended)" not in r.stdout and "e.g. `1A`" in r.stdout)

# --- BLOCKING: derived question and go fallback ---------------------------------------

print("--- BLOCKING ---")
r, _ = run("render", "--input", write_json("blocking-go.json", {
    "reason": "re-review BLOCKING", "review_url": REVIEW_URL,
    "blocking": ["correctness bin/x.sh:12: off by one (shadow HIGH)"]}))
body = r.stdout
check("go: BLOCKING without question or rejected finding needs no decision",
      r.returncode == 0 and "no decision needed; reply `go` to start a rework round" in body
      and "### 1." not in body)
check("go: the blocking reasons are listed", "correctness bin/x.sh:12: off by one" in body)
check("go: data block says answer go, no questions",
      data_block(body) == {"version": 1, "answer": "go", "questions": []})

r, _ = run("render", "--input", write_json("blocking-rejected.json", {
    "reason": "re-review BLOCKING", "review_url": REVIEW_URL,
    "blocking": ["review HIGH: unquoted path (bin/x.sh:3)"],
    "rejected": ["unquoted path: the value is a constant"]}))
body = r.stdout
data = data_block(body)
check("derived: BLOCKING with a rejected finding derives one question",
      r.returncode == 0 and "### 1." in body and data and data["answer"] == "choices"
      and len(data["questions"]) == 1 and data["questions"][0]["options"] == ["A", "B"])
check("derived: the question names the rejected finding and the blocking reason",
      "unquoted path: the value is a constant" in body and "review HIGH: unquoted path" in body)
check("derived: it recommends the review side (A)", data and data["questions"][0]["recommendation"] == "A"
      and "e.g. `1A`" in body)

gates = {"repo": REPO, "pr": 42, "tests": {"passed": 3, "failed": 1},
         "review_findings": [{"severity": "LOW", "finding": "nit", "location": "a.sh:1"}]}
r, _ = run("render", "--input", write_json("reason-only.json", {"reason": "re-review BLOCKING"}),
           "--gates", write_json("gates.json", gates))
check("--gates: blocking reasons come from pre-merge-verdict.py, listed findings do not",
      r.returncode == 0 and "tests: 1 failed" in r.stdout and "nit" not in r.stdout)

human_file = write_json("pre-merge-human.json", HUMAN_INPUT["questions"][:1])
r, _ = run("render", "--input", write_json("left.json", {
    "reason": "rework: left finding",
    "questions": [{"question": "Split the helper?", "options": ["A: yes", "B: no"],
                   "recommendation": "A"}]}), "--human", human_file)
data = data_block(r.stdout)
check("--human: the pre-merge decisions file adds its questions after the input's",
      r.returncode == 0 and data and len(data["questions"]) == 2
      and "### 1. Split the helper?" in r.stdout and "### 2. Change the public flag name?" in r.stdout)

# --- post: create, update, never a second card -----------------------------------------

print("--- post ---")
POST = ["post", "--repo", REPO, "--pr", "42"]
reset_stub()
(STUB / "comments-42.json").write_text(json.dumps([
    {"id": 1, "html_url": "u1", "body": "LGTM", "user": {"login": "jan"}},
    {"id": 2, "html_url": "u2", "body": f"> {MARKER}\n> {CARD_MARKER}\n1A", "user": {"login": "jan"}},
]))
r, out = run(*POST, "--input", write_json("human.json", HUMAN_INPUT), keep=True)
check("post: no card yet -> exit 0, status created", r.returncode == 0 and out
      and out.get("status") == "created")
check("post: exactly one POST, no PATCH", len(of_method("POST")) == 1 and of_method("PATCH") == [])
check("post: a quoted card in a reply is not taken for the card", len(cards()) == 1
      and comments()[1]["body"].startswith("> "))
check("post: the result carries the card url, the question count and the answer kind",
      out and out.get("card_url", "").endswith("#issuecomment-1000") and out.get("questions") == 2
      and out.get("answer") == "choices")
check("post: the posted body is the rendered card",
      cards() and data_block(cards()[0]["body"])["questions"][0]["n"] == 1)

r, out = run(*POST, "--input", write_json("blocking-go.json", {
    "reason": "re-review BLOCKING", "blocking": ["tests: 1 failed"]}), keep=True)
check("post again: status updated, same comment", r.returncode == 0 and out
      and out.get("status") == "updated" and out.get("card_url", "").endswith("#issuecomment-1000"))
check("post again: a PATCH, no new POST", len(of_method("PATCH")) == 1 and len(of_method("POST")) == 1)
check("post again: still exactly one card, now the new content",
      len(cards()) == 1 and "reply `go`" in cards()[0]["body"]
      and data_block(cards()[0]["body"])["answer"] == "go")
check("post again: PATCH goes to the card's comment id",
      of_method("PATCH") and "repos/owner/repo/issues/comments/1000" in of_method("PATCH")[0]["args"])

r, out = run(*POST, "--input", write_json("human.json", HUMAN_INPUT), keep=True)
check("third round: still one card, one POST in total", len(cards()) == 1
      and len(of_method("POST")) == 1 and out and out.get("status") == "updated")

# Two cards (should never happen): edit the oldest, never add a third.
reset_stub()
first = f"{MARKER}\n{CARD_MARKER}\nold"
(STUB / "comments-42.json").write_text(json.dumps([
    {"id": 5, "html_url": "c5", "body": first, "user": {"login": "jan"}},
    {"id": 6, "html_url": "c6", "body": first, "user": {"login": "jan"}},
]))
r, out = run(*POST, "--input", write_json("human.json", HUMAN_INPUT), keep=True)
check("two cards: the oldest is edited, nothing is created, duplicates reported",
      r.returncode == 0 and out and out.get("status") == "updated" and out.get("card_url") == "c5"
      and out.get("duplicates") == 1 and of_method("POST") == [])

# --- post failures ---------------------------------------------------------------------

print("--- post failures ---")
for kind, stage in (("comments", "comments"), ("create", "create")):
    r, out = run(*POST, "--input", write_json("human.json", HUMAN_INPUT),
                 env_extra={"STUB_FAIL": kind})
    check(f"{kind} error: exit 3, status failed, stage {stage}",
          r.returncode == 3 and out and out.get("status") == "failed" and out.get("stage") == stage
          and "HTTP 502" in out.get("error", ""))
r, out = run(*POST, "--input", write_json("human.json", HUMAN_INPUT), env_extra={"STUB_FAIL": "comments"})
check("comments error: nothing is created (no blind POST)", of_method("POST") == [])

reset_stub()
(STUB / "comments-42.json").write_text(json.dumps([
    {"id": 5, "html_url": "c5", "body": f"{MARKER}\n{CARD_MARKER}\nold", "user": {"login": "jan"}}]))
r, out = run(*POST, "--input", write_json("human.json", HUMAN_INPUT),
             env_extra={"STUB_FAIL": "update"}, keep=True)
check("update error: exit 3, stage update, no second card created",
      r.returncode == 3 and out and out.get("stage") == "update" and of_method("POST") == [])

# --- waiting ---------------------------------------------------------------------------

print("--- waiting ---")
reset_stub()
(STUB / "issues.json").write_text(json.dumps([
    {"number": 17}, {"number": 20}, {"number": 22},
    {"number": 50, "pull_request": {"url": "x"}},          # a PR, not an issue
    {"number": 30},                                        # no open PR
]))
(STUB / "prs.json").write_text(json.dumps([
    {"number": 42, "url": "https://github.com/owner/repo/pull/42",
     "closingIssuesReferences": [{"number": 17}]},
    {"number": 45, "url": "https://github.com/owner/repo/pull/45",
     "closingIssuesReferences": [{"number": 20}]},
    {"number": 47, "url": "https://github.com/owner/repo/pull/47",
     "closingIssuesReferences": [{"number": 22}]},
    {"number": 48, "url": "https://github.com/owner/repo/pull/48",
     "closingIssuesReferences": [{"number": 99}]},         # issue not waiting
]))
r, _ = run("post", "--repo", REPO, "--pr", "42", "--input", write_json("human.json", HUMAN_INPUT),
           keep=True)
r, _ = run("post", "--repo", REPO, "--pr", "45", "--input", write_json("go.json", {
    "reason": "review not posted"}), keep=True)
(STUB / "calls.jsonl").unlink(missing_ok=True)
r, out = run("waiting", "--repo", REPO, "--json", keep=True)
rows = out if isinstance(out, list) else []
check("waiting --json: exit 0, one row per waiting PR, in PR order",
      r.returncode == 0 and [row["pr"] for row in rows] == [42, 45, 47])
check("waiting --json: question count from the card, card url, issue",
      rows and rows[0]["questions"] == 2 and rows[0]["answer"] == "choices"
      and rows[0]["card_url"].endswith("#issuecomment-1000") and rows[0]["issues"] == [17])
check("waiting --json: a go card counts 0 questions",
      len(rows) > 1 and rows[1]["questions"] == 0 and rows[1]["answer"] == "go")
check("waiting --json: a waiting PR without card has card_url null",
      len(rows) > 2 and rows[2]["card_url"] is None and rows[2]["questions"] is None)
check("waiting: comments read only for the waiting PRs",
      sorted(c["args"][-1] for c in of_method("GET") if "/comments" in c["args"][-1])
      == [f"repos/owner/repo/issues/{n}/comments?per_page=100" for n in (42, 45, 47)])
check("waiting: the issue list asks for needs-human and agent-pr together",
      any("labels=needs-human,agent-pr" in a for c in of_method("GET") for a in c["args"]))

r, _ = run("waiting", "--repo", REPO, keep=True)
text = r.stdout
check("waiting text: heading with the PR count", text.startswith("Waiting on you (3 PRs):"))
check("waiting text: a row with the question count and the card link",
      "- PR #42 (issue #17): 2 questions, decision card https://github.com/owner/repo/pull/42#issuecomment-1000"
      in text)
check("waiting text: a go row", "- PR #45 (issue #20): no decision needed, reply `go`, decision card " in text)
check("waiting text: a row without card links the PR",
      "- PR #47 (issue #22): no decision card, https://github.com/owner/repo/pull/47" in text)
check("waiting text: no em-dash", "—" not in text)

reset_stub()
r, out = run("waiting", "--repo", REPO, keep=True)
check("waiting: nothing waiting -> exit 0, no output", r.returncode == 0 and r.stdout == "")
r, out = run("waiting", "--repo", REPO, "--json", keep=True)
check("waiting --json: nothing waiting -> []", r.returncode == 0 and out == [])

for kind in ("issues", "prs"):
    reset_stub()
    (STUB / "issues.json").write_text(json.dumps([{"number": 17}]))
    r, out = run("waiting", "--repo", REPO, env_extra={"STUB_FAIL": kind}, keep=True)
    check(f"waiting: {kind} error -> exit 3, stage {kind}",
          r.returncode == 3 and out and out.get("status") == "failed" and out.get("stage") == kind)

# --- handback (#377) -------------------------------------------------------------------

print("--- handback ---")
CARD_DATA = {"version": 1, "answer": "choices",
             "questions": [{"n": 1, "options": ["A", "B"], "recommendation": "A"},
                           {"n": 2, "options": ["A", "B", "C"], "recommendation": None}]}
CARD_BODY = f"{MARKER}\n{CARD_MARKER}\n## card\n{DATA_PREFIX}{json.dumps(CARD_DATA)} -->"


def handback_fixture(reply, issue_comments=()):
    reset_stub()
    (STUB / "issues.json").write_text(json.dumps([
        {"number": 17, "labels": [{"name": "agent-pr"}, {"name": "needs-human"}]},
        {"number": 18, "labels": [{"name": "agent-pr"}, {"name": "agent-wip"}]},
    ]))
    (STUB / "prs.json").write_text(json.dumps([
        {"number": 42, "url": "https://github.com/owner/repo/pull/42", "labels": [],
         "closingIssuesReferences": [{"number": 17}]},
        {"number": 43, "url": "https://github.com/owner/repo/pull/43",
         "labels": [{"name": "agent-rework"}], "closingIssuesReferences": [{"number": 18}]},
    ]))
    (STUB / "comments-42.json").write_text(json.dumps([
        {"id": 1, "html_url": "c1", "body": CARD_BODY, "user": {"login": "jan", "type": "User"},
         "created_at": "2026-01-01T10:00:00Z", "updated_at": "2026-01-02T10:00:00Z"},
        {"id": 2, "html_url": "c2", "body": reply, "user": {"login": "jan", "type": "User"},
         "created_at": "2026-01-03T10:00:00Z", "updated_at": "2026-01-03T10:00:00Z"},
    ]))
    (STUB / "comments-17.json").write_text(json.dumps(list(issue_comments)))
    return run("handback", "--repo", REPO, keep=True)


r, out = handback_fixture("`1b 2C`\nthanks")
check("handback: exit 0, one reply row for PR 42 (PR 43's issue is claimed)",
      r.returncode == 0 and isinstance(out, list) and [row["pr"] for row in out] == [42])
check("handback: the row names the trigger, the issue and the reply",
      out and out[0]["trigger"] == "reply" and out[0]["issues"] == [17]
      and out[0]["reply_url"] == "c2" and out[0]["reply"].startswith("`1b 2C`"))
check("handback: the first line in backticks, any case, is a valid answer",
      out and out[0]["answer_problem"] is None)
for reply, problem in (("2A", "no answer to question 1"), ("1A 1B 2A", "question 1 answered twice"),
                       ("1C 2A", "question 1 has no option C"), ("sure", "'sure' is not <number><letter>")):
    r, out = handback_fixture(reply)
    check(f"handback: '{reply}' -> {problem}", out and out[0]["answer_problem"] == problem)
r, out = handback_fixture("1A 2B", [{"id": 9, "body": f"{MARKER}\nfailed", "user": {"type": "User"},
                                      "created_at": "2026-01-04T10:00:00Z"}])
check("handback: a later marker comment on the issue answered the reply already",
      r.returncode == 0 and out == [])
reset_stub()
(STUB / "issues.json").write_text(json.dumps([{"number": 17, "labels": [{"name": "agent-pr"}]}]))
r, out = run("handback", "--repo", REPO, env_extra={"STUB_FAIL": "prs"}, keep=True)
check("handback: prs error -> exit 3, stage prs",
      r.returncode == 3 and out and out.get("stage") == "prs")

# --- usage errors ----------------------------------------------------------------------

print("--- usage errors ---")
for name, data in [("no reason", {"questions": []}),
                   ("one option", {"reason": "x", "questions": [
                       {"question": "Q?", "options": ["only"], "recommendation": "only"}]}),
                   ("empty question", {"reason": "x", "questions": [
                       {"question": " ", "options": ["a", "b"], "recommendation": "a"}]}),
                   ("blocking not strings", {"reason": "x", "blocking": [1]}),
                   ("unknown key", {"reason": "x", "question": []})]:
    r, out = run(*POST, "--input", write_json("bad.json", data))
    check(f"{name}: exit 2, nothing sent", r.returncode == 2 and calls() == [])
for name, args in [("bad --repo", ["post", "--repo", "repo", "--pr", "42", "--input", "x"]),
                   ("bad --pr", ["post", "--repo", REPO, "--pr", "0", "--input", "x"]),
                   ("missing input file", [*POST, "--input", str(TMP / "nope.json")]),
                   ("no subcommand", [])]:
    r, out = run(*args)
    check(f"{name}: exit 2, nothing sent", r.returncode == 2 and calls() == [])

# --- CLI -------------------------------------------------------------------------------

print("--- CLI ---")
r = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True)
check("--help exits 0", r.returncode == 0)
check("--help documents the markers, the answer format and the exit codes",
      CARD_MARKER in r.stdout and "1A 2C" in r.stdout and "go" in r.stdout and "Exit codes" in r.stdout)

tmp.cleanup()

print(f"\nResults: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
