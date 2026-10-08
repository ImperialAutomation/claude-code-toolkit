#!/bin/bash
# Apply label/milestone changes to many GitHub issues from a TSV plan.
# Usage: batch-issue-edit.sh [--dry-run] <repo> <plan.tsv>
#
# Plan line: <issue>\t<add-labels>\t<remove-labels>\t<milestone>
# Labels are comma-separated; "-" means no change for that field (an empty
# field cannot be used: read collapses consecutive tabs). Lines whose first
# field is not numeric (headers, comments) are skipped.
#
# Exists so a triage pass is one allowlisted command instead of N `gh` calls
# or a `for` loop (see batch-issue-view.sh for the permissions rationale).

set -euo pipefail

DRY=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY=true
    shift
fi

if [ $# -ne 2 ]; then
    echo "Usage: batch-issue-edit.sh [--dry-run] <repo> <plan.tsv>" >&2
    exit 1
fi

REPO="$1"
PLAN="$2"
ok=0
failed=0

while IFS=$'\t' read -r nr add rm ms; do
    [[ "$nr" =~ ^[0-9]+$ ]] || continue
    args=()
    [ "${add:--}" != "-" ] && args+=(--add-label "$add")
    [ "${rm:--}" != "-" ] && args+=(--remove-label "$rm")
    [ "${ms:--}" != "-" ] && args+=(--milestone "$ms")
    [ ${#args[@]} -eq 0 ] && continue
    if $DRY; then
        echo "#$nr ${args[*]}"
        ok=$((ok + 1))
        continue
    fi
    if gh issue edit "$nr" --repo "$REPO" "${args[@]}" >/dev/null; then
        ok=$((ok + 1))
    else
        echo "FAILED #$nr" >&2
        failed=$((failed + 1))
    fi
done < "$PLAN"

echo "edited: $ok, failed: $failed"
[ "$failed" -eq 0 ]
