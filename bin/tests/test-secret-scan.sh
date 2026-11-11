#!/bin/bash
# Tests for secret-scan.sh path arguments.
#
# Usage:
#   bin/tests/test-secret-scan.sh
#
# Runs the real scanner (ripgrep included) on throwaway trees with planted fake
# secrets. The fake values are assembled at runtime so this file itself does
# not match a secret pattern for gitleaks or for the scanner.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../secret-scan.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

# The scanner shells out to ripgrep. Without it every scan comes back empty,
# so the "finds the planted key" checks would fail for the wrong reason.
if ! command -v rg >/dev/null 2>&1; then
    echo "ripgrep (rg) not on PATH: secret-scan.sh cannot scan without it" >&2
    exit 1
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}
contains() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

FAKE_KEY="sk_""live_""abcdefghijklmnop1234"

# clean/ holds nothing; dirty/ and the loose file hold a planted payment key.
mkdir -p "$T/clean" "$T/dirty"
printf 'def add(a, b):\n    return a + b\n' > "$T/clean/util.py"
printf 'STRIPE = "%s"\n' "$FAKE_KEY" > "$T/dirty/billing.py"
printf 'STRIPE = "%s"\n' "$FAKE_KEY" > "$T/loose.py"

run() { bash "$SCRIPT" "$@" 2>&1; }
status() { bash "$SCRIPT" "$@" >/dev/null 2>&1; echo $?; }

echo "== 1. one clean directory: unchanged behaviour =="
OUT=$(run "$T/clean")
check "clean dir exits 0" "0" "$(status "$T/clean")"
check "clean dir reports CLEAN" "yes" "$(contains "$OUT" "Result: CLEAN")"
check "no argument scans . (exit 0 in clean cwd)" "0" \
    "$(cd "$T/clean" && bash "$SCRIPT" >/dev/null 2>&1; echo $?)"

echo "== 2. two directories: the second one is scanned too =="
OUT=$(run "$T/clean" "$T/dirty")
check "two dirs exit 1" "1" "$(status "$T/clean" "$T/dirty")"
check "finding from second dir reported" "yes" "$(contains "$OUT" "billing.py")"
check "header names the second dir" "yes" "$(contains "$OUT" "$T/dirty")"

echo "== 3. a file path as the only argument is scanned =="
OUT=$(run "$T/loose.py")
check "file arg exits 1" "1" "$(status "$T/loose.py")"
check "finding names the file" "yes" "$(contains "$OUT" "loose.py:1:")"
check "no cd error" "no" "$(contains "$OUT" "cd:")"

echo "== 4. a file and a directory together =="
OUT=$(run "$T/loose.py" "$T/dirty")
check "mixed exits 1" "1" "$(status "$T/loose.py" "$T/dirty")"
check "file finding present" "yes" "$(contains "$OUT" "loose.py:1:")"
check "dir finding present" "yes" "$(contains "$OUT" "billing.py:1:")"

echo "== 5. a missing path exits 2 before scanning =="
OUT=$(run "$T/clean" "$T/nope")
check "missing path exits 2" "2" "$(status "$T/clean" "$T/nope")"
check "message names the path" "yes" "$(contains "$OUT" "$T/nope")"
check "no cd error" "no" "$(contains "$OUT" "cd:")"
check "no scan ran" "no" "$(contains "$OUT" "Result:")"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
