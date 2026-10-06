#!/usr/bin/env bash
# repeat-cmd.sh — run a command N times, for warm/cold timing measurements.
#
# `for i in 1 2 3; do <cmd>; done` is a compound command: the `for` segment can
# never match an allow rule, so every such measurement prompts. This wrapper is
# a single command. It matches Bash(~/.claude/bin/*), and hook-auto-approve-bash
# only lets it through when <command> on its own would be approved too, so it
# cannot be used to launder a command that would otherwise prompt.
#
# Usage:
#   repeat-cmd.sh <count> <command> [args...]
#
# Each run's stdout is discarded. Its stderr is kept only until the run ends and
# shown when that run fails: on success it is noise, on failure it is the
# diagnosis. The loop stops at the first non-zero exit.
#
# Output: one summary line on stdout, e.g.
#   repeat-cmd: 10/10 runs ok, total 1.234s, 0.123s/run
#   repeat-cmd: run 4/10 failed (exit 3) after 3 ok, total 0.512s   (on stderr)
#
# Exit codes:
#   0    every run succeeded
#   2    usage error (the command never ran)
#   the failing run's own status otherwise (127: command not found)
#
# Example (a reset and a stats query stay separate, single commands):
#   repeat-cmd.sh 10 docker exec db psql -U postgres -d app -c "SELECT ..."

set -uo pipefail

usage() {
    echo "usage: $(basename "$0") <count> <command> [args...]" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage
[[ "$1" =~ ^[1-9][0-9]*$ ]] || { echo "count must be a positive integer: '$1'" >&2; usage; }

COUNT="$1"; shift

# Microseconds since the epoch, from bash's own clock: no `date` fork per run
# skewing a measurement of short commands. The separator is locale-dependent.
now_us() {
    local t="${EPOCHREALTIME/[.,]/}"
    echo "$((10#$t))"
}

# Seconds with millisecond precision, from a microsecond count.
fmt_seconds() {
    printf '%d.%03ds' "$(($1 / 1000000))" "$((($1 % 1000000) / 1000))"
}

ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT

START=$(now_us)
for ((run = 1; run <= COUNT; run++)); do
    # Status read in the else branch: after an `if` without one, $? is the
    # if-statement's own 0, not the command's.
    if "$@" >/dev/null 2>"$ERRFILE"; then continue; else STATUS=$?; fi
    ELAPSED=$(($(now_us) - START))
    cat "$ERRFILE" >&2
    echo "repeat-cmd: run $run/$COUNT failed (exit $STATUS) after $((run - 1)) ok, total $(fmt_seconds "$ELAPSED")" >&2
    exit "$STATUS"
done
ELAPSED=$(($(now_us) - START))

echo "repeat-cmd: $COUNT/$COUNT runs ok, total $(fmt_seconds "$ELAPSED"), $(fmt_seconds "$((ELAPSED / COUNT))")/run"
