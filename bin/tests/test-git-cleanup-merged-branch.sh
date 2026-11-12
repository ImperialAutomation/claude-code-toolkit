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
#   16-19. toolkit route: sibling, live auto-detect, live with branch,
#          several merged                                -> cleans, or lists
#   20-24. toolkit route refusals                        -> nothing changed
#   25-30. toolkit: locked, directory gone, untracked live file in the way,
#          commitless branch (named, from inside), no candidate -> refuse
#   31-32. toolkit: ignored files listed; --delete-remote -> cleans
#   33-34. toolkit: a step fails after the checks        -> says what was done,
#                                                           a re-run finishes
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

# --- Toolkit route (#206) ------------------------------------------------------
#
# The live toolkit checkout is the main worktree ~/.claude/bin points into. Each
# fixture gets its own HOME whose .claude/bin symlinks into a temporary "live"
# clone, so the real toolkit checkout and its worktrees are never involved.
#
# The PR is merged on the remote, as on the forge: the live checkout's main is
# behind origin/main, and nothing is fetched before the script runs, so the
# script's own fetch is what makes the merge visible.

# A toolkit-shaped clone of a fresh remote on main, plus a HOME that makes it
# live. Prints the live checkout's path; its HOME is "$live-home".
tk_fixture() { # name
    local d
    d=$(newremote "$1" main)
    mkdir -p "$d/bin"
    printf '#!/bin/bash\n' > "$d/bin/tool.sh"
    git -C "$d" add bin
    git -C "$d" commit -qm "Add bin"
    git -C "$d" push -q origin main
    mkdir -p "$d-home/.claude"
    ln -s "$d/bin" "$d-home/.claude/bin"
    echo "$d"
}

# A sibling worktree "$live-<n>" on issue-<n>-<slug> with one commit, pushed.
tk_worktree() { # live n slug
    local live="$1" br="issue-$2-$3" wt="$1-$2"
    git -C "$live" worktree add -q --no-track -b "$br" "$wt" origin/main
    printf 'work for %s\n' "$br" > "$wt/feature-$2.md"
    git -C "$wt" add -A
    git -C "$wt" commit -qm "Add $br notes"
    git -C "$wt" push -q origin "$br"
}

# Merge a pushed branch into the remote's main with a merge commit, as the
# forge does, without touching the live checkout.
tk_merge_on_remote() { # live branch
    local s="$T/merge-$RANDOM"
    git clone -q "$1.git" "$s"
    git -C "$s" config user.email ops@example.com
    git -C "$s" config user.name "Ravi Chandrasekaran"
    git -C "$s" merge -q --no-ff -m "Merge $2" "origin/$2"
    git -C "$s" push -q origin main
    rm -rf "$s"
}

run_tk() { # live dir [args...]
    HOME="$1-home" bash "$SCRIPT" --repo "$2" "${@:3}" </dev/null 2>&1
}

# Everything a refusal must leave alone, in one comparable line.
tk_state() { # live worktree branch
    printf 'head=%s on=%s wt=%s br=%s' \
        "$(git -C "$1" rev-parse HEAD)" "$(git -C "$1" branch --show-current)" \
        "$([[ -d "$2" ]] && echo yes || echo no)" "$(branch_exists "$1" "$3")"
}

# The success state the acceptance criteria name.
check_cleaned() { # live worktree branch
    check "live on main" main "$(git -C "$1" branch --show-current)"
    check "live at origin/main" "$(git -C "$1.git" rev-parse main)" "$(git -C "$1" rev-parse HEAD)"
    check "worktree removed" no "$([[ -d "$2" ]] && echo yes || echo no)"
    # Trailing space: "$L-17" is also a prefix of a sibling "$L-170".
    lacks "worktree unregistered" "$2 " "$(git -C "$1" worktree list)"
    check "branch deleted" no "$(branch_exists "$1" "$3")"
}

echo "== 16. toolkit: run from the merged sibling worktree =="
L=$(tk_fixture tk16)
tk_worktree "$L" 16 widget
tk_merge_on_remote "$L" issue-16-widget
OUT=$(run_tk "$L" "$L-16"); RC=$?
check "exit zero" 0 "$RC"
check_cleaned "$L" "$L-16" issue-16-widget
# The caller's cwd was the removed sibling: tell it where to go on (F4).
contains "names the live checkout to continue in" "Continue in the live checkout: $L" "$OUT"
# No terminal and no flag: the remote branch is kept, as in other repos (F9).
check "remote branch kept by default" yes "$(remote_branch_exists "$L" issue-16-widget)"
contains "prints the delete command" "git push origin --delete issue-16-widget" "$OUT"

echo "== 17. toolkit: run from the live checkout, merged worktree auto-detected =="
L=$(tk_fixture tk17)
tk_worktree "$L" 17 widget
tk_merge_on_remote "$L" issue-17-widget
tk_worktree "$L" 170 unmerged
# A fresh worktree without commits sits on main's own history: an ancestor of
# origin/main, but not merged work. It must not be taken for the merged one.
git -C "$L" worktree add -q --no-track -b issue-171-fresh "$L-171" origin/main
OUT=$(run_tk "$L" "$L"); RC=$?
check "exit zero" 0 "$RC"
check_cleaned "$L" "$L-17" issue-17-widget
check "unmerged worktree kept" yes "$([[ -d "$L-170" ]] && echo yes || echo no)"
check "fresh worktree kept" yes "$([[ -d "$L-171" ]] && echo yes || echo no)"

echo "== 18. toolkit: run from the live checkout with the branch given =="
L=$(tk_fixture tk18)
tk_worktree "$L" 18 widget
tk_merge_on_remote "$L" issue-18-widget
OUT=$(run_tk "$L" "$L" issue-18-widget); RC=$?
check "exit zero" 0 "$RC"
check_cleaned "$L" "$L-18" issue-18-widget

echo "== 19. toolkit: several merged worktrees, no argument -> lists, refuses =="
L=$(tk_fixture tk19)
tk_worktree "$L" 19 alpha
tk_merge_on_remote "$L" issue-19-alpha
tk_worktree "$L" 190 beta
tk_merge_on_remote "$L" issue-190-beta
BEFORE=$(tk_state "$L" "$L-19" issue-19-alpha)
OUT=$(run_tk "$L" "$L"); RC=$?
check "exit one" 1 "$RC"
contains "lists the first" issue-19-alpha "$OUT"
contains "lists the second" issue-190-beta "$OUT"
check "nothing changed" "$BEFORE" "$(tk_state "$L" "$L-19" issue-19-alpha)"
check "second worktree kept" yes "$([[ -d "$L-190" ]] && echo yes || echo no)"

# Each refusal case: set up a merged sibling, break one precondition, run from
# the sibling, and require exit 1, a message, and an untouched state.
tk_refusal() { # name n setup-function needle
    local L
    L=$(tk_fixture "$1")
    tk_worktree "$L" "$2" widget
    tk_merge_on_remote "$L" "issue-$2-widget"
    "$3" "$L" "$L-$2"
    local before
    before=$(tk_state "$L" "$L-$2" "issue-$2-widget")
    OUT=$(run_tk "$L" "$L-$2"); RC=$?
    check "exit one" 1 "$RC"
    contains "explains" "$4" "$OUT"
    check "nothing changed" "$before" "$(tk_state "$L" "$L-$2" "issue-$2-widget")"
}

dirty_live() { printf 'unsaved\n' >> "$1/README.md"; }
live_off_main() { git -C "$1" checkout -q -b side; }
live_diverged() {
    printf 'local only\n' > "$1/local.md"
    git -C "$1" add -A
    git -C "$1" commit -qm "Local-only main commit"
}
feature_unmerged() {
    printf 'late\n' > "$2/late.md"
    git -C "$2" add -A
    git -C "$2" commit -qm "Commit after the merge"
}
dirty_worktree() { printf 'scratch\n' > "$2/scratch.txt"; }

echo "== 20. toolkit: dirty live checkout -> refuses, changes nothing =="
tk_refusal tk20 20 dirty_live "uncommitted changes"
echo "== 21. toolkit: live checkout not on main -> refuses, changes nothing =="
tk_refusal tk21 21 live_off_main "not on 'main'"
echo "== 22. toolkit: live main cannot fast-forward -> refuses, changes nothing =="
tk_refusal tk22 22 live_diverged "cannot fast-forward"
echo "== 23. toolkit: feature branch not merged -> refuses, changes nothing =="
tk_refusal tk23 23 feature_unmerged "not merged"
echo "== 24. toolkit: dirty feature worktree -> refuses, changes nothing =="
tk_refusal tk24 24 dirty_worktree "uncommitted or untracked"

# --- Toolkit route, review round 2 (PR #287) ------------------------------------

lock_worktree() { git -C "$1" worktree lock "$2"; }
# Registered, but the directory is gone: `rm -rf` instead of `worktree remove`.
remove_dir() { rm -rf "$2"; }
# An untracked file in live at a path the merged PR adds.
untracked_in_live() { printf 'draft\n' > "$1/feature-${2##*-}.md"; }

echo "== 25. toolkit: locked feature worktree -> refuses, changes nothing (F9) =="
tk_refusal tk25 25 lock_worktree "is locked"

echo "== 26. toolkit: worktree directory gone -> refuses with prune hint (F1) =="
# Run from the live checkout (the sibling no longer exists to run from), both
# auto-detected and with the branch named.
L=$(tk_fixture tk26)
tk_worktree "$L" 26 widget
tk_merge_on_remote "$L" issue-26-widget
remove_dir "$L" "$L-26"
BEFORE=$(tk_state "$L" "$L-26" issue-26-widget)
for args in "" issue-26-widget; do
    # shellcheck disable=SC2086  # $args is empty or one word on purpose
    OUT=$(run_tk "$L" "$L" $args); RC=$?
    check "exit one (${args:-auto-detect})" 1 "$RC"
    contains "gives the prune hint" "git -C $L worktree prune" "$OUT"
    check "nothing changed" "$BEFORE" "$(tk_state "$L" "$L-26" issue-26-widget)"
done
check "worktree still registered" yes \
    "$(git -C "$L" worktree list | grep -q "^$L-26 " && echo yes || echo no)"

echo "== 27. toolkit: untracked live file the fast-forward writes -> refuses (F5) =="
# Run from the live checkout: the refusal names the file before any change.
L=$(tk_fixture tk27)
tk_worktree "$L" 27 widget
tk_merge_on_remote "$L" issue-27-widget
untracked_in_live "$L" "$L-27"
BEFORE=$(tk_state "$L" "$L-27" issue-27-widget)
OUT=$(run_tk "$L" "$L" issue-27-widget); RC=$?
check "exit one" 1 "$RC"
contains "explains" "would be overwritten" "$OUT"
contains "names the file" "feature-27.md" "$OUT"
check "nothing changed" "$BEFORE" "$(tk_state "$L" "$L-27" issue-27-widget)"

# A branch without commits of its own, as `git-resolve-worktree.sh --create`
# leaves it for a session that has just started (F2, D7). Every path refuses.
tk_fresh() { # live n
    git -C "$1" worktree add -q --no-track -b "issue-$2-fresh" "$1-$2" origin/main
}

echo "== 28. toolkit: commitless branch named from live -> refuses (F2) =="
L=$(tk_fixture tk28)
tk_fresh "$L" 28
BEFORE=$(tk_state "$L" "$L-28" issue-28-fresh)
OUT=$(run_tk "$L" "$L" issue-28-fresh); RC=$?
check "exit one" 1 "$RC"
contains "explains" "no commits of its own" "$OUT"
check "nothing changed" "$BEFORE" "$(tk_state "$L" "$L-28" issue-28-fresh)"

echo "== 29. toolkit: run from inside a commitless sibling -> refuses (F2) =="
L=$(tk_fixture tk29)
tk_fresh "$L" 29
BEFORE=$(tk_state "$L" "$L-29" issue-29-fresh)
OUT=$(run_tk "$L" "$L-29"); RC=$?
check "exit one" 1 "$RC"
contains "explains" "no commits of its own" "$OUT"
check "nothing changed" "$BEFORE" "$(tk_state "$L" "$L-29" issue-29-fresh)"

echo "== 30. toolkit: auto-detect with no merged candidate -> refuses (F9) =="
L=$(tk_fixture tk30)
tk_fresh "$L" 30
tk_worktree "$L" 300 unmerged
BEFORE=$(tk_state "$L" "$L-30" issue-30-fresh)
OUT=$(run_tk "$L" "$L"); RC=$?
check "exit one" 1 "$RC"
contains "explains" "no linked worktree on an issue-* branch is merged" "$OUT"
check "nothing changed" "$BEFORE" "$(tk_state "$L" "$L-30" issue-30-fresh)"
check "unmerged worktree kept" yes "$([[ -d "$L-300" ]] && echo yes || echo no)"

echo "== 31. toolkit: gitignored files in the sibling are listed, then removed (F3) =="
L=$(tk_fixture tk31)
tk_worktree "$L" 31 widget
tk_merge_on_remote "$L" issue-31-widget
# info/exclude is shared by all worktrees of the repository.
# $L is the main worktree, so its .git is the common directory (an absolute
# path: `rev-parse --git-common-dir` answers relative to the caller's cwd).
mkdir -p "$L/.git/info"
printf '.env\n' >> "$L/.git/info/exclude"
printf 'SECRET=1\n' > "$L-31/.env"
OUT=$(run_tk "$L" "$L-31"); RC=$?
check "exit zero" 0 "$RC"
contains "warns about ignored files" "gitignored files are deleted with the worktree" "$OUT"
contains "lists the file" ".env" "$OUT"
check_cleaned "$L" "$L-31" issue-31-widget

echo "== 32. toolkit: --delete-remote deletes the remote branch (F9) =="
L=$(tk_fixture tk32)
tk_worktree "$L" 32 widget
tk_merge_on_remote "$L" issue-32-widget
OUT=$(run_tk "$L" "$L-32" --delete-remote); RC=$?
check "exit zero" 0 "$RC"
check_cleaned "$L" "$L-32" issue-32-widget
check "remote branch deleted" no "$(remote_branch_exists "$L" issue-32-widget)"

# A step after the checks fails (F6). A stub git fails one subcommand and
# passes everything else to the real git; a re-run without it must finish.
REAL_GIT=$(command -v git)
fail_git_on() { # dir "sub1 sub2"
    mkdir -p "$1"
    # shellcheck disable=SC2016  # $1, $2 and $@ belong to the stub, not here
    printf '#!/bin/bash\nif [ "$1 $2" = "%s" ]; then echo "fatal: simulated failure" >&2; exit 1; fi\nexec "%s" "$@"\n' \
        "$2" "$REAL_GIT" > "$1/git"
    chmod +x "$1/git"
}

echo "== 33. toolkit: worktree removal fails -> nothing done, re-run finishes (F6) =="
L=$(tk_fixture tk33)
tk_worktree "$L" 33 widget
tk_merge_on_remote "$L" issue-33-widget
fail_git_on "$T/stub33" "worktree remove"
BEFORE=$(tk_state "$L" "$L-33" issue-33-widget)
OUT=$(PATH="$T/stub33:$PATH" run_tk "$L" "$L-33"); RC=$?
check "exit one" 1 "$RC"
contains "names the step" "Step 1 (git worktree remove) failed" "$OUT"
contains "says what was done" "Already done: nothing." "$OUT"
contains "gives the re-run command" "--repo $L issue-33-widget main" "$OUT"
check "nothing changed" "$BEFORE" "$(tk_state "$L" "$L-33" issue-33-widget)"
OUT=$(run_tk "$L" "$L" issue-33-widget main); RC=$?
check "re-run exits zero" 0 "$RC"
check_cleaned "$L" "$L-33" issue-33-widget

echo "== 34. toolkit: branch deletion fails -> says what was done, re-run finishes (F6) =="
L=$(tk_fixture tk34)
tk_worktree "$L" 34 widget
tk_merge_on_remote "$L" issue-34-widget
fail_git_on "$T/stub34" "branch -d"
OUT=$(PATH="$T/stub34:$PATH" run_tk "$L" "$L-34"); RC=$?
check "exit one" 1 "$RC"
contains "names the step" "Step 3 (git branch -d) failed" "$OUT"
contains "says the worktree is gone" "worktree $L-34 removed" "$OUT"
contains "says live went forward" "live checkout fast-forwarded to origin/main" "$OUT"
check "live already at origin/main" "$(git -C "$L.git" rev-parse main)" "$(git -C "$L" rev-parse HEAD)"
check "branch still there" yes "$(branch_exists "$L" issue-34-widget)"
OUT=$(run_tk "$L" "$L" issue-34-widget main); RC=$?
check "re-run exits zero" 0 "$RC"
check_cleaned "$L" "$L-34" issue-34-widget

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
