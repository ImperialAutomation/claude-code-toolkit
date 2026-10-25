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

echo "== 9. clean removes a plain purpose dir, contents and all =="
D=$(run dir --repo "$REPO" junk-1 2>/dev/null)
mkdir -p "$D/backend/.pytest_cache" && touch "$D/backend/.pytest_cache/x" "$D/.hidden"
run clean --repo "$REPO" junk-1 >/dev/null 2>&1; RC=$?
check "exit 0" "0" "$RC"
check "dir is gone" "no" "$([[ -e "$D" ]] && echo yes || echo no)"

echo "== 10. clean unregisters a worktree instead of orphaning it =="
WT="$T/scratch/acme-webshop/base-7"
echo dirty > "$WT/untracked.txt"   # an untracked file must not block removal
run clean --repo "$REPO" base-7 >/dev/null 2>&1; RC=$?
check "exit 0" "0" "$RC"
check "dir is gone" "no" "$([[ -e "$WT" ]] && echo yes || echo no)"
check "git no longer lists it" "0" \
    "$(git -C "$REPO" worktree list --porcelain | grep -cx "worktree $WT")"
check "no admin entry left in .git/worktrees" "" \
    "$(grep -lx "$WT/.git" "$REPO"/.git/worktrees/*/gitdir 2>/dev/null)"

echo "== 10b. clean also unregisters a locked worktree =="
# `git worktree prune` skips locked entries, so a plain rm -rf + prune would
# orphan this one; only `worktree remove --force --force` takes it out.
WT=$(run worktree --repo "$REPO" locked-1 HEAD 2>/dev/null)
git -C "$REPO" worktree lock "$WT"
run clean --repo "$REPO" locked-1 >/dev/null 2>&1; RC=$?
check "exit 0" "0" "$RC"
check "git no longer lists it" "0" \
    "$(git -C "$REPO" worktree list --porcelain | grep -cx "worktree $WT")"

echo "== 11. clean of something that is not there is not an error =="
OUT=$(run clean --repo "$REPO" never-made 2>&1); RC=$?
check "exit 0" "0" "$RC"
check "says so" "1" "$(grep -c "nothing to clean" <<<"$OUT")"

echo "== 12. clean --all empties this project only =="
run dir --repo "$REPO" a >/dev/null 2>&1
run worktree --repo "$REPO" b HEAD >/dev/null 2>&1
OTHER="$T/Other"; make_repo "$OTHER"
KEEP=$(run dir --repo "$OTHER" keep 2>/dev/null)
run clean --repo "$REPO" --all >/dev/null 2>&1; RC=$?
check "exit 0" "0" "$RC"
check "project dir is gone" "no" "$([[ -e "$T/scratch/acme-webshop" ]] && echo yes || echo no)"
check "worktree b unregistered" "0" \
    "$(git -C "$REPO" worktree list --porcelain | grep -cx "worktree $T/scratch/acme-webshop/b")"
check "other project untouched" "yes" "$([[ -d "$KEEP" ]] && echo yes || echo no)"

echo "== 13. clean reports a dir it could not remove =="
# Stands in for the root-owned files a container leaves in a bind mount on
# native Linux Docker: the rm fails, and that must not be reported as success.
D=$(run dir --repo "$REPO" stuck 2>/dev/null)
mkdir -p "$D/locked" && touch "$D/locked/f" && chmod 555 "$D/locked"
OUT=$(run clean --repo "$REPO" stuck 2>&1); RC=$?
chmod 755 "$D/locked"
check "exit 1" "1" "$RC"
check "names the dir" "1" "$(grep -c "$D" <<<"$OUT")"

echo "== 14. clean usage errors =="
run clean --repo "$REPO" >/dev/null 2>&1; check "no target" "2" "$?"
run clean --repo "$REPO" --all x >/dev/null 2>&1; check "--all plus a purpose" "2" "$?"
run clean --repo "$REPO" ../Other >/dev/null 2>&1; check "escaping purpose" "2" "$?"
check "other project still untouched" "yes" "$([[ -d "$KEEP" ]] && echo yes || echo no)"

echo "== 15. clean removes a symlink as a link, never what it points at =="
# A link to a linked worktree elsewhere is the dangerous case: following it,
# `git worktree remove` would delete that outside checkout.
VICTIM="$T/Victim"; make_repo "$VICTIM"
git -C "$VICTIM" worktree add -q --detach "$T/outside-wt" HEAD 2>/dev/null
mkdir -p "$T/outside-plain" && touch "$T/outside-plain/keep"
LREPO="$T/Linky"; make_repo "$LREPO"
LDIR=$(dirname "$(run dir --repo "$LREPO" real 2>/dev/null)")
ln -s "$T/outside-wt" "$LDIR/to-wt"
ln -s "$T/outside-plain" "$LDIR/to-plain"
ln -s "$T/does-not-exist" "$LDIR/dangling"
run clean --repo "$LREPO" to-wt >/dev/null 2>&1; check "single: exit 0" "0" "$?"
check "single: link gone" "no" "$([[ -L "$LDIR/to-wt" ]] && echo yes || echo no)"
check "single: outside worktree intact" "yes" "$([[ -f "$T/outside-wt/.git" ]] && echo yes || echo no)"
check "single: still registered in its repo" "1" "$(git -C "$VICTIM" worktree list | grep -c "outside-wt")"
run clean --repo "$LREPO" dangling >/dev/null 2>&1; check "dangling: exit 0" "0" "$?"
check "dangling: link gone" "no" "$([[ -L "$LDIR/dangling" ]] && echo yes || echo no)"
ln -s "$T/outside-wt" "$LDIR/to-wt"
run clean --repo "$LREPO" --all >/dev/null 2>&1; check "--all: exit 0" "0" "$?"
check "--all: project dir gone" "no" "$([[ -e "$LDIR" ]] && echo yes || echo no)"
check "--all: outside worktree intact" "yes" "$([[ -f "$T/outside-wt/.git" ]] && echo yes || echo no)"
check "--all: outside plain dir intact" "yes" "$([[ -f "$T/outside-plain/keep" ]] && echo yes || echo no)"

echo "== 16. clean refuses a symlinked project dir =="
SREPO="$T/Swapped"; make_repo "$SREPO"
mkdir -p "$T/elsewhere/p" && ln -s "$T/elsewhere" "$CLAUDE_SCRATCH_ROOT/swapped"
run clean --repo "$SREPO" --all >/dev/null 2>&1; check "--all: exit 1" "1" "$?"
run clean --repo "$SREPO" p >/dev/null 2>&1; check "single: exit 1" "1" "$?"
check "target dir intact" "yes" "$([[ -d "$T/elsewhere/p" ]] && echo yes || echo no)"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
