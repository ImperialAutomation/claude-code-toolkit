#!/bin/bash
# Regression tests for git-find-base-branch.
#
# Covers the three scenarios from issue #17:
#   1. On develop itself (master is an ancestor)      -> expect develop
#   2. On a feature branch cut from develop            -> expect develop
#   3. Repo with only master (no develop)               -> expect master
#
# Each scenario builds a throwaway repo under a temp dir so it never touches
# the real toolkit repo's branches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/git-find-base-branch"

pass=0
fail=0

run_case() {
    local name="$1"
    local expected="$2"
    local repo="$3"

    actual=$(cd "$repo" && "$TARGET")
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $name (got '$actual')"
        pass=$((pass + 1))
    else
        echo "FAIL: $name (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

make_repo() {
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    echo "$dir"
}

# Scenario 1: on develop, master is an ancestor of develop.
repo1=$(make_repo)
git -C "$repo1" checkout -q -b master
git -C "$repo1" commit -q --allow-empty -m "master root"
git -C "$repo1" checkout -q -b develop
git -C "$repo1" commit -q --allow-empty -m "develop ahead"
run_case "on develop (master ancestor)" "develop" "$repo1"
rm -rf "$repo1"

# Scenario 2: on a feature branch cut from develop.
repo2=$(make_repo)
git -C "$repo2" checkout -q -b master
git -C "$repo2" commit -q --allow-empty -m "master root"
git -C "$repo2" checkout -q -b develop
git -C "$repo2" commit -q --allow-empty -m "develop ahead"
git -C "$repo2" checkout -q -b issue-1-feature
git -C "$repo2" commit -q --allow-empty -m "feature work"
run_case "on feature branch cut from develop" "develop" "$repo2"
rm -rf "$repo2"

# Scenario 3: repo with only master (no develop).
repo3=$(make_repo)
git -C "$repo3" checkout -q -b master
git -C "$repo3" commit -q --allow-empty -m "master root"
git -C "$repo3" checkout -q -b issue-2-feature
git -C "$repo3" commit -q --allow-empty -m "feature work"
run_case "repo without develop" "master" "$repo3"
rm -rf "$repo3"

# Scenario 4: an explicit repo argument reports THAT tree's base branch.
#
# Run from a linked worktree whose own answer differs from the target's, so the
# case fails if the argument is ignored and the caller's directory wins. That is
# the real bug: an agent working in a linked worktree would otherwise get the
# base branch of whichever tree the session happened to start in.
repo4=$(make_repo)
git -C "$repo4" checkout -q -b master
git -C "$repo4" commit -q --allow-empty -m "master root"
git -C "$repo4" checkout -q -b develop
git -C "$repo4" commit -q --allow-empty -m "develop ahead"
wt4="${repo4}-dev1"
git -C "$repo4" worktree add -q -b issue-42-invoice-rounding "$wt4" master >/dev/null 2>&1

# From the linked tree (base master), ask about the main tree (on develop).
actual=$(cd "$wt4" && "$TARGET" "$repo4")
if [ "$actual" = "develop" ]; then
    echo "PASS: repo argument targets the given worktree (got '$actual')"
    pass=$((pass + 1))
else
    echo "FAIL: repo argument targets the given worktree (expected 'develop', got '$actual')"
    fail=$((fail + 1))
fi

# And the reverse, so the case cannot pass by always reporting develop.
actual=$(cd "$repo4" && "$TARGET" "$wt4")
if [ "$actual" = "master" ]; then
    echo "PASS: repo argument works in the other direction (got '$actual')"
    pass=$((pass + 1))
else
    echo "FAIL: repo argument works in the other direction (expected 'master', got '$actual')"
    fail=$((fail + 1))
fi

# A bad path must fail loudly. Falling back to the caller's directory here would
# turn a typo into a confidently wrong answer.
if (cd "$repo4" && "$TARGET" "${repo4}-nonexistent" >/dev/null 2>&1); then
    echo "FAIL: nonexistent repo argument exits non-zero"
    fail=$((fail + 1))
else
    echo "PASS: nonexistent repo argument exits non-zero"
    pass=$((pass + 1))
fi

# --repo is the named spelling of the same argument, matching the other
# worktree-targeting scripts (git-commit.sh, git-diff-base.sh, …). An agent
# reading a command should see which tree it acts on without knowing each
# script's argument order.
actual=$(cd "$wt4" && "$TARGET" --repo "$repo4")
if [ "$actual" = "develop" ]; then
    echo "PASS: --repo targets the given worktree (got '$actual')"
    pass=$((pass + 1))
else
    echo "FAIL: --repo targets the given worktree (expected 'develop', got '$actual')"
    fail=$((fail + 1))
fi

actual=$(cd "$repo4" && "$TARGET" --repo "$wt4")
if [ "$actual" = "master" ]; then
    echo "PASS: --repo works in the other direction (got '$actual')"
    pass=$((pass + 1))
else
    echo "FAIL: --repo works in the other direction (expected 'master', got '$actual')"
    fail=$((fail + 1))
fi

if (cd "$repo4" && "$TARGET" --repo "${repo4}-nonexistent" >/dev/null 2>&1); then
    echo "FAIL: nonexistent --repo exits non-zero"
    fail=$((fail + 1))
else
    echo "PASS: nonexistent --repo exits non-zero"
    pass=$((pass + 1))
fi

if (cd "$repo4" && "$TARGET" --repo >/dev/null 2>&1); then
    echo "FAIL: --repo without a value exits non-zero"
    fail=$((fail + 1))
else
    echo "PASS: --repo without a value exits non-zero"
    pass=$((pass + 1))
fi

# Two different trees named at once is a conflict, not a pick: the loser is a
# tree the caller believed they were asking about.
if (cd "$repo4" && "$TARGET" "$wt4" --repo "$repo4" >/dev/null 2>&1); then
    echo "FAIL: conflicting targets exit non-zero"
    fail=$((fail + 1))
else
    echo "PASS: conflicting targets exit non-zero"
    pass=$((pass + 1))
fi

# An unknown option must be REJECTED as an option, not swallowed as the target
# directory. Asserting only on the exit code is not enough: a fall-through makes
# `cd --nope` fail too, so the case would pass while the bug is present. The
# message is what distinguishes the two.
err=$(cd "$repo4" && "$TARGET" --nope 2>&1 >/dev/null) || true
case "$err" in
    *"unknown option"*)
        echo "PASS: unknown option rejected as an option"
        pass=$((pass + 1))
        ;;
    *)
        echo "FAIL: unknown option rejected as an option (got '$err')"
        fail=$((fail + 1))
        ;;
esac

git -C "$repo4" worktree remove --force "$wt4" >/dev/null 2>&1
rm -rf "$repo4" "$wt4"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
