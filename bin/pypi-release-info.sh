#!/usr/bin/env bash
# pypi-release-info.sh: release dates and requires_python from the PyPI JSON API.
#
# Replaces the inline `python3 -c "import json,urllib.request ..."` scripts used
# for release cooldowns and Python-compatibility checks before a dependency
# bump. Inline python3 has no allow rule (and gets none), so every such call
# prompts, and a chain containing one prompts as a whole. This wrapper is a
# single command and matches Bash(~/.claude/bin/*).
#
# Usage:
#   pypi-release-info.sh [--limit N] <package> [<version>...]
#
#   No versions: the latest N releases (default 6), newest first by upload
#   time. Releases without files are skipped.
#   With versions: one line per version, in argument order.
#
# Output, one release per line, fields separated by two spaces:
#   <version>  <upload-time>  <requires_python>[  yanked]
#   <upload-time> is the earliest upload of the release's files, ISO 8601 UTC
#   without fractional seconds (2024-09-14T02:58:28Z). <requires_python> is
#   "-" when the release does not declare one. "yanked" is appended when every
#   file of the release is yanked.
#   A named version that does not exist (or has no files) prints
#   "<version>  not found" and the run continues.
#
# Exit codes:
#   0  the package exists (also when some named versions were not found)
#   1  the package does not exist on PyPI (404), PyPI is unreachable, or it
#      answered with something other than the JSON document
#   2  usage error
#
# Examples:
#   pypi-release-info.sh requests
#   pypi-release-info.sh --limit 3 django
#   pypi-release-info.sh numpy 2.1.0 2.2.0
#
# Read-only; the only network call is GET <base>/pypi/<package>/json, where
# <base> is https://pypi.org. PYPI_BASE_URL overrides it, for the tests only.
# Needs curl and jq.

set -uo pipefail

LIMIT=6
PACKAGE=""
VERSIONS=()
BASE_URL="${PYPI_BASE_URL:-https://pypi.org}"
MAX_TIME=20

usage() {
  echo "usage: $(basename "$0") [--limit N] <package> [<version>...]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      [[ $# -ge 2 ]] || { echo "--limit needs a value" >&2; exit 2; }
      case "$2" in
        ''|*[!0-9]*|0*) echo "--limit must be a positive integer: $2" >&2; exit 2 ;;
      esac
      LIMIT="$2"
      shift 2 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *)
      if [[ -z "$PACKAGE" ]]; then PACKAGE="$1"; else VERSIONS+=("$1"); fi
      shift ;;
  esac
done

[[ -n "$PACKAGE" ]] || usage

# PyPI project names are letters, digits, ".", "_" and "-". Anything else would
# change the URL path rather than name a package.
if [[ ! "$PACKAGE" =~ ^[A-Za-z0-9._-]+$ || "$PACKAGE" == .* ]]; then
  echo "invalid package name: $PACKAGE" >&2
  exit 2
fi

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

URL="$BASE_URL/pypi/$PACKAGE/json"
if ! STATUS=$(curl -sS -L --max-time "$MAX_TIME" -o "$BODY" -w '%{http_code}' "$URL"); then
  echo "PyPI unreachable: $URL" >&2
  exit 1
fi

case "$STATUS" in
  200) ;;
  404) echo "package not found on PyPI: $PACKAGE" >&2; exit 1 ;;
  *)   echo "PyPI answered HTTP $STATUS for $URL" >&2; exit 1 ;;
esac

# One release -> its summary object, or null when it has no files.
# shellcheck disable=SC2016  # $v, $f are jq variables, not shell ones
JQ_PROGRAM='
def summary($v):
  (.releases[$v] // []) as $f
  | if ($f | length) == 0 then null
    else ($f | sort_by(.upload_time_iso_8601)) as $s
      | { v: $v,
          t: $s[0].upload_time_iso_8601,
          rp: ($s[0].requires_python // ""),
          y: ($f | all(.yanked == true)) }
    end;
def line:
  "\(.v)  \(.t | sub("\\.[0-9]+Z$"; "Z"))  \(if .rp == "" then "-" else .rp end)"
  + (if .y then "  yanked" else "" end);
. as $doc
| if ($ARGS.positional | length) == 0 then
    [ .releases | keys[] | . as $k | $doc | summary($k) | select(. != null) ]
    | sort_by(.t) | reverse | .[:$limit][] | line
  else
    $ARGS.positional[] as $v
    | ($doc | summary($v)) as $s
    | if $s == null then "\($v)  not found" else ($s | line) end
  end
'

if ! jq -r --argjson limit "$LIMIT" "$JQ_PROGRAM" "$BODY" --args "${VERSIONS[@]}"; then
  echo "PyPI answered with something other than the release JSON for $PACKAGE" >&2
  exit 1
fi
