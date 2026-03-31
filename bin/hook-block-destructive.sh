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
    "git push.*-f[^i]"
    "git reset.*--hard"
    "git checkout -- \\."
    "git clean.*-f"
    "git branch.*-D"
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

for pattern in "${BLOCKED_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -iE "$pattern" > /dev/null 2>&1; then
        echo "BLOCKED by hook-block-destructive.sh: command matches destructive pattern '$pattern'. Rephrase or ask the user for explicit permission." >&2
        exit 2
    fi
done

exit 0
