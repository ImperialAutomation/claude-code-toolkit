#!/bin/bash
# Tests for install.sh's handling of ~/.claude/settings.json.
#
# Usage:
#   bin/tests/test-install.sh
#
# install.sh writes under ~, so every run gets a throwaway HOME. The symlinks it
# creates there point at this checkout and are removed with the directory.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
INSTALL="${SCRIPT_UNDER_TEST:-$REPO_DIR/install.sh}"
HELPER="$REPO_DIR/bin/lib/settings_template.py"
TEMPLATE="$REPO_DIR/claude-md/settings-global.jsonc"

if [[ ! -f "$INSTALL" ]]; then
    echo "script not found: $INSTALL" >&2
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

install_into() { # home -> install.sh output (stdout+stderr)
    mkdir -p "$1"
    env HOME="$1" bash "$INSTALL" 2>&1
}

echo "== 1. first install writes the loaded template =="
H1="$T/fresh"
out=$(install_into "$H1")
check "reports the install" "yes" \
    "$(contains "$out" "Installed: ~/.claude/settings.json (copied from settings-global.jsonc)")"
env HOME="$H1" python3 "$HELPER" "$TEMPLATE" > "$T/expected.json"
check "settings.json is the loaded template, byte for byte" "same" \
    "$(cmp -s "$T/expected.json" "$H1/.claude/settings.json" && echo same || echo differs)"
check "__HOME__ expanded to the install's HOME" "yes" \
    "$(contains "$(cat "$H1/.claude/settings.json")" "\"$H1/.claude/playwright-output\"")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
