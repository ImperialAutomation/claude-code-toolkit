#!/usr/bin/env bash
set -uo pipefail

# Report the cost of the always-loaded CLAUDE.md set, and list the docs that a new
# finding could be folded into instead of getting its own index line.
#
# Why this exists as a script: the always-loaded set is paid for in every session
# and every sub-agent, so an index that grows per finding is a recurring cost. The
# hygiene rules for it already live in prose and were still outgrown, so the number
# has to be measurable rather than remembered.
#
# This reports. It never edits, never blocks, and exits 0 even over the threshold --
# the semantic judgement of "is this the same mechanism as an existing doc" is the
# caller's, which is why the candidate list is complete rather than keyword-matched.
#
# Usage: claude-md-index-report.sh [project-dir] [--docs DIR] [--file PATH]...
#   project-dir  project root (default: .)
#   --docs DIR   docs directory to list candidates from, relative to project-dir
#                or absolute (default: autodetected)
#   --file PATH  an always-loaded file, replacing autodetection entirely;
#                repeatable
#
# Env: CLAUDE_HOME  overrides ~/.claude (used by the tests)

# Fixed threshold, deliberately not configurable: the point is a testable criterion
# that is the same in every project, tunable from this one line.
MAX_ALWAYS_LOADED_LINES=400

# Caps on the candidate list, so a project with hundreds of docs gets a report
# rather than a dump.
MAX_CANDIDATES=60
MAX_SUMMARY_CHARS=80

PROJECT_DIR=""
DOCS_DIR_ARG=""
EXPLICIT_FILES=()

usage() {
    cat <<'USAGE'
Usage: claude-md-index-report.sh [project-dir] [--docs DIR] [--file PATH]...

  project-dir  project root (default: .)
  --docs DIR   docs directory to list candidates from, relative to project-dir
               or absolute (default: autodetected)
  --file PATH  an always-loaded file, replacing autodetection entirely; repeatable
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --docs)
            [[ $# -ge 2 ]] || { echo "Error: --docs needs a directory" >&2; exit 2; }
            DOCS_DIR_ARG="$2"; shift 2 ;;
        --file)
            [[ $# -ge 2 ]] || { echo "Error: --file needs a path" >&2; exit 2; }
            EXPLICIT_FILES+=("$2"); shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 2 ;;
        *)
            PROJECT_DIR="$1"; shift ;;
    esac
done

PROJECT_DIR="${PROJECT_DIR:-.}"
if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: directory not found: $PROJECT_DIR" >&2
    exit 2
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# --- the always-loaded set ----------------------------------------------------
# Always loaded means: read at session start regardless of what the session goes
# on to touch. That is the project root CLAUDE.md and the global one, plus the
# files those pull in with an `@path` include -- an include is loaded with its
# host, so its lines cost exactly the same.
#
# Scoped files (frontend/CLAUDE.md, backend/app/CLAUDE.md) are NOT in this set:
# they load only once a file under their directory is read. They are still read
# further down, because a doc indexed there must not be indexed again in the root.

ALWAYS_LOADED=()

add_file() { # path
    local f="$1" existing
    [[ -f "$f" ]] || return 0
    f="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    for existing in ${ALWAYS_LOADED+"${ALWAYS_LOADED[@]}"}; do
        [[ "$existing" == "$f" ]] && return 0
    done
    ALWAYS_LOADED+=("$f")

    # Follow `@relative/path` includes, resolved against the including file's own
    # directory. Recursive, and the dedupe above is what stops an include cycle.
    local base line target
    base="$(dirname "$f")"
    while IFS= read -r line; do
        [[ "$line" =~ ^@([^[:space:]]+)[[:space:]]*$ ]] || continue
        target="${BASH_REMATCH[1]}"
        [[ "$target" = /* ]] || target="$base/$target"
        add_file "$target"
    done < "$f"
}

if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
    for f in "${EXPLICIT_FILES[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "Error: file not found: $f" >&2
            exit 2
        fi
        add_file "$f"
    done
else
    add_file "$PROJECT_DIR/CLAUDE.md"
    add_file "$CLAUDE_HOME/CLAUDE.md"
fi

echo "CLAUDE.md Index Report"
echo "=================================================="
echo "Project: $PROJECT_DIR"
echo ""

echo "── Always-loaded files ──"
if [[ ${#ALWAYS_LOADED[@]} -eq 0 ]]; then
    echo "  none found"
    echo ""
    echo "Nothing loads at session start, so there is no index to grow."
    exit 0
fi

TOTAL_LINES=0
for f in "${ALWAYS_LOADED[@]}"; do
    n=$(wc -l < "$f" | tr -d ' ')
    TOTAL_LINES=$((TOTAL_LINES + n))
    printf "  %6s  %s\n" "$n" "$f"
done
echo ""
echo "Total always-loaded lines: $TOTAL_LINES (threshold: $MAX_ALWAYS_LOADED_LINES)"
echo ""
