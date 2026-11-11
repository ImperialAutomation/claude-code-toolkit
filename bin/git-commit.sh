#!/usr/bin/env bash
# git-commit.sh — Commit with a message passed as argument or from stdin.
#
# Avoids heredoc/multiline issues in Claude Code sub-agents by writing
# the message to a temp file and using git commit -F.
#
# Usage:
#   git-commit.sh "Single line commit message"
#   git-commit.sh "Multi-line" "commit message" "each arg is a line"
#   echo "message" | git-commit.sh --stdin
#   git-commit.sh --file /tmp/msg.txt
#   git-commit.sh -- "-a line that starts with a dash"
#
# Options:
#   --file F   Read commit message from file F
#   --stdin    Read commit message from stdin
#   --amend    Amend the previous commit (use with caution)
#   --repo D, --repo=D
#              Run git in repository directory D (avoids a leading `cd`, which
#              would break the Bash(~/.claude/bin/*) permission match)
#   --allow-protected
#              Commit even when the target tree is on a protected branch
#   -h, --help Print this help and exit, without touching git
#   --         End of options: every later argument is a message line
#
# Argument errors (exit 2, nothing committed):
#   - an unknown option: any argument of a dash followed by a non-space
#     character (`--ammend`, `--add`, `-m`). Message lines like "- a bullet"
#     and "" are not options. A line that really starts with `-x` goes after `--`.
#   - --file or --stdin together with message arguments, or with each other:
#     the message has one source, extra lines are never silently dropped.
#   - --file or --repo without a value.
#
# Protected branches:
#   In repos where every change reaches the base branch through a PR, a commit
#   on develop/master/main is always a mistake. This script refuses it, because
#   it is the one choke point every agent commit passes through — a check here
#   runs whether or not the agent remembered the rule.
#
#   Which branches are protected is per repo, read from the first source that
#   exists:
#     1. <repo>/.claude/protected-branches — one branch name per line; blank
#        lines and lines starting with # are ignored
#     2. git config --get-all toolkit.protectedBranch
#   Neither present: nothing is protected, which is the default. Repos that
#   commit straight to main are therefore unaffected.
#
#   Names match exactly, no globbing. Detached HEAD is always allowed (rebase,
#   bisect, cherry-pick sequences).
#
#   Commit the .claude/protected-branches file. Untracked, it exists only in the
#   tree where it was created, so a linked worktree sees no config and the guard
#   never fires there, which is exactly where the mistake happens most. The git
#   config route has no such gap: worktrees share .git/config.
#
# Read-only pre-commit cache:
#   Under the Claude Code sandbox ~/.cache/pre-commit is read-only, and
#   pre-commit dies with a long Python traceback (EROFS) before any hook runs.
#   The fix is always to rerun the commit outside the sandbox, but the traceback
#   does not say so. When a commit fails and its stderr holds both
#   "Read-only file system" and a pre-commit marker ("pre-commit", or the value
#   of $PRE_COMMIT_HOME), one hint line is printed after git's own output. The
#   output and exit status are otherwise unchanged. PRE_COMMIT_HOME is never
#   redirected automatically: hook environments live in that cache, and a fresh
#   one re-downloads every hook repo, which needs network the sandbox may block.

set -euo pipefail

# Resolved from BASH_SOURCE, not the cwd: this script is called from arbitrary
# working directories, and bin/ is reached through a symlink.
# shellcheck source=bin/lib/strip-sandbox-noise.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/strip-sandbox-noise.sh"

readonly EROFS_MARKER="Read-only file system"
readonly PRECOMMIT_MARKER="pre-commit"
readonly PRECOMMIT_EROFS_HINT="git-commit.sh: pre-commit cannot write its cache (read-only, likely the sandbox). Nothing was committed; rerun this commit outside the sandbox."

# Temp files removed on any exit; set once so both commit paths share one trap.
TMPFILE=""
CAPTURE=""
trap 'rm -f ${TMPFILE:+"$TMPFILE"} ${CAPTURE:+"$CAPTURE"}' EXIT

# True when the captured stderr shows pre-commit failing on a read-only path.
is_precommit_erofs() { # capture-file
    grep -qF -- "$EROFS_MARKER" "$1" || return 1
    grep -qF -- "$PRECOMMIT_MARKER" "$1" && return 0
    [[ -n "${PRE_COMMIT_HOME:-}" ]] && grep -qF -- "$PRE_COMMIT_HOME" "$1"
}

# Run `git commit "$@"` through the sandbox-noise filter, with its stderr also
# copied to a capture file, and print the read-only cache hint when it applies.
# Returns git's own status.
#
# Only stderr is captured: git sends a hook's stdout to its own stderr as well,
# so every line pre-commit prints passes through here, and git's stdout (the
# commit summary) stays untouched. fd 3 carries git's stdout past the pipe, as
# in git_filtered. tee writes stderr straight back to fd 2 while capturing, so
# the output still streams live; the pipeline is synchronous, so the hint is
# printed only after all of it.
commit_with_hint() {
    local rc
    CAPTURE=$(mktemp /tmp/git-commit-stderr-XXXXXX)
    # set +e: a failing commit is the case under inspection, not a reason to
    # abort before the hint. PIPESTATUS[0] is git_filtered's, i.e. git's status.
    set +e
    { git_filtered commit "$@" 2>&1 1>&3 3>&- | tee "$CAPTURE" >&2; } 3>&1
    rc=${PIPESTATUS[0]}
    set -e
    if [[ $rc -ne 0 ]] && is_precommit_erofs "$CAPTURE"; then
        echo "$PRECOMMIT_EROFS_HINT" >&2
    fi
    return "$rc"
}

AMEND=""
FROM_STDIN=""
FROM_FILE=""
REPO_DIR=""
ALLOW_PROTECTED=""
MSG_ARGS=()

readonly EXIT_USAGE=2

# Print the header comment block (minus the shebang) as the help text.
print_help() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

usage_error() { # message
    echo "Error: $1" >&2
    echo "Run 'git-commit.sh --help' for usage." >&2
    exit "$EXIT_USAGE"
}

# Refuses an option given as the last argument, instead of letting `set -u`
# die on an unbound $2.
require_value() { # option remaining-argc
    [[ $2 -ge 2 ]] || usage_error "$1 requires a value."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        --)
            shift
            MSG_ARGS+=("$@")
            break
            ;;
        --stdin)
            FROM_STDIN=1
            shift
            ;;
        --file)
            require_value "$1" $#
            FROM_FILE="$2"
            shift 2
            ;;
        --repo)
            require_value "$1" $#
            REPO_DIR="$2"
            shift 2
            ;;
        --repo=*)
            REPO_DIR="${1#--repo=}"
            shift
            ;;
        --amend)
            AMEND="--amend"
            shift
            ;;
        --allow-protected)
            ALLOW_PROTECTED=1
            shift
            ;;
        -[!\ ]*)
            # A dash followed by a non-space: an option this script does not
            # know. Taken as a message line it would commit whatever is staged,
            # with the typo as message (#129). "- bullet" lines do not match.
            usage_error "unknown option '$1'."
            ;;
        *)
            MSG_ARGS+=("$1")
            shift
            ;;
    esac
done

# One message source: lines passed next to --file or --stdin would otherwise
# be dropped without a word, and a trailer among them lost.
if [[ -n "$FROM_FILE" && -n "$FROM_STDIN" ]]; then
    usage_error "--file and --stdin cannot be combined."
fi
if [[ ( -n "$FROM_FILE" || -n "$FROM_STDIN" ) && ${#MSG_ARGS[@]} -gt 0 ]]; then
    usage_error "message arguments cannot be combined with --file or --stdin; put every line in the one source."
fi

# Switch into the repository if requested, so the caller need not prefix the
# command with `cd` (which would break the permission allow-match).
if [[ -n "$REPO_DIR" ]]; then
    cd "$REPO_DIR" || { echo "Error: cannot cd into repo '$REPO_DIR'." >&2; exit 1; }
fi

# Protected-branch guard. Runs after the --repo cd, so it reads the branch of the
# tree being committed to rather than the caller's — the two differ whenever a
# session works in a linked worktree, which is exactly when the mistake happens.
#
# Placed before every commit path (--file, --stdin, message args) and before the
# temp file is written, so a refusal leaves nothing behind.
if [[ -z "$ALLOW_PROTECTED" ]]; then
    # Fails on detached HEAD, which is deliberately allowed: rebases and bisects
    # commit there routinely and no base branch is at risk.
    CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)

    if [[ -n "$CURRENT_BRANCH" ]]; then
        PROTECTED=()
        # --show-toplevel rather than the cwd: the config file lives at the repo
        # root, and this script is routinely called from a subdirectory.
        REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null || true)
        PROTECTED_FILE="$REPO_TOP/.claude/protected-branches"

        if [[ -n "$REPO_TOP" && -f "$PROTECTED_FILE" ]]; then
            # The file is the single source when present; git config is not
            # merged in, so "why is this branch protected" has one answer.
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%%#*}"                 # strip comments
                line="${line#"${line%%[![:space:]]*}"}"  # strip leading space
                line="${line%"${line##*[![:space:]]}"}"  # strip trailing space
                [[ -n "$line" ]] && PROTECTED+=("$line")
            done < "$PROTECTED_FILE"
        else
            while IFS= read -r line; do
                [[ -n "$line" ]] && PROTECTED+=("$line")
            done < <(git config --get-all toolkit.protectedBranch 2>/dev/null || true)
        fi

        for protected in ${PROTECTED+"${PROTECTED[@]}"}; do
            if [[ "$CURRENT_BRANCH" == "$protected" ]]; then
                echo "Error: refusing to commit on protected branch '$CURRENT_BRANCH'." >&2
                echo "Create a branch first (git -C $(pwd) switch -c <name>), or pass --allow-protected." >&2
                exit 1
            fi
        done
    fi
fi

# --file: use the file directly, no temp file needed
if [[ -n "$FROM_FILE" ]]; then
    if [[ ! -s "$FROM_FILE" ]]; then
        echo "Error: File '$FROM_FILE' does not exist or is empty." >&2
        exit 1
    fi
    # Not `exec`: exec replaces this shell, leaving nothing to filter git's
    # stderr. The status is propagated explicitly instead, so callers see the
    # same exit code they did before.
    # shellcheck disable=SC2086  # $AMEND is intentionally word-split (may be empty)
    commit_with_hint $AMEND -F "$FROM_FILE"
    exit $?
fi

TMPFILE=$(mktemp /tmp/commit-msg-XXXXXX.txt)

if [[ -n "$FROM_STDIN" ]]; then
    cat > "$TMPFILE"
elif [[ ${#MSG_ARGS[@]} -gt 0 ]]; then
    # Join arguments with newlines (each arg = one line)
    printf '%s\n' "${MSG_ARGS[@]}" > "$TMPFILE"
else
    echo "Error: No commit message provided." >&2
    echo "Usage: git-commit.sh \"message\" or echo \"message\" | git-commit.sh --stdin" >&2
    exit 1
fi

# Verify the message is not empty
if [[ ! -s "$TMPFILE" ]]; then
    echo "Error: Commit message is empty." >&2
    exit 1
fi

# Not `exec`, for the same reason as the --file path above.
# shellcheck disable=SC2086  # $AMEND is intentionally word-split (may be empty)
commit_with_hint $AMEND -F "$TMPFILE"
exit $?
