#!/usr/bin/env bash
# git-push-pr-merge.sh — Push branch, create PR, gate on CI, merge, return to base branch.
#
# Wraps the full post-commit workflow for sub-agents in implement-epic.
# Avoids multiline/heredoc issues by accepting PR body from a file.
#
# Usage:
#   git-push-pr-merge.sh --base <base-branch> --title "PR title" --body-file /tmp/pr-body.md
#
# What it does:
#   1. Push current branch to origin (with -u)
#   2. Create PR against base branch
#   3. If merging: wait for required CI checks to go green (see CI gate below)
#   4. Merge PR (--merge --delete-branch)
#   5. Checkout base branch and pull
#
# CI gate (skipped entirely when --no-merge is set):
#   After PR creation, required checks (`gh pr checks --required`) are polled
#   until they all pass, one fails, or --ci-timeout elapses. A repo with no
#   checks configured skips the gate and merges as before. On failure or
#   timeout the PR is left open, a `CI_GATE: FAIL|TIMEOUT` line is printed,
#   and the script exits non-zero so callers can react.
#
# Options:
#   --base <branch>            Target branch for the PR (required)
#   --title <title>            PR title (required)
#   --body-file <path>         File containing PR body (required)
#   --no-merge                 Create PR but don't merge (for manual review) — CI gate is skipped
#   --no-ci-wait                Merge immediately without waiting for CI checks
#   --ci-timeout <secs>         Max time to wait for checks (default: 900)
#   --ci-poll-interval <secs>   Polling interval while waiting (default: 15)

set -euo pipefail

BASE=""
TITLE=""
BODY_FILE=""
DO_MERGE=1
CI_WAIT=1
CI_TIMEOUT=900
CI_POLL_INTERVAL=15

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)
            BASE="$2"
            shift 2
            ;;
        --title)
            TITLE="$2"
            shift 2
            ;;
        --body-file)
            BODY_FILE="$2"
            shift 2
            ;;
        --no-merge)
            DO_MERGE=0
            shift
            ;;
        --no-ci-wait)
            CI_WAIT=0
            shift
            ;;
        --ci-timeout)
            CI_TIMEOUT="$2"
            shift 2
            ;;
        --ci-poll-interval)
            CI_POLL_INTERVAL="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Validate required args
if [[ -z "$BASE" ]]; then
    echo "Error: --base is required" >&2
    exit 1
fi
if [[ -z "$TITLE" ]]; then
    echo "Error: --title is required" >&2
    exit 1
fi
if [[ -z "$BODY_FILE" ]]; then
    echo "Error: --body-file is required" >&2
    exit 1
fi
if [[ ! -f "$BODY_FILE" ]]; then
    echo "Error: Body file not found: $BODY_FILE" >&2
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" == "$BASE" ]]; then
    echo "Error: Current branch ($CURRENT_BRANCH) is the same as base ($BASE)" >&2
    exit 1
fi

echo "=== Pushing $CURRENT_BRANCH to origin ==="
git push -u origin "$CURRENT_BRANCH"

echo "=== Creating PR: $TITLE ==="
PR_URL=$(gh pr create --title "$TITLE" --base "$BASE" --body-file "$BODY_FILE")
PR_NUMBER=$(echo "$PR_URL" | grep -oP '/pull/\K[0-9]+')

echo "Created PR #$PR_NUMBER: $PR_URL"

# wait_for_ci_gate: polls required checks on $PR_NUMBER until they all pass,
# one fails, or CI_TIMEOUT elapses. Prints a CI_GATE status line and returns
# non-zero on FAIL/TIMEOUT/unverifiable so the caller can bail before merging.
wait_for_ci_gate() {
    local elapsed=0
    local retried_transient=0

    while true; do
        local checks_json
        local checks_exit=0
        checks_json=$(gh pr checks "$PR_NUMBER" --required --json name,bucket 2>/tmp/ci-gate-stderr.$$) || checks_exit=$?
        local checks_stderr
        checks_stderr=$(cat /tmp/ci-gate-stderr.$$ 2>/dev/null || true)
        rm -f /tmp/ci-gate-stderr.$$

        if [[ "$checks_exit" -ne 0 ]]; then
            if echo "$checks_stderr" | grep -qi "no checks reported"; then
                echo "CI_GATE: SKIP — no checks configured"
                return 0
            fi
            # Transient gh error (rate limit, network blip): retry once, then fail closed.
            if [[ "$retried_transient" -eq 0 ]]; then
                retried_transient=1
                echo "CI gate: transient error from gh, retrying once: $checks_stderr" >&2
                sleep 1
                continue
            fi
            echo "CI_GATE: FAIL — unable to verify checks: $checks_stderr"
            return 1
        fi

        local fail_names
        fail_names=$(echo "$checks_json" | jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | map(.name) | join(",")')
        if [[ -n "$fail_names" ]]; then
            echo "CI_GATE: FAIL — $fail_names"
            return 1
        fi

        local pending_names
        pending_names=$(echo "$checks_json" | jq -r '[.[] | select(.bucket == "pending")] | map(.name) | join(",")')
        if [[ -z "$pending_names" ]]; then
            echo "CI_GATE: PASS"
            return 0
        fi

        if [[ "$elapsed" -ge "$CI_TIMEOUT" ]]; then
            echo "CI_GATE: TIMEOUT — still pending: $pending_names"
            return 1
        fi

        sleep "$CI_POLL_INTERVAL"
        elapsed=$((elapsed + CI_POLL_INTERVAL))
    done
}

if [[ "$DO_MERGE" -eq 1 ]]; then
    if [[ "$CI_WAIT" -eq 1 ]]; then
        echo "=== Waiting for CI checks on PR #$PR_NUMBER ==="
        if ! wait_for_ci_gate; then
            echo "=== CI gate failed — leaving PR #$PR_NUMBER open ===" >&2
            echo "PR_NUMBER: $PR_NUMBER"
            echo "PR_URL: $PR_URL"
            echo "STATUS: CI_GATE_BLOCKED"
            exit 1
        fi
    else
        echo "CI_GATE: SKIP — --no-ci-wait"
    fi

    echo "=== Merging PR #$PR_NUMBER ==="
    gh pr merge "$PR_NUMBER" --merge --delete-branch

    echo "=== Returning to $BASE ==="
    git checkout "$BASE"
    git pull origin "$BASE"

    echo "=== Done ==="
    echo "PR_NUMBER: $PR_NUMBER"
    echo "PR_URL: $PR_URL"
    echo "STATUS: MERGED"
else
    echo "=== Done (no merge) ==="
    echo "PR_NUMBER: $PR_NUMBER"
    echo "PR_URL: $PR_URL"
    echo "STATUS: CREATED"
fi
