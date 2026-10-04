#!/usr/bin/env bash
set -euo pipefail

# Runtime Docker container health verification.
# Checks running containers for health status, restart loops, and error logs.
# Complements docker-audit.sh (which does static config analysis).
#
# Usage: docker-health-check.sh [project-dir] [--timeout SECS] [--filter PREFIX]
#                               [--project NAME]
# Example: docker-health-check.sh /path/to/project --filter myapp_ --timeout 300

USAGE="Usage: docker-health-check.sh [project-dir] [--timeout SECS] [--filter PREFIX] [--project NAME]"

PROJECT_DIR=""
TIMEOUT=120
FILTER=""
COMPOSE_PROJECT=""

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
    --project)
      COMPOSE_PROJECT="$2"
      shift 2
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      echo "$USAGE" >&2
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

# Determine the container set. Two routes, because a compose file cannot always
# name the set: a stack started from a top-level file that pulls the rest in via
# `include:` has no container belonging to the compose project of any single file
# found here, so the compose lookup returns nothing for a stack that is running.
# A caller that passes --filter has already named the set, so that route skips
# the compose lookup entirely and never needs a compose file.
if [[ -n "$FILTER" ]]; then
  echo "Docker Runtime Health Check"
  echo "=================================================="
  echo "Container filter: $FILTER"
  echo ""

  # -a, not just running: an exited container of the stack must stay visible and
  # become an issue, rather than disappearing into "no containers found".
  # Docker's `name=` is a substring match, so this is a pre-selection only — the
  # real prefix test is the name check in the loop below.
  CONTAINERS_JSON=$(docker ps -a --filter "name=$FILTER" --format json 2>/dev/null || true)
else
  # Compose-Spec standard names in the project root. Nothing else: a file found
  # somewhere deeper is as likely to be one member of an include: set as it is to
  # be the top file, and guessing wrong gives a confidently empty answer.
  COMPOSE_FILE=""
  for candidate in \
    "$PROJECT_DIR/docker-compose.yml" \
    "$PROJECT_DIR/docker-compose.yaml" \
    "$PROJECT_DIR/compose.yml" \
    "$PROJECT_DIR/compose.yaml"; do
    if [[ -f "$candidate" ]]; then
      COMPOSE_FILE="$candidate"
      break
    fi
  done

  if [[ -z "$COMPOSE_FILE" ]]; then
    echo "Error: no docker-compose file found in $PROJECT_DIR" >&2
    echo "If the stack is started from an include: set, pass --filter <prefix> instead." >&2
    exit 2
  fi

  COMPOSE_REL="${COMPOSE_FILE#"$PROJECT_DIR"/}"

  # Compose itself reads COMPOSE_PROJECT_NAME from the .env beside the compose
  # file, so that file is the one place a stack's project name is recorded where
  # both the starting side and this check can see it. An explicit --project is
  # the operator speaking now and outranks it.
  COMPOSE_ENV="$(dirname "$COMPOSE_FILE")/.env"
  if [[ -z "$COMPOSE_PROJECT" && -f "$COMPOSE_ENV" ]]; then
    # Only this one key, and only as a real assignment: a commented-out line is
    # not an assignment, and reading it would query a project nobody started.
    # Quotes and padding around the value are legal in a .env and must come off,
    # since a name arriving with its quotes attached matches no project at all.
    env_line=$(grep -E '^[[:space:]]*COMPOSE_PROJECT_NAME[[:space:]]*=' "$COMPOSE_ENV" 2>/dev/null | tail -1 || true)
    if [[ -n "$env_line" ]]; then
      env_value="${env_line#*=}"
      env_value="${env_value#"${env_value%%[![:space:]]*}"}"   # strip leading space
      env_value="${env_value%"${env_value##*[![:space:]]}"}"   # strip trailing space
      env_value="${env_value%\"}"; env_value="${env_value#\"}"
      env_value="${env_value%\'}"; env_value="${env_value#\'}"
      COMPOSE_PROJECT="$env_value"
    fi
  fi

  echo "Docker Runtime Health Check"
  echo "=================================================="
  echo "Compose file: $COMPOSE_REL"
  if [[ -n "$COMPOSE_PROJECT" ]]; then
    echo "Compose project: $COMPOSE_PROJECT"
  fi
  echo ""

  # Ask for the project by name when one is known. Without -p, Compose derives
  # the name from the compose file's directory, which is wrong for any stack
  # started as `docker compose -p <name> ...` — and wrong in the quietest way
  # available: the query succeeds and returns an empty list, so a running stack
  # reads exactly like a stopped one.
  COMPOSE_ARGS=()
  if [[ -n "$COMPOSE_PROJECT" ]]; then
    COMPOSE_ARGS+=(-p "$COMPOSE_PROJECT")
  fi

  CONTAINERS_JSON=$(docker compose "${COMPOSE_ARGS[@]}" -f "$COMPOSE_FILE" ps --format json 2>/dev/null || true)

  if [[ -z "$CONTAINERS_JSON" ]]; then
    echo "Error: no containers found for compose file $COMPOSE_REL" >&2
    echo "Are the containers running? Try: docker compose -f $COMPOSE_REL up -d" >&2
    echo "If the stack is started from an include: set, its containers belong to a" >&2
    echo "different compose project than this file — pass --filter <prefix> instead." >&2
    exit 1
  fi
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

  [[ -z "$name" ]] && continue

  # Docker's `name=` filter matches a substring, so `other_myapp_api` arrives in
  # a `--filter myapp_` set. This is the real prefix test.
  if [[ -n "$FILTER" && "$name" != "$FILTER"* ]]; then
    continue
  fi

  TOTAL=$((TOTAL + 1))

  # Get restart count
  restarts=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null || echo "?")

  # `docker ps --format json` carries no .Health field — only .State and a
  # free-text .Status — so in the filter route health comes from inspect.
  # Empty is the honest answer for a container without a healthcheck, and the
  # checks below treat it as neither healthy nor unhealthy.
  # The `if` guard matters: without it Docker fails the whole template with
  # "map has no entry for key Health" on a container that has no healthcheck,
  # which is a normal case rather than an error.
  if [[ -n "$FILTER" ]]; then
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || echo "")
  fi

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
