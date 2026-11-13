#!/usr/bin/env bash
# run-tests.sh — run every toolkit test script; the same set locally and in CI.
#
# Discovers bin/test-*.{sh,py} and bin/tests/test-*.{sh,py}, runs each one
# on its own (bash for .sh, python3 for .py) and reports per script. A script
# passes when it exits 0. The GitHub Actions workflow runs this with --ci, so
# "CI is green" and "run-tests.sh is green" mean the same set of scripts.
#
# Usage:
#   run-tests.sh [--ci] [--list] [--repo <dir>] [<test-script>...]
#
#   --ci     also apply CI_SKIP below: tests that need something a stock
#            runner lacks. Implied when $CI is "true" (GitHub Actions sets it).
#   --list   print the scripts that would run, and the skips, then exit 0.
#   --repo <dir>  run the tests of that tree instead of the tree this script
#            lives in. <dir> must be the top level of a checkout of this same
#            repository: the live checkout or one of its linked worktrees,
#            e.g. ~/.claude/bin/run-tests.sh --repo ../claude-code-toolkit-<N>
#   <test-script>  run only these (paths or basenames); default: all. An
#            absolute path into a linked worktree selects that tree, as
#            --repo would; it must not contradict --repo. A relative path
#            that exists from the current directory counts as that absolute
#            path.
#
# Each test runs with its tree's top level as working directory. The first
# output line names that tree.
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
#   2    usage error, a named script does not exist, a PREREQS tool is
#        missing, or --repo or a test path is not a checkout of this
#        repository

set -uo pipefail

# Physical path: through the ~/.claude/bin symlink this is the live checkout.
SELF_BIN_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF_REPO_DIR=$(dirname "$SELF_BIN_DIR")
# shellcheck source=bin/lib/live-checkout.sh
. "$SELF_BIN_DIR/lib/live-checkout.sh"

# An exported GIT_DIR or GIT_WORK_TREE would make every git call below
# describe that repository instead of the directory it is asked about.
unset GIT_DIR GIT_WORK_TREE

# Tests skipped under --ci, keyed by path relative to the repo, with the reason
# printed in the job log, e.g.
#   [bin/tests/test-foo.sh]="reads the real ~/.claude/settings.json"
# Add an entry only when making the test hermetic is not cheap; prefer fixing
# the test. Currently every test runs in CI: none is listed.
declare -A CI_SKIP=(
)

# Tools the tests as a set call directly (jq: hook tests; curl and python3:
# http-status; openssl: gh-app-token signs and verifies a real JWT). A missing
# one is a broken environment, not a reason to skip: the run stops before any
# test, naming the tool.
PREREQS=(git python3 jq curl openssl)

usage() {
    echo "usage: $(basename "$0") [--ci] [--list] [--repo <dir>] [<test-script>...]" >&2
    exit 2
}

CI_MODE=false
[[ "${CI:-}" == "true" ]] && CI_MODE=true
LIST_ONLY=false
REPO_ARG=""
SELECTED=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        --ci) CI_MODE=true ;;
        --list) LIST_ONLY=true ;;
        --repo)
            [[ $# -ge 2 && -n "$2" ]] || { echo "--repo needs a directory" >&2; usage; }
            [[ -z "$REPO_ARG" ]] || { echo "--repo given more than once" >&2; usage; }
            REPO_ARG="$2"; shift ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) SELECTED+=("$1") ;;
    esac
    shift
done

for tool in "${PREREQS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "required tool not on PATH: $tool" >&2; exit 2; }
done

# The physical top levels of the worktrees git has registered for the
# repository this script lives in (the main one and its linked ones), read
# once by load_self_trees. A directory merely pointing at this repository's
# .git is not registered, so it does not qualify.
SELF_TREES=()
SELF_TREES_LOADED=false
load_self_trees() {
    $SELF_TREES_LOADED && return 0
    local path rest
    while IFS=$'\t' read -r path rest; do
        path=$(realpath -e "$path" 2>/dev/null) && SELF_TREES+=("$path")
    done < <(worktree_list "$SELF_REPO_DIR")
    SELF_TREES_LOADED=true
    if [[ ${#SELF_TREES[@]} -eq 0 ]]; then
        echo "cannot determine the worktrees of $SELF_REPO_DIR" >&2
        exit 2
    fi
}

# The top level of the checkout holding <dir>, refused (exit 2) unless it is
# a registered worktree of the repository this script lives in. Only this
# repository's own trees run without a prompt, never an arbitrary
# toolkit-shaped directory. Call load_self_trees first.
checkout_of_self() {
    local dir="$1" what="$2" top t
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) \
        || { echo "$what is not inside a git checkout: $dir" >&2; exit 2; }
    top=$(realpath -e "$top")
    for t in "${SELF_TREES[@]}"; do
        [[ "$t" == "$top" ]] && { echo "$top"; return 0; }
    done
    echo "$what is not a checkout of $SELF_REPO_DIR or one of its worktrees: $dir" >&2
    exit 2
}

REPO_DIR="$SELF_REPO_DIR"
if [[ -n "$REPO_ARG" ]]; then
    load_self_trees
    [[ -d "$REPO_ARG" ]] || { echo "--repo is not a directory: $REPO_ARG" >&2; exit 2; }
    REPO_DIR=$(checkout_of_self "$REPO_ARG" "--repo") || exit 2
    if [[ "$REPO_DIR" != "$(realpath -e "$REPO_ARG")" ]]; then
        echo "--repo must be the top level of a checkout ($REPO_DIR), not $REPO_ARG" >&2
        exit 2
    fi
fi

# An absolute test path names its tree; every such path must agree with
# --repo, or, without --repo, with each other. A relative path that exists
# from the current directory is taken as its absolute path, so a run from
# inside a worktree does not silently pick the same name in this script's tree.
# A path into this script's own bin/ needs no git lookup, so a copy of the
# toolkit without .git still accepts it.
PATH_TREE=""
for i in "${!SELECTED[@]}"; do
    s="${SELECTED[i]}"
    if [[ "$s" != /* && "$s" == */* && -e "$s" ]]; then
        s=$(realpath -e "$s"); SELECTED[i]="$s"
    fi
    [[ "$s" == /* ]] || continue
    parent=$(dirname "$s")
    [[ -d "$parent" ]] || { echo "no such test script: $s" >&2; exit 2; }
    if [[ "$(realpath -m "$s")" == "$SELF_BIN_DIR"/* ]]; then
        tree="$SELF_REPO_DIR"
    else
        load_self_trees
        tree=$(checkout_of_self "$parent" "test path") || exit 2
    fi
    if [[ -n "$REPO_ARG" && "$tree" != "$REPO_DIR" ]]; then
        echo "test path is not in --repo $REPO_DIR: $s" >&2; exit 2
    fi
    if [[ -n "$PATH_TREE" && "$tree" != "$PATH_TREE" ]]; then
        echo "test paths name two trees: $PATH_TREE and $tree" >&2; exit 2
    fi
    PATH_TREE="$tree"
done
[[ -n "$PATH_TREE" ]] && REPO_DIR="$PATH_TREE"
BIN_DIR="$REPO_DIR/bin"

# All test scripts, as paths relative to the repo, in a stable order.
discover() {
    local f
    for f in "$BIN_DIR"/test-*.sh "$BIN_DIR"/test-*.py "$BIN_DIR"/tests/test-*.sh "$BIN_DIR"/tests/test-*.py; do
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

echo "Tree: $REPO_DIR"
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
