#!/usr/bin/env bash
# protected-branches.sh — the one parser of a repository's protected branches.
#
# Source it:
#
#     # shellcheck source=bin/lib/protected-branches.sh
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/protected-branches.sh"
#     protected_branch_list "$dir"          # per-repo list only
#     is_protected_branch "$dir" "$branch"  # fixed list plus per-repo list
#
# or run it, which is how non-bash callers (the hook's release guard) ask:
#
#     protected-branches.sh [--repo-only] <dir>
#
# prints the fixed list and the per-repo list, one name per line, or with
# --repo-only the per-repo list alone. Exit 2 on a usage error.
#
# WHY THIS EXISTS
#
# git-commit.sh, git-push-pr-merge.sh and hook-block-destructive.sh all ask
# "is this branch protected in that repository" (#312, D8). Three parsers would
# drift, and then a branch is protected for one guard and open to the next.
#
# The per-repo list comes from the first source that exists:
#   1. <repo top>/.claude/protected-branches: one name per line; blank lines
#      and everything after a # are ignored, surrounding space is trimmed
#   2. git config --get-all toolkit.protectedBranch
# The file is the single source when present; git config is not merged in, so
# "why is this branch protected" has one answer. Neither present, or <dir>
# outside a repository: the per-repo list is empty.
#
# The fixed list (develop, master, main) is what every merge and push guard has
# always protected. git-commit.sh uses the per-repo list alone, as it always has.

PROTECTED_BRANCHES_FIXED=(develop master main)

# Print the per-repo protected branches of the repository holding <dir>.
protected_branch_list() { # dir
    local dir="$1" top file line
    # --show-toplevel rather than <dir>: the file lives at the repo root, and
    # callers routinely stand in a subdirectory.
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
    file="$top/.claude/protected-branches"
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -n "$line" ]] && printf '%s\n' "$line"
        done < "$file"
    else
        git -C "$dir" config --get-all toolkit.protectedBranch 2>/dev/null | while IFS= read -r line; do
            [[ -n "$line" ]] && printf '%s\n' "$line"
        done
    fi
    return 0
}

# Succeed when <branch> is on the fixed list or the per-repo list of <dir>.
is_protected_branch() { # dir branch
    local dir="$1" branch="$2" name
    for name in "${PROTECTED_BRANCHES_FIXED[@]}"; do
        [[ "$branch" == "$name" ]] && return 0
    done
    while IFS= read -r name; do
        [[ "$branch" == "$name" ]] && return 0
    done < <(protected_branch_list "$dir")
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    repo_only=0
    if [[ "${1:-}" == "--repo-only" ]]; then
        repo_only=1
        shift
    fi
    if [[ $# -ne 1 || -z "$1" ]]; then
        echo "usage: protected-branches.sh [--repo-only] <dir>" >&2
        exit 2
    fi
    [[ "$repo_only" -eq 1 ]] || printf '%s\n' "${PROTECTED_BRANCHES_FIXED[@]}"
    protected_branch_list "$1"
fi
