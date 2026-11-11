#!/usr/bin/env bash
# agent-pr-wip.sh — count open agent PRs against the agent PR WIP limit.
#
# Usage:
#   agent-pr-wip.sh [--repo <dir>] [--limit <N>]
#
# Counts the open PRs labelled `agent-authored` in the GitHub repository of
# <dir> (default: the current directory) and prints `<open>/<limit>`, e.g.
# `2/3`. The limit is --limit, a positive integer (default AGENT_PR_WIP_LIMIT
# below, 3). /queue-run passes its --max-prs here (#251, D6).
#
# The label is applied by /implement to every PR it opens, so the count is
# every agent PR still waiting for human review: review time is the scarce
# resource the limit protects. The queue runner calls this before it claims an
# issue; /implement itself does not, because a human starting it is already
# deciding to add review load (#187, D3).
#
# Exit codes:
#   0  below the limit: an unattended run may claim new work
#   1  at or above the limit: do not claim
#   2  usage error, <dir> is not usable, or gh failed (stderr says why);
#      treat it as "do not claim", the count is unknown

set -uo pipefail

AGENT_PR_WIP_LIMIT=3
AGENT_PR_LABEL="agent-authored"
# gh pr list returns 30 PRs by default; fetch enough to report a real count.
GH_FETCH_LIMIT=200

usage() {
    echo "usage: $(basename "$0") [--repo <dir>] [--limit <N>]" >&2
    exit 2
}

repo=""
limit="$AGENT_PR_WIP_LIMIT"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        --repo) [[ $# -ge 2 ]] || usage; repo="$2"; shift 2 ;;
        --repo=*) repo="${1#*=}"; shift ;;
        --limit) [[ $# -ge 2 ]] || usage; limit="$2"; shift 2 ;;
        --limit=*) limit="${1#*=}"; shift ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "error: --limit must be a positive integer: '$limit'" >&2; usage; }

if [[ -n "$repo" ]]; then
    cd "$repo" 2>/dev/null || { echo "error: cannot cd into '$repo'" >&2; exit 2; }
fi

if ! open=$(gh pr list --state open --label "$AGENT_PR_LABEL" \
        --limit "$GH_FETCH_LIMIT" --json number --jq length); then
    echo "error: gh could not list the open '$AGENT_PR_LABEL' PRs" >&2
    exit 2
fi
if [[ ! "$open" =~ ^[0-9]+$ ]]; then
    echo "error: unexpected count from gh: '$open'" >&2
    exit 2
fi

echo "$open/$limit"
(( open < limit ))
