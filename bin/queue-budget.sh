#!/usr/bin/env bash
# queue-budget.sh: the stop conditions of one /loop /queue-run (#251).
#
# Usage:
#   queue-budget.sh gate <budget>
#   queue-budget.sh idle <max-idle>
#   queue-budget.sh worked
#   queue-budget.sh stop
#
# A /loop runs in one Claude Code session, so the session id
# ($CLAUDE_CODE_SESSION_ID) identifies the loop.
#
# gate <budget>  Checked before every claim. Prints one line and exits 1 (stop
#                the loop, claim nothing) when:
#                - the stop file ~/.claude/queue-stop exists; it is left in
#                  place, the human removes it before the next loop (D7);
#                - CLAUDE_CODE_SESSION_ID is unset or not a plain id: the
#                  budget cannot be counted, so fail closed (D8);
#                - this session's releases in the run log
#                  ~/.claude/queue-runs.tsv reached <budget>. Every release
#                  counts (pr, rework, escalated, failed); a row counts
#                  when its `session` column (the 10th, written by
#                  queue-claim.sh) equals the session id. Rows from before
#                  that column have nine fields and never count; the review
#                  columns (#297) come after it and do not move it. A
#                  `runner` row (the session's own tokens, #270) is not a
#                  release and never counts.
#                Otherwise prints `budget <used>/<budget>` and exits 0. The
#                first such gate of a session records the loop start in
#                ~/.claude/queue-idle/<session-id>.start; later gates leave it.
# idle <max>     An iteration that claimed nothing. Adds one to this session's
#                idle count in ~/.claude/queue-idle/<session-id> and prints
#                `idle <count>/<max>`; exit 1 when the count reached <max>
#                (stop the loop), 0 otherwise.
# worked         An iteration that released an issue: resets the idle count.
# stop           The loop stops: measures this session's main transcript since
#                the loop start (`agent-tokens.py --session --since`), appends
#                one `runner` row with `queue-claim.sh log-runner`, removes the
#                start and prints `runner: <summary>`. A failed measurement
#                writes the row with unknown tokens and prints
#                `runner tokens: unknown (<why>)`; without a recorded start it
#                writes nothing and says so. Exit 0 either way.
#
# QUEUE_RUNS_LOG, QUEUE_STOP_FILE and QUEUE_IDLE_DIR override the three paths.
#
# Exit codes:
#   0  continue
#   1  stop the loop (the printed line says why)
#   2  usage error, or the idle file cannot be written

set -uo pipefail

RUNS_LOG="${QUEUE_RUNS_LOG:-$HOME/.claude/queue-runs.tsv}"
STOP_FILE="${QUEUE_STOP_FILE:-$HOME/.claude/queue-stop}"
IDLE_DIR="${QUEUE_IDLE_DIR:-$HOME/.claude/queue-idle}"
# Column of the session id in the run log (queue-claim.sh, SESSION_COLUMN).
SESSION_FIELD=10
# The id becomes a file name: no slashes, no dot-only names.
SESSION_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
# Column of the outcome; rows with the runner outcome (queue-claim.sh
# RUNNER_OUTCOME) are not releases (#270).
OUTCOME_FIELD=3
RUNNER_OUTCOME="runner"
# The loop start, next to the idle count: <idle-dir>/<session-id>.start.
START_SUFFIX=".start"
# Sibling scripts that `stop` calls.
BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_TOKENS="$BIN_DIR/agent-tokens.py"
QUEUE_CLAIM="$BIN_DIR/queue-claim.sh"

usage() {
    echo "usage: $(basename "$0") gate <budget> | idle <max-idle> | worked | stop" >&2
    exit 2
}

positive() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

[[ $# -ge 1 ]] || usage
case "$1" in
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac
command="$1"; shift

case "$command" in
    gate|idle) [[ $# -eq 1 ]] && positive "$1" || usage; limit="$1" ;;
    worked|stop) [[ $# -eq 0 ]] || usage ;;
    *) echo "unknown command: $command" >&2; usage ;;
esac

# session_ok: prints why and returns 1 when the session id is unusable.
session_ok() {
    if [[ ! "$SESSION_ID" =~ $SESSION_ID_PATTERN ]]; then
        echo "stop: CLAUDE_CODE_SESSION_ID is unset or not a plain id; the budget cannot be counted"
        return 1
    fi
}

idle_file() { echo "$IDLE_DIR/$SESSION_ID"; }
start_file() { echo "$IDLE_DIR/$SESSION_ID$START_SUFFIX"; }

do_gate() {
    if [[ -e "$STOP_FILE" ]]; then
        echo "stop: stop file $STOP_FILE exists (remove it before the next loop)"
        return 1
    fi
    session_ok || return 1
    local used=0
    if [[ -f "$RUNS_LOG" ]]; then
        used=$(awk -F'\t' -v s="$SESSION_ID" -v f="$SESSION_FIELD" \
            -v of="$OUTCOME_FIELD" -v runner="$RUNNER_OUTCOME" \
            'NR > 1 && NF >= f && $f == s && $of != runner { n++ } END { print n + 0 }' "$RUNS_LOG")
    fi
    if (( used >= limit )); then
        echo "stop: budget used up ($used/$limit)"
        return 1
    fi
    record_start
    echo "budget $used/$limit"
}

# record_start: the loop start, written by the first gate that lets the loop
# go on; a later gate leaves it. Not writable is a warning: the budget still
# works, only the runner's own tokens stay unknown at stop.
record_start() {
    local file
    file=$(start_file)
    [[ -e "$file" ]] && return 0
    { mkdir -p "$IDLE_DIR" && date -u +%Y-%m-%dT%H:%M:%SZ > "$file"; } 2>/dev/null \
        || echo "warning: cannot write the loop start '$file'" >&2
}

# do_stop: the runner session's own tokens since the loop start, as one
# `runner` row in the run log (#270). A failed measurement still writes the
# row, with unknown tokens. Always exit 0 once the session id is usable.
do_stop() {
    session_ok || return 1
    local file since tokens err reason
    file=$(start_file)
    if [[ ! -f "$file" ]]; then
        echo "runner tokens: unknown (no loop start recorded; nothing measured)"
        return 0
    fi
    since=$(< "$file")
    tokens=$(mktemp)
    err=$(mktemp)
    if "$AGENT_TOKENS" --session "$SESSION_ID" --since "$since" --json > "$tokens" 2> "$err"; then
        "$QUEUE_CLAIM" --tokens "$tokens" log-runner
        echo "runner: $(jq -r .summary "$tokens")"
    else
        reason=$(head -1 "$err")
        "$QUEUE_CLAIM" log-runner
        echo "runner tokens: unknown (${reason:-agent-tokens.py failed})"
    fi
    rm -f "$tokens" "$err" "$file"
    return 0
}

do_idle() {
    session_ok || return 1
    local file count=0
    file=$(idle_file)
    if [[ -f "$file" ]]; then
        count=$(< "$file")
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
    fi
    count=$((count + 1))
    { mkdir -p "$IDLE_DIR" && echo "$count" > "$file"; } 2>/dev/null \
        || { echo "error: cannot write the idle count '$file'" >&2; exit 2; }
    if (( count >= limit )); then
        echo "stop: idle $count/$limit"
        return 1
    fi
    echo "idle $count/$limit"
}

do_worked() {
    session_ok || return 1
    rm -f "$(idle_file)"
}

case "$command" in
    gate)   do_gate ;;
    idle)   do_idle ;;
    worked) do_worked ;;
    stop)   do_stop ;;
esac
