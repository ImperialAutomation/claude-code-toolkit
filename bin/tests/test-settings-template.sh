#!/bin/bash
# Tests for lib/settings_template.py.
#
# Usage:
#   bin/tests/test-settings-template.sh
#
# The helper turns settings-global.jsonc into the JSON that lands in
# ~/.claude/settings.json. Both install.sh (first install) and
# settings-sync-hooks.sh read the template through it, so a difference between
# what they see would make the sync report hooks the install never wrote.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../lib/settings_template.py}"
TEMPLATE="$SCRIPT_DIR/../../claude-md/settings-global.jsonc"

if [[ ! -f "$HELPER" ]]; then
    echo "script not found: $HELPER" >&2
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

# Evaluates a Python expression over the JSON on stdin, bound to `d`.
jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

cat > "$T/fixture.jsonc" <<'EOF'
// Leading comment line
{
  // comment inside an object
  "env": {
    "DIR": "__HOME__/out"  // trailing comment
  },
  "list": ["__HOME__/a", "plain"],
  "nested": {"deep": {"path": "__HOME__"}},
  "number": 3
}
EOF

echo "== 1. comments are stripped and the result is valid JSON =="
out=$(HOME=/fake/home python3 "$HELPER" "$T/fixture.jsonc"); status=$?
check "exit 0" "0" "$status"
check "valid JSON" "3" "$(printf '%s' "$out" | jq_py "d['number']")"
check "no comment text left" "no" "$(contains "$out" "comment")"

echo "== 2. __HOME__ is expanded everywhere =="
check "in a nested string" "/fake/home/out" \
    "$(printf '%s' "$out" | jq_py "d['env']['DIR']")"
check "in a list" "/fake/home/a" \
    "$(printf '%s' "$out" | jq_py "d['list'][0]")"
check "deep in nested objects" "/fake/home" \
    "$(printf '%s' "$out" | jq_py "d['nested']['deep']['path']")"
check "no placeholder left" "no" "$(contains "$out" "__HOME__")"

echo "== 3. output format matches what install.sh writes =="
# Two-space indent and a trailing newline: the file install.sh has always
# produced, so moving the code here changes no installed byte.
HOME=/fake/home python3 "$HELPER" "$T/fixture.jsonc" > "$T/out.json"
check "two-space indent" "yes" "$(contains "$(cat "$T/out.json")" $'\n  "env": {')"
check "ends with a newline" "1" "$(tail -c1 "$T/out.json" | wc -l | tr -d ' ')"

echo "== 4. the real template loads =="
real=$(HOME=/fake/home python3 "$HELPER" "$TEMPLATE"); status=$?
check "real template exit 0" "0" "$status"
check "real template has hooks" "True" \
    "$(printf '%s' "$real" | jq_py "'PreToolUse' in d['hooks']")"
check "real template placeholder expanded" "no" "$(contains "$real" "__HOME__")"

echo "== 5. errors exit non-zero =="
python3 "$HELPER" "$T/does-not-exist.jsonc" >/dev/null 2>&1
check "missing file" "1" "$?"
printf '{ "broken": \n' > "$T/broken.jsonc"
python3 "$HELPER" "$T/broken.jsonc" >/dev/null 2>&1
check "invalid JSON" "1" "$?"
python3 "$HELPER" >/dev/null 2>&1
check "no argument is a usage error" "2" "$?"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
