#!/usr/bin/env bash
# cmd-save.sh — run a command and save its output to a file.
#
# A shell redirect defeats permission matching: the rule matches on the first
# token, and `docker exec ... > /tmp/out` is no longer covered by a Bash(docker *)
# rule, so it prompts every time. This wrapper is a single command and matches
# Bash(~/.claude/bin/*).
#
# Usage:
#   cmd-save.sh <output-file> <command> [args...]
#
# Examples:
#   cmd-save.sh /tmp/pods.json kubectl get pods -o json
#   cmd-save.sh /tmp/schema.sql docker exec db psql -U postgres -d app -t -A -c "SELECT ..."

set -uo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $(basename "$0") <output-file> <command> [args...]" >&2
    exit 2
fi

OUTFILE="$1"; shift

mkdir -p "$(dirname "$OUTFILE")"

# Run the command, then report. The status reported is the command's own, not
# the redirect's: a failing command that still wrote a file would otherwise look
# like a successful capture, and the caller would read an error message as data.
if "$@" > "$OUTFILE"; then
    STATUS=0
else
    STATUS=$?
fi

# The byte count makes an empty capture visible. A zero-byte file is the
# signature of a command that produced nothing, and it is otherwise invisible
# until something downstream behaves strangely.
BYTES=$(wc -c < "$OUTFILE" | tr -d ' ')

printf '%s (%s bytes, exit %d)\n' "$OUTFILE" "$BYTES" "$STATUS"
exit "$STATUS"
