#!/usr/bin/env bash
# batch-issue-search.sh — search GitHub issues with several queries in one call.
#
# Replaces the duplicate-check loop
#   for q in "a" "b"; do gh issue list --search "$q" ...; done
# whose first word is `for`, so permission matching never sees `gh` and every
# such check prompts. This wrapper is a single command and matches
# Bash(~/.claude/bin/*).
#
# Usage:
#   batch-issue-search.sh [--repo <owner/repo>] [--state open|closed|all]
#                         [--limit N] [--] <query> [query...]
#
#   --repo   repository to search; default: the one gh finds from the
#            current directory
#   --state  default all: a duplicate check needs the closed issues too
#   --limit  hits per query, default 10
#
# Output:
#   One group per query, in argument order: a `== <query>` header, then one
#   line per hit, `#N STATE title`, or `(no hits)`.
#   Then `== Summary`: every matched issue once, with the queries that found
#   it, the issue found by most queries first. That one is the likeliest
#   duplicate. With no hits at all the summary says `no matches`.
#
# Exit codes:
#   0  every search ran (zero hits is an answer, not an error)
#   1  at least one gh call failed; its stderr is passed through and the
#      remaining queries still run
#   2  usage error
#
# Examples:
#   batch-issue-search.sh "login bug" "auth error" "session expired"
#   batch-issue-search.sh --repo owner/repo --state open --limit 5 "dark mode"

set -uo pipefail

STATE="all"
LIMIT=10
REPO_ARGS=()
QUERIES=()

usage() {
  echo "usage: $(basename "$0") [--repo <owner/repo>] [--state open|closed|all] [--limit N] <query> [query...]" >&2
  exit 2
}

need_value() { # option remaining-arg-count
  [[ "$2" -ge 2 ]] || { echo "$1 needs a value" >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  need_value "$1" $#; REPO_ARGS=(--repo "$2"); shift 2 ;;
    --state)
      need_value "$1" $#
      case "$2" in
        open|closed|all) STATE="$2" ;;
        *) echo "--state must be open, closed or all: $2" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --limit)
      need_value "$1" $#
      case "$2" in
        ''|*[!0-9]*|0) echo "--limit must be a positive integer: $2" >&2; exit 2 ;;
      esac
      LIMIT="$2"; shift 2 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    --) shift; QUERIES+=("$@"); break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) QUERIES+=("$1"); shift ;;
  esac
done

[[ ${#QUERIES[@]} -gt 0 ]] || usage

FAILED=0
declare -A FOUND_BY=()   # issue number -> "q1", "q2"
declare -A HIT_COUNT=()  # issue number -> how many queries found it
declare -A LINE_OF=()    # issue number -> "#N STATE title"

for query in "${QUERIES[@]}"; do
  echo "== $query"
  if ! json=$(gh issue list "${REPO_ARGS[@]}" --state "$STATE" --limit "$LIMIT" \
      --search "$query" --json number,state,title); then
    echo "(gh failed)"
    FAILED=1
    continue
  fi
  # number<TAB>"#N STATE title" per hit; titles cannot hold a newline.
  if ! lines=$(jq -r '.[] | "\(.number)\t#\(.number) \(.state) \(.title)"' <<< "$json"); then
    echo "(unreadable gh output)"
    FAILED=1
    continue
  fi
  if [[ -z "$lines" ]]; then
    echo "(no hits)"
    continue
  fi
  while IFS=$'\t' read -r number line; do
    echo "$line"
    LINE_OF[$number]="$line"
    HIT_COUNT[$number]=$(( ${HIT_COUNT[$number]:-0} + 1 ))
    FOUND_BY[$number]="${FOUND_BY[$number]:+${FOUND_BY[$number]}, }\"$query\""
  done <<< "$lines"
done

echo "== Summary"
if [[ ${#HIT_COUNT[@]} -eq 0 ]]; then
  echo "no matches"
else
  # Most queries first, then by issue number.
  for number in "${!HIT_COUNT[@]}"; do
    printf '%s\t%s\n' "${HIT_COUNT[$number]}" "$number"
  done | sort -t$'\t' -k1,1nr -k2,2n | while IFS=$'\t' read -r count number; do
    echo "${LINE_OF[$number]}  <- $count: ${FOUND_BY[$number]}"
  done
fi

exit "$FAILED"
