#!/usr/bin/env bash
# Regression tests for git-push-pr-merge.sh's CI gate (issue #13).
#
# Covers:
#   1. No checks configured           -> CI_GATE: SKIP, merges
#   2. Required checks pass           -> CI_GATE: PASS, merges
#   3. A required check fails         -> CI_GATE: FAIL, no merge, exit non-zero
#   4. Checks stuck pending (timeout) -> CI_GATE: TIMEOUT, no merge, exit non-zero
#   5. --no-ci-wait                   -> merges without checking, regardless of check state
#   6. --no-merge                     -> CI gate skipped entirely, unaffected
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
#   - `gh pr create` prints a fake PR URL
#   - `gh pr checks` behavior driven by $1/checks-state (see scenarios below)
#   - `gh pr merge` records that merge happened into $1/merged
make_fake_gh() {
    local workdir="$1"
    local bindir="$workdir/bin"
    mkdir -p "$bindir"

    cat > "$bindir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
WORKDIR="$FAKE_GH_WORKDIR"

case "$1 $2" in
    "pr create")
        echo "https://github.com/example/repo/pull/42"
        exit 0
        ;;
    "pr checks")
        # checks-state file contains one of: none, pass, fail, pending-then-pass, pending-forever, ratelimit-then-pass
        state=$(cat "$WORKDIR/checks-state" 2>/dev/null || echo "none")
        count_file="$WORKDIR/checks-call-count"
        count=$(cat "$count_file" 2>/dev/null || echo "0")
        count=$((count + 1))
        echo "$count" > "$count_file"

        case "$state" in
            none)
                echo "no checks reported on the '42' pull request" >&2
                exit 1
                ;;
            pass)
                echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                exit 0
                ;;
            fail)
                echo '[{"name":"build","state":"FAILURE","bucket":"fail"}]'
                exit 0
                ;;
            pending-then-pass)
                if [ "$count" -lt 2 ]; then
                    echo '[{"name":"build","state":"PENDING","bucket":"pending"}]'
                else
                    echo '[{"name":"build","state":"SUCCESS","bucket":"pass"}]'
                fi
                exit 0
                ;;
            pending-forever)
                echo '[{"name":"build","state":"PENDING","bucket":"pending"}]'
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
    rm -f "$repo/merged" "$repo/checks-call-count"

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

    if echo "$haystack" | grep -qF "$needle"; then
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

# --- Scenario 1: no checks configured -> skip gate, merge proceeds ---
repo1=$(make_repo)
make_fake_gh "$repo1"
echo "Test PR body" > "$repo1/body.md"
run_case "no checks" "$repo1" "none"
assert_contains "no checks: CI_GATE line" "CI_GATE: SKIP" "$(cat "$repo1/last-output.txt")"
assert_exit "no checks: exit code" "0" "$(cat "$repo1/last-exit.txt")"
assert_file_present "no checks: merge happened" "$repo1/merged"
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

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
