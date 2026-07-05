#!/usr/bin/env bash
# Print files (or full diff) changed on the current branch vs its base branch.
# Resolves the merge-base internally so callers never need $(...) substitution
# — which the Bash permission matcher blocks. Matches Bash(~/.claude/bin/*).
#
# Usage:
#   git-diff-base.sh                 # names of changed files vs auto-detected base
#   git-diff-base.sh develop         # vs a specific base branch (positional)
#   git-diff-base.sh --base develop  # vs a specific base branch (flag form)
#   git-diff-base.sh --stat          # diffstat instead of names
#   git-diff-base.sh --patch         # full patch
#   git-diff-base.sh --repo DIR ...  # run git in repository DIR (avoids a leading
#                                    # `cd`, which would break the allow-match)
#
# When no base is given (positional or --base), it is resolved via
# git-find-base-branch. Works from a detached HEAD or a branch with no
# upstream, since resolution only inspects local branches.
set -euo pipefail

base=""
mode="--name-only"
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --stat)  mode="--stat";  shift ;;
    --patch) mode="";        shift ;;
    --name-only) mode="--name-only"; shift ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *) base="$1"; shift ;;
  esac
done

# Switch into the repository if requested, before any git command.
if [[ -n "$repo" ]]; then
  cd "$repo" || { echo "Error: cannot cd into repo '$repo'" >&2; exit 1; }
fi

if [[ -z "$base" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  base="$("$script_dir/git-find-base-branch")" || { echo "Error: could not auto-detect base branch — pass one explicitly" >&2; exit 1; }
fi

mb="$(git merge-base HEAD "$base")"
# shellcheck disable=SC2086  # $mode is intentionally word-split (may be empty)
git diff $mode "$mb"..HEAD
