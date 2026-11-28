#!/usr/bin/env bash
# retro-pr.sh — Put /retro's project-doc changes on a retro-* branch in a
# linked worktree, then open them as a PR and remove the worktree.
#
# Why this exists
# ---------------
# A retro writes CLAUDE.md, docs/development/ and scripts/ changes in whatever
# project the session ran in. Committed on the checked-out branch they ride
# along with unrelated work, or land on the base branch unreviewed. This script
# is the one implementation of "a fresh branch from the base, in its own tree,
# opened as a PR" that /retro (and /retro auto) call, in two steps around the
# skill's own writing and committing.
#
# Usage:
#   retro-pr.sh [--repo DIR] prepare <slug>
#   retro-pr.sh [--repo DIR] prepare <slug> --join <retro-branch>
#   retro-pr.sh publish <worktree> --title <title> --body-file <file>
#
# prepare
#   Fetches origin, picks the base and creates a linked worktree on a new
#   branch retro-<YYYY-MM-DD>-<slug> from origin/<base>, at the sibling
#   <main-worktree>-<branch>. With --join it uses that existing retro-* branch
#   (local or on origin) instead: a worktree already on it is reused when
#   clean, otherwise one is created; either way it is fast-forwarded to
#   origin/<branch>. The caller's own tree is never checked out or changed.
#
#   Base: origin/develop when it exists, otherwise the target of origin/HEAD.
#   The checked-out branch never decides, so a session on main in a repo with
#   develop still gets develop.
#
# publish
#   Refuses a worktree with uncommitted changes or no commits ahead of
#   origin/<base>. Pushes the branch and opens a PR to <base> (reusing an open
#   one) through git-push-pr-merge.sh --no-merge, so nothing is merged. Then
#   removes the worktree. The branch stays, locally and on origin.
#
# Output (stdout):
#   prepare  WORKTREE: <path>, BRANCH: <branch>, BASE: <base>, one per line
#   publish  git-push-pr-merge.sh's lines (PR_NUMBER:, PR_URL:, STATUS:),
#            then REMOVED: <worktree>
#
# Exit codes:
#   0 = done
#   1 = refused: no repository, no base (no origin/develop and no
#       origin/HEAD), branch already exists, branch to join not found, worktree
#       dirty or path taken, nothing to publish, or a git/gh step failed
#   2 = usage error

set -uo pipefail

BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/lib/live-checkout.sh
. "$BIN_DIR/lib/live-checkout.sh"
# shellcheck source=bin/lib/git-env.sh
. "$BIN_DIR/lib/git-env.sh"

USAGE="usage: retro-pr.sh [--repo DIR] prepare <slug> [--join <retro-branch>]
       retro-pr.sh publish <worktree> --title <title> --body-file <file>"
usage() { echo "$USAGE" >&2; exit 2; }
die() { echo "retro-pr.sh: $*" >&2; exit 1; }

# Every retro branch carries this prefix; the parallel-branch check in /retro
# lists branches by it.
BRANCH_PREFIX="retro-"
DEVELOP="develop"

# An exported GIT_DIR or GIT_WORK_TREE would point every git call below at
# another repository. Nothing here needs them.
git_env_isolate || die "cannot clear the git environment"

REPO="."
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || usage; REPO="$2"; shift 2 ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        -*) usage ;;
        *) break ;;
    esac
done
[[ $# -ge 1 ]] || usage
COMMAND="$1"; shift

# Print the base branch of the repository at <dir>, or fail when it has none.
retro_base() { # dir
    local head
    if git -C "$1" rev-parse --verify -q "refs/remotes/origin/$DEVELOP" >/dev/null; then
        echo "$DEVELOP"
        return 0
    fi
    head=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
    echo "${head#origin/}"
}

is_dirty() { # worktree
    [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]
}

has_ref() { # dir ref
    git -C "$1" rev-parse --verify -q "$2" >/dev/null
}

# Bring a joined worktree up to the branch's state on origin, so a commit made
# there pushes as a fast-forward instead of being rejected.
fast_forward() { # worktree branch
    has_ref "$1" "refs/remotes/origin/$2" || return 0
    git -C "$1" merge -q --ff-only "origin/$2" >&2 \
        || die "$2 in $1 has diverged from origin/$2; reconcile it by hand"
}

prepare() {
    local slug="" join="" root main base branch path existing
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --join) [[ $# -ge 2 ]] || usage; join="$2"; shift 2 ;;
            -*) usage ;;
            *) [[ -z "$slug" ]] || usage; slug="$1"; shift ;;
        esac
    done
    [[ -n "$slug" ]] || usage
    # The slug becomes part of a branch name and a path: keep it kebab-case.
    if [[ ! "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "retro-pr.sh: slug '$slug' is not kebab-case" >&2
        usage
    fi
    if [[ -n "$join" && "$join" != "$BRANCH_PREFIX"* ]]; then
        echo "retro-pr.sh: --join takes a ${BRANCH_PREFIX}* branch, not '$join'" >&2
        usage
    fi

    root=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "$REPO is not inside a git repository"
    main=$(main_worktree_root "$root")
    git -C "$root" remote get-url origin >/dev/null 2>&1 || die "$root has no origin remote; no base to branch from"

    # A failed fetch (offline, sandbox) still leaves the last fetched refs.
    git -C "$root" fetch -q origin >&2 \
        || echo "retro-pr.sh: fetching origin failed; using the last fetched refs." >&2

    base=$(retro_base "$root") \
        || die "no base: origin/$DEVELOP does not exist and origin/HEAD is not set (git remote set-head origin --auto)"

    if [[ -n "$join" ]]; then
        branch="$join"
        existing=$(awk -F'\t' -v b="$branch" '$2 == b { print $1; exit }' <<< "$(worktree_list "$root")")
        if [[ -n "$existing" ]]; then
            is_dirty "$existing" && die "$existing (on $branch) has uncommitted changes; commit or discard them there first"
            path="$existing"
        else
            path="$main-$branch"
            [[ -e "$path" ]] && die "$path exists but is not a worktree on $branch"
            if has_ref "$root" "refs/heads/$branch"; then
                git -C "$root" worktree add -q "$path" "$branch" >&2 || die "could not create $path"
            elif has_ref "$root" "refs/remotes/origin/$branch"; then
                git -C "$root" worktree add -q --no-track -b "$branch" "$path" "origin/$branch" >&2 \
                    || die "could not create $path"
            else
                die "branch $branch exists neither locally nor on origin"
            fi
        fi
        fast_forward "$path" "$branch"
    else
        branch="$BRANCH_PREFIX$(date +%F)-$slug"
        if has_ref "$root" "refs/heads/$branch" || has_ref "$root" "refs/remotes/origin/$branch"; then
            die "branch $branch already exists; pass --join $branch to add to it, or pick another slug"
        fi
        path="$main-$branch"
        [[ -e "$path" ]] && die "$path already exists"
        has_ref "$root" "refs/remotes/origin/$base" || die "origin/$base does not exist; cannot branch from it"
        # --no-track: an upstream of origin/<base> would point a later plain
        # push at the base branch. The push in publish sets the real upstream.
        git -C "$root" worktree add -q --no-track -b "$branch" "$path" "origin/$base" >&2 \
            || die "could not create $path"
    fi

    echo "WORKTREE: $path"
    echo "BRANCH: $branch"
    echo "BASE: $base"
}

case "$COMMAND" in
    prepare) prepare "$@" ;;
    *) usage ;;
esac
