#!/usr/bin/env bash
# Pre-tool-use hook: refuse a git checkout/switch, git bisect or gh pr checkout
# that moves the LIVE toolkit checkout off its base branch.
#
# Why this exists
# ---------------
# ~/.claude/bin and ~/.claude/skills are symlinks into one toolkit checkout.
# Whatever branch that checkout is on runs in every project and every session,
# immediately. A feature branch checked out there is live before review: with
# #115, half-finished hook changes caused permission prompts in unrelated
# projects, and `git switch main` was no way out while the implementing agent
# was still working in that tree.
#
# So toolkit changes are built in a linked worktree (the repo CLAUDE.md states
# the rule), and this hook enforces it at the one moment it can go wrong: the
# checkout or switch that would put something other than the base branch in
# the live tree. That covers new branches (-b/-B/--orphan, -c/-C), existing
# branches, detached commits and `switch -`; `gh pr checkout` (also with
# --detach, and its alias `gh co`), which a review sub-agent reached for in
# #375; and `git bisect`, which detaches HEAD at every step.
#
# Left to other guards or harmless: `git reset --hard <ref>` is refused
# everywhere by hook-block-destructive.sh, and `git worktree add` builds a new
# tree beside the live one, which is the intended route.
#
# Scope:
#   - Only the live checkout: the main worktree whose top level equals
#     dirname(readlink -f ~/.claude/bin). Linked worktrees and every other
#     repository are untouched. When ~/.claude/bin is not a symlink, nothing is
#     live and this hook does nothing.
#   - Only branch moves. Path checkouts (`checkout -- <path>`,
#     `checkout <ref> <path>`, `checkout <file>`) move no HEAD and are left to
#     hook-block-destructive.sh.
#   - Only Claude's tool calls. A human switching branches in a terminal is not
#     seen by any hook.
#
# The target tree is the hook input's cwd, followed through `cd <dir>` earlier
# in the same command chain, through an `env -C`/`--chdir` prefix and through
# git's own -C options. Leading VAR=value assignments are skipped.
#
# Installation: register in settings.json under PreToolUse / matcher "Bash":
#   { "type": "command", "command": "~/.claude/bin/hook-block-toolkit-live-checkout.sh" }
#
# Exit codes:
#   0 = allow
#   2 = block (reason to stderr, shown to Claude)

set -uo pipefail

# shellcheck source=bin/lib/live-checkout.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/live-checkout.sh"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$CWD" ] && CWD=$PWD

[ -z "$COMMAND" ] && exit 0
# Cheap prefilter: most commands never mention a verb that moves HEAD.
echo "$COMMAND" | grep -qE '(checkout|switch|bisect|\<co\>)' || exit 0

LIVE_ROOT=$(live_checkout_root)
[ -z "$LIVE_ROOT" ] && exit 0

# Tokenize like a shell would (quotes, chains), one NUL-terminated token per
# word or operator. Unparseable input yields nothing and is allowed: git will
# reject it too, and a guard that blocks on its own parse errors gets disabled.
mapfile -d '' TOKENS < <(python3 -c '
import shlex, sys
try:
    lex = shlex.shlex(sys.argv[1].replace("\n", ";"), posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    tokens = list(lex)
except ValueError:
    sys.exit(0)
for t in tokens:
    sys.stdout.write(t + "\0")
' "$COMMAND")

# Resolve <dir> against <base> the way cd and git -C do, expanding a leading ~.
resolve_dir() { # base dir
    local dir=$2
    case "$dir" in "~") dir=$HOME ;; "~"/*) dir="$HOME/${dir#\~/}" ;; esac
    [[ "$dir" != /* ]] && dir="$1/$dir"
    printf '%s' "$dir"
}

block() { # target base_branch
    cat >&2 <<EOF
BLOCKED by hook-block-toolkit-live-checkout.sh: this takes the live toolkit
checkout off '$2'.

  live checkout: $1
  command      : $COMMAND

~/.claude/bin and ~/.claude/skills point into this tree, so whatever it has
checked out runs in every project and every session right away, before review.
Build toolkit changes in a linked worktree instead:

  ~/.claude/bin/git-resolve-worktree.sh --issue <N> --create <slug>

or by hand:

  git -C $1 worktree add --no-track -b issue-<N>-<slug> $1-<N> origin/$2

then work there with git -C <worktree> and absolute paths. Why: $1/CLAUDE.md.
EOF
    exit 2
}

# Succeed when <dir> lies in the live checkout's own working tree. A linked
# worktree has its own top level, so it never matches.
in_live_tree() { # dir
    local root
    root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ "$root" = "$LIVE_ROOT" ]
}

# Judge `git bisect <sub>` run in <dir>. Every step of a bisect (start with or
# without revisions, good/bad/new/old/skip, next, run, replay and custom terms)
# detaches HEAD onto a commit under test. Only the subcommands that move no
# HEAD pass, and `reset <commit>` only when it returns to the base branch.
judge_bisect() { # dir words...
    local dir=$1; shift
    in_live_tree "$dir" || return 0
    local base
    base=$(live_base_branch "$LIVE_ROOT")
    case "${1:-}" in
        ""|log|view|visualize|terms|help|-h|--help) return 0 ;;
        reset)
            [ $# -lt 2 ] && return 0
            [ "$2" = "$base" ] && return 0
            ;;
    esac
    block "$LIVE_ROOT" "$base"
}

# Judge one `gh ...` invocation run from <dir>. Words exclude the leading gh.
# `gh pr checkout` (and its stock alias `gh co`) checks the PR out in the git
# repository of the current directory: on the PR's branch, or detached with
# --detach. Either way the live checkout leaves its base branch. -R/--repo
# only picks which repository's PR to fetch, not where it lands.
judge_gh() { # dir words...
    local dir=$1; shift
    [ "${1:-}" = co ] || { [ "${1:-}" = pr ] && [ "${2:-}" = checkout ]; } || return 0
    in_live_tree "$dir" || return 0
    block "$LIVE_ROOT" "$(live_base_branch "$LIVE_ROOT")"
}

# Judge one `git ...` invocation run from <cwd>. Words exclude the leading git.
judge_git() { # cwd words...
    local dir=$1; shift
    local sub=""

    # Global options up to the subcommand. -C stacks like cd; options with a
    # separate value are skipped along with it.
    while [ $# -gt 0 ]; do
        case "$1" in
            -C) [ $# -ge 2 ] || return 0; dir=$(resolve_dir "$dir" "$2"); shift 2 ;;
            -C*) dir=$(resolve_dir "$dir" "${1#-C}"); shift ;;
            -c|--git-dir|--work-tree|--namespace|--exec-path|--config-env) shift 2 ;;
            -*) shift ;;
            *) sub=$1; shift; break ;;
        esac
    done
    case "$sub" in
        checkout|switch) ;;
        bisect) judge_bisect "$dir" "$@"; return 0 ;;
        *) return 0 ;;
    esac

    in_live_tree "$dir" || return 0
    local base
    base=$(live_base_branch "$LIVE_ROOT")

    # Short options that create a branch or detach. git accepts them stuck to
    # their value (-bx) and clustered behind other flags (-qb x); neither
    # command has another short option that takes a value, so the letter
    # anywhere in a single-dash word means that option.
    local branch_flags=bB
    [ "$sub" = switch ] && branch_flags=cCd

    local -a positional=()
    local arg
    while [ $# -gt 0 ]; do
        arg=$1; shift
        case "$arg" in
            # Path mode: whatever precedes `--` is a tree-ish to read from, not
            # a branch to move to. A trailing `--` with no pathspec after it
            # only disambiguates <branch> and still moves HEAD.
            --) if [ "$sub" = checkout ]; then [ $# -gt 0 ] && return 0; break; fi ;;
            --orphan|--orphan=*|--detach|--create|--create=*|--force-create|--force-create=*)
                block "$LIVE_ROOT" "$base" ;;
            -) block "$LIVE_ROOT" "$base" ;;
            --*) ;;
            -*) [[ "${arg#-}" == *["$branch_flags"]* ]] && block "$LIVE_ROOT" "$base" ;;
            *) positional+=("$arg") ;;
        esac
    done

    # No target: git stays where it is (or errors). Several positionals on a
    # checkout are `<tree-ish> <pathspec>...`, a path checkout.
    [ ${#positional[@]} -eq 0 ] && return 0
    [ "${positional[0]}" = "$base" ] && return 0
    if [ "$sub" = checkout ]; then
        [ ${#positional[@]} -gt 1 ] && return 0
        # A lone argument that is no commit is a path; git reads it that way too.
        git -C "$LIVE_ROOT" rev-parse --verify -q "${positional[0]}^{commit}" >/dev/null 2>&1 || return 0
    fi
    block "$LIVE_ROOT" "$base"
}

# Walk the chain segment by segment, following `cd` for the segments after it.
# Leading `VAR=value` assignments and an `env` prefix still run git; env's -C
# moves only its own command, not the segments after it.
judge_segment() { # words...
    local dir=$CWD
    while [ $# -gt 0 ] && [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done
    if [ "${1:-}" = env ]; then
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                -C|--chdir) [ $# -ge 2 ] || return 0; dir=$(resolve_dir "$dir" "$2"); shift 2 ;;
                --chdir=*) dir=$(resolve_dir "$dir" "${1#--chdir=}"); shift ;;
                -C*) dir=$(resolve_dir "$dir" "${1#-C}"); shift ;;
                -u|--unset) shift 2 ;;
                -*) shift ;;
                *=*) shift ;;
                *) break ;;
            esac
        done
    fi
    [ $# -eq 0 ] && return 0
    case "$1" in
        cd) [ $# -ge 2 ] && CWD=$(resolve_dir "$CWD" "$2") ;;
        git) shift; judge_git "$dir" "$@" ;;
        gh) shift; judge_gh "$dir" "$@" ;;
    esac
}

SEGMENT=()
SKIP_NEXT=0
for tok in "${TOKENS[@]}"; do
    if [ "$SKIP_NEXT" = 1 ]; then SKIP_NEXT=0; continue; fi
    case "$tok" in
        ';'|'&&'|'||'|'|'|'&'|'('|')'|'|&')
            judge_segment "${SEGMENT[@]}"
            SEGMENT=()
            ;;
        '>'|'>>'|'<'|'>&'|'<&'|'&>'|'&>>'|'<>')
            # A redirect and its target are no arguments. Drop an fd number
            # written before it too (`2>&1` tokenizes as 2, >&, 1).
            if [ ${#SEGMENT[@]} -gt 1 ] && [[ "${SEGMENT[-1]}" =~ ^[0-9]$ ]]; then
                unset 'SEGMENT[-1]'
            fi
            SKIP_NEXT=1
            ;;
        *) SEGMENT+=("$tok") ;;
    esac
done
judge_segment "${SEGMENT[@]}"

exit 0
