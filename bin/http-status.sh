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
    --max-time)
      # An empty or non-numeric value makes curl wait forever, which is the one
      # outcome this wrapper exists to prevent.
      [[ $# -ge 2 ]] || { echo "--max-time needs a value" >&2; exit 2; }
      MAX_TIME="$2"
      case "$MAX_TIME" in
        ''|*[!0-9.]*) echo "--max-time must be a number: $MAX_TIME" >&2; exit 2 ;;
      esac
      shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) URLS+=("$1"); shift ;;
  esac
done

if [[ ${#URLS[@]} -eq 0 ]]; then
  echo "usage: $(basename "$0") [--body] [--max-time SECS] <url> [url...]" >&2
  exit 2
fi

FAILED=0

for url in "${URLS[@]}"; do
  if [[ $SHOW_BODY -eq 1 ]]; then
    # Several bodies run together are unattributable, so each gets a header.
    # A single body stays raw, so it can be piped into jq or compared directly.
    [[ ${#URLS[@]} -gt 1 ]] && echo "==> $url <=="
    curl -sS --max-time "$MAX_TIME" "$url" || FAILED=1
    continue
  fi

  # A transport failure prints ERR rather than curl's "000", which is easy to
  # misread as a status. The loop continues: one dead host must not hide the
  # answers for the URLs behind it.
  if status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$MAX_TIME" "$url"); then
    :
  else
    status="ERR"
    FAILED=1
  fi

  if [[ ${#URLS[@]} -eq 1 ]]; then
    echo "$status"
  else
    echo "$status  $url"
  fi
done

exit "$FAILED"
