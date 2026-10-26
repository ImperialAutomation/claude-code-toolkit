#!/usr/bin/env bash
# doc-budget-check.sh: enforce a per-file byte budget on markdown docs.
#
# An index that stays small says nothing about the documents behind it. A doc
# that every retro appends to grows without bound, and an agent that follows the
# index link pays for the whole file. This check gives each doc a budget: above
# the warn size it is reported, above the fail size the check exits 1. Over
# budget means split the doc by theme, not append to it.
#
# Usage:
#   doc-budget-check.sh [--warn SIZE] [--fail SIZE] [--repo DIR] <doc-root>...
#
#   <doc-root>    a directory (searched recursively for *.md) or a single file
#   --warn SIZE   report files above SIZE (default 15K)
#   --fail SIZE   report files above SIZE and exit 1 (default 25K)
#   --repo DIR    repo root for the exception list and for the paths printed;
#                 default the git toplevel of the current directory, or the
#                 current directory outside git
#   SIZE          bytes, or with a K suffix (x1024): 15000, 15K, 15k
#
# Skipped: every file below a directory named `archive`.
#
# Exception list: <repo>/.claude/doc-budget-exceptions, when it exists. One path
# per line, relative to the repo root; blank lines and lines starting with #
# are ignored. A listed file is reported as "exempt" instead of failing. A
# listed file that is back under the warn size is reported as a stale entry, so
# the list does not outlive its reasons.
#
# Output: one line per file over the warn size, largest first, then a summary:
#   FAIL    31.2K  docs/catalog.md
#   WARN    16.0K  docs/setup.md
#   exempt  40.1K  docs/generated-reference.md
#   doc-budget: 2 over warn (15.0K), 1 over fail (25.0K), 1 exempt, 48 files checked
#
# Exit codes:
#   0  no file over the fail size (warnings and exempt files allowed)
#   1  at least one file over the fail size and not in the exception list
#   2  usage error, or a <doc-root> that does not exist
#
# Examples:
#   doc-budget-check.sh docs/
#   doc-budget-check.sh --warn 12K --fail 20K docs/development docs/architecture
#   doc-budget-check.sh --repo ~/Projects/acme docs/   # from anywhere
#
# As a pre-commit hook (.pre-commit-config.yaml, repo: local):
#   - id: doc-budget
#     name: doc byte budget
#     entry: doc-budget-check.sh docs
#     language: system
#     pass_filenames: false

set -uo pipefail

DEFAULT_WARN=15K
DEFAULT_FAIL=25K
EXCEPTIONS_REL=.claude/doc-budget-exceptions
ARCHIVE_DIR=archive
KIB=1024

usage() {
    echo "usage: $(basename "$0") [--warn SIZE] [--fail SIZE] [--repo DIR] <doc-root>..." >&2
    exit 2
}

# SIZE -> bytes on stdout; non-zero status when it is not a size.
to_bytes() {
    case "$1" in
        ''|*[!0-9kK]*) return 1 ;;
        *[kK]) local n="${1%[kK]}"; [[ "$n" =~ ^[0-9]+$ ]] || return 1; echo $((n * KIB)) ;;
        *) [[ "$1" =~ ^[0-9]+$ ]] || return 1; echo "$1" ;;
    esac
}

# bytes -> "12.3K", one decimal, the unit the thresholds are given in.
human() {
    printf '%d.%dK' $(($1 / KIB)) $((($1 % KIB) * 10 / KIB))
}

WARN_SIZE=$DEFAULT_WARN
FAIL_SIZE=$DEFAULT_FAIL
REPO=""
ROOTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --warn) [[ $# -ge 2 ]] || usage; WARN_SIZE="$2"; shift 2 ;;
        --fail) [[ $# -ge 2 ]] || usage; FAIL_SIZE="$2"; shift 2 ;;
        --repo) [[ $# -ge 2 ]] || usage; REPO="$2"; shift 2 ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        --) shift; ROOTS+=("$@"); break ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) ROOTS+=("$1"); shift ;;
    esac
done

[[ ${#ROOTS[@]} -gt 0 ]] || usage
WARN=$(to_bytes "$WARN_SIZE") || { echo "--warn is not a size: $WARN_SIZE" >&2; exit 2; }
FAIL=$(to_bytes "$FAIL_SIZE") || { echo "--fail is not a size: $FAIL_SIZE" >&2; exit 2; }
[[ "$WARN" -le "$FAIL" ]] || { echo "--warn ($WARN_SIZE) is above --fail ($FAIL_SIZE)" >&2; exit 2; }

if [[ -z "$REPO" ]]; then
    REPO=$(git rev-parse --show-toplevel 2>/dev/null) || REPO="$PWD"
fi
[[ -d "$REPO" ]] || { echo "--repo is not a directory: $REPO" >&2; exit 2; }
REPO=$(cd "$REPO" && pwd -P)

# Exceptions, as repo-relative paths.
declare -A EXEMPT=()
if [[ -f "$REPO/$EXCEPTIONS_REL" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        EXEMPT["${line#./}"]=1
    done < "$REPO/$EXCEPTIONS_REL"
fi

# Repo-relative spelling of an absolute path; the path itself when outside.
relpath() {
    case "$1" in
        "$REPO"/*) echo "${1#"$REPO"/}" ;;
        *) echo "$1" ;;
    esac
}

FILES=()
for root in "${ROOTS[@]}"; do
    # A relative root is relative to the repo when --repo is given, else to PWD.
    [[ "$root" == /* || -e "$root" ]] || root="$REPO/$root"
    [[ -e "$root" ]] || { echo "doc root does not exist: $root" >&2; exit 2; }
    if [[ -f "$root" ]]; then
        FILES+=("$(cd "$(dirname "$root")" && pwd -P)/$(basename "$root")")
        continue
    fi
    root=$(cd "$root" && pwd -P)
    while IFS= read -r -d '' f; do
        FILES+=("$f")
    done < <(find "$root" -type d -name "$ARCHIVE_DIR" -prune -o -type f -name '*.md' -print0)
done

declare -A SEEN=()
REPORT=()
N_WARN=0; N_FAIL=0; N_EXEMPT=0; N_CHECKED=0
for f in "${FILES[@]}"; do
    [[ -z "${SEEN[$f]:-}" ]] || continue
    SEEN[$f]=1
    rel=$(relpath "$f")
    # A single file given directly still honours the archive skip.
    [[ "/$rel/" == */"$ARCHIVE_DIR"/* ]] && continue
    N_CHECKED=$((N_CHECKED + 1))
    size=$(wc -c < "$f" | tr -d ' ')
    exempt="${EXEMPT[$rel]:-}"
    if [[ -n "$exempt" ]]; then
        if [[ "$size" -gt "$WARN" ]]; then
            N_EXEMPT=$((N_EXEMPT + 1))
            REPORT+=("$size"$'\t'"exempt"$'\t'"$rel")
        else
            REPORT+=("$size"$'\t'"stale"$'\t'"$rel")
        fi
        continue
    fi
    if [[ "$size" -gt "$FAIL" ]]; then
        N_FAIL=$((N_FAIL + 1)); N_WARN=$((N_WARN + 1))
        REPORT+=("$size"$'\t'"FAIL"$'\t'"$rel")
    elif [[ "$size" -gt "$WARN" ]]; then
        N_WARN=$((N_WARN + 1))
        REPORT+=("$size"$'\t'"WARN"$'\t'"$rel")
    fi
done

if [[ ${#REPORT[@]} -gt 0 ]]; then
    while IFS=$'\t' read -r size label rel; do
        if [[ "$label" == stale ]]; then
            printf 'stale   %7s  %s (in %s but under %s: remove the entry)\n' \
                "$(human "$size")" "$rel" "$EXCEPTIONS_REL" "$(human "$WARN")"
        else
            printf '%-6s  %7s  %s\n' "$label" "$(human "$size")" "$rel"
        fi
    done < <(printf '%s\n' "${REPORT[@]}" | sort -t$'\t' -k1,1nr)
fi

printf 'doc-budget: %d over warn (%s), %d over fail (%s), %d exempt, %d files checked\n' \
    "$N_WARN" "$(human "$WARN")" "$N_FAIL" "$(human "$FAIL")" "$N_EXEMPT" "$N_CHECKED"

[[ "$N_FAIL" -eq 0 ]]
