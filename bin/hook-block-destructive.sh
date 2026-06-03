#!/bin/bash
# Pre-tool-use hook that blocks destructive Bash commands.
#
# Designed for use with Claude Code's bypass-permissions mode as a safety net.
# Works in all permission modes — hooks always run regardless of permission settings.
#
# Installation: register in settings.json (project or global):
#   {
#     "hooks": {
#       "PreToolUse": [{
#         "matcher": "Bash",
#         "hooks": [{ "type": "command", "command": "~/.claude/hooks/block-destructive.sh" }]
#       }]
#     }
#   }
#
# Exit codes:
#   0 = allow
#   2 = block (reason sent to stderr, shown to Claude)

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
    exit 0
fi

# Patterns for destructive operations
BLOCKED_PATTERNS=(
    # Filesystem destruction
    "rm -rf /"
    "rm -rf /[a-z]"
    "rm -rf ~"
    "rm -rf \\$HOME"
    # Git destructive operations
    "git push.*--force"
    "git push.* -f( |$)"
    "git reset.*--hard"
    "git checkout -- \\."
    "git clean.* -f( |$)"
    # Database destruction
    "DROP TABLE"
    "DROP DATABASE"
    "TRUNCATE"
    "DELETE FROM.*WITHOUT.*WHERE"
    # Process/system
    "kill -9 1$"
    "killall"
    "shutdown"
    "reboot"
    "mkfs"
    "dd if=.* of=/dev/"
)

# Case-sensitive patterns: only block uppercase forms (e.g. -D force delete, not -d safe delete)
CASE_SENSITIVE_PATTERNS=(
    "git branch.*-D"
)

# Guard: never auto-merge a PR into a protected base branch.
# Blocks git-push-pr-merge.sh targeting develop/master/main UNLESS --no-merge is set.
# Epic sub-issue PRs (--base <feature_branch>) are unaffected; only the shared
# integration branches are protected. The agent must leave those PRs for the user
# to review and merge manually. See implement / implement-epic skill rules.
if echo "$COMMAND" | grep -qE 'git-push-pr-merge\.sh'; then
    if echo "$COMMAND" | grep -qE -- '--base[= ]+(develop|master|main)([[:space:]]|$)'; then
        if ! echo "$COMMAND" | grep -qE -- '--no-merge'; then
            echo "BLOCKED by hook-block-destructive.sh: refusing to auto-merge a PR into a protected base branch (develop/master/main). This repo has no server-side branch protection (private/free tier), so merges to integration branches are the user's call. Re-run with --no-merge to open the PR for review, or ask the user to merge it." >&2
            exit 2
        fi
    fi
fi

# Guard: never run a raw `git merge` while ON a protected base branch.
# Merging INTO feature/epic branches is fine (that is the normal sync direction,
# e.g. develop -> epic branch). But a merge whose TARGET is develop/master/main
# must go through a reviewed PR the user merges manually — this repo has no
# server-side branch protection (private/free tier). A static permission pattern
# can't see the current branch, so the check lives here. The sanctioned wrapper
# git-merge-branch.sh enforces the same rule; this catches raw `git merge` too.
if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+merge([[:space:]]|$)'; then
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)
    case "$CURRENT_BRANCH" in
        develop|master|main)
            echo "BLOCKED by hook-block-destructive.sh: refusing 'git merge' while on protected branch '$CURRENT_BRANCH'. Merges INTO develop/master/main must go through a reviewed PR the user merges manually. To sync changes the other way (e.g. develop into a feature/epic branch), checkout that branch first — git-merge-branch.sh <source> does this with the same guard." >&2
            exit 2
            ;;
    esac
fi

for pattern in "${CASE_SENSITIVE_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -E "$pattern" > /dev/null 2>&1; then
        echo "BLOCKED by hook-block-destructive.sh: command matches destructive pattern '$pattern'. Rephrase or ask the user for explicit permission." >&2
        exit 2
    fi
done

for pattern in "${BLOCKED_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -iE "$pattern" > /dev/null 2>&1; then
        echo "BLOCKED by hook-block-destructive.sh: command matches destructive pattern '$pattern'. Rephrase or ask the user for explicit permission." >&2
        exit 2
    fi
done

exit 0
