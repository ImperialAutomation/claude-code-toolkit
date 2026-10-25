#!/bin/bash
# Tests for docker-scratch.sh.
#
# Usage:
#   bin/tests/test-docker-scratch.sh
#
# Every run points CLAUDE_SCRATCH_ROOT at a temp directory, so the real
# ~/.cache/claude-scratch is never touched. The repos are real git repos with a
# real linked worktree: the point of `clean` over a bare `rm -rf` is that it
# also unregisters the worktree, and only git itself can show whether it did.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../docker-scratch.sh}"

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

export CLAUDE_SCRATCH_ROOT="$T/scratch"
run() { bash "$SCRIPT" "$@"; }

make_repo() { # dir
    git init -q -b main "$1"
    git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
    git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m second
}

REPO="$T/Acme_Webshop"
make_repo "$REPO"

echo "== 1. dir creates <root>/<project>/<purpose> and prints it =="
OUT=$(run dir --repo "$REPO" base-42 2>/dev/null); RC=$?
check "exit 0" "0" "$RC"
check "printed path" "$T/scratch/acme-webshop/base-42" "$OUT"
check "directory exists" "yes" "$([[ -d "$OUT" ]] && echo yes || echo no)"
check "second call is idempotent" "$OUT" "$(run dir --repo "$REPO" base-42 2>/dev/null)"
check "--repo=D form" "$OUT" "$(run dir --repo="$REPO" base-42 2>/dev/null)"

echo "== 2. a linked worktree maps to the same project as its main tree =="
git -C "$REPO" worktree add -q "$T/Acme_Webshop-dev1" -b dev1 2>/dev/null
check "worktree shares the project dir" "$T/scratch/acme-webshop/x" \
    "$(run dir --repo "$T/Acme_Webshop-dev1" x 2>/dev/null)"

echo "== 3. without --repo the current directory decides =="
check "cwd repo" "$T/scratch/acme-webshop/y" "$(cd "$REPO" && run dir y 2>/dev/null)"
mkdir -p "$T/Plain Dir"
check "non-git dir uses its basename" "$T/scratch/plain-dir/z" \
    "$(cd "$T/Plain Dir" && run dir z 2>/dev/null)"

echo "== 4. a purpose that could escape the root is refused =="
for bad in "../evil" "a/b" ".." ".hidden" "" "-rf"; do
    run dir --repo "$REPO" "$bad" >/dev/null 2>&1; RC=$?
    check "refused: '$bad'" "2" "$RC"
done
check "nothing created outside the root" "no" "$([[ -e "$T/evil" ]] && echo yes || echo no)"

echo "== 5. usage errors =="
run >/dev/null 2>&1; check "no subcommand" "2" "$?"
run bogus x >/dev/null 2>&1; check "unknown subcommand" "2" "$?"
run dir --repo "$T/missing" x >/dev/null 2>&1; check "missing --repo dir" "2" "$?"

echo "== 6. worktree checks out <ref> detached at the purpose dir =="
FIRST=$(git -C "$REPO" rev-parse HEAD~1)
OUT=$(run worktree --repo "$REPO" base-7 HEAD~1 2>/dev/null); RC=$?
check "exit 0" "0" "$RC"
check "printed path" "$T/scratch/acme-webshop/base-7" "$OUT"
check "checkout is at <ref>" "$FIRST" "$(git -C "$OUT" rev-parse HEAD 2>/dev/null)"
check "HEAD is detached" "" "$(git -C "$OUT" branch --show-current 2>/dev/null)"
check "git lists it as a worktree" "1" \
    "$(git -C "$REPO" worktree list --porcelain | grep -cx "worktree $OUT")"
check "the main tree's branch is untouched" "main" "$(git -C "$REPO" branch --show-current)"

echo "== 7. worktree refuses a purpose dir that already exists =="
run worktree --repo "$REPO" base-7 HEAD >/dev/null 2>&1; RC=$?
check "exit 1" "1" "$RC"
check "existing checkout unchanged" "$FIRST" "$(git -C "$OUT" rev-parse HEAD 2>/dev/null)"

echo "== 8. worktree needs a git repo and a valid ref =="
run worktree --repo "$T/Plain Dir" w HEAD >/dev/null 2>&1; check "non-git --repo" "2" "$?"
run worktree --repo "$REPO" bad-ref no-such-ref >/dev/null 2>&1; check "unknown ref" "1" "$?"
check "no dir left after a failed ref" "no" \
    "$([[ -e "$T/scratch/acme-webshop/bad-ref" ]] && echo yes || echo no)"
run worktree --repo "$REPO" only-purpose >/dev/null 2>&1; check "missing ref" "2" "$?"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
