#!/bin/bash
# PostToolUse hook that ensures agent-authored commits carry the
# Co-Authored-By trailer.
#
# Why this exists as a hook and not in git-commit.sh: that script is also used
# by the human maintainer from a normal terminal. Hardcoding the trailer there
# would label human commits as agent-authored, which destroys the distinction
# the `agent-authored` label (and the heightened-review gate behind it) depends
# on. A PostToolUse hook only fires when the agent commits through the Bash
# tool, so human commits stay untouched.
#
# Without the trailer, repositories that auto-apply an `agent-authored` label
# never apply it, and any required checklist gate keyed to that label never
# runs — a review gate that is green because it never executed.
#
# Advisory-but-corrective: amends the trailer in and reports on stderr so the
# agent sees what happened. Always exits 0; a failure to amend must never break
# the session.
#
# Installation: register in settings.json (project or global):
#   {
#     "hooks": {
#       "PostToolUse": [{
#         "matcher": "Bash",
#         "hooks": [{ "type": "command", "command": "~/.claude/bin/hook-post-commit-trailer.sh" }]
#       }]
#     }
#   }
#
# Skips:
#   - Bash calls that did not commit
#   - Commits that already carry the trailer
#   - Repos with no commit yet, or a detached/unborn HEAD
#   - Merge commits (the trailer belongs on the authored commit)

set -uo pipefail

TRAILER="Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"

# Resolved from BASH_SOURCE, not the cwd: hooks run from arbitrary working
# directories, and bin/ is reached through a symlink.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Exit statuses of lib/commit_target.py.
EXIT_RESOLVED=0
EXIT_UNRESOLVABLE=2
# Its second output line when a `git push` follows the commit.
PUSH_MARKER="push"

TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_ERR"' EXIT

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

# Cheap pre-filter before the parser below, which decides whether the command
# really commits (git-commit.sh or a raw `git ... commit`).
if ! echo "$COMMAND" | grep -q 'commit'; then
    exit 0
fi

# --amend --no-edit reuses an existing message; re-amending it here would loop
# on a message this hook itself just wrote.
if echo "$COMMAND" | grep -q -- '--no-edit'; then
    exit 0
fi

# Resolve the repo the commit landed in from the commit segment itself; see
# lib/commit_target.py for the order and what counts as unresolvable.
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TARGET=$(echo "$COMMAND" | python3 "$SCRIPT_DIR/lib/commit_target.py" "$CWD" 2>"$TMP_ERR")
case $? in
    "$EXIT_RESOLVED") ;;
    "$EXIT_UNRESOLVABLE")
        # Never fall back to the cwd: amending the wrong commit is not
        # recoverable, a missing trailer is.
        echo "hook: Co-Authored-By trailer not added: $(<"$TMP_ERR"); add it manually if this call committed" >&2
        exit 0
        ;;
    *) exit 0 ;;
esac
{ read -r REPO_DIR; read -r PUSH_AFTER; } <<< "$TARGET"

git -C "$REPO_DIR" rev-parse --verify HEAD &>/dev/null || exit 0

# Merge commits are not authored content.
if [[ $(git -C "$REPO_DIR" rev-list --no-walk --count --merges HEAD 2>/dev/null) == "1" ]]; then
    exit 0
fi

MESSAGE=$(git -C "$REPO_DIR" log -1 --format='%B' 2>/dev/null)
if echo "$MESSAGE" | grep -qi "^Co-Authored-By:"; then
    exit 0
fi

# Verify the commit is recent: a Bash call that merely *mentioned* commit
# (a grep over history, a --dry-run) must not rewrite an older commit.
COMMIT_AGE=$(( $(date +%s) - $(git -C "$REPO_DIR" log -1 --format='%ct' 2>/dev/null || echo 0) ))
if (( COMMIT_AGE > 120 )); then
    exit 0
fi

# A hook that rewrites a commit already pushed would desync the remote. Checked
# last, so the warning below only fires for a commit that needed the trailer.
if git -C "$REPO_DIR" branch -r --contains HEAD 2>/dev/null | grep -q .; then
    if [[ "$PUSH_AFTER" == "$PUSH_MARKER" ]]; then
        HASH=$(git -C "$REPO_DIR" rev-parse --short HEAD)
        echo "hook: commit $HASH in $REPO_DIR was pushed in the same call; the trailer was not added. On a feature branch: amend it in and force-push" >&2
    fi
    exit 0
fi

# --allow-empty: without it git refuses to amend an empty commit (a tracking-PR
# opener, for one), so exactly those commits would silently stay unlabelled.
if git -C "$REPO_DIR" commit --amend --no-edit --no-verify --allow-empty \
        --trailer "$TRAILER" &>/dev/null; then
    echo "hook: added missing '$TRAILER' to HEAD (agent-authored label depends on it)" >&2
else
    echo "hook: could not add Co-Authored-By trailer to HEAD; add it manually so the agent-authored label applies" >&2
fi

exit 0
