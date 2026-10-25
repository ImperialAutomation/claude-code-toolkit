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
#
#   dir       create <root>/<project>/<purpose> and print its absolute path
#   worktree  check <ref> out there as a detached linked worktree of D (the
#             base / pre-fix tree a container runs the tests in) and print the
#             path; refuses a purpose dir that already exists
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
#   0  done; prints the path
#   1  worktree: purpose dir exists, unknown ref, or git failed
#   2  usage error, invalid <purpose>, or --repo is not a directory (worktree:
#      not a git repository)
#
# Examples:
#   docker-scratch.sh dir --repo ~/Projects/Acme pytest-cache-42
#   docker-scratch.sh worktree --repo ~/Projects/Acme base-42 origin/develop

set -uo pipefail

SCRATCH_ROOT="${CLAUDE_SCRATCH_ROOT:-$HOME/.cache/claude-scratch}"
PURPOSE_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

usage() {
    echo "usage: $(basename "$0") dir      [--repo D] <purpose>" >&2
    echo "       $(basename "$0") worktree [--repo D] <purpose> <ref>" >&2
    exit 2
}

die_usage() { echo "$1" >&2; exit 2; }

[[ $# -ge 1 ]] || usage
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

case "$SUBCOMMAND" in
    dir) cmd_dir ;;
    worktree) cmd_worktree ;;
    *) usage ;;
esac
