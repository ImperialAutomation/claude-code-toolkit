#!/bin/bash
# Tests for lib/strip-sandbox-noise.sh.
#
# Usage:
#   bin/tests/test-strip-sandbox-noise.sh
#
# The helper exists to drop ONE cosmetic line the Claude Code sandbox provokes
# from almost every git call, and the risk of such a filter is not that it fails
# to match — it is that it matches too much. So the bulk of what is tested here
# is the lines that must survive: other warnings, other paths, other reasons.
# A filter that swallows a detached-HEAD warning or an aborted merge is a worse
# outcome than the noise it removes.
#
# `git` is stubbed on PATH throughout. The subject is the filter's wiring —
# which stream a line lands on, and whose exit status is reported — and a real
# git would test this machine's sandbox state instead of the helper.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="${LIB_UNDER_TEST:-$SCRIPT_DIR/../lib/strip-sandbox-noise.sh}"

if [[ ! -f "$LIB" ]]; then
    echo "library not found: $LIB" >&2
    exit 1
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

# A stub `git` that emits whatever the test asks for, on the stream the test
# asks for, and exits with the status the test asks for.
mkdir -p "$T/bin"
cat > "$T/bin/git" <<'STUB'
#!/bin/bash
if [[ -n "${GIT_STUB_STDERR:-}" ]]; then printf '%s\n' "$GIT_STUB_STDERR" >&2; fi
if [[ -n "${GIT_STUB_STDOUT:-}" ]]; then printf '%s\n' "$GIT_STUB_STDOUT"; fi
exit "${GIT_STUB_EXIT:-0}"
STUB
chmod +x "$T/bin/git"
export PATH="$T/bin:$PATH"

# Run git_filtered in a subshell that sources the library, so each case starts
# from a clean environment. Only stderr is returned.
err() { # -> the filtered stderr of one git_filtered call
    # The order is deliberate and not the SC2069 mistake: 2>&1 first aims stderr
    # at the captured stdout, then >/dev/null drops git's real stdout. Swapping
    # them would capture stdout and discard stderr, which is the opposite of
    # what every assertion below needs.
    # shellcheck disable=SC2069
    bash -c 'set -uo pipefail; . "$1"; shift; git_filtered "$@"' _ "$LIB" status 2>&1 >/dev/null
}
out() { # -> the stdout of one git_filtered call
    bash -c 'set -uo pipefail; . "$1"; shift; git_filtered "$@"' _ "$LIB" status 2>/dev/null
}
rc() { # -> the exit status of one git_filtered call
    bash -c 'set -uo pipefail; . "$1"; shift; git_filtered "$@"' _ "$LIB" status >/dev/null 2>&1
    echo $?
}

SANDBOX_LINE="warning: unable to access '/home/jan/Projects/demo/.gitmodules': Permission denied"

echo "== 1. the sandbox line is dropped =="
check "exact sandbox warning is filtered" "" \
    "$(GIT_STUB_STDERR="$SANDBOX_LINE" err)"
# The sandbox reports the path absolutely, but a relative form is the same noise.
check "relative .gitmodules path is filtered" "" \
    "$(GIT_STUB_STDERR="warning: unable to access '.gitmodules': Permission denied" err)"
# Worktrees put the repo anywhere; the path between the quotes is not fixed.
check "any repo path is filtered" "" \
    "$(GIT_STUB_STDERR="warning: unable to access '/srv/wt/repo-dev2/.gitmodules': Permission denied" err)"

echo "== 2. the filter is narrow — these must survive =="
# This is the acceptance criterion that matters most. Each line below shares
# some part of the sandbox line's shape, and each one carries real information.
survives() { # name line
    check "$1" "$2" "$(GIT_STUB_STDERR="$2" err)"
}
survives "detached HEAD warning passes" \
    "warning: you are in 'detached HEAD' state"
survives "a different unreadable path passes" \
    "warning: unable to access '/home/jan/.gitconfig': Permission denied"
survives "a .gitmodules problem that is NOT a permission error passes" \
    "warning: unable to access '/repo/.gitmodules': Input/output error"
survives "an error about .gitmodules passes" \
    "error: unable to access '/repo/.gitmodules': Permission denied"
survives "a submodule config complaint passes" \
    "fatal: no submodule mapping found in .gitmodules for path 'vendor/x'"
survives "an aborted merge passes" \
    "error: Your local changes to the following files would be overwritten by merge:"
survives "a failing hook passes" \
    "error: failed to push some refs to 'origin'"
survives "a bare warning prefix passes" \
    "warning: something else entirely went wrong"

echo "== 3. exit codes are unchanged =="
# A filter in a pipeline moves the exit status to the last command. Without
# PIPESTATUS every git failure behind this helper would report success, which
# would turn a cosmetic fix into a silent bug.
check "success stays 0" "0" "$(GIT_STUB_EXIT=0 rc)"
check "generic failure propagates" "1" "$(GIT_STUB_EXIT=1 rc)"
check "git usage error propagates" "129" "$(GIT_STUB_EXIT=129 rc)"
check "fatal propagates" "128" "$(GIT_STUB_EXIT=128 rc)"
# The combination the sandbox actually produces: a real failure whose stderr
# ALSO carries the cosmetic line. The status must still be git's own.
check "failure with filtered noise still fails" "128" \
    "$(GIT_STUB_EXIT=128 GIT_STUB_STDERR="$SANDBOX_LINE" rc)"

echo "== 4. stderr stays stderr, stdout stays stdout =="
# Callers that separate the streams rely on this; routing a warning through
# stdout changes the meaning of the output for them.
check "a surviving warning is on stderr" "warning: you are in 'detached HEAD' state" \
    "$(GIT_STUB_STDERR="warning: you are in 'detached HEAD' state" err)"
check "a surviving warning is NOT on stdout" "" \
    "$(GIT_STUB_STDERR="warning: you are in 'detached HEAD' state" out)"
check "stdout passes through untouched" "M  a.txt" \
    "$(GIT_STUB_STDOUT="M  a.txt" out)"
# Filtering stderr must not disturb stdout even when both are in play.
check "stdout is intact while stderr is filtered" "M  a.txt" \
    "$(GIT_STUB_STDOUT="M  a.txt" GIT_STUB_STDERR="$SANDBOX_LINE" out)"
# A .gitmodules permission line on stdout is data, not the sandbox warning:
# `git show` can print one. The filter only ever touches stderr.
check "stdout is never filtered" "$SANDBOX_LINE" \
    "$(GIT_STUB_STDOUT="$SANDBOX_LINE" out)"

echo "== 5. arguments reach git intact =="
# The helper stands in for a bare `git` call; dropping or reordering arguments
# would break every wrapper that adopts it.
cat > "$T/bin/git" <<'STUB'
#!/bin/bash
printf 'ARGS:'
printf ' [%s]' "$@"
printf '\n'
STUB
chmod +x "$T/bin/git"
check "arguments passed through verbatim" \
    "ARGS: [commit] [--amend] [-F] [/tmp/msg with space.txt]" \
    "$(bash -c 'set -uo pipefail; . "$1"; shift; git_filtered "$@"' _ "$LIB" \
        commit --amend -F "/tmp/msg with space.txt" 2>/dev/null)"
# `printf ' [%s]' "$@"` emits one empty pair for zero arguments, so this is the
# stub reporting an empty argument list, not the helper inventing an argument.
check "no arguments is not an error" "ARGS: []" \
    "$(bash -c 'set -uo pipefail; . "$1"; git_filtered' _ "$LIB" 2>/dev/null)"

echo "== 6. the library is safe to source =="
# The wrappers source it from arbitrary working directories, so resolution must
# not depend on cwd, and sourcing must not emit anything of its own.
check "sourcing is silent" "" \
    "$(cd / && bash -c '. "$1"' _ "$LIB" 2>&1)"
check "sourcing from an unrelated cwd works" "0" \
    "$(cd "$T" && bash -c '. "$1"; declare -F git_filtered >/dev/null' _ "$LIB" >/dev/null 2>&1; echo $?)"
# `set -e` is the wrappers' prevailing mode; the helper must not trip it, and a
# git failure must still be visible to the caller as a non-zero status.
check "survives set -e in the caller" "1" \
    "$(GIT_STUB_EXIT=1 bash -c 'set -euo pipefail; . "$1"; shift; git_filtered "$@"' _ "$LIB" status >/dev/null 2>&1; echo $?)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
