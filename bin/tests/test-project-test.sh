#!/bin/bash
# Tests for project-test.sh's full-suite warning.
#
# Usage:
#   bin/tests/test-project-test.sh
#
# The warning exists to catch an accidental full-suite run, which the script
# infers from "no path argument given". A collection-only run has no path
# argument either, so without special-casing it the script cries full suite at
# the one invocation that deliberately runs zero tests — training the reader to
# ignore the warning entirely.
#
# pytest itself is stubbed: the subject is which warning the wrapper prints for
# which argument shape, not anything pytest does with the arguments. The stub
# lives in a fake .venv so the script's own venv detection picks it up, because
# that detection runs before the argument handling under test.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../project-test.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

# PWD must sit under ~/Projects/ or the script refuses to run at all, so the
# sandbox is created there rather than in /tmp.
T=$(mktemp -d "$HOME/Projects/.test-project-test-XXXXXX")
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

# --- a stub pytest in a fake venv, so venv detection succeeds ---------------
mkdir -p "$T/.venv/bin" "$T/tests"
cat > "$T/.venv/bin/pytest" <<'STUB'
#!/bin/bash
echo "stub-pytest args: $*"
STUB
chmod +x "$T/.venv/bin/pytest"

run() { # args... -> stderr only (the warning stream)
    (cd "$T" && { "$SCRIPT" "$@" >/dev/null; } 2>&1)
}

WARNING="No test path specified"

echo "project-test.sh: full-suite warning"

# A bare run really is a full suite: the warning is correct and must stay.
out=$(run -x)
check_contains "warns when no path and no collection flag" "$out" "$WARNING"

# A path given means the run is scoped, warning not applicable.
out=$(run tests/ -v)
check_lacks "no warning when a path is given" "$out" "$WARNING"

# Collection-only runs zero tests. It is cheap by construction, so the
# full-suite warning is wrong here even though no path was given.
out=$(run --collect-only -q)
check_lacks "no warning for --collect-only" "$out" "$WARNING"

out=$(run --co)
check_lacks "no warning for --co" "$out" "$WARNING"

# The flag must still reach pytest — suppressing the warning is not allowed to
# consume the argument.
out=$(cd "$T" && "$SCRIPT" --collect-only -q 2>/dev/null)
check_contains "collection flag is passed through to pytest" "$out" "--collect-only"


# --- which tree the run resolves to -----------------------------------------
# The bug this guards: the venv search walked `.venv`, `backend/.venv`, `../.venv`
# ... relative to $PWD, so the caller's shell location decided which interpreter
# ran the tests. Give a path in another worktree and the right FILE is collected
# against the wrong VENV — and nothing says so. Two sibling trees with
# deliberately different stub pytests make that visible: the stub prints which
# tree it came from, so the assertion is "B's interpreter ran", not "a pytest ran".

A="$T/billing-api"          # the tree the shell stands in
B="$T/billing-api-dev1"     # the tree the test path points at

for tree in "$A" "$B"; do
    mkdir -p "$tree/.venv/bin" "$tree/tests"
    name=$(basename "$tree")
    cat > "$tree/.venv/bin/pytest" <<STUB
#!/bin/bash
echo "ran-from:$name args: \$*"
STUB
    chmod +x "$tree/.venv/bin/pytest"
    : > "$tree/tests/test_invoice_rounding.py"
    git -C "$tree" init -q 2>/dev/null
done

run_in() { # dir args... -> stdout+stderr combined
    local dir="$1"; shift
    (cd "$dir" && "$SCRIPT" "$@" 2>&1)
}

echo
echo "project-test.sh: root is taken from the path argument, not from PWD"

# The headline case from the issue: absolute path into B, shell sitting in A.
out=$(run_in "$A" "$B/tests/test_invoice_rounding.py")
check_contains "absolute path in B uses B's venv" "$out" "ran-from:billing-api-dev1"
check_lacks "absolute path in B does not use A's venv" "$out" "ran-from:billing-api "

# The chosen venv must be identifiable. `.venv` names no tree, so a wrong-tree
# run looks identical to a right-tree one in the log.
check_contains "reports the venv as an absolute path" "$out" "$B/.venv"

# Silence is what let this bug live. Diverging from PWD is worth a line.
# Note "$A" alone is a prefix of "$B" here, so it would match the B path as well;
# the notice has to be asserted as the whole phrase to mean anything.
check_contains "announces that the root differs from PWD" "$out" "(PWD is $A)"

# A relative path resolves within PWD, which is the tree the caller stands in.
out=$(run_in "$B" tests/test_invoice_rounding.py)
check_contains "relative path from B runs against B" "$out" "ran-from:billing-api-dev1"
check_lacks "relative path from B does not reach A" "$out" "ran-from:billing-api "
check_lacks "no divergence notice when root matches PWD" "$out" "PWD is"

# No path argument: nothing to derive a root from, so PWD stays in charge.
out=$(run_in "$B" -x)
check_contains "no path argument keeps PWD behaviour" "$out" "ran-from:billing-api-dev1"

# Paths from two trees in one command cannot both be right. Refuse rather than
# silently picking one and testing half the arguments against a foreign venv.
out=$(run_in "$A" "$A/tests/test_invoice_rounding.py" "$B/tests/test_invoice_rounding.py")
rc=$?
if [[ $rc -ne 0 ]]; then echo "  PASS: multi-root run exits non-zero"; PASS=$((PASS+1))
else echo "  FAIL: multi-root run exits non-zero (got exit 0)"; FAIL=$((FAIL+1)); fi
check_contains "names both roots when refusing" "$out" "multiple"
check_lacks "refusal runs no tests at all" "$out" "ran-from:"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
