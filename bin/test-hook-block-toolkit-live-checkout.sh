#!/usr/bin/env bash
# Standalone tests for hook-block-toolkit-live-checkout.sh.
#
# Builds a throwaway toolkit repository made live through a fake $HOME whose
# .claude/bin symlinks into it, plus a linked worktree and an unrelated repo,
# then feeds the hook a set of commands and checks its exit code:
#   0 = allow, 2 = block.
#
# Usage: bin/test-hook-block-toolkit-live-checkout.sh
set -uo pipefail

HOOK="$(dirname "$(readlink -f "$0")")/hook-block-toolkit-live-checkout.sh"
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# The live checkout on main, with an existing feature branch to switch to and a
# tracked file for path checkouts.
TK="$BASE/toolkit"
git init -q -b main "$TK"
git -C "$TK" config user.email test@example.com
git -C "$TK" config user.name test
mkdir -p "$TK/bin"
echo hi > "$TK/f.txt"
touch "$TK/bin/tool.sh"
git -C "$TK" add f.txt bin/tool.sh
git -C "$TK" commit -qm init
git -C "$TK" branch feature
SHA=$(git -C "$TK" rev-parse HEAD)
WT="$BASE/toolkit-7"
git -C "$TK" worktree add -q -b issue-7-x "$WT"

OTHER="$BASE/unrelated"
git init -q -b main "$OTHER"
git -C "$OTHER" config user.email test@example.com
git -C "$OTHER" config user.name test
git -C "$OTHER" commit -q --allow-empty -m init

LIVE_HOME="$BASE/home"
mkdir -p "$LIVE_HOME/.claude"
ln -s "$TK/bin" "$LIVE_HOME/.claude/bin"
PLAIN_HOME="$BASE/plain-home"
mkdir -p "$PLAIN_HOME/.claude/bin"

fail=0
LAST_STDERR=""
check() { # want_exit description cwd command [home]
  local want=$1 desc=$2 cwd=$3 cmd=$4 home=${5:-$LIVE_HOME} got
  LAST_STDERR=$(printf '{"cwd":%s,"tool_input":{"command":%s}}' \
      "$(printf '%s' "$cwd" | jq -Rs .)" "$(printf '%s' "$cmd" | jq -Rs .)" \
    | (cd "$BASE" && HOME="$home" "$HOOK") 2>&1 >/dev/null)
  got=$?
  if [ "$got" = "$want" ]; then
    echo "ok   ($got) $desc"
  else
    echo "FAIL want $want got $got: $desc"
    fail=1
  fi
}

# Blocked: anything that leaves the live checkout off its base branch.
check 2 "checkout -b in the live checkout"        "$TK" "git checkout -b x"
check 2 "checkout -B in the live checkout"        "$TK" "git checkout -B x"
check 2 "checkout --orphan in the live checkout"  "$TK" "git checkout --orphan x"
check 2 "switch -c in the live checkout"          "$TK" "git switch -c x"
check 2 "switch --create in the live checkout"    "$TK" "git switch --create x"
check 2 "checkout an existing branch"             "$TK" "git checkout feature"
check 2 "switch to an existing branch"            "$TK" "git switch feature"
check 2 "checkout a commit (detached)"            "$TK" "git checkout $SHA"
check 2 "switch --detach, even onto main"         "$TK" "git switch --detach main"
check 2 "switch to the previous branch"           "$TK" "git switch -"
check 2 "-C <live> from another repo"             "$OTHER" "git -C $TK switch x"
check 2 "quoted -C <live>"                        "$OTHER" "git -C \"$TK\" checkout feature"
check 2 "cd <live> earlier in the chain"          "$OTHER" "cd $TK && git checkout feature"
check 2 "later segment of a chain"                "$TK" "git status; git checkout -b x"
check 2 "from a subdirectory of the live checkout" "$TK/bin" "git switch feature"
check 2 "global option before the subcommand"     "$TK" "git -c core.x=y checkout -b x"
# git's option parser accepts stuck values and clustered short flags.
check 2 "checkout -b with a stuck value"          "$TK" "git checkout -bx"
check 2 "checkout -b inside a short-flag cluster" "$TK" "git checkout -qb x"
check 2 "switch -c with a stuck value"            "$TK" "git switch -cx"
check 2 "switch -d inside a short-flag cluster"   "$TK" "git switch -qd main"
# A trailing `--` with no pathspec after it still moves HEAD to <branch>.
check 2 "checkout <branch> -- with no path"       "$TK" "git checkout feature --"
# Prefixes that still run git in (or against) the live checkout.
check 2 "env var assignment before git"           "$TK" "FOO=1 git checkout -b x"
check 2 "env before git"                          "$TK" "env FOO=1 git switch feature"
check 2 "env -C <live>"                           "$OTHER" "env -C $TK git switch feature"
check 2 "env --chdir=<live>"                      "$OTHER" "env --chdir=$TK git switch feature"

# The deny reason must name the way out, or the agent improvises one.
check 2 "deny reason probe"                       "$TK" "git checkout -b x"
case "$LAST_STDERR" in
  *"git-resolve-worktree.sh --issue"*"--create"*) echo "ok   deny reason names git-resolve-worktree.sh --create" ;;
  *) echo "FAIL deny reason lacks git-resolve-worktree.sh --create: $LAST_STDERR"; fail=1 ;;
esac
case "$LAST_STDERR" in
  *"git -C $TK worktree add"*) echo "ok   deny reason names git worktree add" ;;
  *) echo "FAIL deny reason lacks git worktree add: $LAST_STDERR"; fail=1 ;;
esac

# Allowed: back to (or staying on) the base branch.
check 0 "checkout main"                           "$TK" "git checkout main"
check 0 "switch main"                             "$TK" "git switch main"
check 0 "-C <live> switch main"                   "$OTHER" "git -C $TK switch main"

# Allowed: path checkouts move no HEAD (hook-block-destructive.sh judges those).
check 0 "checkout -- <path>"                      "$TK" "git checkout -- f.txt"
check 0 "checkout <path> that is no ref"          "$TK" "git checkout f.txt"
check 0 "checkout <branch> -- <path>"             "$TK" "git checkout feature -- f.txt"
check 0 "checkout <branch> <path>"                "$TK" "git checkout feature f.txt"
check 0 "checkout with no argument"               "$TK" "git checkout"
check 0 "checkout <base> -- <path>"               "$TK" "git checkout main -- f.txt"
check 0 "checkout -f <base>"                      "$TK" "git checkout -f main"
check 0 "switch <base> --discard-changes"         "$TK" "git switch main --discard-changes"
check 0 "short-flag cluster without a branch flag" "$TK" "git checkout -qf main"
check 0 "env -C elsewhere"                        "$TK" "env -C $OTHER git switch -c z"

# Allowed: not the live checkout.
check 0 "checkout -b in a linked worktree"        "$WT" "git checkout -b y"
check 0 "switch in a linked worktree"             "$WT" "git switch feature"
check 0 "-C <linked worktree> from the live tree" "$TK" "git -C $WT switch -c z"
check 0 "cd elsewhere, then switch"               "$TK" "cd $OTHER && git switch -c z"
check 0 "another repository"                      "$OTHER" "git checkout -b z"

# Allowed: unrelated commands, and words that merely look like the verbs.
check 0 "git status"                              "$TK" "git status"
check 0 "commit message mentioning switch"        "$TK" "git commit -m 'switch -c later'"
check 0 "not a git command"                       "$TK" "ls -la"

# ~/.claude/bin is not a symlink: nothing is live, the hook does nothing.
check 0 "no symlink: checkout -b"                 "$TK" "git checkout -b x" "$PLAIN_HOME"
check 0 "no symlink: switch feature"              "$TK" "git switch feature" "$PLAIN_HOME"

# The hook must only ever judge, never act.
if [ "$(git -C "$TK" branch --show-current)" = main ]; then
  echo "ok   live checkout still on main"
else
  echo "FAIL live checkout moved"; fail=1
fi

if [ $fail -eq 0 ]; then
  echo "all tests passed"
else
  echo "some tests failed"
fi
exit $fail
