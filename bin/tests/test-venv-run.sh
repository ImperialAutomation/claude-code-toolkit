#!/bin/bash
# Tests for venv-run.sh's project root handling.
#
# Usage:
#   bin/tests/test-venv-run.sh
#
# venv-run.sh takes a COMMAND, not a path, so unlike project-test.sh it has no
# argument to derive a project root from — `venv-run.sh python script.py` could
# mean either tree and guessing from a later argument would be worse than not
# guessing. The root is therefore stated with --repo, and PWD remains the
# default.
#
# The binaries are stubs: the subject is which venv the script selects, not what
# python or alembic do once selected. Each stub prints the tree it came from, so
# an assertion can distinguish "the right tree ran" from "something ran".

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../venv-run.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

# PWD must sit under ~/Projects/ or the script refuses to run at all, so the
# sandbox is created there rather than in /tmp.
T=$(mktemp -d "$HOME/Projects/.test-venv-run-XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check_contains() { # name haystack needle
    if [[ "$2" == *"$3"* ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected to find '$3' in: $2)"; FAIL=$((FAIL+1)); fi
}

check_lacks() { # name haystack needle
    if [[ "$2" != *"$3"* ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (did not expect '$3' in: $2)"; FAIL=$((FAIL+1)); fi
}

# --- two sibling trees, each with its own stubbed interpreter ----------------
# Named as worktrees of one repository actually are, since that is the case the
# --repo flag exists for.
A="$T/billing-api"          # the tree the shell stands in
B="$T/billing-api-dev1"     # the tree the caller means

for tree in "$A" "$B"; do
    mkdir -p "$tree/.venv/bin"
    name=$(basename "$tree")
    cat > "$tree/.venv/bin/python" <<STUB
#!/bin/bash
echo "ran-from:$name args: \$*"
STUB
    chmod +x "$tree/.venv/bin/python"
done

run_in() { # dir args... -> stdout+stderr combined
    local dir="$1"; shift
    (cd "$dir" && "$SCRIPT" "$@" 2>&1)
}

echo "venv-run.sh: --repo selects the tree"

# Without --repo nothing changes: PWD is the only information available.
out=$(run_in "$B" python -c "pass")
check_contains "no --repo uses PWD's venv" "$out" "ran-from:billing-api-dev1"

# The case the flag exists for: shell in A, work in B.
out=$(run_in "$A" --repo "$B" python -c "pass")
check_contains "--repo B uses B's venv" "$out" "ran-from:billing-api-dev1"
# "billing-api" is a prefix of "billing-api-dev1", so the trailing space is what
# pins this to A's stub rather than matching B's line as well.
check_lacks "--repo B does not use A's venv" "$out" "ran-from:billing-api "

# `.venv` names no tree, so a wrong-tree run reads exactly like a right one in
# the log. That absence of signal is half of why this class of bug survives.
check_contains "reports the binary's venv as an absolute path" "$out" "$B/.venv"

# The command and its arguments must survive the flag parsing intact.
out=$(run_in "$A" --repo "$B" python -c "pass")
check_contains "command arguments are passed through" "$out" "args: -c pass"

# A --repo that is not a directory is a typo, and falling back to PWD would run
# the very tree the caller was trying to avoid.
out=$(run_in "$A" --repo "$T/billing-api-dev9" python -c "pass")
rc=$?
if [[ $rc -ne 0 ]]; then echo "  PASS: nonexistent --repo exits non-zero"; PASS=$((PASS+1))
else echo "  FAIL: nonexistent --repo exits non-zero (got exit 0)"; FAIL=$((FAIL+1)); fi
check_lacks "nonexistent --repo runs nothing" "$out" "ran-from:"

# --repo without a value would otherwise swallow the command as its argument.
out=$(run_in "$A" --repo)
rc=$?
if [[ $rc -ne 0 ]]; then echo "  PASS: --repo without a value exits non-zero"; PASS=$((PASS+1))
else echo "  FAIL: --repo without a value exits non-zero (got exit 0)"; FAIL=$((FAIL+1)); fi

# A command named --repo-something must not be mistaken for the flag.
out=$(run_in "$B" python --repo-style=x)
check_contains "flag parsing stops at the command" "$out" "args: --repo-style=x"

# --repo AFTER the command belongs to the command. Consuming it there would both
# redirect the venv behind the caller's back and eat an argument the command
# needed, e.g. a tool of its own that takes a --repo.
out=$(run_in "$A" python --repo "$B")
check_contains "--repo after the command is the command's argument" "$out" "ran-from:billing-api "
check_contains "--repo after the command is passed through" "$out" "args: --repo $B"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
