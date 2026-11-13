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

reset
new_log
# A rework release (#300, D2) counts like any other release.
row 1 pr sess-1
row 1 rework sess-1
run gate 3
check "a rework row counts toward the budget" "budget 2/3" "$OUT"
run gate 2
check "a rework row can use up the budget: exit 1" "1" "$RC"

reset
new_log
# The runner session's own row (#270) is not a release.
row 1 pr sess-1
row "" runner sess-1
row "" runner sess-1
run gate 2
check "runner rows do not count toward the budget" "budget 1/2" "$OUT"

echo "== 1b. gate: loop start marker (#270) =="
START="$QUEUE_IDLE_DIR/sess-1.start"
reset
run gate 3
check "first gate writes the loop start" "yes" \
    "$(grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$START" 2>/dev/null && echo yes || echo no)"
echo "2026-11-11T10:00:00Z" > "$START"
run gate 3
check "a later gate leaves the start unchanged" "2026-11-11T10:00:00Z" "$(cat "$START")"
: > "$START"
run gate 3
check "an empty start is rewritten" "yes" \
    "$(grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$START" 2>/dev/null && echo yes || echo no)"
echo "garbled" > "$START"
run gate 3
check "a garbled start is rewritten" "no" "$(grep -q garbled "$START" && echo yes || echo no)"
reset
touch "$QUEUE_STOP_FILE"
run gate 3
check "a gate that stops the loop writes no start" "no" "$([[ -e "$START" ]] && echo yes || echo no)"

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

echo "== 2b. gate: rows with the review columns (#297) =="
REVIEW_HEADER=$'review\treview_final\treview_findings\treview_input_tokens\treview_cache_creation_input_tokens\treview_cache_read_input_tokens\treview_output_tokens\treview_agents\tfix_input_tokens\tfix_cache_creation_input_tokens\tfix_cache_read_input_tokens\tfix_output_tokens\tfix_agents'
# review_row <issue> <session> <review columns...>: a row as queue-claim.sh
# writes it since #297, the 13 review columns after the session.
review_row() {
    local issue="$1" session="$2"; shift 2
    local IFS=$'\t'
    printf '2026-11-12T00:00:00Z\t%s\tpr\thttps://github.com/o/r/pull/%s\t1\t2\t3\t4\t1\t%s\t%s\n' \
        "$issue" "$issue" "$session" "$*" >> "$QUEUE_RUNS_LOG"
}
reset
printf '%s\t%s\n' "$HEADER" "$REVIEW_HEADER" > "$QUEUE_RUNS_LOG"
# old (nine fields), current (ten) and new rows mixed in one log
printf '2026-11-01T00:00:00Z\t1\tpr\thttps://github.com/o/r/pull/1\t1\t2\t3\t4\t1\n' >> "$QUEUE_RUNS_LOG"
row 2 escalated sess-1
review_row 3 sess-1 BLOCKING APPROVE 3 10 20 30 40 2 5 6 7 8 1
review_row 4 sess-1 "" "" "" "" "" "" "" "" "" "" "" "" ""
review_row 5 other-session APPROVE "" 0 10 20 30 40 2 "" "" "" "" ""
# no session id: an empty 10th field followed by review columns never counts
review_row 6 "" APPROVE "" 0 "" "" "" "" "" "" "" "" ""
run gate 5
check "old, current and new rows: exit 0" "0" "$RC"
check "old, current and new rows: counts this session's current and new rows" "budget 3/5" "$OUT"
run gate 3
check "new rows reach the budget: exit 1" "1" "$RC"
OUT=$(CLAUDE_CODE_SESSION_ID="APPROVE" bash "$QB" gate 5 2>/dev/null)
check "a review value is never taken for the session" "budget 0/5" "$OUT"

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

echo "== 5b. stop: the runner session's own row (#270) =="
# A main transcript as Claude Code writes it, under the temp $HOME.
TRANSCRIPT="$HOME/.claude/projects/-proj/sess-1.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
msg() { # msg <id> <timestamp> <in> <cw> <cr> <out>
    printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
        "$2" "$1" "$3" "$4" "$5" "$6"
}
{
    msg m0 2026-11-11T09:00:00Z 900 900 900 900   # before the loop
    msg m1 2026-11-11T10:00:05Z 1 100 1000 10
    msg m1 2026-11-11T10:00:06Z 1 100 1000 10     # same message again
    msg m2 2026-11-11T11:00:00Z 2 200 2000 20
} > "$TRANSCRIPT"
runner_rows() { awk -F'\t' 'NR > 1 && $3 == "runner"' "$QUEUE_RUNS_LOG" 2>/dev/null; }

reset
mkdir -p "$QUEUE_IDLE_DIR"
echo "2026-11-11T10:00:00Z" > "$START"
echo 5 > "$QUEUE_IDLE_DIR/sess-1"
run stop
check "stop: exit 0" "0" "$RC"
check "stop: removes the idle count" "no" "$([[ -e "$QUEUE_IDLE_DIR/sess-1" ]] && echo yes || echo no)"
check "stop: prints the runner summary" "runner: in 0.0k / cw 0.3k / cr 3.0k / out 0.0k, 1 agent" "$OUT"
check "stop: one runner row, window only, each message once" \
    $'\trunner\t\t3\t300\t3000\t30\t1\tsess-1' "$(runner_rows | cut -f2-10)"
check "stop: removes the loop start" "no" "$([[ -e "$START" ]] && echo yes || echo no)"
run gate 1
check "stop: its row does not use up the budget" "budget 0/1" "$OUT"

reset
run stop
check "stop without a loop start: exit 0" "0" "$RC"
check "stop without a loop start: says so" "yes" "$(contains "$OUT" "no loop start")"
check "stop without a loop start: writes no row" "no" "$([[ -e "$QUEUE_RUNS_LOG" ]] && echo yes || echo no)"

reset
mkdir -p "$QUEUE_IDLE_DIR"
echo "2026-11-11T10:00:00Z" > "$START"
OUT=$(CLAUDE_CODE_SESSION_ID="sess-9" bash "$QB" stop 2>/dev/null); RC=$?
check "stop, other session without a start: no row" "no" "$([[ -e "$QUEUE_RUNS_LOG" ]] && echo yes || echo no)"
mkdir -p "$QUEUE_IDLE_DIR"
echo "2026-11-11T10:00:00Z" > "$QUEUE_IDLE_DIR/sess-9.start"
OUT=$(CLAUDE_CODE_SESSION_ID="sess-9" bash "$QB" stop 2>/dev/null); RC=$?
check "stop, no transcript: exit 0" "0" "$RC"
check "stop, no transcript: tokens unknown" "yes" "$(contains "$OUT" "runner tokens: unknown")"
check "stop, no transcript: row with unknown tokens" \
    $'\trunner\t\tunknown\tunknown\tunknown\tunknown\tunknown\tsess-9' "$(runner_rows | cut -f2-10)"
check "stop, no transcript: removes the loop start" "no" \
    "$([[ -e "$QUEUE_IDLE_DIR/sess-9.start" ]] && echo yes || echo no)"
check "stop, no transcript: other session's start kept" "yes" "$([[ -e "$START" ]] && echo yes || echo no)"

reset
mkdir -p "$QUEUE_IDLE_DIR"
echo "2026-11-11T10:00:00Z" > "$START"
mkdir -p "$T/log-is-a-dir"
OUT=$(QUEUE_RUNS_LOG="$T/log-is-a-dir" bash "$QB" stop 2>/dev/null); RC=$?
check "stop, row not written: exit 0" "0" "$RC"
check "stop, row not written: says so" "yes" "$(contains "$OUT" "runner tokens: not logged")"
check "stop, row not written: no success line" "no" "$(contains "$OUT" "runner: ")"
check "stop, row not written: keeps the loop start" "yes" "$([[ -e "$START" ]] && echo yes || echo no)"
rmdir "$T/log-is-a-dir"

for bad in "" "garbled"; do
    reset
    mkdir -p "$QUEUE_IDLE_DIR"
    echo "$bad" > "$START"
    run stop
    check "stop, start '$bad': exit 0" "0" "$RC"
    check "stop, start '$bad': readable reason, not the argparse usage" "yes" \
        "$(contains "$OUT" "runner tokens: unknown (loop start '$bad'")"
    check "stop, start '$bad': no usage line" "no" "$(contains "$OUT" "usage:")"
    check "stop, start '$bad': row with unknown tokens" \
        $'\trunner\t\tunknown\tunknown\tunknown\tunknown\tunknown\tsess-1' "$(runner_rows | cut -f2-10)"
    check "stop, start '$bad': removes the loop start" "no" "$([[ -e "$START" ]] && echo yes || echo no)"
done

reset
OUT=$(env -u CLAUDE_CODE_SESSION_ID bash "$QB" stop 2>/dev/null); RC=$?
check "stop without session id: exit 0" "0" "$RC"
check "stop without session id: documented form" "yes" \
    "$(contains "$OUT" "runner tokens: unknown (CLAUDE_CODE_SESSION_ID")"
check "stop without session id: one line" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
check "stop without session id: writes no row" "no" "$([[ -e "$QUEUE_RUNS_LOG" ]] && echo yes || echo no)"

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
run stop extra
check "stop with an argument: exit 2" "2" "$RC"
check "usage errors made no idle file" "no" "$([[ -e "$QUEUE_IDLE_DIR" ]] && echo yes || echo no)"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
