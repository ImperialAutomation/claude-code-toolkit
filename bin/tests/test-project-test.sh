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

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
