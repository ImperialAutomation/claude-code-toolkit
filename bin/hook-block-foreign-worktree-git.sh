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
#     name a commit, or literally a remote branch git would DWIM into a new
#     branch (D7), in the target repository. The remote-branch match is literal,
#     so a pathspec glob such as `*` stays a path.
#   - Only git's own -C sets the target (D6). `env -C <wt> git ...` is the same
#     deliberate act as `cd <wt> && git ...` and is not judged.
#
# How a command is judged
# -----------------------
# By meaning, not by word order. The command line is split into its git
# invocations (a chain may hold several). Per invocation the global options are
# skipped (`-C <dir>`, `-c <k=v>`, `--git-dir=<d>`, `--no-pager`, ...), the first
# remaining word is the subcommand, and only that subcommand's own arguments are
# judged:
#
#   checkout  blocked: bare `--`, -f/--force, -p/--patch, --pathspec-from-file
#             (long options also abbreviated),
#             `.`, two or more positional arguments, or one that is not a ref
#             allowed: -b/-B/--orphan, --detach/--track/--no-track/--quiet and
#             other long options, switching to an existing branch
#             (a trailing `--` with nothing after it only disambiguates a
#             branch, D2)
#   switch    blocked: -f/--force/--discard-changes; everything else allowed
#   restore, reset, clean   always blocked
#   stash     list/show allowed; pop/apply/drop judged on the entry's origin
#             (below); everything else (bare, push, -u, clear, ...) blocked
#   read-tree       blocked: -u together with --reset
#   checkout-index  blocked: -f/--force
#   worktree        blocked: remove with -f/--force
#   anything else (add, grep, log, show, diff, ...)   allowed
#
# A verb that appears as a path or a pattern (`add docs/restore.md`,
# `log --grep=clean`) is therefore never mistaken for the subcommand (#125).
# An alias defined inline (`-c alias.x='reset --hard' x`) is expanded first and
# judged as what it runs; an inline shell alias (`!...`) cannot be judged and
# is blocked.
#
# Words come from lib/shell-tokens.sh, which splits like a shell: quotes
# removed, chain operators and redirects (`2>&1`, `>/dev/null`) as their own
# tokens. A -C target gets `~`, `$VAR` and `${VAR}` expanded from the hook's
# environment.
#
# Fail closed: the parser only allows what it fully understood. When the split
# cannot be trusted (the tokenizer gave up on a quote, a `#` that shlex reads as
# a comment and that swallows the rest, a command substitution inside quotes,
# a backtick, a heredoc), the whole line is also judged the old way: a
# destructive verb anywhere on it plus a -C target in a foreign worktree blocks.
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

# shellcheck source=bin/lib/shell-tokens.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/shell-tokens.sh"

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

# Subcommands that can discard work; any other subcommand is allowed without
# resolving the target, which saves the git calls of foreign_root.
DESTRUCTIVE_CANDIDATES=' checkout switch restore reset clean stash read-tree checkout-index worktree '

# The whole-line verdict for a command the parser could not fully understand
# (see "Fail closed" above): any of these words anywhere on the line.
FALLBACK_DESTRUCTIVE_RE='(checkout[[:space:]]+--|checkout[[:space:]]+-f|checkout-index\b|restore\b|reset\b|clean\b|stash\b|worktree[[:space:]]+remove\b)'

# A `$NAME` or `${NAME}` reference, with the text before and after it.
# shellcheck disable=SC2016  # a literal `$`, not an expansion
VAR_REF_RE='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'

expand_path() { # path -> path with a leading ~ and $VAR/${VAR} expanded
    local p=$1 out="" name
    case "$p" in
        "~") p=$HOME ;;
        "~"/*) p="$HOME/${p#\~/}" ;;
    esac
    while [[ "$p" =~ $VAR_REF_RE ]]; do
        name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
        out+=${BASH_REMATCH[1]}${!name:-}
        p=${BASH_REMATCH[5]}
    done
    printf '%s' "$out$p"
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
        [ -n "$3" ] && case "$3" in *"$c"*)
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
    # tracking branch (DWIM): a branch switch, not a path restore (D7). Compared
    # literally against refs/remotes/<remote>/<name>, never as a ref pattern:
    # a pathspec glob such as `*` must not match every remote branch.
    local ref
    while IFS= read -r ref; do
        ref=${ref#refs/remotes/}
        [ "${ref#*/}" = "$2" ] && return 0
    done < <(git -C "$1" for-each-ref --format='%(refname)' refs/remotes/ 2>/dev/null)
    return 1
}

checkout_is_destructive() { # target-root args...
    local root=$1; shift
    local creates=0 skip=0 a r
    local -a positional=()
    while [ $# -gt 0 ]; do
        a=$1; shift
        if [ $skip -eq 1 ]; then skip=0; continue; fi
        case "$a" in
            # Paths after `--` are restored. A trailing `--` with nothing after
            # it only says the word before it is a branch (D2).
            --) [ $# -gt 0 ] && return 0; break ;;
            --orphan) creates=1; skip=1 ;;
            --orphan=*) creates=1 ;;
            --*)
                # pathspec-fr: shortest prefix not shared with --pathspec-file-nul.
                # No other checkout option starts with f, so `--f` is --force.
                is_long_prefix "$a" pathspec-from-file 11 && return 0
                is_long_prefix "$a" force 1 && return 0
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
                is_long_prefix "$a" force 1 && return 0
                is_long_prefix "$a" discard-changes 2 && return 0
                ;;
            -?*) [ "$(scan_short_cluster "$a" f cC)" = D ] && return 0 ;;
        esac
    done
    return 1
}

read_tree_is_destructive() { # args...: -u with --reset overwrites the tree
    local a update=0 reset=0
    for a in "$@"; do
        case "$a" in
            --) break ;;
            # res: shortest prefix not shared with --recurse-submodules.
            --*) is_long_prefix "$a" reset 3 && reset=1 ;;
            -?*) [ "$(scan_short_cluster "$a" u "")" = D ] && update=1 ;;
        esac
    done
    [ $update -eq 1 ] && [ $reset -eq 1 ]
}

force_flag_given() { # args...: -f or (abbreviated) --force before any `--`
    local a
    for a in "$@"; do
        case "$a" in
            --) return 1 ;;
            --*) is_long_prefix "$a" force 1 && return 0 ;;
            -?*) [ "$(scan_short_cluster "$a" f "")" = D ] && return 0 ;;
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
        read-tree) read_tree_is_destructive "$@" ;;
        # Without force both refuse to overwrite local changes.
        checkout-index) force_flag_given "$@" ;;
        worktree) [ "${1:-}" = remove ] && force_flag_given "${@:2}" ;;
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

    # Which entry: an explicit stash@{N} or its short form N if named, otherwise
    # the top of the stack, which is what a bare pop/apply/drop takes.
    local ref='stash@{0}' a
    for a in "$@"; do
        case "$a" in stash@\{*\}) ref=$a; break ;; esac
        [[ "$a" =~ ^[0-9]+$ ]] && { ref="stash@{$a}"; break; }
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

# The caller's worktree root and common git dir, resolved once per run by
# load_caller_tree: a chain with several git -C calls needs them only once.
CALLER_LOADED=0
CALLER_ROOT=""
CALLER_COMMON=""

tree_and_common() { # [dir] -> two lines: worktree root, absolute common git dir
    git ${1:+-C "$1"} rev-parse --path-format=absolute --show-toplevel --git-common-dir 2>/dev/null
}

load_caller_tree() {
    [ "$CALLER_LOADED" = 1 ] && return 0
    CALLER_LOADED=1
    { IFS= read -r CALLER_ROOT; IFS= read -r CALLER_COMMON; } < <(tree_and_common || true)
}

# Set by foreign_root: the target's worktree root.
FOREIGN_ROOT=""

foreign_root() { # target -> sets FOREIGN_ROOT and succeeds when the target is a
    # DIFFERENT worktree of the SAME repository as the caller's; fails otherwise.
    # Called directly, not in $(...), so the caller's tree stays cached.
    #
    # If either resolution fails the command is not something this hook
    # understands (not a repo, path does not exist), so it is out of scope and
    # git reports the real error.
    local target_root="" target_common=""
    { IFS= read -r target_root; IFS= read -r target_common; } < <(tree_and_common "$1" || true)
    [ -n "$target_root" ] || return 1
    load_caller_tree
    [ -n "$CALLER_ROOT" ] || return 1

    # Same tree: this is the caller's own working directory, out of scope.
    [ "$target_root" = "$CALLER_ROOT" ] && return 1

    # Different trees that do not share a repository are unrelated checkouts.
    # The worktree hazard is specifically about trees sharing one .git, where
    # the sibling is easy to mistake for your own; leave the unrelated case alone.
    [ "$target_common" = "$CALLER_COMMON" ] || return 1

    FOREIGN_ROOT=$target_root
}

block_foreign() { # target-root subcommand
    load_caller_tree
    cat >&2 <<EOF
BLOCKED by hook-block-foreign-worktree-git.sh: this discards uncommitted work in
a worktree you are not working in.

  you are in : $CALLER_ROOT
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
    local n=${#words[@]} i=0 w dir target="" sub="" kv key
    # Inline aliases from `-c alias.<name>=<body>`, keyed by lowercase name:
    # git config variable names are case-insensitive.
    local -A aliases=()

    # Find `git` (or a path ending in /git). Words before it are env
    # assignments or wrappers (env, rtk, command, ...).
    while [ "$i" -lt "$n" ]; do
        case "${words[i]}" in git|*/git) break ;; esac
        i=$((i + 1))
    done
    [ "$i" -ge "$n" ] && return 0
    i=$((i + 1))

    # Global options up to the subcommand. Several -C options apply
    # cumulatively, a relative one resolved against the previous.
    while [ "$i" -lt "$n" ]; do
        w=${words[i]}
        dir=""
        case "$w" in
            -C) i=$((i + 1)); [ "$i" -lt "$n" ] && dir=${words[i]} ;;
            -c)
                i=$((i + 1))
                kv=${words[i]:-}
                if [[ "${kv,,}" == alias.*=* ]]; then
                    kv=${kv#*.}
                    key=${kv%%=*}
                    aliases[${key,,}]=${kv#*=}
                fi
                ;;
            -*) case "$GLOBAL_OPTS_WITH_VALUE" in *" $w "*) i=$((i + 1)) ;; esac ;;
            *) sub=$w; i=$((i + 1)); break ;;
        esac
        if [ -n "$dir" ]; then
            dir=$(expand_path "$dir")
            case "$dir" in
                /*) target=$dir ;;
                *) target=${target:+$target/}$dir ;;
            esac
        fi
        i=$((i + 1))
    done
    [ -z "$sub" ] && return 0

    local -a args=("${words[@]:i}")

    # An inline alias runs its body instead of the name: judge the body. A
    # shell alias (`!...`) runs arbitrary commands this hook cannot judge, so
    # in a foreign worktree it is blocked.
    local body=${aliases[${sub,,}]:-} shell_alias=0
    if [ -n "$body" ]; then
        if [ "${body#!}" != "$body" ]; then
            shell_alias=1
        else
            local -a expansion=()
            read -ra expansion <<< "$body"
            sub=${expansion[0]:-}
            args=("${expansion[@]:1}" "${args[@]}")
        fi
    fi

    if [ "$sub" = stash ] && [ $shell_alias -eq 0 ]; then
        case "${args[0]:-}" in
            list|show) return 0 ;;
            pop|apply|drop) check_stash_origin "$target" "${args[@]:1}"; return 0 ;;
        esac
    fi

    [ -z "$target" ] && return 0
    # Decide on the subcommand before resolving the target: most `git -C`
    # calls (log, status, diff) never need the git calls of foreign_root.
    [ $shell_alias -eq 1 ] || case "$DESTRUCTIVE_CANDIDATES" in *" $sub "*) ;; *) return 0 ;; esac
    foreign_root "$target" || return 0
    [ $shell_alias -eq 1 ] && block_foreign "$FOREIGN_ROOT" "$sub (inline shell alias)"
    subcommand_is_destructive "$FOREIGN_ROOT" "$sub" "${args[@]}" && block_foreign "$FOREIGN_ROOT" "$sub"
    return 0
}

# Is fd number $1 written glued to a redirect (`2>x`) and never apart from one
# (`2 >x`)? Only then is the word before a redirect an fd and no argument:
# `stash pop 1 >/dev/null` pops stash@{1}.
fd_glued_to_redirect() { # digit
    local glued="(^|[[:space:];&|()])$1[<>]" spaced="(^|[[:space:]])$1[[:space:]]+[<>]"
    [[ "$COMMAND" =~ $glued ]] && ! [[ "$COMMAND" =~ $spaced ]]
}

# Fail-closed verdict for a line the parser could not fully understand: the
# whole-line check from before #322. Every -C target on the line is resolved;
# one in a foreign worktree with a destructive verb anywhere on the line blocks.
judge_whole_line() {
    echo "$COMMAND" | grep -qE "$FALLBACK_DESTRUCTIVE_RE" || return 0
    local t
    while IFS= read -r t; do
        t=${t#-C}; t=${t#=}; t=${t#"${t%%[! ]*}"}
        t=${t%\"}; t=${t#\"}; t=${t%\'}; t=${t#\'}
        foreign_root "$(expand_path "$t")" || continue
        block_foreign "$FOREIGN_ROOT" "(command not fully parsed; judged on the whole line)"
    done < <(echo "$COMMAND" | grep -oE -- '-C[= ]+[^ ;&|()`]+' || true)
}

# Can the split of the command line be trusted? Not when shlex gave up (no
# tokens), when a `#` may have been read as a comment that swallows the rest
# (shlex does so mid-word too, as in `${#a[@]}`), when a backtick or a quoted
# `$(...)` hides a command inside one word, or when a heredoc body follows.
split_is_uncertain() {
    [ ${#TOKENS[@]} -eq 0 ] && return 0
    case "$COMMAND" in *'#'*|*'`'*) return 0 ;; esac
    local t
    for t in "${TOKENS[@]}"; do
        # shellcheck disable=SC2016  # a literal `$(`, not an expansion
        case "$t" in *'$('*|'<<'|'<<-') return 0 ;; esac
    done
    return 1
}

# Split the command line into its separate commands and judge each one. Command
# substitution in backticks is a command of its own, so a backtick ends one;
# `$(` and `)` already do, as `(` and `)` are operators.
mapfile -d '' TOKENS < <(shell_tokens "${COMMAND//\`/ ; }")

SEGMENT=()
SKIP_NEXT=0
for tok in "${TOKENS[@]}" ';'; do
    if [ "$SKIP_NEXT" = 1 ]; then SKIP_NEXT=0; continue; fi
    if ! [[ "$tok" =~ ^[\;\&\|\(\)\<\>]+$ ]]; then
        SEGMENT+=("$tok")
        continue
    fi
    if [[ "$tok" == *[\;\(\)]* || ! "$tok" =~ [\<\>] ]]; then
        # Chain operator(s), possibly clustered (`);`, `)>`, `<(`): the
        # command ends here.
        [ ${#SEGMENT[@]} -gt 0 ] && judge_invocation "${SEGMENT[@]}"
        SEGMENT=()
        # A redirect after the last `;`, `(` or `)` (`)>/dev/null`) still
        # takes the next word as its target.
        [[ "${tok##*[;()]}" =~ [\<\>] ]] && SKIP_NEXT=1
    else
        # A redirect and its target are no arguments. Drop an fd number written
        # before it too (`2>&1` tokenizes as 2, >&, 1).
        if [ ${#SEGMENT[@]} -gt 1 ] && [[ "${SEGMENT[-1]}" =~ ^[0-9]$ ]] \
           && fd_glued_to_redirect "${SEGMENT[-1]}"; then
            unset 'SEGMENT[-1]'
        fi
        SKIP_NEXT=1
    fi
done

split_is_uncertain && judge_whole_line

exit 0
