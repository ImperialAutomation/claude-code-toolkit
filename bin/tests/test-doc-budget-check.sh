#!/bin/bash
# Tests for doc-budget-check.sh.
#
# Usage:
#   bin/tests/test-doc-budget-check.sh
#
# Builds throwaway doc trees of known sizes and checks what the script reports
# and how it exits. Sizes are set with small thresholds (--warn 1K --fail 2K)
# so the fixtures stay tiny.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../doc-budget-check.sh}"

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

# mkdoc <path> <bytes>: a file of exactly <bytes> bytes.
mkdoc() {
    mkdir -p "$(dirname "$1")"
    head -c "$2" /dev/zero | tr '\0' 'x' > "$1"
}

# run <repo> [args...]: output in $OUT, status in $STATUS. Always from inside
# <repo>, which is not a git repo, so <repo> is the root by the PWD fallback.
run() {
    local repo="$1"; shift
    OUT=$(env -C "$repo" bash "$SCRIPT" "$@" 2>&1); STATUS=$?
}

R="$T/repo"
mkdoc "$R/docs/small.md" 500
mkdoc "$R/docs/warn.md" 1500
mkdoc "$R/docs/sub/fail.md" 3000
mkdoc "$R/docs/archive/huge.md" 9000
mkdoc "$R/docs/sub/archive/deep/huge.md" 9000
mkdoc "$R/docs/notes.txt" 9000

echo "== 1. thresholds and exit status =="
run "$R" --warn 1K --fail 2K docs
check "a file over fail exits 1"           "1"   "$STATUS"
check "the failing file is named as FAIL"  "yes" "$(contains "$OUT" "FAIL")"
check "path printed repo-relative"         "yes" "$(contains "$OUT" "docs/sub/fail.md")"
check "the warn file is named as WARN"     "yes" "$(contains "$OUT" "WARN")"
check "a file under warn is not listed"    "no"  "$(contains "$OUT" "small.md")"
check "sizes are printed in K"             "yes" "$(contains "$OUT" "2.9K")"
check "summary counts"                     "yes" \
    "$(contains "$OUT" "2 over warn (1.0K), 1 over fail (2.0K), 0 exempt, 3 files checked")"
# Largest first: the FAIL line comes before the WARN line.
first=$(printf '%s\n' "$OUT" | head -1)
check "largest file listed first"          "yes" "$(contains "$first" "fail.md")"

run "$R" --warn 1K --fail 4K docs
check "only warnings exits 0"              "0"   "$STATUS"

echo "== 2. what is skipped =="
check "archive/ is skipped"                "no"  "$(contains "$OUT" "archive")"
check "non-markdown is skipped"            "no"  "$(contains "$OUT" "notes.txt")"
run "$R" --warn 1K --fail 2K docs/archive/huge.md
check "a file given directly under archive/ is skipped" "0" "$STATUS"

echo "== 3. exception list =="
mkdir -p "$R/.claude"
printf '%s\n' "# generated reference, split tracked elsewhere" "" "docs/sub/fail.md" "  ./docs/small.md  " > "$R/.claude/doc-budget-exceptions"
run "$R" --warn 1K --fail 2K docs
check "an excepted file does not fail"     "0"   "$STATUS"
check "it is reported as exempt"           "yes" "$(contains "$OUT" "exempt")"
check "summary counts the exempt file"     "yes" "$(contains "$OUT" "1 exempt")"
# small.md is listed but under the warn size: the entry has no reason left.
check "an entry under warn is reported stale" "yes" "$(contains "$OUT" "stale")"
check "the stale line names the file"      "yes" "$(contains "$OUT" "docs/small.md (in .claude/doc-budget-exceptions")"
rm "$R/.claude/doc-budget-exceptions"

echo "== 4. --repo and roots =="
run "$T" --repo "$R" --warn 1K --fail 2K docs
check "--repo resolves a relative root"    "1"   "$STATUS"
check "--repo makes paths repo-relative"   "yes" "$(contains "$OUT" "docs/sub/fail.md")"
run "$R" --warn 1K --fail 2K docs/small.md docs/warn.md
check "single files as roots"              "yes" "$(contains "$OUT" "2 files checked")"
run "$R" --warn 1K --fail 2K docs docs/sub
check "a file reached twice is counted once" "yes" "$(contains "$OUT" "3 files checked")"
run "$R" --warn 1500 --fail 2K docs
check "byte thresholds: exactly warn is not over" "yes" "$(contains "$OUT" "1 over warn")"

echo "== 5. defaults =="
run "$R" docs
check "defaults: 3000 bytes is fine"       "0"   "$STATUS"
check "defaults named in the summary"      "yes" "$(contains "$OUT" "(15.0K)")"

echo "== 6. usage errors =="
run "$R";                         check "no root exits 2"             "2" "$STATUS"
run "$R" missing-dir;             check "missing root exits 2"        "2" "$STATUS"
run "$R" --warn abc docs;         check "bad --warn exits 2"          "2" "$STATUS"
run "$R" --fail 2KB docs;         check "bad --fail exits 2"          "2" "$STATUS"
run "$R" --warn 3K --fail 2K docs; check "warn above fail exits 2"    "2" "$STATUS"
run "$R" --bogus docs;            check "unknown option exits 2"      "2" "$STATUS"
run "$R" --help
check "--help exits 0"                     "0"   "$STATUS"
check "--help describes the exception list" "yes" "$(contains "$OUT" ".claude/doc-budget-exceptions")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
