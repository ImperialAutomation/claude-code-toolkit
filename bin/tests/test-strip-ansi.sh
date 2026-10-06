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

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
