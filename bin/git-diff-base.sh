#!/usr/bin/env bash
# Print files (or full diff) changed on the current branch vs its base branch.
# Resolves the merge-base internally so callers never need $(...) substitution
# — which the Bash permission matcher blocks. Matches Bash(~/.claude/bin/*).
#
# Usage:
#   git-diff-base.sh                 # names of changed files vs base (default: main)
#   git-diff-base.sh --base develop  # vs a specific base branch
#   git-diff-base.sh --stat          # diffstat instead of names
#   git-diff-base.sh --patch         # full patch
#   git-diff-base.sh --repo DIR ...  # run git in repository DIR (avoids a leading
#                                    # `cd`, which would break the allow-match)
set -euo pipefail

base="main"
mode="--name-only"
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --stat)  mode="--stat";  shift ;;
    --patch) mode="";        shift ;;
    --name-only) mode="--name-only"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Switch into the repository if requested, before any git command.
if [[ -n "$repo" ]]; then
  cd "$repo" || { echo "Error: cannot cd into repo '$repo'" >&2; exit 1; }
fi

mb="$(git merge-base HEAD "$base")"
# shellcheck disable=SC2086  # $mode is intentionally word-split (may be empty)
git diff $mode "$mb"..HEAD
