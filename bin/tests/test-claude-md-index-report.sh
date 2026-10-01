#!/bin/bash
# Tests for claude-md-index-report.sh.
#
# Usage:
#   bin/tests/test-claude-md-index-report.sh
#
# Drives the real script against fixture project trees in a temp dir. The global
# CLAUDE.md is redirected with CLAUDE_HOME so no test ever reads or reports on the
# machine's actual ~/.claude. A report that measured the developer's own always-
# loaded set would pass or fail depending on whose laptop ran it.
#
# What is deliberately NOT mocked: the script. The behaviour under test is which
# files it decides are always loaded, which list items it calls index entries, and
# when it warns, so every assertion goes through the real discovery and parsing.

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

echo "== 4. the reported entry count is the real number of entries =="
# The agent reads this count to decide whether the index has outgrown a lookup
# table. Three entries across the root and its include is three, not the number of
# lines that happen to mention a docs path elsewhere in the report.
ENTRY_COUNT=$(run "$T/proj" 2>&1 | grep 'Index entries (always loaded):' | tr -dc '0-9')
check "three project entries counted" "3" "$ENTRY_COUNT"

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

echo "== 6. consolidation candidates: one truncated line per existing doc =="
OUT=$(run "$T/proj" 2>&1)
check "candidates section present"  "yes" "$(contains "$OUT" "Consolidation candidates")"
check "lists an indexed doc"        "yes" "$(contains "$OUT" "docker-restart.md")"
# A doc on disk that nothing indexes is the most consolidatable of all -- it is
# already costing nothing, so folding a finding into it is free.
check "lists an unindexed doc"      "yes" "$(contains "$OUT" "headless.md")"
check "shows a doc's first heading" "yes" "$(contains "$OUT" "A green test proves nothing")"
# No heading means the first prose line, so the agent still gets a subject.
check "falls back to the intro line" "yes" "$(contains "$OUT" "No heading here")"
check "reports a candidate count"    "yes" "$(contains "$OUT" "Candidate docs")"

echo "== 7. a candidate is one line, never a file dump =="
mkdir -p "$T/fat/docs/development"
{
    echo "# Fat doc"
    echo ""
    printf 'secret-sauce-line-%s\n' $(seq 1 200)
} > "$T/fat/docs/development/fat.md"
printf '# Root\n' > "$T/fat/CLAUDE.md"
OUT=$(run "$T/fat" 2>&1)
check "does not dump the body" "no" "$(contains "$OUT" "secret-sauce-line-7")"
FAT_LINES=$(printf '%s\n' "$OUT" | grep -c 'fat.md')
check "one line for the doc" "1" "$FAT_LINES"
# A long heading is truncated rather than wrapped, so the list stays scannable.
mkdir -p "$T/longhead/docs/development"
printf '# %s\n' "$(printf 'x%.0s' $(seq 1 300))" > "$T/longhead/docs/development/long.md"
printf '# Root\n' > "$T/longhead/CLAUDE.md"
LONGEST=$(run "$T/longhead" 2>&1 | grep 'long.md' | wc -c | tr -d ' ')
check "long heading is truncated" "yes" "$([[ $LONGEST -lt 200 ]] && echo yes || echo no)"

echo "== 8. a large docs directory is capped, not dumped =="
mkdir -p "$T/many/docs/development"
printf '# Root\n' > "$T/many/CLAUDE.md"
for i in $(seq 1 90); do
    printf '# Doc %s\n' "$i" > "$T/many/docs/development/doc-$i.md"
done
OUT=$(run "$T/many" 2>&1)
LISTED=$(printf '%s\n' "$OUT" | grep -c 'docs/development/doc-')
check "candidate list is capped"  "yes" "$([[ $LISTED -le 60 ]] && echo yes || echo no)"
check "says how many were hidden" "yes" "$(contains "$OUT" "more")"
check "still reports the true total" "yes" "$(contains "$OUT" "90")"

echo "== 9. --docs overrules the autodetected docs directory =="
mkdir -p "$T/custom/handbook" "$T/custom/docs/development"
printf '# Root\n' > "$T/custom/CLAUDE.md"
printf '# Handbook entry\n' > "$T/custom/handbook/hb.md"
printf '# Default entry\n' > "$T/custom/docs/development/def.md"
OUT=$(run "$T/custom" --docs handbook 2>&1)
check "uses the given docs dir"      "yes" "$(contains "$OUT" "hb.md")"
check "ignores the autodetected one" "no"  "$(contains "$OUT" "def.md")"

echo "== 10. the threshold warns and never blocks =="
# The threshold is a fixed constant in the script, so the test reads it from there
# rather than hardcoding a second copy that drifts when the constant is tuned.
THRESHOLD=$(grep -E '^MAX_ALWAYS_LOADED_LINES=' "$SCRIPT" | cut -d= -f2)
check "threshold is a number" "yes" "$([[ "$THRESHOLD" =~ ^[0-9]+$ ]] && echo yes || echo no)"

mkdir -p "$T/under"
{ printf '# Root\n'; seq 1 $((THRESHOLD - 10)); } > "$T/under/CLAUDE.md"
check "under fixture is really under" "yes" \
    "$([[ $(wc -l < "$T/under/CLAUDE.md") -lt $THRESHOLD ]] && echo yes || echo no)"
OUT=$(run "$T/under" 2>&1); RC=$?
check "under threshold exits 0"   "0"  "$RC"
check "under threshold is silent" "no" "$(contains "$OUT" "WARNING")"

mkdir -p "$T/over/docs/development"
{ printf '# Root\n'; seq 1 $((THRESHOLD + 10)); } > "$T/over/CLAUDE.md"
printf '# An existing mechanism\n' > "$T/over/docs/development/existing.md"
# Assert the fixture before asserting the behaviour: a fixture that quietly came
# out two lines long would make the "no warning" case pass for the wrong reason.
check "over fixture is really over" "yes" \
    "$([[ $(wc -l < "$T/over/CLAUDE.md") -gt $THRESHOLD ]] && echo yes || echo no)"
OUT=$(run "$T/over" 2>&1); RC=$?
check "over threshold warns" "yes" "$(contains "$OUT" "WARNING")"
# Blocking would make the helper something a caller routes around. A warning is
# information; a non-zero exit in a chain is a stop.
check "over threshold still exits 0" "0" "$RC"
check "warning names the threshold"  "yes" "$(contains "$OUT" "$THRESHOLD")"
# A bare number is not actionable. The warning has to say what to do instead of
# adding an entry, and this fixture has candidate docs to fold into.
check "warning says what to do"      "yes" "$(contains "$OUT" "Fold the finding into")"

echo "== 11. explicit --file replaces autodetection =="
mkdir -p "$T/explicit"
printf '# Root\n\n- [root-only](docs/root-only.md)\n' > "$T/explicit/CLAUDE.md"
printf '# Elsewhere\n\n- [elsewhere-doc](docs/elsewhere-doc.md)\n' > "$T/explicit/other.md"
OUT=$(run "$T/explicit" --file "$T/explicit/other.md" 2>&1)
check "uses the explicit file"      "yes" "$(contains "$OUT" "elsewhere-doc")"
# Not "in addition to": the issue asks for an override, and a caller measuring a
# specific set must not silently get the autodetected one folded in.
check "drops the autodetected root" "no"  "$(contains "$OUT" "root-only")"

OUT=$(run "$T/explicit" --file "$T/explicit/nope.md" 2>&1); RC=$?
check "missing explicit file is an error" "2"   "$RC"
check "error names the path"              "yes" "$(contains "$OUT" "nope.md")"

OUT=$(run "$T/explicit" --file 2>&1); RC=$?
check "--file without a value is an error" "2" "$RC"
OUT=$(run "$T/explicit" --bogus 2>&1); RC=$?
check "unknown option is an error"         "2" "$RC"

echo "== 12. runs in a project with no CLAUDE.md at all =="
# A report that errored here would fire on any project that has not started one,
# which is exactly when the index is still cheap to keep honest.
mkdir -p "$T/bare"
OUT=$(run "$T/bare" 2>&1); RC=$?
check "bare project exits 0"  "0"   "$RC"
check "says nothing is loaded" "yes" "$(contains "$OUT" "none found")"

echo "== 13. the summary's advice matches whether candidates exist =="
# Found on a real project: both summary branches pointed at "the candidates above"
# even when the list was empty, which is advice the reader cannot act on.
OUT=$(run "$T/proj" 2>&1)
check "with candidates, says fold into them" "yes" "$(contains "$OUT" "Fold the finding into")"

mkdir -p "$T/nodocs"
printf '# Root\n' > "$T/nodocs/CLAUDE.md"
OUT=$(run "$T/nodocs" 2>&1)
check "without candidates, says so"          "yes" "$(contains "$OUT" "no existing docs to fold into")"
check "without candidates, no dangling ref"  "no"  "$(contains "$OUT" "candidate docs above")"

# Same must hold in the warning branch, which is the one a real project hit.
mkdir -p "$T/overnodocs"
{ printf '# Root\n'; seq 1 $((THRESHOLD + 10)); } > "$T/overnodocs/CLAUDE.md"
OUT=$(run "$T/overnodocs" 2>&1)
check "over threshold, no candidates, warns" "yes" "$(contains "$OUT" "WARNING")"
check "over threshold, no dangling ref"      "no"  "$(contains "$OUT" "candidate docs above")"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
