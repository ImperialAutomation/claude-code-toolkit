#!/bin/bash
# Tests for toolkit-live-repo.sh: the yes/no question /finish asks before it
# refuses to merge locally in the live toolkit repository (#206, D9).
#
# Usage:
#   bin/tests/test-toolkit-live-repo.sh
#
# Every case uses a temporary HOME whose .claude/bin symlinks into a temporary
# "live" clone, so the real toolkit checkout is never involved.
#
# Scenario index:
#   1. the live checkout itself              -> exit 0, prints the live root
#   2. a linked worktree of the live repo    -> exit 0, prints the live root
#   3. another repository                    -> exit 1, prints nothing
#   4. ~/.claude/bin is not a symlink        -> exit 1
#   5. not a repository                      -> exit 1
#   6. --help, unknown argument              -> exit 0 / exit 2

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../toolkit-live-repo.sh}"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

newrepo() { # dir
    git init -q -b main "$1"
    git -C "$1" config user.email dev@example.com
    git -C "$1" config user.name "Dana Vermeer"
    mkdir -p "$1/bin"
    printf '#!/bin/bash\n' > "$1/bin/tool.sh"
    git -C "$1" add -A
    git -C "$1" commit -qm "Add bin"
}

LIVE="$T/live"
newrepo "$LIVE"
git -C "$LIVE" worktree add -q -b issue-5-x "$T/live-5"
newrepo "$T/other"
mkdir -p "$T/home/.claude" "$T/plainhome/.claude/bin" "$T/norepo"
ln -s "$LIVE/bin" "$T/home/.claude/bin"

run() { # home args...
    OUT=$(HOME="$1" bash "$SCRIPT" "${@:2}" 2>/dev/null); RC=$?
}

echo "== 1. the live checkout =="
run "$T/home" --repo "$LIVE"
check "exit 0" 0 "$RC"
check "prints the live root" "$LIVE" "$OUT"

echo "== 2. a linked worktree of the live repo =="
run "$T/home" --repo "$T/live-5"
check "exit 0" 0 "$RC"
check "prints the live root" "$LIVE" "$OUT"

echo "== 2b. without --repo, from the current directory =="
OUT=$(env -C "$T/live-5" HOME="$T/home" bash "$SCRIPT" 2>/dev/null); RC=$?
check "exit 0" 0 "$RC"
check "prints the live root" "$LIVE" "$OUT"

echo "== 3. another repository =="
run "$T/home" --repo "$T/other"
check "exit 1" 1 "$RC"
check "prints nothing" "" "$OUT"

echo "== 4. ~/.claude/bin is not a symlink =="
run "$T/plainhome" --repo "$LIVE"
check "exit 1" 1 "$RC"

echo "== 5. not a repository =="
run "$T/home" --repo "$T/norepo"
check "exit 1" 1 "$RC"

echo "== 6. --help and an unknown argument =="
run "$T/home" --help
check "--help exits 0" 0 "$RC"
run "$T/home" --bogus
check "unknown argument exits 2" 2 "$RC"

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
