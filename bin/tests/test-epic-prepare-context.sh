#!/bin/bash
# Tests for epic-prepare-context.sh.
#
# Usage:
#   bin/tests/test-epic-prepare-context.sh
#
# Builds throwaway project trees in a temp dir and runs the script against them.
# Nothing outside that temp dir is touched — including the destination files,
# which are redirected into the temp dir via TMPDIR.
#
# The load-bearing part is WHICH file ends up at the backend destination.
# A missing context file is harmless (the sub-agent reads the repo's CLAUDE.md
# itself); a file from a DIFFERENT project at that path is actively misleading,
# because the skill tells sub-agents to treat it as this project's architecture.
# Cases 2, 5 and 6 exist for that specifically.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../epic-prepare-context.sh}"

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

# Destinations land in $T/dest via TMPDIR so the real /tmp stays untouched.
DEST="$T/dest"
mkdir -p "$DEST"

run() { # epic-number project-dir  -> prints the prefix, stderr on fd 2
    TMPDIR="$DEST" bash "$SCRIPT" "$1" "$2"
}

# Build a project tree. Each extra arg is "relpath:marker" — the marker is
# written into the file so we can tell whose doc ended up at a destination.
newproject() { # name [relpath:marker ...]
    local d="$T/$1"; shift
    mkdir -p "$d"
    local spec rel marker
    for spec in "$@"; do
        rel="${spec%%:*}"; marker="${spec#*:}"
        mkdir -p "$d/$(dirname "$rel")"
        printf '# %s\n\nArchitecture doc for %s.\n' "$marker" "$marker" > "$d/$rel"
    done
    echo "$d"
}

marker_of() { # file -> first-line marker, or "MISSING"
    [[ -f "$1" ]] || { echo MISSING; return; }
    head -1 "$1" | sed 's/^# //'
}

echo "== 1. nested layout: backend/app/CLAUDE.md is copied =="
P=$(newproject nested "CLAUDE.md:nested-root" "backend/app/CLAUDE.md:nested-backend")
PREFIX=$(run 100 "$P")
check "root copied"    nested-root    "$(marker_of "$PREFIX-root.md")"
check "backend copied" nested-backend "$(marker_of "$PREFIX-backend.md")"

echo "== 2. flat layout: backend/CLAUDE.md is copied =="
P=$(newproject flat "CLAUDE.md:flat-root" "backend/CLAUDE.md:flat-backend")
PREFIX=$(run 200 "$P")
check "root copied"    flat-root    "$(marker_of "$PREFIX-root.md")"
check "backend copied" flat-backend "$(marker_of "$PREFIX-backend.md")"

echo "== 3. frontend: src/CLAUDE.md is used when frontend/ has none =="
P=$(newproject webapp "CLAUDE.md:web-root" "src/CLAUDE.md:web-src")
PREFIX=$(run 300 "$P")
check "frontend from src" web-src "$(marker_of "$PREFIX-frontend.md")"

echo "== 4. first candidate wins when both backend paths exist =="
P=$(newproject dual "CLAUDE.md:dual-root" \
    "backend/CLAUDE.md:dual-backend-top" "backend/app/CLAUDE.md:dual-backend-app")
PREFIX=$(run 400 "$P")
check "backend/CLAUDE.md preferred" dual-backend-top "$(marker_of "$PREFIX-backend.md")"

echo "== 5. no backend doc -> no backend destination file =="
P=$(newproject frontonly "CLAUDE.md:front-root" "frontend/CLAUDE.md:front-fe")
PREFIX=$(run 500 "$P")
check "root copied"       front-root "$(marker_of "$PREFIX-root.md")"
check "no backend file"   MISSING    "$(marker_of "$PREFIX-backend.md")"

echo "== 6. stale destination from an earlier run is removed, not reused =="
# Same project + same epic number, but the backend doc is gone the second time.
# Without an unlink the first run's copy survives and the skill points
# sub-agents at a doc the project no longer has.
P=$(newproject churn "CLAUDE.md:churn-root" "backend/CLAUDE.md:churn-backend-v1")
PREFIX=$(run 600 "$P")
check "backend present on first run" churn-backend-v1 "$(marker_of "$PREFIX-backend.md")"
rm "$P/backend/CLAUDE.md"
PREFIX=$(run 600 "$P")
check "stale backend removed" MISSING "$(marker_of "$PREFIX-backend.md")"

echo "== 7. destinations are namespaced per project =="
A=$(newproject alpha "CLAUDE.md:alpha-root" "backend/CLAUDE.md:alpha-backend")
B=$(newproject beta  "CLAUDE.md:beta-root")
PREFIX_A=$(run 700 "$A")
PREFIX_B=$(run 700 "$B")
check "different prefixes per project" different \
    "$([[ "$PREFIX_A" != "$PREFIX_B" ]] && echo different || echo same)"
check "project A backend untouched by B" alpha-backend "$(marker_of "$PREFIX_A-backend.md")"
check "project B has no backend leak"    MISSING       "$(marker_of "$PREFIX_B-backend.md")"

echo "== 8. reports which docs were copied so a miss is visible =="
P=$(newproject reported "CLAUDE.md:rep-root" "backend/CLAUDE.md:rep-backend")
ERR=$(TMPDIR="$DEST" bash "$SCRIPT" 800 "$P" 2>&1 >/dev/null)
check "names root"        yes "$(grep -q root    <<<"$ERR" && echo yes || echo no)"
check "names backend"     yes "$(grep -q backend <<<"$ERR" && echo yes || echo no)"
check "omits frontend"    yes "$(grep -q frontend <<<"$ERR" && echo no || echo yes)"

echo "== 9. no CLAUDE.md at all -> non-zero exit =="
P=$(newproject empty)
if TMPDIR="$DEST" bash "$SCRIPT" 900 "$P" >/dev/null 2>&1; then rc=0; else rc=1; fi
check "exits non-zero" 1 "$rc"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
