#!/bin/bash
# Tests that every script in bin/ is committed with the execute bit.
#
# Usage:
#   bin/tests/test-exec-bits.sh
#
# Skills and hooks call the scripts as ~/.claude/bin/<script>, so a script
# committed as 100644 fails with exit 126 everywhere it is used. The tests run
# their scripts through bash or python3 and never notice: queue-claim.sh was
# 100644 from its first commit until the first /queue-run trial hit it (#260).
#
# A script is a tracked file in bin/ or bin/tests/ that starts with "#!".
# bin/lib/ holds sourced and imported modules; it is not checked.
# The mode is read from the index, which is what a checkout reproduces.

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

# nonexec_scripts <repo>: the scripts in bin/ and bin/tests/ of <repo> whose
# index mode is not 100755, one path per line, sorted.
nonexec_scripts() {
    local repo="$1" mode path
    git -C "$repo" ls-files -s -- bin | while read -r mode _ _ path; do
        [[ "$path" == bin/lib/* ]] && continue
        [[ "$(head -c 2 "$repo/$path")" == "#!" ]] || continue
        [[ "$mode" == 100755 ]] || echo "$path"
    done | sort
}

echo "== fixture: the check finds what it should =="
F="$T/repo"
mkdir -p "$F/bin/tests" "$F/bin/lib"
git -C "$F" init -q
printf '#!/bin/bash\necho claim\n' > "$F/bin/queue-claim.sh"
printf '#!/usr/bin/env python3\nprint("ok")\n' > "$F/bin/agent-tokens.py"
printf '#!/bin/bash\nexit 0\n' > "$F/bin/tests/test-queue-claim.sh"
printf '#!/bin/bash\nlive_checkout() { :; }\n' > "$F/bin/lib/live-checkout.sh"
printf 'denylist pattern, no shebang\n' > "$F/bin/escalation-denylist.example"
chmod +x "$F/bin/agent-tokens.py"
git -C "$F" add -A
git -C "$F" update-index --chmod=-x bin/queue-claim.sh bin/tests/test-queue-claim.sh
check "fixture reports the two 100644 scripts, not lib/ or a non-script" \
    $'bin/queue-claim.sh\nbin/tests/test-queue-claim.sh' "$(nonexec_scripts "$F")"
git -C "$F" update-index --chmod=+x bin/queue-claim.sh bin/tests/test-queue-claim.sh
check "fixture reports nothing once the bits are set" "" "$(nonexec_scripts "$F")"

echo "== this repository =="
check "every script in bin/ and bin/tests/ is 100755" "" "$(nonexec_scripts "$REPO_DIR")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
