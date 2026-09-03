#!/usr/bin/env bash
set -euo pipefail

# Runtime Docker container health verification.
# Checks running containers for health status, restart loops, and error logs.
# Complements docker-audit.sh (which does static config analysis).
#
# Usage: docker-health-check.sh [project-dir] [--timeout SECS] [--filter PREFIX]
# Example: docker-health-check.sh /path/to/project --filter myapp_ --timeout 300

PROJECT_DIR=""
TIMEOUT=120
FILTER=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --filter)
      FILTER="$2"
      shift 2
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      echo "Usage: docker-health-check.sh [project-dir] [--timeout SECS] [--filter PREFIX]" >&2
      exit 2
      ;;
    *)
      PROJECT_DIR="$1"
      shift
      ;;
  esac
done

PROJECT_DIR="${PROJECT_DIR:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Error: directory not found: $PROJECT_DIR" >&2
  exit 2
fi

# Find compose file
COMPOSE_FILE=""
for candidate in \
  "$PROJECT_DIR/docker-compose.yml" \
  "$PROJECT_DIR/docker-compose.yaml" \
  "$PROJECT_DIR/compose.yml" \
  "$PROJECT_DIR/compose.yaml" \
  "$PROJECT_DIR/backend/docker/docker-compose.yml" \
  "$PROJECT_DIR/backend/docker/docker-compose.yaml"; do
  if [[ -f "$candidate" ]]; then
    COMPOSE_FILE="$candidate"
    break
  fi
done

if [[ -z "$COMPOSE_FILE" ]]; then
  echo "Error: no docker-compose file found in $PROJECT_DIR" >&2
  exit 2
fi

COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
COMPOSE_REL="${COMPOSE_FILE#"$PROJECT_DIR"/}"

echo "Docker Runtime Health Check"
echo "=================================================="
echo "Compose file: $COMPOSE_REL"
echo ""

# Get container list from compose project
COMPOSE_PROJECT=""
if [[ -f "$COMPOSE_DIR/.env" ]]; then
  COMPOSE_PROJECT=$(grep -E '^COMPOSE_PROJECT_NAME=' "$COMPOSE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"'"'" || true)
fi

# Get running containers via docker compose
CONTAINERS_JSON=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null || true)

if [[ -z "$CONTAINERS_JSON" ]]; then
  echo "Error: no containers found for compose file $COMPOSE_REL" >&2
  echo "Are the containers running? Try: docker compose -f $COMPOSE_REL up -d" >&2
  exit 1
fi

# Parse containers (docker compose ps --format json outputs one JSON object per line)
ISSUES=0
TOTAL=0
HEALTHY=0

echo "── Container Status ──"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  name=$(echo "$line" | jq -r '.Name // .Names // empty' 2>/dev/null)
  state=$(echo "$line" | jq -r '.State // empty' 2>/dev/null)
  health=$(echo "$line" | jq -r '.Health // empty' 2>/dev/null)
  status_full=$(echo "$line" | jq -r '.Status // empty' 2>/dev/null)

  [[ -z "$name" ]] && continue

  # Apply filter if specified
  if [[ -n "$FILTER" && "$name" != "$FILTER"* ]]; then
    continue
  fi

  TOTAL=$((TOTAL + 1))

  # Get restart count
  restarts=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null || echo "?")

  # Determine status display
  status_display="$state"
  if [[ -n "$health" && "$health" != "empty" && "$health" != "" ]]; then
    status_display="$state ($health)"
  fi

  # Check for problems
  container_ok=true

  if [[ "$state" != "running" ]]; then
    container_ok=false
    ISSUES=$((ISSUES + 1))
  fi

  if [[ "$health" == "unhealthy" ]]; then
    container_ok=false
    ISSUES=$((ISSUES + 1))
  fi

  if [[ "$restarts" =~ ^[0-9]+$ && "$restarts" -gt 0 ]]; then
    container_ok=false
    ISSUES=$((ISSUES + 1))
  fi

  if [[ "$container_ok" == "true" ]]; then
    HEALTHY=$((HEALTHY + 1))
  fi

  # Format output with padding
  printf "  %-30s %-25s restarts: %s\n" "$name:" "$status_display" "$restarts"

  # If container has health check and is not yet healthy, poll until timeout
  if [[ "$health" == "starting" ]]; then
    echo "    ⏳ Waiting for health check (timeout: ${TIMEOUT}s)..."
    elapsed=0
    interval=5
    while [[ $elapsed -lt $TIMEOUT ]]; do
      sleep "$interval"
      elapsed=$((elapsed + interval))
      current_health=$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || echo "unknown")
      if [[ "$current_health" == "healthy" ]]; then
        echo "    ✓ Became healthy after ${elapsed}s"
        HEALTHY=$((HEALTHY + 1))
        break
      elif [[ "$current_health" == "unhealthy" ]]; then
        echo "    ✗ Became unhealthy after ${elapsed}s"
        ISSUES=$((ISSUES + 1))
        break
      fi
    done
    if [[ $elapsed -ge $TIMEOUT ]]; then
      echo "    ✗ Timed out waiting for health check"
      ISSUES=$((ISSUES + 1))
    fi
  fi

  # Show logs for unhealthy/stopped containers
  if [[ "$container_ok" != "true" ]]; then
    echo "    Recent logs:"
    docker logs --tail=10 "$name" 2>&1 | sed 's/^/      /' || true
    echo ""
  fi

done <<< "$CONTAINERS_JSON"

if [[ $TOTAL -eq 0 ]]; then
  echo "  No containers found"
  if [[ -n "$FILTER" ]]; then
    echo "  (filter: $FILTER)"
  fi
  exit 1
fi

echo ""

# Check logs for error patterns
echo "── Log Issues (last 50 lines) ──"

LOG_ISSUES=0
ERROR_PATTERNS='ERROR|CRITICAL|Traceback|ModuleNotFoundError|ImportError|FATAL|panic:'

while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  name=$(echo "$line" | jq -r '.Name // .Names // empty' 2>/dev/null)
  [[ -z "$name" ]] && continue

  if [[ -n "$FILTER" && "$name" != "$FILTER"* ]]; then
    continue
  fi

  # Get recent logs and check for error patterns
  errors=$(docker logs --tail=50 "$name" 2>&1 | grep -E "$ERROR_PATTERNS" 2>/dev/null || true)
  if [[ -n "$errors" ]]; then
    error_count=$(echo "$errors" | wc -l | tr -d ' ')
    echo "  $name: $error_count error(s)"
    echo "$errors" | head -5 | sed 's/^/    /'
    if [[ $error_count -gt 5 ]]; then
      echo "    ... and $((error_count - 5)) more"
    fi
    LOG_ISSUES=$((LOG_ISSUES + error_count))
    echo ""
  fi

done <<< "$CONTAINERS_JSON"

if [[ $LOG_ISSUES -eq 0 ]]; then
  echo "  No errors detected."
fi

echo ""

# Summary
echo "── Summary ──"
if [[ $ISSUES -eq 0 && $LOG_ISSUES -eq 0 ]]; then
  echo "Result: HEALTHY ($HEALTHY/$TOTAL containers OK)"
  exit 0
else
  if [[ $ISSUES -gt 0 ]]; then
    echo "Result: $ISSUES CONTAINER ISSUE(S) ($HEALTHY/$TOTAL containers OK)"
  fi
  if [[ $LOG_ISSUES -gt 0 ]]; then
    echo "Log errors: $LOG_ISSUES error(s) in recent logs"
  fi
  exit 1
fi
