#!/usr/bin/env bash
# git-merge-branch.sh — Merge a source ref into the CURRENT branch, with guards.
#
# Purpose: sync changes between feature/epic branches (e.g. develop -> epic branch,
# epic branch -> sub-epic branch) without exposing a raw `git merge` that could be
# pointed at a protected integration branch.
#
# HARD GUARD: refuses to run when the current branch (the MERGE TARGET) is
# develop/master/main. Merges INTO those branches must go through a reviewed PR
# that the user merges manually — never an agent-driven local merge.
# (develop/master/main as the SOURCE is fine — that is the normal direction.)
#
# Usage:
#   git-merge-branch.sh <source-ref> [-m "merge commit message"]
#
# Examples:
#   git-merge-branch.sh origin/develop -m "Merge develop into epic: bring in fix #X"
#   git-merge-branch.sh issue-1883-production-security
#
# Options:
#   -m <msg>   Merge commit message (default: "Merge <source> into <target>")
#   --ff       Allow fast-forward (default: --no-ff, always create a merge commit)
#
# Exit codes: 0 = merged (or already up to date), non-zero = refused or conflict.

set -euo pipefail

PROTECTED_BRANCHES="develop master main"

SOURCE=""
MSG=""
FF_MODE="--no-ff"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m)
            MSG="$2"
            shift 2
            ;;
        --ff)
            FF_MODE="--ff"
            shift
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$SOURCE" ]]; then
                SOURCE="$1"
                shift
            else
                echo "Error: unexpected argument: $1" >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$SOURCE" ]]; then
    echo "Error: source ref is required. Usage: git-merge-branch.sh <source-ref> [-m msg]" >&2
    exit 1
fi

# Must run inside a git repo under ~/Projects (mirror of other toolkit wrappers).
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: not inside a git work tree" >&2
    exit 1
fi
REPO_ROOT=$(git rev-parse --show-toplevel)
case "$REPO_ROOT" in
    "$HOME"/Projects/*) ;;
    *)
        echo "Error: refusing to run outside ~/Projects (repo: $REPO_ROOT)" >&2
        exit 1
        ;;
esac

TARGET=$(git branch --show-current)
if [[ -z "$TARGET" ]]; then
    echo "Error: detached HEAD — checkout a branch before merging" >&2
    exit 1
fi

# HARD GUARD: never merge into a protected integration branch.
for protected in $PROTECTED_BRANCHES; do
    if [[ "$TARGET" == "$protected" ]]; then
        echo "BLOCKED: current branch is '$TARGET'. Merges INTO develop/master/main must go through a reviewed PR that the user merges manually — not a local git merge. Checkout a feature/epic branch first." >&2
        exit 2
    fi
done

# Verify the source ref exists.
if ! git rev-parse --verify --quiet "$SOURCE^{commit}" >/dev/null; then
    echo "Error: source ref '$SOURCE' not found (did you fetch?)" >&2
    exit 1
fi

# Require a clean working tree so the merge isn't tangled with uncommitted work.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: working tree has uncommitted changes — commit or stash first" >&2
    exit 1
fi

if [[ -z "$MSG" ]]; then
    MSG="Merge $SOURCE into $TARGET"
fi

echo "=== Merging $SOURCE into $TARGET ($FF_MODE) ==="
git merge "$FF_MODE" "$SOURCE" -m "$MSG"
echo "=== Done: $TARGET now contains $SOURCE ==="
