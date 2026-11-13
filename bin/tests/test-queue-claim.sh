#!/bin/bash
# Tests for queue-claim.sh.
#
# Usage:
#   bin/tests/test-queue-claim.sh
#
# Only `gh` is a stub, put first on PATH. It keeps a tiny issue tracker in
# $STUB/issues/<N>/: `labels` (one per line), `created` (ISO date) and `state`
# (OPEN when absent). It answers the four calls queue-claim.sh makes:
#   gh issue list ... --label <L> ... --json ...   open issues with label <L>
#       (agent-ready, or agent-rework for claim --rework) as JSON, NEWEST
#       first on purpose (the script must sort);
#   gh issue view <N> --json state,labels
#   gh issue edit <N> [--add-label X]... [--remove-label X]...
#   gh issue comment <N> --body-file <file>   appended to $STUB/comments/<N>
# Races are simulated with hooks: $STUB/after-list runs after a list call,
# $STUB/after-claim-<N> after agent-wip is added to <N>. $STUB/fail-<cmd>
# (list, view, edit, comment) makes that call fail. Every call is logged as
# `<cwd>|<args>` to $STUB/calls.
#
# Hermetic: $HOME is a temp dir, the run log goes to $QUEUE_RUNS_LOG in the
# temp dir, and no real `gh` or network is reached.
#
# When adding a case, check it actually constrains the script: break the rule
# in queue-claim.sh, confirm THIS test goes red, then revert.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QC="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../queue-claim.sh}"

if [[ ! -f "$QC" ]]; then
    echo "script not found: $QC" >&2
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
I="$STUB/issues"
has_label() { [[ -f "$I/$1/labels" ]] && grep -qxF -- "$2" "$I/$1/labels"; }
labels_json() { # <N>
    if [[ -s "$I/$1/labels" ]]; then
        jq -R '{name: .}' "$I/$1/labels" | jq -s .
    else
        echo '[]'
    fi
}
state_of() { cat "$I/$1/state" 2>/dev/null || echo OPEN; }
[[ "$1" == "issue" ]] || { echo "unexpected gh call: $*" >&2; exit 1; }
cmd="$2"; shift 2
[[ -e "$STUB/fail-$cmd" ]] && { echo "gh: network down" >&2; exit 1; }
# --jq: gh applies the filter itself and prints raw strings, like jq -r.
filter="."
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[i]}" == "--jq" ]] && filter="${args[i + 1]}"
done
if [[ "$filter" != "." && ( "$cmd" == "list" || "$cmd" == "view" ) ]]; then
    "$0" issue "$cmd" "${args[@]/--jq/--no-jq}" | jq -r "$filter"
    exit "${PIPESTATUS[0]}"
fi
case "$cmd" in
    list)
        want=""
        for ((i = 0; i < ${#args[@]}; i++)); do
            [[ "${args[i]}" == "--label" ]] && want="${args[i + 1]}"
        done
        [[ -n "$want" ]] || { echo "list without --label" >&2; exit 1; }
        out='[]'
        # newest first, like gh's default order
        for d in $(ls "$I" 2>/dev/null); do
            [[ "$(state_of "$d")" == "OPEN" ]] && has_label "$d" "$want" || continue
            out=$(jq --argjson n "$d" --arg c "$(cat "$I/$d/created")" \
                    --argjson l "$(labels_json "$d")" \
                    '. + [{number: $n, createdAt: $c, labels: $l}]' <<< "$out")
        done
        jq 'sort_by(.createdAt) | reverse' <<< "$out"
        [[ -x "$STUB/after-list" ]] && "$STUB/after-list"
        ;;
    view)
        n="$1"
        [[ -d "$I/$n" ]] || { echo "no issue $n" >&2; exit 1; }
        jq -n --arg s "$(state_of "$n")" --argjson l "$(labels_json "$n")" \
            '{state: $s, labels: $l}'
        ;;
    edit)
        n="$1"; shift
        [[ -d "$I/$n" ]] || { echo "no issue $n" >&2; exit 1; }
        touch "$I/$n/labels"
        claimed=false
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --add-label)
                    has_label "$n" "$2" || echo "$2" >> "$I/$n/labels"
                    [[ "$2" == "agent-wip" ]] && claimed=true
                    shift 2 ;;
                --remove-label)
                    grep -vxF -- "$2" "$I/$n/labels" > "$I/$n/labels.new"
                    mv "$I/$n/labels.new" "$I/$n/labels"
                    shift 2 ;;
                *) echo "unexpected edit arg: $1" >&2; exit 1 ;;
            esac
        done
        $claimed && [[ -x "$STUB/after-claim-$n" ]] && "$STUB/after-claim-$n"
        ;;
    comment)
        n="$1"
        [[ "$2" == "--body-file" && -f "$3" ]] || { echo "comment needs --body-file" >&2; exit 1; }
        mkdir -p "$STUB/comments"
        { cat "$3"; echo "----"; } >> "$STUB/comments/$n"
        ;;
    *) echo "unexpected gh issue call: $cmd $*" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$STUB/bin/gh"
export STUB
export PATH="$STUB/bin:$PATH"

export QUEUE_RUNS_LOG="$T/queue-runs.tsv"
export CLAUDE_CODE_SESSION_ID="sess-1"
reset_stub() { rm -rf "$STUB/issues" "$STUB/comments" "$STUB"/after-* "$STUB"/fail-* "$STUB/calls" "$QUEUE_RUNS_LOG"; mkdir -p "$STUB/issues"; }
# issue <N> <created-date> [label...]
issue() {
    local n="$1" c="$2"; shift 2
    mkdir -p "$STUB/issues/$n"
    echo "${c}T10:00:00Z" > "$STUB/issues/$n/created"
    : > "$STUB/issues/$n/labels"
    local l; for l in "$@"; do echo "$l" >> "$STUB/issues/$n/labels"; done
}
labels_of() { sort "$STUB/issues/$1/labels" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
has() { grep -qxF -- "$2" "$STUB/issues/$1/labels" && echo yes || echo no; }
comments_of() { cat "$STUB/comments/$1" 2>/dev/null; }
hook() { # hook <name> <script body>
    printf '#!/bin/bash\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"
}

R="$T/repo"
mkdir -p "$R"
MSG="$T/failure.md"
printf 'CI red on test-foo.sh\nTried: two fixes\n' > "$MSG"
# The --json output of agent-tokens.py, numbers from #254's example.
TOK="$T/tokens.json"
cat > "$TOK" <<'EOF'
{"agent_id": "a1", "totals": {"input_tokens": 42, "cache_creation_input_tokens": 94872, "cache_read_input_tokens": 1470008, "output_tokens": 14878}, "agents": 3, "models": ["claude-opus-5-5"], "summary": "in 0.0k / cw 95k / cr 1.47M / out 15k, 3 agents"}
EOF
TOK_LINE="tokens: in 0.0k / cw 95k / cr 1.47M / out 15k, 3 agents"
TSV_HEADER_V1=$'date\tissue\toutcome\tpr_url\tinput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\toutput_tokens\tagents'
TSV_HEADER_V2="$TSV_HEADER_V1"$'\tsession'
# Written out by hand on purpose: the script derives them from TOKEN_KEYS.
REVIEW_HEADER=$'review\treview_final\treview_findings\treview_input_tokens\treview_cache_creation_input_tokens\treview_cache_read_input_tokens\treview_output_tokens\treview_agents\tfix_input_tokens\tfix_cache_creation_input_tokens\tfix_cache_read_input_tokens\tfix_output_tokens\tfix_agents'
TSV_HEADER="$TSV_HEADER_V2"$'\t'"$REVIEW_HEADER"
# The 13 review columns of a release without review options: all empty.
NO_REVIEW=$'\t\t\t\t\t\t\t\t\t\t\t\t'
# Columns 2 to 10 (issue to session) and 11 on (the review columns).
log_rows() { tail -n +2 "$QUEUE_RUNS_LOG" 2>/dev/null | cut -f2-10; }
review_rows() { tail -n +2 "$QUEUE_RUNS_LOG" 2>/dev/null | cut -f11-; }
log_lines() { wc -l < "$QUEUE_RUNS_LOG" 2>/dev/null | tr -d ' ' || echo 0; }

OUT=""; RC=0; ERR=""
run() { OUT=$(bash "$QC" --repo "$R" "$@" 2>"$T/stderr"); RC=$?; ERR=$(cat "$T/stderr"); }

echo "== 0. --help =="
reset_stub
OUT=$(bash "$QC" --help 2>/dev/null); RC=$?
check "--help exits 0" "0" "$RC"
check "--help prints usage" "yes" "$(contains "$OUT" "sage")"
check "--help names agent-failed" "yes" "$(contains "$OUT" "agent-failed")"
check "--help names agent-pr" "yes" "$(contains "$OUT" "agent-pr")"
check "--help names agent-rework" "yes" "$(contains "$OUT" "agent-rework")"
check "--help names claim --rework" "yes" "$(contains "$OUT" "claim --rework")"
check "--help names release rework" "yes" "$(contains "$OUT" "rework <url>")"
check "--help names --tokens" "yes" "$(contains "$OUT" "--tokens")"
check "--help names QUEUE_RUNS_LOG" "yes" "$(contains "$OUT" "QUEUE_RUNS_LOG")"
for opt in --review --review-final --review-findings --review-tokens --fix-tokens; do
    check "--help names $opt" "yes" "$(contains "$OUT" "$opt ")"
done
check "--help calls no gh" "no" "$([[ -e "$STUB/calls" ]] && echo yes || echo no)"

echo "== 1. empty queue =="
reset_stub
run claim
check "empty: exit 0" "0" "$RC"
check "empty: prints nothing" "" "$OUT"
check "empty: no edit" "no" "$(contains "$(cat "$STUB/calls")" "issue edit")"
issue 7 2026-01-01 bug
run claim
check "no agent-ready issue: prints nothing" "" "$OUT"
check "no agent-ready issue: untouched" "bug" "$(labels_of 7)"

echo "== 2. oldest first =="
reset_stub
issue 5 2026-01-03 agent-ready
issue 3 2026-01-02 agent-ready
issue 9 2026-01-01 agent-ready
run claim
check "oldest: exit 0" "0" "$RC"
check "oldest: prints the oldest (by creation date)" "9" "$OUT"
check "oldest: claimed with agent-wip" "yes" "$(has 9 agent-wip)"
check "oldest: newer issue untouched" "no" "$(has 5 agent-wip)"
check "oldest: newer issue untouched (2)" "no" "$(has 3 agent-wip)"
calls=$(cat "$STUB/calls")
check "gh ran in the --repo directory" "yes" "$(contains "$calls" "$R|")"
check "gh listed open issues" "yes" "$(contains "$calls" "--state open")"

echo "== 3. skip filters =="
reset_stub
issue 1 2026-01-01 agent-ready agent-wip
issue 2 2026-01-02 agent-ready needs-human
issue 3 2026-01-03 agent-ready epic
issue 4 2026-01-04 enhancement
issue 5 2026-01-05 agent-ready agent-failed agent-wip
issue 6 2026-01-06 agent-ready agent-failed
issue 8 2026-01-08 agent-ready
run claim
check "filters: claims the first claimable one" "6" "$OUT"
check "filters: agent-wip issue keeps its single claim" "agent-ready agent-wip" "$(labels_of 1)"
check "filters: needs-human issue not claimed" "no" "$(has 2 agent-wip)"
check "filters: epic not claimed" "no" "$(has 3 agent-wip)"
check "filters: issue without agent-ready not claimed" "no" "$(has 4 agent-wip)"
check "filters: an agent-failed issue IS claimable (retry)" "yes" "$(has 6 agent-wip)"
check "filters: newer issue untouched" "no" "$(has 8 agent-wip)"

reset_stub
issue 1 2026-01-01 agent-ready epic
issue 2 2026-01-02 agent-ready epic needs-human
run claim
check "only epics: nothing claimed" "" "$OUT"
check "only epics: exit 0" "0" "$RC"

reset_stub
issue 1 2026-01-01 agent-ready
echo CLOSED > "$STUB/issues/1/state"
run claim
check "closed issue: nothing claimed" "" "$OUT"

echo "== 4. lost race before the claim =="
reset_stub
issue 3 2026-01-01 agent-ready
issue 4 2026-01-02 agent-ready
# Another runner claims #3 between our list and our edit.
hook after-list "echo agent-wip >> \"\$STUB/issues/3/labels\""
run claim
check "race before: exit 0" "0" "$RC"
check "race before: claims the next issue" "4" "$OUT"
check "race before: the other runner keeps its claim on #3" "yes" "$(has 3 agent-wip)"
check "race before: #4 claimed" "yes" "$(has 4 agent-wip)"

echo "== 5. lost race after the claim =="
reset_stub
issue 3 2026-01-01 agent-ready
issue 4 2026-01-02 agent-ready
# While we add agent-wip, #3 is escalated by someone else.
hook after-claim-3 "echo needs-human >> \"\$STUB/issues/3/labels\""
run claim
check "race after: claims the next issue" "4" "$OUT"
check "race after: #3 released again" "no" "$(has 3 agent-wip)"
check "race after: #3 keeps needs-human" "yes" "$(has 3 needs-human)"
check "race after: #4 claimed" "yes" "$(has 4 agent-wip)"

reset_stub
issue 3 2026-01-01 agent-ready
hook after-claim-3 "echo epic >> \"\$STUB/issues/3/labels\""
run claim
check "every candidate lost: prints nothing" "" "$OUT"
check "every candidate lost: exit 0" "0" "$RC"
check "every candidate lost: no claim left behind" "no" "$(has 3 agent-wip)"

echo "== 6. gh fails during claim =="
reset_stub
issue 3 2026-01-01 agent-ready
touch "$STUB/fail-list"
run claim
check "list fails: exit 1" "1" "$RC"
check "list fails: nothing on stdout" "" "$OUT"
check "list fails: gh's error on stderr" "yes" "$(contains "$ERR" "network down")"

reset_stub
issue 3 2026-01-01 agent-ready
touch "$STUB/fail-edit"
run claim
check "edit fails: exit 1" "1" "$RC"
check "edit fails: nothing on stdout" "" "$OUT"

echo "== 7. release pr =="
reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run release 3 pr https://github.com/o/r/pull/77
check "pr: exit 0" "0" "$RC"
check "pr: agent-wip and agent-ready swapped for agent-pr" "agent-pr" "$(labels_of 3)"
check "pr: comment links the PR" "yes" "$(contains "$(comments_of 3)" "https://github.com/o/r/pull/77")"
check "pr without --tokens: comment says tokens: unknown" "yes" "$(contains "$(comments_of 3)" "tokens: unknown")"
check "pr without --tokens: log header written" "$TSV_HEADER" "$(head -1 "$QUEUE_RUNS_LOG" 2>/dev/null)"
check "pr without --tokens: one row, unknown totals" \
    $'3\tpr\thttps://github.com/o/r/pull/77\tunknown\tunknown\tunknown\tunknown\tunknown\tsess-1' "$(log_rows)"
check "log row starts with an ISO date" "yes" \
    "$(tail -1 "$QUEUE_RUNS_LOG" | cut -f1 | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' && echo yes || echo no)"

reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run --tokens "$TOK" release 3 pr https://github.com/o/r/pull/77
check "pr with --tokens: exit 0" "0" "$RC"
check "pr with --tokens: comment carries the totals" "yes" "$(contains "$(comments_of 3)" "$TOK_LINE")"
check "pr with --tokens: no 'unknown' in the comment" "no" "$(contains "$(comments_of 3)" "tokens: unknown")"
check "pr with --tokens: one row with the totals" \
    $'3\tpr\thttps://github.com/o/r/pull/77\t42\t94872\t1470008\t14878\t3\tsess-1' "$(log_rows)"
issue 4 2026-01-02 agent-ready agent-wip
run --tokens "$TOK" release 4 pr https://github.com/o/r/pull/78
check "second release: header only once, one row per release" "3" "$(log_lines)"
check "second release: header is still the first line" "1" "$(grep -c "^date" "$QUEUE_RUNS_LOG")"
run claim
check "pr: no later iteration claims it (would open a second PR)" "" "$OUT"

echo "== 7b. release pr with a message: needs-human, PR kept =="
reset_stub
issue 3 2026-01-01 agent-ready agent-wip
NOTE="$T/review-error.md"
printf 'review not posted (files: no token for o/r)\n' > "$NOTE"
run --tokens "$TOK" --review error release 3 pr https://github.com/o/r/pull/77 "$NOTE"
check "pr+message: exit 0" "0" "$RC"
check "pr+message: agent-pr and needs-human, agent-wip dropped" "agent-pr needs-human" "$(labels_of 3)"
check "pr+message: one queue-runner comment" "1" "$(grep -c '^<!-- queue-runner -->$' "$STUB/comments/3" 2>/dev/null || echo 0)"
check "pr+message: comment links the PR" "yes" "$(contains "$(comments_of 3)" "https://github.com/o/r/pull/77")"
check "pr+message: comment holds the message" "yes" "$(contains "$(comments_of 3)" "no token for o/r")"
check "pr+message: comment names needs-human" "yes" "$(contains "$(comments_of 3)" "needs-human")"
check "pr+message: comment carries the totals" "yes" "$(contains "$(comments_of 3)" "$TOK_LINE")"
check "pr+message: logged as pr with its PR" \
    $'3\tpr\thttps://github.com/o/r/pull/77\t42\t94872\t1470008\t14878\t3\tsess-1' "$(log_rows)"
check "pr+message: review column says error" "error" "$(review_rows | cut -f1)"
run claim
check "pr+message: not claimed again" "" "$OUT"

reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run release 3 pr https://github.com/o/r/pull/77 "$T/no-such-file.md"
check "pr+missing message file: exit 2" "2" "$RC"
check "pr+missing message file: labels untouched" "agent-ready agent-wip" "$(labels_of 3)"
check "pr+missing message file: no gh call" "no" "$([[ -e "$STUB/calls" ]] && echo yes || echo no)"
run release 3 pr https://github.com/o/r/pull/77 "$NOTE" extra
check "pr with two extra arguments: exit 2" "2" "$RC"
run release 3 pr https://github.com/o/r/pull/77
check "pr without a message: no needs-human" "no" "$(has 3 needs-human)"

reset_stub
# A human puts agent-ready back (PR closed unmerged) but leaves agent-pr.
issue 3 2026-01-01 agent-ready agent-pr
issue 4 2026-01-02 agent-ready
run claim
check "agent-pr is a skip label: claims the next issue" "4" "$OUT"
check "agent-pr is a skip label: #3 untouched" "agent-pr agent-ready" "$(labels_of 3)"

echo "== 8. release escalated =="
reset_stub
issue 3 2026-01-01 agent-ready agent-wip needs-human
run --tokens "$TOK" release 3 escalated
check "escalated: exit 0" "0" "$RC"
check "escalated: agent-wip dropped, needs-human kept" "agent-ready needs-human" "$(labels_of 3)"
check "escalated: one queue-runner comment" "1" "$(grep -c '^<!-- queue-runner -->$' "$STUB/comments/3" 2>/dev/null || echo 0)"
check "escalated: comment carries the totals" "yes" "$(contains "$(comments_of 3)" "$TOK_LINE")"
check "escalated: one row, empty PR column" \
    $'3\tescalated\t\t42\t94872\t1470008\t14878\t3\tsess-1' "$(log_rows)"
run claim
check "escalated: not claimed again" "" "$OUT"

reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run release 3 escalated
check "escalated without needs-human: exit 0" "0" "$RC"
check "escalated without needs-human: needs-human added" "agent-ready needs-human" "$(labels_of 3)"
check "escalated without needs-human: warns" "yes" "$(contains "$ERR" "needs-human")"
check "escalated without --tokens: comment says tokens: unknown" "yes" "$(contains "$(comments_of 3)" "tokens: unknown")"

echo "== 9. release failed: first failure =="
reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run release 3 failed "$MSG"
check "first failure: exit 0" "0" "$RC"
check "first failure: agent-failed added, agent-wip dropped" "agent-failed agent-ready" "$(labels_of 3)"
check "first failure: no needs-human" "no" "$(has 3 needs-human)"
check "first failure: comment holds the error" "yes" "$(contains "$(comments_of 3)" "CI red on test-foo.sh")"
check "first failure: comment holds what was tried" "yes" "$(contains "$(comments_of 3)" "Tried: two fixes")"
check "first failure without --tokens: tokens: unknown" "yes" "$(contains "$(comments_of 3)" "tokens: unknown")"
check "first failure: one row" $'3\tfailed\t\tunknown\tunknown\tunknown\tunknown\tunknown\tsess-1' "$(log_rows)"
run claim
check "first failure: the next iteration claims it again" "3" "$OUT"

echo "== 10. release failed: second failure =="
run --tokens "$TOK" release 3 failed "$MSG"
check "second failure: exit 0" "0" "$RC"
check "failed with --tokens: comment carries the totals" "yes" "$(contains "$(tail -n +4 "$STUB/comments/3")" "$TOK_LINE")"
check "failed: two releases, two rows under one header" "3" "$(log_lines)"
check "second failure: agent-failed and needs-human, no agent-wip" "agent-failed agent-ready needs-human" "$(labels_of 3)"
check "second failure: two error comments" "2" "$(grep -c '^----$' "$STUB/comments/3")"
run claim
check "second failure: no later iteration claims it" "" "$OUT"

echo "== 11. release: gh fails =="
reset_stub
issue 3 2026-01-01 agent-ready agent-wip
touch "$STUB/fail-edit"
run release 3 pr https://github.com/o/r/pull/77
check "release, edit fails: exit 1" "1" "$RC"
check "release, edit fails: no log row" "no" "$([[ -e "$QUEUE_RUNS_LOG" ]] && echo yes || echo no)"
reset_stub
issue 3 2026-01-01 agent-ready agent-wip
touch "$STUB/fail-view"
run release 3 failed "$MSG"
check "release failed, view fails: exit 1" "1" "$RC"
check "release failed, view fails: claim kept" "yes" "$(has 3 agent-wip)"

echo "== 11b. session column =="
reset_stub
issue 3 2026-01-01 agent-ready agent-wip
OUT=$(env -u CLAUDE_CODE_SESSION_ID bash "$QC" --repo "$R" release 3 escalated 2>/dev/null); RC=$?
check "no session id: release still exits 0" "0" "$RC"
check "no session id: empty session column" $'3\tescalated\t\tunknown\tunknown\tunknown\tunknown\tunknown\t' "$(log_rows)"

reset_stub
# A log written before #251: nine columns, no session.
printf 'date\tissue\toutcome\tpr_url\tinput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\toutput_tokens\tagents\n2026-01-01T00:00:00Z\t1\tpr\thttps://github.com/o/r/pull/1\t1\t2\t3\t4\t1\n' > "$QUEUE_RUNS_LOG"
issue 3 2026-01-01 agent-ready agent-wip
run release 3 escalated
check "old log: release exits 0" "0" "$RC"
check "old log: old row untouched" $'2026-01-01T00:00:00Z\t1\tpr\thttps://github.com/o/r/pull/1\t1\t2\t3\t4\t1' "$(sed -n 2p "$QUEUE_RUNS_LOG")"
check "old log: new row carries the session" "sess-1" "$(tail -1 "$QUEUE_RUNS_LOG" | cut -f10)"
check "old log: header gains the session and review columns" "$TSV_HEADER" "$(head -1 "$QUEUE_RUNS_LOG")"

echo "== 11c. review and fix columns (#297) =="
REVTOK="$T/review-tokens.json"
cat > "$REVTOK" <<'EOF'
{"agent_id": "r1", "totals": {"input_tokens": 10, "cache_creation_input_tokens": 20, "cache_read_input_tokens": 30, "output_tokens": 40}, "agents": 2, "models": ["claude-opus-5-5"], "summary": "review summary"}
EOF
FIXTOK="$T/fix-tokens.json"
cat > "$FIXTOK" <<'EOF'
{"agent_id": "f1", "totals": {"input_tokens": 5, "cache_creation_input_tokens": 6, "cache_read_input_tokens": 7, "output_tokens": 8}, "agents": 1, "models": ["claude-opus-5-5"], "summary": "fix summary"}
EOF

reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run release 3 pr https://github.com/o/r/pull/77
check "no review options: header has the review columns" "$TSV_HEADER" "$(head -1 "$QUEUE_RUNS_LOG")"
check "no review options: header and row have the same field count" \
    "$(head -1 "$QUEUE_RUNS_LOG" | awk -F'\t' '{print NF}')" "$(tail -1 "$QUEUE_RUNS_LOG" | awk -F'\t' '{print NF}')"
check "no review options: review columns empty" "$NO_REVIEW" "$(review_rows)"

reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run --tokens "$TOK" --review BLOCKING --review-final APPROVE --review-findings 4 \
    --review-tokens "$REVTOK" --fix-tokens "$FIXTOK" release 3 pr https://github.com/o/r/pull/77
check "all review options: exit 0" "0" "$RC"
check "all review options: base columns unchanged" \
    $'3\tpr\thttps://github.com/o/r/pull/77\t42\t94872\t1470008\t14878\t3\tsess-1' "$(log_rows)"
check "all review options: review columns filled" \
    $'BLOCKING\tAPPROVE\t4\t10\t20\t30\t40\t2\t5\t6\t7\t8\t1' "$(review_rows)"
check "all review options: comment keeps the whole-issue token line" "yes" "$(contains "$(comments_of 3)" "$TOK_LINE")"
check "review summary not in the comment" "no" "$(contains "$(comments_of 3)" "review summary")"

reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run --review=APPROVE --review-findings=0 --review-tokens="$REVTOK" release 3 pr https://github.com/o/r/pull/77
check "--opt=value forms, no fix round: exit 0" "0" "$RC"
check "no fix round: review_final and fix columns empty" \
    $'APPROVE\t\t0\t10\t20\t30\t40\t2\t\t\t\t\t' "$(review_rows)"

reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run --review error release 3 pr https://github.com/o/r/pull/77
check "verdict error: exit 0" "0" "$RC"
check "verdict error: logged" "error" "$(tail -1 "$QUEUE_RUNS_LOG" | cut -f11)"
run --review HUMAN release 3 escalated
check "verdict HUMAN: logged" "HUMAN" "$(tail -1 "$QUEUE_RUNS_LOG" | cut -f11)"

reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run --review BLOCKING --review-final BLOCKING --review-findings 2 \
    --review-tokens "$T/nope.json" --fix-tokens "$FIXTOK" release 3 pr https://github.com/o/r/pull/77
check "missing review tokens file: release still exits 0" "0" "$RC"
check "missing review tokens file: warns" "yes" "$(contains "$ERR" "review tokens unknown")"
check "missing review tokens file: labels still updated" "agent-pr" "$(labels_of 3)"
check "missing review tokens file: only the review_ token columns empty" \
    $'BLOCKING\tBLOCKING\t2\t\t\t\t\t\t5\t6\t7\t8\t1' "$(review_rows)"

reset_stub
issue 3 2026-01-01 agent-ready agent-wip
printf '{"totals": ' > "$T/bad-fix.json"
run --review BLOCKING --review-final HUMAN --review-findings 1 \
    --review-tokens "$REVTOK" --fix-tokens "$T/bad-fix.json" release 3 escalated
check "malformed fix tokens file: release still exits 0" "0" "$RC"
check "malformed fix tokens file: warns" "yes" "$(contains "$ERR" "fix tokens unknown")"
check "malformed fix tokens file: only the fix_ columns empty" \
    $'BLOCKING\tHUMAN\t1\t10\t20\t30\t40\t2\t\t\t\t\t' "$(review_rows)"

reset_stub
# A log written with the #251 header: ten columns, session last.
chmod_log_mode=600
printf '%s\n2026-01-01T00:00:00Z\t1\tpr\thttps://github.com/o/r/pull/1\t1\t2\t3\t4\t1\tsess-old\n' "$TSV_HEADER_V2" > "$QUEUE_RUNS_LOG"
chmod "$chmod_log_mode" "$QUEUE_RUNS_LOG"
issue 3 2026-01-01 agent-ready agent-wip
run --review APPROVE --review-findings 0 release 3 pr https://github.com/o/r/pull/77
check "#251 log: release exits 0" "0" "$RC"
check "#251 log: header gains the review columns" "$TSV_HEADER" "$(head -1 "$QUEUE_RUNS_LOG")"
check "#251 log: header line only once" "1" "$(grep -c "^date" "$QUEUE_RUNS_LOG")"
check "#251 log: old row untouched (ten fields)" \
    $'2026-01-01T00:00:00Z\t1\tpr\thttps://github.com/o/r/pull/1\t1\t2\t3\t4\t1\tsess-old' "$(sed -n 2p "$QUEUE_RUNS_LOG")"
check "#251 log: file mode kept" "$chmod_log_mode" "$(stat -c %a "$QUEUE_RUNS_LOG")"
check "#251 log: new row carries the verdict" "APPROVE" "$(tail -1 "$QUEUE_RUNS_LOG" | cut -f11)"
check "#251 log: three lines" "3" "$(log_lines)"

reset_stub
# An unknown header is left alone; the row is still appended.
printf 'something\telse\n' > "$QUEUE_RUNS_LOG"
issue 3 2026-01-01 agent-ready agent-wip
run release 3 escalated
check "unknown header: left alone" $'something\telse' "$(head -1 "$QUEUE_RUNS_LOG")"

echo "== 11d. claim --rework (#300) =="
reset_stub
issue 1 2026-01-01 agent-rework agent-pr agent-wip
issue 2 2026-01-02 agent-rework agent-pr needs-human
issue 3 2026-01-03 agent-rework epic
issue 4 2025-12-01 agent-ready
issue 5 2026-01-05 agent-rework agent-pr
issue 6 2026-01-04 agent-rework agent-pr agent-failed
issue 8 2026-01-08 agent-rework agent-pr
run claim --rework
check "rework: exit 0" "0" "$RC"
check "rework: oldest claimable agent-rework issue (agent-failed is a retry)" "6" "$OUT"
check "rework: claimed with agent-wip" "agent-failed agent-pr agent-rework agent-wip" "$(labels_of 6)"
check "rework: agent-wip issue keeps its single claim" "agent-pr agent-rework agent-wip" "$(labels_of 1)"
check "rework: needs-human issue not claimed" "no" "$(has 2 agent-wip)"
check "rework: epic not claimed" "no" "$(has 3 agent-wip)"
check "rework: an older agent-ready issue is not taken" "no" "$(has 4 agent-wip)"
check "rework: newer rework issue untouched" "no" "$(has 5 agent-wip)"
check "rework: listed the agent-rework label" "yes" "$(contains "$(cat "$STUB/calls")" "--label agent-rework")"
run claim --rework
check "rework: next call takes the next one" "5" "$OUT"

reset_stub
issue 4 2026-01-01 agent-ready
run claim --rework
check "rework, none waiting: prints nothing" "" "$OUT"
check "rework, none waiting: exit 0" "0" "$RC"
check "rework, none waiting: agent-ready issue untouched" "agent-ready" "$(labels_of 4)"

reset_stub
issue 3 2026-01-01 agent-rework agent-pr
issue 4 2026-01-02 agent-rework agent-pr
hook after-list "echo agent-wip >> \"\$STUB/issues/3/labels\""
run claim --rework
check "rework, race before: claims the next issue" "4" "$OUT"

reset_stub
issue 3 2026-01-01 agent-rework agent-pr
issue 4 2026-01-02 agent-rework agent-pr
hook after-claim-3 "echo needs-human >> \"\$STUB/issues/3/labels\""
run claim --rework
check "rework, race after: claims the next issue" "4" "$OUT"
check "rework, race after: #3 released again" "no" "$(has 3 agent-wip)"

reset_stub
issue 3 2026-01-01 agent-rework agent-pr
hook after-claim-3 "grep -vxF agent-rework \"\$STUB/issues/3/labels\" > \"\$STUB/l\"; mv \"\$STUB/l\" \"\$STUB/issues/3/labels\""
run claim --rework
check "rework, label removed while claiming: nothing claimed" "" "$OUT"
check "rework, label removed while claiming: no claim left" "no" "$(has 3 agent-wip)"

echo "== 11e. plain claim never takes agent-rework =="
reset_stub
issue 1 2026-01-01 agent-ready agent-rework
issue 2 2026-01-02 agent-rework agent-pr
issue 3 2026-01-03 agent-ready
run claim
check "plain claim skips an agent-rework issue" "3" "$OUT"
check "plain claim: agent-rework issue untouched" "no" "$(has 1 agent-wip)"
reset_stub
issue 2 2026-01-02 agent-rework agent-pr
run claim
check "plain claim with only rework waiting: prints nothing" "" "$OUT"

echo "== 11f. release rework =="
reset_stub
issue 3 2026-01-01 agent-pr agent-rework agent-wip
run --tokens "$TOK" --review-final APPROVE --fix-tokens "$FIXTOK" --review-tokens "$REVTOK" \
    release 3 rework https://github.com/o/r/pull/77
check "rework: exit 0" "0" "$RC"
check "rework: agent-rework and agent-wip swapped for agent-pr" "agent-pr" "$(labels_of 3)"
check "rework: one queue-runner comment" "1" "$(grep -c '^<!-- queue-runner -->$' "$STUB/comments/3" 2>/dev/null || echo 0)"
check "rework: comment links the PR" "yes" "$(contains "$(comments_of 3)" "https://github.com/o/r/pull/77")"
check "rework: comment carries the totals" "yes" "$(contains "$(comments_of 3)" "$TOK_LINE")"
check "rework: comment has no needs-human" "no" "$(contains "$(comments_of 3)" "needs-human")"
check "rework: row has outcome rework and its PR" \
    $'3\trework\thttps://github.com/o/r/pull/77\t42\t94872\t1470008\t14878\t3\tsess-1' "$(log_rows)"
check "rework: review columns filled" \
    $'\tAPPROVE\t\t10\t20\t30\t40\t2\t5\t6\t7\t8\t1' "$(review_rows)"
run claim --rework
check "rework released: not claimed again" "" "$OUT"
run claim
check "rework released: plain claim does not take it either" "" "$OUT"
check "rework release counts in queue-budget.sh gate" "budget 1/2" \
    "$(bash "$SCRIPT_DIR/../queue-budget.sh" gate 2 2>/dev/null)"
bash "$SCRIPT_DIR/../queue-budget.sh" gate 1 >/dev/null 2>&1
check "rework release uses up a budget of 1" "1" "$?"

reset_stub
issue 3 2026-01-01 agent-rework agent-wip
run release 3 rework https://github.com/o/r/pull/77
check "rework without agent-pr on the issue: agent-pr added" "agent-pr" "$(labels_of 3)"

reset_stub
issue 3 2026-01-01 agent-pr agent-rework agent-wip
NOTE="$T/rework-note.md"
printf 'Re-review stayed BLOCKING: https://github.com/o/r/pull/77#pullrequestreview-9\n' > "$NOTE"
run --review-final BLOCKING release 3 rework https://github.com/o/r/pull/77 "$NOTE"
check "rework+note: exit 0" "0" "$RC"
check "rework+note: agent-pr and needs-human, no agent-rework" "agent-pr needs-human" "$(labels_of 3)"
check "rework+note: comment holds the note" "yes" "$(contains "$(comments_of 3)" "pullrequestreview-9")"
check "rework+note: comment names needs-human" "yes" "$(contains "$(comments_of 3)" "needs-human")"
check "rework+note: outcome rework" "rework" "$(tail -1 "$QUEUE_RUNS_LOG" | cut -f3)"
run claim --rework
check "rework+note: not claimed again" "" "$OUT"

echo "== 11g. failed and escalated rework keep agent-rework =="
reset_stub
issue 3 2026-01-01 agent-pr agent-rework agent-wip
run release 3 failed "$MSG"
check "rework failed once: agent-rework kept, agent-failed added" "agent-failed agent-pr agent-rework" "$(labels_of 3)"
check "rework failed once: logged as failed" "failed" "$(tail -1 "$QUEUE_RUNS_LOG" | cut -f3)"
run claim --rework
check "rework failed once: claimed again for its retry" "3" "$OUT"
run release 3 failed "$MSG"
check "rework failed twice: agent-rework kept, needs-human added" \
    "agent-failed agent-pr agent-rework needs-human" "$(labels_of 3)"
run claim --rework
check "rework failed twice: not claimed again" "" "$OUT"

reset_stub
issue 3 2026-01-01 agent-pr agent-rework agent-wip
run release 3 escalated
check "rework escalated: agent-rework kept, needs-human added" "agent-pr agent-rework needs-human" "$(labels_of 3)"
check "rework escalated: logged as escalated" "escalated" "$(tail -1 "$QUEUE_RUNS_LOG" | cut -f3)"
run claim --rework
check "rework escalated: not claimed until the human removes needs-human" "" "$OUT"
grep -vxF needs-human "$STUB/issues/3/labels" > "$T/l"; mv "$T/l" "$STUB/issues/3/labels"
run claim --rework
check "rework escalated, needs-human removed (D3 route): claimed again" "3" "$OUT"

echo "== 12. release: exit 0 and no temp file left, every outcome =="
# The comment body is a mktemp file; its EXIT trap must still find it once
# do_release's locals are gone (set -u turned that into a non-zero exit).
export TMPDIR="$T/tmpdir"
for outcome in pr rework escalated failed; do
    reset_stub
    rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    issue 3 2026-01-01 agent-ready agent-wip
    case "$outcome" in
        pr)        run release 3 pr https://github.com/o/r/pull/77 ;;
        rework)    run release 3 rework https://github.com/o/r/pull/77 ;;
        escalated) run release 3 escalated ;;
        failed)    run release 3 failed "$MSG" ;;
    esac
    check "$outcome: exit 0" "0" "$RC"
    check "$outcome: no 'unbound variable' on stderr" "no" "$(contains "$ERR" "unbound variable")"
    check "$outcome: no temp file left" "" "$(ls -A "$TMPDIR")"
done
unset TMPDIR

echo "== 13. usage errors =="
reset_stub
issue 3 2026-01-01 agent-ready agent-wip
run
check "no command: exit 2" "2" "$RC"
run bogus
check "unknown command: exit 2" "2" "$RC"
run release
check "release without issue: exit 2" "2" "$RC"
run release abc escalated
check "release with non-numeric issue: exit 2" "2" "$RC"
run release 3
check "release without outcome: exit 2" "2" "$RC"
run release 3 merged
check "unknown outcome: exit 2" "2" "$RC"
run release 3 pr
check "pr without url: exit 2" "2" "$RC"
run release 3 failed
check "failed without message file: exit 2" "2" "$RC"
run release 3 failed "$T/nope.md"
check "failed with missing message file: exit 2" "2" "$RC"
run claim extra
check "claim with extra argument: exit 2" "2" "$RC"
run --tokens "$TOK" claim
check "--tokens with claim: exit 2" "2" "$RC"
run --tokens "$T/nope.json" release 3 escalated
check "--tokens with a missing file: exit 2" "2" "$RC"
printf '{"totals": ' > "$T/bad.json"
run --tokens "$T/bad.json" release 3 escalated
check "--tokens with malformed JSON: exit 2" "2" "$RC"
run --tokens
check "--tokens without a value: exit 2" "2" "$RC"
run --review approve release 3 escalated
check "--review with an unknown verdict: exit 2" "2" "$RC"
run --review-final MAYBE release 3 escalated
check "--review-final with an unknown verdict: exit 2" "2" "$RC"
run --review-findings two release 3 escalated
check "--review-findings not a count: exit 2" "2" "$RC"
run --review APPROVE claim
check "--review with claim: exit 2" "2" "$RC"
run --fix-tokens "$TOK" claim
check "--fix-tokens with claim: exit 2" "2" "$RC"
run --review-tokens
check "--review-tokens without a value: exit 2" "2" "$RC"
run claim --rework extra
check "claim --rework with an extra argument: exit 2" "2" "$RC"
run claim --bogus
check "claim with an unknown flag: exit 2" "2" "$RC"
run --tokens "$TOK" claim --rework
check "--tokens with claim --rework: exit 2" "2" "$RC"
run release 3 rework
check "rework without url: exit 2" "2" "$RC"
run release 3 rework https://github.com/o/r/pull/77 "$T/nope.md"
check "rework with missing message file: exit 2" "2" "$RC"
run release 3 rework https://github.com/o/r/pull/77 "$MSG" extra
check "rework with two extra arguments: exit 2" "2" "$RC"
check "usage errors posted no comment" "" "$(comments_of 3)"
check "usage errors wrote no log row" "no" "$([[ -e "$QUEUE_RUNS_LOG" ]] && echo yes || echo no)"
check "usage errors changed nothing" "agent-ready agent-wip" "$(labels_of 3)"
OUT=$(bash "$QC" --repo "$T/nowhere" claim 2>/dev/null); RC=$?
check "missing repo: exit 2" "2" "$RC"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
