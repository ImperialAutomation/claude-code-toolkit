#!/bin/bash
# Tests for gh-save.sh.
#
# Usage:
#   bin/tests/test-gh-save.sh
#
# gh-save.sh delegates to cmd-save.sh, so what is tested here is the delegation
# contract the ~14 skill callers depend on: the gh arguments arrive intact, the
# file is where they will read it, and a failed gh call does not look like a
# successful capture. `gh` itself is stubbed on PATH — the subject is the
# wrapper's wiring, and a real gh call would test GitHub's availability instead.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../gh-save.sh}"

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

# A stub `gh` that echoes the arguments it was handed, so the test can assert
# they survived the hop through the wrapper. GH_EXIT lets a run fail on demand.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf 'ARGS:'
printf ' [%s]' "$@"
printf '\n'
if [[ -n "${GH_STDERR:-}" ]]; then printf '%s\n' "$GH_STDERR" >&2; fi
exit "${GH_EXIT:-0}"
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

run() { bash "$SCRIPT" "$@"; }

echo "== 1. gh output lands in the file =="
run "$T/out.json" issue view 795 --json title,body >/dev/null 2>&1
check "arguments passed through verbatim" \
    "ARGS: [issue] [view] [795] [--json] [title,body]" \
    "$(cat "$T/out.json")"
check "exit 0 on success" "0" \
    "$(run "$T/out.json" issue view 795 >/dev/null 2>&1; echo $?)"
# The documented call shape from claude-md/global.md and the skills.
run "$T/issue.json" issue view 68 --json title,body,labels >/dev/null 2>&1
check "documented call shape works" \
    "ARGS: [issue] [view] [68] [--json] [title,body,labels]" \
    "$(cat "$T/issue.json")"

echo "== 2. a failing gh call is not a successful capture =="
# Callers read the file afterwards; without status propagation they would parse
# an error message as issue data.
check "gh failure propagates" "1" \
    "$(GH_EXIT=1 run "$T/fail.json" issue view 999999 >/dev/null 2>&1; echo $?)"
check "gh exit 4 propagates" "4" \
    "$(GH_EXIT=4 run "$T/fail.json" issue view 999999 >/dev/null 2>&1; echo $?)"

echo "== 3. gh diagnostics do not pollute the JSON =="
# gh writes warnings to stderr; folding them into the file would make the
# capture unparseable for every skill that reads it with a JSON parser.
GH_STDERR='gh: warning: rate limit low' run "$T/clean.json" issue view 1 >/dev/null 2>&1
check "file holds only gh stdout" "ARGS: [issue] [view] [1]" "$(cat "$T/clean.json")"
check "warning still reaches the caller" "yes" \
    "$(case "$(GH_STDERR='gh: warning: rate limit low' run "$T/clean.json" issue view 1 2>&1 >/dev/null)" in
         *"rate limit low"*) echo yes ;; *) echo no ;;
       esac)"

echo "== 4. usage =="
check "no args exits 2"      "2" "$(run >/dev/null 2>&1; echo $?)"
check "only outfile exits 2" "2" "$(run "$T/x.json" >/dev/null 2>&1; echo $?)"
check "usage goes to stderr" "yes" \
    "$(case "$(run 2>&1 >/dev/null)" in *usage*) echo yes ;; *) echo no ;; esac)"
# The summary belongs on stdout, not in the capture file.
check "summary names the file" "yes" \
    "$(case "$(run "$T/sum.json" issue view 1 2>/dev/null)" in *sum.json*) echo yes ;; *) echo no ;; esac)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
