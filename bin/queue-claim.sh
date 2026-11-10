#!/usr/bin/env bash
# queue-claim.sh: claim and release issues of the agent queue (queue runner).
#
# Usage:
#   queue-claim.sh [--repo <dir>] claim
#   queue-claim.sh [--repo <dir>] [--tokens <json-file>] release <N> pr <url>
#   queue-claim.sh [--repo <dir>] [--tokens <json-file>] release <N> escalated
#   queue-claim.sh [--repo <dir>] [--tokens <json-file>] release <N> failed <message-file>
#
# Works on the GitHub repository of <dir> (default: the current directory).
# The labels are described in docs/escalation-list.md.
#
# --tokens  the `agent-tokens.py --json` output for the issue's sub-agent
#           tree. Every release comment carries one `tokens: <summary>` line,
#           or `tokens: unknown` without this option.
#
# Every release appends one row to the run log ~/.claude/queue-runs.tsv
# (QUEUE_RUNS_LOG overrides the path): date, issue, outcome, PR URL (empty
# when none), the four token totals and the agent count, `unknown` in those
# five columns without --tokens. A new file gets a header line first. The row
# is written once the labels are updated; a log that cannot be written is a
# warning, not a failed release.
#
# claim     Takes the oldest open `agent-ready` issue (by creation date) that
#           has none of `agent-wip`, `needs-human` or `epic`, adds `agent-wip`
#           and prints its number. Prints nothing when the queue is empty.
#           Labels are not atomic, so each candidate is re-read right before
#           and right after the claim: claimed by someone else in between,
#           skip it; no longer claimable after our claim (closed, escalated,
#           made an epic), drop our `agent-wip` again. Either way the next
#           candidate is tried. An `agent-failed` issue is claimable: that is
#           its one retry.
# release   Ends a claim; every outcome drops `agent-wip`:
#   pr <url>               comments with the PR link.
#   escalated              /refine or the escalation hook already posted the
#                          question; adds `needs-human` only when it is missing
#                          (with a warning), so the issue is never re-claimed.
#                          Comments only the token line; /refine never reads a
#                          `<!-- queue-runner -->` comment as the answer.
#   failed <message-file>  comments with the file's text (the error and what
#                          was attempted). First failure: adds `agent-failed`,
#                          the issue returns to the queue for one retry. When
#                          it already has `agent-failed`: adds `needs-human`
#                          as well, so no later claim takes it (#188, D5).
#
# Exit codes:
#   0  done (claim: a number, or nothing for an empty queue)
#   1  gh failed (stderr says which call); the labels may be half-changed
#   2  usage error or <dir> is not usable

set -uo pipefail

READY_LABEL="agent-ready"
WIP_LABEL="agent-wip"
HUMAN_LABEL="needs-human"
EPIC_LABEL="epic"
FAILED_LABEL="agent-failed"
# Labels that make an agent-ready issue unclaimable (#188, D7 for epic).
SKIP_LABELS=("$WIP_LABEL" "$HUMAN_LABEL" "$EPIC_LABEL")
# gh issue list returns 30 issues by default; the queue is never this long.
GH_FETCH_LIMIT=200
COMMENT_MARKER="<!-- queue-runner -->"
RUNS_LOG="${QUEUE_RUNS_LOG:-$HOME/.claude/queue-runs.tsv}"
UNKNOWN="unknown"
# Keys of the agent-tokens.py --json totals, in log column order.
TOKEN_KEYS=(input_tokens cache_creation_input_tokens cache_read_input_tokens output_tokens)

usage() {
    echo "usage: $(basename "$0") [--repo <dir>] claim | [--tokens <json-file>] release <N> pr <url> | ... release <N> escalated | ... release <N> failed <message-file>" >&2
    exit 2
}

repo=""
tokens_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        --repo) [[ $# -ge 2 ]] || usage; repo="$2"; shift 2 ;;
        --repo=*) repo="${1#*=}"; shift ;;
        --tokens) [[ $# -ge 2 ]] || usage; tokens_file="$2"; shift 2 ;;
        --tokens=*) tokens_file="${1#*=}"; shift ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) break ;;
    esac
done

[[ $# -ge 1 ]] || usage
command="$1"; shift

# Validate all arguments before touching anything.
case "$command" in
    claim)
        [[ $# -eq 0 ]] || usage
        [[ -z "$tokens_file" ]] || { echo "error: --tokens belongs to release" >&2; usage; }
        ;;
    release)
        [[ $# -ge 2 ]] || usage
        issue="$1"; outcome="$2"; shift 2
        [[ "$issue" =~ ^[0-9]+$ ]] || { echo "error: issue must be a number: '$issue'" >&2; usage; }
        case "$outcome" in
            pr)        [[ $# -eq 1 && -n "$1" ]] || usage; pr_url="$1" ;;
            escalated) [[ $# -eq 0 ]] || usage ;;
            failed)    [[ $# -eq 1 ]] || usage; message_file="$1"
                       [[ -f "$message_file" ]] || { echo "error: message file not found: '$message_file'" >&2; exit 2; } ;;
            *) echo "unknown outcome: $outcome" >&2; usage ;;
        esac
        # Token line for the comment and the five log columns.
        tokens_line="tokens: $UNKNOWN"
        token_columns=("$UNKNOWN" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN" "$UNKNOWN")
        if [[ -n "$tokens_file" ]]; then
            [[ -f "$tokens_file" ]] || { echo "error: tokens file not found: '$tokens_file'" >&2; exit 2; }
            jq_cols=$(printf '.totals.%s, ' "${TOKEN_KEYS[@]}")
            parsed=$(jq -er "(${jq_cols}.agents | numbers | tostring), .summary | strings" "$tokens_file" 2>/dev/null) \
                || { echo "error: not agent-tokens.py --json output: '$tokens_file'" >&2; exit 2; }
            mapfile -t parsed_lines <<< "$parsed"
            [[ ${#parsed_lines[@]} -eq 6 ]] \
                || { echo "error: not agent-tokens.py --json output: '$tokens_file'" >&2; exit 2; }
            token_columns=("${parsed_lines[@]:0:5}")
            tokens_line="tokens: ${parsed_lines[5]}"
        fi
        ;;
    *) echo "unknown command: $command" >&2; usage ;;
esac

if [[ -n "$repo" ]]; then
    cd "$repo" 2>/dev/null || { echo "error: cannot cd into '$repo'" >&2; exit 2; }
fi

gh_fail() {
    echo "error: gh could not $*" >&2
    exit 1
}

# labels_of <N>: the issue's labels, one per line, prefixed by `state:<STATE>`.
labels_of() {
    gh issue view "$1" --json state,labels \
        --jq '"state:" + .state, .labels[].name'
}

# claimable <labels-of-output>: open, agent-ready, and no skip label.
claimable() {
    grep -qxF "state:OPEN" <<< "$1" || return 1
    grep -qxF -- "$READY_LABEL" <<< "$1" || return 1
    local l
    for l in "${SKIP_LABELS[@]}"; do
        grep -qxF -- "$l" <<< "$1" && return 1
    done
    return 0
}

do_claim() {
    local skip_filter candidates n before after
    skip_filter=$(printf '"%s",' "${SKIP_LABELS[@]}"); skip_filter="[${skip_filter%,}]"
    candidates=$(gh issue list --state open --label "$READY_LABEL" \
            --search "sort:created-asc" --limit "$GH_FETCH_LIMIT" \
            --json number,createdAt,labels \
            --jq "map(select([.labels[].name] - $skip_filter == [.labels[].name]))
                  | sort_by(.createdAt, .number) | .[].number") \
        || gh_fail "list the open '$READY_LABEL' issues"

    for n in $candidates; do
        # The list may be stale: someone may have claimed it since.
        before=$(labels_of "$n") || gh_fail "read the labels of #$n"
        claimable "$before" || continue

        gh issue edit "$n" --add-label "$WIP_LABEL" >/dev/null \
            || gh_fail "add '$WIP_LABEL' to #$n"

        after=$(labels_of "$n") || gh_fail "re-read the labels of #$n after claiming it"
        # Our own agent-wip is expected now; judge the rest.
        if claimable "$(grep -vxF -- "$WIP_LABEL" <<< "$after")"; then
            echo "$n"
            return 0
        fi
        echo "lost #$n while claiming it (its labels changed); releasing it" >&2
        gh issue edit "$n" --remove-label "$WIP_LABEL" >/dev/null \
            || gh_fail "drop '$WIP_LABEL' from #$n after a lost race"
    done
    return 0
}

# comment <N> <body-file>
comment() {
    gh issue comment "$1" --body-file "$2" >/dev/null || gh_fail "comment on #$1"
}

do_release() {
    local body labels edit_args
    body=$(mktemp)
    # Expanded now: the EXIT trap fires after this local is gone (set -u).
    trap "rm -f '$body'" EXIT
    edit_args=(--remove-label "$WIP_LABEL")

    case "$outcome" in
        pr)
            printf '%s\nQueue runner opened %s for this issue.\n\n%s\n' \
                "$COMMENT_MARKER" "$pr_url" "$tokens_line" > "$body"
            comment "$issue" "$body"
            ;;
        escalated)
            labels=$(labels_of "$issue") || gh_fail "read the labels of #$issue"
            if ! grep -qxF -- "$HUMAN_LABEL" <<< "$labels"; then
                echo "warning: #$issue was released as escalated but had no '$HUMAN_LABEL'; adding it" >&2
                edit_args+=(--add-label "$HUMAN_LABEL")
            fi
            # Not an answer to the escalation: /refine skips this marker.
            printf '%s\nQueue runner released this issue as escalated; it waits for a human.\n\n%s\n' \
                "$COMMENT_MARKER" "$tokens_line" > "$body"
            comment "$issue" "$body"
            ;;
        failed)
            labels=$(labels_of "$issue") || gh_fail "read the labels of #$issue"
            {
                echo "$COMMENT_MARKER"
                if grep -qxF -- "$FAILED_LABEL" <<< "$labels"; then
                    edit_args+=(--add-label "$HUMAN_LABEL")
                    echo "## Queue runner: second failure, needs a human"
                    echo
                    echo "The runner failed on this issue twice. It now has \`$HUMAN_LABEL\` and will not be claimed again until a human removes that label."
                else
                    edit_args+=(--add-label "$FAILED_LABEL")
                    echo "## Queue runner: run failed"
                    echo
                    echo "The issue is back in the queue with \`$FAILED_LABEL\` for one retry. A second failure adds \`$HUMAN_LABEL\`."
                fi
                echo
                cat "$message_file"
                echo
                echo "$tokens_line"
            } > "$body"
            comment "$issue" "$body"
            ;;
    esac

    gh issue edit "$issue" "${edit_args[@]}" >/dev/null \
        || gh_fail "update the labels of #$issue"
    log_run
}

# log_run: one row in the run log, the header first when the file is new.
log_run() {
    local row
    row=$(printf '%s\t' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$issue" "$outcome" "${pr_url:-}" "${token_columns[@]}")
    {
        mkdir -p "$(dirname "$RUNS_LOG")" &&
        if [[ ! -s "$RUNS_LOG" ]]; then
            printf 'date\tissue\toutcome\tpr_url\t%s\tagents\n' "$(IFS=$'\t'; echo "${TOKEN_KEYS[*]}")" > "$RUNS_LOG"
        fi &&
        printf '%s\n' "${row%$'\t'}" >> "$RUNS_LOG"
    } 2>/dev/null || echo "warning: could not append to the run log '$RUNS_LOG'" >&2
}

case "$command" in
    claim) do_claim ;;
    release) do_release ;;
esac
