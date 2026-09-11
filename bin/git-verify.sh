#!/usr/bin/env bash
# Read-only git status snapshot in one call — avoids a permission prompt per
# individual command, which is the dominant friction during long epic runs.
#
# Usage: git-verify.sh [repo-dir | --repo <dir>] [--base <branch>] [--alembic]
#   repo-dir   defaults to the current directory
#   --repo     same thing, named. Preferred when an agent calls this: a working
#              directory resets between commands, so "." is whichever tree the
#              session started in, not necessarily the one being worked on.
#              Naming the target makes a wrong one visible in the command itself
#   --base     also show commits on HEAD not in <branch>, and vice versa
#   --alembic  also show alembic heads (fails loudly if more than one)
#
# Naming the same tree twice is fine; naming two different ones is an error
# rather than a silent pick, because the loser is a tree the caller believed
# they were looking at.
#
# Examples:
#   git-verify.sh
#   git-verify.sh --repo ~/Projects/Acme --base develop --alembic
#   git-verify.sh ~/Projects/Acme --base develop --alembic
#
# Read-only by design: it never writes, fetches, checks out or stashes.
set -euo pipefail

repo=""
base=""
want_alembic=0

# Track how the target was given so a second, conflicting one can be rejected.
# Previously any unrecognised argument fell into the catch-all and overwrote
# `repo`, so a typo (or a flag this script does not know) silently became the
# target directory instead of an error.
set_repo() { # path source
  if [[ -n "$repo" && "$repo" != "$1" ]]; then
    echo "git-verify: two different targets given ($repo and $1)" >&2
    exit 1
  fi
  repo="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    [[ $# -ge 2 ]] || { echo "git-verify: --repo needs a directory" >&2; exit 1; }
               set_repo "$2"; shift 2 ;;
    --base)    base="${2:-}"; shift 2 ;;
    --alembic) want_alembic=1; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    -*)        echo "git-verify: unknown option: $1" >&2; exit 1 ;;
    *)         set_repo "$1"; shift ;;
  esac
done

repo="${repo:-.}"

[[ -d "$repo" ]] || { echo "git-verify: no such directory: $repo" >&2; exit 1; }
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "git-verify: not a git repository: $repo" >&2; exit 1; }

branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
echo "=== branch ==="
echo "$branch"

echo
echo "=== uncommitted (tracked) ==="
# Untracked files are omitted: sandbox dotfile-masking makes that list noisy.
if [[ -n "$(git -C "$repo" status --short --untracked-files=no)" ]]; then
  git -C "$repo" status --short --untracked-files=no
else
  echo "(clean)"
fi

echo
echo "=== recent commits ==="
git -C "$repo" log --oneline -5

upstream="$(git -C "$repo" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
if [[ -n "$upstream" ]]; then
  echo
  echo "=== vs upstream ($upstream) ==="
  ahead=$(git -C "$repo" rev-list --count "$upstream..HEAD" 2>/dev/null || echo "?")
  behind=$(git -C "$repo" rev-list --count "HEAD..$upstream" 2>/dev/null || echo "?")
  echo "ahead: $ahead   behind: $behind"
  # Unpushed work is the thing worth seeing at a glance: it is what a dying
  # background agent loses.
  if [[ "$ahead" != "0" && "$ahead" != "?" ]]; then
    git -C "$repo" log --oneline "$upstream..HEAD"
  fi
else
  echo
  echo "=== vs upstream ==="
  echo "(no upstream configured — nothing pushed yet)"
fi

if [[ -n "$base" ]]; then
  echo
  echo "=== vs $base ==="
  if git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null; then
    n=$(git -C "$repo" rev-list --count "$base..HEAD")
    echo "commits on HEAD not in $base: $n"
    # Capped: a long-running feature branch can be 50+ commits ahead, and
    # dumping them all is the context cost this script exists to avoid.
    if [[ "$n" != "0" ]]; then
      git -C "$repo" log --oneline -10 "$base..HEAD"
      if [[ "$n" -gt 10 ]]; then echo "... and $((n - 10)) more"; fi
    fi
  else
    echo "(branch not found: $base)"
  fi
fi

stashes=$(git -C "$repo" stash list 2>/dev/null || true)
if [[ -n "$stashes" ]]; then
  echo
  echo "=== stashes ==="
  echo "$stashes"
fi

worktrees=$(git -C "$repo" worktree list 2>/dev/null | tail -n +2 || true)
if [[ -n "$worktrees" ]]; then
  echo
  echo "=== extra worktrees ==="
  echo "$worktrees"
fi

if [[ "$want_alembic" -eq 1 ]]; then
  echo
  echo "=== alembic heads ==="
  alembic_bin=""
  for candidate in "$repo/backend/.venv/bin/alembic" "$repo/.venv/bin/alembic"; do
    [[ -x "$candidate" ]] && { alembic_bin="$candidate"; break; }
  done
  if [[ -z "$alembic_bin" ]]; then
    echo "(no venv alembic found)"
  else
    alembic_dir=$(dirname "$(dirname "$(dirname "$alembic_bin")")")
    heads=$("$alembic_bin" -c "$alembic_dir/alembic.ini" heads 2>&1 | grep -c "(head)" || true)
    "$alembic_bin" -c "$alembic_dir/alembic.ini" heads 2>&1 | tail -5
    # More than one head means a branched revision history — it breaks every
    # later migration in the run, so surface it rather than letting it pass.
    [[ "$heads" -gt 1 ]] && echo "WARNING: $heads heads — revision history has branched"
  fi
fi

exit 0
