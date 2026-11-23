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

# --- Judged by meaning, not word order (#322, #125) -------------------------
#
# The hook parses each git invocation: global options are skipped, the first
# remaining word is the subcommand, and only that subcommand's own arguments
# are judged. A branch that exists in the repo but is not checked out anywhere
# gives the "switch to an existing branch" cases something to switch to.
git -C "$BASE/main" branch -q spare
git -C "$BASE/main" update-ref refs/remotes/origin/develop HEAD

# Allowed: creating or switching branches never discards work (D2, D3).
check 0 "checkout --no-track -b (option before -b)" "git -C $BASE/wt checkout --no-track -b issue-1-x origin/develop"
check 0 "checkout -b --no-track (option after -b)"  "git -C $BASE/wt checkout -b issue-1-x --no-track origin/develop"
check 0 "switch --no-track -c"                      "git -C $BASE/wt switch --no-track -c issue-1-x origin/develop"
check 0 "checkout --detach"                         "git -C $BASE/wt checkout --detach origin/develop"
check 0 "checkout --orphan"                         "git -C $BASE/wt checkout --orphan x"
check 0 "checkout --track remote branch"            "git -C $BASE/wt checkout --track origin/develop"
check 0 "checkout existing branch (D2)"             "git -C $BASE/wt checkout spare"
check 0 "switch existing branch (D2)"               "git -C $BASE/wt switch spare"
check 0 "checkout DWIM remote-only branch (D2)"     "git -C $BASE/wt checkout develop"
check 0 "checkout - (previous branch)"              "git -C $BASE/wt checkout -"
check 0 "checkout -B (D3)"                          "git -C $BASE/wt checkout -B x origin/develop"
check 0 "switch -C (D3)"                            "git -C $BASE/wt switch -C x origin/develop"

# Allowed: a verb word outside the subcommand position (#125).
check 0 "add a path containing 'restore'"           "git -C $BASE/wt add docs/restore-runbook.md"
check 0 "grep for 'reset'"                          "git -C $BASE/wt grep -e reset"
check 0 "log --grep=clean"                          "git -C $BASE/wt log --grep=clean"
check 0 "show a path containing 'stash'"            "git -C $BASE/wt show HEAD:x/stash.sh"
check 0 "diff -- a path containing 'stash'"         "git -C $BASE/wt diff -- src/stash/"
check 0 "-c value containing a verb"                "git -C $BASE/wt -c alias.x=reset status"

# Blocked: checkout forms that restore paths or force (D4).
check 2 "checkout HEAD -- files"                    "git -C $BASE/wt checkout HEAD -- f.txt"
check 2 "checkout --force"                          "git -C $BASE/wt checkout --force"
check 2 "checkout -f with a branch"                 "git -C $BASE/wt checkout -f spare"
check 2 "checkout -qf (short cluster)"              "git -C $BASE/wt checkout -qf spare"
check 2 "checkout --forc (abbreviated --force)"     "git -C $BASE/wt checkout --forc spare"
check 2 "checkout -B with --force"                  "git -C $BASE/wt checkout -B x --force origin/develop"
check 2 "checkout a path, no ref (D4)"              "git -C $BASE/wt checkout f.txt"
check 2 "checkout <ref> <path> (D4)"                "git -C $BASE/wt checkout HEAD f.txt"
check 2 "checkout . (D4)"                           "git -C $BASE/wt checkout ."
check 2 "checkout -p (interactive path restore)"    "git -C $BASE/wt checkout -p"
check 2 "switch -f"                                 "git -C $BASE/wt switch -f spare"
check 2 "switch --force"                            "git -C $BASE/wt switch --force spare"
check 2 "switch --discard-changes"                  "git -C $BASE/wt switch --discard-changes spare"
check 2 "stash push"                                "git -C $BASE/wt stash push"
check 2 "stash -u (implicit push)"                  "git -C $BASE/wt stash -u"
check 2 "stash clear"                               "git -C $BASE/wt stash clear"

# Blocked: judged per invocation, so a chain or global options do not hide it.
check 2 "destructive second invocation in a chain"  "git -C $BASE/wt add x && git -C $BASE/wt reset --hard"
check 2 "harmless first target, foreign second"     "git -C $BASE/main reset --hard; git -C $BASE/wt reset --hard"
check 2 "global options before the subcommand"      "git -C $BASE/wt -c core.x=y --no-pager reset --hard"
check 2 "-C written as -C=<dir>"                    "git -C=$BASE/wt reset --hard"
check 2 "quoted -C target"                          "git -C \"$BASE/wt\" reset --hard"
check 2 "inside a command substitution"             "echo \$(git -C $BASE/wt reset --hard)"
check 2 "backslash-newline continuation"            "git -C $BASE/wt \\
  reset --hard"
check 0 "foreign harmless, own destructive"         "git -C $BASE/wt status && git -C $BASE/main reset --hard"
check 0 "make -C is not git"                        "make -C $BASE/wt clean"

# Allowed: read-only stash verbs.
check 0 "stash list is read-only"               "git -C $BASE/wt stash list"
check 0 "stash show is read-only"               "git -C $BASE/wt stash show"

# --- Restoring a stash raised elsewhere -------------------------------------
#
# refs/stash is ONE stack shared by every worktree of the repository; a linked
# worktree gets no private copy. So a stash raised in one tree is visible — and
# poppable — from all the others, and `pop` applies it to whatever branch the
# caller happens to be on.
#
# The same-tree rule below cannot cover this: at the moment of the pop the target
# and the caller ARE the same tree. What makes it dangerous is the stash's
# ORIGIN, which the entry records as "On <branch>: ...".
#
# Fixture: stash something while on branch `other` in the linked worktree, then
# ask about popping it from `main`, which is on a different branch.
(
  cd "$BASE/wt" || exit 1
  echo changed >> f.txt
  git stash push -q -m "raised-in-wt"
) >/dev/null 2>&1

check 2 "pop a stash raised on another branch"   "git -C $BASE/main stash pop"
check 2 "apply a stash raised on another branch" "git -C $BASE/main stash apply"
check 2 "drop a stash raised on another branch"  "git -C $BASE/main stash drop"
check 2 "pop by explicit ref"                    "git -C $BASE/main stash pop stash@{0}"

# Not over-blocking: from the tree whose branch the stash was raised on, the
# entry is the caller's own and restoring it is ordinary work.
check 0 "pop from the branch it was raised on"   "git -C $BASE/wt stash pop"
check 0 "apply from the branch it was raised on" "git -C $BASE/wt stash apply"

# Inspecting the shared stack stays free from anywhere — that is how you find out
# whose entry it is before touching it.
check 0 "stash list from the other tree"         "git -C $BASE/main stash list"
check 0 "stash show from the other tree"         "git -C $BASE/main stash show stash@{0}"

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

# An empty stack has no origin to compare against, so there is nothing to judge;
# git will report "No stash entries found" itself. Checked in the unrelated repo,
# which never had a stash raised in it.
check 0 "pop with an empty stash stack"        "git -C $BASE/unrelated stash pop"

if [ $fail -eq 0 ]; then
  echo "all tests passed"
else
  echo "some tests failed"
fi
exit $fail
