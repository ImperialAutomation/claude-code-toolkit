#!/usr/bin/env bash
# git-resolve-worktree.sh — Resolve a worktree hint to one absolute path.
#
# Why this exists
# ---------------
# An agent's working directory resets between every Bash call, so "work in that
# other worktree" cannot be held in shell state. Every command has to carry the
# target path explicitly. This script turns a short, human-sized hint into the
# one absolute path those commands need, and refuses to guess when the hint is
# ambiguous — a wrong worktree fails silently, which is the failure mode worth
# spending an exit code on.
#
# Usage:
#   git-resolve-worktree.sh                 # the worktree the caller is in
#   git-resolve-worktree.sh --issue 42      # the worktree on branch issue-42-*
#   git-resolve-worktree.sh dev1            # substring of a worktree path
#   git-resolve-worktree.sh /abs/path       # an absolute path, validated
#
# Options:
#   --issue N   Prefer the worktree whose branch is `issue-N-<slug>`. Combined
#               with a hint, the hint decides and --issue is ignored.
#
# Output:
#   success  one absolute worktree root on stdout, exit 0
#   failure  nothing on stdout, diagnosis and candidates on stderr, exit 1
#
# Exit codes:
#   0 = resolved   1 = unresolvable (no match, ambiguous, not a worktree)
#   2 = usage error

set -uo pipefail

ISSUE=""
HINT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            [[ $# -ge 2 ]] || { echo "usage: git-resolve-worktree.sh [--issue N] [hint]" >&2; exit 2; }
            ISSUE="$2"
            shift 2
            ;;
        --issue=*)
            ISSUE="${1#--issue=}"
            shift
            ;;
        -h|--help)
            echo "usage: git-resolve-worktree.sh [--issue N] [hint]" >&2
            exit 2
            ;;
        -*)
            echo "usage: git-resolve-worktree.sh [--issue N] [hint]" >&2
            exit 2
            ;;
        *)
            [[ -n "$HINT" ]] && { echo "usage: git-resolve-worktree.sh [--issue N] [hint]" >&2; exit 2; }
            HINT="$1"
            shift
            ;;
    esac
done

# Everything is judged against the repository the caller is standing in. Without
# one there is no worktree list to search and no sane default to fall back to.
CURRENT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$CURRENT_ROOT" ]]; then
    echo "git-resolve-worktree.sh: not inside a git repository" >&2
    exit 1
fi

# Collect the repository's worktrees as `<path>\t<branch>` lines. --porcelain is
# the stable machine format; a detached worktree gets an empty branch field
# rather than being dropped, so it can still be matched by path and can still be
# listed as a candidate.
WORKTREES=$(
    git worktree list --porcelain 2>/dev/null |
    awk '
        /^worktree /        { if (path != "") print path "\t" branch; path = substr($0, 10); branch = "" }
        /^branch refs\/heads\// { branch = substr($0, 19) }
        END                 { if (path != "") print path "\t" branch }
    '
)

field() { # line index
    printf '%s' "$1" | cut -f"$2"
}

# Report every worktree with its branch, so a failed resolve tells the caller
# what they could have meant instead of just that they were wrong.
list_candidates() { # lines...
    local line path branch
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        path=$(field "$line" 1)
        branch=$(field "$line" 2)
        printf '  %s  [%s]\n' "$path" "${branch:-detached}" >&2
    done <<< "$1"
}

# Narrow to at most one worktree, or explain why that was not possible. Nothing
# is ever printed to stdout on failure: callers capture stdout in `$(...)`, so a
# guess there would be indistinguishable from a real answer.
select_one() { # matches description
    local matches="$1" description="$2" count
    count=$(grep -c . <<< "$matches")
    [[ -z "$matches" ]] && count=0

    if [[ "$count" -eq 1 ]]; then
        field "$matches" 1
        return 0
    fi

    if [[ "$count" -eq 0 ]]; then
        echo "git-resolve-worktree.sh: $description matches no worktree of this repository." >&2
    else
        echo "git-resolve-worktree.sh: $description matches $count worktrees:" >&2
        list_candidates "$matches"
        echo "Be more specific — pass a longer hint or the absolute path." >&2
    fi

    if [[ "$count" -eq 0 ]]; then
        echo "Known worktrees:" >&2
        list_candidates "$WORKTREES"
    fi
    return 1
}

# 1. An explicit hint decides, because the caller said it out loud. Two forms,
#    tried in order of how specific they are.
if [[ -n "$HINT" ]]; then
    # Expand a leading ~ so a shell-quoted path still resolves.
    case "$HINT" in "~"/*) HINT="$HOME/${HINT#\~/}" ;; esac

    # 1a. A path: validated against this repository's worktree list, never
    #     trusted on sight. A typo that happens to be a real directory
    #     elsewhere, or a worktree of another project, must fail loudly.
    if [[ "$HINT" == /* || "$HINT" == ./* || "$HINT" == ../* ]]; then
        HINT_ROOT=$(git -C "$HINT" rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -z "$HINT_ROOT" ]]; then
            echo "git-resolve-worktree.sh: '$HINT' is not inside a git worktree." >&2
            echo "Known worktrees:" >&2
            list_candidates "$WORKTREES"
            exit 1
        fi
        MATCHES=$(awk -F'\t' -v root="$HINT_ROOT" '$1 == root' <<< "$WORKTREES")
        select_one "$MATCHES" "path '$HINT_ROOT'" || exit 1
        exit 0
    fi

    # 1b. An exact name wins outright. Worktree siblings are conventionally named
    #     by suffixing the main tree (`<repo>`, `<repo>-dev1`, `<repo>-dev2`), so
    #     the main tree's own name is a substring of every sibling. Under a plain
    #     substring rule, typing the exact name of the main tree matches all of
    #     them and resolves to nothing — making the most common target the one
    #     tree you cannot name without an absolute path. Exact-beats-partial is
    #     how tab-completion and package managers already behave.
    MATCHES=$(awk -F'\t' -v hint="$HINT" '
        BEGIN { hint = tolower(hint) }
        {
            path = tolower($1)
            base = path
            sub(/^.*\//, "", base)
            if (base == hint || path == hint) print
        }
    ' <<< "$WORKTREES")

    # 1c. Otherwise a substring, case-insensitively. Short enough to type, and
    #     unique matching is what keeps it honest.
    if [[ -z "$MATCHES" ]]; then
        MATCHES=$(awk -F'\t' -v hint="$HINT" '
            BEGIN { hint = tolower(hint) }
            index(tolower($1), hint) > 0
        ' <<< "$WORKTREES")
    fi

    select_one "$MATCHES" "hint '$HINT'" || exit 1
    exit 0
fi

# 2. --issue: the branch convention `issue-<nr>-<slug>` makes the worktree
#    derivable on resumed work, so the caller types nothing. The trailing dash
#    is load-bearing: without it `--issue 7` also matches `issue-77-...`.
if [[ -n "$ISSUE" ]]; then
    MATCHES=$(awk -F'\t' -v prefix="issue-$ISSUE-" 'index($2, prefix) == 1' <<< "$WORKTREES")

    # No worktree on that branch is not an error. --issue is a detection attempt
    # the CALLER makes on every run, not something the user typed: on new work
    # the branch does not exist yet, which is the normal case, not a mistake.
    # Falling through to the current worktree gives the same answer as no
    # argument at all. Failing here would instead hand back no path, and whatever
    # picks up the pieces would be guessing — the exact failure this script
    # exists to prevent.
    #
    # Several matches IS an error: the branch convention is supposed to be
    # unique, so two trees on `issue-N-*` is a genuine ambiguity to report.
    if [[ -n "$MATCHES" ]]; then
        select_one "$MATCHES" "issue $ISSUE" || exit 1
        exit 0
    fi
fi

# 3. No hint and no issue: the caller's own tree. Unchanged behaviour for the
#    single-worktree case, which is most repositories most of the time.
echo "$CURRENT_ROOT"
