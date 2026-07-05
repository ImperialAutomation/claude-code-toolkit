#!/usr/bin/env bash
# Poll a Docker container's health status until healthy or timeout.
# Replaces ad-hoc `until docker inspect ...; do sleep N; done` loops, whose
# shell keywords (`until`) and `sleep` first-token never match a Bash
# permission allowlist. Matches Bash(~/.claude/bin/*).
#
# Usage: wait-for-healthy.sh <container> [--timeout SECS] [--interval SECS]
# Example: wait-for-healthy.sh pam_api --timeout 60
#
# Exit codes:
#   0  container reached "healthy"
#   1  timed out before becoming healthy
#   2  no such container, or container has no health check configured
set -euo pipefail

container=""
timeout=120
interval=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)  timeout="$2";  shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *) container="$1"; shift ;;
  esac
done

if [[ -z "$container" ]]; then
  echo "Usage: wait-for-healthy.sh <container> [--timeout SECS] [--interval SECS]" >&2
  exit 2
fi

if ! docker inspect "$container" >/dev/null 2>&1; then
  echo "Error: no such container: $container" >&2
  exit 2
fi

health="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "")"
if [[ -z "$health" ]]; then
  echo "Error: container '$container' has no health check configured" >&2
  exit 2
fi

elapsed=0
while [[ "$health" != "healthy" && $elapsed -lt $timeout ]]; do
  sleep "$interval"
  elapsed=$((elapsed + interval))
  health="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")"
done

if [[ "$health" == "healthy" ]]; then
  echo "$container is healthy (after ${elapsed}s)"
  exit 0
fi

echo "Error: $container did not become healthy within ${timeout}s (last status: $health)" >&2
exit 1
