#!/bin/bash
# Tests for install.sh's handling of ~/.claude/settings.json.
#
# Usage:
#   bin/tests/test-install.sh
#
# install.sh writes under ~, so every run gets a throwaway HOME. The symlinks it
# creates there point at this checkout and are removed with the directory.
# A stub uv shadows the real one, so no run downloads MarkItDown.

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

status_of() { # exit status -> zero/nonzero
    [[ "$1" -eq 0 ]] && echo zero || echo nonzero
}

# Stub uv: logs its arguments to $UV_LOG, exits with $UV_STUB_RC (default 0).
STUB_BIN="$T/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/uv" << 'EOF'
#!/bin/bash
echo "$*" >> "$UV_LOG"
exit "${UV_STUB_RC:-0}"
EOF
chmod +x "$STUB_BIN/uv"
UV_LOG="$T/uv.log"
STUB_PATH="$STUB_BIN:$PATH"

# PATH without uv, for the "uv missing" case. A directory that holds a uv is
# replaced by a copy of symlinks to everything else in it, so a uv installed
# next to bash and python3 (e.g. /usr/bin from a distro package) does not take
# them out of PATH too.
NO_UV_PATH=""
n=0
IFS=: read -ra path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
    if [[ -x "$d/uv" ]]; then
        n=$((n+1)); farm="$T/no-uv-$n"; mkdir -p "$farm"
        for f in "$d"/*; do [[ "${f##*/}" == uv ]] || ln -s "$f" "$farm/"; done
        d="$farm"
    fi
    NO_UV_PATH+="${NO_UV_PATH:+:}$d"
done

install_into() { # home [path] -> install.sh output (stdout+stderr)
    mkdir -p "$1"
    env HOME="$1" PATH="${2:-$STUB_PATH}" UV_LOG="$UV_LOG" bash "$INSTALL" 2>&1
}

echo "== 1. first install writes the loaded template =="
H1="$T/fresh"
out=$(install_into "$H1"); rc=$?
check "first install exits 0" "zero" "$(status_of $rc)"
check "reports the install" "yes" \
    "$(contains "$out" "Installed: ~/.claude/settings.json (copied from settings-global.jsonc)")"
env HOME="$H1" python3 "$HELPER" "$TEMPLATE" > "$T/expected.json"
check "settings.json is the loaded template, byte for byte" "same" \
    "$(cmp -s "$T/expected.json" "$H1/.claude/settings.json" && echo same || echo differs)"
check "__HOME__ expanded to the install's HOME" "yes" \
    "$(contains "$(cat "$H1/.claude/settings.json")" "\"$H1/.claude/playwright-output\"")"

echo "== 2. a re-run brings a missing template hook into the existing file =="
FOREIGN="~/.claude/bin/hook-block-foreign-worktree-git.sh"
# Drop the hook from the installed file, as on a machine installed before the
# template gained it.
python3 -c '
import json, sys
d = json.load(sys.stdin)
for group in d["hooks"]["PreToolUse"]:
    group["hooks"] = [h for h in group["hooks"] if h["command"] != sys.argv[1]]
json.dump(d, sys.stdout, indent=2)
' "$FOREIGN" < "$H1/.claude/settings.json" > "$T/without.json"
mv "$T/without.json" "$H1/.claude/settings.json"
check "precondition: hook removed" "no" "$(contains "$(cat "$H1/.claude/settings.json")" "$FOREIGN")"
out=$(install_into "$H1"); rc=$?
check "re-run with sync exits 0" "zero" "$(status_of $rc)"
check "re-run reports the added hook" "yes" "$(contains "$out" "added: PreToolUse [Bash] $FOREIGN")"
check "hook is back in settings.json" "yes" "$(contains "$(cat "$H1/.claude/settings.json")" "$FOREIGN")"
check "backup written next to it" "1" \
    "$(compgen -G "$H1/.claude/settings.json.*.bak" | grep -c .)"
out=$(install_into "$H1"); rc=$?
check "up-to-date re-run exits 0" "zero" "$(status_of $rc)"
check "third run reports up to date" "yes" "$(contains "$out" "settings hooks up to date")"

echo "== 3. a failing sync fails the install, after the remaining steps =="
H3="$T/broken-live"
mkdir -p "$H3/.claude"
echo '{ not json' > "$H3/.claude/settings.json"
out=$(install_into "$H3"); rc=$?
check "exits non-zero" "nonzero" "$(status_of $rc)"
check "sync error is in the output" "yes" "$(contains "$out" "settings-sync-hooks:")"
check "toolkit.yaml still created" "yes" "$([[ -f "$H3/.claude/toolkit.yaml" ]] && echo yes || echo no)"
check "knowledge/ still created" "yes" "$([[ -d "$H3/.claude/knowledge" ]] && echo yes || echo no)"

echo "== 4. a failing template load on first install leaves nothing behind =="
# install.sh reads the template next to itself, so a scratch copy of the repo
# with a broken template makes the real helper fail; nothing is mocked.
R4="$T/broken-repo"
mkdir -p "$R4/claude-md"
cp "$INSTALL" "$R4/install.sh"
cp -r "$REPO_DIR/bin" "$R4/bin"
echo '{ not json' > "$R4/claude-md/settings-global.jsonc"
H4="$T/broken-template"
mkdir -p "$H4"
out=$(env HOME="$H4" PATH="$STUB_PATH" UV_LOG="$UV_LOG" bash "$R4/install.sh" 2>&1); rc=$?
check "exits non-zero" "nonzero" "$(status_of $rc)"
check "no settings.json written" "no" "$([[ -e "$H4/.claude/settings.json" ]] && echo yes || echo no)"
# Whatever the temp file is called: the only regular file left is toolkit.yaml.
check "no temp file left in ~/.claude" "0" \
    "$(find "$H4/.claude" -maxdepth 1 -type f ! -name toolkit.yaml | grep -c .)"
check "no install reported" "no" "$(contains "$out" "Installed: ~/.claude/settings.json")"

echo "== 5. MarkItDown is installed as a uv tool =="
H5="$T/markitdown"
rm -f "$UV_LOG"
out=$(install_into "$H5"); rc=$?
check "exits 0" "zero" "$(status_of $rc)"
check "uv asked to install markitdown with all extras" "tool install markitdown[all]" \
    "$(cat "$UV_LOG" 2>/dev/null)"

echo "== 6. without uv the MarkItDown step warns and the install succeeds =="
H6="$T/no-uv"
check "precondition: no uv on the stripped PATH" "no" \
    "$(env PATH="$NO_UV_PATH" "$BASH" -c 'command -v uv' >/dev/null && echo yes || echo no)"
check "precondition: bash and python3 still on the stripped PATH" "yes" \
    "$(env PATH="$NO_UV_PATH" "$BASH" -c 'command -v bash && command -v python3' >/dev/null && echo yes || echo no)"
out=$(install_into "$H6" "$NO_UV_PATH"); rc=$?
check "exits 0" "zero" "$(status_of $rc)"
check "warns that uv is missing" "yes" "$(contains "$out" "uv not found")"
check "settings.json still installed" "yes" "$([[ -f "$H6/.claude/settings.json" ]] && echo yes || echo no)"

echo "== 7. a failing uv install fails the install, after the remaining steps =="
H7="$T/uv-fails"
out=$(UV_STUB_RC=1 install_into "$H7"); rc=$?
check "exits non-zero" "nonzero" "$(status_of $rc)"
check "reports the failed MarkItDown step" "yes" "$(contains "$out" "the MarkItDown step failed")"
check "toolkit.yaml still created" "yes" "$([[ -f "$H7/.claude/toolkit.yaml" ]] && echo yes || echo no)"
check "knowledge/ still created" "yes" "$([[ -d "$H7/.claude/knowledge" ]] && echo yes || echo no)"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
