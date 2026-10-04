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

# Split the command line into the pieces a shell would run separately. Every guard
# below classifies per segment rather than over the whole string, so that a
# read-only leader excuses its OWN segment and nothing else: a grep for a pattern
# name followed by `&&` and the real command must block on the second half, even
# though the first half is only a search.
#
# This is a deliberately shallow split, not a shell parser. Writing one in bash is
# its own source of bugs, and the failure mode of being too shallow is extra
# segments that match no read-only leader — i.e. a block. Erring toward more
# segments therefore errs toward refusing, which is the direction to err in.
_split_segments() {
    sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g' <<< "$COMMAND"
}

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
    done < <(_split_segments)
    return 1
}

# Guard: destructive SQL, in whatever form carries the same effect.
#
# The patterns this replaces blocked DROP TABLE / DROP DATABASE / TRUNCATE but
# not DROP SCHEMA ... CASCADE or DROP OWNED BY, which destroy the same data. That
# inconsistency is worse than a uniform gap: the loud form gets refused, so the
# next thing reached for is the quiet equivalent, and the guard trains rephrasing
# instead of asking. It happened in a real session (issue #67) — a blocked
# DROP DATABASE was followed by DROP SCHEMA public CASCADE against the same
# database, with no second prompt.
#
# Kept as a function rather than entries in BLOCKED_PATTERNS so all SQL forms
# share ONE mechanism: segment splitting (below), the no-WHERE delete check that
# needs two steps, and the read-only-leader skip. Adding a bare pattern to the
# array would have reproduced the self-match nuisance for each new form.
#
# On scope: this does produce false positives on legitimate throwaway work — test
# databases, disposable containers, a schema reset between fixtures — and that is
# a real cost, not an acceptable one. The aim is NOT to block more. It is that the
# loud form and the quiet equivalent get the same answer, because an inconsistent
# guard teaches rephrasing rather than asking. When a block is a false positive,
# the fix is to ask the user, not to find the phrasing that slips past; if a
# throwaway target starts tripping this routinely, narrow the guard here rather
# than working around it at the call site.
_SQL_DESTRUCTIVE_RE='(^|[^[:alnum:]_])(DROP[[:space:]]+(TABLE|DATABASE|SCHEMA)|DROP[[:space:]]+OWNED[[:space:]]+BY|TRUNCATE)([^[:alnum:]_]|$)'

# Commands that only READ or PRINT text. A destructive keyword appearing as an
# argument to one of these is being searched for or quoted, not executed —
# grepping for a pattern tripped the guard, and so did a commit message naming
# one. Anchored to the segment's LEADING word, mirroring the git-merge guard
# below: a read-only leader cannot launder a real command in a later segment,
# because each segment is classified on its own.
#
# This started as an SQL-only skip (issue #67) and now serves the pattern lists
# too (issue #70), where the same false positive was three times as common: a
# grep for a pattern name, a word inside an echo, a commit subject. The worst of
# those was a grep over THIS FILE — the guard blocked the investigation into the
# guard, with no phrasing available that got past it.
#
# Why a leader check and not stripping quoted text, which is the obvious move:
# quoting an operand is ordinary shell hygiene, not a signal that the text is
# data. `rm -rf "$HOME"` and `dd if=/dev/zero of="/dev/sda"` destroy exactly as
# much with the quotes as without, so a strip-then-match pass would have read
# them as safe. Both were in fact already slipping through for a related reason
# (the quote broke a literal-text pattern); see the dd/rm notes below. The leader
# is what separates naming a command from running one, so the leader is what
# this looks at.
#
# Everything not listed here gets no skip, which is the fail-closed half: an
# unrecognised leader (eval, xargs, bash -c, a project wrapper) still blocks on a
# quoted keyword. That is noisier than ideal and deliberately so — a false
# negative here is a destroyed working tree, a false positive is one rephrasing.
_READONLY_LEADER_RE='^[[:space:]]*(sudo[[:space:]]+)?([^[:space:]]*/)?(grep|egrep|fgrep|rg|ag|ack|cat|bat|less|more|head|tail|echo|printf|awk|sed|diff|wc|sort|uniq|strings|git-commit\.sh|gh)([[:space:]]|$)'

# An unqualified DELETE empties the table. The pattern this replaces was
# "DELETE FROM.*WITHOUT.*WHERE", which matched the literal word WITHOUT and so
# matched nothing anyone types — it read as covered while covering nothing, which
# is worse than an honest gap. The intent cannot be written as one regex: it
# takes two steps, finding the statement and then asking whether it is qualified.
_SQL_DELETE_RE='(^|[^[:alnum:]_])DELETE[[:space:]]+FROM([^[:alnum:]_]|$)'
_SQL_WHERE_RE='(^|[^[:alnum:]_])WHERE([^[:alnum:]_]|$)'

_sql_destructive_hit() {
    local segment
    while IFS= read -r segment; do
        # Classify each segment independently, so one read-only leader does not
        # excuse the rest of the command line, and a qualified delete does not
        # excuse an unqualified one sharing it.
        echo "$segment" | grep -qE "$_READONLY_LEADER_RE" && continue
        echo "$segment" | grep -qiE "$_SQL_DESTRUCTIVE_RE" && return 0
        if echo "$segment" | grep -qiE "$_SQL_DELETE_RE"; then
            echo "$segment" | grep -qiE "$_SQL_WHERE_RE" || return 0
        fi
    done < <(_split_segments)
    return 1
}

if _sql_destructive_hit; then
    echo "BLOCKED by hook-block-destructive.sh: refusing a destructive SQL statement (DROP TABLE/DATABASE/SCHEMA, DROP OWNED BY, TRUNCATE, or a DELETE FROM with no WHERE clause). All of these destroy data irreversibly, including the forms that avoid the word DATABASE. Adding a WHERE clause is fine if that is what you meant. If this targets a throwaway database, say so and ask the user to confirm — do not rephrase the statement to get past this check." >&2
    exit 2
fi

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
    # Database destruction is handled by _sql_destructive_hit() above, which
    # covers the DROP SCHEMA / DROP OWNED BY forms these patterns missed and the
    # unqualified DELETE a single regex cannot express.
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

# Match the pattern lists per segment, skipping the segments whose leading word
# only reads or prints (see _READONLY_LEADER_RE). These loops used to grep the
# whole command string, so a keyword present only as DATA blocked the command:
# a search term, a word in an echo, a commit subject. Issue #70 collected three
# such blocks from one session, the sharpest being a grep over this file —
# looking the pattern up was impossible without tripping it.
#
# Echoes the matched SEGMENT, not the whole command line, so the message points
# at the part that actually matched; with a multi-segment command the pattern
# alone left you guessing which half was the problem.
_pattern_hit() { # _pattern_hit <grep-flags> <pattern>...
    local flags="$1" segment pattern
    shift
    while IFS= read -r segment; do
        grep -qE "$_READONLY_LEADER_RE" <<< "$segment" && continue
        for pattern in "$@"; do
            if grep -q"$flags" -- "$pattern" <<< "$segment" 2>/dev/null; then
                _PATTERN_HIT_PATTERN="$pattern"
                _PATTERN_HIT_SEGMENT="$segment"
                return 0
            fi
        done
    done < <(_split_segments)
    return 1
}

_PATTERN_HIT_PATTERN=""
_PATTERN_HIT_SEGMENT=""

# Case-sensitive list first: it distinguishes -D from -d, so folding case would
# make the two indistinguishable and block the safe form along with the forced one.
if _pattern_hit E "${CASE_SENSITIVE_PATTERNS[@]}" ||
   _pattern_hit iE "${BLOCKED_PATTERNS[@]}"; then
    echo "BLOCKED by hook-block-destructive.sh: command matches destructive pattern '$_PATTERN_HIT_PATTERN' in '$_PATTERN_HIT_SEGMENT'. Rephrase or ask the user for explicit permission. Note that a keyword appearing only as data — a grep pattern, a word inside echo, a commit message — is NOT blocked; if you are reading this, the match is outside quotes or under a command this hook does not recognise as read-only." >&2
    exit 2
fi

exit 0
