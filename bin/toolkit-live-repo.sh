#!/bin/bash
# toolkit-live-repo.sh - is this repository the live toolkit checkout's?
#
# Usage: toolkit-live-repo.sh [--repo DIR]
#
# Succeeds, printing the live checkout's path, when the main worktree of the
# repository at DIR (default: the current directory) is the live toolkit
# checkout: the main worktree ~/.claude/bin points into. That holds from the
# live checkout and from each of its linked worktrees. Read-only.
#
# Skills ask this instead of rebuilding the check in prose, so the answer is
# the one bin/lib/live-checkout.sh gives every script.
#
# Options:
#   --repo DIR   Ask about the repository at DIR (avoids a leading `cd`)
#   -h, --help   Show this help and exit
#
# Exit codes: 0 live (path on stdout), 1 not live or not a repository,
#             2 usage error.

set -euo pipefail

# shellcheck source=bin/lib/live-checkout.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/live-checkout.sh"

readonly EXIT_NOT_LIVE=1
readonly EXIT_USAGE=2

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

usage_error() { # message
    echo "Error: $1" >&2
    echo "Run '$(basename "$0") --help' for usage." >&2
    exit "$EXIT_USAGE"
}

REPO_DIR="."
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --repo)
            [ $# -ge 2 ] || usage_error "--repo needs a directory"
            REPO_DIR="$2"
            shift 2
            ;;
        *) usage_error "unknown argument '$1'" ;;
    esac
done

is_live_repo "$REPO_DIR" || exit "$EXIT_NOT_LIVE"
live_checkout_root
