#!/bin/bash
# Tests for pypi-release-info.sh.
#
# Usage:
#   bin/tests/test-pypi-release-info.sh
#
# Runs against a real HTTP server on an ephemeral localhost port that serves a
# fixture in the shape of the PyPI JSON API (/pypi/<package>/json), reached
# through PYPI_BASE_URL. The thing under test is the fetch, the status handling
# and the jq selection, so mocking curl or jq would test nothing. An unknown
# package is a real 404 from that server; "unreachable" is a port with nothing
# listening on it.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../pypi-release-info.sh}"

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

contains() { # haystack needle -> yes/no
    case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac
}

# --- fixture in the PyPI JSON shape -------------------------------------------
# Key order in "releases" deliberately differs from upload order (1.10.0 sorts
# before 1.9.0 as a string but was uploaded after it), so "newest first" can
# only pass when the script sorts by upload time. 1.0.0 has two files whose
# later one is listed first: the earliest upload time must win. 2.0.0 is fully
# yanked, 2.1.0 has no files at all.
mkdir -p "$T/www/pypi/billing-sdk"
cat > "$T/www/pypi/billing-sdk/json" <<'EOF'
{
  "info": {"name": "billing-sdk", "version": "2.0.0", "requires_python": ">=3.10"},
  "releases": {
    "1.0.0": [
      {"packagetype": "sdist", "upload_time_iso_8601": "2024-01-10T09:05:12.000000Z", "requires_python": ">=3.8", "yanked": false},
      {"packagetype": "bdist_wheel", "upload_time_iso_8601": "2024-01-10T09:00:00.123456Z", "requires_python": ">=3.8", "yanked": false}
    ],
    "1.10.0": [
      {"packagetype": "bdist_wheel", "upload_time_iso_8601": "2024-06-01T12:00:00.000000Z", "requires_python": ">=3.9", "yanked": false}
    ],
    "1.9.0": [
      {"packagetype": "bdist_wheel", "upload_time_iso_8601": "2024-03-15T08:30:00.000000Z", "requires_python": null, "yanked": false}
    ],
    "2.0.0": [
      {"packagetype": "bdist_wheel", "upload_time_iso_8601": "2024-09-20T16:45:30.500000Z", "requires_python": ">=3.10", "yanked": true}
    ],
    "2.1.0": []
  }
}
EOF

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
DEAD_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$T"' EXIT

BASE="http://127.0.0.1:$PORT"
DEAD="http://127.0.0.1:$DEAD_PORT"

for _ in $(seq 1 50); do
    curl -s -o /dev/null "$BASE/pypi/billing-sdk/json" && break
    sleep 0.1
done

run()      { PYPI_BASE_URL="$BASE" bash "$SCRIPT" "$@"; }
run_dead() { PYPI_BASE_URL="$DEAD" bash "$SCRIPT" "$@"; }

echo "== 1. named versions: earliest upload time and requires_python =="
OUT=$(run billing-sdk 1.0.0 1.9.0)
check "earliest file wins, fraction dropped" "1.0.0  2024-01-10T09:00:00Z  >=3.8" "$(sed -n 1p <<<"$OUT")"
check "unset requires_python prints -"       "1.9.0  2024-03-15T08:30:00Z  -"    "$(sed -n 2p <<<"$OUT")"
check "argument order kept"                  "2" "$(wc -l <<<"$OUT" | tr -d ' ')"
check "exit 0" "0" "$(run billing-sdk 1.0.0 >/dev/null 2>&1; echo $?)"
check "yanked release is marked" "2.0.0  2024-09-20T16:45:30Z  >=3.10  yanked" "$(run billing-sdk 2.0.0)"

echo "== 2. unknown version is reported, the rest still printed, exit 0 =="
OUT=$(run billing-sdk 9.9.9 1.10.0)
check "unknown version line" "9.9.9  not found" "$(sed -n 1p <<<"$OUT")"
check "next version still printed" "1.10.0  2024-06-01T12:00:00Z  >=3.9" "$(sed -n 2p <<<"$OUT")"
check "exit 0 with an unknown version" "0" "$(run billing-sdk 9.9.9 1.10.0 >/dev/null 2>&1; echo $?)"
check "release without files counts as not found" "2.1.0  not found" "$(run billing-sdk 2.1.0)"

echo "== 3. no versions: latest releases, newest first =="
OUT=$(run billing-sdk)
check "newest first" "2.0.0  2024-09-20T16:45:30Z  >=3.10  yanked" "$(sed -n 1p <<<"$OUT")"
check "sorted by upload time, not by key" "1.10.0  2024-06-01T12:00:00Z  >=3.9" "$(sed -n 2p <<<"$OUT")"
check "then 1.9.0" "1.9.0  2024-03-15T08:30:00Z  -" "$(sed -n 3p <<<"$OUT")"
check "release without files skipped" "4" "$(wc -l <<<"$OUT" | tr -d ' ')"
OUT=$(run --limit 2 billing-sdk)
check "--limit caps the list" "2" "$(wc -l <<<"$OUT" | tr -d ' ')"
check "--limit keeps the newest" "2.0.0" "$(sed -n 1p <<<"$OUT" | cut -d' ' -f1)"
check "--limit after the package works too" "1" "$(run billing-sdk --limit 1 | wc -l | tr -d ' ')"

echo "== 4. unknown package and unreachable PyPI exit 1 =="
check "unknown package exits 1" "1" "$(run no-such-package >/dev/null 2>&1; echo $?)"
ERR=$(run no-such-package 2>&1 >/dev/null)
check "unknown package message names it" "yes" "$(contains "$ERR" "no-such-package")"
check "unknown package prints nothing on stdout" "" "$(run no-such-package 2>/dev/null)"
check "unreachable exits 1" "1" "$(run_dead billing-sdk >/dev/null 2>&1; echo $?)"
ERR=$(run_dead billing-sdk 2>&1 >/dev/null)
check "unreachable message says so" "yes" "$(contains "$ERR" "unreachable")"

echo "== 5. argument validation =="
check "no package exits 2"        "2" "$(run >/dev/null 2>&1; echo $?)"
check "usage goes to stderr"      "yes" "$(contains "$(run 2>&1 >/dev/null)" "usage")"
check "unknown option exits 2"    "2" "$(run --nope billing-sdk >/dev/null 2>&1; echo $?)"
check "--limit without value exits 2" "2" "$(run billing-sdk --limit >/dev/null 2>&1; echo $?)"
check "non-numeric --limit exits 2"   "2" "$(run --limit abc billing-sdk >/dev/null 2>&1; echo $?)"
check "zero --limit exits 2"          "2" "$(run --limit 0 billing-sdk >/dev/null 2>&1; echo $?)"
check "package name with a slash exits 2" "2" "$(run '../etc' >/dev/null 2>&1; echo $?)"
check "--help exits 0" "0" "$(run --help >/dev/null 2>&1; echo $?)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
