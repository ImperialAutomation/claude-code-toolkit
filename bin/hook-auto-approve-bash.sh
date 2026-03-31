#!/bin/bash
# auto-approve-bash.sh — PreToolUse hook for Claude Code
#
# Auto-approves safe Bash commands that would otherwise trigger permission
# prompts due to shell constructs (redirects, for-loops, && chains, heredocs).
#
# Permission matching only checks the FIRST token of a command, so:
#   gh issue view 123 > /tmp/out.json    → first token "gh" matches Bash(gh *)
#   ...but the ">" makes it a different command for the permission system.
#
# This hook inspects the full command and approves safe patterns.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# If no command, let normal flow handle it
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

approve() {
    jq -n --arg reason "$1" '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": $reason
        }
    }'
    exit 0
}

# --- Safe patterns ---

# Pattern: Shell redirects to /tmp/ with allowed commands
# e.g., gh issue view 123 --json ... > /tmp/file.json
# e.g., gh issue list ... 2>/dev/null > /tmp/file.json
if printf '%s' "$COMMAND" | grep -qP '^\s*(gh|git|npm|npx|docker)\s+.*[12]?>\s*/tmp/'; then
    approve "Hook: shell redirect to /tmp with allowed command"
fi

# Pattern: Command with stderr suppression (2>/dev/null or 2>/tmp/...)
# e.g., gh issue view 123 --json ... 2>/dev/null
# e.g., some_cmd 2>/tmp/err.txt
if printf '%s' "$COMMAND" | grep -qP '^\s*(gh|git|npm|npx|docker)\s+.*2>/'; then
    approve "Hook: stderr redirect with allowed command"
fi

# Pattern: For loops around allowed commands
# e.g., for i in 1 2 3; do gh issue view $i ...; done
if printf '%s' "$COMMAND" | grep -qP '^\s*for\b.*\bdo\b.*(gh|git|~/.claude/bin/)\b'; then
    approve "Hook: for loop with allowed commands"
fi

# Pattern: && chains where ALL commands are allowed
# e.g., gh issue view 123 && gh issue view 456
# e.g., git add . && git commit -F /tmp/msg.txt
# Split on && and check each part starts with an allowed command
if printf '%s' "$COMMAND" | grep -qP '&&'; then
    ALL_SAFE=true
    while IFS= read -r part; do
        trimmed=$(printf '%s' "$part" | sed 's/^\s*//')
        if ! printf '%s' "$trimmed" | grep -qP '^(gh|git|npm|npx|docker|~/.claude/bin/|echo\s+"OK"|echo\s+OK)\s*'; then
            ALL_SAFE=false
            break
        fi
    done <<< "$(printf '%s' "$COMMAND" | sed 's/&&/\n/g')"

    if $ALL_SAFE; then
        approve "Hook: && chain with all allowed commands"
    fi
fi

# Pattern: Command substitution in git commit
# e.g., git commit -m "$(cat <<'EOF' ... EOF)"
if printf '%s' "$COMMAND" | grep -qP '^\s*git\s+commit\s+'; then
    approve "Hook: git commit (any form)"
fi

# Pattern: Pipe to allowed commands or common utilities
# e.g., gh api ... | jq '.data'
# e.g., git log --oneline | head -5
if printf '%s' "$COMMAND" | grep -qP '^\s*(gh|git|npm|npx|docker)\s+.*\|\s*(jq|head|tail|wc|sort|grep|tee)\b'; then
    approve "Hook: pipe from allowed command to safe utility"
fi

# Default: let normal permission system handle it
exit 0
