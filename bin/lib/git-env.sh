#!/usr/bin/env bash
# git-env.sh — clear the git environment that redirects repository discovery.
#
# Source this, then call git_env_isolate before the git call it guards:
#
#     # shellcheck source=bin/lib/git-env.sh
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
#     top=$(git_env_isolate && git -C "$dir" rev-parse --show-toplevel)
#
# WHY THIS EXISTS
#
# A script that decides something from `git -C <dir> ...` (which repository a
# tree belongs to, which worktrees it has) gets the answer for <dir> only when
# nothing in the environment overrides discovery. An exported GIT_DIR,
# GIT_COMMON_DIR, GIT_WORK_TREE and the like make git describe another
# repository instead, silently (#338). A prompt-free script that admits a tree
# on such an answer can then be steered into an unrelated one.
#
# The set comes from git itself: `git rev-parse --local-env-vars` lists every
# repository-local variable of the installed git, so a variable a later git
# adds is covered without an edit here. That list leaves out the two discovery
# controls below, which are added by name.

# Variables that change how git discovers a repository but are not in the
# --local-env-vars list.
GIT_ENV_DISCOVERY_VARS=(GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM)

# Unset every repository-local git variable and the discovery controls in the
# calling shell. Fails, changing nothing, when git cannot list them or one of
# them is readonly. Call it in a subshell (`( git_env_isolate && git ... )`,
# `$(git_env_isolate && git ...)`) to clear only that git call's environment.
git_env_isolate() {
    local vars v decl names=()
    vars=$(git rev-parse --local-env-vars 2>/dev/null) && [[ -n "$vars" ]] || return 1
    # One name per line; read as lines so the caller's IFS does not matter.
    mapfile -t names <<<"$vars"
    names+=("${GIT_ENV_DISCOVERY_VARS[@]}")
    for v in "${names[@]}"; do
        decl=$(declare -p "$v" 2>/dev/null) || continue
        decl=${decl#declare -}
        [[ "${decl%% *}" == *r* ]] && return 1
    done
    unset "${names[@]}"
}
