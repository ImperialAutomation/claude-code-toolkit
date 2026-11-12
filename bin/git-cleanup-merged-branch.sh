#!/bin/bash
# Git cleanup script - checkout base branch, pull latest, delete merged feature branch
#
# Usage: git-cleanup-merged-branch.sh [options] [feature-branch] [base-branch]
#   If no branches specified, uses current branch as feature and finds its base.
#
# Toolkit route: when the repository's main worktree is the LIVE toolkit
# checkout (the one ~/.claude/bin points into), merged work lives in a linked
# worktree `../<repo>-<N>` and going live means fast-forwarding the live
# checkout. Then, run from either tree:
#   - feature branch: the argument; else the branch of the linked worktree it
#     runs in; else, from the live checkout, the one linked worktree on an
#     `issue-*` branch merged into origin/<base> (several: listed, exit 1)
#   - base branch: the second argument, else origin/HEAD's target, else main
#   - every check runs before the first change: live checkout clean and on
#     <base>, <base> fast-forwardable to origin/<base> without overwriting an
#     untracked file, the feature tip merged into origin/<base> and not on its
#     first-parent line (a branch without commits of its own is refused), its
#     worktree present, unlocked and clean. Any failure changes nothing.
#   - then: `git worktree remove` the feature worktree (its gitignored files
#     are listed as a warning, then deleted with it), fast-forward the live
#     checkout, `git branch -d` the branch, remote branch as below. A failing
#     step says what was already done; a re-run with the branch continues.
#   - run from the linked worktree, this removes the caller's own working
#     directory; the live checkout's path is printed at the end
# In every other repository the route below the toolkit section is unchanged.
#
# Options (anywhere on the command line):
#   --repo DIR       Run git in repository DIR (avoids a leading `cd`, which
#                    would break the Bash(~/.claude/bin/*) permission match)
#   --delete-remote  Delete the remote feature branch without asking
#   --keep-remote    Keep the remote feature branch without asking
#   -h, --help       Show this help and exit
#
# Without a terminal on stdin (an agent session), nothing is prompted and every
# question takes its safe default:
#   - remote branch still exists: kept; the delete command is printed, exit 0
#     (pass --delete-remote to delete it instead)
#   - uncommitted changes: stops before touching anything, exit 1
#   - branch not fully merged but nothing would be lost: kept; the
#     `git branch -D` command is printed, exit 1
#
# Exit codes: 0 cleaned up, 1 refused or failed, 2 usage error.

set -e  # Exit on error

# Sourced before the --repo cd, and resolved from BASH_SOURCE rather than the
# cwd: this script runs from arbitrary directories and bin/ is a symlink.
# shellcheck source=bin/lib/strip-sandbox-noise.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/strip-sandbox-noise.sh"
# shellcheck source=bin/lib/live-checkout.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/live-checkout.sh"

readonly EXIT_USAGE=2

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

usage_error() { # message
    echo "Error: $1" >&2
    echo "Run '$(basename "$0") --help' for usage." >&2
    exit "$EXIT_USAGE"
}

# --help is answered first, wherever it appears: an earlier argument must never
# be acted on (or a later one taken as a branch name) before help is shown.
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
    esac
done

# All options are parsed before any git command, so a mistyped flag can never
# become a branch name and is refused before the repository is touched.
REPO_DIR=""
REMOTE_ACTION=""   # delete | keep | "" (ask on a terminal, keep otherwise)
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            [ $# -ge 2 ] || usage_error "--repo needs a directory"
            REPO_DIR="$2"
            shift 2
            ;;
        --delete-remote|--keep-remote)
            action="${1#--}"; action="${action%-remote}"
            if [ -n "$REMOTE_ACTION" ] && [ "$REMOTE_ACTION" != "$action" ]; then
                usage_error "--delete-remote and --keep-remote exclude each other"
            fi
            REMOTE_ACTION="$action"
            shift
            ;;
        -*) usage_error "unknown option '$1'" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
[ ${#POSITIONAL[@]} -le 2 ] || usage_error "too many arguments: ${POSITIONAL[*]}"

# cd in BEFORE any git command (including the `git branch --show-current` default).
if [ -n "$REPO_DIR" ]; then
    cd "$REPO_DIR" || { echo "Error: cannot cd into repo '$REPO_DIR'" >&2; exit 1; }
fi

FEATURE_BRANCH="${POSITIONAL[0]:-$(git_filtered branch --show-current)}"
BASE_BRANCH="${POSITIONAL[1]:-}"

# A prompt is only asked on a terminal. Without one, `read` hits EOF and, under
# set -e, ends the script mid-cleanup; the callers take the safe default instead.
has_tty() { [ -t 0 ]; }

confirm() { # prompt -> 0 on y/Y
    read -p "$1 (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Called after the local branch is gone. Keeping the remote branch is never a
# failure: the local cleanup succeeded, so the caller still exits 0.
handle_remote_branch() {
    git ls-remote --exit-code --heads origin "$FEATURE_BRANCH" &>/dev/null || return 0

    echo -e "\n${YELLOW}Remote branch 'origin/$FEATURE_BRANCH' still exists${NC}"
    local action="$REMOTE_ACTION"
    if [ -z "$action" ]; then
        if has_tty; then
            if confirm "Delete remote branch?"; then action=delete; else action=keep; fi
        else
            action=keep
            echo "No terminal to confirm, so it was kept (pass --delete-remote to delete)."
        fi
    fi

    if [ "$action" = delete ]; then
        git_filtered push origin --delete "$FEATURE_BRANCH"
        echo -e "${GREEN}✓ Deleted remote branch 'origin/$FEATURE_BRANCH'${NC}"
    elif [ -z "$REMOTE_ACTION" ]; then
        echo "To delete it: git push origin --delete $FEATURE_BRANCH"
    fi
}

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Toolkit route (#206) -----------------------------------------------------

# Refuse with a message; nothing has been changed when this is called.
tk_refuse() { # message...
    echo -e "${RED}Error: $1${NC}" >&2
    shift
    local line
    for line in "$@"; do echo "$line" >&2; done
    echo "Nothing was changed." >&2
    exit 1
}

# A step after the checks failed. The steps before it stay done. A re-run with
# the branch named continues: every check passes again on the partly cleaned
# state, and a step that is already done is skipped or a no-op.
tk_step_failed() { # step already-done
    echo -e "${RED}Error: $1 failed (see git's message above).${NC}" >&2
    echo "Already done: $2." >&2
    echo "Fix the cause, then re-run from the live checkout to continue:" >&2
    echo "  ~/.claude/bin/$(basename "$0") --repo $LIVE_ROOT $FEATURE_BRANCH $TK_BASE" >&2
    exit 1
}

# Succeed when <commit> is on the first-parent line of <remote-base>. A branch
# without commits of its own (a fresh worktree another session just created)
# sits there; work merged with a merge commit does not.
tk_on_first_parent() { # commit remote-base
    local tip
    tip=$(git_filtered -C "$LIVE_ROOT" rev-parse "$1")
    git_filtered -C "$LIVE_ROOT" rev-list --first-parent "$2" | grep -qx "$tip"
}

# Linked worktrees on an issue-* branch whose work is merged into $1: an
# ancestor of the remote base that is not on its first-parent line.
tk_merged_issue_worktrees() { # remote-base
    local path branch
    while IFS=$'\t' read -r path branch _ _; do
        [ "$path" != "$LIVE_ROOT" ] || continue
        [[ "$branch" == issue-* ]] || continue
        git_filtered -C "$LIVE_ROOT" merge-base --is-ancestor "refs/heads/$branch" "$1" || continue
        tk_on_first_parent "refs/heads/$branch" "$1" && continue
        printf '%s\t%s\n' "$path" "$branch"
    done < <(worktree_list "$LIVE_ROOT")
}

toolkit_cleanup() {
    # Leave the feature worktree first: it is about to be removed.
    cd "$LIVE_ROOT"

    local base remote_base worktree="" locked="" prunable="" path branch lock prune
    local candidates overwritten ignored done_so_far
    base="${POSITIONAL[1]:-$(live_base_branch "$LIVE_ROOT")}"
    remote_base="origin/$base"
    TK_BASE="$base"

    echo -e "${GREEN}=== Git Cleanup: Merged Toolkit Worktree ===${NC}"
    echo "Live checkout: $LIVE_ROOT"

    git_filtered fetch --prune origin || tk_refuse "fetching origin failed"
    git_filtered rev-parse --verify -q "$remote_base" >/dev/null \
        || tk_refuse "'$remote_base' does not exist"

    FEATURE_BRANCH="${POSITIONAL[0]:-}"
    if [ -z "$FEATURE_BRANCH" ] && [ "$REPO_TOP" != "$LIVE_ROOT" ]; then
        FEATURE_BRANCH=$(git_filtered -C "$REPO_TOP" branch --show-current)
        [ -n "$FEATURE_BRANCH" ] || tk_refuse "worktree '$REPO_TOP' is not on a branch"
    fi
    if [ -z "$FEATURE_BRANCH" ]; then
        candidates=$(tk_merged_issue_worktrees "$remote_base")
        case "$(grep -c . <<< "$candidates")" in
            0) tk_refuse "no linked worktree on an issue-* branch is merged into '$remote_base'" ;;
            1) FEATURE_BRANCH=$(cut -f2 <<< "$candidates") ;;
            *) tk_refuse "several merged issue worktrees; name the branch to clean up:" \
                   "$(sed 's/^\(.*\)\t\(.*\)$/  \2  (\1)/' <<< "$candidates")" ;;
        esac
    fi

    echo "Feature branch: $FEATURE_BRANCH"
    echo "Base branch: $base"

    [ "$FEATURE_BRANCH" != "$base" ] || tk_refuse "cannot clean up the base branch '$base'"
    git_filtered show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH" \
        || tk_refuse "branch '$FEATURE_BRANCH' does not exist"

    while IFS=$'\t' read -r path branch lock prune; do
        [ "$branch" = "$FEATURE_BRANCH" ] || continue
        worktree="$path"; locked="$lock"; prunable="$prune"
    done < <(worktree_list "$LIVE_ROOT")
    [ "$worktree" != "$LIVE_ROOT" ] \
        || tk_refuse "'$FEATURE_BRANCH' is checked out in the live checkout itself"

    # All checks before the first change.
    [ "$(git_filtered branch --show-current)" = "$base" ] \
        || tk_refuse "the live checkout is not on '$base'" "Switch it back: git -C $LIVE_ROOT switch $base"
    [ -z "$(git_filtered status --porcelain --untracked-files=no)" ] \
        || tk_refuse "the live checkout has uncommitted changes" "Commit or stash them in $LIVE_ROOT, then re-run."
    git_filtered merge-base --is-ancestor HEAD "$remote_base" \
        || tk_refuse "the live checkout's '$base' cannot fast-forward to '$remote_base' (it has commits of its own)"
    # Untracked files are left out of the clean check above, but one that the
    # fast-forward would write over makes the merge abort halfway through.
    overwritten=$(comm -12 \
        <(git_filtered ls-files --others --exclude-standard | sort) \
        <(git_filtered diff --name-only HEAD "$remote_base" | sort))
    [ -z "$overwritten" ] \
        || tk_refuse "untracked files in the live checkout would be overwritten by '$remote_base':" \
               "$(sed 's/^/  /' <<< "$overwritten")" "Move or remove them in $LIVE_ROOT, then re-run."
    git_filtered merge-base --is-ancestor "refs/heads/$FEATURE_BRANCH" "$remote_base" \
        || tk_refuse "'$FEATURE_BRANCH' is not merged into '$remote_base'" \
               "Merge its PR first; for a squash merge delete it by hand: git branch -D $FEATURE_BRANCH"
    # Ancestry alone would also pass a branch without commits of its own, such
    # as a worktree another session has only just created (D7).
    if tk_on_first_parent "refs/heads/$FEATURE_BRANCH" "$remote_base"; then
        tk_refuse "'$FEATURE_BRANCH' has no commits of its own: its tip is on the first-parent line of '$remote_base'" \
            "A fresh worktree looks like this; another session may be working in it." \
            "If it was merged by fast-forward instead, clean up by hand:" \
            "  git -C $LIVE_ROOT worktree remove ${worktree:-<worktree>}" \
            "  git -C $LIVE_ROOT branch -d $FEATURE_BRANCH"
    fi
    if [ -n "$worktree" ]; then
        if [ -n "$prunable" ] || [ ! -d "$worktree" ]; then
            tk_refuse "worktree '$worktree' is registered, but its directory is gone" \
                "Unregister it, then re-run with the branch named:" \
                "  git -C $LIVE_ROOT worktree prune" \
                "  ~/.claude/bin/$(basename "$0") --repo $LIVE_ROOT $FEATURE_BRANCH $base"
        fi
        [ -z "$locked" ] || tk_refuse "worktree '$worktree' is locked" "Unlock it: git worktree unlock $worktree"
        [ -z "$(git_filtered -C "$worktree" status --porcelain)" ] \
            || tk_refuse "worktree '$worktree' has uncommitted or untracked files" \
                   "Commit, move or remove them, then re-run."
    fi

    # The worktree goes first: the fast-forward cannot be undone, and
    # `git branch -d` comes last because it needs the advanced HEAD (the branch
    # has no upstream to be merged into).
    done_so_far="nothing"
    if [ -n "$worktree" ]; then
        echo -e "\n${GREEN}Step 1: Removing worktree $worktree${NC}"
        # `git worktree remove` deletes gitignored files without asking (D8).
        ignored=$(git_filtered -C "$worktree" status --porcelain --ignored | sed -n 's/^!! /  /p')
        if [ -n "$ignored" ]; then
            echo -e "${YELLOW}Warning: these gitignored files are deleted with the worktree:${NC}"
            echo "$ignored"
        fi
        git_filtered worktree remove "$worktree" \
            || tk_step_failed "Step 1 (git worktree remove)" "$done_so_far"
        done_so_far="worktree $worktree removed"
    fi

    echo -e "\n${GREEN}Step 2: Fast-forwarding the live checkout to $remote_base${NC}"
    git_filtered merge --ff-only "$remote_base" \
        || tk_step_failed "Step 2 (fast-forward)" "$done_so_far"
    done_so_far="$done_so_far; live checkout fast-forwarded to $remote_base"
    done_so_far="${done_so_far#nothing; }"

    echo -e "\n${GREEN}Step 3: Deleting merged branch $FEATURE_BRANCH${NC}"
    git_filtered branch -d "$FEATURE_BRANCH" \
        || tk_step_failed "Step 3 (git branch -d)" "$done_so_far"
    handle_remote_branch

    echo -e "\n${GREEN}=== Cleanup Complete: live at $(git_filtered log -1 --oneline) ===${NC}"
    # A run from the sibling has just removed the caller's own working directory.
    echo "Continue in the live checkout: $LIVE_ROOT"
}

REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$REPO_TOP" ] && is_live_repo; then
    LIVE_ROOT=$(live_checkout_root)
    toolkit_cleanup
    exit 0
fi

# --- Every other repository ---------------------------------------------------

echo -e "${GREEN}=== Git Cleanup: Merged Branch ===${NC}"
echo "Feature branch: $FEATURE_BRANCH"

# Find base branch if not specified
if [ -z "$BASE_BRANCH" ]; then
    echo "Finding base branch for $FEATURE_BRANCH..."

    # Try git-find-base-branch first
    if [ -x ~/.claude/bin/git-find-base-branch ]; then
        BASE_BRANCH=$(~/.claude/bin/git-find-base-branch)
    else
        # Fallback: check common base branches
        for candidate in develop master main; do
            if git_filtered show-ref --verify --quiet refs/heads/$candidate; then
                if git merge-base --is-ancestor "$candidate" "$FEATURE_BRANCH" 2>/dev/null; then
                    BASE_BRANCH=$candidate
                    break
                fi
            fi
        done
    fi

    if [ -z "$BASE_BRANCH" ]; then
        echo -e "${RED}Error: Could not determine base branch${NC}"
        echo "Please specify manually: git-cleanup-merged-branch.sh $FEATURE_BRANCH <base-branch>"
        exit 1
    fi
fi

echo "Base branch: $BASE_BRANCH"

# Verify feature branch exists
if ! git_filtered show-ref --verify --quiet refs/heads/"$FEATURE_BRANCH"; then
    echo -e "${RED}Error: Branch '$FEATURE_BRANCH' does not exist${NC}"
    exit 1
fi

# Verify base branch exists
if ! git_filtered show-ref --verify --quiet refs/heads/"$BASE_BRANCH"; then
    echo -e "${RED}Error: Base branch '$BASE_BRANCH' does not exist${NC}"
    exit 1
fi

# Don't allow cleanup of base branch itself
if [ "$FEATURE_BRANCH" = "$BASE_BRANCH" ]; then
    echo -e "${RED}Error: Cannot cleanup base branch '$BASE_BRANCH'${NC}"
    exit 1
fi

# Warn if there are uncommitted changes
if ! git_filtered diff-index --quiet HEAD --; then
    echo -e "${YELLOW}Warning: You have uncommitted changes${NC}"
    if ! has_tty; then
        echo "Stopped: no terminal to confirm continuing. Commit or stash, then re-run."
        exit 1
    fi
    confirm "Continue anyway?" || exit 1
fi

# Step 1: Checkout base branch
echo -e "\n${GREEN}Step 1: Checking out $BASE_BRANCH${NC}"
git_filtered checkout "$BASE_BRANCH"

# Resolve what the base branch actually tracks. A plain `pull origin
# "$BASE_BRANCH"` assumes a same-named branch on origin, which is wrong twice
# over: the upstream branch may have a different name, and it may live on a
# different remote. A linked worktree hits the first case routinely -- the shared
# base is checked out in the main tree, so the worktree parks on its own branch
# tracking origin/develop, and the pull dies on "couldn't find remote ref".
UPSTREAM=$(git_filtered rev-parse --abbrev-ref --symbolic-full-name "$BASE_BRANCH@{upstream}" 2>/dev/null) || {
    echo -e "${RED}Error: '$BASE_BRANCH' has no upstream${NC}" >&2
    echo "Set one with: git branch -u <remote>/<branch> $BASE_BRANCH" >&2
    exit 1
}

# The remote to fetch is the one holding the upstream, not a hardcoded origin.
# Fetching the wrong remote leaves the upstream ref stale, and the
# fast-forward below would then land on an old commit -- exit 0, quietly wrong.
UPSTREAM_REMOTE="${UPSTREAM%%/*}"

# Step 2: Fetch latest changes and prune stale remote-tracking branches
echo -e "\n${GREEN}Step 2: Fetching latest changes from $UPSTREAM_REMOTE${NC}"
git_filtered fetch --prune "$UPSTREAM_REMOTE"

# Step 3: Bring the base branch up to its upstream
#
# --ff-only rather than a merge: if the base has diverged from its upstream,
# that is a situation to report, not to paper over with a merge commit on the
# base branch (which a plain `pull` will happily create depending on config).
echo -e "\n${GREEN}Step 3: Fast-forwarding $BASE_BRANCH to $UPSTREAM${NC}"
git_filtered merge --ff-only "$UPSTREAM"

# Step 4: Delete feature branch (only if fully merged)
echo -e "\n${GREEN}Step 4: Deleting merged feature branch $FEATURE_BRANCH${NC}"

# Check if feature branch is fully merged
if git_filtered branch --merged "$BASE_BRANCH" | grep -q "^[* ]*$FEATURE_BRANCH$"; then
    git_filtered branch -d "$FEATURE_BRANCH"
    echo -e "${GREEN}✓ Successfully deleted local branch '$FEATURE_BRANCH'${NC}"
    handle_remote_branch
else
    # "Not fully merged" means the branch tip is not an ancestor of the base --
    # a reachability fact, not a content fact. The two diverge whenever history
    # was rewritten (cherry-pick, rebase, squash-merge), so the raw warning
    # cannot tell "work would be lost" apart from "already applied under a new
    # commit". Diagnose both before suggesting anything destructive.
    echo -e "${YELLOW}Branch '$FEATURE_BRANCH' is not fully merged into '$BASE_BRANCH'${NC}"
    echo "Diagnosing whether that means unmerged work or rewritten history..."

    UNIQUE_COMMITS=$(git_filtered log --oneline "$BASE_BRANCH".."$FEATURE_BRANCH")

    if [ -z "$UNIQUE_COMMITS" ]; then
        # No unique commits: only a local merge-commit is unreachable.
        echo -e "\n${GREEN}✓ No unique commits. Nothing would be lost.${NC}"
        echo "  (Typically a local '$BASE_BRANCH'-into-feature merge that GitHub"
        echo "   superseded with its own merge commit.)"
        SAFE_TO_FORCE=1
    else
        echo -e "\n${YELLOW}Commits not reachable from '$BASE_BRANCH':${NC}"
        echo "$UNIQUE_COMMITS" | sed 's/^/  /'

        # Content check. Two dots is deliberate: it compares the two tips, so an
        # empty result proves the branch adds nothing the base lacks. (Three dots
        # would diff from the merge-base and hide base-side changes -- the wrong
        # question here.)
        if [ -z "$(git_filtered diff "$BASE_BRANCH" "$FEATURE_BRANCH")" ]; then
            echo -e "\n${GREEN}✓ ...but the trees are identical.${NC}"
            echo "  The content already landed under different commit hashes"
            echo "  (cherry-pick, rebase, or squash-merge). Nothing would be lost."
            SAFE_TO_FORCE=1
        else
            echo -e "\n${RED}✗ These commits contain content missing from '$BASE_BRANCH'.${NC}"
            echo "  Files that differ:"
            git_filtered diff --stat "$BASE_BRANCH" "$FEATURE_BRANCH" | sed 's/^/    /'
            SAFE_TO_FORCE=0
        fi
    fi

    if [ "$SAFE_TO_FORCE" = "1" ]; then
        echo
        if ! has_tty; then
            echo "Left '$FEATURE_BRANCH' in place: no terminal to confirm a force-delete."
            echo "To delete it: git branch -D $FEATURE_BRANCH"
            exit 1
        fi
        if confirm "Force-delete '$FEATURE_BRANCH'?"; then
            git_filtered branch -D "$FEATURE_BRANCH"
            echo -e "${GREEN}✓ Deleted local branch '$FEATURE_BRANCH'${NC}"
            handle_remote_branch
        else
            echo "Left '$FEATURE_BRANCH' in place."
            exit 1
        fi
    else
        echo
        echo -e "${RED}Refusing to delete: this branch holds work that exists nowhere else.${NC}"
        echo "Rescue it first, for example:"
        echo "  git cherry-pick <commit>   # replay onto $BASE_BRANCH, then re-run cleanup"
        echo "  gh pr create --base $BASE_BRANCH --head $FEATURE_BRANCH"
        echo
        echo "If you are certain it is disposable: git branch -D $FEATURE_BRANCH"
        exit 1
    fi
fi

echo -e "\n${GREEN}=== Cleanup Complete ===${NC}"
echo "Current branch: $(git_filtered branch --show-current)"
echo "Latest commit: $(git_filtered log -1 --oneline)"
