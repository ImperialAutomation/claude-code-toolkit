#!/bin/bash
# Tests for strip-ansi.sh.
#
# Usage:
#   bin/tests/test-strip-ansi.sh
#
# Fixtures are built from the escape sequences real test runners emit (vitest's
# colour, cursor and hyperlink codes) rather than a single `ESC[31m`: the point
# of the script over the ad-hoc `sed 's/\x1b\[[0-9;]*m//g'` it replaces is that
# it also removes the non-colour sequences that regex leaves behind.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../strip-ansi.sh}"

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

ESC=$'\033'
BEL=$'\007'

echo "== 1. colour codes (SGR) are removed =="
printf '%s\n' \
    " ${ESC}[32m✓${ESC}[39m src/api/client.test.ts ${ESC}[2m(12 tests)${ESC}[22m ${ESC}[33m48${ESC}[2mms${ESC}[22m${ESC}[39m" \
    " ${ESC}[31m×${ESC}[39m src/api/orders.test.ts > fetchOrders > ${ESC}[1;31mthrows on Network Error${ESC}[0m" \
    > "$T/vitest.txt"
run "$T/vitest.txt" "$T/vitest.clean" >/dev/null 2>&1
check "first line clean" " ✓ src/api/client.test.ts (12 tests) 48ms" "$(sed -n 1p "$T/vitest.clean")"
check "compound SGR (1;31) clean" " × src/api/orders.test.ts > fetchOrders > throws on Network Error" \
    "$(sed -n 2p "$T/vitest.clean")"
check "no ESC byte left" "0" "$(grep -c "$ESC" "$T/vitest.clean")"

echo "== 2. cursor and erase codes (other CSI) are removed =="
# Vitest's interactive reporter rewrites lines with erase-line and
# cursor-to-column codes. The old SGR-only regex leaves these in, and they then
# break a grep for the text they sit in front of.
printf '%s\n' "${ESC}[2K${ESC}[1G RUN  v2.1.8 /home/dev/shop${ESC}[?25l" "${ESC}[1A${ESC}[2K Test Files  1 failed | 4 passed (5)" \
    > "$T/cursor.txt"
run "$T/cursor.txt" "$T/cursor.clean" >/dev/null 2>&1
check "erase + column codes gone" " RUN  v2.1.8 /home/dev/shop" "$(sed -n 1p "$T/cursor.clean")"
check "cursor-up code gone" " Test Files  1 failed | 4 passed (5)" "$(sed -n 2p "$T/cursor.clean")"

echo "== 3. OSC hyperlinks are removed, their visible text kept =="
printf '%s\n' \
    "see ${ESC}]8;;file:///home/dev/shop/src/api/orders.ts${BEL}orders.ts:42${ESC}]8;;${BEL} for details" \
    "and ${ESC}]8;;https://vitest.dev/guide/${ESC}\\the guide${ESC}]8;;${ESC}\\ too" \
    > "$T/osc.txt"
run "$T/osc.txt" "$T/osc.clean" >/dev/null 2>&1
check "BEL-terminated OSC" "see orders.ts:42 for details" "$(sed -n 1p "$T/osc.clean")"
check "ST-terminated OSC" "and the guide too" "$(sed -n 2p "$T/osc.clean")"

echo "== 4. two-byte escapes are removed =="
printf '%s\n' "${ESC}7saved${ESC}8 ${ESC}(Bcharset" > "$T/twobyte.txt"
run "$T/twobyte.txt" "$T/twobyte.clean" >/dev/null 2>&1
check "ESC 7 / ESC 8 / ESC ( B gone" "saved charset" "$(cat "$T/twobyte.clean")"

echo "== 5. everything that is not an escape survives byte for byte =="
# A file without escapes must come out identical: the cleaned copy is what gets
# grepped and quoted back, so mangling unicode, tabs, brackets or a trailing
# line without newline would corrupt exactly the evidence being looked for.
printf 'naïve ✓ café\t[1m] not an escape\nexpected [31m] literal\nno newline at end' > "$T/plain.txt"
run "$T/plain.txt" "$T/plain.clean" >/dev/null 2>&1
check "plain file unchanged" "same" "$(cmp -s "$T/plain.txt" "$T/plain.clean" && echo same || echo differs)"
: > "$T/empty.txt"
check "empty input gives empty output" "$T/empty.clean (0 bytes)" "$(run "$T/empty.txt" "$T/empty.clean" 2>/dev/null)"

echo "== 6. the input is read-only, the output defaults to <file>.clean =="
cp "$T/vitest.txt" "$T/orig.txt"
check "default outfile named in summary" "yes" \
    "$(case "$(run "$T/vitest.txt" 2>/dev/null)" in "$T/vitest.txt.clean ("*) echo yes ;; *) echo no ;; esac)"
check "default outfile is clean" " ✓ src/api/client.test.ts (12 tests) 48ms" "$(sed -n 1p "$T/vitest.txt.clean")"
check "input untouched" "same" "$(cmp -s "$T/vitest.txt" "$T/orig.txt" && echo same || echo differs)"
# A second run over a different input must replace, not append to, the copy.
run "$T/osc.txt" "$T/vitest.txt.clean" >/dev/null 2>&1
check "existing outfile truncated" "2" "$(wc -l < "$T/vitest.txt.clean" | tr -d ' ')"

echo "== 7. the outfile can never be the input =="
# `sed ... in > in` truncates the input before sed reads it: the capture would be
# gone, and the run would report a clean 0-byte success.
check "same path refused with exit 1" "1" "$(run "$T/orig.txt" "$T/orig.txt" >/dev/null 2>&1; echo $?)"
check "same file via another spelling refused" "1" \
    "$(run "$T/orig.txt" "$T/./orig.txt" >/dev/null 2>&1; echo $?)"
ln -s "$T/orig.txt" "$T/link.txt"
check "same file via symlink refused" "1" "$(run "$T/orig.txt" "$T/link.txt" >/dev/null 2>&1; echo $?)"
check "input survives a refused run" "same" "$(cmp -s "$T/vitest.txt" "$T/orig.txt" && echo same || echo differs)"

echo "== 8. argument and input validation =="
check "no args exits 2"         "2" "$(run >/dev/null 2>&1; echo $?)"
check "three args exits 2"      "2" "$(run "$T/orig.txt" "$T/a" "$T/b" >/dev/null 2>&1; echo $?)"
check "usage goes to stderr"    "yes" "$(case "$(run 2>&1 >/dev/null)" in *usage*) echo yes ;; *) echo no ;; esac)"
check "missing input exits 1"   "1" "$(run "$T/nope.txt" "$T/nope.clean" >/dev/null 2>&1; echo $?)"
# A failed run must not leave a file behind that a later Read takes for a result.
check "no outfile for missing input" "absent" "$([[ -e "$T/nope.clean" ]] && echo present || echo absent)"
check "directory as input exits 1" "1" "$(run "$T" "$T/dir.clean" >/dev/null 2>&1; echo $?)"

echo "== 9. paths survive intact =="
run "$T/vitest.txt" "$T/nested/deeper/out.txt" >/dev/null 2>&1
check "parent directories created" " ✓ src/api/client.test.ts (12 tests) 48ms" "$(sed -n 1p "$T/nested/deeper/out.txt")"
cp "$T/vitest.txt" "$T/has space.txt"
run "$T/has space.txt" >/dev/null 2>&1
check "space in input path" " ✓ src/api/client.test.ts (12 tests) 48ms" "$(sed -n 1p "$T/has space.txt.clean")"
check "relative paths work" " ✓ src/api/client.test.ts (12 tests) 48ms" \
    "$(cd "$T" && run vitest.txt rel.clean >/dev/null 2>&1; sed -n 1p "$T/rel.clean")"

echo "== 10. the summary reports the real byte count =="
check "byte count matches file on disk" "yes" \
    "$(summary=$(run "$T/vitest.txt" "$T/count.clean" 2>/dev/null)
       bytes=$(wc -c < "$T/count.clean" | tr -d ' ')
       [[ "$summary" == "$T/count.clean ($bytes bytes)" ]] && echo yes || echo no)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
