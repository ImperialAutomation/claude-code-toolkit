#!/bin/bash
# Pre-tool-use hook that blocks destructive Bash commands.
#
# Designed for use with Claude Code's bypass-permissions mode as a safety net.
# Works in all permission modes — hooks always run regardless of permission settings.
#
# Installation: register in settings.json (project or global):
#   {
#     "hooks": {
#       "PreToolUse": [{
#         "matcher": "Bash",
#         "hooks": [{ "type": "command", "command": "~/.claude/hooks/block-destructive.sh" }]
#       }]
#     }
#   }
#
# Exit codes:
#   0 = allow
#   2 = block (reason sent to stderr, shown to Claude)

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
    exit 0
fi

# Guard: force-recursive rm of an absolute path, EXCEPT below /tmp.
#
# Replaces the old substring patterns ("rm -rf /", "rm -rf /[a-z]", "rm -rf ~",
# "rm -rf $HOME"), which had two problems:
#   1. Every scratch cleanup under /tmp was blocked — agents write their temp
#      files there by convention, so deleting them is routine, not destructive.
#      That false positive is what prompted this change.
#   2. A single substring regex cannot express "EVERY path operand must be
#      safe", so `rm -rf /tmp/a /usr` would pass on the strength of its first
#      operand. Checking each operand fixes that.
#
# Still blocked, deliberately: bare `/tmp` and `/tmp/` (wiping the whole scratch
# dir kills other concurrent agents' files), every other absolute path, and `~`
# / `~/...` (the old `rm -rf ~` pattern required a trailing space, so `~/Projects`
# slipped through — closed here).
#
# Relative paths (./build, node_modules) were never matched and still aren't:
# they are scoped to the working directory and are ordinary build hygiene.
_rm_hits_protected_path() {
    local segment token
    while IFS= read -r segment; do
        echo "$segment" | grep -qE '(^|[[:space:]])rm([[:space:]]|$)' || continue
        # Require BOTH recursive and force flags, in any order or combination.
        echo "$segment" | grep -qE '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)' || continue
        echo "$segment" | grep -qE '(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)' || continue
        for token in $segment; do
            # SC2088 (tilde in quotes) is intentional below: we match a LITERAL
            # ~ in the command text. Expanding it would defeat the check, since
            # the tilde reaches this hook unexpanded.
            # shellcheck disable=SC2088
            case "$token" in
                rm|-*) continue ;;
                /tmp/?*) continue ;;   # a path UNDER /tmp: allowed
                /*) return 0 ;;        # any other absolute path
                '~'|'~/'*) return 0 ;; # home directory (literal ~, see above)
            esac
        done
    done < <(echo "$COMMAND" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g')
    return 1
}

if _rm_hits_protected_path; then
    echo "BLOCKED by hook-block-destructive.sh: refusing a force-recursive rm of an absolute path outside /tmp. Deleting scratch files UNDER /tmp (e.g. /tmp/my-workdir) is allowed; wiping /tmp itself, a home path, or any other absolute path needs the user's explicit go-ahead." >&2
    exit 2
fi

# Patterns for destructive operations
BLOCKED_PATTERNS=(
    # Filesystem destruction
    "rm -rf \\$HOME"
    # Git destructive operations
    "git push.*--force"
    "git push.* -f( |$)"
    "git reset.*--hard"
    "git checkout -- \\."
    "git clean.* -f( |$)"
    # Database destruction
    "DROP TABLE"
    "DROP DATABASE"
    "TRUNCATE"
    "DELETE FROM.*WITHOUT.*WHERE"
    # Process/system
    "kill -9 1$"
    "killall"
    "shutdown"
    "reboot"
    "mkfs"
    "dd if=.* of=/dev/"
)

# Case-sensitive patterns: only block uppercase forms (e.g. -D force delete, not -d safe delete)
CASE_SENSITIVE_PATTERNS=(
    "git branch.*-D"
)

# Guard: never auto-merge a PR into a protected base branch.
# Blocks git-push-pr-merge.sh targeting develop/master/main UNLESS --no-merge is set.
# Epic sub-issue PRs (--base <feature_branch>) are unaffected; only the shared
# integration branches are protected. The agent must leave those PRs for the user
# to review and merge manually. See implement / implement-epic skill rules.
if echo "$COMMAND" | grep -qE 'git-push-pr-merge\.sh'; then
    if echo "$COMMAND" | grep -qE -- '--base[= ]+(develop|master|main)([[:space:]]|$)'; then
        if ! echo "$COMMAND" | grep -qE -- '--no-merge'; then
            echo "BLOCKED by hook-block-destructive.sh: refusing to auto-merge a PR into a protected base branch (develop/master/main). This repo has no server-side branch protection (private/free tier), so merges to integration branches are the user's call. Re-run with --no-merge to open the PR for review, or ask the user to merge it." >&2
            exit 2
        fi
    fi
fi

# Guard: never run a raw `git merge` while ON a protected base branch.
# Merging INTO feature/epic branches is fine (that is the normal sync direction,
# e.g. develop -> epic branch). But a merge whose TARGET is develop/master/main
# must go through a reviewed PR the user merges manually — this repo has no
# server-side branch protection (private/free tier). A static permission pattern
# can't see the current branch, so the check lives here. The sanctioned wrapper
# git-merge-branch.sh enforces the same rule; this catches raw `git merge` too.
#
# Only match `git merge` when it STARTS a command segment — at line start or
# right after a separator (; && || | & newline). This avoids false positives
# where the substring "git merge" appears inside a quoted argument, e.g. a
# commit message (git-commit.sh "feat: block raw git merge ...") or an echo.
# We can't fully parse the shell, but anchoring to segment boundaries kills the
# common cases. A leading-whitespace-after-separator allowance keeps it matching
# `... && git merge ...`. Note `--no-edit` etc. are still caught (trailing \b).
if echo "$COMMAND" | grep -qE '(^|[;&|]|&&|\|\|)[[:space:]]*git[[:space:]]+merge([[:space:]]|$)'; then
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)
    case "$CURRENT_BRANCH" in
        develop|master|main)
            echo "BLOCKED by hook-block-destructive.sh: refusing 'git merge' while on protected branch '$CURRENT_BRANCH'. Merges INTO develop/master/main must go through a reviewed PR the user merges manually. To sync changes the other way (e.g. develop into a feature/epic branch), checkout that branch first — git-merge-branch.sh <source> does this with the same guard." >&2
            exit 2
            ;;
    esac
fi

# Guard: never merge a PR into a protected base branch via raw `gh pr merge`.
# Mirrors the git-push-pr-merge.sh guard above, but for the bare gh CLI, which
# carries no --base (the PR already knows its base). We resolve the PR's base via
# the API: an explicit PR number/URL as the gh arg, else the PR for the current
# branch. Merges into a feature/epic base stay allowed (epic flow); only
# develop/master/main are the user's call to merge manually. On any lookup
# failure we fail closed (block) — a merge command we can't classify is exactly
# the one to stop. Only matches `gh pr merge` at a command-segment boundary, so
# the substring inside a quoted arg (commit message, echo) is not caught.
if echo "$COMMAND" | grep -qE '(^|[;&|]|&&|\|\|)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
    # Extract an explicit PR ref (number or URL) following `gh pr merge`, if any.
    PR_REF=$(echo "$COMMAND" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[^[:space:]]+' | awk '{print $4}' || true)
    case "$PR_REF" in
        -*) PR_REF="" ;;  # a flag, not a PR ref → fall back to current branch
    esac
    PR_BASE=$(gh pr view ${PR_REF:+"$PR_REF"} --json baseRefName --jq '.baseRefName' 2>/dev/null || true)
    if [ -z "$PR_BASE" ]; then
        echo "BLOCKED by hook-block-destructive.sh: refusing 'gh pr merge' — could not resolve the PR's base branch to verify it isn't a protected one (develop/master/main). Merges into integration branches are the user's call; this repo has no server-side branch protection. Ask the user to merge it." >&2
        exit 2
    fi
    case "$PR_BASE" in
        develop|master|main)
            echo "BLOCKED by hook-block-destructive.sh: refusing 'gh pr merge' into protected base branch '$PR_BASE'. Merges into develop/master/main must go through a PR the user reviews and merges manually (HIL). Leave the PR open for the user." >&2
            exit 2
            ;;
    esac
fi

for pattern in "${CASE_SENSITIVE_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -E "$pattern" > /dev/null 2>&1; then
        echo "BLOCKED by hook-block-destructive.sh: command matches destructive pattern '$pattern'. Rephrase or ask the user for explicit permission." >&2
        exit 2
    fi
done

for pattern in "${BLOCKED_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -iE "$pattern" > /dev/null 2>&1; then
        echo "BLOCKED by hook-block-destructive.sh: command matches destructive pattern '$pattern'. Rephrase or ask the user for explicit permission." >&2
        exit 2
    fi
done

exit 0
