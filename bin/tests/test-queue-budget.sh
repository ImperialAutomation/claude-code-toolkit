#!/bin/bash
# Tests for queue-budget.sh.
#
# Usage:
#   bin/tests/test-queue-budget.sh
#
# Hermetic: $HOME is a temp dir; the run log, the stop file and the idle
# directory are pointed into it with QUEUE_RUNS_LOG, QUEUE_STOP_FILE and
# QUEUE_IDLE_DIR. No gh and no network are involved.
#
# When adding a case, check it actually constrains the script: break the rule
# in queue-budget.sh, confirm THIS test goes red, then revert.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QB="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../queue-budget.sh}"

if [[ ! -f "$QB" ]]; then
    echo "script not found: $QB" >&2
    exit 1
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

contains() { # haystack needle -> yes/no
    case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac
}

export HOME="$T/home"
mkdir -p "$HOME"
export QUEUE_RUNS_LOG="$T/queue-runs.tsv"
export QUEUE_STOP_FILE="$T/queue-stop"
export QUEUE_IDLE_DIR="$T/queue-idle"
export CLAUDE_CODE_SESSION_ID="sess-1"

HEADER=$'date\tissue\toutcome\tpr_url\tinput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\toutput_tokens\tagents\tsession'
OLD_HEADER=$'date\tissue\toutcome\tpr_url\tinput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\toutput_tokens\tagents'

reset() { rm -rf "$QUEUE_RUNS_LOG" "$QUEUE_STOP_FILE" "$QUEUE_IDLE_DIR"; }
# row <issue> <outcome> <session>: one release row as queue-claim.sh writes it.
row() { printf '2026-11-11T00:00:00Z\t%s\t%s\t\tunknown\tunknown\tunknown\tunknown\tunknown\t%s\n' "$1" "$2" "$3" >> "$QUEUE_RUNS_LOG"; }
new_log() { printf '%s\n' "$HEADER" > "$QUEUE_RUNS_LOG"; }

OUT=""; RC=0
run() { OUT=$(bash "$QB" "$@" 2>/dev/null); RC=$?; }

echo "== 0. --help =="
run --help
check "--help exits 0" "0" "$RC"
check "--help prints usage" "yes" "$(contains "$OUT" "sage")"
check "--help names the stop file" "yes" "$(contains "$OUT" "queue-stop")"

echo "== 1. gate: budget =="
reset
run gate 3
check "no log: exit 0" "0" "$RC"
check "no log: prints budget 0/3" "budget 0/3" "$OUT"

reset
new_log
row 1 pr sess-1
row 2 escalated sess-1
row 3 failed other-session
run gate 3
check "two of this session: exit 0" "0" "$RC"
check "two of this session: prints budget 2/3" "budget 2/3" "$OUT"

row 4 failed sess-1
run gate 3
check "three releases (pr, escalated, failed) reach budget 3: exit 1" "1" "$RC"
check "budget reached: says so" "yes" "$(contains "$OUT" "budget used up (3/3)")"

row 5 pr sess-1
run gate 3
check "above the budget: exit 1" "1" "$RC"

reset
new_log
row 1 pr sess-10
row 2 pr xsess-1
run gate 1
check "only an exact session match counts" "budget 0/1" "$OUT"

echo "== 2. gate: log written before the session column =="
reset
printf '%s\n' "$OLD_HEADER" > "$QUEUE_RUNS_LOG"
printf '2026-11-01T00:00:00Z\t1\tpr\thttps://github.com/o/r/pull/1\t1\t2\t3\t4\t1\n' >> "$QUEUE_RUNS_LOG"
printf '2026-11-01T00:00:00Z\t2\tfailed\t\tunknown\tunknown\tunknown\tunknown\tunknown\n' >> "$QUEUE_RUNS_LOG"
run gate 1
check "old rows: exit 0" "0" "$RC"
check "old rows never count" "budget 0/1" "$OUT"
row 3 pr sess-1
run gate 2
check "old rows plus one new row: 1/2" "budget 1/2" "$OUT"

echo "== 3. gate: stop file =="
reset
touch "$QUEUE_STOP_FILE"
run gate 3
check "stop file: exit 1" "1" "$RC"
check "stop file: names it" "yes" "$(contains "$OUT" "$QUEUE_STOP_FILE")"
check "stop file: left in place" "yes" "$([[ -e "$QUEUE_STOP_FILE" ]] && echo yes || echo no)"

echo "== 4. gate: no session id (D8) =="
reset
OUT=$(env -u CLAUDE_CODE_SESSION_ID bash "$QB" gate 3 2>/dev/null); RC=$?
check "no session id: exit 1" "1" "$RC"
check "no session id: says so" "yes" "$(contains "$OUT" "CLAUDE_CODE_SESSION_ID")"
OUT=$(CLAUDE_CODE_SESSION_ID="" bash "$QB" gate 3 2>/dev/null); RC=$?
check "empty session id: exit 1" "1" "$RC"
OUT=$(CLAUDE_CODE_SESSION_ID="../x" bash "$QB" gate 3 2>/dev/null); RC=$?
check "session id with a slash: exit 1" "1" "$RC"

echo "== 5. idle counter =="
reset
run idle 3
check "first idle: exit 0" "0" "$RC"
check "first idle: prints idle 1/3" "idle 1/3" "$OUT"
check "idle file is per session" "1" "$(cat "$QUEUE_IDLE_DIR/sess-1" 2>/dev/null)"
run idle 3
check "second idle: idle 2/3" "idle 2/3" "$OUT"
run idle 3
check "third idle reaches the limit: exit 1" "1" "$RC"
check "limit reached: says so" "yes" "$(contains "$OUT" "3/3")"

reset
run idle 3
run idle 3
run worked
check "worked: exit 0" "0" "$RC"
run idle 3
check "worked resets the count: idle 1/3" "idle 1/3" "$OUT"

reset
run idle 2
OUT=$(CLAUDE_CODE_SESSION_ID="sess-2" bash "$QB" idle 2 2>/dev/null)
check "another session has its own count" "idle 1/2" "$OUT"

reset
run worked
check "worked without an idle file: exit 0" "0" "$RC"

reset
mkdir -p "$QUEUE_IDLE_DIR"
echo garbage > "$QUEUE_IDLE_DIR/sess-1"
run idle 3
check "unreadable count starts again at 1" "idle 1/3" "$OUT"

reset
OUT=$(env -u CLAUDE_CODE_SESSION_ID bash "$QB" idle 3 2>/dev/null); RC=$?
check "idle without session id: exit 1" "1" "$RC"

echo "== 6. usage errors =="
reset
run
check "no command: exit 2" "2" "$RC"
run bogus
check "unknown command: exit 2" "2" "$RC"
run gate
check "gate without budget: exit 2" "2" "$RC"
run gate 0
check "gate 0: exit 2" "2" "$RC"
run gate abc
check "gate abc: exit 2" "2" "$RC"
run idle
check "idle without max: exit 2" "2" "$RC"
run idle -1
check "idle -1: exit 2" "2" "$RC"
run worked extra
check "worked with an argument: exit 2" "2" "$RC"
check "usage errors made no idle file" "no" "$([[ -e "$QUEUE_IDLE_DIR" ]] && echo yes || echo no)"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
