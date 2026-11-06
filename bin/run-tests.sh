#!/usr/bin/env bash
# run-tests.sh — run every toolkit test script; the same set locally and in CI.
#
# Discovers bin/test-*.sh, bin/test-*.py and bin/tests/test-*.sh, runs each one
# on its own (bash for .sh, python3 for .py) and reports per script. A script
# passes when it exits 0. The GitHub Actions workflow runs this with --ci, so
# "CI is green" and "run-tests.sh is green" mean the same set of scripts.
#
# Usage:
#   run-tests.sh [--ci] [--list] [<test-script>...]
#
#   --ci     also apply CI_SKIP below: tests that need something a stock
#            runner lacks. Implied when $CI is "true" (GitHub Actions sets it).
#   --list   print the scripts that would run, and the skips, then exit 0.
#   <test-script>  run only these (paths or basenames); default: all.
#
# Skips are never silent: each one prints "SKIP <script>: <reason>" and is
# repeated in the summary. A missing prerequisite tool (PREREQS below) stops
# the run before any test instead: a green run never hides an absent tool.
#
# Output: per script a PASS/FAIL line; a failing script's own output is shown
# in full, framed by its name. The summary lists every failing script by name.
# Under GitHub Actions each failure is also an ::error:: annotation.
#
# Exit codes:
#   0    every script that ran passed
#   1    at least one script failed
#   2    usage error, a named script does not exist, or a PREREQS tool is
#        missing

set -uo pipefail

BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$BIN_DIR")

# Tests skipped under --ci, keyed by path relative to the repo, with the reason
# printed in the job log, e.g.
#   [bin/tests/test-foo.sh]="reads the real ~/.claude/settings.json"
# Add an entry only when making the test hermetic is not cheap; prefer fixing
# the test. Currently every test runs in CI: none is listed.
declare -A CI_SKIP=(
)

# Tools the tests as a set call directly (jq: hook tests; curl and python3:
# http-status). A missing one is a broken environment, not a reason to skip:
# the run stops before any test, naming the tool.
PREREQS=(git python3 jq curl)

usage() {
    echo "usage: $(basename "$0") [--ci] [--list] [<test-script>...]" >&2
    exit 2
}

CI_MODE=false
[[ "${CI:-}" == "true" ]] && CI_MODE=true
LIST_ONLY=false
SELECTED=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        --ci) CI_MODE=true ;;
        --list) LIST_ONLY=true ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) SELECTED+=("$1") ;;
    esac
    shift
done

# All test scripts, as paths relative to the repo, in a stable order.
discover() {
    local f
    for f in "$BIN_DIR"/test-*.sh "$BIN_DIR"/test-*.py "$BIN_DIR"/tests/test-*.sh; do
        [[ -f "$f" ]] && echo "${f#"$REPO_DIR"/}"
    done | sort
}

# Resolve a user-given name (path or basename) to a discovered test.
resolve() {
    local want="$1" t
    for t in "${ALL[@]}"; do
        if [[ "$t" == "$want" || "$(basename "$t")" == "$want" \
              || "$REPO_DIR/$t" == "$(realpath -m "$want")" ]]; then
            echo "$t"; return 0
        fi
    done
    return 1
}

# Why a test is skipped, or nothing when it runs.
skip_reason() {
    if $CI_MODE && [[ -n "${CI_SKIP[$1]:-}" ]]; then
        echo "${CI_SKIP[$1]}"
    fi
}

for tool in "${PREREQS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "required tool not on PATH: $tool" >&2; exit 2; }
done

mapfile -t ALL < <(discover)
TESTS=()
if [[ ${#SELECTED[@]} -gt 0 ]]; then
    for s in "${SELECTED[@]}"; do
        t=$(resolve "$s") || { echo "no such test script: $s" >&2; exit 2; }
        TESTS+=("$t")
    done
else
    TESTS=("${ALL[@]}")
fi

IN_GHA=false
[[ "${GITHUB_ACTIONS:-}" == "true" ]] && IN_GHA=true

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

PASSED=(); FAILED=(); SKIPPED=()
for t in "${TESTS[@]}"; do
    reason=$(skip_reason "$t")
    if [[ -n "$reason" ]]; then
        echo "SKIP $t: $reason"
        SKIPPED+=("$t: $reason")
        continue
    fi
    if $LIST_ONLY; then echo "RUN  $t"; continue; fi

    case "$t" in
        *.py) runner=(python3) ;;
        *)    runner=(bash) ;;
    esac
    start=$SECONDS
    # Each test runs from the repo root with stdin closed, so a test that
    # waits for input fails instead of hanging the job.
    env -C "$REPO_DIR" "${runner[@]}" "$t" </dev/null >"$LOG" 2>&1
    status=$?
    elapsed=$((SECONDS - start))
    if [[ $status -eq 0 ]]; then
        echo "PASS $t (${elapsed}s)"
        PASSED+=("$t")
    else
        echo "FAIL $t (exit $status, ${elapsed}s)"
        FAILED+=("$t")
        $IN_GHA && echo "::group::output of $t"
        echo "----- begin output: $t -----"
        cat "$LOG"
        echo "----- end output: $t -----"
        $IN_GHA && echo "::endgroup::"
        $IN_GHA && echo "::error title=Test failed::$t exited $status"
    fi
done

$LIST_ONLY && exit 0

echo
echo "Summary: ${#PASSED[@]} passed, ${#FAILED[@]} failed, ${#SKIPPED[@]} skipped"
[[ ${#SKIPPED[@]} -eq 0 ]] && echo "  skipped: none"
for s in "${SKIPPED[@]}"; do echo "  skipped: $s"; done
for f in "${FAILED[@]}"; do echo "  FAILED:  $f"; done
[[ ${#FAILED[@]} -eq 0 ]] || exit 1
exit 0
