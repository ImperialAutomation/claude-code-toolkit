#!/bin/bash
# Tests for repeat-cmd.sh.
#
# Usage:
#   bin/tests/test-repeat-cmd.sh
#
# Runs against real commands (sh -c appending to a counter file) rather than
# mocks: the thing under test is how often the wrapper starts a child process,
# where it stops, and what it does with that child's output and exit status.

# The `sh -c '... "$1" ...'` scripts are single-quoted on purpose: $1 must expand
# in the child shell, not here.
# shellcheck disable=SC2016

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../repeat-cmd.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
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

run() { bash "$SCRIPT" "$@"; }

lines() { wc -l < "$1" | tr -d ' '; }

echo "== 1. the command runs exactly <count> times =="
run 7 sh -c 'echo x >> "$1"' _ "$T/seven" >/dev/null 2>&1
check "seven runs" "7" "$(lines "$T/seven")"
check "exit 0 on success" "0" \
    "$(run 3 sh -c 'echo x >> "$1"' _ "$T/exit0" >/dev/null 2>&1; echo $?)"
run 1 sh -c 'echo x >> "$1"' _ "$T/one" >/dev/null 2>&1
check "count 1 runs once" "1" "$(lines "$T/one")"
# Arguments reach the command intact, including spaces, rather than being
# re-split by the wrapper.
run 1 sh -c 'printf "%s\n" "$2" >> "$1"' _ "$T/args" "two words" >/dev/null 2>&1
check "arguments passed verbatim" "two words" "$(cat "$T/args")"

echo "== 2. the command's output is discarded on success =="
out=$(run 3 sh -c 'echo STDOUT-MARKER; echo STDERR-MARKER >&2' 2>&1)
check "stdout not shown"  "no" "$(contains "$out" STDOUT-MARKER)"
check "stderr not shown"  "no" "$(contains "$out" STDERR-MARKER)"

echo "== 3. the summary reports runs and timing =="
summary=$(run 4 true 2>/dev/null)
check "one summary line"         "1"   "$(printf '%s\n' "$summary" | wc -l | tr -d ' ')"
check "summary says 4/4 runs ok" "yes" "$(contains "$summary" "4/4 runs ok")"
check "summary has total"        "yes" "$(contains "$summary" "total ")"
check "summary has per-run time" "yes" "$(contains "$summary" "/run")"
check "timing format" "yes" \
    "$([[ "$summary" =~ total\ [0-9]+\.[0-9]{3}s,\ [0-9]+\.[0-9]{3}s/run ]] && echo yes || echo no)"

echo "== 4. a failing iteration stops the loop and is reported =="
# Fails on its 3rd call: the counter file has 2 lines before the 3rd append.
FAIL_ON_3='echo x >> "$1"; [ "$(wc -l < "$1")" -lt 3 ] || { echo "boom on call 3" >&2; exit 5; }'
out=$(run 10 sh -c "$FAIL_ON_3" _ "$T/fail3" 2>&1); status=$?
check "exit status is the command's own" "5" "$status"
check "stops at the failing run"         "3" "$(lines "$T/fail3")"
check "names the failing iteration"      "yes" "$(contains "$out" "run 3/10 failed")"
check "names the exit status"            "yes" "$(contains "$out" "exit 5")"
check "counts the runs that succeeded"   "yes" "$(contains "$out" "after 2 ok")"
# The failing run's stderr is the diagnosis; without it the caller only knows
# that something broke, not what.
check "failing run's stderr is shown"    "yes" "$(contains "$out" "boom on call 3")"
check "first run failing" "1" \
    "$(run 5 sh -c 'exit 1' >/dev/null 2>&1; echo $?)"
out=$(run 5 sh -c 'exit 1' 2>&1)
check "first run failure named" "yes" "$(contains "$out" "run 1/5 failed")"

echo "== 5. a missing command is a failure, not a silent no-op =="
check "missing command exits 127" "127" \
    "$(run 3 this-command-does-not-exist-xyz >/dev/null 2>&1; echo $?)"

echo "== 6. argument validation =="
for bad in 0 -1 abc 1.5 ""; do
    check "count '$bad' exits 2" "2" "$(run "$bad" true >/dev/null 2>&1; echo $?)"
done
check "no args exits 2"         "2" "$(run >/dev/null 2>&1; echo $?)"
check "count without command exits 2" "2" "$(run 3 >/dev/null 2>&1; echo $?)"
check "usage goes to stderr" "yes" \
    "$(contains "$(run 2>&1 >/dev/null)" usage)"
# A rejected count must not have run the command even once.
run 0 sh -c 'echo x >> "$1"' _ "$T/never" >/dev/null 2>&1
check "nothing runs on usage error" "absent" \
    "$([[ -e "$T/never" ]] && echo present || echo absent)"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
