#!/bin/bash
# Tests for agent-pr-wip.sh.
#
# Usage:
#   bin/tests/test-agent-pr-wip.sh
#
# Only `gh` is a stub, put first on PATH. It answers
# `gh pr list ... --label agent-authored ...` with $STUB/count open PRs (one
# JSON object per PR, the shape `gh pr list --json number` prints) and fails
# when $STUB/fail exists. Every call is logged as `<cwd>|<args>` to
# $STUB/calls, so the tests can see which repo and which label were queried.
#
# Hermetic: $HOME is a temp dir and no real `gh` or network is reached.
#
# When adding a case, check it actually constrains the script: break the rule
# in agent-pr-wip.sh, confirm THIS test goes red, then revert.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WIP="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../agent-pr-wip.sh}"

if [[ ! -f "$WIP" ]]; then
    echo "script not found: $WIP" >&2
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

# gh stub
STUB="$T/stub"
mkdir -p "$STUB/bin"
cat > "$STUB/bin/gh" <<'EOF'
#!/bin/bash
echo "$PWD|$*" >> "$STUB/calls"
[[ -e "$STUB/fail" ]] && { echo "gh: network down" >&2; exit 1; }
if [[ "$1 $2" == "pr list" ]]; then
    case " $* " in *" --label agent-authored "*) ;; *) echo "[]"; exit 0 ;; esac
    n=$(cat "$STUB/count" 2>/dev/null || echo 0)
    # --jq length: gh applies the filter itself and prints the bare count.
    case " $* " in *" --jq length "*) echo "$n"; exit 0 ;; esac
    printf '['
    for ((i = 1; i <= n; i++)); do
        (( i > 1 )) && printf ','
        printf '{"number":%d}' "$i"
    done
    printf ']\n'
    exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
chmod +x "$STUB/bin/gh"
export STUB
export PATH="$STUB/bin:$PATH"

reset_stub() { rm -f "$STUB/count" "$STUB/fail" "$STUB/calls"; }
open_prs() { echo "$1" > "$STUB/count"; }

R="$T/repo"
mkdir -p "$R"

OUT=""; RC=0
run() { OUT=$(bash "$WIP" "$@" 2>"$T/stderr"); RC=$?; ERR=$(cat "$T/stderr"); }

echo "== 0. --help =="
reset_stub
run --help
check "--help exits 0" "0" "$RC"
check "--help prints usage" "yes" "$(contains "$OUT" "sage")"
check "--help names the label" "yes" "$(contains "$OUT" "agent-authored")"
check "--help calls no gh" "no" "$([[ -e "$STUB/calls" ]] && echo yes || echo no)"

echo "== 1. below the limit =="
reset_stub
open_prs 0
run --repo "$R"
check "0 open: exit 0" "0" "$RC"
check "0 open: prints 0/3" "0/3" "$OUT"

reset_stub
open_prs 2
run --repo "$R"
check "2 open: exit 0" "0" "$RC"
check "2 open: prints 2/3" "2/3" "$OUT"

echo "== 2. at the limit =="
reset_stub
open_prs 3
run --repo "$R"
check "3 open: exit 1" "1" "$RC"
check "3 open: prints 3/3" "3/3" "$OUT"

echo "== 3. above the limit =="
reset_stub
open_prs 5
run --repo "$R"
check "5 open: exit 1" "1" "$RC"
check "5 open: prints 5/3" "5/3" "$OUT"

echo "== 4. what gh is asked =="
reset_stub
open_prs 1
run --repo "$R"
calls=$(cat "$STUB/calls")
check "gh ran in the --repo directory" "yes" "$(contains "$calls" "$R|")"
check "gh asked for open PRs" "yes" "$(contains "$calls" "--state open")"
check "gh asked for the agent-authored label" "yes" "$(contains "$calls" "--label agent-authored")"

reset_stub
open_prs 1
OUT=$(env -C "$R" bash "$WIP" 2>/dev/null); RC=$?
check "no --repo: gh runs in the current directory" "yes" "$(contains "$(cat "$STUB/calls")" "$R|")"
check "no --repo: prints 1/3" "1/3" "$OUT"

echo "== 5. gh fails =="
reset_stub
touch "$STUB/fail"
run --repo "$R"
check "gh failure: exit 2" "2" "$RC"
check "gh failure: nothing on stdout" "" "$OUT"
check "gh failure: gh's error on stderr" "yes" "$(contains "$ERR" "network down")"

echo "== 6. usage errors =="
reset_stub
run --repo "$T/nowhere"
check "missing repo: exit 2" "2" "$RC"
run --bogus
check "unknown option: exit 2" "2" "$RC"
run --repo
check "--repo without a value: exit 2" "2" "$RC"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
