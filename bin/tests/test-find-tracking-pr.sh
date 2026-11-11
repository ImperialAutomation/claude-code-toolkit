#!/bin/bash
# Tests for find-tracking-pr.sh.
#
# Usage:
#   bin/tests/test-find-tracking-pr.sh
#
# Only `gh` is a stub, put first on PATH. It answers every `gh pr list` with
# the JSON array in $STUB/branch (when the call searches `head:`) or
# $STUB/body (any other search), so the stub mimics GitHub's loose search:
# it returns candidates and the script must do the exact filtering itself.
# Every call is logged to $STUB/calls; $STUB/fail makes gh fail.
#
# Hermetic: $HOME is a temp dir and no real `gh` or network is reached.
#
# When adding a case, check it actually constrains the script: break the rule
# in find-tracking-pr.sh, confirm THIS test goes red, then revert.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FIND="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../find-tracking-pr.sh}"

if [[ ! -f "$FIND" ]]; then
    echo "script not found: $FIND" >&2
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
mkdir -p "$STUB/bin"
cat > "$STUB/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB/calls"
[[ -e "$STUB/fail" ]] && { echo "gh: network down" >&2; exit 1; }
if [[ "$1 $2" == "pr list" ]]; then
    case " $* " in
        *" head:"*) cat "$STUB/branch" 2>/dev/null || echo "[]" ;;
        *) cat "$STUB/body" 2>/dev/null || echo "[]" ;;
    esac
    exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
chmod +x "$STUB/bin/gh"
export STUB
export PATH="$STUB/bin:$PATH"

PARENT=42
REPO=owner/repo

# pr <number> <branch> <body> -> one PR object as gh prints it
pr() {
    jq -cn --argjson n "$1" --arg b "$2" --arg body "$3" \
        '{number: $n, title: ("PR " + ($n | tostring)), headRefName: $b, body: $body}'
}
SUB_PR=$(pr 101 "issue-77-sub" "Closes #77. Part of #$PARENT.")
TRACKING_PR=$(pr 102 "epic-work" "Tracking.

Closes #$PARENT")
PREFIX_PR=$(pr 103 "issue-${PARENT}0-x" "Closes #${PARENT}0")
BRANCH_PR=$(pr 104 "issue-$PARENT-epic" "Tracking table only")

reset_stub() { rm -f "$STUB/branch" "$STUB/body" "$STUB/fail" "$STUB/calls"; }
branch_hits() { printf '[%s]\n' "$(IFS=,; echo "$*")" > "$STUB/branch"; }
body_hits() { printf '[%s]\n' "$(IFS=,; echo "$*")" > "$STUB/body"; }

OUT=""; RC=0; ERR=""
run() { OUT=$(bash "$FIND" "$@" 2>"$T/stderr"); RC=$?; ERR=$(cat "$T/stderr"); }
numbers() { jq -c '[.[].number]' <<< "$OUT" 2>/dev/null; }

echo "== 0. --help and usage =="
reset_stub
run --help
check "--help exits 0" "0" "$RC"
check "--help prints usage" "yes" "$(contains "$OUT" "sage")"
check "--help names --exclude" "yes" "$(contains "$OUT" "--exclude")"
check "--help calls no gh" "no" "$([[ -e "$STUB/calls" ]] && echo yes || echo no)"
run "$REPO"
check "one positional: exit 2" "2" "$RC"
run "$REPO" abc
check "non-numeric issue: exit 2" "2" "$RC"
run "$REPO" "$PARENT" --exclude
check "--exclude without value: exit 2" "2" "$RC"
run "$REPO" "$PARENT" --exclude x
check "--exclude non-numeric: exit 2" "2" "$RC"
run "$REPO" "$PARENT" --bogus
check "unknown option: exit 2" "2" "$RC"

echo "== 1. loose hits are filtered out, the real tracking PR remains =="
reset_stub
branch_hits "$PREFIX_PR"
body_hits "$SUB_PR" "$TRACKING_PR" "$PREFIX_PR"
run "$REPO" "$PARENT"
check "exit 0" "0" "$RC"
check "only the tracking PR" "[102]" "$(numbers)"
check "output keeps number, title, body" '["body","number","title"]' "$(jq -c '.[0] | keys' <<< "$OUT")"

reset_stub
body_hits "$TRACKING_PR" "$(pr 108 "w" "Closes #$PARENT")"
run "$REPO" "$PARENT"
check "two real hits: only the first is printed" "[102]" "$(numbers)"

echo "== 2. only the sub-issue PR: not found =="
reset_stub
body_hits "$SUB_PR"
run "$REPO" "$PARENT"
check "exit 1" "1" "$RC"
check "nothing on stdout" "" "$OUT"
check "says not found" "yes" "$(contains "$ERR" "No open tracking PR found")"

echo "== 3. branch lookup matches issue-<N>- exactly =="
reset_stub
branch_hits "$PREFIX_PR" "$BRANCH_PR"
run "$REPO" "$PARENT"
check "exit 0" "0" "$RC"
check "branch issue-$PARENT-epic found, issue-${PARENT}0-x skipped" "[104]" "$(numbers)"

reset_stub
branch_hits "$(pr 105 "issue-$PARENT" "x")"
run "$REPO" "$PARENT"
check "bare branch issue-$PARENT found" "[105]" "$(numbers)"

reset_stub
branch_hits "$PREFIX_PR"
run "$REPO" "$PARENT"
check "only a prefix branch: exit 1" "1" "$RC"

echo "== 4. --exclude =="
reset_stub
body_hits "$TRACKING_PR"
run "$REPO" "$PARENT" --exclude 102
check "excluded body hit: exit 1" "1" "$RC"

reset_stub
branch_hits "$BRANCH_PR"
body_hits "$TRACKING_PR"
run "$REPO" "$PARENT" --exclude 104
check "excluded branch hit falls through to the body hit" "[102]" "$(numbers)"

reset_stub
branch_hits "$BRANCH_PR"
body_hits "$TRACKING_PR"
run "$REPO" "$PARENT" --exclude 104 --exclude 102
check "repeated --exclude: exit 1" "1" "$RC"

reset_stub
body_hits "$TRACKING_PR"
run --exclude 999 "$REPO" "$PARENT"
check "--exclude before the positionals works" "[102]" "$(numbers)"

echo "== 5. keyword variants =="
for body in "Fixes #$PARENT" "resolves #$PARENT" "CLOSES #$PARENT." "Closed #$PARENT"; do
    reset_stub
    body_hits "$(pr 106 "w" "$body")"
    run "$REPO" "$PARENT"
    check "'$body' matches" "[106]" "$(numbers)"
done
for body in "Closes #${PARENT}0" "Part of #$PARENT, closes nothing" "Closes #1$PARENT"; do
    reset_stub
    body_hits "$(pr 107 "w" "$body")"
    run "$REPO" "$PARENT"
    check "'$body' does not match" "1" "$RC"
done

echo "== 6. what gh is asked =="
reset_stub
run "$REPO" "$PARENT"
calls=$(cat "$STUB/calls")
check "body search uses the quoted phrase" "yes" "$(contains "$calls" "\"Closes #$PARENT\" in:body")"
check "fetches more than one candidate" "yes" "$(contains "$calls" "--limit 20")"
check "asks for headRefName" "yes" "$(contains "$calls" "headRefName")"
check "queries the given repo" "yes" "$(contains "$calls" "--repo $REPO")"

echo "== 7. gh fails =="
reset_stub
touch "$STUB/fail"
run "$REPO" "$PARENT"
check "gh failure: exit 2" "2" "$RC"
check "gh failure: nothing on stdout" "" "$OUT"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
