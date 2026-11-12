#!/usr/bin/env bash
# queue-budget.sh: the stop conditions of one /loop /queue-run (#251).
#
# Usage:
#   queue-budget.sh gate <budget>
#   queue-budget.sh idle <max-idle>
#   queue-budget.sh worked
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
#                  columns (#297) come after it and do not move it.
#                Otherwise prints `budget <used>/<budget>` and exits 0.
# idle <max>     An iteration that claimed nothing. Adds one to this session's
#                idle count in ~/.claude/queue-idle/<session-id> and prints
#                `idle <count>/<max>`; exit 1 when the count reached <max>
#                (stop the loop), 0 otherwise.
# worked         An iteration that released an issue: resets the idle count.
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

usage() {
    echo "usage: $(basename "$0") gate <budget> | idle <max-idle> | worked" >&2
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
    worked)    [[ $# -eq 0 ]] || usage ;;
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

do_gate() {
    if [[ -e "$STOP_FILE" ]]; then
        echo "stop: stop file $STOP_FILE exists (remove it before the next loop)"
        return 1
    fi
    session_ok || return 1
    local used=0
    if [[ -f "$RUNS_LOG" ]]; then
        used=$(awk -F'\t' -v s="$SESSION_ID" -v f="$SESSION_FIELD" \
            'NR > 1 && NF >= f && $f == s { n++ } END { print n + 0 }' "$RUNS_LOG")
    fi
    if (( used >= limit )); then
        echo "stop: budget used up ($used/$limit)"
        return 1
    fi
    echo "budget $used/$limit"
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
esac
