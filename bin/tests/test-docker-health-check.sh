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
# STUB_COMPOSE  same, answer to `docker compose [-p N] -f X ps --format json`
# STUB_PROJECT  the compose project STUB_COMPOSE belongs to. Set it, and the
#               compose stub answers only when the script asked for that project
#               by name — which is what Compose itself does. Unset, the stub
#               answers any query, the pre-fix behaviour.
# STUB_HEALTH   "name=status" pairs, one per line; inspect reads .State.Health.Status
# STUB_RESTARTS "name=count" pairs, one per line; absent name means 0
# STUB_LOGS     text returned by `docker logs` for every container
# STUB_DAEMON_ERR  when set, every subcommand fails with this on stderr and
#               exit 1 — a dead daemon or an unreadable socket.
# STUB_LABELS   "project<TAB>comma,separated,config,files" rows, one per
#               container, answering the label query the script uses to discover
#               a project name. Modelled on measured output: `docker ps` renders
#               each requested label as its own field, which is why the script
#               asks for them that way instead of parsing the flat .Labels string
#               (where a config_files separator is indistinguishable from a label
#               separator, both being commas).
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'STUB'
#!/bin/bash
# Stub docker. Dispatches on the first non-flag word.
sub="$1"; shift

# A broken daemon fails every subcommand the same way: a message on stderr and a
# non-zero status. Nothing on stdout — which is exactly why swallowing stderr
# makes this indistinguishable from a stopped stack.
if [[ -n "${STUB_DAEMON_ERR:-}" ]]; then
    echo "$STUB_DAEMON_ERR" >&2
    exit 1
fi

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
    want=""; all=""; label_query=""
    for a in "$@"; do
        case "$a" in
          name=*) want="${a#name=}" ;;
          label=*) label_query=1 ;;
          -a|--all) all=1 ;;
        esac
    done
    # The project-discovery query: filtered on the presence of the compose
    # project label, formatted as the two label values. Answered from
    # STUB_LABELS, which is a different fixture from the container list.
    if [[ -n "$label_query" ]]; then
        printf '%s\n' "${STUB_LABELS:-}"
        exit 0
    fi
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
    # `compose [-p <name>] -f <file> ps --format json`. Record the invocation so
    # a test can assert which project name the script actually asked for.
    [[ -n "${STUB_COMPOSE_CALLED:-}" ]] && echo "compose $*" >> "$STUB_COMPOSE_CALLED"
    asked=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
          -p|--project-name) asked="$2"; shift 2 ;;
          *) shift ;;
        esac
    done
    # The heart of the bug being fixed. Compose answers for exactly one project:
    # ask for the wrong one and you get an empty list, not an error — a running
    # stack that reads as a stopped one. With STUB_PROJECT set, wrong name means
    # empty output.
    if [[ -n "${STUB_PROJECT:-}" && "$asked" != "${STUB_PROJECT}" ]]; then
        exit 0
    fi
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
# The compose route may consult `docker ps` to discover a project name from
# container labels, but never to obtain a container set: a name lookup reads
# metadata, while listing containers would hand this check a set the compose
# file never defined. The distinction is the --filter argument, so assert on
# that rather than on whether `ps` was called at all.
PS_CALLS=$(cat "$STUB_PS_CALLED")
check "compose route asks ps only for labels" "no" \
    "$(contains "$PS_CALLS" "name=")"
check "any ps call is a label query" "yes" \
    "$([[ -z "$PS_CALLS" ]] && echo yes || contains "$PS_CALLS" "label=")"
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

echo "== 11. --project names the compose project the stack actually runs under =="
# The issue: `docker compose -p mystack -f a.yml -f b.yml up` puts the containers
# in project "mystack", while `docker compose -f a.yml ps` asks for a project
# named after a.yml's directory. Wrong project, empty answer, healthy stack
# reported as absent.
STUB_COMPOSE='{"Name":"shopfront_api","State":"running","Health":"healthy","Status":"Up 6 hours (healthy)"}'
STUB_PROJECT="shopfront"
STUB_COMPOSE_CALLED="$T/compose-called-11"
: > "$STUB_COMPOSE_CALLED"
export STUB_COMPOSE STUB_PROJECT STUB_COMPOSE_CALLED
OUT=$(run "$T/with-compose" --project shopfront 2>&1); RC=$?
check "named project found"        "0"   "$RC"
check "container is reported"      "yes" "$(contains "$OUT" "shopfront_api")"
check "1/1 OK"                     "yes" "$(contains "$OUT" "HEALTHY (1/1")"
check "not reported as absent"     "no"  "$(contains "$OUT" "no containers found")"
check "project passed to compose"  "yes" \
    "$(contains "$(cat "$STUB_COMPOSE_CALLED")" "-p shopfront")"
check "header names the project"   "yes" "$(contains "$OUT" "Compose project: shopfront")"
unset STUB_COMPOSE_CALLED

# Without the name, the same stack is invisible. This is the asymmetry that makes
# the option load-bearing rather than cosmetic.
OUT=$(run "$T/with-compose" 2>&1); RC=$?
check "same stack unnamed is not found" "1" "$RC"
unset STUB_PROJECT STUB_COMPOSE

echo "== 12. COMPOSE_PROJECT_NAME in the .env beside the compose file is used =="
# Compose reads this file itself when it starts the stack, so it is the one place
# the project name is recorded where both sides can see it. Honouring it means a
# wrapper script that sets it needs no extra argument here.
mkdir -p "$T/dotenv"
: > "$T/dotenv/docker-compose.yml"
cat > "$T/dotenv/.env" <<'ENV'
# Shared by the stack and this check.
COMPOSE_PROJECT_NAME=warehouse
POSTGRES_PASSWORD=not-a-project-name
ENV
STUB_COMPOSE='{"Name":"warehouse_api","State":"running","Health":"healthy","Status":"Up 3 days (healthy)"}'
STUB_PROJECT="warehouse"
export STUB_COMPOSE STUB_PROJECT
OUT=$(run "$T/dotenv" 2>&1); RC=$?
check ".env project found, no args"  "0"   "$RC"
check "container reported"           "yes" "$(contains "$OUT" "warehouse_api")"
check "header names the project"     "yes" "$(contains "$OUT" "Compose project: warehouse")"

# An explicit --project is the operator speaking now; the file is a default.
STUB_PROJECT="override"
export STUB_PROJECT
OUT=$(run "$T/dotenv" --project override 2>&1); RC=$?
check "--project beats .env"      "0"   "$RC"
check "header names the override" "yes" "$(contains "$OUT" "Compose project: override")"
check ".env value not used"       "no"  "$(contains "$OUT" "Compose project: warehouse")"
unset STUB_PROJECT STUB_COMPOSE

# Quoted values and surrounding whitespace are both legal in a Compose .env, and
# a name arriving with its quotes attached matches no project at all.
mkdir -p "$T/dotenv-quoted"
: > "$T/dotenv-quoted/docker-compose.yml"
cat > "$T/dotenv-quoted/.env" <<'ENV'
  COMPOSE_PROJECT_NAME = "warehouse-staging"
ENV
STUB_COMPOSE='{"Name":"warehouse-staging_api","State":"running","Health":"healthy","Status":"Up 1 day (healthy)"}'
STUB_PROJECT="warehouse-staging"
export STUB_COMPOSE STUB_PROJECT
OUT=$(run "$T/dotenv-quoted" 2>&1); RC=$?
check "quoted and spaced value parsed" "0"   "$RC"
check "no quotes in the name"          "no"  "$(contains "$OUT" '"warehouse-staging"')"
unset STUB_PROJECT STUB_COMPOSE

# A commented-out assignment is not an assignment. Reading it would send the
# check off to a project nobody started.
mkdir -p "$T/dotenv-commented"
: > "$T/dotenv-commented/docker-compose.yml"
cat > "$T/dotenv-commented/.env" <<'ENV'
#COMPOSE_PROJECT_NAME=retired-name
ENV
STUB_COMPOSE="$(c ledger_api running 'Up 1 hour')"
export STUB_COMPOSE
OUT=$(run "$T/dotenv-commented" 2>&1)
check "commented assignment ignored" "no" "$(contains "$OUT" "retired-name")"
check "no project line at all"       "no" "$(contains "$OUT" "Compose project:")"
unset STUB_COMPOSE

echo "== 13. with no name given, the project comes from the containers' labels =="
# The case where nothing on disk records the name: the stack was started as
# `docker compose -p <name> -f a.yml -f b.yml up` and the name lives only in the
# shell history. The containers themselves still know it.
mkdir -p "$T/labelled"
: > "$T/labelled/docker-compose.yml"
LABELLED_FILE="$T/labelled/docker-compose.yml"
STUB_LABELS=$(printf 'invoicing\t%s,%s/docker-compose.prod.yml\n' "$LABELLED_FILE" "$T/labelled")
STUB_COMPOSE='{"Name":"invoicing_api","State":"running","Health":"healthy","Status":"Up 5 hours (healthy)"}'
STUB_PROJECT="invoicing"
export STUB_LABELS STUB_COMPOSE STUB_PROJECT
OUT=$(run "$T/labelled" 2>&1); RC=$?
check "project discovered from labels" "0"   "$RC"
check "container reported"             "yes" "$(contains "$OUT" "invoicing_api")"
check "header names the project"       "yes" "$(contains "$OUT" "Compose project: invoicing")"

# A container of a DIFFERENT stack must not donate its project name. Its
# config_files list does not mention this compose file, and adopting it would
# report on a stack that has nothing to do with this directory.
STUB_LABELS=$(printf 'someone-else\t/srv/other/docker-compose.yml\n')
export STUB_LABELS
OUT=$(run "$T/labelled" 2>&1); RC=$?
check "foreign project not adopted" "1"  "$RC"
check "its name is not used"        "no" "$(contains "$OUT" "someone-else")"

# A path that merely contains the compose file path as a substring is a different
# file. /srv/app/docker-compose.yml.bak must not match /srv/app/docker-compose.yml.
STUB_LABELS=$(printf 'backup-stack\t%s.bak\n' "$LABELLED_FILE")
export STUB_LABELS
OUT=$(run "$T/labelled" 2>&1); RC=$?
check "substring path is not a match" "1"  "$RC"
check "backup stack not adopted"      "no" "$(contains "$OUT" "backup-stack")"
unset STUB_LABELS STUB_PROJECT STUB_COMPOSE

# An explicit --project still wins: discovery is the fallback, not an override.
mkdir -p "$T/labelled-override"
: > "$T/labelled-override/docker-compose.yml"
STUB_LABELS=$(printf 'from-labels\t%s/docker-compose.yml\n' "$T/labelled-override")
STUB_COMPOSE='{"Name":"chosen_api","State":"running","Health":"healthy","Status":"Up 1 hour (healthy)"}'
STUB_PROJECT="chosen"
export STUB_LABELS STUB_COMPOSE STUB_PROJECT
OUT=$(run "$T/labelled-override" --project chosen 2>&1); RC=$?
check "--project beats label discovery" "0"  "$RC"
check "label name not used"             "no" "$(contains "$OUT" "from-labels")"
unset STUB_LABELS STUB_PROJECT STUB_COMPOSE

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
