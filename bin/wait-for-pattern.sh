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
#   wait-for-pattern.sh [--newer-than <epoch>] <file> <extended-regex> \
#       [timeout-seconds] [poll-seconds]
#
# Defaults: timeout 600, poll 20.
#
# --newer-than <epoch> ignores the file while its mtime is at or before <epoch>,
# so only a write made after that moment can satisfy the pattern. Pass the time
# the watched process was started (`date +%s` just before spawning it).
#
# Without it, a file left behind by a PREVIOUS run answers for the new one: a
# second run on the same progress file matches the old 'PHASE: DONE' within a
# second, and the caller reports the previous run's result as the new one. Exit
# 0 carries no information about which run wrote the line. The mtime does.
#
# Exit codes:
#   0  pattern found — prints the matching line(s) to stdout
#   1  timed out — prints the file's current contents to stderr for diagnosis
#   2  usage error
#
# Examples:
#   wait-for-pattern.sh /tmp/epic-progress-2677.txt 'DONE|FAILED' 1200
#   wait-for-pattern.sh /tmp/build.log 'BUILD (SUCCESS|FAILED)' 600 15
#   wait-for-pattern.sh --newer-than "$SPAWNED_AT" /tmp/epic-progress-2677.txt \
#       'DONE|FAILED' 1200
#
# Note: the file need not exist yet — a missing file is a normal starting
# state (the writing process may not have created it), not an error.

set -euo pipefail

usage() {
    echo "usage: $(basename "$0") [--newer-than <epoch>] <file> <extended-regex> [timeout-seconds] [poll-seconds]" >&2
    exit 2
}

NEWER_THAN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --newer-than)
            [ $# -ge 2 ] || { echo "--newer-than needs an epoch value" >&2; usage; }
            NEWER_THAN="$2"
            shift 2
            ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) break ;;
    esac
done

if [ $# -lt 2 ]; then
    usage
fi

FILE="$1"
PATTERN="$2"
TIMEOUT="${3:-600}"
POLL="${4:-20}"

if [ -n "$NEWER_THAN" ]; then
    case "$NEWER_THAN" in
        ''|*[!0-9]*) echo "--newer-than must be a positive integer (epoch seconds)" >&2; exit 2 ;;
    esac
fi

case "$TIMEOUT" in ''|*[!0-9]*) echo "timeout must be a positive integer" >&2; exit 2 ;; esac
case "$POLL"    in ''|*[!0-9]*) echo "poll must be a positive integer"    >&2; exit 2 ;; esac
[ "$POLL" -gt 0 ] || { echo "poll must be > 0" >&2; exit 2; }

# Is the file new enough to be this run's? Only asked when --newer-than is set;
# an unreadable mtime counts as too old, since a file we cannot date cannot be
# attributed to this run either.
is_fresh() {
    [ -z "$NEWER_THAN" ] && return 0
    local mtime
    mtime=$(stat -c %Y "$FILE" 2>/dev/null) || return 1
    [ "$mtime" -gt "$NEWER_THAN" ]
}

WAITED=0
while [ "$WAITED" -lt "$TIMEOUT" ]; do
    if [ -f "$FILE" ] && is_fresh && grep -qE -- "$PATTERN" "$FILE" 2>/dev/null; then
        grep -E -- "$PATTERN" "$FILE"
        exit 0
    fi
    sleep "$POLL"
    WAITED=$((WAITED + POLL))
done

echo "timeout after ${TIMEOUT}s: '$PATTERN' not found in $FILE" >&2
if [ -f "$FILE" ]; then
    # A stale file is the one timeout cause the contents alone cannot show: the
    # pattern may be right there in the dump, which reads like a bug in the
    # matching rather than a file left over from an earlier run.
    if ! is_fresh; then
        echo "--- $FILE is older than the --newer-than cutoff ($NEWER_THAN) ---" >&2
        echo "--- it was left by an earlier run; this run never wrote to it ---" >&2
    fi
    echo "--- current contents of $FILE ---" >&2
    cat "$FILE" >&2
else
    echo "--- $FILE does not exist ---" >&2
fi
exit 1
