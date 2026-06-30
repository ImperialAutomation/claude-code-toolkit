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

set -euo pipefail

AMEND=""
FROM_STDIN=""
FROM_FILE=""
REPO_DIR=""
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

# --file: use the file directly, no temp file needed
if [[ -n "$FROM_FILE" ]]; then
    if [[ ! -s "$FROM_FILE" ]]; then
        echo "Error: File '$FROM_FILE' does not exist or is empty." >&2
        exit 1
    fi
    exec git commit $AMEND -F "$FROM_FILE"
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

exec git commit $AMEND -F "$TMPFILE"
