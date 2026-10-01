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

# --- index entries ------------------------------------------------------------
# An index entry is a list item carrying a markdown link. Deliberately not scoped
# to a heading name: the project names its own sections ("Operational Guidelines",
# "Learned Procedures", a Dutch heading), and a report that only understood one
# name would confidently find zero entries in a project that grew the problem.
#
# A list item is the discriminator that keeps prose out. An inline link in a
# paragraph, or a link in a table cell, is a reference, not an index line someone
# could consolidate away.
INDEX_ENTRY_RE='^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+.*\[[^]]+\]\([^)]+\)'

list_entries() { # file...  -> "<file>:<lineno>\t<text>" per entry
    local f lineno line
    for f in "$@"; do
        lineno=0
        while IFS= read -r line; do
            lineno=$((lineno + 1))
            [[ "$line" =~ $INDEX_ENTRY_RE ]] || continue
            # Strip the list marker and leading space; the entry itself is what the
            # agent reads, the location is for finding it again.
            local text="${line#"${line%%[![:space:]]*}"}"
            text="${text#* }"
            printf '%s:%s\t%s\n' "$f" "$lineno" "$text"
        done < "$f"
    done
}

echo "── Index entries in the always-loaded set ──"
ENTRIES=$(list_entries "${ALWAYS_LOADED[@]}")
if [[ -z "$ENTRIES" ]]; then
    ENTRY_COUNT=0
    echo "  none"
else
    ENTRY_COUNT=$(printf '%s\n' "$ENTRIES" | wc -l | tr -d ' ')
    while IFS=$'\t' read -r loc text; do
        printf '  %s\n      %s\n' "$text" "$loc"
    done <<< "$ENTRIES"
fi
echo ""
echo "Index entries (always loaded): $ENTRY_COUNT"
echo ""

# --- scoped CLAUDE.md files ---------------------------------------------------
# These load on demand (reading a file under their directory pulls them in), so
# their lines are not a per-session cost and stay out of the total above. They are
# reported anyway for one reason: a doc indexed here must not be indexed in the
# root as well, and checking only the root is how a doc ends up listed twice.
if [[ ${#EXPLICIT_FILES[@]} -eq 0 ]]; then
    SCOPED=()
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        [[ "$f" == "$PROJECT_DIR/CLAUDE.md" ]] && continue
        SCOPED+=("$f")
    done < <(find "$PROJECT_DIR" -name CLAUDE.md -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | sort)

    if [[ ${#SCOPED[@]} -gt 0 ]]; then
        echo "── Scoped CLAUDE.md files (load on demand; already indexed here) ──"
        for f in "${SCOPED[@]}"; do
            printf '  %s\n' "${f#"$PROJECT_DIR"/}"
        done
        echo ""
        SCOPED_ENTRIES=$(list_entries "${SCOPED[@]}")
        if [[ -n "$SCOPED_ENTRIES" ]]; then
            while IFS=$'\t' read -r loc text; do
                printf '  %s\n      %s\n' "$text" "${loc#"$PROJECT_DIR"/}"
            done <<< "$SCOPED_ENTRIES"
            echo ""
        fi
    fi
fi

# --- consolidation candidates -------------------------------------------------
# Every doc already on disk, indexed or not, with its subject on one line. This is
# the list the caller reads to answer "does one of these already describe the same
# mechanism as my finding". It is deliberately complete and deliberately not
# keyword-matched: a doc that states the same lesson in different words is exactly
# the one that must not drop out of the list as "no match".
#
# One line per doc, truncated. The subject is enough to decide whether to open it;
# the body is what the doc is for.

DOCS_DIR=""
if [[ -n "$DOCS_DIR_ARG" ]]; then
    if [[ "$DOCS_DIR_ARG" = /* ]]; then
        DOCS_DIR="$DOCS_DIR_ARG"
    else
        DOCS_DIR="$PROJECT_DIR/$DOCS_DIR_ARG"
    fi
    if [[ ! -d "$DOCS_DIR" ]]; then
        echo "Error: docs directory not found: $DOCS_DIR" >&2
        exit 2
    fi
else
    # docs/development/ is where the retro convention writes; docs/ is the fallback
    # for a project that keeps them one level up.
    for candidate in "$PROJECT_DIR/docs/development" "$PROJECT_DIR/docs"; do
        if [[ -d "$candidate" ]]; then
            DOCS_DIR="$candidate"
            break
        fi
    done
fi

doc_summary() { # file -> first heading, else first non-empty prose line
    local line
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        line="${line#"${line%%[![:space:]]*}"}"
        # A heading is the doc's own statement of its subject, so prefer it; but a
        # doc without one still has a subject in its opening line.
        if [[ "$line" == '#'* ]]; then
            line="${line##*#}"
            line="${line#"${line%%[![:space:]]*}"}"
        fi
        printf '%s\n' "$line"
        return 0
    done < "$1"
    printf '(empty)\n'
}

echo "── Consolidation candidates ──"
if [[ -z "$DOCS_DIR" ]]; then
    echo "  no docs directory found (looked for docs/development/, docs/)"
    echo ""
    echo "The first finding written here starts the index; there is nothing to fold into yet."
else
    echo "  from: ${DOCS_DIR#"$PROJECT_DIR"/}"
    echo ""
    DOC_TOTAL=0
    SHOWN=0
    while IFS= read -r doc; do
        [[ -n "$doc" ]] || continue
        DOC_TOTAL=$((DOC_TOTAL + 1))
        [[ $SHOWN -ge $MAX_CANDIDATES ]] && continue
        SHOWN=$((SHOWN + 1))
        summary="$(doc_summary "$doc")"
        if [[ ${#summary} -gt $MAX_SUMMARY_CHARS ]]; then
            summary="${summary:0:$MAX_SUMMARY_CHARS}..."
        fi
        printf '  %-44s  %s\n' "${doc#"$PROJECT_DIR"/}" "$summary"
    done < <(find "$DOCS_DIR" -type f -name '*.md' 2>/dev/null | sort)

    if [[ $DOC_TOTAL -eq 0 ]]; then
        echo "  none"
    elif [[ $DOC_TOTAL -gt $SHOWN ]]; then
        echo "  ... and $((DOC_TOTAL - SHOWN)) more (list capped at $MAX_CANDIDATES)"
    fi
    echo ""
    echo "Candidate docs: $DOC_TOTAL"
fi
echo ""
