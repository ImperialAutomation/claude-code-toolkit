#!/usr/bin/env bash
# cmd-save.sh — run a command and save its output to a file.
#
# A shell redirect defeats permission matching: the rule matches on the first
# token, and `docker exec ... > /tmp/out` is no longer covered by a Bash(docker *)
# rule, so it prompts every time. This wrapper is a single command and matches
# Bash(~/.claude/bin/*). gh-save.sh is the gh-shaped special case of it.
#
# Usage:
#   cmd-save.sh [--stderr separate|merge] <output-file> <command> [args...]
#
# Options:
#   --stderr separate  (default) only stdout goes to the file; stderr passes
#                      through to the terminal
#   --stderr merge     stderr is folded into the file alongside stdout
#
# stderr is separated by default because a command that warns on stderr would
# otherwise silently corrupt what the caller reads back as clean data — a
# deprecation notice in the middle of a JSON capture makes it unparseable, and
# nothing reports that. Use `--stderr merge` when the capture exists to diagnose
# a failure rather than to carry data.
#
# Flag parsing stops at the output file, so everything after it belongs to the
# command and a command's own flags are never mistaken for the wrapper's.
#
# Exit codes:
#   the command's own status, so a failed command is never read as a successful
#   capture of an error message
#   2  usage error (nothing is written)
#   127  command not found
#
# Examples:
#   cmd-save.sh /tmp/pods.json kubectl get pods -o json
#   cmd-save.sh /tmp/inspect.json docker inspect my-container
#   cmd-save.sh /tmp/schema.sql docker exec db psql -U postgres -d app -t -A -c "SELECT ..."
#   cmd-save.sh --stderr merge /tmp/build.log npm run build

set -uo pipefail

STDERR_MODE=separate

usage() {
    echo "usage: $(basename "$0") [--stderr separate|merge] <output-file> <command> [args...]" >&2
    exit 2
}

# Only the arguments before the output file are the wrapper's. The first
# non-flag argument is the output file, and parsing ends there.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stderr)
            [[ $# -ge 2 ]] || { echo "--stderr needs a value: separate or merge" >&2; exit 2; }
            case "$2" in
                separate|merge) STDERR_MODE="$2" ;;
                *) echo "--stderr must be 'separate' or 'merge': $2" >&2; exit 2 ;;
            esac
            shift 2 ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done

[[ $# -ge 2 ]] || usage

OUTFILE="$1"; shift

mkdir -p "$(dirname "$OUTFILE")"

# Run the command, then report. The status reported is the command's own, not
# the redirect's: a failing command that still wrote a file would otherwise look
# like a successful capture, and the caller would read an error message as data.
if [[ "$STDERR_MODE" == merge ]]; then
    if "$@" > "$OUTFILE" 2>&1; then STATUS=0; else STATUS=$?; fi
else
    if "$@" > "$OUTFILE"; then STATUS=0; else STATUS=$?; fi
fi

# The byte count makes an empty capture visible. A zero-byte file is the
# signature of a command that produced nothing, and it is otherwise invisible
# until something downstream behaves strangely.
BYTES=$(wc -c < "$OUTFILE" | tr -d ' ')

printf '%s (%s bytes, exit %d)\n' "$OUTFILE" "$BYTES" "$STATUS"
exit "$STATUS"
