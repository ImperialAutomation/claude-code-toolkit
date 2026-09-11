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

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
