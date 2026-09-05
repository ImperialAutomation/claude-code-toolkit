#!/bin/bash
# Tests for hook-post-commit-trailer.sh.
#
# Usage:
#   bin/tests/test-hook-post-commit-trailer.sh
#
# Exercises the hook against throwaway git repos in a temp dir. Nothing outside
# that temp dir is touched. Exits non-zero on the first failing expectation.
#
# The hook rewrites commits (git commit --amend), so the guards that stop it
# from rewriting the WRONG commit are the load-bearing part. Cases 3-6 and 9
# exist for those guards specifically: case 9 (already pushed) is what keeps the
# hook from rewriting published history, and it was added after a mutation run
# showed the suite stayed green with that guard deleted.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${HOOK_UNDER_TEST:-$SCRIPT_DIR/../hook-post-commit-trailer.sh}"

if [[ ! -f "$HOOK" ]]; then
    echo "hook not found: $HOOK" >&2
    exit 1
fi

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected $2, got $3)"; FAIL=$((FAIL+1)); fi
}

has_trailer() {
    git -C "$1" log -1 --format='%B' | grep -qi "^Co-Authored-By:" && echo yes || echo no
}

fire() { # repodir command  — feed the hook a PostToolUse payload
    printf '{"tool_input":{"command":%s},"cwd":%s}' \
        "$(jq -Rn --arg c "$2" '$c')" "$(jq -Rn --arg d "$1" '$d')" | bash "$HOOK" 2>/dev/null
}

newrepo() {
    local d="$T/$1"; mkdir -p "$d"; git -C "$d" init -q
    git -C "$d" config user.email t@t; git -C "$d" config user.name T
    echo x > "$d/f"; git -C "$d" add f
    echo "$d"
}

echo "== 1. plain commit without trailer -> added =="
R=$(newrepo r1); git -C "$R" commit -qm "feat: thing"
fire "$R" "git -C $R commit -m 'feat: thing'"
check "trailer added" yes "$(has_trailer "$R")"

echo "== 2. commit that already has a trailer -> untouched =="
R=$(newrepo r2)
git -C "$R" commit -qm "feat: thing

Co-Authored-By: Someone <s@example.com>"
BEFORE=$(git -C "$R" rev-parse HEAD)
fire "$R" "git -C $R commit -m x"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"

echo "== 3. non-commit bash call -> untouched =="
R=$(newrepo r3); git -C "$R" commit -qm "feat: thing"
BEFORE=$(git -C "$R" rev-parse HEAD)
fire "$R" "git -C $R log --oneline -5"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
check "no trailer added" no "$(has_trailer "$R")"

echo "== 4. old commit (>120s) -> untouched =="
R=$(newrepo r4)
GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$R" commit -qm "feat: old" --date "2020-01-01T00:00:00"
BEFORE=$(git -C "$R" rev-parse HEAD)
fire "$R" "git -C $R commit -m x"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"

echo "== 5. merge commit -> untouched =="
R=$(newrepo r5); git -C "$R" commit -qm base
git -C "$R" checkout -qb side; echo y > "$R/g"; git -C "$R" add g; git -C "$R" commit -qm side
git -C "$R" checkout -q master 2>/dev/null || git -C "$R" checkout -q main
echo z > "$R/h"; git -C "$R" add h; git -C "$R" commit -qm mainline
git -C "$R" merge --no-ff -q side -m "Merge branch 'side'" 2>/dev/null
BEFORE=$(git -C "$R" rev-parse HEAD)
fire "$R" "git -C $R commit -m x"
check "merge untouched" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"

echo "== 6. --no-edit amend -> untouched (no loop) =="
R=$(newrepo r6); git -C "$R" commit -qm "feat: thing"
BEFORE=$(git -C "$R" rev-parse HEAD)
fire "$R" "git -C $R commit --amend --no-edit"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"

echo "== 7. wrapper-script form -> added =="
R=$(newrepo r7); git -C "$R" commit -qm "feat: thing"
fire "$R" "cd $R; ~/.claude/bin/git-commit.sh 'feat: thing'"
check "trailer added" yes "$(has_trailer "$R")"

echo "== 8. cwd fallback (no -C in command) -> added =="
R=$(newrepo r8); git -C "$R" commit -qm "feat: thing"
fire "$R" "git commit -m 'feat: thing'"
check "trailer added via cwd" yes "$(has_trailer "$R")"

echo "== 9. already pushed to a remote -> untouched (no history rewrite) =="
R=$(newrepo r9); git -C "$R" commit -qm "feat: thing"
BARE="$T/r9-remote.git"; git init -q --bare "$BARE"
git -C "$R" remote add origin "$BARE"
git -C "$R" push -q origin HEAD 2>/dev/null
BEFORE=$(git -C "$R" rev-parse HEAD)
fire "$R" "git -C $R commit -m 'feat: thing'"
check "pushed commit untouched" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
