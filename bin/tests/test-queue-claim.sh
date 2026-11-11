#!/bin/bash
# Tests for queue-claim.sh.
#
# Usage:
#   bin/tests/test-queue-claim.sh
#
# Only `gh` is a stub, put first on PATH. It keeps a tiny issue tracker in
# $STUB/issues/<N>/: `labels` (one per line), `created` (ISO date) and `state`
# (OPEN when absent). It answers the four calls queue-claim.sh makes:
#   gh issue list ... --label agent-ready ... --json ...   open agent-ready
#       issues as JSON, NEWEST first on purpose (the script must sort);
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
        case " $* " in *" --label agent-ready "*) ;; *) echo "list without --label agent-ready" >&2; exit 1 ;; esac
        out='[]'
        # newest first, like gh's default order
        for d in $(ls "$I" 2>/dev/null); do
            [[ "$(state_of "$d")" == "OPEN" ]] && has_label "$d" agent-ready || continue
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
TSV_HEADER=$'date\tissue\toutcome\tpr_url\tinput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\toutput_tokens\tagents\tsession'
log_rows() { tail -n +2 "$QUEUE_RUNS_LOG" 2>/dev/null | cut -f2-; }
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
check "--help names --tokens" "yes" "$(contains "$OUT" "--tokens")"
check "--help names QUEUE_RUNS_LOG" "yes" "$(contains "$OUT" "QUEUE_RUNS_LOG")"
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
check "old log: header gains the session column" "$TSV_HEADER" "$(head -1 "$QUEUE_RUNS_LOG")"

echo "== 12. release: exit 0 and no temp file left, every outcome =="
# The comment body is a mktemp file; its EXIT trap must still find it once
# do_release's locals are gone (set -u turned that into a non-zero exit).
export TMPDIR="$T/tmpdir"
for outcome in pr escalated failed; do
    reset_stub
    rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    issue 3 2026-01-01 agent-ready agent-wip
    case "$outcome" in
        pr)        run release 3 pr https://github.com/o/r/pull/77 ;;
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
check "usage errors posted no comment" "" "$(comments_of 3)"
check "usage errors wrote no log row" "no" "$([[ -e "$QUEUE_RUNS_LOG" ]] && echo yes || echo no)"
check "usage errors changed nothing" "agent-ready agent-wip" "$(labels_of 3)"
OUT=$(bash "$QC" --repo "$T/nowhere" claim 2>/dev/null); RC=$?
check "missing repo: exit 2" "2" "$RC"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
