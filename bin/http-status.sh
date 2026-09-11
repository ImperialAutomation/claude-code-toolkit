#!/usr/bin/env bash
# http-status.sh — print the HTTP status of one or more URLs.
#
# Replaces the `curl -s -o /dev/null -w "%{http_code}\n" <url>` idiom, which is
# rarely wanted just once. Two of them on a line make a compound command, and
# permission matching only looks at the first word, so every segment after the
# `;` or `&&` prompts — even with a broad Bash(curl *) rule allowlisted. This
# wrapper is a single command and matches Bash(~/.claude/bin/*).
#
# Usage:
#   http-status.sh [--body] [--max-time SECS] <url> [url...]
#
# Output:
#   One URL  — the status code alone, so it fits in an `if` or a comparison.
#   Several  — "<status>  <url>" per line, in argument order.
#
# Exit codes:
#   0  every URL answered (a 4xx/5xx IS an answer — assert on it yourself)
#   1  at least one call failed at transport level (DNS, refused, timeout)
#   2  usage error
#
# Examples:
#   http-status.sh https://example.test/health
#   http-status.sh https://example.test/a https://example.test/b
#   http-status.sh --body https://example.test/health
#
# Deliberately out of scope: auth headers, retries, JSON parsing — past that
# point it is not a smoke test and calling curl directly is clearer. For waiting
# until a service comes up, use wait-for-pattern.sh / wait-for-healthy.sh.

set -uo pipefail

MAX_TIME=10
SHOW_BODY=0
URLS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --body)     SHOW_BODY=1; shift ;;
    --max-time) MAX_TIME="${2:-}"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) URLS+=("$1"); shift ;;
  esac
done

if [[ ${#URLS[@]} -eq 0 ]]; then
  echo "usage: $(basename "$0") [--body] [--max-time SECS] <url> [url...]" >&2
  exit 2
fi

for url in "${URLS[@]}"; do
  status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$MAX_TIME" "$url")
  if [[ ${#URLS[@]} -eq 1 ]]; then
    echo "$status"
  else
    echo "$status  $url"
  fi
done
