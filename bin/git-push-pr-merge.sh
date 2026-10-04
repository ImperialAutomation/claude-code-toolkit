#!/usr/bin/env bash
# git-push-pr-merge.sh — Push branch, create PR, gate on CI, merge, return to base branch.
#
# Wraps the full post-commit workflow for sub-agents in implement-epic.
# Avoids multiline/heredoc issues by accepting PR body from a file.
#
# Usage:
#   git-push-pr-merge.sh --base <base-branch> --title "PR title" --body-file /tmp/pr-body.md
#   git-push-pr-merge.sh --repo <worktree> --base ... --title ... --body-file ...
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
#   Checks are matched to the pushed commit. The SHA is recorded right after the
#   push, and every poll first reads the PR's head commit (`gh pr view --json
#   headRefOid`); a check set is only judged once that head IS the pushed SHA.
#   Without this the gate judged whatever came back, which for the first seconds
#   after a push to an EXISTING PR is the previous head's completed check set —
#   wrong in both directions (issue #71). A stale green then merged the new
#   commit before any of its checks had started, which is a fail-OPEN hole in a
#   gate whose whole contract is to fail closed.
#
#   Checks do not exist for the first few seconds after a push — GitHub has to
#   create the runs. That gap is a separate --ci-grace deadline (default 120s),
#   not a reason to skip: if no checks appear within it the gate prints
#   `CI_GATE: FAIL — no checks appeared` and does not merge. A head that never
#   catches up with the push shares that deadline, for the same reason: it is a
#   registration gap, not a verdict. Use --no-ci-wait for repos that genuinely
#   have no CI (this toolkit repo is one).
#
#   One race is deliberately NOT handled: a head that matches while only SOME of
#   its runs have registered, all of them green. GitHub does not publish how many
#   runs to expect for a commit, so no API answers "is this set complete yet".
#   An empty set is covered by --ci-grace; a partial one is indistinguishable
#   from a finished one. See docs/git-script-failure-modes.md.
#
#   On FAIL/TIMEOUT the PR is left open, a `CI_GATE: FAIL|TIMEOUT` line is
#   printed, and the script exits non-zero so callers can react. Re-running
#   with the same arguments reuses the open PR and re-runs the gate.
#
#   --allow-failing-check <name> (repeatable) exempts ONE named check from
#   blocking. It exists for a check that is red repo-wide for a cause unrelated
#   to the diff — typically a dependency audit after a new advisory lands on a
#   pinned package, which otherwise blocks every PR in the repo, including the
#   sub-PRs of an epic. Everything else about the gate still applies: the head
#   must still match the pushed commit, pending checks are still waited for, and
#   any OTHER red check still blocks. The PASS line becomes
#   `CI_GATE: PASS (allowed failing: <names>)`, naming the checks that were
#   actually red rather than the ones permitted, so the bypass is in the log.
#
#   Prefer it over --no-ci-wait, which is not a narrower version of the same
#   thing: --no-ci-wait stops waiting for pending checks and stops looking at
#   any check at all, so it merges on no evidence. This flag keeps the gate and
#   subtracts one check from it.
#
#   The match is the exact, whole check name: allowing `audit` does not allow
#   `audit-critical`. A name that no check carries is not an error — check names
#   vary per branch, and refusing an unmatched name would block a merge for a
#   reason unrelated to the diff, which is the problem this flag exists to solve.
#   The cost of that choice is that a typo reads as "allowed" and still blocks.
#
# Worktree targeting:
#   Without --repo this acts on the current directory. That is the right default
#   for a human in a shell, but wrong for an agent: an agent's working directory
#   resets between every command, so the current directory is whichever tree the
#   session started in, not necessarily the one holding the work. This script
#   pushes a branch, opens a PR, and on merge runs `checkout` and `branch -D` —
#   aimed at the wrong worktree that is destructive to a tree nobody is watching.
#   Pass --repo (resolve it with git-resolve-worktree.sh) to say which tree.
#
# Options:
#   --repo <dir>               Run against the worktree at <dir> instead of the
#                              current directory. A path that is not a worktree
#                              is an error, never a fallback to the caller's tree
#   --base <branch>            Target branch for the PR (required)
#   --title <title>            PR title (required)
#   --body-file <path>         File containing PR body (required)
#   --no-merge                 Create PR but don't merge (for manual review) — CI gate is skipped
#   --no-ci-wait                Merge immediately without waiting for CI checks
#   --allow-failing-check <name>  Do not block on this check when it is red. Exact
#                              name, repeatable. The rest of the gate still applies
#   --ci-timeout <secs>         Max time registered checks may stay pending (default: 900)
#   --ci-grace <secs>           Max time checks may take to register (default: 120)
#   --ci-poll-interval <secs>   Polling interval while waiting (default: 15, must be >= 1)

set -euo pipefail

# Resolved from BASH_SOURCE, not the cwd: these scripts run from arbitrary
# working directories and bin/ is reached through a symlink.
# shellcheck source=bin/lib/strip-sandbox-noise.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/strip-sandbox-noise.sh"

BASE=""
TITLE=""
BODY_FILE=""
REPO_DIR=""
DO_MERGE=1
CI_WAIT=1
CI_TIMEOUT=900
CI_POLL_INTERVAL=15
CI_GRACE=120
# Check names that may be red without blocking the merge. Passed to jq as
# positional args, never interpolated into the filter: real check names contain
# spaces, parentheses and dots (`test (3.12)`), which a string-built filter
# would mangle or, worse, read as jq syntax.
ALLOW_FAILING=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO_DIR="$2"
            shift 2
            ;;
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
        --allow-failing-check)
            # An empty name would match a check whose name is empty — i.e. none,
            # so the flag would read as given while allowing nothing. Silent
            # no-ops are the wrong failure for a gate bypass: the caller believes
            # a check is covered and the merge blocks on it anyway.
            if [[ -z "${2:-}" ]]; then
                echo "Error: --allow-failing-check requires a check name" >&2
                exit 1
            fi
            ALLOW_FAILING+=("$2")
            shift 2
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

# Switch into the target worktree before any git/gh call. One `cd` covers every
# call site, including `gh`, which derives its repository from the working
# directory the same way git does.
#
# Resolve the body file to an absolute path FIRST: a relative --body-file is
# relative to where the caller stood, and moving afterwards would break it.
if [[ -n "$REPO_DIR" ]]; then
    BODY_FILE=$(cd "$(dirname "$BODY_FILE")" && pwd)/$(basename "$BODY_FILE")

    # A path that is not a worktree is an error, never a silent fallback to the
    # caller's tree — that fallback is the exact bug this flag exists to prevent.
    if [[ ! -d "$REPO_DIR" ]]; then
        echo "Error: --repo directory not found: $REPO_DIR" >&2
        exit 1
    fi
    if ! git -C "$REPO_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
        echo "Error: --repo is not inside a git worktree: $REPO_DIR" >&2
        exit 1
    fi
    cd "$REPO_DIR" || { echo "Error: cannot cd into repo '$REPO_DIR'" >&2; exit 1; }
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

CURRENT_BRANCH=$(git_filtered branch --show-current)
if [[ "$CURRENT_BRANCH" == "$BASE" ]]; then
    echo "Error: Current branch ($CURRENT_BRANCH) is the same as base ($BASE)" >&2
    exit 1
fi

echo "=== Pushing $CURRENT_BRANCH to origin ==="
git_filtered push -u origin "$CURRENT_BRANCH"

# The commit the gate must judge. Read AFTER the push so it is the SHA that was
# actually sent, and kept for the whole run: `gh pr checks` answers for whatever
# GitHub currently believes is the PR head, which lags a push by seconds, so
# without this the gate has nothing to compare its evidence against (issue #71).
PUSHED_SHA=$(git_filtered rev-parse HEAD)
if ! [[ "$PUSHED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: could not resolve the pushed commit (got: '$PUSHED_SHA')" >&2
    exit 1
fi

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
# "all checks green ON THE PUSHED COMMIT" must block the merge. Two fail-open
# holes have been closed here, and both looked like positive evidence:
#   - "no checks reported" was read as "no CI", merging PRs three seconds before
#     their checks even started (issue #32).
#   - a check set belonging to the PREVIOUS head was judged as if it were this
#     commit's, so a green predecessor merged an unchecked commit (issue #71).
# The lesson both share: evidence has to be attributed before it is weighed.
#
# Two separate deadlines:
#   CI_GRACE   — how long the evidence may take to EXIST for the pushed commit.
#                Covers both an empty check set and a PR head that still lags the
#                push; GitHub needs a few seconds for either, so right after a
#                push both mean "not yet", not "nothing to wait for".
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
    # A separate budget from retried_transient: the head read and the checks read
    # are different calls that fail for different reasons, and letting one consume
    # the other's single retry would make a genuine blip in the second fail the
    # gate outright.
    local retried_head=0
    local stderr_file
    stderr_file=$(mktemp)
    trap 'rm -f "$stderr_file"' RETURN

    while true; do
        # Which commit is this evidence about? `gh pr checks` has no SHA field
        # (see `gh pr checks --help`), so the head commit has to be read
        # separately and the check set only trusted once it is the pushed one.
        # A lagging head and a stale check set are the SAME staleness: `gh pr
        # checks` reads the rollup of the PR's head commit, so when GitHub still
        # reports the previous commit as head, the checks it returns are that
        # commit's. Comparing here is what keeps the gate's "positive evidence"
        # about the commit being merged.
        local head_json
        local head_exit=0
        head_json=$(gh pr view "$PR_NUMBER" --json headRefOid 2>"$stderr_file") || head_exit=$?
        local head_stderr
        head_stderr=$(cat "$stderr_file" 2>/dev/null || true)

        local head_sha=""
        if [[ "$head_exit" -eq 0 ]]; then
            head_sha=$(echo "$head_json" | jq -r 'if type == "object" and (.headRefOid | type) == "string" then .headRefOid else empty end' 2>/dev/null || true)
        fi

        # No SHA to compare against is no evidence at all. Failing closed here
        # matters more than anywhere else in this function: carrying on would
        # restore exactly the behaviour this guard exists to remove, judging
        # whichever check set happened to come back.
        if [[ -z "$head_sha" ]]; then
            if [[ "$retried_head" -eq 0 ]]; then
                retried_head=1
                echo "CI gate: could not read the PR head, retrying once: $head_stderr" >&2
                sleep 1
                continue
            fi
            echo "CI_GATE: FAIL — unable to determine the PR head commit: $head_stderr"
            return 1
        fi

        # The head has not caught up with the push yet. That is the registration
        # gap, not a verdict, so it belongs on the CI_GRACE deadline alongside an
        # empty check set — and like that one it fails closed when grace runs out.
        if [[ "$head_sha" != "$PUSHED_SHA" ]]; then
            if [[ "$grace_elapsed" -ge "$CI_GRACE" ]]; then
                echo "CI_GATE: FAIL — PR head is still ${head_sha:0:7}, not the pushed ${PUSHED_SHA:0:7}, after ${CI_GRACE}s"
                return 1
            fi
            echo "CI gate: PR head still stale (${head_sha:0:7}, waiting for ${PUSHED_SHA:0:7}) (${grace_elapsed}s/${CI_GRACE}s)" >&2
            sleep "$CI_POLL_INTERVAL"
            grace_elapsed=$((grace_elapsed + CI_POLL_INTERVAL))
            continue
        fi

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

        # Red checks split in two: the ones that block, and the ones the caller
        # named in --allow-failing-check. `[.name] - $ARGS.positional` is an exact
        # match on the whole name, not a substring: allowing `audit` must not also
        # allow a future `audit-critical` that nobody has looked at.
        local fail_names
        fail_names=$(echo "$checks_json" | jq -r \
            '[.[] | select((.bucket == "fail" or .bucket == "cancel") and ([.name] - $ARGS.positional | length) > 0)] | map(.name) | join(",")' \
            --args "${ALLOW_FAILING[@]}")
        local allowed_failing_names
        allowed_failing_names=$(echo "$checks_json" | jq -r \
            '[.[] | select((.bucket == "fail" or .bucket == "cancel") and ([.name] - $ARGS.positional | length) == 0)] | map(.name) | join(",")' \
            --args "${ALLOW_FAILING[@]}")
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

        # Only once nothing is pending. A red allowed check means nothing is
        # BLOCKING, which is not the same as nothing being left to run: reporting
        # PASS on that state would merge before the other checks had their say.
        if [[ -z "$pending_names" ]]; then
            if [[ -n "$allowed_failing_names" ]]; then
                # Name the checks that were actually red, not the ones the caller
                # permitted: the log should record what was bypassed, so a PASS
                # carrying a stale allow list is visible rather than implied.
                echo "CI_GATE: PASS (allowed failing: $allowed_failing_names)"
            else
                echo "CI_GATE: PASS"
            fi
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
    git_filtered checkout "$BASE"
    git_filtered pull origin "$BASE"

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
