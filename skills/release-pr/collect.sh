#!/usr/bin/env bash
# Collect everything needed to write a develop -> master release PR body.
#
# Emits a single report to stdout: current version, what the batch contains,
# and the facts that decide the semver bump and the operator/migration notes.
# Read-only: fetches and inspects, never writes a ref.
#
# Usage: collect.sh [--repo OWNER/NAME] [--base master] [--head develop]

set -uo pipefail

REPO=""
BASE="master"
HEAD="develop"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --head) HEAD="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) || {
    echo "Cannot determine repo. Pass --repo OWNER/NAME." >&2; exit 1; }
fi

# git may warn about sandbox-masked .gitmodules; harmless, keep stderr quiet.
git fetch origin --tags --quiet 2>/dev/null

RANGE_AHEAD="origin/$BASE..origin/$HEAD"
RANGE_DIFF="origin/$BASE...origin/$HEAD"

echo "=== REPO ==="
echo "$REPO  ($HEAD -> $BASE)"

echo
echo "=== CURRENT VERSION ==="
LATEST=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -n 1)
[ -z "$LATEST" ] && LATEST="v0.0.0"
echo "latest tag: $LATEST"
V=${LATEST#v}
MAJOR=${V%%.*}; REST=${V#*.}; MINOR=${REST%%.*}; PATCH=${REST#*.}
echo "next: major=v$((MAJOR+1)).0.0  minor=v$MAJOR.$((MINOR+1)).0  patch=v$MAJOR.$MINOR.$((PATCH+1))"

echo
echo "=== SIZE ==="
PRS=$(git rev-list --count --first-parent "$RANGE_AHEAD")
COMMITS=$(git rev-list --count "$RANGE_AHEAD")
echo "merges (PRs): $PRS"
echo "commits: $COMMITS"
git diff --shortstat "$RANGE_DIFF"

echo
echo "=== BEHIND CHECK (commits on $BASE not in $HEAD) ==="
BEHIND=$(git rev-list --count "origin/$HEAD..origin/$BASE")
echo "count: $BEHIND  (merge commits from past releases are expected and harmless)"
# Only NON-merge commits matter: they are work that exists on $BASE and nowhere
# else, and a release would silently carry them along unreviewed.
NONMERGE=$(git rev-list --no-merges "origin/$HEAD..origin/$BASE")
if [ -n "$NONMERGE" ]; then
  echo
  echo "!! non-merge commits present on $BASE only:"
  git log --oneline --no-merges "origin/$HEAD..origin/$BASE"
  echo "   Each is either a hotfix landed directly on $BASE (should be back-merged"
  echo "   into $HEAD first) or pre-dates the release convention. Check before releasing."
else
  echo "OK: no non-merge commits -- $BASE carries nothing $HEAD lacks."
fi

echo
echo "=== MERGED PRs IN THIS BATCH ==="
LAST_RELEASE_AT=$(gh pr list --repo "$REPO" --base "$BASE" --state merged --limit 1 \
  --json mergedAt -q '.[0].mergedAt' 2>/dev/null)
if [ -n "$LAST_RELEASE_AT" ] && [ "$LAST_RELEASE_AT" != "null" ]; then
  echo "(merged into $HEAD after the last release at $LAST_RELEASE_AT)"
  gh pr list --repo "$REPO" --state merged --base "$HEAD" --limit 100 \
    --json number,title,mergedAt \
    -q ".[] | select(.mergedAt > \"$LAST_RELEASE_AT\") | \"#\(.number) \(.title)\""
else
  echo "(no previous release PR found; listing recent merges to $HEAD)"
  gh pr list --repo "$REPO" --state merged --base "$HEAD" --limit 20 \
    --json number,title -q '.[] | "#\(.number) \(.title)"'
fi

echo
echo "=== SEMVER SIGNALS ==="
echo "-- new migrations (additive vs destructive matters) --"
git diff --name-status "$RANGE_DIFF" \
  | grep -iE 'alembic/versions/|migrations/' || echo "(none)"

echo
echo "-- destructive migration ops (drop/delete) --"
MIGRATIONS=$(git diff --name-only "$RANGE_DIFF" | grep -iE 'alembic/versions/|migrations/')
if [ -n "$MIGRATIONS" ]; then
  # shellcheck disable=SC2086
  git diff "$RANGE_DIFF" -- $MIGRATIONS \
    | grep -iE '^\+.*(drop_column|drop_table|drop_constraint|DROP |DELETE FROM)' \
    || echo "(none)"
else
  echo "(no migrations)"
fi

echo
echo "-- lockfiles (changed => rebuild, not a plain restart) --"
git diff --name-status "$RANGE_DIFF" -- \
  '*uv.lock' '*package-lock.json' '*pyproject.toml' '*package.json' || true

echo
echo "-- new/changed env vars (operator note candidates) --"
git diff "$RANGE_DIFF" -- '*.env.example' \
  | grep -E '^[+-][A-Z_]+=' | sort -u || echo "(none)"

echo
echo "-- API surface (route decorators added/removed) --"
git diff "$RANGE_DIFF" -- '*.py' \
  | grep -E '^[+-]@(router|app)\.(get|post|put|patch|delete)' | sort -u || echo "(none)"

echo
echo "=== BUMP GUIDANCE ==="
cat <<'GUIDE'
major -> a breaking change consumers must react to: removed/renamed API route
         or response field, a migration that drops data still in use, a config
         key rename with no fallback.
minor -> new capability that did not exist in the previous tag (new endpoint,
         new feature flag, new user-visible behaviour). Additive migrations.
patch -> fixes, refactors, docs, dependency bumps, tests. No new capability.

When in doubt between minor and patch, ask: could a user do something after
this release they could not do before? Yes -> minor.
GUIDE
