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

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
