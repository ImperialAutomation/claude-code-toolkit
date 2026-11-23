#!/bin/bash
# Tests for bin/lib/git-env.sh.
#
# Usage:
#   bin/tests/test-git-env.sh
#
# Exports every variable git_env_isolate must clear, calls it in a subshell and
# checks the environment a child process then sees.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="${LIB_UNDER_TEST:-$SCRIPT_DIR/../lib/git-env.sh}"

if [[ ! -f "$LIB" ]]; then
    echo "library not found: $LIB" >&2
    exit 1
fi

PASS=0; FAIL=0
check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

# The variables named by git itself, plus the two discovery controls.
mapfile -t LOCAL_VARS < <(git rev-parse --local-env-vars)
EXPECTED=("${LOCAL_VARS[@]}" GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM)

# Export each with a marker value; print the ones a child still sees.
leftover() { # [PATH override]
    local v assigns=()
    for v in "${EXPECTED[@]}"; do assigns+=("$v=/redirected"); done
    # Builtins only in the child: with PATH overridden, no external tool runs.
    # shellcheck disable=SC2016 # expanded by the child, not here
    env "${assigns[@]}" ${1:+"PATH=$1"} "$BASH" -c '
        . "$1"; shift
        git_env_isolate; echo "status $?"
        for v in "$@"; do [[ -n "${!v+set}" ]] && echo "$v"; done
        true' _ "$LIB" "${EXPECTED[@]}"
}

echo "== git_env_isolate =="
check "git names GIT_COMMON_DIR as repository-local" "yes" \
    "$(printf '%s\n' "${LOCAL_VARS[@]}" | grep -qx GIT_COMMON_DIR && echo yes || echo no)"
OUT=$(leftover)
check "succeeds" "status 0" "$(head -1 <<<"$OUT")"
check "no redirecting variable survives" "" "$(tail -n +2 <<<"$OUT")"

# Without git on PATH it fails and leaves the environment as it was.
EMPTY=$(mktemp -d); trap 'rm -rf "$EMPTY"' EXIT
OUT=$(leftover "$EMPTY")
check "fails without git" "status 1" "$(head -1 <<<"$OUT")"
check "changes nothing without git" "${#EXPECTED[@]}" "$(tail -n +2 <<<"$OUT" | grep -c .)"

# The caller's IFS does not change which names are cleared.
# shellcheck disable=SC2016 # expanded by the child, not here
OUT=$(env GIT_COMMON_DIR=/redirected "$BASH" -c '
    . "$1"; IFS=:
    git_env_isolate; echo "status $? ${GIT_COMMON_DIR-unset}"' _ "$LIB")
check "clears under a caller IFS without newline" "status 0 unset" "$OUT"

# A readonly variable fails it before anything is unset.
# shellcheck disable=SC2016 # expanded by the child, not here
OUT=$(env GIT_COMMON_DIR=/redirected GIT_DIR=/redirected "$BASH" -c '
    . "$1"; readonly GIT_DIR
    git_env_isolate; echo "status $? ${GIT_COMMON_DIR-unset}"' _ "$LIB")
check "a readonly variable fails and changes nothing" "status 1 /redirected" "$OUT"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
