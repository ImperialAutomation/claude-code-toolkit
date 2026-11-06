#!/usr/bin/env bash
# docker-scratch.sh: a scratch location a Docker container can mount.
#
# Session scratch belongs in the scratchpad or /tmp, but Docker Desktop shares
# $HOME with its VM and not /tmp: `docker run -v /tmp/x:/app` fails with "mounts
# denied: the path is not shared from the host". Without a documented
# alternative the agent improvises one, and whole base checkouts end up in
# ~/Downloads, where nobody cleans them up. This script gives that one case a
# fixed place under $HOME that is outside every project tree (so test discovery,
# linters and `docker build .` never see it) and a cleanup that needs no prompt.
#
# Usage:
#   docker-scratch.sh dir      [--repo D] <purpose>
#   docker-scratch.sh worktree [--repo D] <purpose> <ref>
#   docker-scratch.sh clean    [--repo D] <purpose> | --all
#
#   dir       create <root>/<project>/<purpose> and print its absolute path
#   worktree  check <ref> out there as a detached linked worktree of D (the
#             base / pre-fix tree a container runs the tests in) and print the
#             path; refuses a purpose dir that already exists
#   clean     remove one purpose dir, or with --all every one of this project.
#             A linked worktree is removed through git, so it does not linger in
#             `git worktree list`. Nothing outside <root>/<project> is touched:
#             <purpose> is validated, so the rm cannot be pointed elsewhere.
#             Something that is not there is reported, not an error.
#
#   <root>     $CLAUDE_SCRATCH_ROOT, default ~/.cache/claude-scratch
#   <project>  basename of the repo's MAIN worktree (so a linked worktree such
#              as Acme-dev1 shares the scratch dir of Acme), or of D itself when
#              D is not a git repo; lowercased, other characters than [a-z0-9]
#              replaced by '-', like the /tmp/<project>-... names
#   <purpose>  one path component: [A-Za-z0-9][A-Za-z0-9._-]*, e.g. base-42
#   --repo D   the tree that decides <project>; default the current directory
#
# Exit codes:
#   0  done; dir/worktree print the path, clean prints what it removed
#   1  worktree: purpose dir exists, unknown ref, or git failed;
#      clean: something could not be removed (typically files a container wrote
#      as root into the mount on native Linux Docker; Docker Desktop maps them
#      to your own user, so there it does not occur)
#   2  usage error, invalid <purpose>, or --repo is not a directory (worktree:
#      not a git repository)
#
# Rules of use:
#   - Only for what a container must mount. Everything else stays in the
#     scratchpad or /tmp; ~/Downloads, ~ and the project tree stay off limits,
#     also when a mount fails.
#   - Paste the printed path literally into `docker run -v`, no $(...).
#   - Run `clean` as soon as the container is done. It needs no prompt; a bare
#     `rm -rf` does, and outside /tmp hook-block-destructive.sh refuses it.
#   - `clean` exit 1 (root-owned files from a container): report it, and do not
#     move the tree somewhere else.
#
# Examples:
#   docker-scratch.sh dir --repo ~/Projects/Acme pytest-cache-42
#   docker-scratch.sh worktree --repo ~/Projects/Acme base-42 origin/develop
#   docker run --rm -v <printed path>:/app ...    # the path, pasted literally
#   docker-scratch.sh clean --repo ~/Projects/Acme base-42

set -uo pipefail

SCRATCH_ROOT="${CLAUDE_SCRATCH_ROOT:-$HOME/.cache/claude-scratch}"
PURPOSE_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

usage() {
    echo "usage: $(basename "$0") dir      [--repo D] <purpose>" >&2
    echo "       $(basename "$0") worktree [--repo D] <purpose> <ref>" >&2
    echo "       $(basename "$0") clean    [--repo D] <purpose> | --all" >&2
    exit 2
}

die_usage() { echo "$1" >&2; exit 2; }

[[ $# -ge 1 ]] || usage
case "$1" in
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac
SUBCOMMAND="$1"; shift

REPO="$PWD"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || usage; REPO="$2"; shift 2 ;;
        --repo=*) REPO="${1#--repo=}"; shift ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

[[ -d "$REPO" ]] || die_usage "--repo is not a directory: $REPO"
REPO=$(cd "$REPO" && pwd)

# The main worktree is the parent of the common git dir; a non-git directory
# stands for itself.
project_name() {
    local common base
    if common=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        base=$(basename "$(dirname "$common")")
    else
        base=$(basename "$REPO")
    fi
    printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-'
}

# Refusing anything but one plain path component is what keeps every rm in this
# script inside the root: no '/', no '..', no leading '-' or '.'.
purpose_dir() {
    [[ "$1" =~ $PURPOSE_RE ]] || die_usage "invalid purpose '$1': use one path component matching $PURPOSE_RE"
    printf '%s/%s/%s' "$SCRATCH_ROOT" "$(project_name)" "$1"
}

cmd_dir() {
    [[ ${#ARGS[@]} -eq 1 ]] || usage
    local dir
    dir=$(purpose_dir "${ARGS[0]}") || exit 2
    mkdir -p "$dir" || exit 1
    printf '%s\n' "$dir"
}

cmd_worktree() {
    [[ ${#ARGS[@]} -eq 2 ]] || usage
    git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die_usage "--repo is not a git repository: $REPO"
    local dir ref="${ARGS[1]}"
    dir=$(purpose_dir "${ARGS[0]}") || exit 2
    if [[ -e "$dir" ]]; then
        echo "already exists, refusing to reuse it: $dir (remove it with: $(basename "$0") clean ${ARGS[0]})" >&2
        exit 1
    fi
    # Resolve the ref before git creates anything, so a typo leaves no
    # half-made directory behind.
    git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { echo "unknown ref: $ref" >&2; exit 1; }
    mkdir -p "$(dirname "$dir")" || exit 1
    git -C "$REPO" worktree add --quiet --detach "$dir" "$ref" >&2 || exit 1
    printf '%s\n' "$dir"
}

# A linked worktree has a .git FILE. Removing it through git also drops its
# entry under .git/worktrees; a bare rm -rf would leave that entry behind, and
# `git worktree list` would keep showing a checkout that no longer exists.
# --force twice: also when it has untracked or modified files, or is locked.
remove_one() {
    local target="$1" common=""
    # A symlink is removed as a link and never followed: the tests below would
    # look through it, and git would then remove the worktree it points at,
    # wherever that is.
    if [[ -L "$target" ]]; then
        rm -f "$target" 2>/dev/null
        if [[ -L "$target" ]]; then
            echo "could not remove symlink $target" >&2
            return 1
        fi
        echo "removed symlink $target"
        return 0
    fi
    if [[ -f "$target/.git" ]] \
        && common=$(git -C "$target" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        git --git-dir="$common" worktree remove --force --force "$target" >/dev/null 2>&1
    fi
    [[ -e "$target" ]] && rm -rf "$target" 2>/dev/null
    [[ -n "$common" ]] && git --git-dir="$common" worktree prune 2>/dev/null
    if [[ -e "$target" ]]; then
        echo "could not remove $target (files a container wrote as root? remove them from inside a container, or ask the user)" >&2
        return 1
    fi
    echo "removed $target"
}

cmd_clean() {
    [[ ${#ARGS[@]} -eq 1 ]] || usage
    local project_dir target rc=0
    project_dir="$SCRATCH_ROOT/$(project_name)"
    # Through a symlinked project dir every rm below would land in its target.
    [[ -L "$project_dir" ]] && { echo "refusing: $project_dir is a symlink" >&2; return 1; }
    if [[ "${ARGS[0]}" == "--all" ]]; then
        [[ -d "$project_dir" ]] || { echo "nothing to clean: $project_dir"; return 0; }
        shopt -s nullglob dotglob
        for target in "$project_dir"/*; do
            remove_one "$target" || rc=1
        done
        shopt -u nullglob dotglob
        [[ $rc -eq 0 ]] && rmdir "$project_dir" 2>/dev/null
        return $rc
    fi
    target=$(purpose_dir "${ARGS[0]}") || exit 2
    [[ -e "$target" || -L "$target" ]] || { echo "nothing to clean: $target"; return 0; }
    remove_one "$target"
}

case "$SUBCOMMAND" in
    dir) cmd_dir ;;
    worktree) cmd_worktree ;;
    clean) cmd_clean ;;
    *) usage ;;
esac
