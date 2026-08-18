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
#   2. Reuse the open PR for this branch, or create one against the base branch
#   3. If merging: wait for CI checks to go green (see CI gate below)
#   4. Merge PR (--merge --delete-branch)
#   5. Checkout base branch and pull
#
# CI gate (skipped entirely when --no-merge is set):
#   After PR creation, all reported checks (`gh pr checks`) are polled until
#   they all pass, one fails, or a deadline elapses. The gate FAILS CLOSED: it
#   only merges on positive evidence that every check is green.
#
#   Checks do not exist for the first few seconds after a push — GitHub has to
#   create the runs. That gap is a separate --ci-grace deadline (default 120s),
#   not a reason to skip: if no checks appear within it the gate prints
#   `CI_GATE: FAIL — no checks appeared` and does not merge. Use --no-ci-wait
#   for repos that genuinely have no CI (this toolkit repo is one).
#
#   On FAIL/TIMEOUT the PR is left open, a `CI_GATE: FAIL|TIMEOUT` line is
#   printed, and the script exits non-zero so callers can react. Re-running
#   with the same arguments reuses the open PR and re-runs the gate.
#
# Options:
#   --base <branch>            Target branch for the PR (required)
#   --title <title>            PR title (required)
#   --body-file <path>         File containing PR body (required)
#   --no-merge                 Create PR but don't merge (for manual review) — CI gate is skipped
#   --no-ci-wait                Merge immediately without waiting for CI checks
#   --ci-timeout <secs>         Max time registered checks may stay pending (default: 900)
#   --ci-grace <secs>           Max time checks may take to register (default: 120)
#   --ci-poll-interval <secs>   Polling interval while waiting (default: 15, must be >= 1)

set -euo pipefail

BASE=""
TITLE=""
BODY_FILE=""
DO_MERGE=1
CI_WAIT=1
CI_TIMEOUT=900
CI_POLL_INTERVAL=15
CI_GRACE=120

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
        --ci-grace)
            CI_GRACE="$2"
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

# Both deadlines advance by CI_POLL_INTERVAL, so 0 (or a non-number) would spin
# forever without ever reaching CI_TIMEOUT or CI_GRACE — a hung gate, which for a
# fail-closed design is worse than a wrong answer.
if ! [[ "$CI_POLL_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$CI_POLL_INTERVAL" -lt 1 ]]; then
    echo "Error: --ci-poll-interval must be a positive integer (got: $CI_POLL_INTERVAL)" >&2
    exit 1
fi
if ! [[ "$CI_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "Error: --ci-timeout must be a non-negative integer (got: $CI_TIMEOUT)" >&2
    exit 1
fi
if ! [[ "$CI_GRACE" =~ ^[0-9]+$ ]]; then
    echo "Error: --ci-grace must be a non-negative integer (got: $CI_GRACE)" >&2
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" == "$BASE" ]]; then
    echo "Error: Current branch ($CURRENT_BRANCH) is the same as base ($BASE)" >&2
    exit 1
fi

echo "=== Pushing $CURRENT_BRANCH to origin ==="
git push -u origin "$CURRENT_BRANCH"

# PR creation is idempotent: a blocked CI gate leaves the PR open, and the
# implement-epic recovery path re-runs this script with identical arguments
# (up to 3 attempts). Without the reuse check, attempt 2 dies on "a pull
# request for branch ... already exists" instead of re-running the gate.
EXISTING_PR=$(gh pr list --head "$CURRENT_BRANCH" --base "$BASE" --state open --json number,url)
PR_NUMBER=$(echo "$EXISTING_PR" | jq -r '.[0].number // empty')
PR_URL=$(echo "$EXISTING_PR" | jq -r '.[0].url // empty')

if [[ -n "$PR_NUMBER" ]]; then
    echo "=== Reusing existing PR #$PR_NUMBER: $PR_URL ==="
else
    echo "=== Creating PR: $TITLE ==="
    PR_URL=$(gh pr create --title "$TITLE" --base "$BASE" --body-file "$BODY_FILE")
    PR_NUMBER=$(echo "$PR_URL" | grep -oP '/pull/\K[0-9]+')
    echo "Created PR #$PR_NUMBER: $PR_URL"
fi

if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: could not determine PR number from: $PR_URL" >&2
    exit 1
fi

# wait_for_ci_gate: polls the checks on $PR_NUMBER until they all pass, one
# fails, or a deadline elapses. Prints a CI_GATE status line and returns
# non-zero on FAIL/TIMEOUT so the caller can bail before merging.
#
# Design principle: fail closed. Every branch that cannot positively establish
# "all checks green" must block the merge. The previous version failed open on
# "no checks reported" and merged PRs three seconds before their checks even
# started (issue #32).
#
# Two separate deadlines:
#   CI_GRACE   — how long checks may take to REGISTER. GitHub creates check runs
#                a few seconds after the push, so an empty set right after
#                `gh pr create` means "not yet", not "this repo has no CI".
#   CI_TIMEOUT — how long registered checks may stay pending.
#
# `gh pr checks` exit codes (see `gh pr checks --help`):
#   0 = all checks passed        8 = checks pending
#   1 = a check failed, OR no checks reported, OR a real gh error
# Exit 1 is overloaded, so it is disambiguated by stderr and by whether the
# JSON payload parses into checks.
wait_for_ci_gate() {
    local elapsed=0
    local grace_elapsed=0
    local retried_transient=0
    local stderr_file
    stderr_file=$(mktemp)
    trap 'rm -f "$stderr_file"' RETURN

    while true; do
        local checks_json
        local checks_exit=0
        checks_json=$(gh pr checks "$PR_NUMBER" --json name,bucket 2>"$stderr_file") || checks_exit=$?
        local checks_stderr
        checks_stderr=$(cat "$stderr_file" 2>/dev/null || true)

        # No checks registered yet: wait out the grace period, then fail closed.
        # Skipping here would be the same fail-open assumption, just 120s later —
        # a workflow file with a syntax error reads identically to "no CI".
        if [[ "$checks_exit" -ne 0 ]] && echo "$checks_stderr" | grep -qi "no checks reported"; then
            if [[ "$grace_elapsed" -ge "$CI_GRACE" ]]; then
                echo "CI_GATE: FAIL — no checks appeared after ${CI_GRACE}s (use --no-ci-wait for repos without CI)"
                return 1
            fi
            echo "CI gate: no checks registered yet, waiting (${grace_elapsed}s/${CI_GRACE}s)" >&2
            sleep "$CI_POLL_INTERVAL"
            grace_elapsed=$((grace_elapsed + CI_POLL_INTERVAL))
            continue
        fi

        # Exit 8 means pending. gh still prints the payload, but treat a missing
        # or unparseable one as "pending with unknown names" rather than an error.
        if [[ "$checks_exit" -eq 8 ]]; then
            local pending_names_8
            pending_names_8=$(echo "$checks_json" | jq -r '[.[] | select(.bucket == "pending")] | map(.name) | join(",")' 2>/dev/null || true)
            [[ -z "$pending_names_8" ]] && pending_names_8="(pending)"

            if [[ "$elapsed" -ge "$CI_TIMEOUT" ]]; then
                echo "CI_GATE: TIMEOUT — still pending: $pending_names_8"
                return 1
            fi
            sleep "$CI_POLL_INTERVAL"
            elapsed=$((elapsed + CI_POLL_INTERVAL))
            continue
        fi

        # Exit 0 (all passed) or exit 1 (a check failed) both carry a full JSON
        # payload. Anything else, or an exit 1 whose payload does not parse, is a
        # real gh error: retry once, then fail closed.
        # `if type == "array"` matters: jq's `length` also succeeds on objects,
        # strings and numbers, so an API error body like {"message":"Not Found"}
        # would yield a plausible count and then blow up in the `.[]` queries
        # below — which, with set -e suppressed inside `if ! wait_for_ci_gate`,
        # left both name lists empty and reported PASS on no evidence at all.
        local parsed_count
        parsed_count=$(echo "$checks_json" | jq -r 'if type == "array" then length else "notarray" end' 2>/dev/null || true)

        if [[ "$checks_exit" -ne 0 && "$checks_exit" -ne 1 ]] || ! [[ "$parsed_count" =~ ^[0-9]+$ ]]; then
            if [[ "$checks_exit" -ne 0 && "$retried_transient" -eq 0 ]]; then
                retried_transient=1
                echo "CI gate: transient error from gh (exit $checks_exit), retrying once: $checks_stderr" >&2
                sleep 1
                continue
            fi
            if [[ "$checks_exit" -eq 0 ]]; then
                echo "CI_GATE: FAIL — unable to parse checks output from gh"
            else
                echo "CI_GATE: FAIL — unable to verify checks: $checks_stderr"
            fi
            return 1
        fi

        local fail_names
        fail_names=$(echo "$checks_json" | jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | map(.name) | join(",")')
        local pending_names
        pending_names=$(echo "$checks_json" | jq -r '[.[] | select(.bucket == "pending")] | map(.name) | join(",")')

        if [[ -n "$fail_names" ]]; then
            echo "CI_GATE: FAIL — $fail_names"
            return 1
        fi

        # An empty set with exit 0 is what --required used to return on every
        # unprotected branch. Without --required it should not happen, but if it
        # does it is not evidence of green — treat it as "not registered yet".
        if [[ "$parsed_count" -eq 0 ]]; then
            if [[ "$grace_elapsed" -ge "$CI_GRACE" ]]; then
                echo "CI_GATE: FAIL — no checks appeared after ${CI_GRACE}s (use --no-ci-wait for repos without CI)"
                return 1
            fi
            echo "CI gate: check set still empty, waiting (${grace_elapsed}s/${CI_GRACE}s)" >&2
            sleep "$CI_POLL_INTERVAL"
            grace_elapsed=$((grace_elapsed + CI_POLL_INTERVAL))
            continue
        fi

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
