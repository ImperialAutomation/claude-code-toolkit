#!/usr/bin/env python3
"""
Standalone tests for pre-merge-verdict.py.

Run directly: python3 bin/tests/test-pre-merge-verdict.py

Hermetic: every run points PRE_MERGE_FINDINGS_LOG at a temp file, so the real
~/.claude/pre-merge-findings.tsv is never touched.

Covers every row of the verdict mapping (#295): escalation hit, UNVERIFIABLE
AC, runtime FAIL (HUMAN); /code-review finding, /review HIGH/CRITICAL finding,
failing test, NOT MET AC (BLOCKING); only MEDIUM/LOW, nothing (APPROVE); a
review that meets both HUMAN and BLOCKING; approved escalations; and the
measurement log rows.

When adding a case, check it actually constrains the script: break the rule
in pre-merge-verdict.py, confirm THIS test goes red, then revert.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "pre-merge-verdict.py"

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
LOG = TMP / "logs" / "pre-merge-findings.tsv"
HEADER = "date\trepo\tpr_or_branch\tlocation\tshadow_severity\tverdict"


def run(payload, *args, log=LOG, raw=None):
    """Run the helper with payload on stdin; returns (CompletedProcess, parsed stdout)."""
    env = dict(os.environ, PRE_MERGE_FINDINGS_LOG=str(log), HOME=str(TMP / "home"))
    text = raw if raw is not None else json.dumps(payload)
    r = subprocess.run([sys.executable, str(SCRIPT_PATH), *args], env=env, input=text,
                       capture_output=True, text=True)
    try:
        out = json.loads(r.stdout)
    except ValueError:
        out = {}
    return r, out


def base(**sections):
    payload = {"repo": "owner/repo", "pr": 42}
    payload.update(sections)
    return payload


def verdict(payload):
    r, out = run(payload)
    return out.get("verdict") if r.returncode == 0 else f"exit {r.returncode}: {r.stderr.strip()}"


def finding(path="bin/x.sh", line=7, shadow="HIGH", summary="off by one"):
    return {"file": path, "line": line, "summary": summary,
            "failure_scenario": "loop skips the last item", "shadow_severity": shadow}


ESC_HIT = {"category": "interface", "file": "bin/old.sh", "reason": "deleted"}
SCOPE_HIT = {"category": "scope", "file": "-", "reason": "adds a --post flag the issue rules out"}

# --- the mapping, row by row -------------------------------------------------

print("--- HUMAN rows ---")
check("escalation hit (category 1-4) -> HUMAN",
      verdict(base(escalation={"hits": [ESC_HIT], "linked_issues": [{"number": 1, "labels": []}]}))
      == "HUMAN")
check("category 5 (scope) hit -> HUMAN",
      verdict(base(escalation={"hits": [SCOPE_HIT], "linked_issues": []})) == "HUMAN")
check("UNVERIFIABLE AC -> HUMAN",
      verdict(base(acceptance=[{"criterion": "works on prod", "status": "UNVERIFIABLE"},
                               {"criterion": "has tests", "status": "VERIFIED"}])) == "HUMAN")
check("runtime FAIL -> HUMAN",
      verdict(base(runtime=[{"check": "containers", "status": "FAIL", "detail": "db exited"}]))
      == "HUMAN")

print("--- BLOCKING rows ---")
check("any /code-review finding -> BLOCKING, even with LOW shadow severity",
      verdict(base(correctness_findings=[finding(shadow="LOW")])) == "BLOCKING")
check("/review HIGH finding -> BLOCKING",
      verdict(base(review_findings=[{"severity": "HIGH", "finding": "uncaught error",
                                     "location": "a.py:3"}])) == "BLOCKING")
check("/review CRITICAL finding -> BLOCKING",
      verdict(base(review_findings=[{"severity": "CRITICAL", "finding": "secret",
                                     "location": "b.py:1"}])) == "BLOCKING")
check("failing test -> BLOCKING",
      verdict(base(tests={"passed": 9, "failed": 1, "skipped": 0})) == "BLOCKING")
check("NOT MET AC -> BLOCKING",
      verdict(base(acceptance=[{"criterion": "logs rows", "status": "NOT MET"}])) == "BLOCKING")

print("--- APPROVE rows ---")
r, out = run(base(review_findings=[{"severity": "MEDIUM", "finding": "magic number", "location": "c.py:9"},
                                   {"severity": "LOW", "finding": "todo", "location": "c.py:10"},
                                   {"severity": "INFO", "finding": "note", "location": "-"}],
                  runtime=[{"check": "smoke", "status": "WARN"}, {"check": "alembic", "status": "SKIP"}],
                  tests={"passed": 3, "failed": 0, "skipped": 2},
                  acceptance=[{"criterion": "x", "status": "VERIFIED"}]))
check("only MEDIUM/LOW findings, WARN/SKIP runtime, green tests -> APPROVE",
      out.get("verdict") == "APPROVE")
check("MEDIUM/LOW findings are still listed under APPROVE",
      any("magic number" in f for f in out.get("listed_findings", []))
      and any("todo" in f for f in out.get("listed_findings", [])))
check("nothing at all -> APPROVE", verdict(base()) == "APPROVE")
check("empty sections -> APPROVE",
      verdict(base(escalation={"hits": [], "linked_issues": []}, acceptance=[], runtime=[],
                   tests={"passed": 0, "failed": 0, "skipped": 0}, review_findings=[],
                   correctness_findings=[])) == "APPROVE")

print("--- HUMAN beats BLOCKING ---")
r, out = run(base(escalation={"hits": [ESC_HIT], "linked_issues": [{"number": 1, "labels": []}]},
                  correctness_findings=[finding()],
                  tests={"passed": 1, "failed": 2, "skipped": 0},
                  review_findings=[{"severity": "MEDIUM", "finding": "dup code", "location": "d.py:1"}]))
check("HUMAN and BLOCKING conditions together -> HUMAN", out.get("verdict") == "HUMAN")
check("the BLOCKING reasons stay listed under HUMAN",
      any("bin/x.sh:7" in b for b in out.get("blocking_reasons", []))
      and any("2 failed" in b for b in out.get("blocking_reasons", [])))
check("the HUMAN reason names the escalation",
      any("interface" in h and "bin/old.sh" in h for h in out.get("human_reasons", [])))
check("MEDIUM findings listed under HUMAN too",
      any("dup code" in f for f in out.get("listed_findings", [])))

print("--- escalation approvals ---")
r, out = run(base(escalation={"hits": [ESC_HIT],
                              "linked_issues": [{"number": 1, "labels": ["approved:interface", "bug"]},
                                                {"number": 2, "labels": ["approved:interface"]}]}))
check("hit approved on every linked issue -> not HUMAN", out.get("verdict") == "APPROVE")
check("an approved hit is reported as approved",
      any("bin/old.sh" in a for a in out.get("approved_escalations", [])))
check("hit approved on only one of two linked issues -> HUMAN",
      verdict(base(escalation={"hits": [ESC_HIT],
                               "linked_issues": [{"number": 1, "labels": ["approved:interface"]},
                                                 {"number": 2, "labels": []}]})) == "HUMAN")
check("approval for another category does not count",
      verdict(base(escalation={"hits": [ESC_HIT],
                               "linked_issues": [{"number": 1, "labels": ["approved:global"]}]}))
      == "HUMAN")
check("no linked issue: nothing can approve -> HUMAN",
      verdict(base(escalation={"hits": [ESC_HIT], "linked_issues": []})) == "HUMAN")
check("scope (category 5) is never approvable by label",
      verdict(base(escalation={"hits": [SCOPE_HIT],
                               "linked_issues": [{"number": 1, "labels": ["approved:scope"]}]}))
      == "HUMAN")

print("--- shadow severity count ---")
r, out = run(base(correctness_findings=[finding(shadow="HIGH"), finding(line=8, shadow="MEDIUM"),
                                        finding(line=9, shadow="LOW")]))
check("downgrade count: MEDIUM and LOW would have been downgraded",
      out.get("correctness", {}).get("downgraded") == 2 and out.get("correctness", {}).get("total") == 3)
check("report line wording",
      out.get("correctness", {}).get("line") == "2 of 3 correctness findings would have been downgraded")
check("shadow severity never lowers the verdict", out.get("verdict") == "BLOCKING")
check("each correctness finding is listed as BLOCKING with its shadow severity",
      sum("shadow LOW" in b for b in out.get("blocking_reasons", [])) == 1
      and len(out.get("blocking_reasons", [])) == 3)

print("--- measurement log ---")
if LOG.exists():
    LOG.unlink()
r, out = run(base(pr=295, correctness_findings=[finding(path="bin/a.py", line=12, shadow="MEDIUM"),
                                                finding(path="bin/b\tc.py", line=None, shadow="HIGH")]))
rows = LOG.read_text().splitlines() if LOG.exists() else []
check("new log: header first", rows[:1] == [HEADER])
check("one row per /code-review finding", len(rows) == 3)
first = rows[1].split("\t") if len(rows) > 1 else []
check("row fields: repo, PR, file:line, shadow severity, verdict",
      first[1:] == ["owner/repo", "295", "bin/a.py:12", "MEDIUM", "BLOCKING"])
check("row date is a UTC timestamp", len(first) > 0 and first[0].endswith("Z") and "T" in first[0])
second = rows[2].split("\t") if len(rows) > 2 else []
check("a tab in a field cannot add a column; no line gives just the file",
      len(second) == 6 and second[3] == "bin/b c.py")
check("helper output reports the rows written",
      out.get("log", {}).get("rows") == 2 and out.get("log", {}).get("written") is True)

r, out = run(base(branch="issue-295-x", pr=None, correctness_findings=[finding()],
                  escalation={"hits": [SCOPE_HIT], "linked_issues": []}))
rows = LOG.read_text().splitlines()
check("existing log: no second header", rows.count(HEADER) == 1 and len(rows) == 4)
check("without a PR the branch takes its place, verdict of the run logged",
      rows[3].split("\t")[2] == "issue-295-x" and rows[3].split("\t")[5] == "HUMAN")

before = LOG.read_text()
run(base(review_findings=[{"severity": "HIGH", "finding": "h", "location": "a:1"}]))
check("/review findings are not logged", LOG.read_text() == before)

os.chmod(LOG, 0o600)
run(base(correctness_findings=[finding()]))
check("appending keeps the log's file mode", stat.S_IMODE(LOG.stat().st_mode) == 0o600)

blocked = TMP / "not-a-dir"
blocked.write_text("x")
r, out = run(base(correctness_findings=[finding()]), log=blocked / "log.tsv")
check("unwritable log: verdict still printed, exit 0", r.returncode == 0 and out.get("verdict") == "BLOCKING")
check("unwritable log: warning on stderr, written false",
      "warning" in r.stderr and out.get("log", {}).get("written") is False)

r, out = run(base(), "--input", str(TMP / "none.json"))
check("--input of a missing file: exit 2", r.returncode == 2)
payload_file = TMP / "gates.json"
payload_file.write_text(json.dumps(base(tests={"passed": 0, "failed": 1})))
r, out = run(None, "--input", str(payload_file), raw="")
check("--input reads the file instead of stdin", out.get("verdict") == "BLOCKING")

print("--- invalid input fails closed ---")
for name, payload in [
    ("not JSON", None),
    ("top level not an object", []),
    ("unknown top-level key (typo)", base(acceptence=[])),
    ("unknown AC status", base(acceptance=[{"criterion": "x", "status": "UNVERIFIED"}])),
    ("unknown runtime status", base(runtime=[{"check": "x", "status": "BROKEN"}])),
    ("unknown review severity", base(review_findings=[{"severity": "SEVERE", "finding": "x"}])),
    ("correctness finding without shadow severity",
     base(correctness_findings=[{"file": "a", "line": 1, "summary": "s"}])),
    ("correctness finding with an invalid shadow severity",
     base(correctness_findings=[finding(shadow="CRITICAL")])),
    ("correctness finding without file", base(correctness_findings=[{"shadow_severity": "LOW"}])),
    ("negative failed count", base(tests={"passed": 1, "failed": -1})),
    ("escalation hit without category", base(escalation={"hits": [{"file": "x"}]})),
    ("neither pr nor branch", {"repo": "o/r"}),
]:
    r, out = run(payload, raw="{not json" if payload is None else None)
    check(f"{name}: exit 2, no verdict", r.returncode == 2 and "verdict" not in out)

print("--- CLI ---")
r = subprocess.run([sys.executable, str(SCRIPT_PATH), "--help"], capture_output=True, text=True)
check("--help exits 0", r.returncode == 0)
check("--help names the exit codes and the log override",
      "Exit codes" in r.stdout and "PRE_MERGE_FINDINGS_LOG" in r.stdout)

tmp.cleanup()

print(f"\nResults: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
