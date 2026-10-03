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

"$@" > "$OUTFILE"
