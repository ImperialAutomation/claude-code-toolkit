#!/bin/bash
# PostToolUse hook that removes [branch "<name>"] sections left behind in the
# repository config after a branch was deleted.
#
# Why this exists as a hook: inside the Claude Code sandbox, git cannot write
# .git/config at all (it is mounted read-only and .git/config.lock is masked).
# That is deliberate: a writable config is a sandbox escape, because
# core.hooksPath, core.fsmonitor, core.sshCommand or an alias set from inside
# runs later in unsandboxed git. The side effect is that `git branch -d` deletes
# the ref but leaves its config section, and removing it costs an unsandboxed
# command per branch. Hooks run outside the per-command sandbox, so this one can
# do that single cleanup without opening the config to anything else.
#
# What it removes is derived from repository state, never from the command: a
# section goes only when refs/heads/<name> does not exist. The command text
# merely selects which repository to look at and whether to look at all.
#
# Advisory-but-corrective: reports removals on stderr, always exits 0. A
# cleanup hook must never break the session.
#
# Installation: register in settings.json (project or global):
#   {
#     "hooks": {
#       "PostToolUse": [{
#         "matcher": "Bash",
#         "hooks": [{ "type": "command", "command": "~/.claude/bin/hook-post-prune-branch-config.sh" }]
#       }]
#     }
#   }
#
# Acts only after:
#   - git-cleanup-merged-branch.sh
#   - git [-C <dir>] branch with -d, -D (also combined, e.g. -df) or --delete

set -uo pipefail

readonly CLEANUP_SCRIPT_RE='git-cleanup-merged-branch\.sh'
# `git branch` at the start of a command (not merely mentioned, as in an echo),
# up to the next shell separator, with a delete flag in it.
readonly BRANCH_DELETE_RE='(^|[;&|(] *)git( +-C +[^ ;&|]+)? +branch[^;&|]* (-[A-Za-z]*[dD][A-Za-z]*|--delete)( |$)'

INPUT=$(cat)

COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null)
[[ -z "$COMMAND" ]] && exit 0

if ! grep -qE "$CLEANUP_SCRIPT_RE|$BRANCH_DELETE_RE" <<<"$COMMAND"; then
    exit 0
fi

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)

# The repository the command operated on: an explicit `git -C <dir>` or
# `--repo <dir>` wins, otherwise the session's working directory.
REPO_DIR=$(grep -oE '(git +-C|--repo) +[^ ;&|]+' <<<"$COMMAND" | head -1 | awk '{print $NF}')
REPO_DIR="${REPO_DIR:-$CWD}"
REPO_DIR="${REPO_DIR/#\~/$HOME}"
if [[ -n "$REPO_DIR" && "$REPO_DIR" != /* && -n "$CWD" ]]; then
    REPO_DIR="$CWD/$REPO_DIR"
fi
[[ -z "$REPO_DIR" || ! -d "$REPO_DIR" ]] && exit 0

# Linked worktrees share the main repository's config.
COMMON_DIR=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
CONFIG="$COMMON_DIR/config"
[[ -f "$CONFIG" ]] || exit 0

# Keys look like branch.<name>.<var>; <name> may itself contain dots and
# slashes, <var> never contains a dot.
declare -A SEEN=()
while IFS= read -r key; do
    name="${key#branch.}"
    name="${name%.*}"
    [[ -z "$name" || -n "${SEEN[$name]:-}" ]] && continue
    SEEN[$name]=1

    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$name"; then
        continue
    fi
    if git config --file "$CONFIG" --remove-section "branch.$name" 2>/dev/null; then
        echo "hook: removed stale [branch \"$name\"] section from $CONFIG (branch no longer exists)" >&2
    fi
done < <(git config --file "$CONFIG" --name-only --get-regexp '^branch\..+\.[^.]+$' 2>/dev/null)

exit 0
