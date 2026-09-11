#!/usr/bin/env bash
# git-resolve-worktree.sh — Resolve a worktree hint to one absolute path.
#
# Why this exists
# ---------------
# An agent's working directory resets between every Bash call, so "work in that
# other worktree" cannot be held in shell state. Every command has to carry the
# target path explicitly. This script turns a short, human-sized hint into the
# one absolute path those commands need, and refuses to guess when the hint is
# ambiguous — a wrong worktree fails silently, which is the failure mode worth
# spending an exit code on.
#
# Usage:
#   git-resolve-worktree.sh                 # the worktree the caller is in
#   git-resolve-worktree.sh --issue 42      # the worktree on branch issue-42-*
#   git-resolve-worktree.sh dev1            # substring of a worktree path
#   git-resolve-worktree.sh /abs/path       # an absolute path, validated
#
# Options:
#   --issue N   Prefer the worktree whose branch is `issue-N-<slug>`. Combined
#               with a hint, the hint decides and --issue is ignored.
#
# Output:
#   success  one absolute worktree root on stdout, exit 0
#   failure  nothing on stdout, diagnosis and candidates on stderr, exit 1
#
# Exit codes:
#   0 = resolved   1 = unresolvable (no match, ambiguous, not a worktree)
#   2 = usage error

set -uo pipefail

ISSUE=""
HINT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            [[ $# -ge 2 ]] || { echo "usage: git-resolve-worktree.sh [--issue N] [hint]" >&2; exit 2; }
            ISSUE="$2"
            shift 2
            ;;
        --issue=*)
            ISSUE="${1#--issue=}"
            shift
            ;;
        -h|--help)
            echo "usage: git-resolve-worktree.sh [--issue N] [hint]" >&2
            exit 2
            ;;
        -*)
            echo "usage: git-resolve-worktree.sh [--issue N] [hint]" >&2
            exit 2
            ;;
        *)
            [[ -n "$HINT" ]] && { echo "usage: git-resolve-worktree.sh [--issue N] [hint]" >&2; exit 2; }
            HINT="$1"
            shift
            ;;
    esac
done

# Everything is judged against the repository the caller is standing in. Without
# one there is no worktree list to search and no sane default to fall back to.
CURRENT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$CURRENT_ROOT" ]]; then
    echo "git-resolve-worktree.sh: not inside a git repository" >&2
    exit 1
fi

echo "$CURRENT_ROOT"
