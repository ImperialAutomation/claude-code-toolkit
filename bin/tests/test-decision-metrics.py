#!/usr/bin/env python3
"""
Standalone tests for decision-metrics.py.

Run directly: python3 bin/tests/test-decision-metrics.py

Hermetic: transcripts are small synthetic fixtures written to a temp dir, and
every `gh` call goes through a stub that serves canned JSON. No real
transcript, issue or PR data is read.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "decision-metrics.py"

spec = importlib.util.spec_from_file_location("decision_metrics", SCRIPT_PATH)
dm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dm)

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


NOW = datetime.now(timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# --- transcript fixtures ------------------------------------------------------


def assistant(ts, blocks):
    return {"type": "assistant", "timestamp": iso(ts), "message": {"role": "assistant", "content": blocks}}


def user(ts, blocks):
    return {"type": "user", "timestamp": iso(ts), "message": {"role": "user", "content": blocks}}


def skill_call(name):
    return {"type": "tool_use", "id": f"sk-{name}", "name": "Skill", "input": {"skill": name}}


def ask(tool_id, questions):
    """questions: list of (question, [labels])."""
    return {
        "type": "tool_use",
        "id": tool_id,
        "name": "AskUserQuestion",
        "input": {
            "questions": [
                {
                    "question": q,
                    "header": "h",
                    "multiSelect": False,
                    "options": [{"label": label, "description": "d"} for label in labels],
                }
                for q, labels in questions
            ]
        },
    }


def answer(tool_id, pairs, prefix="User has answered your questions: "):
    text = prefix + ", ".join(f'"{q}"="{a}"' for q, a in pairs) + ". You can now continue."
    return {"type": "tool_result", "tool_use_id": tool_id, "content": text}


def write_jsonl(path, objs):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(o) for o in objs) + "\n")


FREE_TEXT = "Neither of these, please build a third variant that keeps the old flag working for a while"

tmp = tempfile.TemporaryDirectory()
ROOT = Path(tmp.name) / "projects"
t = NOW - timedelta(days=1)

write_jsonl(
    ROOT / "-proj-a" / "sess1.jsonl",
    [
        assistant(t, [skill_call("refine")]),
        assistant(t, [ask("q1", [("Q1?", ["Alpha (Recommended)", "Beta"])])]),
        user(t, [answer("q1", [("Q1?", "Alpha (Recommended)")])]),
        assistant(t, [ask("q2", [("Q2?", ["Beta", "Gamma (Recommended)"])])]),
        user(t, [answer("q2", [("Q2?", "Beta")])]),
        assistant(t, [ask("q3", [("Q3?", ["Delta (Recommended)", "Eps"])])]),
        user(t, [answer("q3", [("Q3?", FREE_TEXT)])]),
        # No recommended option: not counted.
        assistant(t, [ask("q4", [("Q4?", ["One", "Two"])])]),
        user(t, [answer("q4", [("Q4?", "One")])]),
        # Rejected: no answer, not counted.
        assistant(t, [ask("q6", [("Q6?", ["Yes (Recommended)", "No"])])]),
        user(t, [{"type": "tool_result", "tool_use_id": "q6",
                  "content": "The user doesn't want to proceed with this tool use."}]),
        # A slash command switches the active skill.
        user(t, [{"type": "text", "text": "<command-name>/implement</command-name>"}]),
        assistant(t, [ask("q5", [("Q5a?", ["Up (Recommended)", "Down"]),
                                 ("Q5b?", ["Left", "Right (Recommended)"])])]),
        user(t, [answer("q5", [("Q5a?", "Up (Recommended)"), ("Q5b?", "Left")],
                        prefix="The user answered: ")]),
    ],
)
write_jsonl(
    ROOT / "-proj-b" / "sess2.jsonl",
    [
        assistant(t, [ask("q7", [("Q7?", ["Keep (Recommended)", "Drop"])])]),
        user(t, [answer("q7", [("Q7?", "Keep (Recommended)")])]),
        # Outside the window.
        assistant(NOW - timedelta(days=100), [ask("q8", [("Q8?", ["Old (Recommended)", "X"])])]),
        user(NOW - timedelta(days=100), [answer("q8", [("Q8?", "X")])]),
    ],
)

print("--- agreement report ---")
rep = dm.analyze_agreement(ROOT, days=42)
check("six answered questions with a recommendation", rep["total"] == 6)
check("recommendation class counted", rep["classes"]["recommendation"] == 3)
check("other listed option class counted", rep["classes"]["other_option"] == 2)
check("free-text class counted", rep["classes"]["free_text"] == 1)
check("recommendation listed first counted", rep["recommended_first"] == 4)
check("per-skill: refine", rep["per_skill"]["refine"]["total"] == 3)
check("per-skill: refine free text", rep["per_skill"]["refine"]["free_text"] == 1)
check("per-skill: implement after slash command", rep["per_skill"]["implement"]["total"] == 2)
check("per-skill: unknown when no skill", rep["per_skill"]["unknown"]["recommendation"] == 1)
check("free text listed once", len(rep["free_text"]) == 1)
ft = rep["free_text"][0] if rep["free_text"] else {}
check("free-text excerpt is a prefix of the answer", FREE_TEXT.startswith(ft.get("excerpt", "x").rstrip(".…")))
check("free-text excerpt is short", len(ft.get("excerpt", "")) <= dm.EXCERPT_CHARS + 1)
check("free-text names its skill", ft.get("skill") == "refine")

text = dm.format_agreement(rep, 42)
check("text shows recommendation percentage", "50.0%" in text)
check("text shows other-option percentage", "33.3%" in text)
check("text shows free-text percentage", "16.7%" in text)
check("text shows recommendation-first share", "66.7%" in text)
check("text lists per-skill rows", "refine" in text and "implement" in text and "unknown" in text)

narrowed = dm.analyze_agreement(ROOT, days=42, projects=["-proj-b"])
check("--project narrows to one project", narrowed["total"] == 1)

# --- reversal fixtures --------------------------------------------------------

R = "acme/repo"
T0 = NOW - timedelta(days=30)


def decisions_entry(n, question, status, choice, origin):
    return (
        f"### D{n}: {question}\n"
        f"- **Status:** {status}\n"
        f"- **Origin:** #{origin}, 2026-01-01\n"
        "- **Options:**\n"
        "  | Option | Pros | Cons |\n"
        "  |---|---|---|\n"
        "  | A: a | p | c |\n"
        "- **Recommendation:** A, because.\n"
        f"- **Choice:** {choice}\n"
    )


ISSUES = [
    {
        "number": 10,
        "labels": [{"name": "approved:interface"}],
        "body": "## Context\n\nx\n\n## Decisions\n\n"
        + decisions_entry(1, "Rename?", "active", "A (no HIL: agent default)", 10) + "\n"
        + decisions_entry(2, "Format?", "superseded by D3", "B (no HIL: auto)", 10) + "\n"
        + decisions_entry(3, "Format again?", "active", "A (HIL)", 10),
    },
    {
        "number": 11,
        "labels": [{"name": "needs-human"}],
        "body": "## Decisions\n\n" + decisions_entry(1, "Input?", "active", "A (no HIL: delegated)", 11),
    },
    {
        "number": 12,
        "labels": [],
        "body": "## Decisions\n\n" + decisions_entry(1, "Layout?", "active", "A (no HIL: agent default)", 12),
    },
    {"number": 13, "labels": [], "body": "No decisions here."},
]

AGENT = [{"name": "agent-authored"}]


def pr(number, merged, title, body, labels=(), merge_sha=None, head="x"):
    return {
        "number": number,
        "title": title,
        "body": body,
        "labels": list(labels),
        "mergedAt": iso(merged),
        "mergeCommit": {"oid": merge_sha or f"m{number:0>39}"},
        "headRefName": head,
    }


PRS = [
    pr(20, T0, "Rename things", "Implements #10\n\n## Decisions made\n\n- D1: Rename? → A (no HIL: agent default)\n",
       AGENT, merge_sha="abc1234" + "0" * 33),
    pr(21, T0, "Input handling", "Implements #11", AGENT),
    pr(22, T0 + timedelta(days=3), "fix: handle empty input (#21)", "", ()),
    pr(23, T0 + timedelta(days=20), "fix: late fix for #11", "", ()),
    pr(24, T0 + timedelta(days=2), "fix: unrelated (#11)", "", ()),
    pr(25, T0, "Layout", "Closes #12\n\n## Decisions made\n\n"
       "- D1: Layout? → A (no HIL: agent default)\n\n"
       + decisions_entry(2, "Grid?", "active", "X (no HIL: agent default)", 12),
       AGENT, head="issue-12-layout"),
    pr(26, T0, "Human PR", "Closes #13", ()),
]

FILES = {
    20: (["bin/a.sh"], ["c20" + "0" * 37]),
    21: (["bin/x.sh"], ["c21" + "0" * 37]),
    22: (["bin/x.sh"], []),
    23: (["bin/x.sh"], []),
    24: (["docs/y.md"], []),
    25: (["skills/l.md"], ["c25" + "0" * 37]),
    26: (["bin/h.sh"], ["c26" + "0" * 37]),
}

COMMITS = [
    {"sha": "r1" + "0" * 38, "date": iso(T0 + timedelta(days=40)),
     "message": 'Revert "Rename things"\n\nThis reverts commit abc1234' + "0" * 33 + "."},
    # Revert of a commit from a human PR: not counted.
    {"sha": "r2" + "0" * 38, "date": iso(T0 + timedelta(days=1)),
     "message": 'Revert "Human PR"\n\nThis reverts commit c26' + "0" * 37 + "."},
]
COMMIT_FILES = {}


def make_gh(prs=PRS, commits=COMMITS, commit_files=COMMIT_FILES, calls=None):
    def fake_gh(args):
        if calls is not None:
            calls.append(list(args))
        if args[:2] == ["repo", "view"]:
            return R + "\n"
        if args[:2] == ["issue", "list"]:
            return json.dumps(ISSUES)
        if args[:2] == ["pr", "list"]:
            return json.dumps(prs)
        if args[:2] == ["pr", "view"]:
            files, oids = FILES[int(args[2])]
            return json.dumps({"files": [{"path": f} for f in files],
                               "commits": [{"oid": o} for o in oids]})
        if args[0] == "api" and "--paginate" in args:
            return "\n".join(json.dumps(c) for c in commits) + "\n"
        if args[0] == "api":
            sha = args[1].rsplit("/", 1)[1]
            return json.dumps(commit_files.get(sha, []))
        raise AssertionError(f"unexpected gh call: {args}")
    return fake_gh


print("--- reversal report ---")
calls = []
rev = dm.analyze_reversals([None], gh=make_gh(calls=calls))
check("current repo resolved via gh repo view", ["repo", "view"] in [c[:2] for c in calls])
check("issue list uses the resolved repo", any(c[:2] == ["issue", "list"] and R in c for c in calls))
tot = rev["totals"]
check("five no-HIL entries (HIL skipped, PR one-liner deduplicated)", tot["entries"] == 5)
check("two exact reversals", tot["exact"] == 2)
check("superseded entry is exact", tot["superseded"] == 1)
# Both #10 entries ride on reverted PR #20; D2 is also superseded, and exact
# counts it once.
check("reverted agent-PR commit is exact", tot["reverted"] == 2)
check("reverted marks the active entry", {x["key"]: x for x in rev["entries"]}["10:D1"]["reverted"])
check("follow-up fix only in heuristic column", tot["heuristic"] == 1)
kinds = rev["by_kind"]
check("by kind: agent default entries", kinds["agent default"]["entries"] == 3)
check("by kind: agent default exact", kinds["agent default"]["exact"] == 1)
check("by kind: auto superseded exact", kinds["auto"]["exact"] == 1)
check("by kind: delegated heuristic", kinds["delegated"]["heuristic"] == 1)
check("by kind: delegated not exact", kinds["delegated"]["exact"] == 0)
cats = rev["by_category"]
check("by category: approved:interface", cats.get("interface", {}).get("exact") == 2)
check("by category: needs-human", cats.get("needs-human", {}).get("heuristic") == 1)
check("no category row for unlabeled issues", set(cats) == {"interface", "needs-human"})
pr_only = [e for e in rev["entries"] if e["key"] == "12:D2"]
check("PR-only full entry parsed", len(pr_only) == 1 and pr_only[0]["kind"] == "agent default")

rtext = dm.format_reversals(rev)
check("text has exact and heuristic columns", "exact" in rtext and "heuristic" in rtext)
check("text names FOLLOW_UP_DAYS window", str(dm.FOLLOW_UP_DAYS) in rtext)

check("FOLLOW_UP_DAYS is 14", dm.FOLLOW_UP_DAYS == 14)

# Revert matched through a commit of the PR (not its merge commit), and a
# follow-up fix found as a commit rather than a PR.
commits2 = [
    {"sha": "r3" + "0" * 38, "date": iso(T0 + timedelta(days=5)),
     "message": 'Revert "Layout"\n\nThis reverts commit c25' + "0" * 37 + "."},
    {"sha": "f1" + "0" * 38, "date": iso(T0 + timedelta(days=4)),
     "message": "fix: off-by-one in the rename, refs #20"},
    {"sha": "f2" + "0" * 38, "date": iso(T0 + timedelta(days=4)),
     "message": "fix: something else, refs #20"},
]
calls2 = []
rev2 = dm.analyze_reversals(
    [R],
    gh=make_gh(commits=commits2, commit_files={"f1" + "0" * 38: ["bin/a.sh"], "f2" + "0" * 38: ["z.txt"]},
               calls=calls2),
)
e = {x["key"]: x for x in rev2["entries"]}
check("revert of a PR commit oid marks its entries", e["12:D1"]["reverted"] and e["12:D2"]["reverted"])
check("follow-up commit touching the files is heuristic", e["10:D1"]["heuristic"])
check("follow-up commit not touching the files is ignored",
      [f["ref"] for f in e["10:D1"]["follow_ups"]] == ["commit f1" + "0" * 5])
check("--repo skips gh repo view", ["repo", "view"] not in [c[:2] for c in calls2])

# A merged GitHub "Revert" PR (body "Reverts <repo>#<n>") is exact too, and
# takes the entry out of the heuristic column.
FILES[27] = (["bin/x.sh"], [])
rev3 = dm.analyze_reversals(
    [R],
    gh=make_gh(prs=PRS + [pr(27, T0 + timedelta(days=1), 'Revert "Input handling"', "Reverts acme/repo#21")]),
)
e3 = {x["key"]: x for x in rev3["entries"]}
check("Reverts <repo>#<n> PR marks the entry reverted", e3["11:D1"]["reverted"])
check("an exact entry is not also heuristic", not e3["11:D1"]["heuristic"])

# --- CLI ----------------------------------------------------------------------

print("--- CLI ---")


def run_cli(*args, home):
    env = dict(os.environ, HOME=str(home))
    return subprocess.run([sys.executable, str(SCRIPT_PATH), *args], env=env,
                          capture_output=True, text=True, stdin=subprocess.DEVNULL)


home = Path(tmp.name) / "home"
(home / ".claude").mkdir(parents=True)
(home / ".claude" / "projects").symlink_to(ROOT)

r = run_cli("--help", home=home)
check("--help exits 0", r.returncode == 0)
check("--help names --output", "--output" in r.stdout)

repo = Path(tmp.name) / "somerepo"
repo.mkdir()
subprocess.run(["git", "init", "-q", str(repo)], check=True)
target = repo / "sub" / "out.txt"
r = run_cli("--report", "agreement", "--output", str(target), home=home)
check("--output inside a git work tree is refused", r.returncode != 0)
check("refusal names the reason", "git work tree" in r.stderr)
check("nothing written inside the repo", not target.exists() and not (repo / "sub").exists())

r = run_cli("--report", "agreement", "--output", "/nonexistent-decision-metrics/out.txt", home=home)
check("--output outside the temp dir is refused", r.returncode != 0)

out = Path(tmp.name) / "plain" / "out.txt"
out.parent.mkdir()
r = run_cli("--report", "agreement", "--output", str(out), home=home)
check("--output in a temp dir outside a repo is written", r.returncode == 0 and out.exists())
check("written report has the agreement table", out.exists() and "50.0%" in out.read_text())

r = run_cli("--report", "agreement", "--project=-proj-b", home=home)
check("CLI --project narrows", r.returncode == 0 and "1 question" in r.stdout)

tmp.cleanup()

print(f"\nResults: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
