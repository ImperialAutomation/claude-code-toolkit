#!/usr/bin/env bash
# cmd-save.sh — run a command and save its output to a file.
#
# A shell redirect defeats permission matching: the rule matches on the first
# token, and `docker exec ... > /tmp/out` is no longer covered by a Bash(docker *)
# rule, so it prompts every time. This wrapper is a single command and matches
# Bash(~/.claude/bin/*). gh-save.sh is the gh-shaped special case of it.
#
# Usage:
#   cmd-save.sh [--stderr separate|merge] [--strip-ansi] <output-file> <command> [args...]
#
# Options:
#   --stderr separate  (default) only stdout goes to the file; stderr passes
#                      through to the terminal
#   --stderr merge     stderr is folded into the file alongside stdout
#   --strip-ansi       remove ANSI colour/cursor codes from the capture (via
#                      strip-ansi.sh), so coloured test-runner output can be
#                      grepped without a sed chain; the byte count is of the
#                      cleaned file
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
#   cmd-save.sh --strip-ansi /tmp/vitest.txt npx vitest run

set -uo pipefail

STDERR_MODE=separate
STRIP_ANSI=false

usage() {
    echo "usage: $(basename "$0") [--stderr separate|merge] [--strip-ansi] <output-file> <command> [args...]" >&2
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
        --strip-ansi) STRIP_ANSI=true; shift ;;
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

# Stripped after the fact rather than through a pipe, so $STATUS stays the
# command's own. A failed strip leaves the raw capture in place and is reported:
# a command that succeeded must not look like a clean capture when it is not.
if [[ "$STRIP_ANSI" == true ]]; then
    TMP=$(mktemp "$OUTFILE.XXXXXX")
    if "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/strip-ansi.sh" "$OUTFILE" "$TMP" >/dev/null; then
        mv "$TMP" "$OUTFILE"
    else
        rm -f "$TMP"
        echo "--strip-ansi failed, capture left unstripped: $OUTFILE" >&2
        [[ "$STATUS" -ne 0 ]] || STATUS=1
    fi
fi

# The byte count makes an empty capture visible. A zero-byte file is the
# signature of a command that produced nothing, and it is otherwise invisible
# until something downstream behaves strangely.
BYTES=$(wc -c < "$OUTFILE" | tr -d ' ')

printf '%s (%s bytes, exit %d)\n' "$OUTFILE" "$BYTES" "$STATUS"
exit "$STATUS"
