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

echo "== 7. without options the output is the single summary line =="
out=$(run 3 true 2>&1)
check "exactly one line, nothing else" "yes" \
    "$([[ "$out" =~ ^repeat-cmd:\ 3/3\ runs\ ok,\ total\ [0-9]+\.[0-9]{3}s,\ [0-9]+\.[0-9]{3}s/run$ ]] && echo yes || echo no)"

echo "== 8. --percentiles adds a p50/p95/max line =="
PCT_RE='^repeat-cmd: p50 ([0-9]+)\.([0-9]{3})s, p95 ([0-9]+)\.([0-9]{3})s, max ([0-9]+)\.([0-9]{3})s \(n=([0-9]+)\)$'
ms() { echo $((10#$1 * 1000 + 10#$2)); }
yesno() { if "$@"; then echo yes; else echo no; fi; }
# Alternates 10 ms and 60 ms: n=10 gives five of each, so nearest-rank p50 is
# the 5th sorted value (a fast run) and p95 the 10th (a slow run).
ALTERNATE='n=$(cat "$1" 2>/dev/null | wc -l); echo x >> "$1"; if [ $((n % 2)) -eq 0 ]; then sleep 0.01; else sleep 0.06; fi'
out=$(run --percentiles 10 sh -c "$ALTERNATE" _ "$T/alt" 2>/dev/null)
check "two lines" "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check "first line is the usual summary" "yes" "$(contains "$(head -n1 <<<"$out")" "10/10 runs ok")"
pline=$(tail -n1 <<<"$out")
if [[ "$pline" =~ $PCT_RE ]]; then
    p50=$(ms "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
    p95=$(ms "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
    max=$(ms "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}")
    n="${BASH_REMATCH[7]}"
    check "percentile line format" "yes" "yes"
    check "n is the count" "10" "$n"
    check "p50 in the fast band (10-50 ms)" "yes" "$(yesno test "$p50" -ge 10 -a "$p50" -lt 50)"
    check "p95 in the slow band (>= 60 ms)" "yes" "$(yesno test "$p95" -ge 60)"
    check "max >= p95" "yes" "$(yesno test "$max" -ge "$p95")"
else
    check "percentile line format" "a match" "$pline"
fi
pline=$(run --percentiles 1 sleep 0.01 2>/dev/null | tail -n1)
if [[ "$pline" =~ $PCT_RE ]]; then
    check "count 1: p50 = p95" "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
    check "count 1: p95 = max" "${BASH_REMATCH[3]}.${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}.${BASH_REMATCH[6]}"
    check "count 1: n=1" "1" "${BASH_REMATCH[7]}"
else
    check "count 1 percentile line format" "a match" "$pline"
fi
# A failing counted run: behaviour unchanged, no percentile line anywhere.
out=$(run --percentiles 10 sh -c "$FAIL_ON_3" _ "$T/pfail" 2>&1); status=$?
check "--percentiles failure keeps the command's status" "5" "$status"
check "--percentiles failure names the run as before" "yes" "$(contains "$out" "run 3/10 failed")"
check "--percentiles failure prints no percentile line" "no" "$(contains "$out" "p95")"

echo "== 9. --warmup runs uncounted extra runs =="
out=$(run --warmup 2 --percentiles 5 sh -c 'echo x >> "$1"' _ "$T/warm" 2>/dev/null)
check "warmup 2 + count 5 runs 7 times" "7" "$(lines "$T/warm")"
check "summary counts only 5" "yes" "$(contains "$out" "5/5 runs ok")"
check "percentiles over n=5" "yes" "$(contains "$out" "(n=5)")"
out=$(run --warmup 2 3 sh -c 'echo x >> "$1"' _ "$T/warm2" 2>/dev/null)
check "warmup without --percentiles: one line" "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check "warmup without --percentiles runs 5 times" "5" "$(lines "$T/warm2")"
run --warmup 0 2 sh -c 'echo x >> "$1"' _ "$T/warm0" >/dev/null 2>&1
check "warmup 0 runs only the count" "2" "$(lines "$T/warm0")"
# Fails on its 2nd call, which is the 2nd of 3 warmup runs.
FAIL_ON_2='echo x >> "$1"; [ "$(wc -l < "$1")" -lt 2 ] || { echo "boom on call 2" >&2; exit 4; }'
out=$(run --warmup 3 5 sh -c "$FAIL_ON_2" _ "$T/wfail" 2>&1); status=$?
check "failing warmup run: command's own status" "4" "$status"
check "failing warmup run stops the loop" "2" "$(lines "$T/wfail")"
check "failing warmup run is named as warmup" "yes" "$(contains "$out" "warmup run 2/3 failed")"
check "failing warmup run's stderr is shown" "yes" "$(contains "$out" "boom on call 2")"

echo "== 10. option validation =="
for bad in "--warmup" "--warmup -1" "--warmup abc" "--warmup 01" "--unknown" "--percentiles"; do
    # $bad is split into option words on purpose.
    # shellcheck disable=SC2086
    check "'$bad' with a command exits 2" "2" \
        "$(run $bad sh -c 'echo x >> "$1"' _ "$T/never-opt" >/dev/null 2>&1; echo $?)"
done
check "nothing runs on option error" "absent" \
    "$([[ -e "$T/never-opt" ]] && echo present || echo absent)"
# Options go before the count; after it they are the command, as before.
check "option after the count is run as the command" "127" \
    "$(run 1 --percentiles >/dev/null 2>&1; echo $?)"
check "--help documents --percentiles" "yes" "$(contains "$(run --help)" "--percentiles")"
check "--help documents --warmup" "yes" "$(contains "$(run --help)" "--warmup")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
