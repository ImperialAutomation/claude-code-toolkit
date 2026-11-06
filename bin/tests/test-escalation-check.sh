#!/bin/bash
# Tests for escalation-check.sh.
#
# Usage:
#   bin/tests/test-escalation-check.sh
#
# Builds a throwaway repository with a `main` branch, cuts one branch per case,
# makes the change under test, commits it, and runs the REAL check against
# `main`. Asserts on the exit code (0 clean, 1 hit, 2 error) and on the hit
# lines (`<category>  <file>  <reason>`).
#
# Hermetic: $HOME points at a temp dir, so the denylist the check reads is the
# fixture written here, never the real ~/.claude/escalation-denylist.
#
# When adding a case, check it actually constrains the check: break the rule in
# escalation-check.sh, confirm THIS test goes red, then revert.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../escalation-check.sh}"

if [[ ! -f "$CHECK" ]]; then
    echo "script not found: $CHECK" >&2
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
DENYLIST="$HOME/.claude/escalation-denylist"
write_denylist() {
    cat > "$DENYLIST" <<'EOF'
# Project names that must never reach this public repo.
# The comment line above mentions README; comments are not patterns.
acme-internal
^secret[0-9]+$
EOF
}
write_denylist

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

R="$T/repo"
git init -q -b main "$R"
mkdir -p "$R/bin/tests" "$R/skills/demo" "$R/rules" "$R/claude-md" "$R/.claude" "$R/docs"
for f in bin/hook-auto-approve-bash.py bin/hook-block-destructive.sh bin/escalation-check.sh \
         bin/hook-escalation-check.sh bin/old-tool.sh bin/test-old.sh bin/tests/test-old.sh \
         rules/testing.md claude-md/global.md claude-md/settings-global.jsonc \
         .claude/settings.local.json README.md; do
    echo "original $f" > "$R/$f"
done
cat > "$R/skills/demo/SKILL.md" <<'EOF'
---
name: demo
argument-hint: "<issue-number>"
---
Body text.
EOF
echo "secret42" > "$R/docs/old.md"
git -C "$R" add -A
git -C "$R" commit -q -m base

OUT=""; RC=0
# case <branch>: fresh branch from main; the caller makes changes, then `run`.
case_branch() { git -C "$R" checkout -q -B "$1" main; }
edit() { echo "change" >> "$R/$1"; }
run() { # commit everything and run the check against main
    git -C "$R" add -A
    git -C "$R" commit -q -m change --allow-empty
    OUT=$(bash "$CHECK" --repo "$R" --base main 2>&1); RC=$?
}
hits() { # number of hit lines for category $1
    printf '%s\n' "$OUT" | grep -c "^$1  " || true
}

echo "== 0. --help =="
help_out=$(bash "$CHECK" --help 2>&1); status=$?
check "--help exits 0" "0" "$status"
check "--help prints usage" "yes" "$(contains "$help_out" "sage")"

echo "== 1. a clean diff passes =="
case_branch clean
edit README.md
run
check "clean: exit 0" "0" "$RC"
check "clean: no output" "" "$OUT"

echo "== 2. category 1: permissions =="
case_branch perm-approver
edit bin/hook-auto-approve-bash.py
run
check "auto-approve change: exit 1" "1" "$RC"
check "auto-approve change: permissions hit" "1" "$(hits permissions)"
check "hit line names the file" "yes" "$(contains "$OUT" "permissions  bin/hook-auto-approve-bash.py  ")"

case_branch perm-settings
edit .claude/settings.local.json
run
check ".claude/settings.local.json: permissions hit" "1" "$(hits permissions)"

case_branch perm-template
edit claude-md/settings-global.jsonc
run
check "settings-global.jsonc: permissions hit" "1" "$(hits permissions)"
check "settings-global.jsonc: also global (under claude-md/)" "1" "$(hits global)"

case_branch perm-self
edit bin/escalation-check.sh
run
check "escalation-check.sh itself: exit 1" "1" "$RC"
check "escalation-check.sh itself: permissions hit" "1" "$(hits permissions)"

case_branch perm-hook
edit bin/hook-escalation-check.sh
run
check "hook-escalation-check.sh: permissions hit" "1" "$(hits permissions)"

case_branch deny-only
edit bin/hook-block-destructive.sh
run
check "deny-only hook alone: exit 0" "0" "$RC"
check "deny-only hook alone: no permissions hit" "0" "$(hits permissions)"

case_branch test-only
edit bin/tests/test-old.sh
edit bin/test-old.sh
echo "new test" > "$R/bin/tests/test-escalation-check.sh"
run
check "test files alone: exit 0" "0" "$RC"
check "test files alone: no hit" "" "$OUT"

echo "== 3. category 2: leakage =="
case_branch leak
echo "see the Acme-Internal tracker" >> "$R/README.md"
run
check "denylisted term (case-insensitive): exit 1" "1" "$RC"
check "denylisted term: leakage hit" "1" "$(hits leakage)"
check "hit names the file and the line" "yes" "$(contains "$OUT" "leakage  README.md  added line 2 ")"
check "hit does not repeat the denylisted term" "no" "$(contains "$(printf '%s' "$OUT" | tr '[:upper:]' '[:lower:]')" "acme-internal")"

case_branch leak-anchor
echo "secret7" > "$R/docs/new.md"
run
check "anchored pattern on an added line: leakage hit" "1" "$(hits leakage)"

case_branch leak-removed
git -C "$R" rm -q docs/old.md
run
check "denylisted term only on a REMOVED line: no hit" "0" "$RC"

case_branch leak-comment
echo "README" >> "$R/README.md"
run
check "word that appears only in a denylist comment: no hit" "0" "$RC"

case_branch no-denylist
edit README.md
mv "$DENYLIST" "$T/denylist.bak"
run
check "no denylist: exit 1 (fail closed)" "1" "$RC"
check "no denylist: leakage hit" "1" "$(hits leakage)"
check "no denylist: message names the path" "yes" "$(contains "$OUT" "escalation-denylist")"
mv "$T/denylist.bak" "$DENYLIST"

echo "== 4. category 3: interface =="
case_branch iface-delete
git -C "$R" rm -q bin/old-tool.sh
run
check "deleted bin script: interface hit" "1" "$(hits interface)"
check "deleted bin script: names it" "yes" "$(contains "$OUT" "interface  bin/old-tool.sh  ")"

case_branch iface-rename
git -C "$R" mv bin/old-tool.sh bin/new-tool.sh
run
check "renamed bin script: interface hit" "1" "$(hits interface)"

case_branch iface-skill-rename
git -C "$R" mv skills/demo skills/demo2
run
check "renamed skill: interface hit" "1" "$(hits interface)"

case_branch iface-hint
sed -i 's/<issue-number>/<issue-number> [--auto]/' "$R/skills/demo/SKILL.md"
run
check "changed argument-hint: interface hit" "1" "$(hits interface)"
check "changed argument-hint: names SKILL.md" "yes" "$(contains "$OUT" "interface  skills/demo/SKILL.md  ")"

case_branch iface-body
sed -i 's/Body text./Other body text./' "$R/skills/demo/SKILL.md"
run
check "SKILL.md body change: no hit" "0" "$RC"

case_branch iface-test
git -C "$R" rm -q bin/tests/test-old.sh bin/test-old.sh
run
check "deleted test files: no interface hit" "0" "$RC"

echo "== 5. category 4: global =="
case_branch global-rules
edit rules/testing.md
run
check "rules/ change: exit 1" "1" "$RC"
check "rules/ change: global hit" "1" "$(hits global)"
check "rules/ change: no other category" "1" "$(printf '%s\n' "$OUT" | grep -c .)"

case_branch global-claude-md
edit claude-md/global.md
run
check "claude-md/ change: global hit" "1" "$(hits global)"

echo "== 6. base resolution and errors =="
case_branch feature-default-base
edit rules/testing.md
git -C "$R" add -A; git -C "$R" commit -q -m change
OUT=$(bash "$CHECK" --repo "$R" 2>&1); RC=$?
check "default base (git-find-base-branch): global hit" "1" "$(hits global)"

OUT=$(bash "$CHECK" --repo "$T/nowhere" --base main 2>&1); RC=$?
check "missing repo: exit 2" "2" "$RC"
OUT=$(bash "$CHECK" --repo "$R" --base no-such-branch 2>&1); RC=$?
check "unknown base: exit 2" "2" "$RC"
OUT=$(bash "$CHECK" --bogus 2>&1); RC=$?
check "unknown option: exit 2" "2" "$RC"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
