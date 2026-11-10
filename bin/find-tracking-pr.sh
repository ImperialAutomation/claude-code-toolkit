#!/bin/bash
# find-tracking-pr.sh: find the open tracking PR for a parent issue.
#
# Usage:
#   find-tracking-pr.sh <repo> <issue-number> [--exclude <pr-number>]...
#
# Looks by branch name first, then by PR body, and prints a JSON array holding
# the first matching open PR (number, title, body).
#
#   branch  headRefName is issue-<issue> or starts with issue-<issue>-, so
#           issue-<issue>0-x does not count
#   body    a closing keyword (close/closes/closed, fix/fixes/fixed,
#           resolve/resolves/resolved, any case) directly followed by
#           #<issue>, so "Part of #<issue>" or "Closes #<issue>0" does not count
#
# GitHub search matches loose terms, not phrases: a sub-issue PR saying
# "Closes #<sub>. Part of #<issue>." comes back for <issue>. The script
# therefore fetches up to 20 candidates per lookup and filters them exactly
# itself (#200).
#
# --exclude <pr-number> (repeatable) skips that PR in both lookups. /implement
# passes the PR it just created, so it never mistakes its own PR for the
# tracking PR.
#
# Exit codes:
#   0  found, JSON on stdout
#   1  no open tracking PR found
#   2  usage error, or gh failed (stderr says why)

set -uo pipefail

CANDIDATE_LIMIT=20
CLOSING_KEYWORD='(close[sd]?|fix(e[sd])?|resolve[sd]?)'

usage() {
    echo "usage: $(basename "$0") <repo> <issue-number> [--exclude <pr-number>]..." >&2
    echo "example: $(basename "$0") owner/repo 723 --exclude 801" >&2
    exit 2
}

positionals=()
excludes=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        --exclude)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "error: --exclude needs a PR number" >&2; usage; }
            excludes+=("$2"); shift 2 ;;
        -*) echo "unknown argument: $1" >&2; usage ;;
        *) positionals+=("$1"); shift ;;
    esac
done

[[ ${#positionals[@]} -eq 2 ]] || usage
REPO="${positionals[0]}"
ISSUE="${positionals[1]}"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { echo "error: issue number must be numeric: $ISSUE" >&2; usage; }

EXCLUDE_JSON=$(printf '%s\n' "${excludes[@]+"${excludes[@]}"}" | jq -cR 'select(length > 0) | tonumber' | jq -cs '.')

# lookup <search> <jq-condition on a PR>: print the first open PR whose
# condition holds and whose number is not excluded, as a one-element array.
lookup() {
    local raw
    if ! raw=$(gh pr list --repo "$REPO" --search "$1" --state open \
            --json number,title,body,headRefName --limit "$CANDIDATE_LIMIT"); then
        echo "error: gh could not search the PRs of $REPO" >&2
        exit 2
    fi
    jq -c --argjson exclude "$EXCLUDE_JSON" --arg issue "$ISSUE" --arg kw "$CLOSING_KEYWORD" "
        [ .[]
          | select(.number as \$n | \$exclude | index(\$n) | not)
          | select($2)
          | {number, title, body} ][:1]
        | select(length > 0)" <<< "$raw"
}

result=$(lookup "head:issue-$ISSUE" '.headRefName | test("^issue-" + $issue + "(-|$)")') || exit
if [[ -z "$result" ]]; then
    result=$(lookup "\"Closes #$ISSUE\" in:body" \
        '(.body // "") | test("(^|[^[:alnum:]_])" + $kw + ":? +#" + $issue + "([^0-9]|$)"; "i")') || exit
fi

if [[ -n "$result" ]]; then
    echo "$result"
    exit 0
fi

echo "No open tracking PR found for issue #$ISSUE" >&2
exit 1
