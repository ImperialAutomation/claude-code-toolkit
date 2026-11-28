#!/bin/bash
# Tests for retro-pr.sh.
#
# Usage:
#   bin/tests/test-retro-pr.sh
#
# Runs against throwaway repositories with a REAL bare origin and REAL linked
# worktrees: the thing under test is which base, branch and tree git ends up
# with, so stubbing git would test the stub. Only `gh` is stubbed (publish
# opens a PR through git-push-pr-merge.sh), and the stub logs its arguments.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../retro-pr.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

contains() { # haystack needle -> yes/no
    case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TODAY=$(date +%F)

# A fake gh: `pr list` finds no PR, `pr create` answers with a PR URL. Every
# call is appended to $GH_LOG, one line per call.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'FAKE_GH'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
    "pr list")   echo "[]" ;;
    "pr create") echo "https://github.com/acme/shop/pull/41" ;;
    *)           echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "$T/fakebin/gh"
export GH_LOG="$T/gh.log"

# make_repo <name> <default-branch> [extra-branch...]: a bare origin whose HEAD
# is <default-branch>, carrying every listed branch with a commit of its own (so
# "started from the right branch" is visible in the SHA), and a clone of it at
# $T/<name> checked out on <default-branch>. Prints the clone's path.
make_repo() {
    local name="$1" default="$2" seed="$T/$1-seed" b
    shift 2
    git init -q -b "$default" "$seed"
    git -C "$seed" config user.email "dev@example.com"
    git -C "$seed" config user.name "Test Developer"
    git -C "$seed" commit -q --allow-empty -m "initial commit"
    for b in "$@"; do
        git -C "$seed" switch -q -c "$b"
        git -C "$seed" commit -q --allow-empty -m "work on $b"
        git -C "$seed" switch -q "$default"
    done
    git clone -q --bare "$seed" "$T/$name.git"
    git clone -q "$T/$name.git" "$T/$name" 2>/dev/null
    git -C "$T/$name" config user.email "dev@example.com"
    git -C "$T/$name" config user.name "Test Developer"
    echo "$T/$name"
}

# run <cwd> [args...]: the script from <cwd>, stdout only, fake gh first on PATH.
run() {
    local cwd="$1"; shift
    (cd "$cwd" && PATH="$T/fakebin:$PATH" bash "$SCRIPT" "$@" 2>"$T/stderr")
}

status_of() { # cwd [args...]
    run "$@" >/dev/null; echo $?
}

field() { # output key
    awk -v k="$2: " 'index($0, k) == 1 { print substr($0, length(k) + 1) }' <<< "$1"
}

echo "== 1. base is origin/develop when it exists, also from main =="
R1=$(make_repo shop main develop)
OUT=$(run "$R1" prepare price-rounding)
check "prepare exits 0" "0" "$?"
check "base is develop" "develop" "$(field "$OUT" BASE)"
check "branch is retro-<date>-<slug>" "retro-$TODAY-price-rounding" "$(field "$OUT" BRANCH)"
WT1=$(field "$OUT" WORKTREE)
check "worktree is the sibling <repo>-<branch>" "$T/shop-retro-$TODAY-price-rounding" "$WT1"
check "worktree is on the branch" "retro-$TODAY-price-rounding" "$(git -C "$WT1" branch --show-current)"
check "branch starts at origin/develop" "$(git -C "$R1" rev-parse origin/develop)" "$(git -C "$WT1" rev-parse HEAD)"
check "branch has no upstream yet" "" "$(git -C "$WT1" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"
check "caller's tree stays on main" "main" "$(git -C "$R1" branch --show-current)"
check "caller's tree stays clean" "" "$(git -C "$R1" status --porcelain)"

echo "== 2. without develop the base is the origin default branch =="
R2=$(make_repo api trunk release)
OUT=$(run "$R2" prepare cache-notes)
check "base is origin/HEAD's target" "trunk" "$(field "$OUT" BASE)"
# The checked-out branch must not decide: from a feature branch the base is
# still the origin default, not that branch and not another integration branch.
git -C "$R2" switch -q -c feature/x
OUT=$(run "$R2" prepare other-notes)
check "from a feature branch the base is still trunk" "trunk" "$(field "$OUT" BASE)"
check "--repo selects the repository" "trunk" \
    "$(field "$(run "$T" --repo "$R2" prepare third-notes)" BASE)"

echo "== 3. no base: refuse =="
R3=$(make_repo bare-head main)
git -C "$R3" remote set-head origin --delete
# Since git 2.48 a fetch recreates a missing origin/HEAD by default; "never"
# keeps it missing, as on an older git or a remote that advertises no HEAD.
git -C "$R3" config remote.origin.followRemoteHEAD never
check "missing origin/HEAD without develop exits 1" "1" "$(status_of "$R3" prepare notes)"
check "the refusal says why" "yes" "$(contains "$(cat "$T/stderr")" "origin/HEAD")"
check "and creates no worktree" "no" "$([[ -e "$T/bare-head-retro-$TODAY-notes" ]] && echo yes || echo no)"
git init -q -b main "$T/no-origin"
git -C "$T/no-origin" -c user.email=d@e -c user.name=D commit -q --allow-empty -m init
check "a repository without origin exits 1" "1" "$(status_of "$T/no-origin" prepare notes)"
check "outside a repository exits 1" "1" "$(status_of "$T" prepare notes)"

echo "== 4. naming and usage =="
check "a slug that is not kebab-case exits 2" "2" "$(status_of "$R1" prepare Bad_Slug)"
check "prepare without a slug exits 2" "2" "$(status_of "$R1" prepare)"
check "an unknown command exits 2" "2" "$(status_of "$R1" merge)"
# A second retro with the same slug on the same day must not silently land on
# the first one's branch: joining is a decision, made with --join.
check "an existing branch of that name exits 1" "1" "$(status_of "$R1" prepare price-rounding)"
check "and points at --join" "yes" "$(contains "$(cat "$T/stderr")" "--join")"
check "--join refuses a branch that is not retro-*" "2" "$(status_of "$R1" prepare x --join develop)"

echo "== 5. joining an existing retro-* branch =="
# A parallel retro pushed its branch; this one joins it from a fresh clone.
R5=$(make_repo web main develop)
git -C "$T/web-seed" switch -q -c retro-2026-01-02-auth-notes develop
git -C "$T/web-seed" commit -q --allow-empty -m "retro: capture auth notes"
git -C "$T/web-seed" push -q "$T/web.git" retro-2026-01-02-auth-notes 2>/dev/null
OUT=$(run "$R5" prepare ignored --join retro-2026-01-02-auth-notes)
check "join exits 0" "0" "$?"
WT5=$(field "$OUT" WORKTREE)
check "joined branch is reported" "retro-2026-01-02-auth-notes" "$(field "$OUT" BRANCH)"
check "joined worktree is on it" "retro-2026-01-02-auth-notes" "$(git -C "$WT5" branch --show-current)"
check "joined worktree has the other retro's commit" \
    "$(git -C "$R5" rev-parse origin/retro-2026-01-02-auth-notes)" "$(git -C "$WT5" rev-parse HEAD)"
check "join reports the base" "develop" "$(field "$OUT" BASE)"
# The same join again: the tree exists and is clean, so it is reused.
check "a clean existing worktree is reused" "$WT5" \
    "$(field "$(run "$R5" prepare ignored --join retro-2026-01-02-auth-notes)" WORKTREE)"
echo "draft" > "$WT5/notes.md"
check "a dirty joined worktree exits 1" "1" "$(status_of "$R5" prepare ignored --join retro-2026-01-02-auth-notes)"
check "the refusal names the tree" "yes" "$(contains "$(cat "$T/stderr")" "$WT5")"
check "and leaves the draft alone" "draft" "$(cat "$WT5/notes.md")"
check "joining a branch that does not exist exits 1" "1" \
    "$(status_of "$R5" prepare ignored --join retro-2026-01-02-nope)"
# A registered worktree whose directory was deleted must not pass as clean.
rm -rf "$WT5"
check "a joined worktree whose directory is gone exits 1" "1" \
    "$(status_of "$R5" prepare ignored --join retro-2026-01-02-auth-notes)"
check "and points at git worktree prune" "yes" "$(contains "$(cat "$T/stderr")" "git worktree prune")"

echo "== 6. publish pushes, opens a PR to the base and removes the worktree =="
R6=$(make_repo shop6 main develop)
OUT=$(run "$R6" prepare deploy-notes)
WT6=$(field "$OUT" WORKTREE)
BRANCH6=$(field "$OUT" BRANCH)
DEVELOP_SHA=$(git -C "$R6" rev-parse origin/develop)
echo "## Deploy" > "$WT6/CLAUDE.md"
git -C "$WT6" add CLAUDE.md
git -C "$WT6" commit -q -m "retro: capture deploy notes"
echo "Retro body" > "$T/body6.md"
: > "$GH_LOG"
OUT=$(run "$R6" publish "$WT6" --title "retro: capture deploy notes" --body-file "$T/body6.md")
check "publish exits 0" "0" "$?"
check "publish prints the PR URL" "https://github.com/acme/shop/pull/41" "$(field "$OUT" PR_URL)"
check "publish reports the removed worktree" "$WT6" "$(field "$OUT" REMOVED)"
check "the worktree directory is gone" "no" "$([[ -e "$WT6" ]] && echo yes || echo no)"
check "the worktree is no longer registered" "no" \
    "$(git -C "$R6" worktree list --porcelain | grep -q "$WT6" && echo yes || echo no)"
check "the branch is on origin" "$(git -C "$R6" rev-parse "$BRANCH6")" \
    "$(git -C "$T/shop6.git" rev-parse --verify -q "refs/heads/$BRANCH6")"
check "the PR targets develop with the body file" "yes" \
    "$(contains "$(cat "$GH_LOG")" "pr create --title retro: capture deploy notes --base develop --body-file $T/body6.md")"
check "nothing merged: no gh pr merge" "no" "$(contains "$(cat "$GH_LOG")" "pr merge")"
check "nothing committed on origin/develop" "$DEVELOP_SHA" "$(git -C "$T/shop6.git" rev-parse refs/heads/develop)"
check "caller's tree is still on main" "main" "$(git -C "$R6" branch --show-current)"
check "caller's tree is still clean" "" "$(git -C "$R6" status --porcelain)"

echo "== 7. publish refuses =="
OUT=$(run "$R6" prepare unsaved-notes)
WT7=$(field "$OUT" WORKTREE)
: > "$GH_LOG"
check "a worktree without commits exits 1" "1" \
    "$(status_of "$R6" publish "$WT7" --title t --body-file "$T/body6.md")"
check "and says there is nothing to publish" "yes" "$(contains "$(cat "$T/stderr")" "nothing to publish")"
# Committed work plus an unsaved draft: only the dirty check can refuse here.
git -C "$WT7" commit -q --allow-empty -m "retro: capture part one"
echo "draft" > "$WT7/notes.md"
check "a worktree with uncommitted changes exits 1" "1" \
    "$(status_of "$R6" publish "$WT7" --title t --body-file "$T/body6.md")"
check "and keeps the worktree" "draft" "$(cat "$WT7/notes.md")"
check "the main worktree exits 1" "1" "$(status_of "$R6" publish "$R6" --title t --body-file "$T/body6.md")"
git -C "$R6" worktree add -q -b feature/y "$T/shop6-feature" origin/main 2>/dev/null
check "a worktree not on retro-* exits 1" "1" \
    "$(status_of "$R6" publish "$T/shop6-feature" --title t --body-file "$T/body6.md")"
check "no refusal reached gh" "" "$(cat "$GH_LOG")"
check "publish without --title exits 2" "2" "$(status_of "$R6" publish "$WT7" --body-file "$T/body6.md")"
check "publish without a worktree exits 2" "2" "$(status_of "$R6" publish --title t --body-file "$T/body6.md")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
