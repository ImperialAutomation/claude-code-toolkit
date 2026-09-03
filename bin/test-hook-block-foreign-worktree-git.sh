#!/usr/bin/env bash
# Standalone tests for hook-block-foreign-worktree-git.sh.
#
# Builds a throwaway repository with a linked worktree plus an unrelated repo,
# then feeds the hook a set of commands and checks its exit code:
#   0 = allow, 2 = block.
#
# Usage: bin/test-hook-block-foreign-worktree-git.sh
set -uo pipefail

HOOK="$(dirname "$(readlink -f "$0")")/hook-block-foreign-worktree-git.sh"
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# Two worktrees of one repository, plus a separate repository that merely looks
# similar — the hook must treat the sibling as dangerous and the stranger as not.
git init -q "$BASE/main"
cd "$BASE/main"
git config user.email test@example.com
git config user.name test
echo hi > f.txt
git add f.txt
git commit -qm init
git worktree add -q "$BASE/wt" -b other

git init -q "$BASE/unrelated"
cd "$BASE/unrelated"
git config user.email test@example.com
git config user.name test
echo hi > f.txt
git add f.txt
git commit -qm init

cd "$BASE/main"

fail=0
check() { # want_exit description command
  local want=$1 desc=$2 cmd=$3 got
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
    | "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    echo "ok   ($got) $desc"
  else
    echo "FAIL want $want got $got: $desc"
    fail=1
  fi
}

# Blocked: destructive verbs aimed at a sibling worktree of the same repo.
check 2 "checkout -- files in sibling worktree" "git -C $BASE/wt checkout -- f.txt"
check 2 "checkout -f in sibling worktree"       "git -C $BASE/wt checkout -f"
check 2 "restore in sibling worktree"           "git -C $BASE/wt restore f.txt"
check 2 "reset --hard in sibling worktree"      "git -C $BASE/wt reset --hard"
check 2 "clean -fd in sibling worktree"         "git -C $BASE/wt clean -fd"
check 2 "bare stash in sibling worktree"        "git -C $BASE/wt stash"
check 2 "destructive command later in a chain"  "cd /tmp && git -C $BASE/wt reset --hard"

# Allowed: read-only stash verbs.
check 0 "stash list is read-only"               "git -C $BASE/wt stash list"
check 0 "stash show is read-only"               "git -C $BASE/wt stash show"

# Allowed: out of scope.
check 0 "same tree via explicit -C"             "git -C $BASE/main checkout -- f.txt"
check 0 "no -C target at all"                   "git checkout -- f.txt"
# The natural way to work in another worktree: cd there, then run plain git.
# No -C, so it never reaches the scope check — this is the spelling that keeps
# working when the redundant `cd <wt> && git -C <wt> ...` form gets blocked.
check 0 "cd into worktree, then plain git"      "cd $BASE/wt && git reset --hard"
check 0 "unrelated repository"                  "git -C $BASE/unrelated reset --hard"
check 0 "non-destructive verb"                  "git -C $BASE/wt status"
check 0 "not a git command"                     "ls -la"
check 0 "target path does not exist"            "git -C $BASE/nope reset --hard"

if [ $fail -eq 0 ]; then
  echo "all tests passed"
else
  echo "some tests failed"
fi
exit $fail
