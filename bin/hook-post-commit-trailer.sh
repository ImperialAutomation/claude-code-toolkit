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

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

# Only act on commands that actually create a commit. git-commit.sh is the
# sanctioned path; raw `git commit` is matched too so the trailer does not
# depend on which one was used.
if ! echo "$COMMAND" | grep -qE '(git-commit\.sh|git +(-C +[^ ]+ +)?commit)'; then
    exit 0
fi

# --amend --no-edit reuses an existing message; re-amending it here would loop
# on a message this hook itself just wrote.
if echo "$COMMAND" | grep -q -- '--no-edit'; then
    exit 0
fi

# Resolve the repo the command operated on: an explicit `git -C <dir>` wins,
# otherwise the working directory of the session.
REPO_DIR=$(echo "$COMMAND" | grep -oE 'git +-C +[^ ]+' | head -1 | awk '{print $3}')
if [[ -z "$REPO_DIR" ]]; then
    REPO_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
fi
[[ -z "$REPO_DIR" || ! -d "$REPO_DIR" ]] && exit 0

git -C "$REPO_DIR" rev-parse --verify HEAD &>/dev/null || exit 0

# A hook that rewrites a commit already pushed would desync the remote.
if git -C "$REPO_DIR" branch -r --contains HEAD 2>/dev/null | grep -q .; then
    exit 0
fi

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

if git -C "$REPO_DIR" commit --amend --no-edit --no-verify \
        --trailer "$TRAILER" &>/dev/null; then
    echo "hook: added missing '$TRAILER' to HEAD (agent-authored label depends on it)" >&2
else
    echo "hook: could not add Co-Authored-By trailer to HEAD; add it manually so the agent-authored label applies" >&2
fi

exit 0
