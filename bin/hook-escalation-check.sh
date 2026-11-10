#!/usr/bin/env bash
# hook-escalation-check.sh — PreToolUse hook (matcher Bash): refuse to open a
# PR for an autonomous run whose diff hits an unapproved escalation category.
#
# Fires on PR creation at COMMAND POSITION only: `git-push-pr-merge.sh` (any
# path spelling) or `gh pr create`, at the start of the command or after a
# `;`/`&`/`|` separator, optionally behind `VAR=value` assignments. The same
# anchor as hook-check-agent-review.sh, so `grep x bin/git-push-pr-merge.sh`
# does not fire.
#
# What it reads from the command:
#   worktree   git-push-pr-merge.sh: its --repo; gh pr create: the hook
#              input's cwd (its --repo/-R names a GitHub repo, passed on to gh).
#              Fallback: $PWD.
#   base       --base (or gh's -B); none: escalation-check.sh detects it.
#   body       --body-file (or gh's -F). With no body file, or `-` (stdin),
#              the command text itself is the body: an inline --body or a
#              heredoc is part of it.
#
# Every `Closes|Fixes|Resolves #N` in the body (any tense, any case) names an
# issue whose labels are fetched with `gh issue view`.
#
#   Autonomous  (a closed issue has `agent-wip`): runs escalation-check.sh. A
#               hit is approved when EVERY agent-wip issue carries
#               `approved:<category>`. Any unapproved hit: deny (exit 2) with
#               the escalation hint. All approved: allow, hits on stderr.
#   Interactive (no agent-wip, or no closing keyword): hits on stderr, never
#               blocks.
#
# Fails closed: a missing body file, labels gh cannot fetch, or a check that
# cannot run in an autonomous session all deny. It denies, never asks: an ask
# hangs an unattended session.
#
# Installation: settings.json, PreToolUse, matcher "Bash":
#   { "type": "command", "command": "~/.claude/bin/hook-escalation-check.sh" }
#
# Exit codes:
#   0 = allow
#   2 = deny (reason on stderr, shown to Claude)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$SCRIPT_DIR/escalation-check.sh"
NAME="hook-escalation-check.sh"

CMD_MATCH='(^|[;&|]\s*)([A-Za-z_][A-Za-z0-9_]*=[^ ]*\s+)*([^ ]*git-push-pr-merge\.sh|gh\s+pr\s+create)\b'
CLOSING_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#[0-9]+'
WIP_LABEL="agent-wip"
APPROVED_PREFIX="approved:"

deny() {
    echo "BLOCKED by $NAME: $*" >&2
    exit 2
}

INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ -n "$COMMAND" ]] || exit 0
grep -qE -- "$CMD_MATCH" <<< "$COMMAND" || exit 0

CWD=$(jq -r '.cwd // empty' <<< "$INPUT" 2>/dev/null) || CWD=""
[[ -n "$CWD" ]] || CWD="$PWD"

# The PR call and its arguments, from the matched command onward.
PR_ARGS=$(grep -oE -- "${CMD_MATCH}.*" <<< "$COMMAND" | head -1)
IS_WRAPPER=false
grep -qE 'git-push-pr-merge\.sh' <<< "${PR_ARGS%%[;&|]*}" && IS_WRAPPER=true

unquote() {
    local v="$1"
    v="${v#[\"\']}"; v="${v%[\"\']}"
    printf '%s' "${v/#\~/$HOME}"
}

REPO_ARG="" BASE="" BODY_FILE=""
read -ra TOK <<< "$PR_ARGS"
for ((i = 0; i < ${#TOK[@]}; i++)); do
    t="${TOK[i]}"
    next="${TOK[i + 1]:-}"
    case "$t" in
        ';'|'&&'|'||'|'|'|'&') [[ $i -gt 0 ]] && break ;;
        --repo|-R)        REPO_ARG="$next" ;;
        --repo=*|-R=*)    REPO_ARG="${t#*=}" ;;
        -R?*)             REPO_ARG="${t#-R}" ;;
        --base|-B)        BASE="$next" ;;
        --base=*|-B=*)    BASE="${t#*=}" ;;
        -B?*)             BASE="${t#-B}" ;;
        --body-file|-F)   BODY_FILE="$next" ;;
        --body-file=*|-F=*) BODY_FILE="${t#*=}" ;;
        -F?*)             BODY_FILE="${t#-F}" ;;
    esac
done
REPO_ARG=$(unquote "$REPO_ARG")
BASE=$(unquote "$BASE")
BODY_FILE=$(unquote "$BODY_FILE")

GH_REPO=()
if $IS_WRAPPER; then
    WORKTREE="${REPO_ARG:-$CWD}"
else
    WORKTREE="$CWD"
    [[ -n "$REPO_ARG" ]] && GH_REPO=(--repo "$REPO_ARG")
fi
[[ "$WORKTREE" == /* ]] || WORKTREE="$CWD/$WORKTREE"

if [[ -z "$BODY_FILE" || "$BODY_FILE" == "-" ]]; then
    BODY_TEXT="$COMMAND"
else
    [[ "$BODY_FILE" == /* ]] || BODY_FILE="$CWD/$BODY_FILE"
    [[ -f "$BODY_FILE" ]] \
        || deny "--body-file '$BODY_FILE' does not exist, so this hook cannot tell an autonomous run from an interactive one. Write the body file first, then re-run."
    BODY_TEXT=$(cat "$BODY_FILE")
fi

mapfile -t ISSUES < <(grep -oiE -- "$CLOSING_RE" <<< "$BODY_TEXT" | grep -oE '[0-9]+$' | sort -un)

WIP_ISSUES=()
declare -A LABELS=()
for n in "${ISSUES[@]}"; do
    if ! labels=$(env -C "$WORKTREE" gh issue view "$n" "${GH_REPO[@]}" --json labels --jq '.labels[].name' 2>&1); then
        deny "could not fetch the labels of issue #$n with gh (${labels//$'\n'/ }), so this hook cannot tell an autonomous run from an interactive one. Opening the PR needs gh too: fix gh, then re-run."
    fi
    LABELS[$n]="$labels"
    grep -qxF -- "$WIP_LABEL" <<< "$labels" && WIP_ISSUES+=("$n")
done

CHECK_ARGS=(--repo "$WORKTREE")
[[ -n "$BASE" ]] && CHECK_ARGS+=(--base "$BASE")
CHECK_OUT=$(bash "$CHECK" "${CHECK_ARGS[@]}" 2>&1)
CHECK_RC=$?

if [[ ${#WIP_ISSUES[@]} -eq 0 ]]; then
    case $CHECK_RC in
        0) ;;
        1) printf '%s: escalation hits (interactive session, not blocking):\n%s\n' "$NAME" "$CHECK_OUT" >&2 ;;
        *) printf '%s: escalation check could not run (interactive session, not blocking):\n%s\n' "$NAME" "$CHECK_OUT" >&2 ;;
    esac
    exit 0
fi

WIP_LIST=$(printf '#%s ' "${WIP_ISSUES[@]}"); WIP_LIST="${WIP_LIST% }"

case $CHECK_RC in
    0) exit 0 ;;
    1) ;;
    *) deny "the escalation check could not run for this autonomous run ($WIP_LIST has $WIP_LABEL): ${CHECK_OUT//$'\n'/ }" ;;
esac

# approved <category>: every agent-wip issue carries approved:<category>.
approved() {
    local n
    for n in "${WIP_ISSUES[@]}"; do
        grep -qxF -- "$APPROVED_PREFIX$1" <<< "${LABELS[$n]}" || return 1
    done
    return 0
}

APPROVED_HITS="" BLOCKED_HITS="" BLOCKED_KEYS=""
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%  *}"
    if approved "$key"; then
        APPROVED_HITS+="$line"$'\n'
    else
        BLOCKED_HITS+="$line"$'\n'
        case " $BLOCKED_KEYS " in *" $key "*) ;; *) BLOCKED_KEYS="${BLOCKED_KEYS:+$BLOCKED_KEYS }$key" ;; esac
    fi
done <<< "$CHECK_OUT"

if [[ -n "$BLOCKED_HITS" ]]; then
    {
        echo "BLOCKED by $NAME: escalation required (docs/escalation-list.md)."
        echo "This is an autonomous run ($WIP_LIST has $WIP_LABEL) and the diff hits categories without approval: $BLOCKED_KEYS"
        printf '%s' "$BLOCKED_HITS"
        echo "Do not open the PR and do not work around this check. Post a comment on $WIP_LIST holding the question, the options and your recommendation, add the needs-human label (gh issue edit <n> --add-label needs-human), and stop. A human approves a category by adding the approved:<category> label to the issue."
    } >&2
    exit 2
fi

printf '%s: approved escalation hits (%s):\n%s' "$NAME" "$WIP_LIST" "$APPROVED_HITS" >&2
exit 0
