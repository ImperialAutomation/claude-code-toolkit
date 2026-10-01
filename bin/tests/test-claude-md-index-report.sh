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

echo "== 3. index entries, one per line, whatever the heading says =="
# The project names its own sections. An index found only under a known heading
# would silently report zero entries for a project that calls it something else.
mkdir -p "$T/odd-headings"
cat > "$T/odd-headings/CLAUDE.md" <<'MD'
# Project

## Wat we geleerd hebben

* [dutch-heading-doc](docs/dutch-heading-doc.md) — under a heading no script knows

### Deeply Nested Reference Material

- [nested-doc](docs/nested-doc.md)

Prose with an [inline link](https://example.com) that is not a list item.

| [table-link](docs/table.md) | not a list item either |
MD
OUT=$(run "$T/odd-headings" 2>&1)
check "entry under an unknown heading" "yes" "$(contains "$OUT" "dutch-heading-doc")"
check "entry under a nested heading"   "yes" "$(contains "$OUT" "nested-doc")"
# An inline prose link is not an index entry; counting it inflates the number the
# agent is asked to act on.
check "inline prose link is not an entry" "no" "$(contains "$OUT" "inline link")"
check "table link is not an entry"        "no" "$(contains "$OUT" "table-link")"
check "reports an entry count"            "yes" "$(contains "$OUT" "Index entries")"

echo "== 4. one entry per output line =="
# A multi-entry line in the source is still one entry per report line, because the
# agent reads this list to decide "does one of these already cover my finding".
ENTRY_LINES=$(run "$T/proj" 2>&1 | grep -c 'docs/development/')
check "three project entries listed" "3" "$ENTRY_LINES"

echo "== 5. scoped CLAUDE.md files are listed separately, not counted as loaded =="
# frontend/CLAUDE.md loads only when a file under frontend/ is read, so its lines
# are not an always-session cost. But a doc indexed there must not be indexed in
# the root too, so the report has to show what is already claimed elsewhere.
mkdir -p "$T/scoped/frontend" "$T/scoped/docs"
printf '# Root\n\n- [root-doc](docs/root-doc.md)\n' > "$T/scoped/CLAUDE.md"
printf '# Frontend\n\n- [fe-doc](docs/fe-doc.md)\n' > "$T/scoped/frontend/CLAUDE.md"
OUT=$(run "$T/scoped" 2>&1)
check "scoped file is reported"        "yes" "$(contains "$OUT" "frontend/CLAUDE.md")"
check "scoped entry is reported"       "yes" "$(contains "$OUT" "fe-doc")"
check "scoped section is labelled"     "yes" "$(contains "$OUT" "already indexed")"
# The whole point of the separation: a scoped file's lines must not inflate the
# always-loaded total, or the threshold fires for a cost nobody pays every session.
SCOPED_TOTAL=$(run "$T/scoped" 2>&1 | grep 'Total always-loaded lines' | tr -dc '0-9 ' | awk '{print $1}')
ROOT_LINES=$(wc -l < "$T/scoped/CLAUDE.md" | tr -d ' ')
check "scoped lines excluded from total" "$ROOT_LINES" "$SCOPED_TOTAL"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
