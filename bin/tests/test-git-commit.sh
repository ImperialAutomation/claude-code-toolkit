#!/bin/bash
# Tests for git-commit.sh — focused on the protected-branch guard.
#
# Usage:
#   bin/tests/test-git-commit.sh
#
# Exercises the script against throwaway git repos in a temp dir. Nothing
# outside that temp dir is touched. Exits non-zero if any expectation fails.
#
# The guard's whole value is that it refuses, so the cases that matter most are
# the ones asserting a commit was NOT created (1, 6, 7) and the ones asserting
# the default is still wide open (4, 5) — a guard that fires in unconfigured
# repos would break every project that commits straight to main.
#
# Case 8 is the reason --repo exists at all: the guard must read the TARGET
# tree's branch, not the caller's. A guard reading cwd passes every other case
# here while protecting the wrong repo.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../git-commit.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

contains() { # name needle haystack
    if [[ "$3" == *"$2"* ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 ('$2' not found in: $3)"; FAIL=$((FAIL+1)); fi
}

# A repo on branch $2 with one commit already made and a staged change pending.
newrepo() { # name branch
    local d="$T/$1"
    mkdir -p "$d"
    git -C "$d" init -q -b "$2"
    git -C "$d" config user.email t@t
    git -C "$d" config user.name T
    echo base > "$d/f"
    git -C "$d" add f
    git -C "$d" commit -qm "base"
    echo change > "$d/g"
    git -C "$d" add g
    echo "$d"
}

protect_file() { # repodir branch...
    local d="$1"; shift
    mkdir -p "$d/.claude"
    printf '%s\n' "$@" > "$d/.claude/protected-branches"
}

count_commits() { git -C "$1" rev-list --count HEAD; }

echo "== 1. protected branch listed, no flag -> refuse, no commit =="
R=$(newrepo r1 develop)
protect_file "$R" develop
OUT=$(bash "$SCRIPT" --repo "$R" "feat: should be refused" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "no commit created" 1 "$(count_commits "$R")"
# Must be the refusal naming the branch, not git's own "[develop abc123]" success
# line — that substring alone would pass with no guard at all.
contains "refusal names the branch" "protected branch 'develop'" "$OUT"

echo "== 2. protected branch WITH --allow-protected -> commits =="
R=$(newrepo r2 develop)
protect_file "$R" develop
OUT=$(bash "$SCRIPT" --repo "$R" --allow-protected "feat: explicitly allowed" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" 2 "$(count_commits "$R")"
# The flag must be consumed by the parser, not swallowed into the message: an
# unrecognised flag lands in MSG_ARGS and silently becomes a line of history.
check "flag not in commit message" "" \
    "$(git -C "$R" log -1 --format='%B' | grep -F -- '--allow-protected')"

echo "== 3. branch not in the list -> commits =="
R=$(newrepo r3 issue-81-thing)
protect_file "$R" develop master main
OUT=$(bash "$SCRIPT" --repo "$R" "feat: on a feature branch" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" 2 "$(count_commits "$R")"

echo "== 4. no config at all -> commits even on main =="
R=$(newrepo r4 main)
OUT=$(bash "$SCRIPT" --repo "$R" "feat: unconfigured repo" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" 2 "$(count_commits "$R")"

echo "== 5. empty config file -> protects nothing =="
R=$(newrepo r5 main)
mkdir -p "$R/.claude"
printf '# only a comment\n\n' > "$R/.claude/protected-branches"
OUT=$(bash "$SCRIPT" --repo "$R" "feat: comments are not branches" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" 2 "$(count_commits "$R")"

echo "== 6. git config fallback when no file exists -> refuse =="
R=$(newrepo r6 develop)
git -C "$R" config --add toolkit.protectedBranch develop
OUT=$(bash "$SCRIPT" --repo "$R" "feat: should be refused" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "no commit created" 1 "$(count_commits "$R")"

echo "== 7. the file WINS over git config (file lists other branches) =="
# git config protects develop, the file does not. File wins -> commit goes through.
R=$(newrepo r7 develop)
protect_file "$R" master
git -C "$R" config --add toolkit.protectedBranch develop
OUT=$(bash "$SCRIPT" --repo "$R" "feat: file wins, develop unprotected" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" 2 "$(count_commits "$R")"

echo "== 8. --repo: guard reads the TARGET tree, not cwd =="
# cwd is on an unprotected branch; the target tree is on a protected one.
CALLER=$(newrepo r8caller feature-x)
TARGET=$(newrepo r8target develop)
protect_file "$TARGET" develop
OUT=$(env -C "$CALLER" bash "$SCRIPT" --repo "$TARGET" "feat: should be refused" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "target got no commit" 1 "$(count_commits "$TARGET")"

echo "== 9. no --repo: guard reads cwd's branch =="
R=$(newrepo r9 develop)
protect_file "$R" develop
OUT=$(env -C "$R" bash "$SCRIPT" "feat: should be refused" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "no commit created" 1 "$(count_commits "$R")"

echo "== 10. detached HEAD -> allowed (rebase/bisect) =="
R=$(newrepo r10 develop)
protect_file "$R" develop
# The config file must be COMMITTED, not left untracked: an untracked file does
# not survive the detach cleanly, and the repo would reach the guard
# unconfigured — passing this case for no reason at all.
git -C "$R" add .claude/protected-branches
git -C "$R" commit -qm "chore: protect develop"
git -C "$R" checkout -q --detach HEAD
# A file that does not exist in the committed tree, so there is really something
# to commit: otherwise git exits 1 for "nothing to commit" and the case looks
# like a refusal that never happened.
echo detached > "$R/h"
git -C "$R" add h
DETACHED_BASE=$(count_commits "$R")
OUT=$(bash "$SCRIPT" --repo "$R" "feat: on detached HEAD" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" "$((DETACHED_BASE + 1))" "$(count_commits "$R")"

echo "== 10b. detached HEAD: exempt because there IS no branch =="
# Case 10 shows the commit goes through, but not why: it would also pass under a
# detection method that misreports the branch, since 'develop' is what is
# protected. Protecting the literal 'HEAD' separates the two — this commit only
# succeeds if the guard knows detached HEAD has no branch at all, and fails if
# it resolves HEAD to a name (as `git rev-parse --abbrev-ref HEAD` does).
R=$(newrepo r10b develop)
protect_file "$R" HEAD develop
git -C "$R" add .claude/protected-branches
git -C "$R" commit -qm "chore: protect HEAD and develop"
git -C "$R" checkout -q --detach HEAD
echo detached > "$R/h"
git -C "$R" add h
B=$(count_commits "$R")
OUT=$(bash "$SCRIPT" --repo "$R" "feat: detached, 'HEAD' is not a branch" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" "$((B + 1))" "$(count_commits "$R")"

echo "== 11. --file path is guarded too =="
R=$(newrepo r11 develop)
protect_file "$R" develop
printf 'feat: via --file\n' > "$T/msg11.txt"
OUT=$(bash "$SCRIPT" --repo "$R" --file "$T/msg11.txt" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "no commit created" 1 "$(count_commits "$R")"

echo "== 12. --stdin path is guarded too =="
R=$(newrepo r12 develop)
protect_file "$R" develop
OUT=$(printf 'feat: via stdin\n' | bash "$SCRIPT" --repo "$R" --stdin 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "no commit created" 1 "$(count_commits "$R")"

echo "== 13. --amend on a protected branch is guarded =="
R=$(newrepo r13 develop)
protect_file "$R" develop
BEFORE=$(git -C "$R" rev-parse HEAD)
OUT=$(bash "$SCRIPT" --repo "$R" --amend "feat: rewritten" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "HEAD unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"

echo "== 14. refusal message tells you how to proceed =="
R=$(newrepo r14 develop)
protect_file "$R" develop
OUT=$(bash "$SCRIPT" --repo "$R" "feat: refused" 2>&1)
contains "mentions --allow-protected" "--allow-protected" "$OUT"
contains "mentions creating a branch" "switch -c" "$OUT"

echo "== 15. whitespace and inline comments in the config file =="
R=$(newrepo r15 develop)
mkdir -p "$R/.claude"
printf '  develop  \n# a comment\nmaster\n' > "$R/.claude/protected-branches"
OUT=$(bash "$SCRIPT" --repo "$R" "feat: refused" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "no commit created" 1 "$(count_commits "$R")"

echo "== 16. partial name is not a match (exact only) =="
R=$(newrepo r16 develop-ish)
protect_file "$R" develop
OUT=$(bash "$SCRIPT" --repo "$R" "feat: develop-ish is not develop" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" 2 "$(count_commits "$R")"

echo "== 17. --repo=D commits in D, not in cwd =="
# hook-post-commit-trailer.sh reads --repo=D as the commit's target. If this
# script took it as a message line and committed in cwd instead, the hook would
# amend D's HEAD: a commit this call never made.
CALLER=$(newrepo r17caller feature-x)
R=$(newrepo r17 feature-y)
OUT=$(env -C "$CALLER" bash "$SCRIPT" --repo="$R" "feat: equals form" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created in D" 2 "$(count_commits "$R")"
check "no commit in cwd" 1 "$(count_commits "$CALLER")"
check "option not in commit message" "feat: equals form" \
    "$(git -C "$R" log -1 --format='%B')"

# --- Read-only pre-commit cache hint (#179) ---------------------------------
#
# Under the sandbox ~/.cache/pre-commit is read-only and pre-commit dies with a
# Python traceback before any hook runs. The script adds one line naming the
# cause. These cases stub the pre-commit hook so no real pre-commit is needed.

HINT="pre-commit cannot write its cache"

EROFS_TRACE="Traceback (most recent call last):
  File \"/usr/lib/python3/site-packages/pre_commit/staged_files_only.py\", line 50
OSError: [Errno 30] Read-only file system: '/home/u/.cache/pre-commit/patch1700000000-123'"

# Install an executable pre-commit hook that prints $2 to stream $3 and exits $4.
stub_hook() { # repodir text stream(1|2) exit
    local hook="$1/.git/hooks/pre-commit"
    printf '#!/bin/sh\ncat <<'"'"'EOF'"'"' >&%s\n%s\nEOF\nexit %s\n' "$3" "$2" "$4" > "$hook"
    chmod +x "$hook"
}

count_hint() { grep -cF "$HINT" <<<"$1" || true; }

echo "== 18. EROFS pre-commit traceback on stderr -> hint once, no commit =="
R=$(newrepo r18 feature)
stub_hook "$R" "$EROFS_TRACE" 2 3
OUT=$(bash "$SCRIPT" --repo "$R" "feat: blocked by sandbox" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "no commit created" 1 "$(count_commits "$R")"
contains "original traceback kept" "Read-only file system" "$OUT"
check "hint printed once" 1 "$(count_hint "$OUT")"
# The hint must come after the traceback, so it is the last thing read.
check "hint is the last line" 1 "$(tail -n 1 <<<"$OUT" | grep -cF "$HINT")"
ERR=$(bash "$SCRIPT" --repo "$R" "feat: blocked by sandbox" 2>&1 >/dev/null)
check "hint goes to stderr" 1 "$(count_hint "$ERR")"

echo "== 19. EROFS pre-commit traceback on the hook's stdout -> hint =="
# git routes a hook's stdout to its own stderr, so this lands in the same
# stream as case 18; it guards against a check that only looks at one of them.
R=$(newrepo r19 feature)
stub_hook "$R" "$EROFS_TRACE" 1 3
OUT=$(bash "$SCRIPT" --repo "$R" "feat: blocked by sandbox" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "hint printed once" 1 "$(count_hint "$OUT")"

echo "== 19b. git's own stdout is untouched on success =="
R=$(newrepo r19b feature)
OUTONLY=$(bash "$SCRIPT" --repo "$R" "feat: summary on stdout" 2>/dev/null)
contains "commit summary on stdout" "feat: summary on stdout" "$OUTONLY"

echo "== 20. other hook failure (lint) -> no hint, exit kept =="
R=$(newrepo r20 feature)
stub_hook "$R" "ruff....................Failed
- hook id: ruff
src/x.py:1:1: F401 unused import" 1 1
OUT=$(bash "$SCRIPT" --repo "$R" "feat: lint fails" 2>&1)
RC=$?
check "exit is the hook's" 1 "$RC"
check "no hint" 0 "$(count_hint "$OUT")"
contains "lint output kept" "F401" "$OUT"

echo "== 21. read-only error not from pre-commit -> no hint =="
R=$(newrepo r21 feature)
stub_hook "$R" "OSError: [Errno 30] Read-only file system: '/srv/data/out.txt'" 2 3
OUT=$(bash "$SCRIPT" --repo "$R" "feat: other EROFS" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "no hint" 0 "$(count_hint "$OUT")"

echo "== 22. PRE_COMMIT_HOME path counts as the pre-commit marker =="
R=$(newrepo r22 feature)
stub_hook "$R" "OSError: [Errno 30] Read-only file system: '/opt/hookcache/patch1'" 2 3
OUT=$(PRE_COMMIT_HOME=/opt/hookcache bash "$SCRIPT" --repo "$R" "feat: custom home" 2>&1)
check "hint printed once" 1 "$(count_hint "$OUT")"

echo "== 23. --file path prints the hint too =="
R=$(newrepo r23 feature)
stub_hook "$R" "$EROFS_TRACE" 2 3
printf 'feat: via --file\n' > "$T/msg23.txt"
OUT=$(bash "$SCRIPT" --repo "$R" --file "$T/msg23.txt" 2>&1)
RC=$?
check "exit non-zero" nonzero "$([[ $RC -ne 0 ]] && echo nonzero || echo "zero($RC)")"
check "hint printed once" 1 "$(count_hint "$OUT")"

echo "== 24. successful commit with hook output -> no hint, exit 0 =="
R=$(newrepo r24 feature)
stub_hook "$R" "pre-commit: all hooks passed" 1 0
OUT=$(bash "$SCRIPT" --repo "$R" "feat: clean" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" 2 "$(count_commits "$R")"
check "no hint" 0 "$(count_hint "$OUT")"

# --- Argument parsing (#129) -----------------------------------------------
#
# Every unrecognised argument used to become a message line, so `--help` or a
# mistyped option committed whatever was staged, with that option as message.
# Each refusal case has a staged change pending (newrepo), so "no commit" is a
# real refusal and not git's "nothing to commit".

nonzero() { [[ $1 -ne 0 ]] && echo nonzero || echo "zero($1)"; }

for flag in --help -h; do
    echo "== 25. $flag -> usage, exit 0, no commit =="
    R=$(newrepo "r25$flag" feature)
    OUT=$(bash "$SCRIPT" --repo "$R" "$flag" 2>"$T/err25")
    RC=$?
    check "exit zero" 0 "$RC"
    check "no commit created" 1 "$(count_commits "$R")"
    contains "prints usage" "Usage:" "$OUT"
    check "header comment markers stripped" no \
        "$([[ "$OUT" =~ (^|$'\n')# ]] && echo yes || echo no)"
    check "nothing on stderr" 0 "$(wc -c < "$T/err25" | tr -d ' ')"
    # Answered before any git call: works outside a repository too.
    OUT=$(env -C "$T" bash "$SCRIPT" "$flag" 2>&1)
    check "exit zero outside a repo" 0 "$?"
done

for bad in --ammend --add -m --repo-dir=x; do
    echo "== 26. unknown option $bad -> exit 2, no commit =="
    R=$(newrepo "r26$bad" feature)
    OUT=$(bash "$SCRIPT" --repo "$R" "$bad" "feat: msg" 2>&1)
    RC=$?
    check "exit 2" 2 "$RC"
    check "no commit created" 1 "$(count_commits "$R")"
    contains "names the option" "unknown option '$bad'" "$OUT"
    contains "points at --help" "--help" "$OUT"
done

echo "== 27. -- ends options: a message line may start with - =="
R=$(newrepo r27 feature)
OUT=$(bash "$SCRIPT" --repo "$R" -- "-x" "--not-an-option" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" 2 "$(count_commits "$R")"
check "message kept verbatim" $'-x\n--not-an-option' "$(git -C "$R" log -1 --format='%B')"

echo "== 28. bullet lines and empty lines are message lines, not options =="
R=$(newrepo r28 feature)
OUT=$(bash "$SCRIPT" --repo "$R" "feat: list" "" "- first" "- second" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "commit created" 2 "$(count_commits "$R")"
check "bullets kept" $'feat: list\n\n- first\n- second' "$(git -C "$R" log -1 --format='%B')"

echo "== 29. --file with positional lines -> exit 2, no commit =="
R=$(newrepo r29 feature)
printf 'feat: via --file\n' > "$T/msg29.txt"
OUT=$(bash "$SCRIPT" --repo "$R" --file "$T/msg29.txt" "" "Co-Authored-By: X <x@x>" 2>&1)
RC=$?
check "exit 2" 2 "$RC"
check "no commit created" 1 "$(count_commits "$R")"
contains "explains the conflict" "--file" "$OUT"

echo "== 30. --stdin with positional lines -> exit 2, no commit =="
R=$(newrepo r30 feature)
OUT=$(printf 'feat: via stdin\n' | bash "$SCRIPT" --repo "$R" --stdin "extra" 2>&1)
RC=$?
check "exit 2" 2 "$RC"
check "no commit created" 1 "$(count_commits "$R")"

echo "== 31. --file together with --stdin -> exit 2, no commit =="
R=$(newrepo r31 feature)
printf 'feat: via --file\n' > "$T/msg31.txt"
OUT=$(printf 'feat: via stdin\n' | bash "$SCRIPT" --repo "$R" --stdin --file "$T/msg31.txt" 2>&1)
RC=$?
check "exit 2" 2 "$RC"
check "no commit created" 1 "$(count_commits "$R")"

for opt in --file --repo; do
    echo "== 32. $opt without a value -> exit 2, clear message =="
    R=$(newrepo "r32$opt" feature)
    OUT=$(env -C "$R" bash "$SCRIPT" "feat: msg" "$opt" 2>&1)
    RC=$?
    check "exit 2" 2 "$RC"
    check "no commit created" 1 "$(count_commits "$R")"
    contains "names the option" "$opt requires a value" "$OUT"
done

echo "== 33. --file with --amend still works (known options combine) =="
R=$(newrepo r33 feature)
printf 'feat: amended via --file\n' > "$T/msg33.txt"
OUT=$(bash "$SCRIPT" --repo "$R" --amend --file "$T/msg33.txt" 2>&1)
RC=$?
check "exit zero" 0 "$RC"
check "amended, no new commit" 1 "$(count_commits "$R")"
check "message from file" "feat: amended via --file" "$(git -C "$R" log -1 --format='%B')"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
