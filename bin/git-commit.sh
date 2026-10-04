#!/usr/bin/env bash
# git-commit.sh — Commit with a message passed as argument or from stdin.
#
# Avoids heredoc/multiline issues in Claude Code sub-agents by writing
# the message to a temp file and using git commit -F.
#
# Usage:
#   git-commit.sh "Single line commit message"
#   git-commit.sh "Multi-line" "commit message" "each arg is a line"
#   echo "message" | git-commit.sh --stdin
#
# Options:
#   --file F   Read commit message from file F
#   --stdin    Read commit message from stdin
#   --amend    Amend the previous commit (use with caution)
#   --repo D   Run git in repository directory D (avoids a leading `cd`, which
#              would break the Bash(~/.claude/bin/*) permission match)
#   --allow-protected
#              Commit even when the target tree is on a protected branch
#
# Protected branches:
#   In repos where every change reaches the base branch through a PR, a commit
#   on develop/master/main is always a mistake. This script refuses it, because
#   it is the one choke point every agent commit passes through — a check here
#   runs whether or not the agent remembered the rule.
#
#   Which branches are protected is per repo, read from the first source that
#   exists:
#     1. <repo>/.claude/protected-branches — one branch name per line; blank
#        lines and lines starting with # are ignored
#     2. git config --get-all toolkit.protectedBranch
#   Neither present: nothing is protected, which is the default. Repos that
#   commit straight to main are therefore unaffected.
#
#   Names match exactly, no globbing. Detached HEAD is always allowed (rebase,
#   bisect, cherry-pick sequences).

set -euo pipefail

# Resolved from BASH_SOURCE, not the cwd: this script is called from arbitrary
# working directories, and bin/ is reached through a symlink.
# shellcheck source=bin/lib/strip-sandbox-noise.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/strip-sandbox-noise.sh"

AMEND=""
FROM_STDIN=""
FROM_FILE=""
REPO_DIR=""
ALLOW_PROTECTED=""
MSG_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stdin)
            FROM_STDIN=1
            shift
            ;;
        --file)
            FROM_FILE="$2"
            shift 2
            ;;
        --repo)
            REPO_DIR="$2"
            shift 2
            ;;
        --amend)
            AMEND="--amend"
            shift
            ;;
        --allow-protected)
            ALLOW_PROTECTED=1
            shift
            ;;
        *)
            MSG_ARGS+=("$1")
            shift
            ;;
    esac
done

# Switch into the repository if requested, so the caller need not prefix the
# command with `cd` (which would break the permission allow-match).
if [[ -n "$REPO_DIR" ]]; then
    cd "$REPO_DIR" || { echo "Error: cannot cd into repo '$REPO_DIR'." >&2; exit 1; }
fi

# Protected-branch guard. Runs after the --repo cd, so it reads the branch of the
# tree being committed to rather than the caller's — the two differ whenever a
# session works in a linked worktree, which is exactly when the mistake happens.
#
# Placed before every commit path (--file, --stdin, message args) and before the
# temp file is written, so a refusal leaves nothing behind.
if [[ -z "$ALLOW_PROTECTED" ]]; then
    # Fails on detached HEAD, which is deliberately allowed: rebases and bisects
    # commit there routinely and no base branch is at risk.
    CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)

    if [[ -n "$CURRENT_BRANCH" ]]; then
        PROTECTED=()
        # --show-toplevel rather than the cwd: the config file lives at the repo
        # root, and this script is routinely called from a subdirectory.
        REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null || true)
        PROTECTED_FILE="$REPO_TOP/.claude/protected-branches"

        if [[ -n "$REPO_TOP" && -f "$PROTECTED_FILE" ]]; then
            # The file is the single source when present; git config is not
            # merged in, so "why is this branch protected" has one answer.
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%%#*}"                 # strip comments
                line="${line#"${line%%[![:space:]]*}"}"  # strip leading space
                line="${line%"${line##*[![:space:]]}"}"  # strip trailing space
                [[ -n "$line" ]] && PROTECTED+=("$line")
            done < "$PROTECTED_FILE"
        else
            while IFS= read -r line; do
                [[ -n "$line" ]] && PROTECTED+=("$line")
            done < <(git config --get-all toolkit.protectedBranch 2>/dev/null || true)
        fi

        for protected in ${PROTECTED+"${PROTECTED[@]}"}; do
            if [[ "$CURRENT_BRANCH" == "$protected" ]]; then
                echo "Error: refusing to commit on protected branch '$CURRENT_BRANCH'." >&2
                echo "Create a branch first (git -C $(pwd) switch -c <name>), or pass --allow-protected." >&2
                exit 1
            fi
        done
    fi
fi

# --file: use the file directly, no temp file needed
if [[ -n "$FROM_FILE" ]]; then
    if [[ ! -s "$FROM_FILE" ]]; then
        echo "Error: File '$FROM_FILE' does not exist or is empty." >&2
        exit 1
    fi
    # Not `exec`: exec replaces this shell, leaving nothing to filter git's
    # stderr. The status is propagated explicitly instead, so callers see the
    # same exit code they did before.
    # shellcheck disable=SC2086  # $AMEND is intentionally word-split (may be empty)
    git_filtered commit $AMEND -F "$FROM_FILE"
    exit $?
fi

TMPFILE=$(mktemp /tmp/commit-msg-XXXXXX.txt)
trap 'rm -f "$TMPFILE"' EXIT

if [[ -n "$FROM_STDIN" ]]; then
    cat > "$TMPFILE"
elif [[ ${#MSG_ARGS[@]} -gt 0 ]]; then
    # Join arguments with newlines (each arg = one line)
    printf '%s\n' "${MSG_ARGS[@]}" > "$TMPFILE"
else
    echo "Error: No commit message provided." >&2
    echo "Usage: git-commit.sh \"message\" or echo \"message\" | git-commit.sh --stdin" >&2
    exit 1
fi

# Verify the message is not empty
if [[ ! -s "$TMPFILE" ]]; then
    echo "Error: Commit message is empty." >&2
    exit 1
fi

# Not `exec`, for the same reason as the --file path above.
# shellcheck disable=SC2086  # $AMEND is intentionally word-split (may be empty)
git_filtered commit $AMEND -F "$TMPFILE"
exit $?
