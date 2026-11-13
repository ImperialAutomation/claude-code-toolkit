#!/bin/bash
# Tests for skills/release-pr/collect.sh.
#
# Usage:
#   bin/tests/test-release-pr-collect.sh
#
# Each case builds a bare `origin` with the branches it needs and a clone of
# it, then runs collect.sh inside the clone. Only `gh` is a stub, first on
# PATH:
#   - `repo view ... defaultBranchRef` prints $STUB/default (fails when
#     $STUB/default-fail exists);
#   - `label list` prints $STUB/labels, one label name per line;
#   - `pr list` prints nothing (no previous release);
#   - `api .../rules/branches/<b>` prints $STUB/rules and `api .../branches/<b>`
#     prints $STUB/protection, one required check name per line (both fail
#     when $STUB/api-fail exists).
#
# Hermetic: $HOME is a temp dir and no real `gh` or network is reached.
#
# When adding a case, check it actually constrains the script: break the rule
# in collect.sh, confirm THIS test goes red, then revert.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COLLECT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../../skills/release-pr/collect.sh}"

if [[ ! -f "$COLLECT" ]]; then
    echo "script not found: $COLLECT" >&2
    exit 1
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

contains() { # haystack needle -> yes/no
    case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac
}

export HOME="$T/home"
mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_NOSYSTEM=1

STUB="$T/stub"
mkdir -p "$STUB/bin"
cat > "$STUB/bin/gh" <<'EOF'
#!/bin/bash
if [[ "$1 $2" == "repo view" ]]; then
    case " $* " in
        *defaultBranchRef*)
            [[ -e "$STUB/default-fail" ]] && { echo "gh: network down" >&2; exit 1; }
            cat "$STUB/default"; exit 0 ;;
        *nameWithOwner*) echo "owner/name"; exit 0 ;;
    esac
fi
if [[ "$1 $2" == "label list" ]]; then
    cat "$STUB/labels" 2>/dev/null; exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
    exit 0
fi
if [[ "$1" == "api" ]]; then
    [[ -e "$STUB/api-fail" ]] && { echo "gh: HTTP 403" >&2; exit 1; }
    case "$2" in
        */rules/branches/*) cat "$STUB/rules" 2>/dev/null; exit 0 ;;
        */branches/*) cat "$STUB/protection" 2>/dev/null; exit 0 ;;
    esac
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
chmod +x "$STUB/bin/gh"
export STUB
export PATH="$STUB/bin:$PATH"

N=0
# make_repo <default-branch> <branch>... : bare origin holding the branches
# (each one commit on top of a shared root), cloned to $CLONE.
make_repo() {
    local default="$1"; shift
    N=$((N+1))
    local work="$T/work$N"
    git init -q -b root "$work"
    git -C "$work" commit -q --allow-empty -m root
    local b
    for b in "$@"; do
        git -C "$work" branch -q "$b" root
    done
    git -C "$work" checkout -q develop 2>/dev/null \
        && git -C "$work" commit -q --allow-empty -m "feature on develop"
    ORIGIN="$T/origin$N.git"
    git clone -q --bare "$work" "$ORIGIN"
    git -C "$ORIGIN" branch -q -D root
    git -C "$ORIGIN" symbolic-ref HEAD "refs/heads/$default"
    CLONE="$T/clone$N"
    git clone -q "$ORIGIN" "$CLONE"
    WORK="$work"
    echo "$default" > "$STUB/default"
    rm -f "$STUB/default-fail" "$STUB/labels" "$STUB/rules" "$STUB/protection" "$STUB/api-fail"
}

run() { # args... -> RC, OUT (stdout+stderr)
    OUT=$(cd "$CLONE" && bash "$COLLECT" --repo owner/name "$@" 2>&1)
    RC=$?
}

echo "== 1. main-based repo, no --base =="
make_repo main main develop
run
check "exit 0" "0" "$RC"
check "compares develop -> main" "yes" "$(contains "$OUT" "owner/name  (develop -> main)")"
check "behind check OK" "yes" "$(contains "$OUT" "OK: no non-merge commits")"

echo "== 2. default branch is the head (git-flow), master exists =="
make_repo develop master develop
run
check "exit 0" "0" "$RC"
check "falls back to master" "yes" "$(contains "$OUT" "(develop -> master)")"

echo "== 3. default branch is the head, only main exists =="
make_repo develop main develop
run
check "exit 0" "0" "$RC"
check "falls back to main" "yes" "$(contains "$OUT" "(develop -> main)")"

echo "== 4. default branch is the head, no master or main =="
make_repo develop develop
run
check "exit non-zero" "yes" "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "names --base" "yes" "$(contains "$OUT" "--base")"
check "no OK line" "no" "$(contains "$OUT" "OK:")"

echo "== 5. gh cannot read the default branch =="
make_repo main main develop
touch "$STUB/default-fail"
run
check "exit 0" "0" "$RC"
check "falls back to main" "yes" "$(contains "$OUT" "(develop -> main)")"

echo "== 6. --base names a missing branch =="
make_repo main main develop
run --base doesnotexist
check "exit non-zero" "yes" "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "names the missing ref" "yes" "$(contains "$OUT" "origin/doesnotexist")"
check "lists the remote branches" "yes" "$(contains "$OUT" "origin/main")"
check "no OK line" "no" "$(contains "$OUT" "OK:")"
check "no git fatal leaks through" "no" "$(contains "$OUT" "fatal:")"

echo "== 7. --head names a missing branch =="
run --base main --head nope
check "exit non-zero" "yes" "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "names the missing ref" "yes" "$(contains "$OUT" "origin/nope")"
check "no OK line" "no" "$(contains "$OUT" "OK:")"

echo "== 8. base equals head =="
run --base develop --head develop
check "exit non-zero" "yes" "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "no OK line" "no" "$(contains "$OUT" "OK:")"

echo "== 9. hotfix on the base only =="
make_repo main main develop
git -C "$WORK" checkout -q main
git -C "$WORK" commit -q --allow-empty -m "hotfix on main"
git -C "$WORK" push -q "$ORIGIN" main
run
check "exit 0" "0" "$RC"
check "flags the non-merge commit" "yes" "$(contains "$OUT" "hotfix on main")"
check "no OK line" "no" "$(contains "$OUT" "OK:")"

echo "== 10. release machinery absent =="
make_repo main main develop
run
check "labels absent" "yes" "$(contains "$OUT" "release labels: none")"
check "workflow absent" "yes" "$(contains "$OUT" "semver-tag workflow: none")"
check "workflow list absent" "yes" "$(contains "$OUT" "workflows on main: none")"
check "template absent" "yes" "$(contains "$OUT" "AGENT-REVIEW template: none")"
check "semver verdict absent" "yes" "$(contains "$OUT" "semver: absent")"

echo "== 11. release machinery present =="
make_repo main main develop
git -C "$WORK" checkout -q main
mkdir -p "$WORK/.github/workflows"
echo "name: Semver Tag" > "$WORK/.github/workflows/semver-tag.yml"
printf '<!-- AGENT-REVIEW:START -->\n<!-- AGENT-REVIEW:END -->\n' \
    > "$WORK/.github/PULL_REQUEST_TEMPLATE.md"
git -C "$WORK" add .github
git -C "$WORK" commit -q -m "release machinery"
git -C "$WORK" checkout -q develop
git -C "$WORK" merge -q --no-edit main
git -C "$WORK" push -q "$ORIGIN" main develop
printf 'release:major\nrelease:minor\nrelease:patch\n' > "$STUB/labels"
run
check "exit 0" "0" "$RC"
check "labels present" "yes" "$(contains "$OUT" "release labels: release:major release:minor release:patch")"
check "workflow present" "yes" "$(contains "$OUT" "semver-tag workflow: .github/workflows/semver-tag.yml")"
check "workflow list present" "yes" "$(contains "$OUT" "workflows on main: semver-tag.yml")"
check "template present" "yes" "$(contains "$OUT" "AGENT-REVIEW template: .github/PULL_REQUEST_TEMPLATE.md")"
check "semver verdict present" "yes" "$(contains "$OUT" "semver: present")"

echo "== 12. required checks on the release branch =="
make_repo main main develop
run
check "section present" "yes" "$(contains "$OUT" "=== REQUIRED CHECKS")"
check "none when nothing is required" "yes" "$(contains "$OUT" "required on main: none")"
printf 'backend-tests\nvitest\n' > "$STUB/rules"
printf 'vitest\ndependency-audit\n' > "$STUB/protection"
run
check "exit 0" "0" "$RC"
check "rulesets and protection merged, deduplicated" "yes" \
    "$(contains "$OUT" "required on main: backend-tests dependency-audit vitest")"
touch "$STUB/api-fail"
run
check "exit 0 when gh api fails" "0" "$RC"
check "unknown when gh api fails" "yes" "$(contains "$OUT" "required on main: unknown")"
check "no none on failure" "no" "$(contains "$OUT" "required on main: none")"

echo "== 13. SKILL.md carries no em-dash =="
# The global style rule forbids em-dashes in PR titles and bodies; the skill's
# templates and prose are what agents copy into them (#226).
SKILL_MD="$(dirname "$COLLECT")/SKILL.md"
check "SKILL.md exists" "yes" "$([[ -f "$SKILL_MD" ]] && echo yes || echo no)"
check "no em-dash in SKILL.md" "0" "$(grep -c $'—' "$SKILL_MD")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
