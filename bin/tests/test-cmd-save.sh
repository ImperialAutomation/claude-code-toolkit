#!/bin/bash
# Tests for cmd-save.sh.
#
# Usage:
#   bin/tests/test-cmd-save.sh
#
# Runs against real commands (echo, sh -c, printf) rather than mocks: the thing
# under test is how the wrapper wires a child process's stdout, stderr and exit
# status to a file, and a mock would replace exactly that wiring.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../cmd-save.sh}"

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

run() { bash "$SCRIPT" "$@"; }

echo "== 1. the command's output lands in the file =="
run "$T/hello.txt" echo hello >/dev/null 2>&1
check "file created"  "hello" "$(cat "$T/hello.txt")"
check "exit 0 on success" "0" "$(run "$T/hello.txt" echo hello >/dev/null 2>&1; echo $?)"
# The capture is the file, not the terminal: a caller that reads stdout instead
# of the file must not accidentally get the data and think it worked.
check "data does not leak to stdout" "yes" \
    "$(case "$(run "$T/hello.txt" echo hello 2>/dev/null)" in *hello*) echo no ;; *) echo yes ;; esac)"

echo "== 2. a second run truncates rather than appends =="
run "$T/trunc.txt" printf 'first\n'  >/dev/null 2>&1
run "$T/trunc.txt" printf 'second\n' >/dev/null 2>&1
check "old content gone" "second" "$(cat "$T/trunc.txt")"
check "one line only"    "1"      "$(wc -l < "$T/trunc.txt" | tr -d ' ')"

echo "== 3. argument validation =="
check "no args exits 2"       "2" "$(run >/dev/null 2>&1; echo $?)"
check "only outfile exits 2"  "2" "$(run "$T/x.txt" >/dev/null 2>&1; echo $?)"
check "usage goes to stderr"  "yes" \
    "$(case "$(run 2>&1 >/dev/null)" in *usage*) echo yes ;; *) echo no ;; esac)"
# A usage error must not leave a half-made file behind that a later step reads
# as a real capture.
run "$T/never.txt" >/dev/null 2>&1
check "no file on usage error" "absent" \
    "$([[ -e "$T/never.txt" ]] && echo present || echo absent)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
