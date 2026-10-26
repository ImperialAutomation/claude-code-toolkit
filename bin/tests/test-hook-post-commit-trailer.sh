#!/bin/bash
# Tests for hook-post-commit-trailer.sh.
#
# Usage:
#   bin/tests/test-hook-post-commit-trailer.sh
#
# Exercises the hook against throwaway git repos in a temp dir. Nothing outside
# that temp dir is touched. Exits non-zero on the first failing expectation.
#
# The hook rewrites commits (git commit --amend), so the guards that stop it
# from rewriting the WRONG commit are the load-bearing part. Cases 3-6 and 9
# exist for those guards specifically: case 9 (already pushed) is what keeps the
# hook from rewriting published history, and it was added after a mutation run
# showed the suite stayed green with that guard deleted. Cases 10-26 guard the
# target resolution: the cwd repo there holds another session's fresh commit.
#
# Every message to the model must arrive as PostToolUse additionalContext JSON
# on stdout; every silent skip must leave stdout empty.

# The commands fed to the hook are text, not shell: a literal `~` or `$WT` in
# them is exactly what the hook has to cope with.
# shellcheck disable=SC2088,SC2016

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${HOOK_UNDER_TEST:-$SCRIPT_DIR/../hook-post-commit-trailer.sh}"

if [[ ! -f "$HOOK" ]]; then
    echo "hook not found: $HOOK" >&2
    exit 1
fi

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected $2, got $3)"; FAIL=$((FAIL+1)); fi
}

has_trailer() {
    git -C "$1" log -1 --format='%B' | grep -qi "^Co-Authored-By:" && echo yes || echo no
}

fire() { # repodir command  — feed the hook a PostToolUse payload
    printf '{"tool_input":{"command":%s},"cwd":%s}' \
        "$(jq -Rn --arg c "$2" '$c')" "$(jq -Rn --arg d "$1" '$d')" | bash "$HOOK" &>/dev/null
}

# The hook reports to the model through stdout JSON, not stderr: a PostToolUse
# hook's stderr on exit 0 never reaches the model.
OUT="$T/stdout"
fire_out() { # repodir command  — like fire, but keeps the hook's stdout in $OUT
    printf '{"tool_input":{"command":%s},"cwd":%s}' \
        "$(jq -Rn --arg c "$2" '$c')" "$(jq -Rn --arg d "$1" '$d')" | bash "$HOOK" >"$OUT" 2>/dev/null
}

context_has() { # pattern  — stdout is exactly one PostToolUse additionalContext object containing it
    jq -se --arg p "$1" 'length == 1
        and .[0].hookSpecificOutput.hookEventName == "PostToolUse"
        and (.[0].hookSpecificOutput.additionalContext | contains($p))' \
        "$OUT" >/dev/null 2>&1 && echo yes || echo no
}

stdout_empty() { # label
    check "$1: stdout empty" "" "$(<"$OUT")"
}

newrepo() {
    local d="$T/$1"; mkdir -p "$d"; git -C "$d" init -q
    git -C "$d" config user.email t@t; git -C "$d" config user.name T
    echo x > "$d/f"; git -C "$d" add f
    echo "$d"
}

echo "== 1. plain commit without trailer -> added =="
R=$(newrepo r1); git -C "$R" commit -qm "feat: thing"
fire_out "$R" "git -C $R commit -m 'feat: thing'"
check "trailer added" yes "$(has_trailer "$R")"
# Model-neutral: the PostToolUse payload carries no model name.
check "trailer text" "Co-Authored-By: Claude <noreply@anthropic.com>" \
    "$(git -C "$R" log -1 --format='%B' | grep -i '^Co-Authored-By:')"
# The amend changed the SHA; the model must hear that before it pushes.
check "context says trailer added" yes "$(context_has "added missing")"

echo "== 2. commit that already has a trailer -> untouched =="
R=$(newrepo r2)
git -C "$R" commit -qm "feat: thing

Co-Authored-By: Someone <s@example.com>"
BEFORE=$(git -C "$R" rev-parse HEAD)
fire_out "$R" "git -C $R commit -m x"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
stdout_empty "trailer present"

echo "== 3. non-commit bash call -> untouched =="
R=$(newrepo r3); git -C "$R" commit -qm "feat: thing"
BEFORE=$(git -C "$R" rev-parse HEAD)
fire_out "$R" "git -C $R log --oneline -5"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
check "no trailer added" no "$(has_trailer "$R")"
stdout_empty "no commit"

echo "== 4. old commit (>120s) -> untouched =="
R=$(newrepo r4)
GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$R" commit -qm "feat: old" --date "2020-01-01T00:00:00"
BEFORE=$(git -C "$R" rev-parse HEAD)
fire_out "$R" "git -C $R commit -m x"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
stdout_empty "old commit"

echo "== 5. merge commit -> untouched =="
R=$(newrepo r5); git -C "$R" commit -qm base
git -C "$R" checkout -qb side; echo y > "$R/g"; git -C "$R" add g; git -C "$R" commit -qm side
git -C "$R" checkout -q master 2>/dev/null || git -C "$R" checkout -q main
echo z > "$R/h"; git -C "$R" add h; git -C "$R" commit -qm mainline
git -C "$R" merge --no-ff -q side -m "Merge branch 'side'" 2>/dev/null
BEFORE=$(git -C "$R" rev-parse HEAD)
fire_out "$R" "git -C $R commit -m x"
check "merge untouched" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
stdout_empty "merge commit"

echo "== 6. --no-edit amend -> untouched (no loop) =="
R=$(newrepo r6); git -C "$R" commit -qm "feat: thing"
BEFORE=$(git -C "$R" rev-parse HEAD)
fire_out "$R" "git -C $R commit --amend --no-edit"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
stdout_empty "--no-edit"

echo "== 7. wrapper-script form -> added =="
R=$(newrepo r7); git -C "$R" commit -qm "feat: thing"
fire "$R" "cd $R; ~/.claude/bin/git-commit.sh 'feat: thing'"
check "trailer added" yes "$(has_trailer "$R")"

echo "== 8. cwd fallback (no -C in command) -> added =="
R=$(newrepo r8); git -C "$R" commit -qm "feat: thing"
fire "$R" "git commit -m 'feat: thing'"
check "trailer added via cwd" yes "$(has_trailer "$R")"

echo "== 9. already pushed to a remote -> untouched (no history rewrite) =="
R=$(newrepo r9); git -C "$R" commit -qm "feat: thing"
BARE="$T/r9-remote.git"; git init -q --bare "$BARE"
git -C "$R" remote add origin "$BARE"
git -C "$R" push -q origin HEAD 2>/dev/null
BEFORE=$(git -C "$R" rev-parse HEAD)
fire_out "$R" "git -C $R commit -m 'feat: thing'"
check "pushed commit untouched" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
stdout_empty "pushed HEAD"

# Cases 10+ cover target resolution: the session cwd holds a fresh, unpushed,
# trailer-less HEAD (another session's work in progress), so a hook that falls
# back to the cwd instead of the commit's real target rewrites it.

echo "== 10. git-commit.sh --repo <other>, cwd elsewhere -> trailer in <other> =="
CWD=$(newrepo r10-cwd); git -C "$CWD" commit -qm "feat: other session"
CWD_BEFORE=$(git -C "$CWD" rev-parse HEAD)
R=$(newrepo r10); git -C "$R" commit -qm "feat: thing"
fire "$CWD" "~/.claude/bin/git-commit.sh --repo $R 'feat: thing'"
check "trailer added in target" yes "$(has_trailer "$R")"
check "cwd repo untouched" "$CWD_BEFORE" "$(git -C "$CWD" rev-parse HEAD)"

echo "== 11. --repo=<other> -> trailer in <other> =="
CWD=$(newrepo r11-cwd); git -C "$CWD" commit -qm "feat: other session"
CWD_BEFORE=$(git -C "$CWD" rev-parse HEAD)
R=$(newrepo r11); git -C "$R" commit -qm "feat: thing"
fire "$CWD" "~/.claude/bin/git-commit.sh --repo=$R 'feat: thing'"
check "trailer added in target" yes "$(has_trailer "$R")"
check "cwd repo untouched" "$CWD_BEFORE" "$(git -C "$CWD" rev-parse HEAD)"

echo "== 12. --repo '<other>' (quoted) -> trailer in <other> =="
CWD=$(newrepo r12-cwd); git -C "$CWD" commit -qm "feat: other session"
CWD_BEFORE=$(git -C "$CWD" rev-parse HEAD)
R=$(newrepo r12); git -C "$R" commit -qm "feat: thing"
fire "$CWD" "~/.claude/bin/git-commit.sh --repo '$R' \"feat: thing\""
check "trailer added in target" yes "$(has_trailer "$R")"
check "cwd repo untouched" "$CWD_BEFORE" "$(git -C "$CWD" rev-parse HEAD)"

echo "== 13. --repo ~/<dir> -> tilde expands to \$HOME =="
CWD=$(newrepo r13-cwd); git -C "$CWD" commit -qm "feat: other session"
CWD_BEFORE=$(git -C "$CWD" rev-parse HEAD)
R=$(newrepo r13); git -C "$R" commit -qm "feat: thing"
FAKE_HOME="$T/home13"; mkdir -p "$FAKE_HOME"; ln -s "$R" "$FAKE_HOME/r13"
HOME="$FAKE_HOME" fire "$CWD" "~/.claude/bin/git-commit.sh --repo ~/r13 'feat: thing'"
check "trailer added in target" yes "$(has_trailer "$R")"
check "cwd repo untouched" "$CWD_BEFORE" "$(git -C "$CWD" rev-parse HEAD)"

echo "== 14. git -C <A> add && git-commit.sh --repo <B> -> trailer in B, A untouched =="
A=$(newrepo r14-a); git -C "$A" commit -qm "feat: other session"
A_BEFORE=$(git -C "$A" rev-parse HEAD)
B=$(newrepo r14-b); git -C "$B" commit -qm "feat: thing"
fire "$A" "git -C $A add f && ~/.claude/bin/git-commit.sh --repo $B 'feat: thing'"
check "trailer added in B" yes "$(has_trailer "$B")"
check "A untouched" "$A_BEFORE" "$(git -C "$A" rev-parse HEAD)"

echo "== 15. git -C <A> status && git -C <B> commit -> the commit segment's -C wins =="
A=$(newrepo r15-a); git -C "$A" commit -qm "feat: other session"
A_BEFORE=$(git -C "$A" rev-parse HEAD)
B=$(newrepo r15-b); git -C "$B" commit -qm "feat: thing"
fire "$A" "git -C $A status && git -C $B commit -m 'feat: thing'"
check "trailer added in B" yes "$(has_trailer "$B")"
check "A untouched" "$A_BEFORE" "$(git -C "$A" rev-parse HEAD)"

echo "== 16. message mentioning 'git commit' in a non-commit call -> untouched =="
R=$(newrepo r16); git -C "$R" commit -qm "feat: thing"
BEFORE=$(git -C "$R" rev-parse HEAD)
fire_out "$R" "git -C $R log --grep 'git commit'"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
stdout_empty "mentions commit"

# Cases 17-20: a target the hook cannot resolve amends nothing (not even the
# cwd repo) and tells the model why; a silent skip is how missing trailers went
# unnoticed.

echo "== 17. --repo \"\$WT\" -> nothing amended, context names the target =="
CWD=$(newrepo r17); git -C "$CWD" commit -qm "feat: thing"
CWD_BEFORE=$(git -C "$CWD" rev-parse HEAD)
fire_out "$CWD" '~/.claude/bin/git-commit.sh --repo "$WT" "feat: thing"'
check "cwd repo untouched" "$CWD_BEFORE" "$(git -C "$CWD" rev-parse HEAD)"
check "context names \$WT" yes "$(context_has '$WT')"
# The reason, not just the name: without the expansion check the hook would
# take "$WT" as a relative directory and only fail later, if at all.
check "context says shell expansion" yes "$(context_has "shell expansion")"

echo "== 18. --repo <nonexistent> -> nothing amended, context message =="
CWD=$(newrepo r18); git -C "$CWD" commit -qm "feat: thing"
CWD_BEFORE=$(git -C "$CWD" rev-parse HEAD)
fire_out "$CWD" "~/.claude/bin/git-commit.sh --repo $T/does-not-exist 'feat: thing'"
check "cwd repo untouched" "$CWD_BEFORE" "$(git -C "$CWD" rev-parse HEAD)"
check "context names the missing dir" yes "$(context_has "$T/does-not-exist")"

echo "== 19. two commit segments with different targets -> neither amended =="
A=$(newrepo r19-a); git -C "$A" commit -qm "feat: a"
B=$(newrepo r19-b); git -C "$B" commit -qm "feat: b"
A_BEFORE=$(git -C "$A" rev-parse HEAD); B_BEFORE=$(git -C "$B" rev-parse HEAD)
fire_out "$A" "~/.claude/bin/git-commit.sh --repo $A 'feat: a' && ~/.claude/bin/git-commit.sh --repo $B 'feat: b'"
check "A untouched" "$A_BEFORE" "$(git -C "$A" rev-parse HEAD)"
check "B untouched" "$B_BEFORE" "$(git -C "$B" rev-parse HEAD)"
check "context says several targets" yes "$(context_has "different targets")"

echo "== 20. command that does not tokenize -> nothing amended, context message =="
CWD=$(newrepo r20); git -C "$CWD" commit -qm "feat: thing"
CWD_BEFORE=$(git -C "$CWD" rev-parse HEAD)
fire_out "$CWD" "git commit -m 'unbalanced"
check "cwd repo untouched" "$CWD_BEFORE" "$(git -C "$CWD" rev-parse HEAD)"
check "context says it does not tokenize" yes "$(context_has "does not tokenize")"

echo "== 21. commit && push in one call -> untouched, context names the hash =="
R=$(newrepo r21); git -C "$R" commit -qm "feat: thing"
BARE="$T/r21-remote.git"; git init -q --bare "$BARE"
git -C "$R" remote add origin "$BARE"
git -C "$R" push -q origin HEAD 2>/dev/null
BEFORE=$(git -C "$R" rev-parse HEAD)
fire_out "$R" "~/.claude/bin/git-commit.sh --repo $R 'feat: thing' && git -C $R push"
check "pushed commit untouched" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
check "context names the hash" yes "$(context_has "$(git -C "$R" rev-parse --short HEAD)")"
check "context says pushed in the same call" yes "$(context_has "pushed in the same call")"

echo "== 22. pushed HEAD, no push in the command -> no warning =="
R=$(newrepo r22); git -C "$R" commit -qm "feat: thing"
BARE="$T/r22-remote.git"; git init -q --bare "$BARE"
git -C "$R" remote add origin "$BARE"
git -C "$R" push -q origin HEAD 2>/dev/null
fire_out "$R" "git -C $R commit -m 'feat: thing'"
stdout_empty "pushed HEAD, no push"

# Cases 23-25: a directory change before the commit moves its target. The
# approve hook auto-approves `env -C <dir> git commit`, so falling back to the
# cwd there amends the wrong repo.

echo "== 23. env -C <B> git commit, cwd A -> trailer in B, A untouched =="
A=$(newrepo r23-a); git -C "$A" commit -qm "feat: other session"
A_BEFORE=$(git -C "$A" rev-parse HEAD)
B=$(newrepo r23-b); git -C "$B" commit -qm "feat: thing"
fire "$A" "env -C $B git commit -m 'feat: thing'"
check "trailer added in B" yes "$(has_trailer "$B")"
check "A untouched" "$A_BEFORE" "$(git -C "$A" rev-parse HEAD)"

echo "== 24. cd <B> && git-commit.sh, cwd A -> trailer in B, A untouched =="
A=$(newrepo r24-a); git -C "$A" commit -qm "feat: other session"
A_BEFORE=$(git -C "$A" rev-parse HEAD)
B=$(newrepo r24-b); git -C "$B" commit -qm "feat: thing"
fire "$A" "cd $B && ~/.claude/bin/git-commit.sh 'feat: thing'"
check "trailer added in B" yes "$(has_trailer "$B")"
check "A untouched" "$A_BEFORE" "$(git -C "$A" rev-parse HEAD)"

echo "== 25. cd -; git commit -> nothing amended, context message =="
CWD=$(newrepo r25); git -C "$CWD" commit -qm "feat: thing"
CWD_BEFORE=$(git -C "$CWD" rev-parse HEAD)
fire_out "$CWD" "cd -; git commit -m 'feat: thing'"
check "cwd repo untouched" "$CWD_BEFORE" "$(git -C "$CWD" rev-parse HEAD)"
check "context names cd -" yes "$(context_has "cd -")"

echo "== 26. --git-dir in a non-commit call -> no warning =="
R=$(newrepo r26); git -C "$R" commit -qm "feat: thing"
fire_out "$R" "git --git-dir=$R/.git log --grep commit"
stdout_empty "--git-dir"

echo "== 27. amend fails (index locked) -> context says add it manually =="
R=$(newrepo r27); git -C "$R" commit -qm "feat: thing"
BEFORE=$(git -C "$R" rev-parse HEAD)
# A held index.lock is what a concurrent git process leaves; amend refuses it.
touch "$R/.git/index.lock"
fire_out "$R" "git -C $R commit -m 'feat: thing'"
rm -f "$R/.git/index.lock"
check "sha unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
check "context says could not add" yes "$(context_has "could not add")"

echo "== 28. unborn HEAD -> no warning =="
R=$(newrepo r28)
fire_out "$R" "git -C $R commit -m 'feat: thing'"
stdout_empty "unborn HEAD"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
