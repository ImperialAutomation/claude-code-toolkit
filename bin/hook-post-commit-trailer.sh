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
#   2. the -C <dir> of the `git ... <sub>` segment, where <sub> is commit,
#      revert, cherry-pick or merge
#   3. the session cwd, moved by a `cd <dir>` segment before the commit or an
#      `env -C <dir>` prefix on the commit segment
# Parsing lives in lib/commit_target.py, which reuses the approve hook's
# tokenizer so quotes and separators are read the same way. It also decides
# which commands may commit: git-commit.sh and `git commit`, and `git revert`,
# `cherry-pick` and `merge` unless they ran with --no-commit or an equivalent.
#
# Whether the call really created HEAD is read from HEAD's reflog, not guessed
# from the command text: the newest entry must be fresh and of a kind one of
# the command's subcommands writes (`commit`, `commit (merge)`, `revert:`,
# `cherry-pick:`, `merge ...: Merge made by ...`). A fast-forward (merge or
# cherry-pick --ff) or a call that moved nothing leaves no such entry, so a
# commit someone else made is never amended for it. A conflicted merge or
# cherry-pick concluded with `git commit` writes `commit (merge)` /
# `commit (cherry-pick)` and does get the trailer. What this cannot tell apart
# is an identical fresh entry from another session in the same worktree (#292).
#
# Skips silently:
#   - Bash calls that did not commit
#   - Commits that already carry the Claude trailer (another Co-Authored-By,
#     such as one a cherry-pick copies from the original, does not count)
#   - Repos with no commit yet, or a detached/unborn HEAD
#   - A HEAD whose newest reflog entry no commit segment of the call writes,
#     or that is older than 120 s
#   - `git commit --amend --no-edit` (reuses an existing message as is)
#   - Pushed commits, when the command did not push them
#
# Skips with a message to the model, so a missing trailer does not go unnoticed:
#   - An unresolvable target: a shell variable or backtick in it, a directory
#     that does not exist, several commit segments with different targets, or a
#     command that does not tokenize. Never falls back to the cwd: amending the
#     wrong commit cannot be undone, a missing trailer can.
#   - A HEAD without a reflog (nothing to tell whether the call made it)
#   - A commit pushed by a `git push` later in the same call (names the hash)
#   - A git-commit.sh call whose output (tool_response) lacks git's
#     "[branch <sha>]" summary line for HEAD: the script refused or failed, so
#     HEAD may be someone else's commit, or the output was cut off
#
# Only HEAD is amended. When the call made several commits (a range revert or
# cherry-pick, a commit followed by a merge), the message names the others
# that lack the trailer: amending them would rewrite more history.

set -uo pipefail

# Model-neutral on purpose: the PostToolUse payload carries no model name, so
# any specific name here would misattribute every commit made by another model.
TRAILER="Co-Authored-By: Claude <noreply@anthropic.com>"
# Any Claude trailer counts as present, whatever model name git-commit.sh or
# the agent wrote in it; a Co-Authored-By of someone else does not.
CLAUDE_TRAILER_RE='^Co-Authored-By:.*<noreply@anthropic\.com>'
# A commit this call made is at most this old (seconds, by its reflog entry).
MAX_AGE=120
# How many HEAD reflog entries to read when counting the call's new commits.
REFLOG_SCAN_LIMIT=100

# Resolved from BASH_SOURCE, not the cwd: hooks run from arbitrary working
# directories, and bin/ is reached through a symlink.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Exit statuses of lib/commit_target.py.
EXIT_RESOLVED=0
EXIT_UNRESOLVABLE=2
# Its second output line when a `git push` follows the commit.
PUSH_MARKER="push"
# Its third output line: the subcommands that may have committed.
SUB_COMMIT="commit"
SUB_REVERT="revert"
SUB_CHERRY_PICK="cherry-pick"
SUB_MERGE="merge"
# Its fourth output line when every commit segment is git-commit.sh.
WRAPPER_MARKER="wrapper"

TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_ERR"' EXIT

# Tells the model: one additionalContext object on stdout. jq --arg keeps quotes
# and newlines in the message from breaking the JSON.
report() { # message
    jq -cn --arg msg "$1" \
        '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}'
}

# The subcommands that write a HEAD reflog entry with this subject for a new
# commit; nothing for an entry that created none (a fast-forward, a checkout,
# a reset). `git revert --continue` writes a plain `commit:` entry; the caller
# accepts that for revert on the newest entry only, so a revert does not claim
# older commits of the session as its own.
reflog_creators() { # subject
    case "$1" in
        "$SUB_CHERRY_PICK: fast-forward") ;;
        "$SUB_CHERRY_PICK: "*) echo "$SUB_CHERRY_PICK" ;;
        "$SUB_REVERT: "*) echo "$SUB_REVERT" ;;
        "$SUB_MERGE "*": Fast-forward") ;;
        "$SUB_MERGE "*": "*) echo "$SUB_MERGE" ;;
        "$SUB_COMMIT ($SUB_MERGE): "*) echo "$SUB_COMMIT $SUB_MERGE" ;;
        "$SUB_COMMIT ($SUB_CHERRY_PICK): "*) echo "$SUB_COMMIT $SUB_CHERRY_PICK" ;;
        "$SUB_COMMIT: "*|"$SUB_COMMIT (initial): "*|"$SUB_COMMIT (amend): "*) echo "$SUB_COMMIT" ;;
    esac
}

# True if one of the given subcommands is among the command's ($KINDS).
in_kinds() { # subcommands (space-separated)
    local sub
    for sub in $1; do
        [[ " $KINDS " == *" $sub "* ]] && return 0
    done
    return 1
}

has_claude_trailer() { # repo rev
    git -C "$1" log -1 --format='%B' "$2" 2>/dev/null | grep -qiE "$CLAUDE_TRAILER_RE"
}

# True when the call's output holds git's commit summary line,
# "[<branch> <sha>] <subject>", for the current HEAD of the repo. The prefix
# match takes any abbreviation length git chose.
output_names_head() { # repo output
    local full abbrev
    full=$(git -C "$1" rev-parse HEAD 2>/dev/null) || return 1
    while read -r abbrev; do
        [[ -n "$abbrev" && "$full" == "$abbrev"* ]] && return 0
    done < <(grep -oE '^\[[^]]* [0-9a-f]{7,40}\]' <<< "$2" | grep -oE '[0-9a-f]{7,40}\]$' | tr -d ']')
    return 1
}

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

# Cheap pre-filter before the parser below (which loads the approve hook's
# module), so `git log --merges`, `gh pr merge` or `grep merge` do not start
# python3. The parser decides whether the command really commits.
if ! echo "$COMMAND" | grep -qE 'git-commit\.sh|\bgit\b.*\b(commit|revert|cherry-pick|merge)\b'; then
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
{ read -r REPO_DIR; read -r PUSH_AFTER; read -r KINDS; read -r WRAPPER_ONLY; } <<< "$TARGET"

HEAD_SHA=$(git -C "$REPO_DIR" rev-parse --verify HEAD 2>/dev/null) || exit 0

# HEAD's reflog, newest first: "<selector with unix time> <sha> <subject>".
REFLOG=$(git -C "$REPO_DIR" log -g --date=unix --format='%gd %H %gs' \
    -n "$REFLOG_SCAN_LIMIT" HEAD 2>/dev/null)
if [[ -z "$REFLOG" ]]; then
    report "hook: Co-Authored-By trailer not added: HEAD of $REPO_DIR has no reflog, so the hook cannot tell whether this call made it; add it manually if this call committed"
    exit 0
fi

# The commits this call made: the run of fresh entries at the top of the
# reflog that a commit segment of the call writes. A Bash call that merely
# mentioned commit (a grep over history, a --dry-run), a fast-forward, or a
# failed commit leaves no such entry on top, and the hook stops there.
NOW=$(date +%s)
NEW_COMMITS=()
while read -r SELECTOR SHA SUBJECT; do
    STAMP=${SELECTOR##*@\{}
    STAMP=${STAMP%\}}
    [[ "$STAMP" =~ ^[0-9]+$ ]] || break
    (( NOW - STAMP > MAX_AGE )) && break
    CREATORS=$(reflog_creators "$SUBJECT")
    # `git revert --continue` concludes with a plain commit entry.
    if (( ${#NEW_COMMITS[@]} == 0 )) && [[ "$CREATORS" == "$SUB_COMMIT" ]]; then
        CREATORS="$SUB_COMMIT $SUB_REVERT"
    fi
    in_kinds "$CREATORS" || break
    NEW_COMMITS+=("$SHA")
done <<< "$REFLOG"
(( ${#NEW_COMMITS[@]} )) && [[ "${NEW_COMMITS[0]}" == "$HEAD_SHA" ]] || exit 0

# The call's other new commits still in HEAD's history without the trailer.
# Reported, not amended: that would rewrite more than the commit just made.
OTHERS=()
for SHA in "${NEW_COMMITS[@]:1}"; do
    [[ "$SHA" == "$HEAD_SHA" ]] && continue
    git -C "$REPO_DIR" merge-base --is-ancestor "$SHA" HEAD 2>/dev/null || continue
    has_claude_trailer "$REPO_DIR" "$SHA" && continue
    SHORT=$(git -C "$REPO_DIR" rev-parse --short "$SHA")
    [[ " ${OTHERS[*]} " == *" $SHORT "* ]] || OTHERS+=("$SHORT")
done
OTHERS_NOTE=""
if (( ${#OTHERS[@]} )); then
    OTHERS_NOTE=" This call also made ${OTHERS[*]} in $REPO_DIR without the trailer; the hook only amends HEAD, so add it to those by hand if they need the agent-authored label."
fi

if has_claude_trailer "$REPO_DIR" HEAD; then
    [[ -n "$OTHERS_NOTE" ]] && report "hook:${OTHERS_NOTE}"
    exit 0
fi

# git-commit.sh can end without committing (--help, an argument error, a
# protected branch, a failing pre-commit hook), and the payload carries no exit
# status. HEAD is then whatever the repo already had, possibly another
# author's fresh commit. A real commit prints git's summary line naming the new
# HEAD, so without that line in this call's output nothing is amended.
if [[ "$WRAPPER_ONLY" == "$WRAPPER_MARKER" ]]; then
    OUTPUT=$(echo "$INPUT" | jq -r '.tool_response
        | if type == "object" then ([.stdout, .stderr] | map(select(type == "string")) | join("\n"))
          elif type == "string" then .
          else "" end' 2>/dev/null)
    if ! output_names_head "$REPO_DIR" "$OUTPUT"; then
        HASH=$(git -C "$REPO_DIR" rev-parse --short HEAD)
        report "hook: Co-Authored-By trailer not added: the output of this git-commit.sh call does not show commit $HASH (HEAD of $REPO_DIR), so this call may not have made it; if it did, add the trailer manually"
        exit 0
    fi
fi

# A hook that rewrites a commit already pushed would desync the remote. Checked
# last, so the warning below only fires for a commit that needed the trailer.
if git -C "$REPO_DIR" branch -r --contains HEAD 2>/dev/null | grep -q .; then
    if [[ "$PUSH_AFTER" == "$PUSH_MARKER" ]]; then
        HASH=$(git -C "$REPO_DIR" rev-parse --short HEAD)
        report "hook: commit $HASH in $REPO_DIR was pushed in the same call; the trailer was not added. On a feature branch: amend it in and force-push.${OTHERS_NOTE}"
    fi
    exit 0
fi

# --allow-empty: without it git refuses to amend an empty commit (a tracking-PR
# opener, for one), so exactly those commits would silently stay unlabelled.
if git -C "$REPO_DIR" commit --amend --no-edit --no-verify --allow-empty \
        --trailer "$TRAILER" &>/dev/null; then
    report "hook: added missing '$TRAILER' to HEAD of $REPO_DIR, so its SHA changed (agent-authored label depends on it).${OTHERS_NOTE}"
else
    report "hook: could not add Co-Authored-By trailer to HEAD of $REPO_DIR; add it manually so the agent-authored label applies.${OTHERS_NOTE}"
fi

exit 0
