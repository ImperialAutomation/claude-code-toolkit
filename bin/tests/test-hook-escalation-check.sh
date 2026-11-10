#!/bin/bash
# Tests for hook-escalation-check.sh.
#
# Usage:
#   bin/tests/test-hook-escalation-check.sh
#
# Drives the REAL hook with a JSON payload on stdin (the shape Claude Code
# sends) and asserts on its exit code (2 = denied, 0 = allowed) and stderr.
# The hook runs the REAL escalation-check.sh next to it against a throwaway
# repository; only `gh` is a stub, put first on PATH. The stub answers
# `gh issue view <n> ... --json labels` from $STUB/labels-<n> (one label per
# line), fails when $STUB/fail exists, and logs every call to $STUB/calls.
#
# Hermetic: $HOME is a temp dir holding the denylist fixture, and no real `gh`
# is ever reached.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${HOOK_UNDER_TEST:-$SCRIPT_DIR/../hook-escalation-check.sh}"

if [[ ! -x "$HOOK" ]]; then
    echo "hook not executable: $HOOK" >&2
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
mkdir -p "$HOME/.claude"
echo "acme-internal" > "$HOME/.claude/escalation-denylist"

# gh stub
STUB="$T/stub"
mkdir -p "$STUB/bin"
cat > "$STUB/bin/gh" <<'EOF'
#!/bin/bash
echo "$PWD|$*" >> "$STUB/calls"
[[ -e "$STUB/fail" ]] && { echo "gh: network down" >&2; exit 1; }
if [[ "$1 $2" == "issue view" ]]; then
    f="$STUB/labels-$3"
    [[ -f "$f" ]] && cat "$f"
    exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
chmod +x "$STUB/bin/gh"
export STUB
export PATH="$STUB/bin:$PATH"

reset_stub() { rm -f "$STUB"/labels-* "$STUB/fail" "$STUB/calls"; }
labels() { # labels <issue> <label>...
    local n="$1"; shift
    printf '%s\n' "$@" > "$STUB/labels-$n"
}
gh_calls() { [[ -f "$STUB/calls" ]] && grep -c . "$STUB/calls" || echo 0; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

R="$T/repo"
git init -q -b main "$R"
mkdir -p "$R/bin" "$R/rules"
echo a > "$R/bin/hook-auto-approve-bash.py"
echo a > "$R/rules/testing.md"
echo a > "$R/README.md"
git -C "$R" add -A
git -C "$R" commit -q -m base

# branch <name> <file>...: a branch off main that changes the given files.
branch() {
    local name="$1"; shift
    git -C "$R" checkout -q -B "$name" main
    local f
    for f in "$@"; do echo change >> "$R/$f"; done
    git -C "$R" add -A
    git -C "$R" commit -q -m change --allow-empty
}

body() { # body <file> <text>
    printf '%s\n' "$2" > "$1"
}
BODY="$T/body.md"
BODY2="$T/body2.md"

OUT=""; RC=0
run() { # run <command> [cwd]
    local cwd="${2:-$T}"
    OUT=$(jq -n --arg c "$1" --arg d "$cwd" '{tool_input:{command:$c},cwd:$d}' \
        | env -C "$cwd" "$HOOK" 2>&1 >/dev/null); RC=$?
}

# The literal tilde is the input under test: the hook sees the command text.
# shellcheck disable=SC2088
WRAP="~/.claude/bin/git-push-pr-merge.sh --repo $R --base main --title t"

echo "== 1. not a PR call: the hook stays out =="
# Allowed is not enough here: a hook that fired would also allow an
# interactive call. Silence on stderr shows it did not look at all.
branch arg-case rules/testing.md
reset_stub
run "grep x bin/git-push-pr-merge.sh" "$R"
check "name as an argument: allowed" "0" "$RC"
check "name as an argument: hook silent" "" "$OUT"
check "name as an argument: no gh call" "0" "$(gh_calls)"
run "grep 'Closes #7' bin/git-push-pr-merge.sh" "$R"
check "name as an argument, closing keyword in the text: no gh call" "0" "$(gh_calls)"
run "ls ~/.claude/bin/ git-push-pr-merge.sh" "$R"
check "listing: allowed" "0" "$RC"
check "listing: hook silent" "" "$OUT"
run "echo gh pr create --body-file $T/missing.md"
check "echoing gh pr create: allowed" "0" "$RC"
run "git status"
check "unrelated command: allowed" "0" "$RC"

echo "== 2. autonomous run (agent-wip), rules/ touched =="
branch rules-only rules/testing.md
reset_stub
labels 7 agent-wip
body "$BODY" $'Summary\n\nCloses #7'
run "$WRAP --body-file $BODY"
check "unapproved global hit: denied" "2" "$RC"
check "deny names the category" "yes" "$(contains "$OUT" "global")"
check "deny tells to add needs-human" "yes" "$(contains "$OUT" "needs-human")"
check "deny tells to post the question as a comment" "yes" "$(contains "$OUT" "comment")"
check "deny names the issue" "yes" "$(contains "$OUT" "#7")"
check "gh was asked for the labels of #7" "yes" "$(contains "$(cat "$STUB/calls")" "issue view 7")"
check "gh ran in the --repo worktree" "yes" "$(contains "$(cat "$STUB/calls")" "$R|")"

run "git fetch && $WRAP --body-file=$BODY"
check "after && and --body-file= spelling: still denied" "2" "$RC"

labels 7 agent-wip approved:global
run "$WRAP --body-file $BODY"
check "approved:global: allowed" "0" "$RC"
check "approved hit is listed on stderr" "yes" "$(contains "$OUT" "global  rules/testing.md")"

echo "== 3. two categories, only one approved =="
branch rules-and-approver rules/testing.md bin/hook-auto-approve-bash.py
reset_stub
labels 7 agent-wip approved:global
run "$WRAP --body-file $BODY"
check "permissions unapproved: denied" "2" "$RC"
check "deny names category permissions" "yes" "$(contains "$OUT" "permissions")"
labels 7 agent-wip approved:global approved:permissions
run "$WRAP --body-file $BODY"
check "both approved: allowed" "0" "$RC"

echo "== 4. interactive session: report, never block =="
reset_stub
labels 7 needs-review
run "$WRAP --body-file $BODY"
check "no agent-wip: allowed" "0" "$RC"
check "no agent-wip: hits on stderr" "yes" "$(contains "$OUT" "permissions  bin/hook-auto-approve-bash.py")"
check "no agent-wip: global hit on stderr too" "yes" "$(contains "$OUT" "global  rules/testing.md")"

reset_stub
body "$BODY2" $'Implements #7\nPart of #3'
run "$WRAP --body-file $BODY2"
check "no closing keyword: allowed" "0" "$RC"
check "no closing keyword: no gh call" "0" "$(gh_calls)"
check "no closing keyword: hits on stderr" "yes" "$(contains "$OUT" "global  rules/testing.md")"

echo "== 5. several closed issues =="
reset_stub
branch rules-again rules/testing.md
labels 7 agent-wip approved:global
labels 8 agent-wip
body "$BODY2" $'Fixes #7\nresolves #8'
run "$WRAP --body-file $BODY2"
check "approval on one of two agent-wip issues: denied" "2" "$RC"
labels 8 agent-wip approved:global
run "$WRAP --body-file $BODY2"
check "approval on both: allowed" "0" "$RC"

echo "== 6. fail closed =="
reset_stub
run "$WRAP --body-file $T/missing.md"
check "body file missing: denied" "2" "$RC"
labels 7 agent-wip approved:global
touch "$STUB/fail"
run "$WRAP --body-file $BODY"
check "gh cannot fetch labels: denied" "2" "$RC"
check "gh failure is named" "yes" "$(contains "$OUT" "labels")"

echo "== 7. clean autonomous diff =="
reset_stub
branch clean README.md
labels 7 agent-wip
run "$WRAP --body-file $BODY"
check "no hit: allowed" "0" "$RC"
check "no hit: quiet" "" "$OUT"

echo "== 8. gh pr create =="
branch rules-gh rules/testing.md
reset_stub
labels 7 agent-wip
run "gh pr create --base main --title t --body-file $BODY" "$R"
check "gh pr create from the worktree cwd: denied" "2" "$RC"
check "gh ran in the cwd" "yes" "$(contains "$(cat "$STUB/calls")" "$R|")"
reset_stub
labels 7 agent-wip
run "gh pr create -R owner/name --base main --title t --body-file $BODY" "$R"
check "gh pr create -R: denied" "2" "$RC"
check "-R is passed on to gh" "yes" "$(contains "$(cat "$STUB/calls")" "--repo owner/name")"
reset_stub
labels 7 agent-wip
run "gh pr create --base main --title t --body 'Closes #7'" "$R"
check "inline --body with a closing keyword: denied" "2" "$RC"
reset_stub
run "gh pr create --base main --title t --body 'just a change'" "$R"
check "inline --body without a closing keyword: allowed" "0" "$RC"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
