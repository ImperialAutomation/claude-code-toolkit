#!/bin/bash
# Tests for http-status.sh.
#
# Usage:
#   bin/tests/test-http-status.sh
#
# Runs against a real HTTP server on an ephemeral localhost port — the thing
# under test is the curl invocation and its output shape, so mocking curl would
# test nothing. Transport failure is exercised against a port with nothing
# listening on it, which is what "connection refused" looks like in practice.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../http-status.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

T=$(mktemp -d)
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

# --- a real server, serving a real document tree -----------------------------
# /health -> 200 with a body, /missing -> 404. Nothing is mocked.
mkdir -p "$T/www"
printf '{"status": "ok", "service": "billing-api"}\n' > "$T/www/health"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
DEAD_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$T"' EXIT

BASE="http://127.0.0.1:$PORT"
DEAD="http://127.0.0.1:$DEAD_PORT/health"

# Wait for the server to accept connections before asserting anything.
for _ in $(seq 1 50); do
    curl -s -o /dev/null "$BASE/health" && break
    sleep 0.1
done

run() { bash "$SCRIPT" "$@"; }

echo "== 1. single URL prints only the status code =="
check "bare status" "200" "$(run "$BASE/health")"
check "exit 0 on 200" "0" "$(run "$BASE/health" >/dev/null 2>&1; echo $?)"

echo "== 2. several URLs print status and URL, in argument order =="
OUT=$(run "$BASE/health" "$BASE/missing")
check "first line"  "200  $BASE/health"   "$(sed -n 1p <<<"$OUT")"
check "second line" "404  $BASE/missing"  "$(sed -n 2p <<<"$OUT")"
check "line count"  "2"                   "$(wc -l <<<"$OUT" | tr -d ' ')"
# Argument order, not response order: a slower first URL must still print first.
OUT=$(run "$BASE/missing" "$BASE/health")
check "order follows args" "404  $BASE/missing" "$(sed -n 1p <<<"$OUT")"
check "a 4xx is not an error" "0" "$(run "$BASE/missing" >/dev/null 2>&1; echo $?)"

echo "== 3. transport failure exits non-zero but does not hide the other URLs =="
check "refused connection exits 1" "1" "$(run "$DEAD" >/dev/null 2>&1; echo $?)"
check "refused prints ERR" "ERR" "$(run "$DEAD" 2>/dev/null)"
# A dead host first must not stop the live one behind it from being reported —
# otherwise one broken service makes the whole smoke test unreadable.
OUT=$(run "$DEAD" "$BASE/health" 2>/dev/null)
check "dead URL marked"   "ERR  $DEAD"        "$(sed -n 1p <<<"$OUT")"
check "live URL reported" "200  $BASE/health" "$(sed -n 2p <<<"$OUT")"
check "mixed run exits 1" "1" "$(run "$DEAD" "$BASE/health" >/dev/null 2>&1; echo $?)"
# curl's own explanation must survive to stderr — "ERR" alone does not tell you
# whether it was DNS, a refused connection or a timeout.
DIAG=$(run "$DEAD" 2>&1 >/dev/null)
check "curl diagnostic on stderr" "yes" \
    "$(case "$DIAG" in *onnect*|*efus*|*imed\ out*) echo yes ;; *) echo no ;; esac)"

echo "== 4. --body prints the response instead of the status =="
check "single body is raw" '{"status": "ok", "service": "billing-api"}' \
    "$(run --body "$BASE/health")"
check "no status code in single body" "yes" \
    "$(case "$(run --body "$BASE/health")" in *200*) echo no ;; *) echo yes ;; esac)"
# Several bodies concatenated are unattributable, so each gets a header.
OUT=$(run --body "$BASE/health" "$BASE/health")
check "body header names the URL" "==> $BASE/health <==" "$(sed -n 1p <<<"$OUT")"
check "body follows its header" '{"status": "ok", "service": "billing-api"}' \
    "$(sed -n 2p <<<"$OUT")"
check "both bodies present" "2" \
    "$(grep -c 'billing-api' <<<"$OUT")"
check "--body still exits 1 on transport failure" "1" \
    "$(run --body "$DEAD" >/dev/null 2>&1; echo $?)"

echo "== 5. argument validation =="
check "no URLs exits 2"        "2" "$(run >/dev/null 2>&1; echo $?)"
check "unknown option exits 2" "2" "$(run --nope "$BASE/health" >/dev/null 2>&1; echo $?)"
check "usage goes to stderr"   "yes" \
    "$(case "$(run 2>&1 >/dev/null)" in *usage*) echo yes ;; *) echo no ;; esac)"
check "--max-time accepted"    "200" "$(run --max-time 5 "$BASE/health")"
check "--max-time without value exits 2" "2" \
    "$(run "$BASE/health" --max-time >/dev/null 2>&1; echo $?)"
check "non-numeric --max-time exits 2" "2" \
    "$(run --max-time abc "$BASE/health" >/dev/null 2>&1; echo $?)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
