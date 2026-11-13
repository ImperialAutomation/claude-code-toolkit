#!/usr/bin/env bash
# Collect everything needed to write a develop -> release-branch PR body.
#
# Emits a single report to stdout: the branches compared, which release
# machinery the repo has, current version, what the batch contains, and the
# facts that decide the semver bump and the operator/migration notes.
# Read-only: fetches and inspects, never writes a ref.
#
# Usage: collect.sh [--repo OWNER/NAME] [--base <release-branch>] [--head develop]
#
# --base defaults to the repo's GitHub default branch. When that is the head
# itself (git-flow repos often default to develop), it falls back to the first
# existing origin/master, origin/main. No candidate is an error: pass --base.
#
# Exit codes: 0 report printed; 1 a branch is missing, base equals head, or a
# git comparison failed (the report stops there, never on a false OK);
# 2 usage error.

set -uo pipefail

REPO=""
BASE=""
HEAD="develop"
FALLBACK_BASES="master main"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --head) HEAD="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

die() { echo "!! $*" >&2; exit 1; }

remote_has() { git rev-parse --verify --quiet "refs/remotes/origin/$1" >/dev/null; }

remote_branches() {
  git for-each-ref --format='  %(refname:short)' refs/remotes/origin \
    | grep -v '^  origin/HEAD$' >&2
}

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) || {
    echo "Cannot determine repo. Pass --repo OWNER/NAME." >&2; exit 1; }
fi

# git may warn about sandbox-masked .gitmodules; harmless, keep stderr quiet.
git fetch origin --tags --quiet 2>/dev/null

if [ -z "$BASE" ]; then
  BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
  if [ -z "$BASE" ] || [ "$BASE" = "$HEAD" ]; then
    BASE=""
    for candidate in $FALLBACK_BASES; do
      remote_has "$candidate" && { BASE="$candidate"; break; }
    done
  fi
  if [ -z "$BASE" ]; then
    echo "!! cannot pick a release branch: the default branch is $HEAD or unknown," >&2
    echo "   and none of $FALLBACK_BASES exists on origin. Pass --base <branch>. Remote branches:" >&2
    remote_branches
    exit 1
  fi
fi

[ "$BASE" = "$HEAD" ] && die "base and head are the same branch ($BASE); pass --base <release-branch>."

for ref in "$BASE" "$HEAD"; do
  if ! remote_has "$ref"; then
    echo "!! origin/$ref does not exist. Remote branches:" >&2
    remote_branches
    exit 1
  fi
done

RANGE_AHEAD="origin/$BASE..origin/$HEAD"
RANGE_DIFF="origin/$BASE...origin/$HEAD"

echo "=== REPO ==="
echo "$REPO  ($HEAD -> $BASE)"

echo
echo "=== RELEASE MACHINERY ==="
LABELS=$(gh label list --repo "$REPO" --search "release:" --limit 100 --json name -q '.[].name' 2>/dev/null)
LABELS_RC=$?
RELEASE_LABELS=$(printf '%s\n' "$LABELS" | grep '^release:' | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$LABELS_RC" -ne 0 ]; then
  echo "release labels: unknown (gh label list failed)"
else
  echo "release labels: ${RELEASE_LABELS:-none}"
fi
WORKFLOWS=$(git ls-tree --name-only "origin/$BASE" .github/workflows/ 2>/dev/null)
SEMVER_WF=$(printf '%s\n' "$WORKFLOWS" | grep -E '/semver-tag\.ya?ml$' | head -n 1)
echo "semver-tag workflow: ${SEMVER_WF:-none}"
WORKFLOW_NAMES=$(printf '%s\n' "$WORKFLOWS" | sed 's|.*/||' | tr '\n' ' ' | sed 's/ *$//')
echo "workflows on $BASE: ${WORKFLOW_NAMES:-none}"
TEMPLATE=".github/PULL_REQUEST_TEMPLATE.md"
if git show "origin/$BASE:$TEMPLATE" 2>/dev/null | grep -q 'AGENT-REVIEW:START'; then
  echo "AGENT-REVIEW template: $TEMPLATE"
else
  echo "AGENT-REVIEW template: none"
fi
if [ "$LABELS_RC" -ne 0 ]; then
  echo "semver: unknown -- check the release:* labels by hand before labelling"
elif [ -n "$RELEASE_LABELS" ] && [ -n "$SEMVER_WF" ]; then
  echo "semver: present -- label the PR, the workflow tags the merge"
else
  echo "semver: absent -- skip the release label and tag steps"
fi

echo
echo "=== REQUIRED CHECKS (status checks the merge into $BASE waits for) ==="
# Rulesets and classic branch protection both can require a check. A required
# check whose workflow never starts on this PR (a trigger-level `paths` filter
# the batch does not match) never reports, and blocks the merge.
RULES_REQ=$(gh api "repos/$REPO/rules/branches/$BASE" \
  --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' \
  2>/dev/null)
RULES_RC=$?
PROT_REQ=$(gh api "repos/$REPO/branches/$BASE" \
  --jq '.protection.required_status_checks.contexts[]?' 2>/dev/null)
PROT_RC=$?
if [ "$RULES_RC" -ne 0 ] || [ "$PROT_RC" -ne 0 ]; then
  echo "required on $BASE: unknown (gh api failed; check the branch's rulesets and protection by hand)"
else
  REQUIRED=$(printf '%s\n%s\n' "$RULES_REQ" "$PROT_REQ" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')
  echo "required on $BASE: ${REQUIRED:-none}"
fi
echo "A required check that is absent from the PR blocks the merge; an absent"
echo "check that is not required is normal when the batch touches no file its"
echo "workflow's paths filter matches."

echo
echo "=== CURRENT VERSION ==="
LATEST=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -n 1)
if [ -z "$LATEST" ]; then
  LATEST="v0.0.0"
  echo "latest tag: none (v0.0.0 assumed)"
else
  echo "latest tag: $LATEST"
fi
V=${LATEST#v}
MAJOR=${V%%.*}; REST=${V#*.}; MINOR=${REST%%.*}; PATCH=${REST#*.}
echo "next: major=v$((MAJOR+1)).0.0  minor=v$MAJOR.$((MINOR+1)).0  patch=v$MAJOR.$MINOR.$((PATCH+1))"

echo
echo "=== SIZE ==="
PRS=$(git rev-list --count --first-parent "$RANGE_AHEAD") || die "SIZE: git rev-list $RANGE_AHEAD failed"
COMMITS=$(git rev-list --count "$RANGE_AHEAD") || die "SIZE: git rev-list $RANGE_AHEAD failed"
echo "merges (PRs): $PRS"
echo "commits: $COMMITS"
git diff --shortstat "$RANGE_DIFF" || die "SIZE: git diff $RANGE_DIFF failed"

echo
echo "=== BEHIND CHECK (commits on $BASE not in $HEAD) ==="
# A failed comparison stops the report: this check is a release gate and must
# never print OK on an error.
BEHIND=$(git rev-list --count "origin/$HEAD..origin/$BASE") \
  || die "BEHIND CHECK: git rev-list origin/$HEAD..origin/$BASE failed"
echo "count: $BEHIND  (merge commits from past releases are expected and harmless)"
# Only NON-merge commits matter: they are work that exists on $BASE and nowhere
# else, and a release would silently carry them along unreviewed.
NONMERGE=$(git rev-list --no-merges "origin/$HEAD..origin/$BASE") \
  || die "BEHIND CHECK: git rev-list --no-merges origin/$HEAD..origin/$BASE failed"
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
