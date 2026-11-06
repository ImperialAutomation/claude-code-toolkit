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
# nothing is live and both functions report nothing.

# Print the live checkout's absolute top level, or nothing when there is none.
live_checkout_root() {
    local link="$HOME/.claude/bin" target root main_root

    [[ -L "$link" ]] || return 0
    target=$(readlink -f "$link" 2>/dev/null) || return 0
    root=$(git -C "$(dirname "$target")" rev-parse --show-toplevel 2>/dev/null) || return 0
    [[ "$root" == "$(dirname "$target")" ]] || return 0

    # Only the main worktree counts: a symlink pointing into a linked worktree
    # is unusual, but treating that tree as live would forbid working in it.
    main_root=$(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    [[ "$main_root" == "$root" ]] || return 0

    printf '%s\n' "$root"
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
