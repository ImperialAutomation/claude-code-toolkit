#!/bin/bash
# PostToolUse hook that runs ruff on Python files after Write/Edit.
#
# Advisory only — always exits 0. Lint warnings are sent to stderr
# so Claude sees them and can self-correct in the next edit.
#
# Installation: register in settings.json (project or global):
#   {
#     "hooks": {
#       "PostToolUse": [{
#         "matcher": "Write|Edit",
#         "hooks": [{ "type": "command", "command": "~/.claude/bin/hook-post-edit-lint.sh" }]
#       }]
#     }
#   }
#
# Skips:
#   - Non-Python files
#   - Files in /tmp/
#   - When ruff is not available

set -uo pipefail

INPUT=$(cat)

# Extract file path from tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Skip non-Python files
if [[ "$FILE_PATH" != *.py ]]; then
    exit 0
fi

# Skip temp files
if [[ "$FILE_PATH" == /tmp/* ]]; then
    exit 0
fi

# Skip if file doesn't exist (deleted or moved)
if [[ ! -f "$FILE_PATH" ]]; then
    exit 0
fi

# Find ruff: check PATH, then common venv locations
RUFF=""
if command -v ruff &>/dev/null; then
    RUFF="ruff"
else
    # Try to find ruff in project venv
    PROJECT_DIR=$(echo "$FILE_PATH" | sed 's|/[^/]*$||')
    while [[ "$PROJECT_DIR" != "/" ]]; do
        for venv_dir in .venv venv; do
            if [[ -x "$PROJECT_DIR/$venv_dir/bin/ruff" ]]; then
                RUFF="$PROJECT_DIR/$venv_dir/bin/ruff"
                break 2
            fi
        done
        PROJECT_DIR=$(dirname "$PROJECT_DIR")
    done
fi

# Skip if ruff not found
if [[ -z "$RUFF" ]]; then
    exit 0
fi

# Run ruff check (no fix, just report)
LINT_OUTPUT=$($RUFF check --no-fix "$FILE_PATH" 2>&1) || true

if [[ -n "$LINT_OUTPUT" ]]; then
    echo "ruff: $LINT_OUTPUT" >&2
fi

# Always exit 0 — advisory only
exit 0
