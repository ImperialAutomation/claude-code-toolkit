#!/usr/bin/env bash
# gh-app-token.sh: run a command as the review GitHub App of a repo's owner.
#
# A PR author cannot approve or request changes on their own PR, and agents act
# as the human's account. Each owner account (personal or organization) has its
# own private GitHub App for that; this script picks the app of the repo's
# owner, requests an installation token restricted to that one repository and
# hands it over. Setup, rotation and error causes: docs/review-app-runbook.md.
#
# Usage:
#   gh-app-token.sh --repo <owner/repo> -- <cmd> [args...]
#   gh-app-token.sh --repo <owner/repo> --print
#
#   -- <cmd>   run <cmd> with GH_TOKEN set to the token; the token never reaches
#              stdout or stderr. The route for agents and scripts.
#   --print    print the token on stdout instead, for humans and debugging.
#              The auto-approve hook denies it to agents, so a token never
#              lands in a transcript.
#
# Credentials, per owner, never in a repo (directories 700, files 600):
#   ~/.config/github-apps/<owner>/review/app-id           the App ID
#   ~/.config/github-apps/<owner>/review/private-key.pem  its private key
# Adding an owner is registering its app and dropping these two files in place.
# <owner> is spelled as in --repo.
#
# Every call requests a fresh token (valid one hour); nothing is cached. The
# JWT and the request body go to curl through files in a private temp dir, not
# as arguments, and that dir is removed before <cmd> starts.
#
# Exit codes:
#   <n>  in exec mode: the exit status of <cmd>
#   0    --print: the token was printed
#   1    no app files for the owner, the app is not installed on the repo,
#        GitHub rejected the JWT or the token request, or GitHub is unreachable;
#        <cmd> did not run
#   2    usage error
#
# Examples:
#   gh-app-token.sh --repo ImperialAutomation/claude-code-toolkit -- gh api repos/ImperialAutomation/claude-code-toolkit --jq .full_name
#   gh-app-token.sh --repo ImperialAutomation/claude-code-toolkit -- gh pr review 123 --approve --body "..."
#
# Needs openssl, curl and jq.

set -uo pipefail

API_URL="https://api.github.com"
API_VERSION="2022-11-28"
APPS_DIR="$HOME/.config/github-apps"
APP_NAME="review"
MAX_TIME=20
# GitHub accepts a JWT valid for at most 10 minutes. iat is backdated a minute
# so a clock running slightly ahead of GitHub's is not rejected.
JWT_BACKDATE=60
JWT_LIFETIME=540

usage() {
  echo "usage: $(basename "$0") --repo <owner/repo> (-- <cmd> [args...] | --print)" >&2
  exit 2
}

fail() {
  echo "gh-app-token.sh: $*" >&2
  exit 1
}

REPO=""
PRINT=false
CMD=()
HAVE_CMD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "--repo needs a value" >&2; usage; }
      REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --print) PRINT=true; shift ;;
    --) shift; CMD=("$@"); HAVE_CMD=true; break ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$REPO" ]] || usage
if $HAVE_CMD && [[ ${#CMD[@]} -eq 0 ]]; then echo "no command after --" >&2; usage; fi
if $PRINT && $HAVE_CMD; then echo "--print and -- <cmd> exclude each other" >&2; usage; fi
if ! $PRINT && ! $HAVE_CMD; then usage; fi

# GitHub owner names are letters, digits and hyphens; repo names add "." and
# "_". Anything else would change the credentials path or the API path.
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
if [[ ! "$REPO" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ || "$NAME" == "." || "$NAME" == ".." ]]; then
  echo "invalid repository, expected <owner/repo>: $REPO" >&2
  exit 2
fi

APP_DIR="$APPS_DIR/$OWNER/$APP_NAME"
KEY="$APP_DIR/private-key.pem"
for file in "$APP_DIR/app-id" "$KEY"; do
  [[ -r "$file" ]] || fail "no GitHub App for owner $OWNER: $file is missing or unreadable (see docs/review-app-runbook.md)"
done
APP_ID=$(tr -d '[:space:]' < "$APP_DIR/app-id")
[[ -n "$APP_ID" ]] || fail "no GitHub App for owner $OWNER: $APP_DIR/app-id is empty"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-app-token.XXXXXX") || fail "cannot create a temp dir"
trap 'rm -rf "$WORK"' EXIT

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

NOW=$(date +%s)
JWT_HEADER=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
JWT_PAYLOAD=$(jq -jcn --arg iss "$APP_ID" --argjson now "$NOW" \
  --argjson back "$JWT_BACKDATE" --argjson life "$JWT_LIFETIME" \
  '{iat: ($now - $back), exp: ($now + $life), iss: $iss}' | b64url)
if ! JWT_SIG=$(printf '%s.%s' "$JWT_HEADER" "$JWT_PAYLOAD" \
    | openssl dgst -sha256 -sign "$KEY" -binary 2>/dev/null | b64url) || [[ -z "$JWT_SIG" ]]; then
  fail "cannot sign the JWT with $KEY: not a valid RSA private key"
fi

{
  printf 'Authorization: Bearer %s.%s.%s\n' "$JWT_HEADER" "$JWT_PAYLOAD" "$JWT_SIG"
  printf 'Accept: application/vnd.github+json\n'
  printf 'X-GitHub-Api-Version: %s\n' "$API_VERSION"
} > "$WORK/headers"

# api <METHOD> <path> [<body-file>]: the HTTP status in STATUS, the response
# body in $WORK/response.
api() {
  local args=(-sS --max-time "$MAX_TIME" -o "$WORK/response" -w '%{http_code}' -H @"$WORK/headers")
  [[ $# -ge 3 ]] && args+=(-X "$1" --data-binary @"$3")
  STATUS=$(curl "${args[@]}" "$API_URL$2") || fail "GitHub unreachable: $1 $API_URL$2"
}

github_message() { jq -r '.message // empty' "$WORK/response" 2>/dev/null; }

api GET "/repos/$OWNER/$NAME/installation"
case "$STATUS" in
  200) ;;
  404) fail "the GitHub App of $OWNER (app $APP_ID) is not installed on $REPO, or the repository does not exist" ;;
  401) fail "GitHub rejected the JWT of $OWNER's app ($(github_message)). Usual causes: the system clock is off by more than a minute, or $KEY is not the private key of app $APP_ID" ;;
  *)   fail "GitHub answered HTTP $STATUS looking up the installation for $REPO: $(github_message)" ;;
esac
INSTALLATION_ID=$(jq -r '.id // empty' "$WORK/response" 2>/dev/null)
[[ "$INSTALLATION_ID" =~ ^[0-9]+$ ]] || fail "GitHub's installation answer for $REPO has no installation id"

jq -cn --arg name "$NAME" '{repositories: [$name]}' > "$WORK/request"
api POST "/app/installations/$INSTALLATION_ID/access_tokens" "$WORK/request"
[[ "$STATUS" == 201 ]] || fail "GitHub refused an installation token for $REPO (HTTP $STATUS): $(github_message)"
TOKEN=$(jq -r '.token // empty' "$WORK/response" 2>/dev/null)
[[ -n "$TOKEN" ]] || fail "GitHub's token answer for $REPO has no token"

rm -rf "$WORK"
trap - EXIT

if $PRINT; then
  printf '%s\n' "$TOKEN"
  exit 0
fi
GH_TOKEN="$TOKEN" exec "${CMD[@]}"
