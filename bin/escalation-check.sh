#!/usr/bin/env bash
# escalation-check.sh — flag a branch diff that falls in an escalation category.
#
# Usage:
#   escalation-check.sh [--repo <worktree>] [--base <branch>]
#
# Compares HEAD of <worktree> (default: the current directory) with its merge
# base against <base> (default: git-find-base-branch). origin/<base> is used
# when it exists, because that is what the PR is compared against; otherwise
# the local <base>. Prints one line per hit:
#
#   <category>  <file>  <reason>
#
# <category> is the key the `approved:<key>` labels use. Categories and checks
# (the list itself: docs/escalation-list.md):
#
#   permissions  Any change to a file that can approve, or that enforces this
#                check: bin/hook-auto-approve-bash.{py,sh},
#                claude-md/settings-global.jsonc, claude-md/settings-template.jsonc,
#                .claude/settings*.json, bin/escalation-check.sh,
#                bin/hook-escalation-check.sh. Deny-only hooks and test files do
#                not count. A diff cannot tell widening from narrowing, so this
#                over-escalates on purpose.
#   leakage      An added line matching ~/.claude/escalation-denylist: one
#                case-insensitive extended regex per line, `#` starts a comment
#                line, blank lines are skipped. The hit names the file, the
#                added line's number and the denylist line, never the matched
#                text, so the report can be quoted in a public issue. A missing
#                or unreadable denylist, or an invalid pattern, is a hit
#                (fail closed).
#   interface    A file under bin/ or skills/ deleted or renamed, or a changed
#                `argument-hint:` line in a modified SKILL.md.
#   global       Any change under rules/ or claude-md/.
#
# Test files (bin/tests/*, bin/test-*) never count for permissions or
# interface. Scope changes (category 5) cannot be read from a diff and stay
# agent judgment.
#
# Only committed changes count (merge base..HEAD): that is what a PR carries.
#
# Exit codes:
#   0  clean: no hit
#   1  at least one hit
#   2  usage error, or the diff could not be computed

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DENYLIST="$HOME/.claude/escalation-denylist"

usage() {
    echo "usage: $(basename "$0") [--repo <worktree>] [--base <branch>]" >&2
    exit 2
}

repo=""
base=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        --repo) [[ $# -ge 2 ]] || usage; repo="$2"; shift 2 ;;
        --repo=*) repo="${1#*=}"; shift ;;
        --base) [[ $# -ge 2 ]] || usage; base="$2"; shift 2 ;;
        --base=*) base="${1#*=}"; shift ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

if [[ -n "$repo" ]]; then
    cd "$repo" 2>/dev/null || { echo "error: cannot cd into '$repo'" >&2; exit 2; }
fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "error: not a git work tree: $PWD" >&2; exit 2; }

if [[ -z "$base" ]]; then
    base=$("$SCRIPT_DIR/git-find-base-branch" 2>/dev/null) || base=""
    [[ -n "$base" ]] || { echo "error: could not detect the base branch; pass --base" >&2; exit 2; }
fi

base_ref=""
for cand in "origin/$base" "$base"; do
    if git rev-parse --verify --quiet "$cand^{commit}" >/dev/null 2>&1; then
        base_ref="$cand"
        break
    fi
done
[[ -n "$base_ref" ]] || { echo "error: base branch not found: $base" >&2; exit 2; }

mb=$(git merge-base "$base_ref" HEAD 2>/dev/null) \
    || { echo "error: no merge base between $base_ref and HEAD" >&2; exit 2; }

# Fixed output shape whatever the user's git config says.
GIT_DIFF=(git -c core.quotePath=false diff --no-color --no-ext-diff
          --src-prefix=a/ --dst-prefix=b/)

HITS=0
hit() { # <category> <file> <reason>
    printf '%s  %s  %s\n' "$1" "$2" "$3"
    HITS=$((HITS + 1))
}

is_test() {
    case "$1" in bin/tests/*|bin/test-*) return 0 ;; esac
    return 1
}

can_approve() {
    case "$1" in
        bin/hook-auto-approve-bash.py|bin/hook-auto-approve-bash.sh) return 0 ;;
        claude-md/settings-global.jsonc|claude-md/settings-template.jsonc) return 0 ;;
        .claude/settings*.json) return 0 ;;
        bin/escalation-check.sh|bin/hook-escalation-check.sh) return 0 ;;
    esac
    return 1
}

is_interface() {
    is_test "$1" && return 1
    case "$1" in bin/*|skills/*) return 0 ;; esac
    return 1
}

is_global() {
    case "$1" in rules/*|claude-md/*) return 0 ;; esac
    return 1
}

NAME_STATUS=$("${GIT_DIFF[@]}" --name-status -M "$mb" HEAD) \
    || { echo "error: git diff failed" >&2; exit 2; }

while IFS=$'\t' read -r status old new; do
    [[ -n "$status" ]] || continue
    paths=("$old")
    [[ -n "${new:-}" ]] && paths+=("$new")
    code="${status:0:1}"

    # 1. permissions
    for p in "${paths[@]}"; do
        if can_approve "$p"; then
            hit permissions "$p" "changes a file that can approve commands or enforces the escalation check"
            break
        fi
    done

    # 3. interface
    if [[ "$code" == D ]] && is_interface "$old"; then
        hit interface "$old" "deleted; skills or downstream repos may call it"
    elif [[ "$code" == R ]] && is_interface "$old"; then
        hit interface "$old" "renamed to $new; skills or downstream repos may call it"
    elif [[ "$code" == M && "$old" == skills/*/SKILL.md ]]; then
        if "${GIT_DIFF[@]}" -U0 "$mb" HEAD -- "$old" | grep -qE '^[-+][[:space:]]*argument-hint:'; then
            hit interface "$old" "argument-hint changed"
        fi
    fi

    # 4. global
    for p in "${paths[@]}"; do
        if is_global "$p"; then
            hit global "$p" "changes rules/ or claude-md/, which every session loads"
            break
        fi
    done
done <<< "$NAME_STATUS"

# 2. leakage
if [[ ! -f "$DENYLIST" || ! -r "$DENYLIST" ]]; then
    hit leakage "-" "no readable denylist at $DENYLIST (fail closed)"
else
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    # Added lines as two parallel files: "<file>\t<line>" and the line's text,
    # so a grep -n over the texts maps straight back to file and line.
    if ! "${GIT_DIFF[@]}" -U0 "$mb" HEAD > "$WORK/patch"; then
        echo "error: git diff failed" >&2
        exit 2
    fi
    awk -v meta="$WORK/meta" -v text="$WORK/text" '
        /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
        /^@@ /     { split($3, a, ","); n = substr(a[1], 2) + 0; next }
        /^\+/      { print f "\t" n > meta; print substr($0, 2) > text; n++ }
    ' "$WORK/patch"
    touch "$WORK/meta" "$WORK/text"

    k=0
    while IFS= read -r pat || [[ -n "$pat" ]]; do
        k=$((k + 1))
        pat="${pat%$'\r'}"
        pat="${pat#"${pat%%[![:space:]]*}"}"
        pat="${pat%"${pat##*[![:space:]]}"}"
        [[ -z "$pat" || "$pat" == \#* ]] && continue
        matches=$(grep -niE -- "$pat" "$WORK/text" 2>/dev/null)
        rc=$?
        if [[ $rc -ge 2 ]]; then
            hit leakage "-" "denylist line $k is not a valid extended regex (fail closed)"
            continue
        fi
        [[ $rc -eq 0 ]] || continue
        while IFS=: read -r idx _; do
            IFS=$'\t' read -r file line < <(sed -n "${idx}p" "$WORK/meta")
            hit leakage "$file" "added line $line matches denylist line $k"
        done <<< "$matches"
    done < "$DENYLIST"
fi

[[ $HITS -eq 0 ]] || exit 1
exit 0
