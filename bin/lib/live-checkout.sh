#!/usr/bin/env bash
# live-checkout.sh — identify the toolkit checkout that is live system-wide.
#
# Source this, then ask whether a tree is the live checkout:
#
#     # shellcheck source=bin/lib/live-checkout.sh
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/live-checkout.sh"
#     live_root=$(live_checkout_root)
#
# WHY THIS EXISTS
#
# ~/.claude/bin and ~/.claude/skills are symlinks into the working tree of one
# toolkit checkout. Whatever branch that checkout is on runs in every project
# and every session, immediately. A feature branch checked out there is live
# before review, so toolkit changes are built in a linked worktree instead (see
# the repo CLAUDE.md). git-resolve-worktree.sh --create and
# hook-block-toolkit-live-checkout.sh both need the same answer to "which tree
# is that", so it is defined once, here.
#
# The live checkout is the MAIN worktree whose top level equals
# dirname(readlink -f ~/.claude/bin). When ~/.claude/bin is not a symlink,
# nothing is live: live_checkout_root prints nothing and is_live_repo fails.
#
# worktree_list and main_worktree_root are the shared parsers of
# `git worktree list --porcelain` for every script that needs one.

# Print the live checkout's absolute top level, or nothing when there is none.
live_checkout_root() {
    local link="$HOME/.claude/bin" target root main_root

    [[ -L "$link" ]] || return 0
    target=$(readlink -f "$link" 2>/dev/null) || return 0
    root=$(git -C "$(dirname "$target")" rev-parse --show-toplevel 2>/dev/null) || return 0
    [[ "$root" == "$(dirname "$target")" ]] || return 0

    # Only the main worktree counts: a symlink pointing into a linked worktree
    # is unusual, but treating that tree as live would forbid working in it.
    main_root=$(main_worktree_root "$root")
    [[ "$main_root" == "$root" ]] || return 0

    printf '%s\n' "$root"
}

# Print one `<path>\t<branch>\t<locked>\t<prunable>` line per worktree of the
# repository at <dir> (default: the current directory), the main worktree first.
# <branch> is empty for a detached worktree; <locked> is "locked" or empty;
# <prunable> is "prunable" (registered, but its directory is gone) or empty.
# --porcelain is git's stable machine format; this is its one parser.
worktree_list() { # [dir]
    git -C "${1:-.}" worktree list --porcelain 2>/dev/null | awk '
        function out() { if (p != "") print p "\t" b "\t" l "\t" r }
        /^worktree /            { out(); p = substr($0, 10); b = ""; l = ""; r = "" }
        /^branch refs\/heads\// { b = substr($0, 19) }
        /^locked/               { l = "locked" }
        /^prunable/             { r = "prunable" }
        END                     { out() }'
}

# Print the main worktree's path of the repository at <dir> (default: the
# current directory), or nothing outside a repository.
main_worktree_root() { # [dir]
    worktree_list "${1:-.}" | awk -F'\t' 'NR == 1 { print $1 }'
}

# Succeed when the main worktree of the repository at <dir> (default: the
# current directory) is the live checkout, from any of its worktrees.
is_live_repo() { # [dir]
    local live main
    live=$(live_checkout_root)
    [[ -n "$live" ]] || return 1
    main=$(main_worktree_root "${1:-.}")
    [[ "$main" == "$live" ]]
}

# Print the base branch of the repository at <dir>: origin/HEAD's target when
# the remote advertises one, otherwise main.
live_base_branch() { # dir
    local head
    head=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -n "$head" ]]; then
        printf '%s\n' "${head#origin/}"
    else
        printf 'main\n'
    fi
}
