#!/usr/bin/env bash
# strip-ansi.sh — write a copy of a file with its ANSI escape sequences removed.
#
# Test runner output captured to a file (vitest, pytest --color=yes, npm) is full
# of colour and cursor codes, and grepping it means piping through
# `sed 's/\x1b\[[0-9;]*m//g'`. That sed segment has no allow rule, so the whole
# chain prompts. This wrapper is a single command and matches
# Bash(~/.claude/bin/*); read or grep the cleaned copy with Read/Grep afterwards.
#
# Usage:
#   strip-ansi.sh <file> [<outfile>]
#
#   <outfile> defaults to <file>.clean. The result goes to a file, not stdout, so
#   it is read with Read/Grep instead of piped onwards into a new chain.
#
# What is removed (more than the colour-only regex above, which leaves vitest's
# cursor codes and hyperlinks in place):
#   - CSI sequences: colours (ESC[1;31m) and cursor/erase codes (ESC[2K, ESC[1A)
#   - OSC sequences: terminal hyperlinks (ESC]8;;url BEL), the visible text kept
#   - two- and three-byte escapes: ESC 7, ESC 8, ESC ( B
# Everything else, including unicode, tabs and a missing final newline, is kept
# byte for byte. Carriage-return progress lines are left as they are.
#
# The input file is never modified; an <outfile> that is the input file is
# refused, because the shell would truncate it before it was read.
#
# Exit codes:
#   0  cleaned copy written; prints "<outfile> (<bytes> bytes)"
#   1  input missing or unreadable, or <outfile> is the input (nothing written)
#   2  usage error (nothing written)
#
# Examples:
#   strip-ansi.sh /tmp/shop-vitest-42.txt          # -> /tmp/shop-vitest-42.txt.clean
#   strip-ansi.sh /tmp/shop-pytest-42.log /tmp/shop-pytest-42.txt

set -uo pipefail

usage() {
    echo "usage: $(basename "$0") <file> [<outfile>]" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

INFILE="$1"
OUTFILE="${2:-$INFILE.clean}"

[[ -f "$INFILE" && -r "$INFILE" ]] || { echo "input not found or unreadable: $INFILE" >&2; exit 1; }
if [[ "$INFILE" -ef "$OUTFILE" ]]; then
    echo "outfile is the input file, refusing to overwrite it: $OUTFILE" >&2
    exit 1
fi

ESC=$'\033'
BEL=$'\007'

mkdir -p "$(dirname "$OUTFILE")"

# LC_ALL=C makes the bracket ranges byte ranges and lets sed pass any byte
# sequence through untouched, whatever the file's encoding. Order matters: CSI
# and OSC are removed before the generic two-byte rule, which would otherwise
# take just their first two bytes. '#' is the delimiter so the CSI range [ -/]
# needs no escaping: a backslash inside a bracket is literal, and [ -\/] would
# silently become the range space..backslash, which swallows letters and digits.
LC_ALL=C sed -E \
    -e "s#${ESC}\[[0-?]*[ -/]*[@-~]##g" \
    -e "s#${ESC}\][^${BEL}${ESC}]*(${BEL}|${ESC}\\\\)##g" \
    -e "s#${ESC}[()*+][ -~]##g" \
    -e "s#${ESC}[0-~]##g" \
    "$INFILE" > "$OUTFILE" || exit 1

BYTES=$(wc -c < "$OUTFILE" | tr -d ' ')
printf '%s (%s bytes)\n' "$OUTFILE" "$BYTES"
