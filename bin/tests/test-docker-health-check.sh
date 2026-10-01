#!/bin/bash
# Tests for docker-health-check.sh.
#
# Usage:
#   bin/tests/test-docker-health-check.sh
#
# Drives the real script with a stub `docker` first on PATH. The stub dispatches
# on the subcommand (ps / inspect / logs / compose) and reads its answers from
# env vars, so each case shapes the container set without needing a daemon.
#
# What is deliberately NOT mocked: the script itself. The behaviour under test is
# which containers the script decides to look at and how it judges them, so the
# stub stays a dumb fixture server and every assertion goes through the real
# parsing, filtering and exit-code logic.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../docker-health-check.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

contains() { # haystack needle -> yes/no
    case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac
}

# --- the stub docker ----------------------------------------------------------
# STUB_PS       one JSON object per line, answer to `docker ps -a ... --format json`
# STUB_COMPOSE  same, answer to `docker compose -f X ps --format json`
# STUB_HEALTH   "name=status" pairs, one per line; inspect reads .State.Health.Status
# STUB_RESTARTS "name=count" pairs, one per line; absent name means 0
# STUB_LOGS     text returned by `docker logs` for every container
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'STUB'
#!/bin/bash
# Stub docker. Dispatches on the first non-flag word.
sub="$1"; shift

lookup() { # table name default
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "${line%%=*}" == "$2" ]]; then printf '%s\n' "${line#*=}"; return 0; fi
    done <<< "$1"
    printf '%s\n' "$3"
}

case "$sub" in
  ps)
    # Record that `docker ps` was reached at all, so a test can assert the
    # compose route never consults it.
    [[ -n "${STUB_PS_CALLED:-}" ]] && echo "ps $*" >> "$STUB_PS_CALLED"
    # Honour --filter name=<substring> the way Docker does: a substring match,
    # not a prefix match. The script must not rely on this being a prefix.
    want=""; all=""
    for a in "$@"; do
        case "$a" in
          name=*) want="${a#name=}" ;;
          -a|--all) all=1 ;;
        esac
    done
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=$(printf '%s' "$line" | jq -r '.Names // empty')
        state=$(printf '%s' "$line" | jq -r '.State // empty')
        # Without -a, Docker lists only running containers. Modelling this is the
        # point: it is what makes an exited container vanish from the set.
        [[ -z "$all" && "$state" != "running" ]] && continue
        if [[ -n "$want" ]]; then
            case "$name" in *"$want"*) ;; *) continue ;; esac
        fi
        printf '%s\n' "$line"
    done <<< "${STUB_PS:-}"
    ;;
  compose)
    # Only `compose -f <file> ps --format json` is used by the script.
    printf '%s\n' "${STUB_COMPOSE:-}"
    ;;
  inspect)
    fmt=""; name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
          --format) fmt="$2"; shift 2 ;;
          --format=*) fmt="${1#--format=}"; shift ;;
          *) name="$1"; shift ;;
        esac
    done
    case "$fmt" in
      *RestartCount*) lookup "${STUB_RESTARTS:-}" "$name" "0" ;;
      *Health.Status*) lookup "${STUB_HEALTH:-}" "$name" "" ;;
      *) echo "" ;;
    esac
    ;;
  logs)
    printf '%s\n' "${STUB_LOGS:-}"
    ;;
  *)
    echo "stub docker: unhandled subcommand: $sub" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$T/bin/docker"

# --- fixtures ----------------------------------------------------------------
# A project dir with NO compose file: the include:-set case from the issue, where
# the stack is started from a top file the script's candidate list never finds.
mkdir -p "$T/no-compose"
# A project dir WITH a compose file in the root: the single-file case.
mkdir -p "$T/with-compose"
: > "$T/with-compose/docker-compose.yml"
# A project dir whose only compose file sits where the old candidate list used to
# look (backend/docker/). After the fix that is not a compose project any more.
mkdir -p "$T/backend-docker/backend/docker"
: > "$T/backend-docker/backend/docker/docker-compose.yml"

c() { # name state status -> one docker ps json line
    printf '{"Names":"%s","State":"%s","Status":"%s"}\n' "$1" "$2" "$3"
}

# Command substitution strips trailing newlines, so "$(c a)$(c b)" would glue two
# JSON objects onto one line and every jq field would come back doubled. Join
# rows through this instead of concatenating them.
rows() { printf '%s\n' "$@"; }

run() { # runs the script with the stub docker first on PATH
    PATH="$T/bin:$PATH" bash "$SCRIPT" "$@"
}

echo "== 1. --filter needs no compose file =="
# The bug: a healthy include:-set stack reported as "no containers found".
STUB_PS=$(rows "$(c myapp_api running 'Up 6 hours (healthy)')" "$(c myapp_db running 'Up 6 hours')")
STUB_HEALTH="myapp_api=healthy"
export STUB_PS STUB_HEALTH
OUT=$(run "$T/no-compose" --filter myapp_ 2>&1); RC=$?
check "healthy filtered stack exits 0" "0" "$RC"
check "names the api container"  "yes" "$(contains "$OUT" "myapp_api")"
check "names the db container"   "yes" "$(contains "$OUT" "myapp_db")"
check "reports its health"       "yes" "$(contains "$OUT" "running (healthy)")"
check "2/2 containers OK"        "yes" "$(contains "$OUT" "HEALTHY (2/2")"
check "no compose-file error"    "no"  "$(contains "$OUT" "no docker-compose file")"

echo "== 2. the filter route reads docker ps -a, so an exited container is in the set =="
# Not "no containers found": an exited container of the stack is the finding.
STUB_PS=$(rows "$(c myapp_api running 'Up 6 hours (healthy)')" "$(c myapp_worker exited 'Exited (1) 2 minutes ago')")
STUB_HEALTH="myapp_api=healthy"
export STUB_PS STUB_HEALTH
OUT=$(run "$T/no-compose" --filter myapp_ 2>&1); RC=$?
check "exited container exits 1"      "1"   "$RC"
check "exited container is listed"    "yes" "$(contains "$OUT" "myapp_worker")"
check "counted as an issue"           "yes" "$(contains "$OUT" "CONTAINER ISSUE")"
check "not reported as empty set"     "no"  "$(contains "$OUT" "No containers found")"
# The stub lists only running containers unless -a is passed, so an exited
# container reaching the report at all is the evidence that -a was used. Asserted
# on the invocation too, because a future refactor could keep the behaviour by
# accident while losing the flag.
STUB_PS_CALLED="$T/ps-called-2"
: > "$STUB_PS_CALLED"
export STUB_PS_CALLED
run "$T/no-compose" --filter myapp_ >/dev/null 2>&1
check "docker ps is called with -a" "yes" \
    "$(contains "$(cat "$STUB_PS_CALLED")" " -a ")"
unset STUB_PS_CALLED

echo "== 3. the prefix match is a real prefix, not Docker's substring =="
# docker ps --filter name= matches anywhere in the name, so a foreign container
# carrying the prefix mid-name arrives in the set and must be dropped.
STUB_PS=$(rows "$(c myapp_api running 'Up 6 hours (healthy)')" "$(c other_myapp_api exited 'Exited (1) ago')")
STUB_HEALTH="myapp_api=healthy"
export STUB_PS STUB_HEALTH
OUT=$(run "$T/no-compose" --filter myapp_ 2>&1); RC=$?
check "foreign container excluded"  "no"  "$(contains "$OUT" "other_myapp_api")"
check "its failure does not count"  "0"   "$RC"
check "only the real match counted" "yes" "$(contains "$OUT" "HEALTHY (1/1")"

echo "== 4. health in the filter route comes from docker inspect =="
# docker ps --format json has no .Health field. Reading health from the ps row
# would leave it empty, and every running container would go green.
STUB_PS="$(c myapp_api running 'Up 6 hours (unhealthy)')"
STUB_HEALTH="myapp_api=unhealthy"
export STUB_PS STUB_HEALTH
OUT=$(run "$T/no-compose" --filter myapp_ 2>&1); RC=$?
check "unhealthy exits 1"           "1"   "$RC"
check "unhealthy shown in status"   "yes" "$(contains "$OUT" "running (unhealthy)")"
check "unhealthy counted as issue"  "yes" "$(contains "$OUT" "CONTAINER ISSUE")"

# A container without a healthcheck inspects to an empty status. That is not a
# failure — most sidecars have no healthcheck at all.
STUB_PS="$(c myapp_db running 'Up 6 hours')"
STUB_HEALTH=""
export STUB_PS STUB_HEALTH
OUT=$(run "$T/no-compose" --filter myapp_ 2>&1); RC=$?
check "no healthcheck is not unhealthy" "0"   "$RC"
check "status shows bare state"         "yes" "$(contains "$OUT" "running")"
check "no empty parenthesis"            "no"  "$(contains "$OUT" "running ()")"

echo "== 5. RestartCount > 0 still fails, in the filter route =="
STUB_PS="$(c myapp_api running 'Up 2 minutes (healthy)')"
STUB_HEALTH="myapp_api=healthy"
STUB_RESTARTS="myapp_api=3"
export STUB_PS STUB_HEALTH STUB_RESTARTS
OUT=$(run "$T/no-compose" --filter myapp_ 2>&1); RC=$?
check "restart loop exits 1"    "1"   "$RC"
check "restart count reported"  "yes" "$(contains "$OUT" "restarts: 3")"
unset STUB_RESTARTS

echo "== 6. header names what actually determined the set =="
STUB_PS="$(c myapp_api running 'Up 6 hours (healthy)')"
STUB_HEALTH="myapp_api=healthy"
export STUB_PS STUB_HEALTH
OUT=$(run "$T/no-compose" --filter myapp_ 2>&1)
check "filter route names the filter"   "yes" "$(contains "$OUT" "Container filter: myapp_")"
# Showing a compose file here would claim that file defined the checked set.
check "filter route hides compose file" "no"  "$(contains "$OUT" "Compose file:")"

STUB_COMPOSE="$(c myapp_api running 'Up 6 hours')"
export STUB_COMPOSE
OUT=$(run "$T/with-compose" 2>&1)
check "compose route names the file"    "yes" "$(contains "$OUT" "Compose file: docker-compose.yml")"
check "compose route hides filter line" "no"  "$(contains "$OUT" "Container filter:")"
unset STUB_COMPOSE

echo "== 7. compose route: health still comes from the compose row =="
# docker compose ps --format json DOES carry .Health, and that path is unchanged.
STUB_COMPOSE='{"Name":"myapp_api","State":"running","Health":"unhealthy","Status":"Up 6 hours (unhealthy)"}'
export STUB_COMPOSE
OUT=$(run "$T/with-compose" 2>&1); RC=$?
check "compose unhealthy exits 1"    "1"   "$RC"
check "compose unhealthy in status"  "yes" "$(contains "$OUT" "running (unhealthy)")"
unset STUB_COMPOSE

echo "== 8. zero containers without --filter is a hard failure that names the fix =="
STUB_COMPOSE=""
STUB_PS=$(rows "$(c stray_container running 'Up 6 hours')")
STUB_PS_CALLED="$T/ps-called-8"
: > "$STUB_PS_CALLED"
export STUB_COMPOSE STUB_PS STUB_PS_CALLED
OUT=$(run "$T/with-compose" 2>&1); RC=$?
check "empty compose set exits 1"   "1"   "$RC"
check "error mentions --filter"     "yes" "$(contains "$OUT" "--filter")"
# Falling back to every container on the host would be a silently wrong answer:
# it would report on containers that have nothing to do with this project.
check "no fallback to all containers" "no" "$(contains "$OUT" "HEALTHY")"
check "stray container not reported"  "no" "$(contains "$OUT" "stray_container")"
check "compose route never calls docker ps" "0" \
    "$(wc -l < "$STUB_PS_CALLED" | tr -d ' ')"
unset STUB_COMPOSE STUB_PS_CALLED

echo "== 9. the compose candidate list is the Compose-Spec names in the root =="
# backend/docker/docker-compose.yml used to be a candidate. A project whose only
# compose file lives there is no longer a compose project for this script.
STUB_COMPOSE="$(c myapp_api running 'Up 6 hours')"
export STUB_COMPOSE
OUT=$(run "$T/backend-docker" 2>&1); RC=$?
check "backend/docker is not a candidate" "2" "$RC"
check "reports no compose file"  "yes" "$(contains "$OUT" "no docker-compose file")"
unset STUB_COMPOSE

for name in compose.yml compose.yaml docker-compose.yaml; do
    D="$T/cand-$name"; mkdir -p "$D"; : > "$D/$name"
    STUB_COMPOSE="$(c myapp_api running 'Up 6 hours')"
    export STUB_COMPOSE
    OUT=$(run "$D" 2>&1)
    check "$name is a candidate" "yes" "$(contains "$OUT" "Compose file: $name")"
    unset STUB_COMPOSE
done

echo "== 10. --filter with an empty result set is still a failure =="
# A prefix that matches nothing means the caller's prefix is wrong or the stack
# is down. Either way it is not healthy.
STUB_PS=""
export STUB_PS
OUT=$(run "$T/no-compose" --filter nosuch_ 2>&1); RC=$?
check "empty filtered set exits 1" "1"   "$RC"
check "names the filter used"      "yes" "$(contains "$OUT" "nosuch_")"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
