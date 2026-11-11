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
# Advisory-but-corrective: amends the trailer in and tells the agent what
# happened. Always exits 0; a failure to amend must never break the session.
#
# Reports go out as PostToolUse `additionalContext` JSON on stdout, which the
# model receives as a system reminder after the tool result. Not stderr: on
# exit 0 a PostToolUse hook's stderr never reaches the model, and the agent that
# made the commit is the one that can fix it cheaply, before pushing. Not exit
# 2: an advisory should not be presented as a hook error. Stdout therefore
# carries nothing but that JSON; no other command below writes to stdout.
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
# Target repo, taken from the commit segment of the command itself (never from
# another segment of the chain), first match wins:
#   1. git-commit.sh --repo <dir> / --repo=<dir>
#   2. the -C <dir> of the `git ... commit` segment
#   3. the session cwd, moved by a `cd <dir>` segment before the commit or an
#      `env -C <dir>` prefix on the commit segment
# Parsing lives in lib/commit_target.py, which reuses the approve hook's
# tokenizer so quotes and separators are read the same way. It also decides
# which commands commit: git-commit.sh and `git commit`, and `git revert`,
# `cherry-pick` and `merge` unless they ran with --no-commit or an equivalent.
#
# Skips silently:
#   - Bash calls that did not commit
#   - Commits that already carry the trailer
#   - Repos with no commit yet, or a detached/unborn HEAD
#   - A merge commit HEAD after `git commit`, revert or cherry-pick (none of
#     them made it; the trailer belongs on the authored commit)
#   - A non-merge HEAD after `git merge` (a fast-forward made no commit)
#   - `git commit --amend --no-edit` (reuses an existing message as is)
#   - Commits older than 120 s
#   - Pushed commits, when the command did not push them
#
# Skips with a message to the model, so a missing trailer does not go unnoticed:
#   - An unresolvable target: a shell variable or backtick in it, a directory
#     that does not exist, several commit segments with different targets, or a
#     command that does not tokenize. Never falls back to the cwd: amending the
#     wrong commit cannot be undone, a missing trailer can.
#   - A commit pushed by a `git push` later in the same call (names the hash)

set -uo pipefail

# Model-neutral on purpose: the PostToolUse payload carries no model name, so
# any specific name here would misattribute every commit made by another model.
TRAILER="Co-Authored-By: Claude <noreply@anthropic.com>"

# Resolved from BASH_SOURCE, not the cwd: hooks run from arbitrary working
# directories, and bin/ is reached through a symlink.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Exit statuses of lib/commit_target.py.
EXIT_RESOLVED=0
EXIT_UNRESOLVABLE=2
# Its second output line when a `git push` follows the commit.
PUSH_MARKER="push"
# Its third output line when the last commit segment is a `git merge`.
KIND_MERGE="merge"

TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_ERR"' EXIT

# Tells the model: one additionalContext object on stdout. jq --arg keeps quotes
# and newlines in the message from breaking the JSON.
report() { # message
    jq -cn --arg msg "$1" \
        '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}'
}

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

# Cheap pre-filter before the parser below, which decides whether the command
# really commits (git-commit.sh, or `git commit|revert|cherry-pick|merge`
# without a no-commit option; `commit --amend --no-edit` does not count).
if ! echo "$COMMAND" | grep -qE 'commit|revert|cherry-pick|merge'; then
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
        report "hook: Co-Authored-By trailer not added: $(<"$TMP_ERR"); add it manually if this call committed"
        exit 0
        ;;
    *) exit 0 ;;
esac
{ read -r REPO_DIR; read -r PUSH_AFTER; read -r KIND; } <<< "$TARGET"

git -C "$REPO_DIR" rev-parse --verify HEAD &>/dev/null || exit 0

# A `git merge` gets the trailer on the merge commit it made; a non-merge HEAD
# means it fast-forwarded and made nothing. Any other command makes no merge
# commit, so a merge HEAD there is not this call's work.
IS_MERGE=0
[[ $(git -C "$REPO_DIR" rev-list --no-walk --count --merges HEAD 2>/dev/null) == "1" ]] && IS_MERGE=1
if [[ "$KIND" == "$KIND_MERGE" ]]; then
    (( IS_MERGE )) || exit 0
else
    (( IS_MERGE )) && exit 0
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
        report "hook: commit $HASH in $REPO_DIR was pushed in the same call; the trailer was not added. On a feature branch: amend it in and force-push"
    fi
    exit 0
fi

# --allow-empty: without it git refuses to amend an empty commit (a tracking-PR
# opener, for one), so exactly those commits would silently stay unlabelled.
if git -C "$REPO_DIR" commit --amend --no-edit --no-verify --allow-empty \
        --trailer "$TRAILER" &>/dev/null; then
    report "hook: added missing '$TRAILER' to HEAD of $REPO_DIR, so its SHA changed (agent-authored label depends on it)"
else
    report "hook: could not add Co-Authored-By trailer to HEAD of $REPO_DIR; add it manually so the agent-authored label applies"
fi

exit 0
