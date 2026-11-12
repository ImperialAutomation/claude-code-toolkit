#!/bin/bash
# Tests for bin/lib/protected-branches.sh, the one parser of a repository's
# protected-branch list (#312, D8).
#
# Usage:
#   bin/tests/test-protected-branches.sh
#
# Covers both ways in: sourced (protected_branch_list, is_protected_branch) and
# run as a command (the form hook-side Python calls). The per-repo semantics are
# the ones git-commit.sh always had: the committed file wins, git config is the
# fallback, and the two are never merged.

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$REPO_DIR/bin/lib/protected-branches.sh"

# shellcheck source=bin/lib/protected-branches.sh
. "$LIB"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

check_rc() { # name expected-rc command...
    local name="$1" want="$2" rc=0
    shift 2
    "$@" >/dev/null 2>&1 || rc=$?
    check "$name" "$want" "$rc"
}

new_repo() { # dir
    mkdir -p "$1"
    git -C "$1" init -q
}

echo "== no per-repo source =="
R="$T/plain"; new_repo "$R"
check "list is empty" "" "$(protected_branch_list "$R")"
check_rc "main is protected (fixed list)" 0 is_protected_branch "$R" main
check_rc "master is protected (fixed list)" 0 is_protected_branch "$R" master
check_rc "develop is protected (fixed list)" 0 is_protected_branch "$R" develop
check_rc "a feature branch is not" 1 is_protected_branch "$R" issue-1-x
check_rc "names match exactly, not by prefix" 1 is_protected_branch "$R" main2

echo "== git config =="
R="$T/config"; new_repo "$R"
git -C "$R" config --add toolkit.protectedBranch release
git -C "$R" config --add toolkit.protectedBranch production
check "list reads every value" $'release\nproduction' "$(protected_branch_list "$R")"
check_rc "a configured branch is protected" 0 is_protected_branch "$R" production
check_rc "the fixed list still applies" 0 is_protected_branch "$R" main

echo "== committed file wins over git config =="
R="$T/file"; new_repo "$R"
git -C "$R" config --add toolkit.protectedBranch from-config
mkdir -p "$R/.claude"
printf '# comment\n\n  stable  \nlive # trailing comment\n' > "$R/.claude/protected-branches"
check "file lines, comments and blanks dropped, trimmed" $'stable\nlive' "$(protected_branch_list "$R")"
check_rc "git config is not merged in" 1 is_protected_branch "$R" from-config
check_rc "a file entry is protected" 0 is_protected_branch "$R" live

echo "== from a subdirectory and a linked worktree =="
mkdir -p "$R/sub/dir"
check "subdirectory reads the repo root's file" $'stable\nlive' "$(protected_branch_list "$R/sub/dir")"
git -C "$R" add .claude/protected-branches
git -C "$R" -c user.name=t -c user.email=t@t commit -qm init
git -C "$R" worktree add -q "$T/file-wt" -b wt
check "a linked worktree reads its own checkout of the file" $'stable\nlive' "$(protected_branch_list "$T/file-wt")"

echo "== outside a repository =="
mkdir -p "$T/none"
check "list is empty" "" "$(protected_branch_list "$T/none")"
check_rc "the fixed list still applies" 0 is_protected_branch "$T/none" main

echo "== as a command =="
R="$T/config"
check "prints fixed list plus per-repo list" $'develop\nmaster\nmain\nrelease\nproduction' "$(bash "$LIB" "$R")"
check "--repo-only prints only the per-repo list" $'release\nproduction' "$(bash "$LIB" --repo-only "$R")"
check_rc "no directory is a usage error" 2 bash "$LIB"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
