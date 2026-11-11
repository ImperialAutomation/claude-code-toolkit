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
#   repeat-cmd.sh [--percentiles] [--warmup <n>] <count> <command> [args...]
#
# Options (before <count>, in any order):
#   --percentiles  time each run and add a line with nearest-rank p50, p95 and
#                  max over the counted runs. Use it when a target is stated as
#                  a percentile ("p95 under 200 ms"): a mean hides the tail.
#   --warmup <n>   run the command n extra times first (n >= 0). Warmup runs
#                  count in neither the total, the mean nor the percentiles;
#                  they absorb cold caches and connection set-up.
#
# Each run's stdout is discarded. Its stderr is kept only until the run ends and
# shown when that run fails: on success it is noise, on failure it is the
# diagnosis. The loop stops at the first non-zero exit, warmup runs included.
#
# Output: one summary line on stdout, e.g.
#   repeat-cmd: 10/10 runs ok, total 1.234s, 0.123s/run
# with --percentiles followed by
#   repeat-cmd: p50 0.075s, p95 0.159s, max 0.342s (n=10)
# On failure (on stderr, no percentile line):
#   repeat-cmd: run 4/10 failed (exit 3) after 3 ok, total 0.512s
#   repeat-cmd: warmup run 2/3 failed (exit 3)
#
# Exit codes:
#   0    every run succeeded
#   2    usage error (the command never ran)
#   the failing run's own status otherwise (127: command not found)
#
# Example (a reset and a stats query stay separate, single commands):
#   repeat-cmd.sh --warmup 2 --percentiles 50 curl -sf http://localhost:8000/health

set -uo pipefail

usage() {
    echo "usage: $(basename "$0") [--percentiles] [--warmup <n>] <count> <command> [args...]" >&2
    exit 2
}

case "${1:-}" in
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac

PERCENTILES=0
WARMUP=0
# The auto-approve hook mirrors this loop (_repeat_cmd_inner): keep them in step.
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        --percentiles) PERCENTILES=1; shift ;;
        --warmup)
            [[ "${2:-}" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "--warmup needs a non-negative integer: '${2:-}'" >&2; usage; }
            WARMUP="$2"; shift 2 ;;
        *) echo "unknown option: '$1'" >&2; usage ;;
    esac
done

[[ $# -ge 2 ]] || usage
[[ "$1" =~ ^[1-9][0-9]*$ ]] || { echo "count must be a positive integer: '$1'" >&2; usage; }

COUNT="$1"; shift

# Microseconds since the epoch into NOW_US, from bash's own clock: no `date`
# fork, and no subshell, per run skewing a measurement of short commands. The
# separator is locale-dependent.
now_us() {
    local t="${EPOCHREALTIME/[.,]/}"
    NOW_US=$((10#$t))
}

# Seconds with millisecond precision, from a microsecond count.
fmt_seconds() {
    printf '%d.%03ds' "$(($1 / 1000000))" "$((($1 % 1000000) / 1000))"
}

# Nearest-rank percentile: the value at rank ceil(p * n / 100) of the sorted list.
percentile() { # p sorted-values...
    local p="$1"; shift
    local rank=$(( (p * $# + 99) / 100 ))
    echo "${!rank}"
}

ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT

for ((run = 1; run <= WARMUP; run++)); do
    if "$@" >/dev/null 2>"$ERRFILE"; then continue; else STATUS=$?; fi
    cat "$ERRFILE" >&2
    echo "repeat-cmd: warmup run $run/$WARMUP failed (exit $STATUS)" >&2
    exit "$STATUS"
done

DURATIONS=()
now_us; START=$NOW_US
for ((run = 1; run <= COUNT; run++)); do
    RUN_START=$NOW_US
    # Status read in the else branch: after an `if` without one, $? is the
    # if-statement's own 0, not the command's.
    if "$@" >/dev/null 2>"$ERRFILE"; then
        now_us
        ((PERCENTILES)) && DURATIONS+=("$((NOW_US - RUN_START))")
        continue
    else STATUS=$?; fi
    now_us
    cat "$ERRFILE" >&2
    echo "repeat-cmd: run $run/$COUNT failed (exit $STATUS) after $((run - 1)) ok, total $(fmt_seconds "$((NOW_US - START))")" >&2
    exit "$STATUS"
done
ELAPSED=$((NOW_US - START))

echo "repeat-cmd: $COUNT/$COUNT runs ok, total $(fmt_seconds "$ELAPSED"), $(fmt_seconds "$((ELAPSED / COUNT))")/run"

if ((PERCENTILES)); then
    mapfile -t SORTED < <(printf '%s\n' "${DURATIONS[@]}" | sort -n)
    echo "repeat-cmd: p50 $(fmt_seconds "$(percentile 50 "${SORTED[@]}")"), p95 $(fmt_seconds "$(percentile 95 "${SORTED[@]}")"), max $(fmt_seconds "${SORTED[COUNT - 1]}") (n=$COUNT)"
fi
