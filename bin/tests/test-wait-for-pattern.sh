#!/bin/bash
# Tests for wait-for-pattern.sh.
#
# Usage:
#   bin/tests/test-wait-for-pattern.sh
#
# Runs against real files on a real filesystem — the thing under test is a
# grep plus an mtime comparison, so a mock would test nothing. Every case uses
# poll 1 and a short timeout so a timing-out case costs a second, not ten
# minutes; the match cases are written so the pattern is already present before
# the script starts, which keeps the suite deterministic rather than racing a
# background writer.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../wait-for-pattern.sh}"

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

check_contains() { # name haystack needle
    if [[ "$2" == *"$3"* ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 ('$3' not in '$2')"; FAIL=$((FAIL+1)); fi
}

# A progress file as implement-epic writes one: a finished run.
done_file() { # path
    printf 'PHASE: DONE\nDETAIL: all green\n' > "$1"
}

echo "== 1. a present pattern is found =="
done_file "$T/found.txt"
OUT=$("$SCRIPT" "$T/found.txt" 'DONE|FAILED' 5 1 2>/dev/null)
check "exits 0 on a match" "0" "$?"
check_contains "prints the matching line" "$OUT" "PHASE: DONE"

echo "== 2. no match times out =="
printf 'PHASE: IMPLEMENTING\n' > "$T/working.txt"
ERR=$("$SCRIPT" "$T/working.txt" 'DONE|FAILED' 2 1 2>&1 >/dev/null)
check "exits 1 on timeout" "1" \
    "$("$SCRIPT" "$T/working.txt" 'DONE|FAILED' 2 1 >/dev/null 2>&1; echo $?)"
check_contains "timeout names the pattern" "$ERR" "not found in"
check_contains "timeout dumps current contents" "$ERR" "PHASE: IMPLEMENTING"

echo "== 3. a missing file is a normal starting state =="
# Not an error: the writing process may not have created it yet. It must poll
# until the timeout rather than exiting immediately.
ERR=$("$SCRIPT" "$T/absent.txt" 'DONE' 2 1 2>&1 >/dev/null)
check "missing file exits 1 after waiting" "1" \
    "$("$SCRIPT" "$T/absent.txt" 'DONE' 2 1 >/dev/null 2>&1; echo $?)"
check_contains "missing file is reported as such" "$ERR" "does not exist"

echo "== 4. --newer-than ignores a previous run's file =="
# The bug this flag exists for: a second run on the same epic finds the first
# run's 'PHASE: DONE' still in place, matches it within a second, and reports
# the previous run's DETAIL as the new agent's result. The spawn timestamp is
# the only thing that can tell the two runs apart.
done_file "$T/stale.txt"
touch -d '2 hours ago' "$T/stale.txt"
SPAWNED_AT=$(date +%s)
check "a stale match is not accepted" "1" \
    "$("$SCRIPT" --newer-than "$SPAWNED_AT" "$T/stale.txt" 'DONE|FAILED' 2 1 >/dev/null 2>&1; echo $?)"
ERR=$("$SCRIPT" --newer-than "$SPAWNED_AT" "$T/stale.txt" 'DONE|FAILED' 2 1 2>&1 >/dev/null)
check_contains "the stale file's age is reported" "$ERR" "older than"

# Without the flag the same file matches — the flag is what changes the verdict,
# not the fixture. Without this pair, a bug that broke matching outright would
# still make the case above pass.
check "the same stale file matches without the flag" "0" \
    "$("$SCRIPT" "$T/stale.txt" 'DONE|FAILED' 5 1 >/dev/null 2>&1; echo $?)"

# mtime == cutoff must be rejected. mtime has one-second granularity, so the
# previous run's last write and the new spawn routinely land in the same second;
# accepting equality hands that file to the new run, which is the whole bug.
done_file "$T/same-second.txt"
check "mtime equal to the cutoff is rejected" "1" \
    "$("$SCRIPT" --newer-than "$(stat -c %Y "$T/same-second.txt")" \
        "$T/same-second.txt" 'DONE|FAILED' 2 1 >/dev/null 2>&1; echo $?)"

echo "== 5. --newer-than accepts the current run's file =="
# The new agent overwrites the path, so the mtime moves past the spawn time.
PAST=$(( $(date +%s) - 60 ))
done_file "$T/fresh.txt"
OUT=$("$SCRIPT" --newer-than "$PAST" "$T/fresh.txt" 'DONE|FAILED' 5 1 2>/dev/null)
check "a fresh match is accepted" "0" "$?"
check_contains "the fresh match is printed" "$OUT" "PHASE: DONE"

echo "== 6. a stale file overwritten mid-wait is accepted =="
# The real sequence: the wait starts while the previous run's file is still on
# disk, and the new agent replaces it a moment later.
done_file "$T/replaced.txt"
touch -d '2 hours ago' "$T/replaced.txt"
SPAWNED_AT=$(date +%s)
( sleep 2; done_file "$T/replaced.txt" ) &
WRITER=$!
OUT=$("$SCRIPT" --newer-than "$SPAWNED_AT" "$T/replaced.txt" 'DONE|FAILED' 10 1 2>/dev/null)
RC=$?
wait "$WRITER"
check "the rewritten file matches" "0" "$RC"
check_contains "the rewritten match is printed" "$OUT" "PHASE: DONE"

echo "== 7. --newer-than does not relax the pattern =="
# An mtime newer than the spawn is a precondition, not a match. A file the new
# agent is actively writing must still fail the pattern until it reports.
printf 'PHASE: IMPLEMENTING\n' > "$T/newish.txt"
check "a fresh non-match still times out" "1" \
    "$("$SCRIPT" --newer-than "$PAST" "$T/newish.txt" 'DONE|FAILED' 2 1 >/dev/null 2>&1; echo $?)"

echo "== 8. argument validation =="
check "no arguments exits 2" "2" \
    "$("$SCRIPT" >/dev/null 2>&1; echo $?)"
check "pattern missing exits 2" "2" \
    "$("$SCRIPT" "$T/found.txt" >/dev/null 2>&1; echo $?)"
check_contains "usage goes to stderr" "$("$SCRIPT" 2>&1 >/dev/null)" "usage"
check "non-numeric timeout exits 2" "2" \
    "$("$SCRIPT" "$T/found.txt" 'DONE' abc 1 >/dev/null 2>&1; echo $?)"
check "zero poll exits 2" "2" \
    "$("$SCRIPT" "$T/found.txt" 'DONE' 5 0 >/dev/null 2>&1; echo $?)"
# A bad epoch must not be silently treated as 0, which would accept every file
# and quietly restore the bug the flag exists to prevent.
check "non-numeric --newer-than exits 2" "2" \
    "$("$SCRIPT" --newer-than abc "$T/found.txt" 'DONE' 2 1 >/dev/null 2>&1; echo $?)"
check "--newer-than without a value exits 2" "2" \
    "$("$SCRIPT" --newer-than >/dev/null 2>&1; echo $?)"
check "unknown option exits 2" "2" \
    "$("$SCRIPT" --nope "$T/found.txt" 'DONE' 2 1 >/dev/null 2>&1; echo $?)"
# The flag is a leading option; a file or pattern may legitimately start with a
# dash only after `--`, and positional parsing must not eat the flag's value.
check "-- ends option parsing" "0" \
    "$("$SCRIPT" --newer-than "$PAST" -- "$T/fresh.txt" 'DONE' 5 1 >/dev/null 2>&1; echo $?)"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
