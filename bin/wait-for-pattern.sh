#!/usr/bin/env bash
# wait-for-pattern.sh — block until a regex appears in a file, or time out.
#
# Replaces the `until grep -qE "..." <file>; do sleep N; done` idiom. That form
# is a compound command, so permission matching fails on its second segment and
# it prompts every time. This wrapper matches Bash(~/.claude/bin/*) and runs
# prompt-free. hook-auto-approve-bash.py denies the raw idiom and points here.
#
# Typical use: waiting on a background agent's progress file, a build log, or
# any other file that a separate process appends to.
#
# Usage:
#   wait-for-pattern.sh <file> <extended-regex> [timeout-seconds] [poll-seconds]
#
# Defaults: timeout 600, poll 20.
#
# Exit codes:
#   0  pattern found — prints the matching line(s) to stdout
#   1  timed out — prints the file's current contents to stderr for diagnosis
#   2  usage error
#
# Examples:
#   wait-for-pattern.sh /tmp/epic-progress-2677.txt 'DONE|FAILED' 1200
#   wait-for-pattern.sh /tmp/build.log 'BUILD (SUCCESS|FAILED)' 600 15
#
# Note: the file need not exist yet — a missing file is a normal starting
# state (the writing process may not have created it), not an error.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $(basename "$0") <file> <extended-regex> [timeout-seconds] [poll-seconds]" >&2
    exit 2
fi

FILE="$1"
PATTERN="$2"
TIMEOUT="${3:-600}"
POLL="${4:-20}"

case "$TIMEOUT" in ''|*[!0-9]*) echo "timeout must be a positive integer" >&2; exit 2 ;; esac
case "$POLL"    in ''|*[!0-9]*) echo "poll must be a positive integer"    >&2; exit 2 ;; esac
[ "$POLL" -gt 0 ] || { echo "poll must be > 0" >&2; exit 2; }

WAITED=0
while [ "$WAITED" -lt "$TIMEOUT" ]; do
    if [ -f "$FILE" ] && grep -qE -- "$PATTERN" "$FILE" 2>/dev/null; then
        grep -E -- "$PATTERN" "$FILE"
        exit 0
    fi
    sleep "$POLL"
    WAITED=$((WAITED + POLL))
done

echo "timeout after ${TIMEOUT}s: '$PATTERN' not found in $FILE" >&2
if [ -f "$FILE" ]; then
    echo "--- current contents of $FILE ---" >&2
    cat "$FILE" >&2
else
    echo "--- $FILE does not exist ---" >&2
fi
exit 1
