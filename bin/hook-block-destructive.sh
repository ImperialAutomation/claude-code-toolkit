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
#   any other = an internal error, converted to a block by the trap below

set -euo pipefail

# Fail closed on an internal error. Claude Code blocks on exit 2 specifically, so
# every OTHER non-zero exit — a typo in a regex, a missing jq, an unset variable
# under `set -u` — reads as "allow". That inverts the guard precisely when it is
# broken, and silently: nothing in the transcript distinguishes "checked, fine"
# from "crashed before checking".
#
# Not hypothetical. While tightening the $HOME pattern (issue #70) an unescaped
# `$(HOME|...)` became command substitution, the hook exited 127, and every
# destructive command in the test suite came back ALLOW. The suite caught it
# because it asserts on BLOCK as well as ALLOW; in a real session nothing would
# have.
#
# The trap fires only on an unexpected exit: both deliberate paths (`exit 0` and
# `exit 2`) are excluded, so a normal allow stays an allow.
# SC2329: invoked indirectly, by the `trap ... EXIT` immediately below.
# shellcheck disable=SC2329
_fail_closed() {
    local rc=$?
    case "$rc" in
        0 | 2) exit "$rc" ;;
    esac
    echo "BLOCKED by hook-block-destructive.sh: the guard itself failed (exit $rc) and cannot say whether this command is safe. Failing closed. This is a bug in the hook, not in the command — report it rather than working around it." >&2
    exit 2
}
trap _fail_closed EXIT

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

# Leaders whose heredoc body is a program in ANOTHER language, with a QUOTED
# delimiter. Both halves are required, and each rules out a different mistake.
#
# Another language: the body of `python3 - <<'PY'` is Python, so a shell pattern
# matched against it is matching prose. Issue #70's first observed false positive
# was exactly this — a Python heredoc printing a sentence that happened to contain
# a blocked word. These leaders are NOT in _READONLY_LEADER_RE and must not be:
# python3 runs arbitrary code, so its own command line is judged like any other.
# Only the body is exempt, and only from the SHELL patterns this hook knows.
#
# Quoted delimiter: with `<<PY` the shell expands $(...) and `...` inside the body
# before the interpreter ever sees it, so a shell command really can hide there.
# With `<<'PY'` no substitution happens and the body reaches the interpreter
# verbatim. That is the difference between data and a disguised command line, so
# the quote is the condition, not a stylistic detail.
#
# What this does NOT claim: that the body is safe. Python can shell out, and this
# hook cannot read Python. It claims only that matching bash patterns against
# non-bash source produces noise rather than safety — the guard against what the
# script then does is the interpreter's own command line, which is still judged.
_INTERPRETER_LEADER_RE='^[[:space:]]*(sudo[[:space:]]+)?([^[:space:]]*/)?(python3?|perl|ruby|node|osascript|Rscript)([[:space:]]|$)'

# Drop heredoc bodies before splitting, but ONLY where the line opening the
# heredoc is itself read-only. Without this step the body arrives as its own
# segment whose leading word is the body text, which matches no read-only command
# and therefore blocks — so a `cat <<EOF` of prose, or a Python script that prints
# a sentence, trips the guard on a word it merely contains.
#
# The leader condition is what keeps this honest, and it is not a refinement: a
# heredoc body is stdin, and whether stdin is DATA or a PROGRAM depends entirely
# on what reads it. `cat <<EOF` and `python3 - <<PY` print and interpret text that
# this hook has no business classifying as shell. `psql -d app <<SQL` EXECUTES
# every statement in the body, so dropping it would hide a DROP SCHEMA from the
# SQL guard — which is exactly the test that caught an earlier, leader-blind
# version of this function.
#
# The heredoc's OWN line is always kept, so the command introducing it is judged
# regardless, and a real command on a line after the closing delimiter is judged
# on itself. Only the body in between can go.
#
# Both `<<DELIM` and `<<'DELIM'` are handled, and the `<<-` tab-stripping form.
# The quoted delimiter is the one that guarantees no substitution, but that
# distinction does not matter here: what the body means is settled by its reader,
# not by its quoting.
#
# An unterminated heredoc runs to end of input. Since only a read-only leader can
# open a stripped body at all, the most that hides is the tail of a `cat` — and
# the opening line is still judged, so there is nothing to launder a real command
# with.
_strip_heredoc_bodies() {
    local delim body_open=0 line out=""
    while IFS= read -r line; do
        if [ "$body_open" -eq 1 ]; then
            # Closing delimiter: `<<-` allows leading tabs before it.
            if [ "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" = "$delim" ]; then
                body_open=0
            fi
            continue
        fi
        out+="$line"$'\n'
        # Opening redirect: capture the delimiter, quoted or bare. A body may be
        # hidden only under a read-only leader (see the psql note above), or under
        # an interpreter whose delimiter is QUOTED, which is what stops the shell
        # expanding a command into the body before the interpreter reads it.
        if { grep -qE "$_READONLY_LEADER_RE" <<< "$line" ||
             { grep -qE "$_INTERPRETER_LEADER_RE" <<< "$line" &&
               grep -qE '<<-?[[:space:]]*('"'"'[^'"'"']+'"'"'|"[^"]+")' <<< "$line"; }; } &&
           grep -qE '<<-?[[:space:]]*('"'"'[^'"'"']+'"'"'|"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)' <<< "$line"; then
            delim=$(grep -oE '<<-?[[:space:]]*('"'"'[^'"'"']+'"'"'|"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)' <<< "$line" |
                    tail -1 | sed 's/^<<-\?[[:space:]]*//; s/^['"'"'"]//; s/['"'"'"]$//')
            [ -n "$delim" ] && body_open=1
        fi
    done <<< "$COMMAND"
    printf '%s' "$out"
}

_split_segments() {
    _strip_heredoc_bodies | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g'
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

# Assert every regex the guards depend on is set and non-empty, before the first
# guard runs. `set -u` is not enough on its own: the guards read their constants
# inside a `while ... done < <(...)` loop, so an unbound variable kills only the
# SUBSHELL. The loop then sees end-of-input, reports "no match", and the hook
# exits 0 — a fail-OPEN whose only trace is a line on stderr that nothing reads.
#
# Found by testing for it: a deliberately renamed constant made the hook allow a
# command it should have blocked, and the EXIT trap above could not catch it
# because the exit status was a perfectly ordinary 0. Renaming a constant is the
# realistic way in; this file renamed one while fixing issue #70.
#
# Listed in one place rather than checked at each use, so a guard added later is
# covered by adding its constant here instead of re-deriving the reasoning.
for _required in _READONLY_LEADER_RE _INTERPRETER_LEADER_RE _SQL_DESTRUCTIVE_RE \
                 _SQL_DELETE_RE _SQL_WHERE_RE; do
    if [ -z "${!_required:-}" ]; then
        echo "BLOCKED by hook-block-destructive.sh: internal error — the pattern '$_required' this guard relies on is unset or empty, so the check cannot run. Failing closed. This is a bug in the hook; report it rather than working around it." >&2
        exit 2
    fi
done
unset _required

if _sql_destructive_hit; then
    echo "BLOCKED by hook-block-destructive.sh: refusing a destructive SQL statement (DROP TABLE/DATABASE/SCHEMA, DROP OWNED BY, TRUNCATE, or a DELETE FROM with no WHERE clause). All of these destroy data irreversibly, including the forms that avoid the word DATABASE. Adding a WHERE clause is fine if that is what you meant. If this targets a throwaway database, say so and ask the user to confirm — do not rephrase the statement to get past this check." >&2
    exit 2
fi

if _rm_hits_protected_path; then
    echo "BLOCKED by hook-block-destructive.sh: refusing a force-recursive rm of an absolute path outside /tmp. Deleting scratch files UNDER /tmp (e.g. /tmp/my-workdir) is allowed; wiping /tmp itself, a home path, or any other absolute path needs the user's explicit go-ahead." >&2
    exit 2
fi

# Patterns for destructive operations.
#
# Three of these were tightened after the per-segment rewrite (issue #70) exposed
# them. Each had the same shape of hole: the pattern pinned LITERAL TEXT, so an
# ordinary shell habit — quoting an operand, combining short flags — stepped
# around it. They were found by writing the false-negative cases this change had
# to avoid introducing, then discovering those cases already passed on main.
#
#   rm -rf "$HOME"              quoting the operand broke `rm -rf \$HOME`
#   dd if=/dev/zero of="/dev/sda"  quoting the target broke `of=/dev/`
#   git clean -fd               a combined flag broke `git clean.* -f( |$)`
#
# The lesson generalises: a pattern that must match a FLAG should accept it in a
# cluster, and one that must match an OPERAND should tolerate quotes around it.
# SC2016 is intentional for the $HOME entry below: these are REGEXES matching
# literal command text, and $HOME reaches this hook unexpanded. It must stay
# single-quoted — written with double quotes, `$(HOME|...)` is command
# substitution the shell runs while building the array. That happened: the
# resulting exit 127 is neither 0 nor 2, so the hook allowed everything it should
# have blocked. A guard whose own error means "allow" is worse than no guard,
# which is why the trap above now converts any internal failure into a block.
# shellcheck disable=SC2016
BLOCKED_PATTERNS=(
    # Filesystem destruction. Quotes around the operand are ordinary hygiene, not
    # a signal of intent — `rm -rf "$HOME"` deletes exactly as much as the bare
    # form, so both must match.
    'rm -rf ["'"'"']?\$(HOME|\{HOME\})["'"'"']?'
    # Git destructive operations
    "git push.*--force"
    "git push.* -f( |$)"
    "git reset.*--hard"
    "git checkout -- \\."
    # `-f` may arrive clustered with other short flags (-fd, -fx, -xdf), which the
    # earlier `-f( |$)` form required to stand alone.
    "git clean.* -[a-zA-Z]*f[a-zA-Z]*( |$)"
    # Database destruction is handled by _sql_destructive_hit() above, which
    # covers the DROP SCHEMA / DROP OWNED BY forms these patterns missed and the
    # unqualified DELETE a single regex cannot express.
    # Process/system
    "kill -9 1$"
    "killall"
    "shutdown"
    "reboot"
    "mkfs"
    # Writing to a raw device destroys the filesystem on it. The target may be
    # quoted, which the earlier `of=/dev/` form did not allow for.
    "dd if=.* of=['\"]?/dev/"
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
