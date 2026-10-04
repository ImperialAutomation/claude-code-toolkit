#!/usr/bin/env bash
# Regression tests for git-push-pr-merge.sh's CI gate (issues #13, #32, #71, #75, #92).
#
# Covers:
#    1. No checks reported at all      -> CI_GATE: FAIL after grace, no merge (fail closed)
#    2. Checks pass                    -> CI_GATE: PASS, merges
#    3. A check fails                  -> CI_GATE: FAIL, no merge, exit non-zero
#    4. Checks stuck pending (timeout)  -> CI_GATE: TIMEOUT, no merge, exit non-zero
#    5. Pending then pass within timeout -> CI_GATE: PASS, merges
#    6. Transient gh error retried once -> CI_GATE: PASS, merges
#   6b. Malformed JSON from gh          -> CI_GATE: FAIL, no merge
#   6c. Valid JSON that is not an array -> CI_GATE: FAIL, no merge
#    7. --no-ci-wait                    -> merges without checking, regardless of check state
#    8. --no-merge                      -> CI gate skipped entirely, unaffected
#    9. Checks appear late, within grace -> CI_GATE: PASS, merges
#   10. Grace period elapses, no checks  -> CI_GATE: FAIL, no merge
#   11. gh exit 8                        -> read as pending, not "unable to verify"
#   12. Re-run with an existing open PR   -> reuses it, gate runs again
#   13. --ci-poll-interval 0              -> rejected up front, never spins
#   14. --repo targets another worktree    -> acts there, never on the caller's
#   15. Previous head GREEN, head lagging  -> no merge until the pushed commit
#                                             is itself green (the fail-open half)
#   16. Previous head RED, new head green  -> PASS in one invocation
#   17. Head never catches up              -> FAIL after grace, no merge
#   18. Unparseable `gh pr view` output     -> FAIL closed, no merge
#   19. --allow-failing-check, that check red -> PASS names the bypass, merges
#   20. Allowed red + another red            -> blocks, FAIL names only the other
#   21. Allowed red + another pending        -> keeps waiting, no early merge
#  21b. Allowed check cancelled              -> allowed too (cancel counts as red)
#   22. Same red check, no flag              -> FAIL, no merge (the list is opt-in)
#   23. Allowed name is a substring only     -> still blocks (exact match)
#   24. Flag repeated, one allowed check green -> PASS names only the red one
#   25. All green with the flag set          -> bare PASS, no bypass note
#   26. --allow-failing-check with no name   -> rejected before anything is pushed
#   27. Allowed name starting with a dash    -> passed to jq as a value, not an option
#  27b. Dash name that matches nothing       -> the real red check still blocks
#   28. Name with spaces/dots/parens         -> matches exactly
#  28b. Regex-ish allowed name (`.*`)        -> matches nothing, still blocks
#   29. `name=` (empty pattern)              -> rejected before anything is pushed
#  29b. `=regex` (empty name)                -> rejected before anything is pushed
#   30. Pattern matches the job log          -> PASS, and the log was really read
#   31. Pattern does NOT match               -> blocks, FAIL says the pattern missed
#   32. Job log cannot be fetched            -> blocks, FAIL names the unreadable log
#  32b. Job log is empty (HTTP 200, no body) -> a non-match, not a fetch failure
#   33. Allowed check is not an Actions job  -> blocks, no fetch attempted
#  33b. Allowed check has no link at all     -> blocks, no fetch attempted
#   34. Allowed red, no pattern              -> #75 unchanged, no log fetched
#   35. Allowed check GREEN, pattern set     -> no fetch, bare PASS
#   36. One patterned + one bare allow, miss -> only the patterned one blocks
#  36b. Same pair, log matches               -> both allowed, PASS names both
#   37. Pattern containing `=`               -> survives the first-`=` split
#  37b. ERE metacharacters in the pattern    -> honoured as a regex
#   38. Pattern re-matched on every poll     -> fetch per poll, not cached
#
# Each scenario builds a throwaway repo and a fake `gh`/`git push` stub so it
# never touches a real GitHub repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/git-push-pr-merge.sh"

# One temp root for every scenario repo, removed on EXIT. The per-scenario
# `rm -rf` only runs when that scenario completes, so under `set -e` a failing
# assertion would leave the repo (and scenario 14's linked worktrees) behind.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0

make_repo() {
    local dir
    dir=$(mktemp -d -p "$TEST_ROOT")
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" checkout -q -b main
    git -C "$dir" commit -q --allow-empty -m "root"
    git -C "$dir" checkout -q -b issue-1-feature
    git -C "$dir" commit -q --allow-empty -m "feature work"
    echo "$dir"
}

# Builds a fake `gh` binary in $1/bin that:
#   - `gh pr list` reports an existing open PR only if $1/existing-pr is present
#   - `gh pr create` prints a fake PR URL and records the call in $1/create-count
#   - `gh pr checks` behavior driven by $1/checks-state (see scenarios below)
#   - `gh pr view` headRefOid driven by $1/head-state (see below)
#   - `gh pr merge` records that merge happened into $1/merged
#
# The stub mirrors two real `gh pr checks` behaviours the earlier version got
# wrong, which is why the suite never caught issue #32:
#   - `--required` on a branch without protection returns an EMPTY set with
#     exit 0 — not the actual checks. Any state combined with --required
#     therefore looks green, which is the fail-open bug.
#   - Pending checks exit 8; failing checks exit 1 (see `gh pr checks --help`).
#
# It also models the staleness of issue #71: for the first seconds after a push
# to a branch that already has a PR, GitHub's view of that PR still has the
# PREVIOUS commit as head, and `gh pr checks` therefore answers for that commit.
# The `head-state` file drives `gh pr view --json headRefOid`:
#   current             — always the repo's real HEAD (i.e. the pushed SHA)
#   stale-then-current  — a foreign SHA for the first 2 calls, then the real HEAD
#   stale-forever       — always a foreign SHA
#   malformed           — unparseable output, so there is no SHA to compare
# The foreign SHA is a well-formed 40-hex object name that simply is not this
# HEAD, so the script has to actually compare rather than pattern-match.
make_fake_gh() {
    local workdir="$1"
    local bindir="$workdir/bin"
    mkdir -p "$bindir"

    cat > "$bindir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
WORKDIR="$FAKE_GH_WORKDIR"

case "$1 $2" in
    "pr list")
        # Only reports a PR when the scenario planted one (re-run case).
        if [ -f "$WORKDIR/existing-pr" ]; then
            echo '[{"number":42,"url":"https://github.com/example/repo/pull/42"}]'
        else
            echo '[]'
        fi
        exit 0
        ;;
    "pr create")
        count_file="$WORKDIR/create-count"
        count=$(cat "$count_file" 2>/dev/null || echo "0")
        echo $((count + 1)) > "$count_file"
        echo "https://github.com/example/repo/pull/42"
        exit 0
        ;;
    "pr checks")
        # checks-state file contains one of: none, none-then-pass, none-forever,
        # pass, fail, pending-then-pass, pending-forever, exit8-then-pass,
        # ratelimit-then-pass, malformed-json, stale-green-then-pass,
        # stale-red-then-pass
        state=$(cat "$WORKDIR/checks-state" 2>/dev/null || echo "none")
        count_file="$WORKDIR/checks-call-count"
        count=$(cat "$count_file" 2>/dev/null || echo "0")
        count=$((count + 1))
        echo "$count" > "$count_file"

        # The two stale-* states answer for whichever commit `head-state` says is
        # currently head, which is what real gh does: `gh pr checks` reads the
        # rollup of the PR's head commit, so a lagging head yields the PREVIOUS
        # commit's completed checks. Deriving it from head-state rather than from
        # the checks call count keeps the stub truthful either way — a script
        # that never consults the head still sees the old commit's answer, and
        # one that waits for the head to catch up sees the new commit's.
        head_state=$(cat "$WORKDIR/head-state" 2>/dev/null || echo "current")
        head_is_stale=0
        if [ "$head_state" = "stale-forever" ]; then
            head_is_stale=1
        elif [ "$head_state" = "stale-then-current" ]; then
            view_count=$(cat "$WORKDIR/view-call-count" 2>/dev/null || echo "0")
            [ "$view_count" -le 2 ] && head_is_stale=1
        fi

        # Real gh: --required on a branch without protection yields an empty
        # set with exit 0, regardless of the checks that actually ran.
        for arg in "$@"; do
            if [ "$arg" = "--required" ]; then
                echo "[]"
                exit 0
            fi
        done

        case "$state" in
            none)
                echo "no checks reported on the '42' pull request" >&2
                exit 1
                ;;
            none-then-pass)
                # Checks not registered yet, then they appear and pass.
                if [ "$count" -lt 3 ]; then
                    echo "no checks reported on the '42' pull request" >&2
                    exit 1
                fi
                echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                exit 0
                ;;
            none-forever)
                echo "no checks reported on the '42' pull request" >&2
                exit 1
                ;;
            pass)
                echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                exit 0
                ;;
            fail)
                # Real gh exits 1 when checks are failing.
                echo '[{"name":"build","state":"FAILURE","bucket":"fail"}]'
                exit 1
                ;;
            pending-then-pass)
                if [ "$count" -lt 2 ]; then
                    echo '[{"name":"build","state":"PENDING","bucket":"pending"}]'
                    exit 8
                else
                    echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                    exit 0
                fi
                ;;
            pending-forever)
                echo '[{"name":"build","state":"PENDING","bucket":"pending"}]'
                exit 8
                ;;
            exit8-then-pass)
                # Exit 8 with no parseable payload — pending, not "unverifiable".
                # Must exit 8 more than once: the transient-error branch retries
                # a single time, so a one-shot exit 8 would also go green there
                # and the scenario could not tell the two paths apart.
                if [ "$count" -lt 4 ]; then
                    exit 8
                fi
                echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                exit 0
                ;;
            ratelimit-then-pass)
                if [ "$count" -lt 2 ]; then
                    echo "API rate limit exceeded" >&2
                    exit 1
                else
                    echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                fi
                exit 0
                ;;
            malformed-json)
                echo 'not valid json {{{'
                exit 0
                ;;
            stale-green-then-pass)
                # The dangerous half of issue #71: the previous head was fully
                # green, so a gate that does not check WHICH commit it is looking
                # at merges the new commit before any of its checks have started.
                if [ "$head_is_stale" = "1" ]; then
                    echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                    exit 0
                fi
                # The new head's own checks: pending first, then green.
                if [ "$count" -lt 5 ]; then
                    echo '[{"name":"build","state":"PENDING","bucket":"pending"}]'
                    exit 8
                fi
                echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                exit 0
                ;;
            stale-red-then-pass)
                # The other half: the previous head failed a check and the new
                # commit fixes it. Reading the stale set reports FAIL for a
                # commit that is green, and the documented recovery ("fix, push,
                # re-run") then needs a second invocation to come out right.
                if [ "$head_is_stale" = "1" ]; then
                    echo '[{"name":"build","state":"FAILURE","bucket":"fail"}]'
                    exit 1
                fi
                echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                exit 0
                ;;
            fail-allowed)
                # One red check that the caller named in --allow-failing-check,
                # everything else green. The realistic shape of issue #75: an
                # advisory landed on a pinned package, so the audit is red in
                # every PR in the repo regardless of the diff.
                echo '[{"name":"dependency-audit","state":"FAILURE","bucket":"fail","link":"https://github.com/example/repo/actions/runs/500/job/9001"},{"name":"build","state":"SUCCESS","bucket":"pass","link":"https://github.com/example/repo/actions/runs/500/job/9002"}]'
                exit 1
                ;;
            fail-allowed-nonactions)
                # The allowed red check is an external service's commit status,
                # not a GitHub Actions job (issue #92, design question 4). Its
                # link points at the service's own page, so there is no job ID to
                # resolve and no run log to match a pattern against.
                echo '[{"name":"dependency-audit","state":"FAILURE","bucket":"fail","link":"https://audit.example.com/reports/abc123"},{"name":"build","state":"SUCCESS","bucket":"pass","link":"https://github.com/example/repo/actions/runs/500/job/9002"}]'
                exit 1
                ;;
            fail-allowed-nolink)
                # A commit status with no target URL at all: `link` is an empty
                # string. Distinct from nonactions because an empty field and a
                # foreign URL fail the job-ID parse for different reasons, and a
                # naive parse could read "" as a successful match of nothing.
                echo '[{"name":"dependency-audit","state":"FAILURE","bucket":"fail","link":""},{"name":"build","state":"SUCCESS","bucket":"pass","link":"https://github.com/example/repo/actions/runs/500/job/9002"}]'
                exit 1
                ;;
            fail-allowed-plus-other)
                # The allowed check AND a second one are red. The second is about
                # this diff, so the gate must still block — and must not launder
                # the allowed name into the failure list.
                echo '[{"name":"dependency-audit","state":"FAILURE","bucket":"fail","link":"https://github.com/example/repo/actions/runs/500/job/9001"},{"name":"build","state":"FAILURE","bucket":"fail","link":"https://github.com/example/repo/actions/runs/500/job/9002"}]'
                exit 1
                ;;
            fail-allowed-plus-pending)
                # The allowed check is red while another is still running. Nothing
                # is blocking YET, which is exactly the state a gate can misread
                # as "nothing blocking, therefore green" and merge before the
                # pending check has had its say.
                echo '[{"name":"dependency-audit","state":"FAILURE","bucket":"fail","link":"https://github.com/example/repo/actions/runs/500/job/9001"},{"name":"build","state":"PENDING","bucket":"pending","link":"https://github.com/example/repo/actions/runs/500/job/9002"}]'
                exit 1
                ;;
            fail-allowed-cancelled)
                # Same bypass, cancel bucket. The gate lumps fail and cancel
                # together, so the allow list has to cover both or a cancelled
                # allowed check blocks while a failed one does not.
                echo '[{"name":"dependency-audit","state":"CANCELLED","bucket":"cancel","link":"https://github.com/example/repo/actions/runs/500/job/9001"},{"name":"build","state":"SUCCESS","bucket":"pass","link":"https://github.com/example/repo/actions/runs/500/job/9002"}]'
                exit 1
                ;;
            fail-dashname)
                # A red check whose name starts with a dash, alongside a second
                # red check. Without `--args --`, jq eats the leading-dash
                # allow-list value as one of its own options, exits 2, prints
                # nothing, and BOTH red checks disappear from the fail list.
                echo '[{"name":"-weird*[name]","state":"FAILURE","bucket":"fail"},{"name":"build","state":"FAILURE","bucket":"fail"}]'
                exit 1
                ;;
            fail-parens-name)
                # Real-world check names carry spaces, dots and parentheses.
                # These must match exactly as a whole name, with no globbing or
                # regex interpretation anywhere in the path.
                echo '[{"name":"test (3.12)","state":"FAILURE","bucket":"fail","link":"https://github.com/example/repo/actions/runs/500/job/9001"},{"name":"build","state":"SUCCESS","bucket":"pass","link":"https://github.com/example/repo/actions/runs/500/job/9002"}]'
                exit 1
                ;;
            object-json)
                # Valid JSON but NOT an array — e.g. a GitHub API error body.
                # jq's `length` succeeds on objects, so this used to pass the
                # payload guard and then report PASS on zero green evidence.
                echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}'
                exit 0
                ;;
        esac
        ;;
    "pr view")
        # Which commit GitHub currently believes is the PR head. Right after a
        # push this lags, and `gh pr checks` lags with it — that coupling is the
        # whole of issue #71.
        state=$(cat "$WORKDIR/head-state" 2>/dev/null || echo "current")
        count_file="$WORKDIR/view-call-count"
        count=$(cat "$count_file" 2>/dev/null || echo "0")
        count=$((count + 1))
        echo "$count" > "$count_file"

        # Resolved through the real git: the fake only intercepts push/pull.
        real_head=$(git -C "$WORKDIR" rev-parse HEAD)
        stale_head="1f0c8a3e7b94d25610af83cc71e0d4b5926af300"

        case "$state" in
            stale-then-current)
                if [ "$count" -le 2 ]; then
                    echo "{\"headRefOid\":\"$stale_head\"}"
                else
                    echo "{\"headRefOid\":\"$real_head\"}"
                fi
                ;;
            stale-forever)
                echo "{\"headRefOid\":\"$stale_head\"}"
                ;;
            malformed)
                echo 'not json at all {{{'
                ;;
            *)
                echo "{\"headRefOid\":\"$real_head\"}"
                ;;
        esac
        exit 0
        ;;
    "pr merge")
        echo "merged" > "$WORKDIR/merged"
        exit 0
        ;;
esac

# `gh api /repos/{owner}/{repo}/actions/jobs/<id>/logs` — the failed job's log,
# which is what an allow PATTERN is matched against (issue #92). Real gh returns
# the log as plain text with exit 0, or prints an API error to stderr and exits
# non-zero (verified against the live API: a missing job is `HTTP 404`).
#
# Every fetch is recorded in joblog-fetch-count. Scenarios assert on that file
# as well as on the verdict, because "did not fetch" is a real requirement in
# two directions: a green allowed check must not cost an API call on every PR,
# and a pattern that is supposed to gate a merge must not pass without reading
# anything.
if [ "$1" = "api" ]; then
    endpoint=""
    for arg in "$@"; do
        case "$arg" in
            */actions/jobs/*/logs) endpoint="$arg" ;;
        esac
    done

    if [ -n "$endpoint" ]; then
        count_file="$WORKDIR/joblog-fetch-count"
        count=$(cat "$count_file" 2>/dev/null || echo "0")
        echo $((count + 1)) > "$count_file"
        # Record which job was asked for, so a scenario can prove the job ID came
        # from the right check's link rather than from whichever check was first.
        echo "$endpoint" >> "$WORKDIR/joblog-endpoints"

        state=$(cat "$WORKDIR/joblog-state" 2>/dev/null || echo "match")
        case "$state" in
            match)
                # A realistic audit log: the known advisory the bypass was opened
                # for, surrounded by the noise a real job log carries.
                printf '%s\n' \
                    '2026-10-04T08:06:10.1234567Z ##[group]Run npm audit --audit-level=high' \
                    '2026-10-04T08:06:12.7654321Z # npm audit report' \
                    '2026-10-04T08:06:12.7654322Z tar  <6.2.1' \
                    '2026-10-04T08:06:12.7654323Z Severity: high' \
                    '2026-10-04T08:06:12.7654324Z Denial of service - GHSA-2xqp-wc4f-hj7p' \
                    '2026-10-04T08:06:12.7654325Z 1 high severity vulnerability' \
                    '2026-10-04T08:06:13.0000001Z ##[error]Process completed with exit code 1.'
                exit 0
                ;;
            nomatch)
                # The same check red for a DIFFERENT cause: a new advisory on a
                # different package. This is the case the whole issue exists for —
                # it reads identically to the known one if you only match by name.
                printf '%s\n' \
                    '2026-10-04T08:06:10.1234567Z ##[group]Run npm audit --audit-level=high' \
                    '2026-10-04T08:06:12.7654321Z # npm audit report' \
                    '2026-10-04T08:06:12.7654322Z lodash  <4.17.21' \
                    '2026-10-04T08:06:12.7654323Z Severity: critical' \
                    '2026-10-04T08:06:12.7654324Z Prototype pollution - GHSA-p6mc-m468-83gg' \
                    '2026-10-04T08:06:12.7654325Z 1 critical severity vulnerability' \
                    '2026-10-04T08:06:13.0000001Z ##[error]Process completed with exit code 1.'
                exit 0
                ;;
            fetch-fail)
                # Logs expire (GitHub keeps them 90 days by default), and the API
                # has its own outages. Either way the gate has no evidence.
                echo '{"message":"Not Found","status":"404"}'
                echo "gh: Not Found (HTTP 404)" >&2
                exit 1
                ;;
            empty)
                # A 200 with an empty body. Distinct from fetch-fail: nothing
                # failed, so a gate that only checks the exit status would match
                # an empty string against the pattern and call it a non-match,
                # which happens to be right here but for the wrong reason.
                exit 0
                ;;
        esac
    fi

    echo "fake gh: unhandled api endpoint: $*" >&2
    exit 1
fi

echo "fake gh: unhandled args: $*" >&2
exit 1
FAKE_GH
    chmod +x "$bindir/gh"
    # Bake the workdir path into the script itself (avoids env export plumbing through git push -u).
    sed -i "s#\$FAKE_GH_WORKDIR#$workdir#" "$bindir/gh"

    # Fake `git` that only intercepts `push`/`pull` (network ops); everything
    # else delegates to the real git so branch/commit machinery still works.
    cat > "$bindir/git" <<FAKE_GIT
#!/usr/bin/env bash
if [ "\$1" = "push" ] || [ "\$1" = "pull" ]; then
    exit 0
fi
exec $(command -v git) "\$@"
FAKE_GIT
    chmod +x "$bindir/git"
}

# HEAD_STATE drives the fake `gh pr view` (see make_fake_gh). Scenarios that do
# not care about head staleness leave it at "current", which is what every real
# run converges on within seconds.
HEAD_STATE="current"

# JOBLOG_STATE drives the fake `gh api .../actions/jobs/<id>/logs` (see
# make_fake_gh): match, nomatch, fetch-fail or empty. Only the --allow-failing-
# check pattern scenarios (#92) care; everything else leaves it at "match",
# which is inert because no pattern is set and so no fetch happens at all.
JOBLOG_STATE="match"

run_case() {
    local name="$1"
    local repo="$2"
    local checks_state="$3"
    shift 3
    local extra_args=("$@")

    echo "$checks_state" > "$repo/checks-state"
    echo "$HEAD_STATE" > "$repo/head-state"
    echo "$JOBLOG_STATE" > "$repo/joblog-state"
    rm -f "$repo/merged" "$repo/checks-call-count" "$repo/create-count" \
        "$repo/view-call-count" "$repo/joblog-fetch-count" "$repo/joblog-endpoints"

    set +e
    output=$(cd "$repo" && PATH="$repo/bin:$PATH" "$TARGET" --base main --title "Test PR" --body-file "$repo/body.md" "${extra_args[@]}" 2>&1)
    actual_exit=$?
    set -e

    echo "$output" > "$repo/last-output.txt"
    echo "$actual_exit" > "$repo/last-exit.txt"
    echo "$name"
}

assert_contains() {
    local case_name="$1"
    local needle="$2"
    local haystack="$3"

    # -e is required: needles starting with `--` would otherwise be parsed as
    # grep options and silently never match.
    if echo "$haystack" | grep -qF -e "$needle"; then
        echo "PASS: $case_name (found '$needle')"
        pass=$((pass + 1))
    else
        echo "FAIL: $case_name (expected to find '$needle')"
        echo "--- output ---"
        echo "$haystack"
        echo "--------------"
        fail=$((fail + 1))
    fi
}

assert_exit() {
    local case_name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$actual" = "$expected" ]; then
        echo "PASS: $case_name (exit $actual)"
        pass=$((pass + 1))
    else
        echo "FAIL: $case_name (expected exit $expected, got $actual)"
        fail=$((fail + 1))
    fi
}

assert_file_absent() {
    local case_name="$1"
    local path="$2"

    if [ ! -f "$path" ]; then
        echo "PASS: $case_name (no merge happened)"
        pass=$((pass + 1))
    else
        echo "FAIL: $case_name (merge happened but should not have)"
        fail=$((fail + 1))
    fi
}

assert_file_present() {
    local case_name="$1"
    local path="$2"

    if [ -f "$path" ]; then
        echo "PASS: $case_name (merge happened)"
        pass=$((pass + 1))
    else
        echo "FAIL: $case_name (merge did not happen but should have)"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local case_name="$1"
    local needle="$2"
    local haystack="$3"

    if echo "$haystack" | grep -qF -e "$needle"; then
        echo "FAIL: $case_name (unexpectedly found '$needle')"
        echo "--- output ---"
        echo "$haystack"
        echo "--------------"
        fail=$((fail + 1))
    else
        echo "PASS: $case_name (no '$needle')"
        pass=$((pass + 1))
    fi
}

assert_file_content() {
    local case_name="$1"
    local path="$2"
    local expected="$3"
    local actual
    actual=$(cat "$path" 2>/dev/null || echo "<absent>")

    if [ "$actual" = "$expected" ]; then
        echo "PASS: $case_name ($expected)"
        pass=$((pass + 1))
    else
        echo "FAIL: $case_name (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

# --- Scenario 1: no checks reported at all -> fail closed after grace, no merge ---
# Previously asserted CI_GATE: SKIP + merge. That WAS the bug (issue #32): a PR
# whose checks have not registered yet is indistinguishable from a repo without
# CI, and merging on that assumption merged three red branches. "No checks" now
# means wait, then fail closed; --no-ci-wait is the deliberate escape hatch.
repo1=$(make_repo)
make_fake_gh "$repo1"
echo "Test PR body" > "$repo1/body.md"
run_case "no checks" "$repo1" "none" --ci-grace 2 --ci-poll-interval 1
assert_contains "no checks: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo1/last-output.txt")"
assert_contains "no checks: reason names grace period" "no checks appeared" "$(cat "$repo1/last-output.txt")"
assert_exit "no checks: exit code" "1" "$(cat "$repo1/last-exit.txt")"
assert_file_absent "no checks: no merge" "$repo1/merged"
rm -rf "$repo1"

# --- Scenario 2: required checks pass -> merge proceeds ---
repo2=$(make_repo)
make_fake_gh "$repo2"
echo "Test PR body" > "$repo2/body.md"
run_case "checks pass" "$repo2" "pass"
assert_contains "checks pass: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo2/last-output.txt")"
assert_exit "checks pass: exit code" "0" "$(cat "$repo2/last-exit.txt")"
assert_file_present "checks pass: merge happened" "$repo2/merged"
rm -rf "$repo2"

# --- Scenario 3: a required check fails -> no merge, non-zero exit ---
repo3=$(make_repo)
make_fake_gh "$repo3"
echo "Test PR body" > "$repo3/body.md"
run_case "checks fail" "$repo3" "fail"
assert_contains "checks fail: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo3/last-output.txt")"
assert_contains "checks fail: names failing check" "build" "$(cat "$repo3/last-output.txt")"
assert_exit "checks fail: exit code" "1" "$(cat "$repo3/last-exit.txt")"
assert_file_absent "checks fail: no merge" "$repo3/merged"
rm -rf "$repo3"

# --- Scenario 4: checks pending forever -> timeout, no merge ---
repo4=$(make_repo)
make_fake_gh "$repo4"
echo "Test PR body" > "$repo4/body.md"
run_case "checks timeout" "$repo4" "pending-forever" --ci-timeout 2 --ci-poll-interval 1
assert_contains "timeout: CI_GATE line" "CI_GATE: TIMEOUT" "$(cat "$repo4/last-output.txt")"
assert_exit "timeout: exit code" "1" "$(cat "$repo4/last-exit.txt")"
assert_file_absent "timeout: no merge" "$repo4/merged"
rm -rf "$repo4"

# --- Scenario 5: checks pending then pass within timeout -> merge proceeds ---
repo5=$(make_repo)
make_fake_gh "$repo5"
echo "Test PR body" > "$repo5/body.md"
run_case "checks pending then pass" "$repo5" "pending-then-pass" --ci-timeout 30 --ci-poll-interval 1
assert_contains "pending-then-pass: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo5/last-output.txt")"
assert_exit "pending-then-pass: exit code" "0" "$(cat "$repo5/last-exit.txt")"
assert_file_present "pending-then-pass: merge happened" "$repo5/merged"
rm -rf "$repo5"

# --- Scenario 6: transient gh error retried once, then succeeds ---
repo6=$(make_repo)
make_fake_gh "$repo6"
echo "Test PR body" > "$repo6/body.md"
run_case "transient error then pass" "$repo6" "ratelimit-then-pass" --ci-timeout 30 --ci-poll-interval 1
assert_contains "transient error: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo6/last-output.txt")"
assert_file_present "transient error: merge happened" "$repo6/merged"
rm -rf "$repo6"

# --- Scenario 6b: malformed JSON from gh -> fail closed, no merge, no crash ---
repo6b=$(make_repo)
make_fake_gh "$repo6b"
echo "Test PR body" > "$repo6b/body.md"
run_case "malformed json" "$repo6b" "malformed-json"
assert_contains "malformed json: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo6b/last-output.txt")"
assert_exit "malformed json: exit code" "1" "$(cat "$repo6b/last-exit.txt")"
assert_file_absent "malformed json: no merge" "$repo6b/merged"
rm -rf "$repo6b"

# --- Scenario 6c: valid JSON that is not an array -> fail closed, no merge ---
# jq `length` answers for objects too, so this payload satisfied a naive numeric
# guard and then made the `.[]` queries error out. set -e is suppressed inside
# `if ! wait_for_ci_gate`, so both name lists came back empty and the gate
# announced PASS without a single green check.
repo6c=$(make_repo)
make_fake_gh "$repo6c"
echo "Test PR body" > "$repo6c/body.md"
run_case "object json" "$repo6c" "object-json"
assert_contains "object json: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo6c/last-output.txt")"
assert_not_contains "object json: never reports PASS" "CI_GATE: PASS" "$(cat "$repo6c/last-output.txt")"
assert_exit "object json: exit code" "1" "$(cat "$repo6c/last-exit.txt")"
assert_file_absent "object json: no merge" "$repo6c/merged"
rm -rf "$repo6c"

# --- Scenario 7: --no-ci-wait skips the gate even with failing checks ---
repo7=$(make_repo)
make_fake_gh "$repo7"
echo "Test PR body" > "$repo7/body.md"
run_case "no-ci-wait with failing checks" "$repo7" "fail" --no-ci-wait
assert_contains "no-ci-wait: CI_GATE line" "CI_GATE: SKIP" "$(cat "$repo7/last-output.txt")"
assert_exit "no-ci-wait: exit code" "0" "$(cat "$repo7/last-exit.txt")"
assert_file_present "no-ci-wait: merge happened" "$repo7/merged"
rm -rf "$repo7"

# --- Scenario 8: --no-merge is unaffected (gate skipped, no merge, no CI_GATE noise) ---
repo8=$(make_repo)
make_fake_gh "$repo8"
echo "Test PR body" > "$repo8/body.md"
run_case "no-merge path" "$repo8" "fail" --no-merge
assert_exit "no-merge: exit code" "0" "$(cat "$repo8/last-exit.txt")"
assert_file_absent "no-merge: no merge" "$repo8/merged"
rm -rf "$repo8"

# --- Scenario 9: checks appear late but within the grace period -> PASS, merge ---
# The original failure mode: merged 3s before the check even started. The gate
# must sit through the registration gap instead of reading it as "no CI".
repo9=$(make_repo)
make_fake_gh "$repo9"
echo "Test PR body" > "$repo9/body.md"
run_case "checks appear late" "$repo9" "none-then-pass" --ci-grace 30 --ci-poll-interval 1
assert_contains "late checks: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo9/last-output.txt")"
assert_exit "late checks: exit code" "0" "$(cat "$repo9/last-exit.txt")"
assert_file_present "late checks: merge happened" "$repo9/merged"
rm -rf "$repo9"

# --- Scenario 10: grace period elapses with no checks -> FAIL closed, no merge ---
repo10=$(make_repo)
make_fake_gh "$repo10"
echo "Test PR body" > "$repo10/body.md"
run_case "grace expires" "$repo10" "none-forever" --ci-grace 2 --ci-poll-interval 1
assert_contains "grace expires: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo10/last-output.txt")"
assert_contains "grace expires: reason" "no checks appeared" "$(cat "$repo10/last-output.txt")"
assert_exit "grace expires: exit code" "1" "$(cat "$repo10/last-exit.txt")"
assert_file_absent "grace expires: no merge" "$repo10/merged"
rm -rf "$repo10"

# --- Scenario 11: exit 8 reads as pending, not "unable to verify" ---
repo11=$(make_repo)
make_fake_gh "$repo11"
echo "Test PR body" > "$repo11/body.md"
run_case "exit 8 is pending" "$repo11" "exit8-then-pass" --ci-timeout 30 --ci-poll-interval 1
assert_contains "exit 8: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo11/last-output.txt")"
assert_not_contains "exit 8: not misread as unverifiable" "unable to verify" "$(cat "$repo11/last-output.txt")"
assert_exit "exit 8: exit code" "0" "$(cat "$repo11/last-exit.txt")"
assert_file_present "exit 8: merge happened" "$repo11/merged"
rm -rf "$repo11"

# --- Scenario 12: re-run on a branch that already has a PR -> reuse, gate re-runs ---
# implement-epic's CI_GATE_BLOCKED recovery re-runs with identical arguments.
# Without an idempotent create, attempt 2 dies on gh instead of re-gating.
repo12=$(make_repo)
make_fake_gh "$repo12"
echo "Test PR body" > "$repo12/body.md"
touch "$repo12/existing-pr"
run_case "re-run with existing PR" "$repo12" "pass" --ci-timeout 30 --ci-poll-interval 1
assert_contains "re-run: reuses PR" "Reusing existing PR #42" "$(cat "$repo12/last-output.txt")"
assert_file_content "re-run: no second create" "$repo12/create-count" "<absent>"
assert_contains "re-run: gate ran again" "CI_GATE: PASS" "$(cat "$repo12/last-output.txt")"
assert_exit "re-run: exit code" "0" "$(cat "$repo12/last-exit.txt")"
assert_file_present "re-run: merge happened" "$repo12/merged"
rm -rf "$repo12"

# --- Scenario 13: --ci-poll-interval 0 is rejected instead of spinning forever ---
# Both deadlines advance by the poll interval, so 0 would never reach CI_TIMEOUT
# or CI_GRACE: the gate would hammer `gh` in a tight loop and never return.
repo13=$(make_repo)
make_fake_gh "$repo13"
echo "Test PR body" > "$repo13/body.md"
run_case "zero poll interval" "$repo13" "pending-forever" --ci-timeout 2 --ci-poll-interval 0
assert_contains "zero poll: rejected" "--ci-poll-interval must be a positive integer" "$(cat "$repo13/last-output.txt")"
assert_exit "zero poll: exit code" "1" "$(cat "$repo13/last-exit.txt")"
assert_file_absent "zero poll: no merge" "$repo13/merged"
rm -rf "$repo13"

# --- Scenario 14: --repo acts on the target worktree, not the caller's ---
# The whole point of the flag. An agent's working directory resets between Bash
# calls, so without --repo this script pushes whatever branch the session's start
# directory happens to be on — and after a merge it also runs `checkout` and
# `branch -D` there, which is destructive in a tree nobody is looking at.
#
# Every case below runs from a DIFFERENT worktree than the target, and the two
# are on different branches. If --repo were ignored, the caller's branch name
# would surface instead and each assertion fails.
repo14=$(make_repo)
make_fake_gh "$repo14"
echo "Test PR body" > "$repo14/body.md"

# A linked worktree of the same repo, on its own branch. This is the realistic
# shape: two trees, one repository, two sessions.
wt14="${repo14}-dev1"
git -C "$repo14" worktree add -q -b issue-99-other-work "$wt14" main >/dev/null 2>&1

# Run FROM the linked tree (on issue-99-other-work), TARGETING the main tree
# (on issue-1-feature).
set +e
out14=$(cd "$wt14" && PATH="$repo14/bin:$PATH" "$TARGET" --repo "$repo14" \
    --base main --title "Test PR" --body-file "$repo14/body.md" --no-merge 2>&1)
exit14=$?
set -e

assert_contains "--repo: pushes the target's branch" "Pushing issue-1-feature" "$out14"
assert_exit "--repo: exit code" "0" "$exit14"
# The caller's own branch must not appear anywhere — that would mean the script
# read the working directory after all.
if echo "$out14" | grep -qF "issue-99-other-work"; then
    echo "FAIL: --repo: caller's branch leaked into the run"
    echo "--- output ---"; echo "$out14"; echo "--------------"
    fail=$((fail + 1))
else
    echo "PASS: --repo: caller's branch never used"
    pass=$((pass + 1))
fi

# The same-branch-as-base guard must also judge the TARGET tree, not the caller.
# Targeting a tree that sits on `main` has to be refused even though the caller
# is on a feature branch and looks fine.
main14="${repo14}-mainwt"
git -C "$repo14" worktree add -q --detach "$main14" main >/dev/null 2>&1
git -C "$main14" checkout -q main 2>/dev/null || git -C "$main14" switch -q -c main-copy main
set +e
out14b=$(cd "$wt14" && PATH="$repo14/bin:$PATH" "$TARGET" --repo "$main14" \
    --base "$(git -C "$main14" branch --show-current)" --title "Test PR" \
    --body-file "$repo14/body.md" --no-merge 2>&1)
exit14b=$?
set -e
assert_contains "--repo: base-equals-current judged on target" "same as base" "$out14b"
assert_exit "--repo: base-equals-current exit code" "1" "$exit14b"

# A bad path fails loudly. Falling back to the caller's directory here is exactly
# the silent-wrong-tree bug the flag exists to prevent.
set +e
out14c=$(cd "$wt14" && PATH="$repo14/bin:$PATH" "$TARGET" --repo "${repo14}-nonexistent" \
    --base main --title "Test PR" --body-file "$repo14/body.md" --no-merge 2>&1)
exit14c=$?
set -e
assert_exit "--repo: nonexistent path exits non-zero" "1" "$exit14c"
if echo "$out14c" | grep -qF "Pushing"; then
    echo "FAIL: --repo: pushed despite a bad --repo path"
    fail=$((fail + 1))
else
    echo "PASS: --repo: nothing pushed on a bad path"
    pass=$((pass + 1))
fi

# Without --repo the behaviour is unchanged: the caller's own tree is used.
set +e
out14d=$(cd "$wt14" && PATH="$repo14/bin:$PATH" "$TARGET" \
    --base main --title "Test PR" --body-file "$repo14/body.md" --no-merge 2>&1)
exit14d=$?
set -e
assert_contains "no --repo: uses caller's tree" "Pushing issue-99-other-work" "$out14d"
assert_exit "no --repo: exit code" "0" "$exit14d"

git -C "$repo14" worktree remove --force "$wt14" >/dev/null 2>&1 || true
git -C "$repo14" worktree remove --force "$main14" >/dev/null 2>&1 || true
rm -rf "$repo14" "$wt14" "$main14"

# --- Scenario 15: previous head green -> must NOT merge on the stale set (#71) ---
# The fail-open half. GitHub's view of an existing PR lags a push by seconds, so
# `gh pr checks` first answers for the PREVIOUS commit. When that commit was
# fully green, a gate that never asks WHICH commit it is judging prints
# CI_GATE: PASS and merges the new commit before a single check on it has
# started — positive evidence about the wrong commit.
#
# The merge must still happen, but only after the head catches up and the new
# commit's own checks go green. So this asserts the ORDER, not just the outcome:
# no merge while the head is stale.
repo15=$(make_repo)
make_fake_gh "$repo15"
echo "Test PR body" > "$repo15/body.md"
touch "$repo15/existing-pr"
HEAD_STATE="stale-then-current"
run_case "stale green head" "$repo15" "stale-green-then-pass" --ci-timeout 30 --ci-grace 30 --ci-poll-interval 1
HEAD_STATE="current"
assert_contains "stale green: ends in PASS" "CI_GATE: PASS" "$(cat "$repo15/last-output.txt")"
assert_exit "stale green: exit code" "0" "$(cat "$repo15/last-exit.txt")"
assert_file_present "stale green: merged once the new head was green" "$repo15/merged"
# The load-bearing assertion: the gate waited out the stale window. With the old
# code the very first poll returned the previous head's green set, so the run
# never saw a pending check at all.
assert_contains "stale green: waited for the pushed commit" "stale" "$(cat "$repo15/last-output.txt")"
rm -rf "$repo15"

# --- Scenario 16: previous head red, new head green -> PASS in ONE run (#71) ---
# The false-FAIL half. The documented recovery for a blocked gate is "fix, push
# to the same branch, re-run with the same arguments". That re-run reuses the
# open PR, so the first poll answers for the commit that failed — and the fix is
# reported as a failure. Matching checks to the pushed SHA makes the single
# invocation come out right, with no second one needed.
repo16=$(make_repo)
make_fake_gh "$repo16"
echo "Test PR body" > "$repo16/body.md"
touch "$repo16/existing-pr"
HEAD_STATE="stale-then-current"
run_case "stale red head" "$repo16" "stale-red-then-pass" --ci-timeout 30 --ci-grace 30 --ci-poll-interval 1
HEAD_STATE="current"
assert_contains "stale red: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo16/last-output.txt")"
assert_not_contains "stale red: never reports the old head's failure" "CI_GATE: FAIL" "$(cat "$repo16/last-output.txt")"
assert_exit "stale red: exit code" "0" "$(cat "$repo16/last-exit.txt")"
assert_file_present "stale red: merge happened" "$repo16/merged"
rm -rf "$repo16"

# --- Scenario 17: head never catches up -> fail closed after grace (#71) ---
# A head that stays stale is indistinguishable from a push that never landed.
# There is no evidence about the pushed commit, so the gate must not merge.
repo17=$(make_repo)
make_fake_gh "$repo17"
echo "Test PR body" > "$repo17/body.md"
touch "$repo17/existing-pr"
HEAD_STATE="stale-forever"
run_case "head never catches up" "$repo17" "stale-green-then-pass" --ci-grace 2 --ci-poll-interval 1
HEAD_STATE="current"
assert_contains "stale forever: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo17/last-output.txt")"
assert_not_contains "stale forever: never reports PASS" "CI_GATE: PASS" "$(cat "$repo17/last-output.txt")"
assert_exit "stale forever: exit code" "1" "$(cat "$repo17/last-exit.txt")"
assert_file_absent "stale forever: no merge" "$repo17/merged"
rm -rf "$repo17"

# --- Scenario 18: unparseable head -> fail closed, never merges (#71) ---
# The guard itself must fail closed. If `gh pr view` cannot be read there is no
# SHA to compare against, and proceeding would silently restore the old
# behaviour of judging whatever check set happens to come back.
repo18=$(make_repo)
make_fake_gh "$repo18"
echo "Test PR body" > "$repo18/body.md"
touch "$repo18/existing-pr"
HEAD_STATE="malformed"
run_case "unparseable head" "$repo18" "pass" --ci-grace 2 --ci-poll-interval 1
HEAD_STATE="current"
assert_contains "malformed head: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo18/last-output.txt")"
assert_not_contains "malformed head: never reports PASS" "CI_GATE: PASS" "$(cat "$repo18/last-output.txt")"
assert_exit "malformed head: exit code" "1" "$(cat "$repo18/last-exit.txt")"
assert_file_absent "malformed head: no merge" "$repo18/merged"
rm -rf "$repo18"

# --- Scenario 19: --allow-failing-check lets one named red check through (#75) ---
# A check that is red repo-wide for a cause unrelated to the diff (an advisory on
# a pinned package) blocked every PR in the repo. The only escape was
# --no-ci-wait, which switches the whole gate off: no pending wait, no verdict on
# any other check, no head matching. This flag relaxes exactly one check.
repo19=$(make_repo)
make_fake_gh "$repo19"
echo "Test PR body" > "$repo19/body.md"
run_case "allowed check red" "$repo19" "fail-allowed" --allow-failing-check "dependency-audit"
assert_contains "allowed red: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo19/last-output.txt")"
# The bypass has to be readable in the log. A bare PASS here would be
# indistinguishable from a run where everything was actually green, which is a
# weaker claim presented as the stronger one.
assert_contains "allowed red: names what was bypassed" "allowed failing: dependency-audit" "$(cat "$repo19/last-output.txt")"
assert_exit "allowed red: exit code" "0" "$(cat "$repo19/last-exit.txt")"
assert_file_present "allowed red: merge happened" "$repo19/merged"
rm -rf "$repo19"

# --- Scenario 20: allowed red + another red -> still blocks, names only the other ---
# The flag relaxes one check, not the gate. The second failure is about this diff
# and must block exactly as before.
repo20=$(make_repo)
make_fake_gh "$repo20"
echo "Test PR body" > "$repo20/body.md"
run_case "allowed red plus other red" "$repo20" "fail-allowed-plus-other" --allow-failing-check "dependency-audit"
assert_contains "allowed+other: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo20/last-output.txt")"
assert_contains "allowed+other: names the blocking check" "build" "$(cat "$repo20/last-output.txt")"
# The allowed name must not appear in the FAIL list either. Listing it there
# would send the caller to investigate the one check they already decided about.
assert_not_contains "allowed+other: FAIL list excludes the allowed check" "CI_GATE: FAIL — dependency-audit" "$(cat "$repo20/last-output.txt")"
assert_exit "allowed+other: exit code" "1" "$(cat "$repo20/last-exit.txt")"
assert_file_absent "allowed+other: no merge" "$repo20/merged"
rm -rf "$repo20"

# --- Scenario 21: allowed red + another pending -> keeps waiting, no early merge ---
# The subtle one. With the allowed check excluded there is nothing BLOCKING, and a
# gate that reads "nothing blocking" as "green" merges while a check is still
# running. Nothing in scenarios 19-20 would catch that: both have a settled set.
repo21=$(make_repo)
make_fake_gh "$repo21"
echo "Test PR body" > "$repo21/body.md"
run_case "allowed red plus pending" "$repo21" "fail-allowed-plus-pending" \
    --allow-failing-check "dependency-audit" --ci-timeout 2 --ci-poll-interval 1
assert_contains "allowed+pending: CI_GATE line" "CI_GATE: TIMEOUT" "$(cat "$repo21/last-output.txt")"
assert_contains "allowed+pending: names the pending check" "build" "$(cat "$repo21/last-output.txt")"
assert_not_contains "allowed+pending: never reports PASS" "CI_GATE: PASS" "$(cat "$repo21/last-output.txt")"
assert_exit "allowed+pending: exit code" "1" "$(cat "$repo21/last-exit.txt")"
assert_file_absent "allowed+pending: no merge" "$repo21/merged"
rm -rf "$repo21"

# --- Scenario 21b: a cancelled allowed check is allowed too ---
# The gate treats cancel as a failure, so the allow list has to cover it. A
# cancelled run is the common shape when a repo-wide check is cancelled by a
# concurrency group rather than failing on its merits.
repo21b=$(make_repo)
make_fake_gh "$repo21b"
echo "Test PR body" > "$repo21b/body.md"
run_case "allowed check cancelled" "$repo21b" "fail-allowed-cancelled" --allow-failing-check "dependency-audit"
assert_contains "allowed cancel: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo21b/last-output.txt")"
assert_contains "allowed cancel: names what was bypassed" "allowed failing: dependency-audit" "$(cat "$repo21b/last-output.txt")"
assert_file_present "allowed cancel: merge happened" "$repo21b/merged"
rm -rf "$repo21b"

# --- Scenario 22: the allow list is opt-in -> same state blocks without the flag ---
# Guards the default. If the jq partition ever treated an empty allow list as
# "allow everything", every scenario above would still pass and the gate would
# merge every red PR in the repo.
repo22=$(make_repo)
make_fake_gh "$repo22"
echo "Test PR body" > "$repo22/body.md"
run_case "no flag, same red check" "$repo22" "fail-allowed"
assert_contains "no flag: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo22/last-output.txt")"
assert_contains "no flag: names the red check" "dependency-audit" "$(cat "$repo22/last-output.txt")"
assert_not_contains "no flag: never reports PASS" "CI_GATE: PASS" "$(cat "$repo22/last-output.txt")"
assert_exit "no flag: exit code" "1" "$(cat "$repo22/last-exit.txt")"
assert_file_absent "no flag: no merge" "$repo22/merged"
rm -rf "$repo22"

# --- Scenario 23: the match is exact, not a substring ---
# `--allow-failing-check audit` must not cover `dependency-audit`. A substring
# match would silently widen every bypass as the repo grows checks.
repo23=$(make_repo)
make_fake_gh "$repo23"
echo "Test PR body" > "$repo23/body.md"
run_case "partial name does not match" "$repo23" "fail-allowed" --allow-failing-check "audit"
assert_contains "exact match: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo23/last-output.txt")"
assert_contains "exact match: still blocks on the full name" "dependency-audit" "$(cat "$repo23/last-output.txt")"
assert_exit "exact match: exit code" "1" "$(cat "$repo23/last-exit.txt")"
assert_file_absent "exact match: no merge" "$repo23/merged"
rm -rf "$repo23"

# --- Scenario 24: repeatable, and a green allowed check is not an error ---
# Two names, only one of them red. The green one must not produce a bypass note
# (nothing was bypassed), and an allowed name that no check carries is fine —
# check names vary per branch, so an unmatched name must not block.
repo24=$(make_repo)
make_fake_gh "$repo24"
echo "Test PR body" > "$repo24/body.md"
run_case "repeatable flag" "$repo24" "fail-allowed" \
    --allow-failing-check "dependency-audit" --allow-failing-check "licence-scan"
assert_contains "repeatable: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo24/last-output.txt")"
assert_contains "repeatable: names only the red one" "allowed failing: dependency-audit" "$(cat "$repo24/last-output.txt")"
assert_not_contains "repeatable: green allowed check not listed as bypassed" "licence-scan" "$(cat "$repo24/last-output.txt")"
assert_exit "repeatable: exit code" "0" "$(cat "$repo24/last-exit.txt")"
assert_file_present "repeatable: merge happened" "$repo24/merged"
rm -rf "$repo24"

# --- Scenario 25: an all-green run still reports a bare PASS ---
# The bypass note is conditional. If it leaked onto every PASS the log would
# claim a bypass that never happened, which is the same misreporting as a bare
# PASS on a bypassed run, pointing the other way.
repo25=$(make_repo)
make_fake_gh "$repo25"
echo "Test PR body" > "$repo25/body.md"
run_case "green with flag set" "$repo25" "pass" --allow-failing-check "dependency-audit"
assert_contains "green with flag: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo25/last-output.txt")"
assert_not_contains "green with flag: no bypass note" "allowed failing" "$(cat "$repo25/last-output.txt")"
assert_exit "green with flag: exit code" "0" "$(cat "$repo25/last-exit.txt")"
assert_file_present "green with flag: merge happened" "$repo25/merged"
rm -rf "$repo25"

# --- Scenario 26: --allow-failing-check with no name is rejected up front ---
# An empty name matches a check named "", i.e. none. The flag would read as given
# while allowing nothing, and the merge would block on the check the caller
# believed was covered.
repo26=$(make_repo)
make_fake_gh "$repo26"
echo "Test PR body" > "$repo26/body.md"
run_case "empty allowed name" "$repo26" "fail-allowed" --allow-failing-check ""
assert_contains "empty name: rejected" "--allow-failing-check requires a check name" "$(cat "$repo26/last-output.txt")"
assert_exit "empty name: exit code" "1" "$(cat "$repo26/last-exit.txt")"
assert_file_absent "empty name: no merge" "$repo26/merged"
# Nothing may be pushed either: a rejected argument must stop before side effects.
assert_not_contains "empty name: nothing pushed" "Pushing" "$(cat "$repo26/last-output.txt")"
rm -rf "$repo26"

# --- Scenario 27: a leading-dash check name must not be eaten by jq (#75) ---
# The fail-open case. `jq ... --args "-weird*[name]"` without a `--` terminator
# makes jq parse the value as its own option: exit 2, empty stdout. The fail list
# comes back empty, set -e is suppressed inside `if ! wait_for_ci_gate`, and the
# gate reports PASS while TWO checks are red. The allowed name here is red and
# genuinely allowed; `build` is red and must still block.
repo27=$(make_repo)
make_fake_gh "$repo27"
echo "Test PR body" > "$repo27/body.md"
run_case "leading-dash allowed name" "$repo27" "fail-dashname" --allow-failing-check "-weird*[name]"
assert_contains "dash name: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo27/last-output.txt")"
assert_contains "dash name: still blocks on the other red check" "build" "$(cat "$repo27/last-output.txt")"
assert_not_contains "dash name: never reports PASS" "CI_GATE: PASS" "$(cat "$repo27/last-output.txt")"
assert_exit "dash name: exit code" "1" "$(cat "$repo27/last-exit.txt")"
assert_file_absent "dash name: no merge" "$repo27/merged"
rm -rf "$repo27"

# --- Scenario 27b: a leading-dash name is still matched exactly when alone ---
# The terminator must not break the feature it protects: with the other check
# green, the dash-named check is bypassed and named on the PASS line.
repo27b=$(make_repo)
make_fake_gh "$repo27b"
echo "Test PR body" > "$repo27b/body.md"
run_case "leading-dash name allowed alone" "$repo27b" "fail-parens-name" --allow-failing-check "-weird*[name]"
# That name matches nothing in this fixture, so `test (3.12)` must still block —
# proving the dash value was passed through as a positional, not silently lost.
assert_contains "dash unmatched: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo27b/last-output.txt")"
assert_contains "dash unmatched: names the real red check" "test (3.12)" "$(cat "$repo27b/last-output.txt")"
assert_exit "dash unmatched: exit code" "1" "$(cat "$repo27b/last-exit.txt")"
assert_file_absent "dash unmatched: no merge" "$repo27b/merged"
rm -rf "$repo27b"

# --- Scenario 28: names with spaces, dots and parentheses match exactly ---
# `test (3.12)` is an ordinary GitHub matrix job name. It must be matchable, and
# the match must be literal: no glob, no regex.
repo28=$(make_repo)
make_fake_gh "$repo28"
echo "Test PR body" > "$repo28/body.md"
run_case "parenthesised check name" "$repo28" "fail-parens-name" --allow-failing-check "test (3.12)"
assert_contains "parens name: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo28/last-output.txt")"
assert_contains "parens name: names what was bypassed" "allowed failing: test (3.12)" "$(cat "$repo28/last-output.txt")"
assert_exit "parens name: exit code" "0" "$(cat "$repo28/last-exit.txt")"
assert_file_present "parens name: merge happened" "$repo28/merged"
rm -rf "$repo28"

# --- Scenario 28b: a regex-ish allowed name does not match by pattern ---
# `.*` must allow nothing. If the match were ever regex-based this would wave
# every red check through, which is the widest possible silent bypass.
repo28b=$(make_repo)
make_fake_gh "$repo28b"
echo "Test PR body" > "$repo28b/body.md"
run_case "regex-ish allowed name" "$repo28b" "fail-parens-name" --allow-failing-check ".*"
assert_contains "regex name: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo28b/last-output.txt")"
assert_contains "regex name: still blocks" "test (3.12)" "$(cat "$repo28b/last-output.txt")"
assert_not_contains "regex name: never reports PASS" "CI_GATE: PASS" "$(cat "$repo28b/last-output.txt")"
assert_exit "regex name: exit code" "1" "$(cat "$repo28b/last-exit.txt")"
assert_file_absent "regex name: no merge" "$repo28b/merged"
rm -rf "$repo28b"

# --- Scenario 29: an empty pattern in <name>=<regex> is rejected up front (#92) ---
# `dependency-audit=` reads as "allow this check, narrowed to its cause" while
# the cause is the empty regex, which matches every log. That is the widest
# possible bypass wearing the syntax of the narrowest one, so it is refused
# before anything is pushed rather than silently behaving like #75's flag.
repo29=$(make_repo)
make_fake_gh "$repo29"
echo "Test PR body" > "$repo29/body.md"
run_case "empty pattern" "$repo29" "fail-allowed" --allow-failing-check "dependency-audit="
assert_contains "empty pattern: rejected" "requires a non-empty pattern" "$(cat "$repo29/last-output.txt")"
assert_exit "empty pattern: exit code" "1" "$(cat "$repo29/last-exit.txt")"
assert_file_absent "empty pattern: no merge" "$repo29/merged"
assert_not_contains "empty pattern: nothing pushed" "Pushing" "$(cat "$repo29/last-output.txt")"
rm -rf "$repo29"

# --- Scenario 29b: an empty name in <name>=<regex> is rejected up front (#92) ---
# `=GHSA-xxx` carries a cause but no check to attach it to. Same reasoning as
# #75's empty-name guard: it would match a check named "", i.e. none.
repo29b=$(make_repo)
make_fake_gh "$repo29b"
echo "Test PR body" > "$repo29b/body.md"
run_case "empty name with pattern" "$repo29b" "fail-allowed" --allow-failing-check "=GHSA-2xqp-wc4f-hj7p"
assert_contains "empty name+pattern: rejected" "requires a check name" "$(cat "$repo29b/last-output.txt")"
assert_exit "empty name+pattern: exit code" "1" "$(cat "$repo29b/last-exit.txt")"
assert_file_absent "empty name+pattern: no merge" "$repo29b/merged"
assert_not_contains "empty name+pattern: nothing pushed" "Pushing" "$(cat "$repo29b/last-output.txt")"
rm -rf "$repo29b"

# --- Scenario 30: allowed check red, log matches the pattern -> PASS (#92) ---
# The feature's happy path. The audit is red for the advisory the bypass was
# opened for, the log says so, and the merge proceeds — same outcome as #75's
# flag, but now on evidence about the CAUSE rather than the name alone.
repo30=$(make_repo)
make_fake_gh "$repo30"
echo "Test PR body" > "$repo30/body.md"
JOBLOG_STATE="match"
run_case "pattern matches log" "$repo30" "fail-allowed" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p"
assert_contains "pattern match: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo30/last-output.txt")"
assert_contains "pattern match: names what was bypassed" "allowed failing: dependency-audit" "$(cat "$repo30/last-output.txt")"
assert_exit "pattern match: exit code" "0" "$(cat "$repo30/last-exit.txt")"
assert_file_present "pattern match: merge happened" "$repo30/merged"
# The verdict must rest on a log that was actually read. Without this, an
# implementation that skipped the fetch and allowed by name would pass every
# other assertion in this scenario.
assert_file_present "pattern match: log was fetched" "$repo30/joblog-fetch-count"
# And it must be the ALLOWED check's job, not whichever check came first in the
# payload. `build` is job 9002; a job-ID parse that read the wrong element would
# fetch that one and match nothing.
assert_contains "pattern match: fetched the allowed check's job" "/actions/jobs/9001/logs" "$(cat "$repo30/joblog-endpoints")"
rm -rf "$repo30"

# --- Scenario 31: allowed check red, log does NOT match -> blocks (#92) ---
# The whole point of the issue. The audit is red for a NEW advisory on a
# different package; by name alone this is indistinguishable from the known
# cause, and #75's flag would merge it. The FAIL line must say the pattern did
# not match, not just "build failed", so the caller knows to read the log rather
# than assume a flake.
repo31=$(make_repo)
make_fake_gh "$repo31"
echo "Test PR body" > "$repo31/body.md"
JOBLOG_STATE="nomatch"
run_case "pattern does not match log" "$repo31" "fail-allowed" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p"
assert_contains "pattern nomatch: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo31/last-output.txt")"
assert_contains "pattern nomatch: says the pattern missed" "allow pattern did not match" "$(cat "$repo31/last-output.txt")"
assert_contains "pattern nomatch: names the check" "dependency-audit" "$(cat "$repo31/last-output.txt")"
assert_not_contains "pattern nomatch: never reports PASS" "CI_GATE: PASS" "$(cat "$repo31/last-exit.txt")"
assert_not_contains "pattern nomatch: no bypass note" "allowed failing" "$(cat "$repo31/last-output.txt")"
assert_exit "pattern nomatch: exit code" "1" "$(cat "$repo31/last-exit.txt")"
assert_file_absent "pattern nomatch: no merge" "$repo31/merged"
rm -rf "$repo31"

# --- Scenario 32: the job log cannot be read -> blocks, says so (#92) ---
# Logs expire after 90 days and the API has outages. "Could not check" is not
# evidence that this is the known failure, so a fail-closed gate must block —
# which is what makes the pattern form deliberately more fragile than #75's.
# The message distinguishes it from a genuine non-match: the reactions differ
# (retry or drop the pattern, versus read the log).
repo32=$(make_repo)
make_fake_gh "$repo32"
echo "Test PR body" > "$repo32/body.md"
JOBLOG_STATE="fetch-fail"
run_case "job log fetch fails" "$repo32" "fail-allowed" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p"
assert_contains "log unreadable: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo32/last-output.txt")"
assert_contains "log unreadable: says the log could not be read" "could not read the job log" "$(cat "$repo32/last-output.txt")"
assert_contains "log unreadable: names the check" "dependency-audit" "$(cat "$repo32/last-output.txt")"
# Must NOT read as a non-match: that would send the caller to read a log that
# was never retrieved.
assert_not_contains "log unreadable: not reported as a non-match" "did not match" "$(cat "$repo32/last-output.txt")"
assert_not_contains "log unreadable: never reports PASS" "CI_GATE: PASS" "$(cat "$repo32/last-output.txt")"
assert_exit "log unreadable: exit code" "1" "$(cat "$repo32/last-exit.txt")"
assert_file_absent "log unreadable: no merge" "$repo32/merged"
rm -rf "$repo32"

# --- Scenario 32b: an empty log body is a non-match, not a fetch failure (#92) ---
# A 200 with no body. Nothing failed, so this is a genuine "the pattern is not
# in the log" — but an implementation that only inspected the exit status could
# just as easily have matched the empty string and merged.
repo32b=$(make_repo)
make_fake_gh "$repo32b"
echo "Test PR body" > "$repo32b/body.md"
JOBLOG_STATE="empty"
run_case "job log is empty" "$repo32b" "fail-allowed" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p"
assert_contains "empty log: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo32b/last-output.txt")"
assert_contains "empty log: reported as a non-match" "allow pattern did not match" "$(cat "$repo32b/last-output.txt")"
assert_not_contains "empty log: never reports PASS" "CI_GATE: PASS" "$(cat "$repo32b/last-output.txt")"
assert_exit "empty log: exit code" "1" "$(cat "$repo32b/last-exit.txt")"
assert_file_absent "empty log: no merge" "$repo32b/merged"
rm -rf "$repo32b"

# --- Scenario 33: a non-Actions check has no log to match -> blocks (#92) ---
# Design question 4. An external service posting a commit status has no run log
# at all, so a pattern against it can never be satisfied. It is not refused at
# argument-parse time, because nothing about the flag says what kind of check
# the name will turn out to refer to — that is only knowable once the payload
# arrives. The message says which cause it was, so the caller does not go
# hunting for a log that does not exist.
repo33=$(make_repo)
make_fake_gh "$repo33"
echo "Test PR body" > "$repo33/body.md"
JOBLOG_STATE="match"   # inert here: the parse fails before any fetch
run_case "non-actions check with pattern" "$repo33" "fail-allowed-nonactions" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p"
assert_contains "non-actions: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo33/last-output.txt")"
assert_contains "non-actions: says there is no job log" "no job log to match" "$(cat "$repo33/last-output.txt")"
assert_not_contains "non-actions: never reports PASS" "CI_GATE: PASS" "$(cat "$repo33/last-output.txt")"
assert_exit "non-actions: exit code" "1" "$(cat "$repo33/last-exit.txt")"
assert_file_absent "non-actions: no merge" "$repo33/merged"
# No log fetch may be attempted: there is no job ID to fetch, and an attempt
# would mean the link was parsed into something bogus.
assert_file_absent "non-actions: no log fetch attempted" "$repo33/joblog-fetch-count"
rm -rf "$repo33"

# --- Scenario 33b: a check with no link at all -> blocks (#92) ---
# `link` is an empty string. Distinct from 33 because an empty field and a
# foreign URL fail the job-ID parse for different reasons.
repo33b=$(make_repo)
make_fake_gh "$repo33b"
echo "Test PR body" > "$repo33b/body.md"
JOBLOG_STATE="match"   # inert here too, for the same reason
run_case "check with no link" "$repo33b" "fail-allowed-nolink" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p"
assert_contains "no link: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo33b/last-output.txt")"
assert_contains "no link: says there is no job log" "no job log to match" "$(cat "$repo33b/last-output.txt")"
assert_not_contains "no link: never reports PASS" "CI_GATE: PASS" "$(cat "$repo33b/last-output.txt")"
assert_exit "no link: exit code" "1" "$(cat "$repo33b/last-exit.txt")"
assert_file_absent "no link: no merge" "$repo33b/merged"
assert_file_absent "no link: no log fetch attempted" "$repo33b/joblog-fetch-count"
rm -rf "$repo33b"

# --- Scenario 34: no pattern -> #75 behaviour, and no log fetch at all (#92) ---
# The compatibility guarantee. A check allowed by name alone must behave exactly
# as before: allowed unconditionally, with no log fetched. The fetch assertion is
# the load-bearing one — if the pattern stage ran for every allowed check, every
# repo-wide bypass would start costing an API call and would start FAILING
# whenever a log had expired, breaking #75's callers without touching their
# command lines.
repo34=$(make_repo)
make_fake_gh "$repo34"
echo "Test PR body" > "$repo34/body.md"
# nomatch: if a fetch happened despite no pattern, this log would not match and
# the scenario would block instead of merging.
JOBLOG_STATE="nomatch"
run_case "no pattern given" "$repo34" "fail-allowed" --allow-failing-check "dependency-audit"
assert_contains "no pattern: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo34/last-output.txt")"
assert_contains "no pattern: names what was bypassed" "allowed failing: dependency-audit" "$(cat "$repo34/last-output.txt")"
assert_exit "no pattern: exit code" "0" "$(cat "$repo34/last-exit.txt")"
assert_file_present "no pattern: merge happened" "$repo34/merged"
assert_file_absent "no pattern: no log fetch attempted" "$repo34/joblog-fetch-count"
rm -rf "$repo34"

# --- Scenario 35: a GREEN allowed check with a pattern -> no fetch (#92) ---
# Nothing was red, so there is no failure to attribute and nothing to match. A
# fetch here would be a wasted API call on every PR in the repo for as long as
# the flag stays in the command line, and with a fetch-fail state it would also
# block a run where every check passed — a green PR blocked by a bypass flag.
repo35=$(make_repo)
make_fake_gh "$repo35"
echo "Test PR body" > "$repo35/body.md"
JOBLOG_STATE="fetch-fail"
run_case "green allowed check with pattern" "$repo35" "pass" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p"
assert_contains "green+pattern: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo35/last-output.txt")"
assert_not_contains "green+pattern: no bypass note" "allowed failing" "$(cat "$repo35/last-output.txt")"
assert_exit "green+pattern: exit code" "0" "$(cat "$repo35/last-exit.txt")"
assert_file_present "green+pattern: merge happened" "$repo35/merged"
assert_file_absent "green+pattern: no log fetch attempted" "$repo35/joblog-fetch-count"
rm -rf "$repo35"

# --- Scenario 36: a pattern narrows only its own check (#92) ---
# Two allowed checks, one with a pattern and one without, both red. The
# patterned one must be gated on its log while the bare one keeps #75's
# behaviour. This is what the `<name>=<regex>` form buys over a positionally
# paired flag: the pairing cannot drift, so a reordered command line cannot
# attach this pattern to the other check.
repo36=$(make_repo)
make_fake_gh "$repo36"
echo "Test PR body" > "$repo36/body.md"
JOBLOG_STATE="nomatch"
run_case "patterned and bare allowed checks" "$repo36" "fail-allowed-plus-other" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p" \
    --allow-failing-check "build"
# dependency-audit is red for the wrong cause, so it blocks even though `build`
# is waved through by name.
assert_contains "mixed allow: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo36/last-output.txt")"
assert_contains "mixed allow: the patterned check blocks" "allow pattern did not match" "$(cat "$repo36/last-output.txt")"
assert_not_contains "mixed allow: never reports PASS" "CI_GATE: PASS" "$(cat "$repo36/last-output.txt")"
assert_exit "mixed allow: exit code" "1" "$(cat "$repo36/last-exit.txt")"
assert_file_absent "mixed allow: no merge" "$repo36/merged"
# Exactly one fetch: the bare-named check must not be looked up.
assert_contains "mixed allow: fetched once" "1" "$(cat "$repo36/joblog-fetch-count")"
assert_contains "mixed allow: fetched the patterned check's job" "/actions/jobs/9001/logs" "$(cat "$repo36/joblog-endpoints")"
rm -rf "$repo36"

# --- Scenario 36b: the same pair, matching log -> both allowed, merges (#92) ---
# The positive half of 36: with the patterned check red for its known cause, both
# bypasses apply and the PASS line names both.
repo36b=$(make_repo)
make_fake_gh "$repo36b"
echo "Test PR body" > "$repo36b/body.md"
JOBLOG_STATE="match"
run_case "patterned and bare, log matches" "$repo36b" "fail-allowed-plus-other" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p" \
    --allow-failing-check "build"
assert_contains "mixed allow ok: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo36b/last-output.txt")"
assert_contains "mixed allow ok: names the patterned check" "dependency-audit" "$(cat "$repo36b/last-output.txt")"
assert_contains "mixed allow ok: names the bare check" "build" "$(cat "$repo36b/last-output.txt")"
assert_exit "mixed allow ok: exit code" "0" "$(cat "$repo36b/last-exit.txt")"
assert_file_present "mixed allow ok: merge happened" "$repo36b/merged"
rm -rf "$repo36b"

# --- Scenario 37: a pattern may contain '=' (#92) ---
# The split is on the FIRST '=', so an ERE carrying its own '=' survives intact.
# A naive split on every '=' would truncate the pattern to `severity` and match
# far more than the caller asked for — a silently widened bypass.
repo37=$(make_repo)
make_fake_gh "$repo37"
echo "Test PR body" > "$repo37/body.md"
JOBLOG_STATE="match"
# The fixture log contains "Severity: high", not "severity=high", so this
# pattern must NOT match. If the split dropped everything after the second '=',
# the pattern would become `Severity` and match — blocking is the correct
# outcome and the proof the full pattern survived.
run_case "pattern containing equals" "$repo37" "fail-allowed" \
    --allow-failing-check "dependency-audit=Severity=high"
assert_contains "equals in pattern: CI_GATE line" "CI_GATE: FAIL" "$(cat "$repo37/last-output.txt")"
assert_contains "equals in pattern: reported as a non-match" "allow pattern did not match" "$(cat "$repo37/last-output.txt")"
assert_exit "equals in pattern: exit code" "1" "$(cat "$repo37/last-exit.txt")"
assert_file_absent "equals in pattern: no merge" "$repo37/merged"
rm -rf "$repo37"

# --- Scenario 37b: an ERE metacharacter is honoured as a regex (#92) ---
# The pattern is an ERE, unlike the check NAME, which is matched literally. A
# caller writing `GHSA-[0-9a-z]{4}-` must get regex semantics.
repo37b=$(make_repo)
make_fake_gh "$repo37b"
echo "Test PR body" > "$repo37b/body.md"
JOBLOG_STATE="match"
run_case "ERE pattern" "$repo37b" "fail-allowed" \
    --allow-failing-check "dependency-audit=GHSA-(2xqp|9999)-wc4f"
assert_contains "ERE pattern: CI_GATE line" "CI_GATE: PASS" "$(cat "$repo37b/last-output.txt")"
assert_contains "ERE pattern: names what was bypassed" "allowed failing: dependency-audit" "$(cat "$repo37b/last-output.txt")"
assert_exit "ERE pattern: exit code" "0" "$(cat "$repo37b/last-exit.txt")"
assert_file_present "ERE pattern: merge happened" "$repo37b/merged"
rm -rf "$repo37b"

# --- Scenario 38: a pattern is re-matched on every poll while waiting (#92) ---
# The allowed check is red for its known cause while another check is still
# pending, so the gate keeps polling. Documents what that costs: the pattern
# stage runs each time round, so the job log is fetched once per poll rather
# than being cached after the first match.
#
# That is the conservative choice, not an oversight. A re-run of a failed job
# replaces its log, so a cached first answer could outlive the evidence it was
# based on — and the gate's whole contract is that a verdict is about the state
# it just observed. The cost is bounded by --ci-timeout / --ci-poll-interval,
# and the request is a conditional GET against a blob store.
repo38=$(make_repo)
make_fake_gh "$repo38"
echo "Test PR body" > "$repo38/body.md"
JOBLOG_STATE="match"
run_case "pattern re-matched while pending" "$repo38" "fail-allowed-plus-pending" \
    --allow-failing-check "dependency-audit=GHSA-2xqp-wc4f-hj7p" \
    --ci-timeout 2 --ci-poll-interval 1
# Still blocks: the allowed check is accounted for, but `build` never finishes.
assert_contains "repoll: CI_GATE line" "CI_GATE: TIMEOUT" "$(cat "$repo38/last-output.txt")"
assert_contains "repoll: names the pending check" "build" "$(cat "$repo38/last-output.txt")"
assert_not_contains "repoll: never reports PASS" "CI_GATE: PASS" "$(cat "$repo38/last-output.txt")"
assert_file_absent "repoll: no merge" "$repo38/merged"
# More than one fetch, i.e. the match is re-evaluated rather than cached. If
# this ever becomes a caching decision, this assertion is the one to revisit.
if [ "$(cat "$repo38/joblog-fetch-count")" -gt 1 ]; then
    echo "PASS: repoll: log re-fetched each poll ($(cat "$repo38/joblog-fetch-count") fetches)"
    pass=$((pass + 1))
else
    echo "FAIL: repoll: expected more than one fetch, got $(cat "$repo38/joblog-fetch-count")"
    fail=$((fail + 1))
fi
rm -rf "$repo38"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
