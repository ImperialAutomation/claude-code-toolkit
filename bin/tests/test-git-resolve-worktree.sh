#!/bin/bash
# Tests for git-resolve-worktree.sh.
#
# Usage:
#   bin/tests/test-git-resolve-worktree.sh
#
# Runs against a throwaway repository with REAL linked worktrees. The thing
# under test is how the script reads `git worktree list` and narrows it down, so
# stubbing git would test the stub. Every case below builds its own trees and
# removes them on exit.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../git-resolve-worktree.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

# --- a real repository with real linked worktrees ----------------------------
# Layout mirrors how these are used in practice: a main tree on `main`, plus two
# sibling trees named after the developer slot, each checked out on an issue
# branch following the `issue-<nr>-<slug>` convention.
#
#   <T>/billing-api        main
#   <T>/billing-api-dev1   issue-77-invoice-rounding
#   <T>/billing-api-dev2   issue-108-vat-export
#
# Issue numbers 77 and 108 are deliberate: 7 is a prefix of 77, and 10 a prefix
# of 108, so a resolver matching without the trailing dash picks the wrong tree.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

MAIN="$T/billing-api"
DEV1="$T/billing-api-dev1"
DEV2="$T/billing-api-dev2"

git init -q -b main "$MAIN"
git -C "$MAIN" config user.email "dev@example.com"
git -C "$MAIN" config user.name "Test Developer"
git -C "$MAIN" commit -q --allow-empty -m "initial commit"

git -C "$MAIN" worktree add -q -b issue-77-invoice-rounding "$DEV1" >/dev/null 2>&1
git -C "$MAIN" worktree add -q -b issue-108-vat-export "$DEV2" >/dev/null 2>&1

# An unrelated repository, to prove a path outside this repo is refused rather
# than accepted just because it happens to be a valid git worktree somewhere.
OTHER="$T/unrelated-project"
git init -q -b main "$OTHER"
git -C "$OTHER" config user.email "dev@example.com"
git -C "$OTHER" config user.name "Test Developer"
git -C "$OTHER" commit -q --allow-empty -m "initial commit"

# Run from a given directory: the script's default is "where I am", so the
# working directory is an input, not incidental setup.
run() { # cwd [args...]
    local cwd="$1"; shift
    (cd "$cwd" && bash "$SCRIPT" "$@")
}

echo "== 1. no argument resolves to the worktree the caller is in =="
check "from the main tree" "$MAIN" "$(run "$MAIN")"
check "from a linked tree" "$DEV1" "$(run "$DEV1")"
check "exit 0 without argument" "0" "$(run "$MAIN" >/dev/null 2>&1; echo $?)"
# A subdirectory must resolve to the tree ROOT — the path is handed to
# `git -C` and to absolute Read/Edit paths, so the root is the only useful answer.
mkdir -p "$DEV1/src/billing"
check "from a subdirectory" "$DEV1" "$(run "$DEV1/src/billing")"
# Outside any repository there is nothing to resolve, and guessing would be the
# exact silent fallback this script exists to prevent.
check "outside a repository exits non-zero" "1" "$(run "$T" >/dev/null 2>&1; echo $?)"

echo "== 2. --issue picks the worktree whose branch is issue-<nr>-<slug> =="
check "matches its own tree" "$DEV1" "$(run "$MAIN" --issue 77)"
check "matches the other tree" "$DEV2" "$(run "$MAIN" --issue 108)"
check "--issue=N spelling" "$DEV2" "$(run "$MAIN" --issue=108)"
# The pattern must end at the dash. Without it `7` matches `issue-77-*` and the
# work lands one tree over, which is precisely the silent failure this prevents.
check "7 does not match issue-77" "1" "$(run "$MAIN" --issue 7 >/dev/null 2>&1; echo $?)"
check "10 does not match issue-108" "1" "$(run "$MAIN" --issue 10 >/dev/null 2>&1; echo $?)"
check "unknown issue exits non-zero" "1" "$(run "$MAIN" --issue 999 >/dev/null 2>&1; echo $?)"
# Resolving from inside a linked tree must still obey --issue, otherwise an
# agent already sitting in dev1 would silently keep working there.
check "--issue wins over the caller's tree" "$DEV2" "$(run "$DEV1" --issue 108)"
check "--issue without a value exits 2" "2" "$(run "$MAIN" --issue >/dev/null 2>&1; echo $?)"

echo "== 3. a hint is a case-insensitive substring of a worktree path =="
check "unique substring" "$DEV1" "$(run "$MAIN" dev1)"
check "uppercase hint" "$DEV2" "$(run "$MAIN" DEV2)"
check "mixed case hint" "$DEV1" "$(run "$MAIN" Dev1)"
check "hint exit 0" "0" "$(run "$MAIN" dev1 >/dev/null 2>&1; echo $?)"
check "no such hint exits non-zero" "1" "$(run "$MAIN" nope >/dev/null 2>&1; echo $?)"
# An absolute path is the escape hatch when no short hint is unique, but it is
# validated rather than trusted: a typo must fail loudly, not point somewhere.
check "absolute path passes through" "$DEV2" "$(run "$MAIN" "$DEV2")"
check "trailing slash tolerated" "$DEV2" "$(run "$MAIN" "$DEV2/")"
check "subdirectory of a worktree resolves to its root" "$DEV1" "$(run "$MAIN" "$DEV1/src/billing")"
# A worktree of a DIFFERENT repository is a valid worktree, just not one of
# ours. Accepting it would commit this session's work into an unrelated project.
check "another repo's worktree is refused" "1" "$(run "$MAIN" "$OTHER" >/dev/null 2>&1; echo $?)"
check "nonexistent absolute path exits non-zero" "1" \
    "$(run "$MAIN" "$T/billing-api-dev9" >/dev/null 2>&1; echo $?)"
# An explicit hint decides; --issue is only the fallback for when none was given.
check "hint wins over --issue" "$DEV1" "$(run "$MAIN" --issue 108 dev1)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
