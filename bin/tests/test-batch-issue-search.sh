#!/bin/bash
# Tests for batch-issue-search.sh.
#
# Usage:
#   bin/tests/test-batch-issue-search.sh
#
# Only `gh` is a stub, put first on PATH. `gh issue list` answers with the
# JSON array in $STUB/hits/<query> (an empty array when that file is absent),
# so each query can be given its own hits. Every call is logged to
# $STUB/calls, one argument per line between `--- call` markers; $STUB/fail
# makes gh fail with a message on stderr.
#
# Hermetic: $HOME is a temp dir and no real `gh` or network is reached.
#
# When adding a case, check it actually constrains the script: break the rule
# in batch-issue-search.sh, confirm THIS test goes red, then revert.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SEARCH="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../batch-issue-search.sh}"

if [[ ! -f "$SEARCH" ]]; then
    echo "script not found: $SEARCH" >&2
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
mkdir -p "$HOME"

STUB="$T/stub"
mkdir -p "$STUB/bin" "$STUB/hits"
cat > "$STUB/bin/gh" <<'EOF'
#!/bin/bash
{ echo "--- call"; printf '%s\n' "$@"; } >> "$STUB/calls"
[[ -e "$STUB/fail" ]] && { echo "gh: network down" >&2; exit 1; }
if [[ "$1 $2" != "issue list" ]]; then
    echo "unexpected gh call: $*" >&2
    exit 1
fi
query=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "--search" ]] && query="$2"
    shift
done
cat "$STUB/hits/$query" 2>/dev/null || echo "[]"
EOF
chmod +x "$STUB/bin/gh"
export STUB
export PATH="$STUB/bin:$PATH"

# issue <number> <state> <title> -> one issue object as gh prints it
issue() {
    jq -cn --argjson n "$1" --arg s "$2" --arg t "$3" '{number: $n, state: $s, title: $t}'
}
hits() { # query issue-objects...
    local query="$1"; shift
    printf '[%s]\n' "$(IFS=,; echo "$*")" > "$STUB/hits/$query"
}

reset_stub() { rm -rf "$STUB/hits" "$STUB/fail" "$STUB/calls"; mkdir -p "$STUB/hits"; }

OUT=""; RC=0; ERR=""
run() { OUT=$(bash "$SEARCH" "$@" 2>"$T/stderr"); RC=$?; ERR=$(cat "$T/stderr"); }

echo "== 0. --help and usage =="
reset_stub
run --help
check "--help exits 0" "0" "$RC"
check "--help prints usage" "yes" "$(contains "$OUT" "sage")"
check "--help names --state" "yes" "$(contains "$OUT" "--state")"
check "--help calls no gh" "no" "$([[ -e "$STUB/calls" ]] && echo yes || echo no)"
run
check "no query: exit 2" "2" "$RC"
run --bogus x
check "unknown option: exit 2" "2" "$RC"
run --state maybe x
check "invalid --state: exit 2" "2" "$RC"
run --limit abc x
check "non-numeric --limit: exit 2" "2" "$RC"
run --limit
check "--limit without value: exit 2" "2" "$RC"
check "usage errors call no gh" "no" "$([[ -e "$STUB/calls" ]] && echo yes || echo no)"

echo "== 1. three queries, grouped output and a deduplicated summary =="
reset_stub
hits "login bug" "$(issue 12 OPEN "Login fails on Safari")" "$(issue 30 CLOSED "Session expires early")"
hits "auth error" "$(issue 12 OPEN "Login fails on Safari")"
hits "dark mode" "$(issue 7 OPEN "Add dark mode")"
run "login bug" "auth error" "dark mode"
check "exit 0" "0" "$RC"
check "header for query 1" "yes" "$(contains "$OUT" "== login bug")"
check "header for query 2" "yes" "$(contains "$OUT" "== auth error")"
check "header for query 3" "yes" "$(contains "$OUT" "== dark mode")"
check "hit line format" "yes" "$(contains "$OUT" "#30 CLOSED Session expires early")"
check "groups in argument order" "== login bug|== auth error|== dark mode" \
    "$(grep '^== [a-z]' <<< "$OUT" | paste -sd '|')"
GROUP2=$(awk '/^== auth error/{f=1; next} /^== /{f=0} f' <<< "$OUT")
check "query 2 group holds only its own hit" "#12 OPEN Login fails on Safari" "$(grep '^#' <<< "$GROUP2")"
SUMMARY=$(awk '/^== Summary/{f=1; next} f' <<< "$OUT")
check "summary present" "yes" "$(contains "$OUT" "== Summary")"
check "summary lists #12 once" "1" "$(grep -c '^#12 ' <<< "$SUMMARY")"
check "summary names both queries for #12" "yes" \
    "$(grep '^#12 ' <<< "$SUMMARY" | grep -q 'login bug' && grep '^#12 ' <<< "$SUMMARY" | grep -q 'auth error' && echo yes || echo no)"
check "summary lists every matched issue" "3" "$(grep -c '^#' <<< "$SUMMARY")"
check "issue found by most queries comes first" "#12" "$(grep '^#' <<< "$SUMMARY" | head -1 | cut -d' ' -f1)"
check "one gh call per query" "3" "$(grep -c '^--- call' "$STUB/calls")"
check "stderr empty" "" "$ERR"

echo "== 2. zero hits =="
reset_stub
run "nothing here" "nor here"
check "exit 0" "0" "$RC"
check "explicit no matches line" "yes" "$(contains "$OUT" "no matches")"

echo "== 3. options are passed through to gh, defaults otherwise =="
reset_stub
run --repo owner/repo --state open --limit 3 x
CALL=$(paste -sd ' ' "$STUB/calls")
check "--repo passed" "yes" "$(contains "$CALL" "--repo owner/repo")"
check "--state passed" "yes" "$(contains "$CALL" "--state open")"
check "--limit passed" "yes" "$(contains "$CALL" "--limit 3")"
check "--search passed" "yes" "$(contains "$CALL" "--search x")"
reset_stub
run x
CALL=$(paste -sd ' ' "$STUB/calls")
check "default --state all" "yes" "$(contains "$CALL" "--state all")"
check "default --limit 10" "yes" "$(contains "$CALL" "--limit 10")"
check "no --repo by default" "no" "$(contains "$CALL" "--repo")"
reset_stub
run -- --looks-like-option
CALL=$(paste -sd ' ' "$STUB/calls")
check "-- ends options" "yes" "$(contains "$CALL" "--search --looks-like-option")"

echo "== 4. a failing gh =="
reset_stub
touch "$STUB/fail"
run "a" "b"
check "non-zero exit" "1" "$RC"
check "gh stderr visible" "yes" "$(contains "$ERR" "gh: network down")"
check "every query still tried" "2" "$(grep -c '^--- call' "$STUB/calls")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
