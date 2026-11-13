#!/bin/bash
# Tests for run-tests.sh.
#
# Usage:
#   bin/tests/test-run-tests.sh
#
# Builds a toolkit-shaped temp repo ("main") holding a copy of run-tests.sh
# and stub tests, a linked worktree of it ("wt") whose stubs differ, and an
# unrelated repo ("other") of the same shape. Each stub appends
# "<name> <cwd>" to $MARK, so a case can see which tree's test ran.
#
# Hermetic: $HOME is a temp dir; only git and the runner's PREREQS are used.
#
# When adding a case, check it actually constrains the script: break the rule
# in run-tests.sh, confirm THIS test goes red, then revert.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../run-tests.sh}"

if [[ ! -f "$RUNNER" ]]; then
    echo "script not found: $RUNNER" >&2
    exit 1
fi

T=$(mktemp -d)
T=$(cd -P "$T" && pwd)
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
export GIT_CONFIG_NOSYSTEM=1
# Pinned explicitly: an exported GIT_CONFIG_GLOBAL would otherwise win over
# $HOME and the writes below would land in the user's real global config.
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
unset GIT_DIR GIT_WORK_TREE
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main
unset CI GITHUB_ACTIONS

export MARK="$T/mark"

# stub <file> <exit> <message>: a test that records where it ran.
stub() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
#!/bin/bash
echo "\$(basename "\$0") \$PWD" >> "\$MARK"
echo "$3"
exit $2
EOF
}

# make_repo <dir>: a toolkit-shaped repo with run-tests.sh and one passing test.
make_repo() {
    mkdir -p "$1/bin/tests" "$1/bin/lib"
    cp "$RUNNER" "$1/bin/run-tests.sh"
    cp "$(dirname "$RUNNER")/lib/live-checkout.sh" "$1/bin/lib/"
    stub "$1/bin/tests/test-alpha.sh" 0 "alpha says hello"
    git -C "$1" init -q
    git -C "$1" add -A
    git -C "$1" commit -qm init
}

MAIN="$T/main"
WT="$T/wt"
OTHER="$T/other"
make_repo "$MAIN"
make_repo "$OTHER"
git -C "$MAIN" worktree add -q -b wt "$WT"
# The worktree gains a failing test that the main tree does not have.
stub "$WT/bin/tests/test-broken.sh" 3 "broken output line"

# A symlinked bin dir, the way ~/.claude/bin points into the live checkout.
ln -s "$MAIN/bin" "$T/claude-bin"
LIVE="$T/claude-bin/run-tests.sh"

# run <args...>: output in $OUT, status in $STATUS, $MARK reset first.
run() {
    rm -f "$MARK"
    OUT=$(env -C "$T" bash "$@" 2>&1); STATUS=$?
}
ran() { cat "$MARK" 2>/dev/null; }

echo "== default tree: unchanged behaviour =="
run "$MAIN/bin/run-tests.sh"
check "all tests of the main tree pass" "0" "$STATUS"
check "the main tree's test ran in the main tree" "test-alpha.sh $MAIN" "$(ran)"
check "PASS line printed" "yes" "$(contains "$OUT" "PASS bin/tests/test-alpha.sh")"
check "passing output not shown" "no" "$(contains "$OUT" "alpha says hello")"

run "$MAIN/bin/run-tests.sh" test-alpha.sh
check "basename selects a test" "test-alpha.sh $MAIN" "$(ran)"

run "$MAIN/bin/run-tests.sh" --list
check "--list exits 0" "0" "$STATUS"
check "--list names the test" "yes" "$(contains "$OUT" "RUN  bin/tests/test-alpha.sh")"
check "--list runs nothing" "" "$(ran)"

run "$MAIN/bin/run-tests.sh" test-nope.sh
check "unknown name exits 2" "2" "$STATUS"

echo "== --repo <linked worktree> =="
run "$LIVE" --repo "$WT" test-alpha.sh
check "--repo runs the worktree's test" "0" "$STATUS"
check "the test ran in the worktree, not the main tree" "test-alpha.sh $WT" "$(ran)"

run "$LIVE" --repo "$WT"
check "a failing worktree test exits 1" "1" "$STATUS"
check "FAIL line names the test" "yes" "$(contains "$OUT" "FAIL bin/tests/test-broken.sh (exit 3")"
check "failing output shown" "yes" "$(contains "$OUT" "broken output line")"
check "summary names the failure" "yes" "$(contains "$OUT" "FAILED:  bin/tests/test-broken.sh")"

run "$LIVE" --repo "$MAIN" test-broken.sh
check "--repo <main> does not see the worktree's test" "2" "$STATUS"

echo "== --repo refusals =="
run "$LIVE" --repo "$OTHER"
check "--repo of an unrelated repository exits 2" "2" "$STATUS"
check "nothing ran for the unrelated repository" "" "$(ran)"
check "the refusal says why" "yes" "$(contains "$OUT" "not a checkout of")"

run "$LIVE" --repo "$WT/bin"
check "--repo of a subdirectory exits 2" "2" "$STATUS"

run "$LIVE" --repo "$T/missing"
check "--repo of a missing directory exits 2" "2" "$STATUS"

mkdir -p "$T/plain"
run "$LIVE" --repo "$T/plain"
check "--repo of a non-git directory exits 2" "2" "$STATUS"

run "$LIVE" --repo
check "--repo without a value exits 2" "2" "$STATUS"

run "$LIVE" --repo "$WT" --repo "$MAIN"
check "a repeated --repo exits 2" "2" "$STATUS"
check "nothing ran on a repeated --repo" "" "$(ran)"

# A directory whose .git file points at the main repository is not one of
# its registered worktrees.
FAKE="$T/fake"
make_repo "$FAKE"
rm -rf "$FAKE/.git"
echo "gitdir: $MAIN/.git" > "$FAKE/.git"
run "$LIVE" --repo "$FAKE"
check "--repo of a dir with a .git file into the repo exits 2" "2" "$STATUS"
check "nothing ran for the .git-file dir" "" "$(ran)"

rm -f "$MARK"
OUT=$(env -C "$T" GIT_DIR="$MAIN/.git" bash "$LIVE" --repo "$OTHER" 2>&1); STATUS=$?
check "an exported GIT_DIR does not admit an unrelated repository" "2" "$STATUS"
check "nothing ran under an exported GIT_DIR" "" "$(ran)"

echo "== absolute path to a test =="
run "$LIVE" "$WT/bin/tests/test-alpha.sh"
check "an absolute worktree path runs that tree's test" "0" "$STATUS"
check "it ran in the worktree" "test-alpha.sh $WT" "$(ran)"

run "$LIVE" "$MAIN/bin/tests/test-alpha.sh"
check "an absolute path into the live tree works through a symlinked bin" "test-alpha.sh $MAIN" "$(ran)"

run "$LIVE" "$OTHER/bin/tests/test-alpha.sh"
check "a path in an unrelated repository exits 2" "2" "$STATUS"
check "nothing ran for the unrelated path" "" "$(ran)"

run "$LIVE" "$T/plain/test-alpha.sh"
check "a path outside any checkout exits 2" "2" "$STATUS"

run "$LIVE" --repo "$MAIN" "$WT/bin/tests/test-alpha.sh"
check "--repo and a path in another tree exit 2" "2" "$STATUS"
check "nothing ran on the conflict" "" "$(ran)"

run "$LIVE" "$MAIN/bin/tests/test-alpha.sh" "$WT/bin/tests/test-alpha.sh"
check "paths into two trees exit 2" "2" "$STATUS"

run "$LIVE" --repo "$WT" "$WT/bin/tests/test-alpha.sh"
check "--repo and a path in the same tree run it" "test-alpha.sh $WT" "$(ran)"

echo "== relative path and tree name =="
rm -f "$MARK"
OUT=$(env -C "$WT" bash "$LIVE" bin/tests/test-alpha.sh 2>&1); STATUS=$?
check "a relative path from inside the worktree runs the worktree's test" "test-alpha.sh $WT" "$(ran)"
check "the output names the worktree" "yes" "$(contains "$OUT" "Tree: $WT")"

run "$LIVE" test-alpha.sh
check "a bare run names the tree it uses" "yes" "$(contains "$OUT" "Tree: $MAIN")"

echo "== copy without .git =="
COPY="$T/copy"
mkdir -p "$COPY"
cp -r "$MAIN/bin" "$COPY/"
run "$COPY/bin/run-tests.sh" "$COPY/bin/tests/test-alpha.sh"
check "an absolute path into the runner's own tree works without .git" "test-alpha.sh $COPY" "$(ran)"

echo "== --help =="
run "$LIVE" --help
check "--help exits 0" "0" "$STATUS"
check "--help documents --repo" "yes" "$(contains "$OUT" "--repo <dir>")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
