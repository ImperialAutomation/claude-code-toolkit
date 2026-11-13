#!/usr/bin/env bash
# queue-claim.sh: claim and release issues of the agent queue (queue runner).
#
# Usage:
#   queue-claim.sh [--repo <dir>] claim [--rework]
#   queue-claim.sh [--repo <dir>] [<release-options>] release <N> pr <url> [<message-file>]
#   queue-claim.sh [--repo <dir>] [<release-options>] release <N> rework <url> [<message-file>]
#   queue-claim.sh [--repo <dir>] [<release-options>] release <N> escalated
#   queue-claim.sh [--repo <dir>] [<release-options>] release <N> failed <message-file>
#
# Works on the GitHub repository of <dir> (default: the current directory).
# The labels are described in docs/escalation-list.md.
#
# Release options, each optional; all but --tokens only fill run log columns:
# --tokens <json-file>         the `agent-tokens.py --json` output for the
#                              issue's whole sub-agent tree. Every release
#                              comment carries one `tokens: <summary>` line,
#                              or `tokens: unknown` without this option. A
#                              missing or malformed file is a usage error.
# --review <verdict>           verdict of the first review: APPROVE, BLOCKING,
#                              HUMAN, or error (no review could be posted).
# --review-final <verdict>     verdict after the fix round, same values.
# --review-findings <count>    number of findings in the first review.
# --review-tokens <json-file>  `agent-tokens.py --json` of the review phase.
# --fix-tokens <json-file>     `agent-tokens.py --json` of the fix round.
# A --review-tokens or --fix-tokens file that is missing or malformed is a
# warning: that phase's token columns stay empty and the release goes on.
#
# Every release appends one row to the run log ~/.claude/queue-runs.tsv
# (QUEUE_RUNS_LOG overrides the path): date, issue, outcome, PR URL (empty
# when none), the four token totals and the agent count, `unknown` in those
# five columns without --tokens, the session id ($CLAUDE_CODE_SESSION_ID,
# empty when unset) that queue-budget.sh counts as the 10th column, then
# `review`, `review_final`, `review_findings`, and the four token totals plus
# agent count of the review phase (`review_` prefix) and of the fix round
# (`fix_` prefix). Each of those is empty when its option is not given. A new
# file gets a header line first; an older header (without `session`, #251, or
# without the review columns, #297) is extended in place, keeping the file
# mode; its old rows keep their field count. The row is written once the
# labels are updated; a log that cannot be written is a warning, not a failed
# release.
#
# claim     Takes the oldest open `agent-ready` issue (by creation date) that
#           has none of `agent-wip`, `needs-human`, `epic`, `agent-pr` or
#           `agent-rework`, adds `agent-wip` and prints its number. Prints
#           nothing when the queue is empty.
#           Labels are not atomic, so each candidate is re-read right before
#           and right after the claim: claimed by someone else in between,
#           skip it; no longer claimable after our claim (closed, escalated,
#           made an epic), drop our `agent-wip` again. Either way the next
#           candidate is tried. An `agent-failed` issue is claimable: that is
#           its one retry.
# claim --rework
#           The same, for the oldest open `agent-rework` issue that has none
#           of `agent-wip`, `needs-human`, `epic` (#300, D4). Only a human sets
#           `agent-rework`, on an issue whose agent PR needs another round.
# release   Ends a claim; every outcome drops `agent-wip`:
#   pr <url>               comments with the PR link and swaps `agent-ready`
#                          for `agent-pr`, so no later claim opens a second
#                          PR. A PR closed unmerged needs a human to swap
#                          them back. The `agent-pr` label must exist in the
#                          repository.
#   pr <url> <message-file>
#                          the same, and also adds `needs-human` and puts the
#                          file's text (why a human must look, e.g. a review
#                          that could not be posted) in the comment. The PR is
#                          kept; only the human decides what happens next.
#   rework <url> [<message-file>]
#                          after a rework round on the existing PR <url>:
#                          comments like `pr` and swaps `agent-rework` for
#                          `agent-pr`. With a message file it also adds
#                          `needs-human` (a re-review that stayed BLOCKING or
#                          says HUMAN, or a finding left for the human). A
#                          failed or escalated rework uses `failed` or
#                          `escalated`, which keep `agent-rework` (#300, D5).
#   escalated             /refine or the escalation hook already posted the
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
PR_LABEL="agent-pr"
REWORK_LABEL="agent-rework"
# Labels that make an agent-ready issue unclaimable (#188, D7 for epic; #263
# for agent-pr; #300 for agent-rework, which only claim --rework takes).
SKIP_LABELS=("$WIP_LABEL" "$HUMAN_LABEL" "$EPIC_LABEL" "$PR_LABEL" "$REWORK_LABEL")
# Labels that make an agent-rework issue unclaimable (#300, D4).
REWORK_SKIP_LABELS=("$WIP_LABEL" "$HUMAN_LABEL" "$EPIC_LABEL")
# Claim order, highest first (#309); an issue without one of them sorts last.
PRIORITY_LABELS=("priority:critical" "priority:high" "priority:medium" "priority:low")
# Added to an agent-ready issue that has no priority label; claim never
# reads or removes it (#309, D1).
TRIAGE_LABEL="needs-triage"
# gh issue list returns 30 issues by default; the queue is never this long.
GH_FETCH_LIMIT=200
COMMENT_MARKER="<!-- queue-runner -->"
RUNS_LOG="${QUEUE_RUNS_LOG:-$HOME/.claude/queue-runs.tsv}"
UNKNOWN="unknown"
# Keys of the agent-tokens.py --json totals, in log column order. The review_
# and fix_ token columns are derived from it (prefixed_token_columns).
TOKEN_KEYS=(input_tokens cache_creation_input_tokens cache_read_input_tokens output_tokens)
# Last log column: the session that released, so queue-budget.sh can count
# the releases of one /loop (#251, D2). Empty when the variable is unset.
SESSION_COLUMN="session"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
# Review gate columns after `session` (#288, #297).
AGENTS_KEY="agents"
REVIEW_COLUMNS=(review review_final review_findings)
REVIEW_PREFIX="review_"
FIX_PREFIX="fix_"
REVIEW_VERDICTS=(APPROVE BLOCKING HUMAN error)

usage() {
    echo "usage: $(basename "$0") [--repo <dir>] claim [--rework] | [<release-options>] release <N> pr|rework <url> [<message-file>] | ... release <N> escalated | ... release <N> failed <message-file> (see --help)" >&2
    exit 2
}

repo=""
tokens_file=""
review=""
review_final=""
review_findings=""
review_tokens_file=""
fix_tokens_file=""
release_options=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        --repo) [[ $# -ge 2 ]] || usage; repo="$2"; shift 2 ;;
        --repo=*) repo="${1#*=}"; shift ;;
        --tokens) [[ $# -ge 2 ]] || usage; tokens_file="$2"; release_options=true; shift 2 ;;
        --tokens=*) tokens_file="${1#*=}"; release_options=true; shift ;;
        --review) [[ $# -ge 2 ]] || usage; review="$2"; release_options=true; shift 2 ;;
        --review=*) review="${1#*=}"; release_options=true; shift ;;
        --review-final) [[ $# -ge 2 ]] || usage; review_final="$2"; release_options=true; shift 2 ;;
        --review-final=*) review_final="${1#*=}"; release_options=true; shift ;;
        --review-findings) [[ $# -ge 2 ]] || usage; review_findings="$2"; release_options=true; shift 2 ;;
        --review-findings=*) review_findings="${1#*=}"; release_options=true; shift ;;
        --review-tokens) [[ $# -ge 2 ]] || usage; review_tokens_file="$2"; release_options=true; shift 2 ;;
        --review-tokens=*) review_tokens_file="${1#*=}"; release_options=true; shift ;;
        --fix-tokens) [[ $# -ge 2 ]] || usage; fix_tokens_file="$2"; release_options=true; shift 2 ;;
        --fix-tokens=*) fix_tokens_file="${1#*=}"; release_options=true; shift ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) break ;;
    esac
done

# valid_verdict <value>: empty (not given) or one of REVIEW_VERDICTS.
valid_verdict() {
    [[ -z "$1" ]] && return 0
    local v
    for v in "${REVIEW_VERDICTS[@]}"; do
        [[ "$1" == "$v" ]] && return 0
    done
    return 1
}

# read_tokens <json-file>: the four totals, the agent count and the summary of
# an agent-tokens.py --json file, one per line. Returns 1 when the file is
# missing or not that output.
read_tokens() {
    local jq_cols parsed lines
    [[ -f "$1" ]] || return 1
    jq_cols=$(printf '.totals.%s, ' "${TOKEN_KEYS[@]}")
    parsed=$(jq -er "(${jq_cols}.${AGENTS_KEY} | numbers | tostring), .summary | strings" "$1" 2>/dev/null) || return 1
    mapfile -t lines <<< "$parsed"
    [[ ${#lines[@]} -eq $(( ${#TOKEN_KEYS[@]} + 2 )) ]] || return 1
    printf '%s\n' "$parsed"
}

# phase_token_columns <phase> <json-file>: sets phase_columns to the four
# totals and the agent count of one phase; all empty when no file was given or
# the file is unusable (a warning, never a failed release).
phase_token_columns() {
    local parsed i n=$(( ${#TOKEN_KEYS[@]} + 1 ))
    phase_columns=()
    if [[ -n "$2" ]]; then
        if parsed=$(read_tokens "$2"); then
            mapfile -t phase_columns <<< "$parsed"
            phase_columns=("${phase_columns[@]:0:n}")
            return 0
        fi
        echo "warning: $1 tokens unknown, not agent-tokens.py --json output: '$2'; its columns stay empty" >&2
    fi
    for (( i = 0; i < n; i++ )); do phase_columns+=(""); done
}

[[ $# -ge 1 ]] || usage
command="$1"; shift

# Validate all arguments before touching anything.
case "$command" in
    claim)
        claim_label="$READY_LABEL"
        claim_skip=("${SKIP_LABELS[@]}")
        # A human set agent-rework, which is triage enough (#309, D3).
        needs_priority=true
        if [[ $# -eq 1 && "$1" == "--rework" ]]; then
            claim_label="$REWORK_LABEL"
            claim_skip=("${REWORK_SKIP_LABELS[@]}")
            needs_priority=false
        elif [[ $# -ne 0 ]]; then
            usage
        fi
        $release_options && { echo "error: --tokens, --review* and --fix-tokens belong to release" >&2; usage; }
        ;;
    release)
        [[ $# -ge 2 ]] || usage
        issue="$1"; outcome="$2"; shift 2
        [[ "$issue" =~ ^[0-9]+$ ]] || { echo "error: issue must be a number: '$issue'" >&2; usage; }
        case "$outcome" in
            pr|rework) [[ ( $# -eq 1 || $# -eq 2 ) && -n "$1" ]] || usage; pr_url="$1"
                       message_file="${2:-}"
                       [[ -z "$message_file" || -f "$message_file" ]] \
                           || { echo "error: message file not found: '$message_file'" >&2; exit 2; } ;;
            escalated) [[ $# -eq 0 ]] || usage ;;
            failed)    [[ $# -eq 1 ]] || usage; message_file="$1"
                       [[ -f "$message_file" ]] || { echo "error: message file not found: '$message_file'" >&2; exit 2; } ;;
            *) echo "unknown outcome: $outcome" >&2; usage ;;
        esac
        # Token line for the comment and the five log columns.
        tokens_line="tokens: $UNKNOWN"
        token_columns=()
        for key in "${TOKEN_KEYS[@]}" "$AGENTS_KEY"; do token_columns+=("$UNKNOWN"); done
        if [[ -n "$tokens_file" ]]; then
            [[ -f "$tokens_file" ]] || { echo "error: tokens file not found: '$tokens_file'" >&2; exit 2; }
            parsed=$(read_tokens "$tokens_file") \
                || { echo "error: not agent-tokens.py --json output: '$tokens_file'" >&2; exit 2; }
            mapfile -t parsed_lines <<< "$parsed"
            token_columns=("${parsed_lines[@]:0:${#token_columns[@]}}")
            tokens_line="tokens: ${parsed_lines[-1]}"
        fi
        valid_verdict "$review" \
            || { echo "error: --review must be one of ${REVIEW_VERDICTS[*]}: '$review'" >&2; usage; }
        valid_verdict "$review_final" \
            || { echo "error: --review-final must be one of ${REVIEW_VERDICTS[*]}: '$review_final'" >&2; usage; }
        [[ -z "$review_findings" || "$review_findings" =~ ^[0-9]+$ ]] \
            || { echo "error: --review-findings must be a count: '$review_findings'" >&2; usage; }
        # A bad phase measurement only warns: read here, before any gh call.
        phase_token_columns review "$review_tokens_file"
        review_token_columns=("${phase_columns[@]}")
        phase_token_columns fix "$fix_tokens_file"
        fix_token_columns=("${phase_columns[@]}")
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

# claimable <labels-of-output>: open, the claim label (agent-ready, or
# agent-rework for claim --rework), and no skip label of that claim.
claimable() {
    grep -qxF "state:OPEN" <<< "$1" || return 1
    grep -qxF -- "$claim_label" <<< "$1" || return 1
    local l
    for l in "${claim_skip[@]}"; do
        grep -qxF -- "$l" <<< "$1" && return 1
    done
    return 0
}

# prioritized <labels-of-output>: has one of PRIORITY_LABELS.
prioritized() {
    local p
    for p in "${PRIORITY_LABELS[@]}"; do
        grep -qxF -- "$p" <<< "$1" && return 0
    done
    return 1
}

# json_array <value>...: the values as a JSON array of strings.
json_array() {
    local a
    a=$(printf '"%s",' "$@")
    echo "[${a%,}]"
}

# triage <N> <has-triage-label>: report an agent-ready issue without a
# priority label and add TRIAGE_LABEL when it is missing (#309, D2).
triage() {
    echo "skipped #$1: no priority label; it needs '$TRIAGE_LABEL'" >&2
    [[ "$2" == true ]] && return 0
    gh issue edit "$1" --add-label "$TRIAGE_LABEL" >/dev/null \
        || gh_fail "add '$TRIAGE_LABEL' to #$1"
}

do_claim() {
    local skip_filter priorities listed n rank triaged before after
    local -a candidates=()
    skip_filter=$(json_array "${claim_skip[@]}")
    priorities=$(json_array "${PRIORITY_LABELS[@]}")
    # One line per issue: number, rank (index of its first priority label,
    # past the end without one) and whether it has TRIAGE_LABEL.
    listed=$(gh issue list --state open --label "$claim_label" \
            --search "sort:created-asc" --limit "$GH_FETCH_LIMIT" \
            --json number,createdAt,labels \
            --jq "$priorities as \$p
                  | map(select([.labels[].name] - $skip_filter == [.labels[].name])
                        | [.labels[].name] as \$l
                        | .rank = ([\$p | to_entries[] | select(.value as \$v | \$l | index([\$v])) | .key] | first // (\$p | length))
                        | .triaged = (\$l | index([\"$TRIAGE_LABEL\"]) != null))
                  | sort_by(.rank, .createdAt, .number)
                  | .[] | \"\(.number) \(.rank) \(.triaged)\"") \
        || gh_fail "list the open '$claim_label' issues"

    # Every untriaged issue is flagged now, not only once the queue reaches it.
    while read -r n rank triaged; do
        [[ -n "$n" ]] || continue
        if $needs_priority && (( rank == ${#PRIORITY_LABELS[@]} )); then
            triage "$n" "$triaged"
        else
            candidates+=("$n")
        fi
    done <<< "$listed"

    for n in "${candidates[@]}"; do
        # The list may be stale: someone may have claimed it since.
        before=$(labels_of "$n") || gh_fail "read the labels of #$n"
        claimable "$before" || continue
        if $needs_priority && ! prioritized "$before"; then
            continue
        fi

        gh issue edit "$n" --add-label "$WIP_LABEL" >/dev/null \
            || gh_fail "add '$WIP_LABEL' to #$n"

        after=$(labels_of "$n") || gh_fail "re-read the labels of #$n after claiming it"
        # Our own agent-wip is expected now; judge the rest.
        if claimable "$(grep -vxF -- "$WIP_LABEL" <<< "$after")" \
                && { ! $needs_priority || prioritized "$after"; }; then
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
    local body labels edit_args what
    body=$(mktemp)
    # Expanded now: the EXIT trap fires after this local is gone (set -u).
    trap "rm -f '$body'" EXIT
    edit_args=(--remove-label "$WIP_LABEL")

    case "$outcome" in
        pr|rework)
            if [[ "$outcome" == pr ]]; then
                edit_args+=(--remove-label "$READY_LABEL" --add-label "$PR_LABEL")
                what="opened $pr_url for this issue"
            else
                edit_args+=(--remove-label "$REWORK_LABEL" --add-label "$PR_LABEL")
                what="reworked $pr_url; the round is listed in its last queue-runner comment on the PR"
            fi
            {
                printf '%s\nQueue runner %s.\n\n' "$COMMENT_MARKER" "$what"
                if [[ -n "$message_file" ]]; then
                    edit_args+=(--add-label "$HUMAN_LABEL")
                    printf 'It needs a human before it can be merged; it has `%s`.\n\n' "$HUMAN_LABEL"
                    cat "$message_file"
                    echo
                fi
                echo "$tokens_line"
            } > "$body"
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

# join_tab <field>...: the fields joined by tabs; empty fields are kept.
join_tab() {
    local IFS=$'\t'
    echo "$*"
}

# prefixed_token_columns <prefix>: the token column names with a prefix, one
# per line, derived from TOKEN_KEYS so the groups cannot drift apart.
prefixed_token_columns() {
    local key
    for key in "${TOKEN_KEYS[@]}" "$AGENTS_KEY"; do
        printf '%s%s\n' "$1" "$key"
    done
}

# log_run: one row in the run log, the header first when the file is new. A
# log from before the session column (#251) or the review columns (#297) gets
# its header extended; its old rows keep their nine or ten fields, so a
# nine-field row never matches a session.
log_run() {
    local row header first header_v1 header_v2 tmp
    local -a review_names fix_names
    mapfile -t review_names < <(prefixed_token_columns "$REVIEW_PREFIX")
    mapfile -t fix_names < <(prefixed_token_columns "$FIX_PREFIX")
    row=$(join_tab "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$issue" "$outcome" "${pr_url:-}" \
        "${token_columns[@]}" "$SESSION_ID" \
        "$review" "$review_final" "$review_findings" \
        "${review_token_columns[@]}" "${fix_token_columns[@]}")
    header_v1=$(join_tab date issue outcome pr_url "${TOKEN_KEYS[@]}" "$AGENTS_KEY")
    header_v2=$(join_tab "$header_v1" "$SESSION_COLUMN")
    header=$(join_tab "$header_v2" "${REVIEW_COLUMNS[@]}" "${review_names[@]}" "${fix_names[@]}")
    {
        mkdir -p "$(dirname "$RUNS_LOG")" &&
        if [[ ! -s "$RUNS_LOG" ]]; then
            printf '%s\n' "$header" > "$RUNS_LOG"
        elif first=$(head -1 "$RUNS_LOG") && [[ "$first" == "$header_v1" || "$first" == "$header_v2" ]]; then
            tmp=$(mktemp "$RUNS_LOG.XXXXXX") &&
            { printf '%s\n' "$header"; tail -n +2 "$RUNS_LOG"; } > "$tmp" &&
            # Copied back, not moved: the log keeps its own mode.
            cat "$tmp" > "$RUNS_LOG" && rm -f "$tmp"
        fi &&
        printf '%s\n' "$row" >> "$RUNS_LOG"
    } 2>/dev/null || echo "warning: could not append to the run log '$RUNS_LOG'" >&2
}

case "$command" in
    claim) do_claim ;;
    release) do_release ;;
esac
