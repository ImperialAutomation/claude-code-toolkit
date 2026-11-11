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
#   6-9.  --help, unknown options, conflicting flags     -> answered without git
#   10-14. stdin is not a terminal                       -> no prompt, safe default
#   15.   --repo after the positional arguments          -> still honoured
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

# --- Argument parsing (#207) -------------------------------------------------
#
# A stub `git` on PATH records every call. Parsing errors and --help must be
# answered before the script touches any repository, so the log stays empty.
STUB="$T/stub-bin"
mkdir -p "$STUB"
GIT_LOG="$T/git-calls.log"
printf '#!/bin/bash\necho "$*" >> "%s"\nexit 0\n' "$GIT_LOG" > "$STUB/git"
chmod +x "$STUB/git"

run_stubbed() { # args...  -> output in $OUT, status in $RC
    : > "$GIT_LOG"
    OUT=$(env -C "$T" PATH="$STUB:$PATH" bash "$SCRIPT" "$@" </dev/null 2>&1); RC=$?
}

for flag in --help -h; do
    echo "== 6. $flag prints usage and runs no git =="
    run_stubbed "$flag"
    check "$flag exits 0" 0 "$RC"
    contains "$flag prints usage" "Usage" "$OUT"
    lacks "$flag is not a branch name" "Feature branch:" "$OUT"
    check "$flag runs no git" 0 "$(wc -l < "$GIT_LOG" | tr -d ' ')"
done

echo "== 7. --help wins even after other arguments =="
run_stubbed --repo "$T" some-branch --help
check "exits 0" 0 "$RC"
check "runs no git" 0 "$(wc -l < "$GIT_LOG" | tr -d ' ')"

echo "== 8. unknown option exits 2 with no git =="
run_stubbed --foo
check "exits 2" 2 "$RC"
contains "names the option" "--foo" "$OUT"
check "runs no git" 0 "$(wc -l < "$GIT_LOG" | tr -d ' ')"

echo "== 9. --delete-remote with --keep-remote exits 2 with no git =="
run_stubbed --delete-remote --keep-remote
check "exits 2" 2 "$RC"
check "runs no git" 0 "$(wc -l < "$GIT_LOG" | tr -d ' ')"

# --- No terminal (#207) --------------------------------------------------------
#
# stdin is /dev/null, as in an agent session. No prompt may be read: each one
# takes its safe default and says what to run instead.
#
# bash's `read -p` prints its prompt only on a terminal, so "no prompt text in
# the output" cannot tell "did not prompt" from "prompted silently". Cases that
# must prove no answer was read therefore use run_notty_yes: a pipe full of "y"
# that the old script would have taken as consent.
run_notty() { # repodir [args...]
    bash "$SCRIPT" --repo "$@" </dev/null 2>&1
}

run_notty_yes() { # repodir [args...]
    printf 'y\ny\ny\ny\n' | bash "$SCRIPT" --repo "$@" 2>&1
}

remote_branch_exists() { # repodir branch
    if git -C "$1" ls-remote --exit-code --heads origin "$2" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# A merged feature whose branch is also published, as after a forge merge.
merged_with_remote() { # name feature
    local d
    d=$(newremote "$1" develop)
    add_merged_feature "$d" develop "$2" >/dev/null
    git -C "$d" push -q origin "$2"
    echo "$d"
}

echo "== 10. no TTY, no flag: remote kept, delete command printed, exit 0 =="
R=$(merged_with_remote r10 issue-10-notify)
OUT=$(run_notty "$R" issue-10-notify develop); RC=$?
check "exit zero" 0 "$RC"
check "local branch deleted" no "$(branch_exists "$R" issue-10-notify)"
check "remote branch kept" yes "$(remote_branch_exists "$R" issue-10-notify)"
contains "prints delete command" "git push origin --delete issue-10-notify" "$OUT"

echo "== 11. no TTY, --delete-remote: remote deleted =="
R=$(merged_with_remote r11 issue-11-billing)
OUT=$(run_notty "$R" --delete-remote issue-11-billing develop); RC=$?
check "exit zero" 0 "$RC"
check "local branch deleted" no "$(branch_exists "$R" issue-11-billing)"
check "remote branch deleted" no "$(remote_branch_exists "$R" issue-11-billing)"

echo "== 12. no TTY, --keep-remote: remote kept, no prompt =="
R=$(merged_with_remote r12 issue-12-search)
OUT=$(run_notty "$R" issue-12-search develop --keep-remote); RC=$?
check "exit zero" 0 "$RC"
check "remote branch kept" yes "$(remote_branch_exists "$R" issue-12-search)"
lacks "no delete hint either" "git push origin --delete" "$OUT"

echo "== 12b. piped 'y' without --delete-remote does not delete the remote =="
R=$(merged_with_remote r12b issue-12b-search)
OUT=$(run_notty_yes "$R" issue-12b-search develop); RC=$?
check "exit zero" 0 "$RC"
check "remote branch kept" yes "$(remote_branch_exists "$R" issue-12b-search)"
R=$(merged_with_remote r12c issue-12c-search)
OUT=$(run_notty_yes "$R" --keep-remote issue-12c-search develop); RC=$?
check "--keep-remote with piped 'y' keeps it" yes "$(remote_branch_exists "$R" issue-12c-search)"

echo "== 13. no TTY, uncommitted changes: stops before checkout =="
R=$(newremote r13 develop)
add_merged_feature "$R" develop issue-13-upload
git_q "$R" checkout -q issue-13-upload
printf 'unsaved edit\n' >> "$R/README.md"
OUT=$(run_notty_yes "$R" issue-13-upload develop); RC=$?
check "exit one" 1 "$RC"
check "still on feature branch" issue-13-upload "$(git_q "$R" branch --show-current)"
check "feature branch survives" yes "$(branch_exists "$R" issue-13-upload)"
contains "names the missing terminal" "no terminal" "$OUT"

echo "== 14. no TTY, force-delete path: branch kept, command printed =="
# The content landed on the remote base as a cherry-pick, so the feature tip is
# not an ancestor of the base but the trees are identical.
R=$(newremote r14 develop)
TIP=$(git_q "$R" rev-parse develop)
git_q "$R" checkout -q -b issue-14-sync
printf 'sync work\n' > "$R/sync.md"
git_q "$R" add -A
git_q "$R" commit -qm "Add sync notes"
git_q "$R" checkout -q -b pick develop
git_q "$R" cherry-pick -x issue-14-sync >/dev/null
git_q "$R" push -q origin pick:develop
git_q "$R" checkout -q develop
git_q "$R" branch -q -D pick
git_q "$R" reset -q --hard "$TIP"
OUT=$(run_notty_yes "$R" issue-14-sync develop); RC=$?
check "exit one" 1 "$RC"
check "feature branch survives" yes "$(branch_exists "$R" issue-14-sync)"
contains "prints force-delete command" "git branch -D issue-14-sync" "$OUT"

echo "== 15. --repo after the branch arguments still selects the repository =="
R=$(merged_with_remote r15 issue-15-export)
OUT=$(env -C "$T" bash "$SCRIPT" issue-15-export develop --keep-remote --repo "$R" </dev/null 2>&1); RC=$?
check "exit zero" 0 "$RC"
check "local branch deleted" no "$(branch_exists "$R" issue-15-export)"
check "on base branch" develop "$(git_q "$R" branch --show-current)"
check "remote branch kept" yes "$(remote_branch_exists "$R" issue-15-export)"

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
