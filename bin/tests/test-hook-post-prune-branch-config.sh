#!/bin/bash
# Tests for hook-post-prune-branch-config.sh.
#
# Usage:
#   bin/tests/test-hook-post-prune-branch-config.sh
#
# Exercises the hook against throwaway git repos in a temp dir. Nothing outside
# that temp dir is touched. Exits non-zero if any expectation fails.
#
# A branch deleted inside the sandbox loses its ref but keeps its config
# section. The tests reproduce that state with `update-ref -d`, which removes
# the ref and leaves the config alone.
#
# The hook writes to the repository config, so the cases that prove what it
# must NOT remove (an existing branch, a worktree branch, core/remote sections,
# a command that deleted nothing) carry as much weight as the removal itself.

# SC2088: the `~/` in command strings below is literal on purpose; it is the
# text the hook receives, not a path this script uses.
# shellcheck disable=SC2088
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${HOOK_UNDER_TEST:-$SCRIPT_DIR/../hook-post-prune-branch-config.sh}"

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

fire() { # cwd command  — feed the hook a PostToolUse payload, print its exit code
    printf '{"tool_input":{"command":%s},"cwd":%s}' \
        "$(jq -Rn --arg c "$2" '$c')" "$(jq -Rn --arg d "$1" '$d')" | bash "$HOOK" 2>/dev/null
    echo $?
}

newrepo() {
    local d="$T/$1"; mkdir -p "$d"; git -C "$d" init -q
    git -C "$d" config user.email t@t; git -C "$d" config user.name T
    echo x > "$d/f"; git -C "$d" add f; git -C "$d" commit -qm base
    echo "$d"
}

# A branch with upstream config, as `push -u` or `checkout --track` writes it.
tracked_branch() { # repo name
    git -C "$1" branch -q "$2"
    git -C "$1" config "branch.$2.remote" origin
    git -C "$1" config "branch.$2.merge" "refs/heads/$2"
}

# What a sandboxed `git branch -d` leaves behind: ref gone, section kept.
sandbox_delete() { # repo name
    git -C "$1" update-ref -d "refs/heads/$2"
}

has_section() { # repo name
    git -C "$1" config --get "branch.$2.remote" >/dev/null && echo yes || echo no
}

echo "== 1. deleted branch -> section removed =="
R=$(newrepo r1); tracked_branch "$R" gone; sandbox_delete "$R" gone
fire "$R" "git -C $R branch -d gone" >/dev/null
check "stale section removed" no "$(has_section "$R" gone)"

echo "== 2. existing branch -> section kept =="
R=$(newrepo r2); tracked_branch "$R" alive; tracked_branch "$R" gone; sandbox_delete "$R" gone
fire "$R" "git branch -D gone" >/dev/null
check "live section kept" yes "$(has_section "$R" alive)"
check "stale section removed" no "$(has_section "$R" gone)"

echo "== 3. core and remote sections untouched =="
R=$(newrepo r3); git -C "$R" remote add origin "$T/nowhere.git"
git -C "$R" config core.hooksPath /some/where
tracked_branch "$R" gone; sandbox_delete "$R" gone
fire "$R" "git branch --delete gone" >/dev/null
check "core.hooksPath kept" /some/where "$(git -C "$R" config core.hooksPath)"
check "remote.origin.url kept" "$T/nowhere.git" "$(git -C "$R" config remote.origin.url)"
check "stale section removed" no "$(has_section "$R" gone)"

echo "== 4. command that deletes no branch -> nothing removed =="
R=$(newrepo r4); tracked_branch "$R" gone; sandbox_delete "$R" gone
for cmd in "git -C $R branch --list" "git -C $R log --oneline" "git -C $R branch -v" \
           "git -C $R branch --show-current" "echo git branch -d gone"; do
    fire "$R" "$cmd" >/dev/null
    check "kept after: $cmd" yes "$(has_section "$R" gone)"
done
fire "$R" "git status; git branch -d gone" >/dev/null
check "removed when the delete follows a separator" no "$(has_section "$R" gone)"

echo "== 5. cleanup script triggers the hook =="
R=$(newrepo r5); tracked_branch "$R" gone; sandbox_delete "$R" gone
fire "$R" "~/.claude/bin/git-cleanup-merged-branch.sh gone develop" >/dev/null
check "stale section removed" no "$(has_section "$R" gone)"

echo "== 6. combined flags (-df) trigger the hook =="
R=$(newrepo r6); tracked_branch "$R" gone; sandbox_delete "$R" gone
fire "$R" "git branch -df gone" >/dev/null
check "stale section removed" no "$(has_section "$R" gone)"

echo "== 7. repo resolution: -C and --repo win over cwd =="
R=$(newrepo r7); tracked_branch "$R" gone; sandbox_delete "$R" gone
OTHER=$(newrepo r7-other); tracked_branch "$OTHER" gone; sandbox_delete "$OTHER" gone
fire "$OTHER" "git -C $R branch -d gone" >/dev/null
check "-C repo cleaned" no "$(has_section "$R" gone)"
check "cwd repo untouched" yes "$(has_section "$OTHER" gone)"
R=$(newrepo r7b); tracked_branch "$R" gone; sandbox_delete "$R" gone
fire "$OTHER" "~/.claude/bin/git-cleanup-merged-branch.sh --repo $R" >/dev/null
check "--repo cleaned" no "$(has_section "$R" gone)"

echo "== 8. branch names with / and . =="
R=$(newrepo r8)
tracked_branch "$R" feature/x; sandbox_delete "$R" feature/x
tracked_branch "$R" release-1.2; sandbox_delete "$R" release-1.2
tracked_branch "$R" release-1.3
fire "$R" "git branch -d feature/x release-1.2" >/dev/null
check "feature/x removed" no "$(has_section "$R" feature/x)"
check "release-1.2 removed" no "$(has_section "$R" release-1.2)"
check "release-1.3 kept" yes "$(has_section "$R" release-1.3)"

echo "== 9. linked worktree: shared config cleaned, worktree branch kept =="
R=$(newrepo r9); tracked_branch "$R" gone; sandbox_delete "$R" gone
git -C "$R" worktree add -q -b wt-branch "$T/r9-wt" 2>/dev/null
git -C "$R" config branch.wt-branch.remote origin
fire "$T/r9-wt" "git branch -d gone" >/dev/null
check "stale section removed via worktree" no "$(has_section "$R" gone)"
check "worktree branch section kept" yes "$(has_section "$R" wt-branch)"

echo "== 10. garbage input -> exit 0 =="
check "empty payload" 0 "$(echo '' | bash "$HOOK" 2>/dev/null; echo $?)"
check "no command" 0 "$(echo '{"cwd":"/"}' | bash "$HOOK" 2>/dev/null; echo $?)"
check "not a repo" 0 "$(fire "$T" "git branch -d x")"
check "missing dir" 0 "$(fire "$T/does-not-exist" "git branch -d x")"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
