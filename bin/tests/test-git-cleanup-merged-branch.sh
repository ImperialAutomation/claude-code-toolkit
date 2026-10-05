#!/bin/bash
# Tests for git-cleanup-merged-branch.sh — focused on step 3, which brings the
# base branch up to date before the merged-ness check in step 4.
#
# Usage:
#   bin/tests/test-git-cleanup-merged-branch.sh
#
# Exercises the script against throwaway git repos in a temp dir. Nothing
# outside that temp dir is touched. Exits non-zero if any expectation fails.
#
# Step 3 used to run `pull origin "$BASE_BRANCH"`, which assumes the base branch
# has a same-named branch on origin. The cases here pin the three ways that
# assumption breaks — a differently named upstream (1), a non-origin remote (5),
# and no upstream at all (3) — plus the same-named case (2) that must keep
# working, and the diverged base (4) that must be refused rather than merged.
#
# Scenario index:
#   1. base is a parking branch tracking origin/develop  -> cleans up
#   2. base is develop tracking origin/develop           -> cleans up, advances
#   3. base has no upstream                              -> actionable refusal
#   4. base diverged from its upstream                   -> refuses, no merge
#   5. base tracks a second remote (not origin)          -> fetches that remote
#
# Cases 3 and 4 assert the feature branch SURVIVES. A cleanup that fails after
# deleting the branch is worse than one that never ran, and exit-status-only
# assertions cannot tell those apart.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../git-cleanup-merged-branch.sh}"

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

contains() { # name needle haystack
    if [[ "$3" == *"$2"* ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 ('$2' not found in: $3)"; FAIL=$((FAIL+1)); fi
}

lacks() { # name needle haystack
    if [[ "$3" != *"$2"* ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 ('$2' unexpectedly found in: $3)"; FAIL=$((FAIL+1)); fi
}

git_q() { git -C "$1" "${@:2}"; }

# A bare remote plus a clone, both seeded with one commit on $2.
#
# The remote is bare and local-path: the script pushes nothing here, but step 2
# fetches, and a non-bare remote would refuse a push if a later case needed one.
newremote() { # name branch
    local d="$T/$1"
    git init -q --bare -b "$2" "$d.git"
    git init -q -b "$2" "$d"
    git -C "$d" config user.email dev@example.com
    git -C "$d" config user.name "Dana Vermeer"
    git -C "$d" remote add origin "$d.git"
    printf 'cleanup fixture\n' > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -qm "Add README"
    git -C "$d" push -q -u origin "$2"
    echo "$d"
}

# Add a commit to the remote's $2 branch, without touching the clone at $1.
# Uses a scratch clone so the fixture repo's worktree and index stay clean.
advance_remote() { # repodir branch subject
    local d="$1" branch="$2" subject="$3"
    local s="$d-pusher-$RANDOM"
    git clone -q "$d.git" "$s"
    git -C "$s" config user.email ops@example.com
    git -C "$s" config user.name "Ravi Chandrasekaran"
    git -C "$s" checkout -q "$branch"
    printf '%s\n' "$subject" > "$s/CHANGELOG-$RANDOM.md"
    git -C "$s" add -A
    git -C "$s" commit -qm "$subject"
    git -C "$s" push -q origin "$branch"
    rm -rf "$s"
}

# The post-merge state cleanup actually runs in: the PR was merged on the
# forge, so the merge commit exists on the REMOTE and the local base is strictly
# behind it. The feature branch still points at its own last commit.
#
# Merging into the local base instead (the obvious shortcut) would leave the
# base ahead of its upstream, so a later remote commit makes the two diverge --
# and then --ff-only refuses, which is correct behaviour for a state that never
# occurs after a real merge. Pushing the merge and resetting the local base back
# reproduces the real thing: a fast-forward is possible, and step 4's --merged
# check only succeeds once step 3 has actually performed it.
add_merged_feature() { # repodir base feature upstream_branch
    local d="$1" base="$2" feat="$3" up="${4:-$2}"
    local remote tip
    remote=$(git -C "$d" config "branch.$base.remote")
    tip=$(git -C "$d" rev-parse "$base")

    git -C "$d" checkout -q "$base"
    git -C "$d" checkout -q -b "$feat"
    printf 'feature work\n' > "$d/feature-$feat.md"
    git -C "$d" add -A
    git -C "$d" commit -qm "Add $feat notes"

    # Merge on a throwaway local branch, publish it, then drop it: the merge
    # must reach the remote without the local base ever pointing at it.
    git -C "$d" checkout -q -b "$feat-merge" "$base"
    git -C "$d" merge -q --no-ff -m "Merge $feat" "$feat"
    git -C "$d" push -q "$remote" "$feat-merge:$up"
    git -C "$d" checkout -q "$base"
    git -C "$d" branch -q -D "$feat-merge"
    git -C "$d" reset -q --hard "$tip"
    git -C "$d" fetch -q "$remote"
}

branch_exists() { # repodir branch
    if git -C "$1" show-ref --verify --quiet "refs/heads/$2"; then echo yes; else echo no; fi
}

# Answers every interactive prompt with "n". Only the remote-branch deletion
# prompt can be reached in these cases (the feature branch is fully merged and
# the worktree is clean), and there is no remote feature branch to delete, so
# this is belt-and-braces against a hang if a case regresses.
run() { # repodir [args...]
    printf 'n\nn\nn\n' | bash "$SCRIPT" --repo "$@" 2>&1
}

echo "== 1. base is a parking branch tracking origin/develop =="
# The reported bug. A linked worktree cannot check out `develop` (the main tree
# holds it), so it parks on a branch with its own name tracking origin/develop.
# `pull origin park-develop` then dies on "couldn't find remote ref".
R=$(newremote r1 develop)
git_q "$R" branch -q park-develop develop
git_q "$R" branch -q -u origin/develop park-develop
# The merge landed on origin/develop, which park-develop tracks under its own name.
add_merged_feature "$R" park-develop issue-1-widget develop
OUT=$(run "$R" issue-1-widget park-develop); RC=$?
check "exit zero" 0 "$RC"
check "feature branch deleted" no "$(branch_exists "$R" issue-1-widget)"
# The old failure mode, pinned by its exact message: a passing exit status alone
# would not distinguish "fixed" from "fetch happened to be enough".
lacks "no 'couldn't find remote ref'" "couldn't find remote ref" "$OUT"
# The base must actually carry the upstream commit, not merely survive the run.
check "base has upstream commit" yes \
    "$(git_q "$R" merge-base --is-ancestor origin/develop park-develop && echo yes || echo no)"

echo "== 2. same-named base: develop tracking origin/develop =="
R=$(newremote r2 develop)
add_merged_feature "$R" develop issue-2-invoice
advance_remote "$R" develop "Upstream hotfix landed after the merge"
OUT=$(run "$R" issue-2-invoice develop); RC=$?
check "exit zero" 0 "$RC"
check "feature branch deleted" no "$(branch_exists "$R" issue-2-invoice)"
# Advancing is the point of step 3. Asserting the tip equals the fetched
# upstream catches a "fix" that resolves the upstream but forgets to merge it.
check "base fast-forwarded to upstream" \
    "$(git_q "$R" rev-parse origin/develop)" "$(git_q "$R" rev-parse develop)"

echo "== 3. base has no upstream -> actionable refusal =="
R=$(newremote r3 develop)
add_merged_feature "$R" develop issue-3-report
git_q "$R" branch -q --unset-upstream develop
OUT=$(run "$R" issue-3-report develop); RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
contains "names the branch" "'develop' has no upstream" "$OUT"
contains "suggests the remedy" "git branch -u" "$OUT"
# A refusal must not have already done the destructive half.
check "feature branch survives" yes "$(branch_exists "$R" issue-3-report)"

echo "== 4. base diverged from upstream -> refuses, creates no merge =="
R=$(newremote r4 develop)
add_merged_feature "$R" develop issue-4-export
advance_remote "$R" develop "Upstream change"
# Local-only commit on the base, so neither side is an ancestor of the other.
git_q "$R" checkout -q develop
printf 'local only\n' > "$R/local-note.md"
git_q "$R" add -A
git_q "$R" commit -qm "Local-only base commit"
BEFORE=$(git_q "$R" rev-parse develop)
OUT=$(run "$R" issue-4-export develop); RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
# The content assertion AC 4 actually asks for: no merge commit was fabricated.
check "base tip unchanged" "$BEFORE" "$(git_q "$R" rev-parse develop)"
check "no merge left in progress" no \
    "$([[ -f "$R/.git/MERGE_HEAD" ]] && echo yes || echo no)"
check "feature branch survives" yes "$(branch_exists "$R" issue-4-export)"

echo "== 5. base tracks a second remote, not origin =="
# Step 2 fetches a hardcoded 'origin'. When the upstream lives on another
# remote, that leaves the upstream ref stale and a fast-forward would land on an
# old commit — green, and quietly wrong. The fetch must follow the upstream.
R=$(newremote r5 develop)
git init -q --bare -b develop "$R-fork.git"
git_q "$R" remote add fork "$R-fork.git"
git_q "$R" push -q fork develop
git_q "$R" fetch -q fork
git_q "$R" branch -q -u fork/develop develop
# Runs after the retarget, so the merge is published to the fork (the upstream),
# not to origin.
add_merged_feature "$R" develop issue-5-audit
# Only the fork advances; origin stays where it was.
git clone -q "$R-fork.git" "$R-forkpush"
git_q "$R-forkpush" config user.email ops@example.com
git_q "$R-forkpush" config user.name "Ravi Chandrasekaran"
printf 'fork side\n' > "$R-forkpush/FORK.md"
git_q "$R-forkpush" add -A
git_q "$R-forkpush" commit -qm "Fork-side commit"
git_q "$R-forkpush" push -q origin develop
FORK_TIP=$(git_q "$R-forkpush" rev-parse HEAD)
rm -rf "$R-forkpush"
OUT=$(run "$R" issue-5-audit develop); RC=$?
check "exit zero" 0 "$RC"
check "feature branch deleted" no "$(branch_exists "$R" issue-5-audit)"
check "base advanced to fork tip" "$FORK_TIP" "$(git_q "$R" rev-parse develop)"

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
