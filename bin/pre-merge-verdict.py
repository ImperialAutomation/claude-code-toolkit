#!/usr/bin/env python3
"""
The /pre-merge verdict: one fixed mapping from gate results to APPROVE,
BLOCKING or HUMAN, plus the shadow-severity measurement log (#295).

Usage:
  pre-merge-verdict.py [--input <file>]

Reads one JSON object from <file> (default: stdin), prints one JSON object on
stdout. /pre-merge calls it after its gates; /pre-merge --post reuses it, so
the rules live here and nowhere else.

Input (every section is optional; an absent section counts as empty; an
unknown top-level key is an error, so a typo cannot drop a gate):

  {
    "repo": "owner/name",
    "pr": 295,                         # or null; then "branch" is required
    "branch": "issue-295-...",
    "escalation": {
      "hits": [{"category": "interface", "file": "bin/x.sh", "reason": "..."}],
      "linked_issues": [{"number": 295, "labels": ["approved:interface"]}]
    },
    "acceptance": [{"criterion": "...", "status": "VERIFIED|NOT MET|UNVERIFIABLE"}],
    "runtime": [{"check": "...", "status": "PASS|WARN|FAIL|SKIP", "detail": "..."}],
    "tests": {"passed": 10, "failed": 0, "skipped": 0},
    "review_findings": [{"severity": "CRITICAL|HIGH|MEDIUM|LOW|INFO",
                         "finding": "...", "location": "file:line"}],
    "correctness_findings": [{"file": "...", "line": 12, "summary": "...",
                              "failure_scenario": "...",
                              "shadow_severity": "HIGH|MEDIUM|LOW"}]
  }

escalation.hits are the lines of escalation-check.sh (categories 1 to 4,
keys permissions, leakage, interface, global) plus category 5 as "scope". A
hit is approved, and does not escalate, when there is at least one linked
issue and every linked issue carries `approved:<category>`. Scope is never
approved by a label.

Mapping, top to bottom; HUMAN wins over BLOCKING, whose reasons stay listed:

  HUMAN     an unapproved escalation hit, an UNVERIFIABLE AC, a runtime FAIL
  BLOCKING  any /code-review finding (each counts as HIGH, whatever its shadow
            severity), a /review CRITICAL or HIGH finding, a failed test, a
            NOT MET AC
  APPROVE   otherwise; MEDIUM/LOW/INFO /review findings are listed anyway

The shadow severity of a /code-review finding is reported and logged but never
changes the verdict. A MEDIUM or LOW shadow severity counts as "would have
been downgraded".

Output:

  {
    "verdict": "APPROVE|BLOCKING|HUMAN",
    "human_reasons": ["..."],
    "blocking_reasons": ["..."],
    "listed_findings": ["..."],          # /review MEDIUM, LOW and INFO
    "approved_escalations": ["..."],
    "correctness": {"total": M, "downgraded": N,
                    "line": "N of M correctness findings would have been downgraded"},
    "log": {"path": "...", "rows": M, "written": true}
  }

Measurement log: one row per /code-review finding is appended to
~/.claude/pre-merge-findings.tsv (PRE_MERGE_FINDINGS_LOG overrides the path):
date (UTC timestamp), repo, PR number or branch, file:line, shadow severity,
verdict of the run. A new or empty file gets the header line first; appending
keeps the file's mode. A log that cannot be written is a warning on stderr
and "written": false, never a lost verdict.

Exit codes:
  0  verdict printed
  2  usage error, or the input is unreadable or invalid (no verdict printed)
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_LOG = Path.home() / ".claude" / "pre-merge-findings.tsv"
LOG_ENV = "PRE_MERGE_FINDINGS_LOG"
LOG_COLUMNS = ("date", "repo", "pr_or_branch", "location", "shadow_severity", "verdict")

APPROVE = "APPROVE"
BLOCKING = "BLOCKING"
HUMAN = "HUMAN"

AC_VERIFIED = "VERIFIED"
AC_NOT_MET = "NOT MET"
AC_UNVERIFIABLE = "UNVERIFIABLE"
AC_STATUSES = (AC_VERIFIED, AC_NOT_MET, AC_UNVERIFIABLE)

RUNTIME_FAIL = "FAIL"
RUNTIME_STATUSES = ("PASS", "WARN", RUNTIME_FAIL, "SKIP")

REVIEW_SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO")
REVIEW_BLOCKING = ("CRITICAL", "HIGH")

SHADOW_HIGH = "HIGH"
SHADOW_SEVERITIES = (SHADOW_HIGH, "MEDIUM", "LOW")

APPROVED_LABEL_PREFIX = "approved:"
# Category 5 of docs/escalation-list.md: judgment, never approved by a label.
SCOPE_CATEGORY = "scope"

TOP_LEVEL_KEYS = ("repo", "pr", "branch", "escalation", "acceptance", "runtime",
                  "tests", "review_findings", "correctness_findings")
TEST_COUNT_KEYS = ("passed", "failed", "skipped")

EXIT_OK = 0
EXIT_INVALID = 2


class Invalid(Exception):
    pass


# --- validation ---------------------------------------------------------------

def _list(data, key):
    value = data.get(key, [])
    if not isinstance(value, list) or not all(isinstance(v, dict) for v in value):
        raise Invalid(f"'{key}' must be a list of objects")
    return value


def _choice(item, key, allowed, where):
    value = item.get(key)
    if value not in allowed:
        raise Invalid(f"{where}: '{key}' must be one of {', '.join(allowed)}, got {value!r}")
    return value


def _text(item, key, where, required=False):
    value = item.get(key, "")
    if value is None:
        value = ""
    if not isinstance(value, (str, int)):
        raise Invalid(f"{where}: '{key}' must be a string")
    value = str(value)
    if required and not value:
        raise Invalid(f"{where}: '{key}' is required")
    return value


def validate(data):
    if not isinstance(data, dict):
        raise Invalid("input must be a JSON object")
    unknown = sorted(set(data) - set(TOP_LEVEL_KEYS))
    if unknown:
        raise Invalid(f"unknown key(s): {', '.join(unknown)}")
    if data.get("pr") in (None, "") and not data.get("branch"):
        raise Invalid("either 'pr' or 'branch' is required")

    escalation = data.get("escalation", {})
    if not isinstance(escalation, dict):
        raise Invalid("'escalation' must be an object")
    for hit in _list(escalation, "hits"):
        _text(hit, "category", "escalation hit", required=True)
    for issue in _list(escalation, "linked_issues"):
        labels = issue.get("labels", [])
        if not isinstance(labels, list) or not all(isinstance(l, str) for l in labels):
            raise Invalid("linked issue: 'labels' must be a list of strings")

    for ac in _list(data, "acceptance"):
        _choice(ac, "status", AC_STATUSES, "acceptance")
    for check in _list(data, "runtime"):
        _choice(check, "status", RUNTIME_STATUSES, "runtime")
    for f in _list(data, "review_findings"):
        _choice(f, "severity", REVIEW_SEVERITIES, "review finding")
    for f in _list(data, "correctness_findings"):
        _text(f, "file", "correctness finding", required=True)
        _choice(f, "shadow_severity", SHADOW_SEVERITIES, "correctness finding")

    tests = data.get("tests", {})
    if not isinstance(tests, dict):
        raise Invalid("'tests' must be an object")
    for key in TEST_COUNT_KEYS:
        value = tests.get(key, 0)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise Invalid(f"tests: '{key}' must be a non-negative integer")


# --- mapping ------------------------------------------------------------------

def location(finding):
    line = finding.get("line")
    return f"{finding['file']}:{line}" if line not in (None, "") else finding["file"]


def is_approved(category, linked_issues):
    if category == SCOPE_CATEGORY or not linked_issues:
        return False
    label = APPROVED_LABEL_PREFIX + category
    return all(label in issue.get("labels", []) for issue in linked_issues)


def evaluate(data):
    human, blocking, listed, approved = [], [], [], []

    escalation = data.get("escalation", {})
    linked = escalation.get("linked_issues", [])
    for hit in escalation.get("hits", []):
        text = f"escalation {hit['category']}: {hit.get('file') or '-'} ({hit.get('reason') or 'no reason given'})"
        (approved if is_approved(hit["category"], linked) else human).append(text)

    for ac in data.get("acceptance", []):
        if ac["status"] == AC_UNVERIFIABLE:
            human.append(f"AC {AC_UNVERIFIABLE}: {ac.get('criterion', '')}")
        elif ac["status"] == AC_NOT_MET:
            blocking.append(f"AC {AC_NOT_MET}: {ac.get('criterion', '')}")

    for check in data.get("runtime", []):
        if check["status"] == RUNTIME_FAIL:
            detail = f" ({check['detail']})" if check.get("detail") else ""
            human.append(f"runtime {RUNTIME_FAIL}: {check.get('check', '')}{detail}")

    correctness = data.get("correctness_findings", [])
    for f in correctness:
        blocking.append(f"correctness {location(f)}: {f.get('summary', '')} "
                        f"(shadow {f['shadow_severity']})")

    for f in data.get("review_findings", []):
        text = f"review {f['severity']}: {f.get('finding', '')} ({f.get('location') or '-'})"
        (blocking if f["severity"] in REVIEW_BLOCKING else listed).append(text)

    failed = data.get("tests", {}).get("failed", 0)
    if failed:
        blocking.append(f"tests: {failed} failed")

    verdict = HUMAN if human else BLOCKING if blocking else APPROVE
    downgraded = sum(f["shadow_severity"] != SHADOW_HIGH for f in correctness)
    return {
        "verdict": verdict,
        "human_reasons": human,
        "blocking_reasons": blocking,
        "listed_findings": listed,
        "approved_escalations": approved,
        "correctness": {
            "total": len(correctness),
            "downgraded": downgraded,
            "line": f"{downgraded} of {len(correctness)} correctness findings would have been downgraded",
        },
    }


# --- measurement log ----------------------------------------------------------

def _field(value):
    """One TSV field: tabs and newlines would add columns or rows."""
    return " ".join(str(value).split()) if value is not None else ""


def log_rows(data, verdict):
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    target = data.get("pr") if data.get("pr") not in (None, "") else data.get("branch")
    return ["\t".join(_field(v) for v in (stamp, data.get("repo", ""), target, location(f),
                                          f["shadow_severity"], verdict))
            for f in data.get("correctness_findings", [])]


def write_log(path, rows):
    if not rows:
        return True
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        new = not path.exists() or path.stat().st_size == 0
        with path.open("a", encoding="utf-8") as fh:
            if new:
                fh.write("\t".join(LOG_COLUMNS) + "\n")
            fh.write("\n".join(rows) + "\n")
        return True
    except OSError as exc:
        print(f"warning: could not append to the findings log '{path}': {exc}", file=sys.stderr)
        return False


# --- CLI ----------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", help="JSON file with the gate results (default: stdin)")
    args = parser.parse_args(argv)

    try:
        text = Path(args.input).read_text(encoding="utf-8") if args.input else sys.stdin.read()
        data = json.loads(text)
        validate(data)
    except (OSError, UnicodeDecodeError) as exc:
        print(f"pre-merge-verdict: cannot read input: {exc}", file=sys.stderr)
        return EXIT_INVALID
    except ValueError as exc:
        print(f"pre-merge-verdict: input is not valid JSON: {exc}", file=sys.stderr)
        return EXIT_INVALID
    except Invalid as exc:
        print(f"pre-merge-verdict: invalid input: {exc}", file=sys.stderr)
        return EXIT_INVALID

    result = evaluate(data)
    log_path = Path(os.environ.get(LOG_ENV) or DEFAULT_LOG)
    rows = log_rows(data, result["verdict"])
    result["log"] = {"path": str(log_path), "rows": len(rows), "written": write_log(log_path, rows)}
    print(json.dumps(result, indent=2))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
