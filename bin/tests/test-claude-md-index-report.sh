#!/bin/bash
# Tests for claude-md-index-report.sh.
#
# Usage:
#   bin/tests/test-claude-md-index-report.sh
#
# Drives the real script against fixture project trees in a temp dir. The global
# CLAUDE.md is redirected with CLAUDE_HOME so no test ever reads or reports on the
# machine's actual ~/.claude — a report that measured the developer's own always-
# loaded set would pass or fail depending on whose laptop ran it.
#
# What is deliberately NOT mocked: the script. The behaviour under test is which
# files it decides are always loaded, which list items it calls index entries, and
# when it warns — so every assertion goes through the real discovery and parsing.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../claude-md-index-report.sh}"

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

# Every run gets an empty fake ~/.claude unless the case fills it in.
run() { # project-dir [args...]
    local dir="$1"; shift
    CLAUDE_HOME="${FAKE_CLAUDE_HOME:-$T/empty-home}" "$SCRIPT" "$dir" "$@"
}
mkdir -p "$T/empty-home"

# --- fixtures -----------------------------------------------------------------
# A project whose root CLAUDE.md carries an index and an @include.
mkdir -p "$T/proj/docs/development"
cat > "$T/proj/CLAUDE.md" <<'MD'
# Project

## Operational Guidelines

- [docker-restart](docs/development/docker-restart.md)
- [green-test-proves-nothing](docs/development/green-test-proves-nothing.md) — a test already green on old code (#12)

@shared-rules.md
MD
cat > "$T/proj/shared-rules.md" <<'MD'
# Shared rules

- [migration-order](docs/development/migration-order.md) — expand before contract
MD
printf '# Docker restart\n\nWhy it matters.\n' > "$T/proj/docs/development/docker-restart.md"
printf '# A green test proves nothing\n\nWhy it matters.\n' > "$T/proj/docs/development/green-test-proves-nothing.md"
printf '# Migration order\n\nWhy it matters.\n' > "$T/proj/docs/development/migration-order.md"
printf 'No heading here, just an intro line.\n' > "$T/proj/docs/development/headless.md"

echo "== 1. discovery of the always-loaded set =="
OUT=$(run "$T/proj" 2>&1); RC=$?
check "exits 0"                      "0"   "$RC"
check "finds the project CLAUDE.md"  "yes" "$(contains "$OUT" "CLAUDE.md")"
check "follows an @include"          "yes" "$(contains "$OUT" "shared-rules.md")"
check "reports a line total"         "yes" "$(contains "$OUT" "Total always-loaded lines")"

echo "== 2. the global CLAUDE.md counts as always loaded =="
mkdir -p "$T/home"
printf '# Global\n\n- [global-doc](docs/global-doc.md)\n' > "$T/home/CLAUDE.md"
FAKE_CLAUDE_HOME="$T/home"
OUT=$(FAKE_CLAUDE_HOME="$T/home" run "$T/proj" 2>&1)
check "includes the global CLAUDE.md" "yes" "$(contains "$OUT" "$T/home/CLAUDE.md")"
check "lists a global index entry"    "yes" "$(contains "$OUT" "global-doc")"
unset FAKE_CLAUDE_HOME

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
