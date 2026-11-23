#!/usr/bin/env bash
# Pre-tool-use hook: refuse a destructive git operation aimed at a DIFFERENT
# worktree than the one the command runs from.
#
# Why this exists
# ---------------
# Linked worktrees share one repository but have independent working trees, each
# with its own uncommitted work. `git -C <other-worktree> checkout -- <files>`
# discards changes in a tree the caller is not working in and cannot see. The
# files come back at HEAD, so anything uncommitted there is gone, including work
# belonging to another session that is editing that tree right now.
#
# That is not hypothetical. A common route: a test runner copies sources into a
# long-lived container whose bind-mount points at ANOTHER worktree, so the run
# writes files into a tree the caller never touched. Cleaning up with
# `git -C <that-tree> checkout -- <files>` then restores to HEAD and takes any
# uncommitted work there with it. The correct cleanup is to save the originals
# aside first and restore those, i.e. restore to WHAT WAS THERE, not to HEAD.
#
# What it guards, and what it does not
# ------------------------------------
# The hook guards one thing: losing uncommitted work in the target's working
# tree. It does not guard which branch is checked out there, nor the history of
# a branch. That boundary decides every case below (#322, D2-D4):
#
#   - Switching to an existing branch without force (`checkout <branch>`,
#     `switch <branch>`) is allowed (D2). Without force git refuses when local
#     changes would be overwritten, so no work is lost; landing on another
#     branch is a different risk from the one this hook watches.
#   - Resetting a branch with `checkout -B` / `switch -C` is allowed (D3). It
#     moves a branch, not the working tree's uncommitted changes; commits it
#     drops stay in the reflog, and git already refuses -B on a branch that is
#     checked out in another worktree.
#   - Restoring paths is blocked whether or not it is spelled with `--` (D4):
#     `checkout -- f`, `checkout HEAD f`, `checkout .` and `checkout f` all put
#     files back at a commit. A single argument counts as a path when it does not
#     name a commit (or a remote branch git would DWIM into a new branch) in the
#     target repository.
#
# How a command is judged
# -----------------------
# By meaning, not by word order. The command line is split into its git
# invocations (a chain may hold several). Per invocation the global options are
# skipped (`-C <dir>`, `-c <k=v>`, `--git-dir=<d>`, `--no-pager`, ...), the first
# remaining word is the subcommand, and only that subcommand's own arguments are
# judged:
#
#   checkout  blocked: bare `--`, -f/--force, -p/--patch, --pathspec-from-file,
#             `.`, two or more positional arguments, or one that is not a ref
#             allowed: -b/-B/--orphan, --detach/--track/--no-track/--quiet and
#             other long options, switching to an existing branch
#   switch    blocked: -f/--force/--discard-changes; everything else allowed
#   restore, reset, clean   always blocked
#   stash     list/show allowed; pop/apply/drop judged on the entry's origin
#             (below); everything else (bare, push, -u, clear, ...) blocked
#   anything else (add, grep, log, show, diff, ...)   allowed
#
# A verb that appears as a path or a pattern (`add docs/restore.md`,
# `log --grep=clean`) is therefore never mistaken for the subcommand (#125).
# Words are split on whitespace with one layer of quotes stripped; a quoted
# path containing spaces splits into several words, which errs toward blocking.
#
# Scope: only cross-worktree operations. Inside your own tree these commands stay
# untouched: that is your own work to discard, and guarding it would add friction
# to routine reverts (e.g. undoing a mutation test) for no safety gain.
#
# hook-block-destructive.sh blocks `git checkout -- .` (whole tree) but not
# `git checkout -- <files>`, which is the form an agent naturally reaches for
# because it names the files it touched. This closes that path for the case where
# it can damage someone else's tree.
#
# Generic by design: nothing here names a project. Where a repository has its own
# safe alternative (an isolated test runner, a documented restore procedure),
# surface it through WORKTREE_GUARD_HINT from a small project wrapper rather than
# hardcoding it: a suggestion pointing at a script that does not exist in the
# caller's repo is worse than no suggestion.
#
# Configuration (environment variables):
#   WORKTREE_GUARD_HINT   Optional project-specific text appended to the block
#                         message, e.g. the repo's isolated test-runner command.
#
# Installation: register in settings.json under PreToolUse / matcher "Bash".
# Register a project wrapper when you have a hint to add, otherwise this script:
#   { "type": "command", "command": "~/.claude/bin/hook-block-foreign-worktree-git.sh" }
#
# Example wrapper:
#   #!/usr/bin/env bash
#   export WORKTREE_GUARD_HINT='Run tests in a disposable container instead:
#     bin/<your-isolated-test-runner>.sh <args>'
#   exec ~/.claude/bin/hook-block-foreign-worktree-git.sh
#
# Exit codes:
#   0 = allow
#   2 = block (reason to stderr, shown to Claude)

set -uo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

# Only look at git commands carrying an explicit -C/--git-dir target. Without one
# git acts on the current directory, which by definition is the caller's own tree
# and therefore out of scope.
#
# This is also the escape hatch. Working in another worktree the normal way --
# `cd <wt> && git reset --hard` -- carries no -C and so never gets here. Only the
# redundant `cd <wt> && git -C <wt> ...`, where the -C repeats the cd, is judged
# against this process's working directory and blocked. Rewriting it the natural
# way is the fix; the hook errs toward over-blocking, never under-blocking.
echo "$COMMAND" | grep -qE '(^|[^[:alnum:]_.-])git[[:space:]]' || exit 0
echo "$COMMAND" | grep -qE -- '-C[= ]|--git-dir[= ]' || exit 0

# Global options of git that take their value as the NEXT word. Any other word
# starting with `-` before the subcommand is a flag or carries its value after
# `=`; -C is handled separately because it sets the target.
GLOBAL_OPTS_WITH_VALUE=' -c --git-dir --work-tree --namespace --config-env --super-prefix --list-cmds '

# Shell operators that end one command and start the next. `$(` must come
# before `(` so a command substitution leaves no stray `$`.
# shellcheck disable=SC2016  # literal `$(`, not an expansion
CHAIN_SEPARATORS=('$(' '&&''||' ';' '&' '|' '(' ')' '`')

strip_quotes() { # word -> the word without one layer of surrounding quotes
    local w=$1
    case "$w" in
        \"*\") w=${w#\"}; w=${w%\"} ;;
        \'*\') w=${w#\'}; w=${w%\'} ;;
    esac
    printf '%s' "$w"
}

expand_tilde() { # path -> path with a leading ~/ expanded
    case "$1" in
        "~") printf '%s' "$HOME" ;;
        "~"/*) printf '%s' "$HOME/${1#\~/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

is_long_prefix() { # word full-name min-len: does --<abbrev> abbreviate --<full>?
    # git accepts any unambiguous prefix of a long option, so `--forc` is
    # `--force`. min-len keeps a prefix shared with another option out.
    local name=${1#--}
    name=${name%%=*}
    [ "${#name}" -ge "$3" ] && [ "${2#"$name"}" != "$2" ]
}

scan_short_cluster() { # word destructive-letters value-letters
    # Walk a cluster such as -qfb. Prints D when a destructive letter comes
    # first, V<letter> when a value-taking letter ends the cluster (its value is
    # the next word), A<letter> when its value is attached (-bname), N otherwise.
    local w=${1#-} i c
    for ((i = 0; i < ${#w}; i++)); do
        c=${w:i:1}
        case "$2" in *"$c"*) echo D; return ;; esac
        case "$3" in *"$c"*)
            if [ $((i + 1)) -eq ${#w} ]; then echo "V$c"; else echo "A$c"; fi
            return ;;
        esac
    done
    echo N
}

is_ref() { # target-root word: does the word name a commit or a remote branch?
    [ "$2" = "-" ] && return 0
    git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1 && return 0
    # `checkout <name>` with no local branch <name> but a remote one creates a
    # tracking branch (DWIM): a branch switch, not a path restore.
    [ -n "$(git -C "$1" for-each-ref --count=1 --format=x "refs/remotes/*/$2" 2>/dev/null)" ]
}

checkout_is_destructive() { # target-root args...
    local root=$1; shift
    local creates=0 skip=0 a r
    local -a positional=()
    for a in "$@"; do
        if [ $skip -eq 1 ]; then skip=0; continue; fi
        case "$a" in
            --) return 0 ;;
            --orphan) creates=1; skip=1 ;;
            --orphan=*) creates=1 ;;
            --pathspec-from-file|--pathspec-from-file=*) return 0 ;;
            --*)
                is_long_prefix "$a" force 2 && return 0
                is_long_prefix "$a" patch 2 && return 0
                ;;
            -?*)
                r=$(scan_short_cluster "$a" fp bB)
                case "$r" in
                    D) return 0 ;;
                    V*) creates=1; skip=1 ;;
                    A*) creates=1 ;;
                esac
                ;;
            *) positional+=("$a") ;;
        esac
    done
    [ $creates -eq 1 ] && return 1
    [ ${#positional[@]} -eq 0 ] && return 1
    [ ${#positional[@]} -ge 2 ] && return 0
    [ "${positional[0]}" = "." ] && return 0
    is_ref "$root" "${positional[0]}" && return 1
    return 0
}

switch_is_destructive() { # args...
    local a
    for a in "$@"; do
        case "$a" in
            --) return 1 ;;
            --*)
                is_long_prefix "$a" force 2 && return 0
                is_long_prefix "$a" discard-changes 2 && return 0
                ;;
            -?*) [ "$(scan_short_cluster "$a" f cC)" = D ] && return 0 ;;
        esac
    done
    return 1
}

subcommand_is_destructive() { # target-root subcommand args...
    local root=$1 sub=$2; shift 2
    case "$sub" in
        checkout) checkout_is_destructive "$root" "$@" ;;
        switch) switch_is_destructive "$@" ;;
        restore|reset|clean) return 0 ;;
        # list/show/pop/apply/drop never reach here; every other form, bare
        # `stash`, `push`, `-u`, `clear`, removes changes or entries.
        stash) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Restoring a stash raised in another worktree ---------------------------
#
# refs/stash is ONE stack shared by every worktree of a repository; a linked
# worktree gets no private copy under .git/worktrees/<name>/refs/stash. An entry
# raised anywhere is therefore visible, and poppable, everywhere.
#
# That breaks the same-tree assumption further down. `git -C <own-tree> stash pop`
# has target == caller, so the scope check would allow it, yet the entry it pops
# may have been raised in a sibling tree, on a different branch, by another
# session. Popping it applies those changes to the branch the caller is on and
# removes the entry its owner was going to restore.
#
# Judged on the entry's ORIGIN rather than on the path: `stash list` records it as
# "On <branch>: ...". Restoring an entry raised on the branch you are on is
# ordinary work and stays allowed; restoring one raised elsewhere is the case
# worth refusing.
#
# pop/apply/drop are judged here and not as destructive-by-path: they do not
# remove anything from the target tree, they ADD to it, so the cross-tree
# reasoning does not apply, and treating them as destructive-by-path blocked
# restoring your own stash in your own worktree.
check_stash_origin() { # target args-after-pop/apply/drop...
    local target=$1; shift
    [ -z "$target" ] && return 0

    # Which entry: an explicit stash@{N} if named, otherwise the top of the
    # stack, which is what a bare pop/apply/drop takes.
    local ref='stash@{0}' a
    for a in "$@"; do
        case "$a" in stash@\{*\}) ref=$a; break ;; esac
    done

    # "On <branch>: <message>": the branch the entry was raised on. Empty when
    # the stack is empty or the ref does not resolve, in which case there is
    # nothing to judge and git reports the real error itself.
    local origin current
    origin=$(git -C "$target" log -g --format='%gs' "$ref" 2>/dev/null \
        | head -1 | sed -nE 's/^(On|WIP on) ([^:]+):.*/\2/p' || true)
    current=$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

    [ -n "$origin" ] && [ -n "$current" ] && [ "$origin" != "$current" ] || return 0

    cat >&2 <<EOF
BLOCKED by hook-block-foreign-worktree-git.sh: this restores a stash entry that
was raised somewhere else.

  entry  : $ref, raised on branch '$origin'
  you are on: '$current'

refs/stash is shared by every worktree of this repository; there is no
per-worktree stash stack. This entry may belong to another worktree or another
session, and applying it here puts its changes on YOUR branch while removing the
entry its owner was going to restore.

Check whose it is first:
  git -C $target stash list

If it is yours and you want it here, switch to '$origin' and restore it
there. If you are cleaning up an entry you raised for a measurement, do that from
the worktree that raised it.

For A/B measurements, prefer a method that touches no worktree at all: copy the
sources into a disposable container, or restore explicit paths with
\`git checkout <ref> -- <path>\`.
EOF
    exit 2
}

foreign_root() { # target -> prints the target's worktree root when it is a
    # DIFFERENT worktree of the SAME repository as the caller's; fails otherwise.
    #
    # If either resolution fails the command is not something this hook
    # understands (not a repo, path does not exist), so it is out of scope and
    # git reports the real error.
    local target_root cwd_root target_common cwd_common
    target_root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$target_root" ] || return 1
    cwd_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$cwd_root" ] || return 1

    # Same tree: this is the caller's own working directory, out of scope.
    [ "$target_root" = "$cwd_root" ] && return 1

    # Different trees that do not share a repository are unrelated checkouts.
    # The worktree hazard is specifically about trees sharing one .git, where
    # the sibling is easy to mistake for your own; leave the unrelated case alone.
    target_common=$(git -C "$target_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    cwd_common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    [ "$target_common" = "$cwd_common" ] || return 1

    printf '%s' "$target_root"
}

block_foreign() { # target-root subcommand
    local cwd_root
    cwd_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    cat >&2 <<EOF
BLOCKED by hook-block-foreign-worktree-git.sh: this discards uncommitted work in
a worktree you are not working in.

  you are in : $cwd_root
  target     : $1
  subcommand : git $2

Both are worktrees of the same repository, so the target may hold another
session's uncommitted changes. Restoring it to HEAD destroys them silently.

If you are undoing files you wrote into that tree yourself (e.g. a container
bind-mount wrote them back), restore to WHAT WAS THERE, not to HEAD: copy the
originals aside before the operation that writes, then copy them back and verify
by checksum.

Better still, avoid writing into the other tree in the first place.
EOF

    [ -n "${WORKTREE_GUARD_HINT:-}" ] && printf '\n%s\n' "$WORKTREE_GUARD_HINT" >&2

    cat >&2 <<'EOF'

If you genuinely need this, ask the user first; they may have work in progress
there.
EOF
    exit 2
}

judge_invocation() { # words of one shell command
    local -a words=("$@")
    local n=${#words[@]} i=0 w dir target="" sub=""

    # Find `git` (or a path ending in /git). Words before it are env
    # assignments or wrappers (env, rtk, command, ...).
    while [ "$i" -lt "$n" ]; do
        w=$(strip_quotes "${words[i]}")
        case "$w" in git|*/git) break ;; esac
        i=$((i + 1))
    done
    [ "$i" -ge "$n" ] && return 0
    i=$((i + 1))

    # Global options up to the subcommand. Several -C options apply
    # cumulatively, a relative one resolved against the previous.
    while [ "$i" -lt "$n" ]; do
        w=$(strip_quotes "${words[i]}")
        dir=""
        case "$w" in
            -C) i=$((i + 1)); [ "$i" -lt "$n" ] && dir=$(strip_quotes "${words[i]}") ;;
            -C=*) dir=$(strip_quotes "${w#-C=}") ;;
            -*) case "$GLOBAL_OPTS_WITH_VALUE" in *" $w "*) i=$((i + 1)) ;; esac ;;
            *) sub=$w; i=$((i + 1)); break ;;
        esac
        if [ -n "$dir" ]; then
            dir=$(expand_tilde "$dir")
            case "$dir" in
                /*) target=$dir ;;
                *) target=${target:+$target/}$dir ;;
            esac
        fi
        i=$((i + 1))
    done
    [ -z "$sub" ] && return 0

    local -a args=()
    for w in "${words[@]:i}"; do args+=("$(strip_quotes "$w")"); done

    if [ "$sub" = stash ]; then
        case "${args[0]:-}" in
            list|show) return 0 ;;
            pop|apply|drop) check_stash_origin "$target" "${args[@]:1}"; return 0 ;;
        esac
    fi

    [ -z "$target" ] && return 0
    local root
    root=$(foreign_root "$target") || return 0
    subcommand_is_destructive "$root" "$sub" "${args[@]}" && block_foreign "$root" "$sub"
    return 0
}

# Split the command line into its separate commands and judge each one. A
# backslash-newline continues the same command, so it is joined first; split as a
# line break it would cut `git -C <wt> \` from the `reset --hard` that follows.
SEGMENTS=${COMMAND//$'\\\n'/ }
for sep in "${CHAIN_SEPARATORS[@]}"; do
    SEGMENTS=${SEGMENTS//"$sep"/$'\n'}
done

while IFS= read -r segment; do
    read -ra words <<< "$segment"
    [ ${#words[@]} -eq 0 ] && continue
    judge_invocation "${words[@]}"
done <<< "$SEGMENTS"

exit 0
