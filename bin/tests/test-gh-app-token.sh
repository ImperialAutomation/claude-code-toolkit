#!/bin/bash
# Tests for gh-app-token.sh.
#
# Usage:
#   bin/tests/test-gh-app-token.sh
#
# curl is a stub on PATH that answers the two GitHub API calls from fixtures
# and records each request: method and URL, the headers it was handed, and the
# request body. openssl is the real one, with throwaway RSA keys generated
# here: the signature is the thing a stub could not check, so the test verifies
# the JWT with the matching public key. HOME points at a temp dir, so the
# credentials are read from $T/.config/github-apps/<owner>/review/.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../gh-app-token.sh}"

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

contains() { # haystack needle -> yes/no
    case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac
}

# Not in the ghs_ shape: gitleaks would take it for a real token.
TOKEN="stub-installation-token-for-billing-api"
INSTALLATION_ID=4242

# --- curl stub ------------------------------------------------------------------
# Call <n> leaves $STUB/call-<n>-headers and, when it posts a body,
# $STUB/call-<n>-body; $STUB/calls.log gets "<METHOD> <URL>" per call.
# STUB_INSTALL_STATUS / STUB_TOKEN_STATUS pick the HTTP status of each answer.
STUB="$T/stub"
mkdir -p "$T/stubbin" "$STUB"
cat > "$T/stubbin/curl" <<'EOF'
#!/bin/bash
n=$(( $(cat "$STUB/calls.log" 2>/dev/null | wc -l) + 1 ))
out=""; data=""; method=GET; url=""
: > "$STUB/call-$n-headers"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -w|--max-time) shift 2 ;;
        -X) method="$2"; shift 2 ;;
        -H) if [[ "$2" == @* ]]; then cat "${2#@}" >> "$STUB/call-$n-headers"
            else printf '%s\n' "$2" >> "$STUB/call-$n-headers"; fi
            shift 2 ;;
        --data-binary) cp "${2#@}" "$STUB/call-$n-body"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
echo "$method $url" >> "$STUB/calls.log"
case "$url" in
    */installation)
        status="${STUB_INSTALL_STATUS:-200}"
        case "$status" in
            200) body="{\"id\": $STUB_INSTALLATION_ID, \"account\": {\"login\": \"x\"}}" ;;
            404) body='{"message": "Not Found", "status": "404"}' ;;
            *)   body='{"message": "A JSON web token could not be decoded", "status": "401"}' ;;
        esac ;;
    */access_tokens)
        status="${STUB_TOKEN_STATUS:-201}"
        case "$status" in
            201) body="{\"token\": \"$STUB_TOKEN\", \"expires_at\": \"2026-11-11T13:00:00Z\"}" ;;
            *)   body='{"message": "There is at least one repository that does not exist or is not accessible to the parent installation.", "status": "422"}' ;;
        esac ;;
    *) status=599; body='{}' ;;
esac
printf '%s' "$body" > "$out"
printf '%s' "$status"
EOF
chmod +x "$T/stubbin/curl"

# --- credentials for two owners ---------------------------------------------------
# add_app <owner> <app-id>: an app for <owner> under $T/.config/github-apps,
# with its public key next to the stub data for verification.
add_app() {
    local dir="$T/.config/github-apps/$1/review"
    mkdir -p "$dir"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$dir/private-key.pem" 2>/dev/null
    openssl pkey -in "$dir/private-key.pem" -pubout -out "$T/$1.pub.pem" 2>/dev/null
    printf '%s\n' "$2" > "$dir/app-id"
}
add_app jkeijzer 111111
add_app ImperialAutomation 222222

reset_stub() { rm -f "$STUB"/*; }

mkdir -p "$T/tmp"

run() { # gh-app-token.sh with the stub and the temp HOME; stdout/stderr as-is
    HOME="$T" TMPDIR="$T/tmp" PATH="$T/stubbin:$PATH" STUB="$STUB" STUB_TOKEN="$TOKEN" \
        STUB_INSTALLATION_ID="$INSTALLATION_ID" bash "$SCRIPT" "$@"
}

b64url_decode() {
    local s
    s=$(tr '_-' '/+' <<<"$1")
    while (( ${#s} % 4 )); do s+="="; done
    base64 -d <<<"$s"
}

# jwt_of <call-n>: the bearer token of that call's Authorization header.
jwt_of() {
    sed -n 's/^Authorization: Bearer //p' "$STUB/call-$1-headers"
}

# jwt_verifies <jwt> <owner>: yes when <owner>'s public key verifies its RS256
# signature.
jwt_verifies() {
    local h p s
    IFS=. read -r h p s <<<"$1"
    printf '%s.%s' "$h" "$p" > "$T/signed"
    b64url_decode "$s" > "$T/sig"
    if openssl dgst -sha256 -verify "$T/$2.pub.pem" -signature "$T/sig" "$T/signed" >/dev/null 2>&1
    then echo yes; else echo no; fi
}

jwt_part() { # <jwt> <1|2> -> decoded header or payload
    b64url_decode "$(cut -d. -f"$2" <<<"$1")"
}

echo "== 1. exec mode: the command runs with GH_TOKEN, exit status passes through =="
reset_stub
# shellcheck disable=SC2016  # $GH_TOKEN and $1 expand in the command's shell
OUT=$(run --repo jkeijzer/billing-api -- bash -c 'printf "%s" "$GH_TOKEN" > "$1"; exit 7' _ "$T/seen" 2>"$T/err")
STATUS=$?
check "command saw the installation token" "$TOKEN" "$(cat "$T/seen" 2>/dev/null)"
check "exit status of the command" "7" "$STATUS"
check "no stdout of its own" "" "$OUT"
check "no stderr of its own" "" "$(cat "$T/err")"
check "two API calls" "2" "$(wc -l < "$STUB/calls.log" | tr -d ' ')"
check "installation looked up for the repo" \
    "GET https://api.github.com/repos/jkeijzer/billing-api/installation" "$(sed -n 1p "$STUB/calls.log")"
check "token requested for that installation" \
    "POST https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens" "$(sed -n 2p "$STUB/calls.log")"
check "exit 0 passes through too" "0" "$(run --repo jkeijzer/billing-api -- true >/dev/null 2>&1; echo $?)"
# shellcheck disable=SC2016  # $1 and $2 expand in the command's shell
check "arguments reach the command unchanged" "a b|c" \
    "$(run --repo jkeijzer/billing-api -- bash -c 'printf "%s|%s" "$1" "$2"' _ 'a b' c 2>/dev/null)"

echo "== 2. the token request is restricted to the repository =="
reset_stub
run --repo jkeijzer/billing-api -- true >/dev/null 2>&1
check "body names only that repository" '["billing-api"]' \
    "$(jq -c '.repositories' "$STUB/call-2-body" 2>/dev/null)"
check "body asks nothing else" '["repositories"]' "$(jq -c 'keys' "$STUB/call-2-body" 2>/dev/null)"

echo "== 3. the JWT: signed with the owner's key, issued by its app =="
JWT=$(jwt_of 1)
check "installation lookup carries a JWT" "3" "$(awk -F. '{print NF}' <<<"$JWT")"
check "token request carries the same JWT" "$JWT" "$(jwt_of 2)"
check "signature verifies with the owner's public key" "yes" "$(jwt_verifies "$JWT" jkeijzer)"
check "signature does not verify with another owner's key" "no" "$(jwt_verifies "$JWT" ImperialAutomation)"
check "header alg RS256" "RS256" "$(jwt_part "$JWT" 1 | jq -r .alg)"
check "iss is the owner's app id" "111111" "$(jwt_part "$JWT" 2 | jq -r .iss)"
NOW=$(date +%s)
IAT=$(jwt_part "$JWT" 2 | jq -r .iat); EXP=$(jwt_part "$JWT" 2 | jq -r .exp)
check "iat is backdated for clock skew" "yes" "$([[ $IAT -le $((NOW - 30)) && $IAT -ge $((NOW - 120)) ]] && echo yes || echo no)"
check "exp is within GitHub's 10 minutes" "yes" "$([[ $((EXP - IAT)) -le 600 && $EXP -gt $NOW ]] && echo yes || echo no)"
check "API version header sent" "yes" "$(contains "$(cat "$STUB/call-1-headers")" "X-GitHub-Api-Version: 2022-11-28")"

echo "== 4. two owners side by side =="
reset_stub
run --repo ImperialAutomation/queue-runner -- true >/dev/null 2>&1
JWT=$(jwt_of 1)
check "second owner: lookup for its repo" \
    "GET https://api.github.com/repos/ImperialAutomation/queue-runner/installation" "$(sed -n 1p "$STUB/calls.log")"
check "second owner: signed with its own key" "yes" "$(jwt_verifies "$JWT" ImperialAutomation)"
check "second owner: its own app id" "222222" "$(jwt_part "$JWT" 2 | jq -r .iss)"

echo "== 5. --print =="
reset_stub
check "--print prints the token" "$TOKEN" "$(run --repo jkeijzer/billing-api --print 2>/dev/null)"
check "--print exits 0" "0" "$(run --repo jkeijzer/billing-api --print >/dev/null 2>&1; echo $?)"
check "--print before --repo works too" "$TOKEN" "$(run --print --repo jkeijzer/billing-api 2>/dev/null)"

echo "== 6. no app files for the owner: non-zero, named, command not run =="
reset_stub
ERR=$(run --repo someone-else/tool -- touch "$T/ran" 2>&1 >/dev/null); STATUS=$?
check "exits 1" "1" "$STATUS"
check "message names the owner" "yes" "$(contains "$ERR" "someone-else")"
check "message names the missing file" "yes" "$(contains "$ERR" "app-id")"
check "command not run" "no" "$([[ -e "$T/ran" ]] && echo yes || echo no)"
check "no API call" "no" "$([[ -e "$STUB/calls.log" ]] && echo yes || echo no)"
mkdir -p "$T/.config/github-apps/halfdone/review"
echo 333333 > "$T/.config/github-apps/halfdone/review/app-id"
ERR=$(run --repo halfdone/tool -- true 2>&1 >/dev/null); STATUS=$?
check "missing private key exits 1" "1" "$STATUS"
check "message names private-key.pem" "yes" "$(contains "$ERR" "private-key.pem")"
echo "not a key" > "$T/.config/github-apps/halfdone/review/private-key.pem"
ERR=$(run --repo halfdone/tool -- touch "$T/ran" 2>&1 >/dev/null); STATUS=$?
check "invalid private key exits 1" "1" "$STATUS"
check "message says the key is not valid" "yes" "$(contains "$ERR" "not a valid RSA private key")"
check "invalid key: command not run" "no" "$([[ -e "$T/ran" ]] && echo yes || echo no)"
check "invalid key: no API call" "no" "$([[ -e "$STUB/calls.log" ]] && echo yes || echo no)"

echo "== 7. app not installed on the repo: non-zero, named, command not run =="
reset_stub
ERR=$(STUB_INSTALL_STATUS=404 run --repo jkeijzer/elsewhere -- touch "$T/ran" 2>&1 >/dev/null); STATUS=$?
check "exits 1" "1" "$STATUS"
check "message says not installed" "yes" "$(contains "$ERR" "not installed")"
check "message names the repo" "yes" "$(contains "$ERR" "jkeijzer/elsewhere")"
check "command not run" "no" "$([[ -e "$T/ran" ]] && echo yes || echo no)"
check "no token requested" "1" "$(wc -l < "$STUB/calls.log" | tr -d ' ')"

echo "== 8. JWT rejected: names clock skew and key mismatch, shows GitHub's message =="
reset_stub
ERR=$(STUB_INSTALL_STATUS=401 run --repo jkeijzer/billing-api -- touch "$T/ran" 2>&1 >/dev/null); STATUS=$?
check "exits 1" "1" "$STATUS"
check "names clock skew" "yes" "$(contains "$ERR" "clock")"
check "names the key" "yes" "$(contains "$ERR" "private key")"
check "carries GitHub's message" "yes" "$(contains "$ERR" "could not be decoded")"
check "command not run" "no" "$([[ -e "$T/ran" ]] && echo yes || echo no)"

echo "== 9. token request refused: non-zero, command not run =="
reset_stub
ERR=$(STUB_TOKEN_STATUS=422 run --repo jkeijzer/billing-api -- touch "$T/ran" 2>&1 >/dev/null); STATUS=$?
check "exits 1" "1" "$STATUS"
check "carries GitHub's message" "yes" "$(contains "$ERR" "not accessible")"
check "command not run" "no" "$([[ -e "$T/ran" ]] && echo yes || echo no)"

echo "== 10. secrets stay off stdout and stderr =="
KEY_LINE=$(sed -n 2p "$T/.config/github-apps/jkeijzer/review/private-key.pem")
reset_stub
ALL=$(run --repo jkeijzer/billing-api -- true 2>&1)
check "exec mode: no token" "no" "$(contains "$ALL" "$TOKEN")"
check "exec mode: no key material" "no" "$(contains "$ALL" "$KEY_LINE")"
for case in "STUB_INSTALL_STATUS=401" "STUB_INSTALL_STATUS=404" "STUB_TOKEN_STATUS=422"; do
    reset_stub
    ALL=$(export "${case?}"; run --repo jkeijzer/billing-api -- true 2>&1)
    check "$case: no key material" "no" "$(contains "$ALL" "$KEY_LINE")"
    check "$case: no JWT" "no" "$(contains "$ALL" "$(jwt_of 1)")"
done
ALL=$(run --repo jkeijzer/billing-api --print 2>&1 >/dev/null)
check "--print: token on stdout only, stderr empty" "" "$ALL"
check "no temp files left behind" "" "$(ls -A "$T/tmp")"

echo "== 11. argument validation =="
reset_stub
check "no arguments exits 2"           "2" "$(run >/dev/null 2>&1; echo $?)"
check "usage goes to stderr"           "yes" "$(contains "$(run 2>&1 >/dev/null)" "usage")"
check "no --repo exits 2"              "2" "$(run -- true >/dev/null 2>&1; echo $?)"
check "--repo without value exits 2"   "2" "$(run --repo >/dev/null 2>&1; echo $?)"
check "neither --print nor a command exits 2" "2" "$(run --repo jkeijzer/billing-api >/dev/null 2>&1; echo $?)"
check "-- without a command exits 2"   "2" "$(run --repo jkeijzer/billing-api -- >/dev/null 2>&1; echo $?)"
check "--print with a command exits 2" "2" "$(run --repo jkeijzer/billing-api --print -- true >/dev/null 2>&1; echo $?)"
check "unknown option exits 2"         "2" "$(run --repo jkeijzer/billing-api --nope -- true >/dev/null 2>&1; echo $?)"
check "repo without owner exits 2"     "2" "$(run --repo billing-api -- true >/dev/null 2>&1; echo $?)"
check "path traversal in owner exits 2" "2" "$(run --repo ../x/billing-api -- true >/dev/null 2>&1; echo $?)"
check "repo name .. exits 2"           "2" "$(run --repo jkeijzer/.. -- true >/dev/null 2>&1; echo $?)"
check "validation runs nothing" "no" "$([[ -e "$STUB/calls.log" ]] && echo yes || echo no)"
check "--help exits 0" "0" "$(run --help >/dev/null 2>&1; echo $?)"
check "--help prints the usage" "yes" "$(contains "$(run --help 2>/dev/null)" "--repo <owner/repo>")"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
