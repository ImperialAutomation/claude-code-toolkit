#!/bin/bash
# Tests for git-verify.sh's repository targeting.
#
# Usage:
#   bin/tests/test-git-verify.sh
#
# Scope: which tree the script reports on, not the formatting of every section.
# That is the part an agent gets wrong — a working directory resets between Bash
# calls, so a script reading "." silently reports on whichever tree the session
# started in. Everything runs against throwaway repos with real linked worktrees.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../git-verify.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

# Two worktrees of one repository, on different branches. Every case below runs
# from one and targets the other, so a script that ignores its argument reports
# the caller's branch and the assertion fails.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

MAIN="$T/billing-api"
DEV1="$T/billing-api-dev1"

git init -q -b main "$MAIN"
git -C "$MAIN" config user.email "dev@example.com"
git -C "$MAIN" config user.name "Test Developer"
git -C "$MAIN" commit -q --allow-empty -m "initial commit"
git -C "$MAIN" worktree add -q -b issue-77-invoice-rounding "$DEV1" >/dev/null 2>&1

run() { # cwd [args...]
    local cwd="$1"; shift
    (cd "$cwd" && bash "$SCRIPT" "$@" 2>&1)
}

# The reported branch is the cheapest unambiguous proof of which tree was read.
branch_of() { grep -A1 '^=== branch ===$' <<< "$1" | tail -1; }

echo "== 1. --repo targets the given worktree, not the caller's =="
check "--repo from the other tree" "issue-77-invoice-rounding" \
    "$(branch_of "$(run "$MAIN" --repo "$DEV1")")"
# The reverse direction too, so the case cannot pass by always reporting one branch.
check "--repo in the other direction" "main" \
    "$(branch_of "$(run "$DEV1" --repo "$MAIN")")"
check "--repo exits 0" "0" "$(run "$MAIN" --repo "$DEV1" >/dev/null 2>&1; echo $?)"

echo "== 2. the positional path keeps working (no regression) =="
check "positional from the other tree" "issue-77-invoice-rounding" \
    "$(branch_of "$(run "$MAIN" "$DEV1")")"
check "positional in the other direction" "main" \
    "$(branch_of "$(run "$DEV1" "$MAIN")")"
# Options after the positional path must still parse.
check "positional with --base" "issue-77-invoice-rounding" \
    "$(branch_of "$(run "$MAIN" "$DEV1" --base main)")"

echo "== 3. no argument reports the caller's own tree =="
check "bare run in main" "main" "$(branch_of "$(run "$MAIN")")"
check "bare run in linked tree" "issue-77-invoice-rounding" "$(branch_of "$(run "$DEV1")")"

echo "== 4. a bad target fails loudly, never falls back to the caller =="
check "nonexistent --repo exits non-zero" "1" \
    "$(run "$MAIN" --repo "$T/billing-api-dev9" >/dev/null 2>&1; echo $?)"
check "non-repo --repo exits non-zero" "1" \
    "$(run "$MAIN" --repo "$T" >/dev/null 2>&1; echo $?)"
# Falling back would print the caller's branch and exit 0 — the silent wrong-tree
# answer this flag exists to prevent.
check "bad --repo prints no branch" "yes" \
    "$(case "$(run "$MAIN" --repo "$T/billing-api-dev9")" in *"=== branch ==="*) echo no ;; *) echo yes ;; esac)"
check "--repo without a value exits non-zero" "1" \
    "$(run "$MAIN" --repo >/dev/null 2>&1; echo $?)"

echo "== 5. conflicting targets are refused rather than silently resolved =="
# Two paths meaning two different trees: picking either is a guess, and the loser
# is a tree the caller believed they were looking at.
check "--repo plus a different positional exits non-zero" "1" \
    "$(run "$MAIN" "$MAIN" --repo "$DEV1" >/dev/null 2>&1; echo $?)"
check "two positional paths exit non-zero" "1" \
    "$(run "$MAIN" "$MAIN" "$DEV1" >/dev/null 2>&1; echo $?)"
# The same tree named twice is not a conflict — nothing is ambiguous.
check "--repo matching the positional is fine" "0" \
    "$(run "$MAIN" "$DEV1" --repo "$DEV1" >/dev/null 2>&1; echo $?)"

echo "== 6. an unknown option is an error, not a target directory =="
# The original catch-all swallowed anything unrecognised into `repo`, so a typo
# became a silent target instead of a complaint.
check "unknown option exits non-zero" "1" \
    "$(run "$MAIN" --nope >/dev/null 2>&1; echo $?)"
check "unknown option names itself" "yes" \
    "$(case "$(run "$MAIN" --nope)" in *"unknown option"*) echo yes ;; *) echo no ;; esac)"
# A mistyped --repo must not degrade into "report on the caller's tree".
check "mistyped --repo does not report a branch" "yes" \
    "$(case "$(run "$MAIN" --rep "$DEV1")" in *"=== branch ==="*) echo no ;; *) echo yes ;; esac)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
