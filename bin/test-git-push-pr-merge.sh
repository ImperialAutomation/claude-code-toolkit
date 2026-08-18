#!/usr/bin/env bash
# Regression tests for git-push-pr-merge.sh's CI gate (issues #13, #32).
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
#
# Each scenario builds a throwaway repo and a fake `gh`/`git push` stub so it
# never touches a real GitHub repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/git-push-pr-merge.sh"

pass=0
fail=0

make_repo() {
    local dir
    dir=$(mktemp -d)
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
#   - `gh pr merge` records that merge happened into $1/merged
#
# The stub mirrors two real `gh pr checks` behaviours the earlier version got
# wrong, which is why the suite never caught issue #32:
#   - `--required` on a branch without protection returns an EMPTY set with
#     exit 0 — not the actual checks. Any state combined with --required
#     therefore looks green, which is the fail-open bug.
#   - Pending checks exit 8; failing checks exit 1 (see `gh pr checks --help`).
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
        # ratelimit-then-pass, malformed-json
        state=$(cat "$WORKDIR/checks-state" 2>/dev/null || echo "none")
        count_file="$WORKDIR/checks-call-count"
        count=$(cat "$count_file" 2>/dev/null || echo "0")
        count=$((count + 1))
        echo "$count" > "$count_file"

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
            object-json)
                # Valid JSON but NOT an array — e.g. a GitHub API error body.
                # jq's `length` succeeds on objects, so this used to pass the
                # payload guard and then report PASS on zero green evidence.
                echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}'
                exit 0
                ;;
        esac
        ;;
    "pr merge")
        echo "merged" > "$WORKDIR/merged"
        exit 0
        ;;
    *)
        echo "fake gh: unhandled args: $*" >&2
        exit 1
        ;;
esac
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

run_case() {
    local name="$1"
    local repo="$2"
    local checks_state="$3"
    shift 3
    local extra_args=("$@")

    echo "$checks_state" > "$repo/checks-state"
    rm -f "$repo/merged" "$repo/checks-call-count" "$repo/create-count"

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

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
