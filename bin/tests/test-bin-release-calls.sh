#!/bin/bash
# Tests that no script in bin/ merges, pushes, releases or starts a workflow
# outside an explicit allowlist of guarded scripts (#312, D6).
#
# Usage:
#   bin/tests/test-bin-release-calls.sh
#
# The hook judges the command line an agent types. A script in bin/ runs
# without a prompt (Bash(~/.claude/bin/*)) and the hook sees only its name, so
# a call inside it is out of the hook's sight. That hole was found twice:
# git-push-pr-merge.sh merged into any --base, and a plugin release script
# (removed in #312) pushed the current branch and created a release. This scan turns a third such wrapper
# into a red test instead of a review finding.
#
# Scanned: every file under bin/ except the tests (bin/tests/, bin/test-*).
# A line that is only a comment does not count. A hit in a file that is not on
# ALLOWED fails the test, naming file and line; an allowlisted script carries
# the reason it is safe, which is the place to look when it changes.

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# Paths relative to bin/, with the reason each call in it is safe.
declare -A ALLOWED=(
    [git-push-pr-merge.sh]="pushes only the current branch; refuses a protected --base unless --no-merge"
    [git-cleanup-merged-branch.sh]="only deletes the merged feature branch on the remote"
    [hook-block-destructive.sh]="the guard: names the calls in its messages and comments"
    [lib/release_guard.py]="the guard: names the calls it refuses"
    [lib/commit_target.py]="reads command text; names git push in its documentation"
)

# The calls that release: a merge, a push, a release or tag, a workflow start.
RELEASE_CALL_RE='gh[[:space:]]+pr[[:space:]]+merge|gh[[:space:]]+release[[:space:]]+(create|edit)|gh[[:space:]]+workflow[[:space:]]+run|gh[[:space:]]+run[[:space:]]+rerun|gh[[:space:]]+api.*(/merge|/merges|dispatches|releases|git/refs|/rerun)|git(_filtered)?([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1"; echo "    expected: '$2'"; echo "    got:      '$3'"; FAIL=$((FAIL+1)); fi
}

# unguarded_calls <bin-dir>: `<path>:<line>` for every release call outside
# ALLOWED, one per line, sorted.
unguarded_calls() {
    local bin="$1" file rel
    while IFS= read -r file; do
        rel="${file#"$bin"/}"
        [[ -n "${ALLOWED[$rel]:-}" ]] && continue
        grep -InE "$RELEASE_CALL_RE" "$file" | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1 |
            sed "s|^|$rel:|"
    done < <(find "$bin" -type f ! -path "$bin/tests/*" ! -name 'test-*' | sort)
}

echo "== fixture: the scan finds what it should =="
F="$T/bin"
mkdir -p "$F/lib" "$F/tests"
printf '#!/bin/bash\ngh workflow run deploy.yml\n' > "$F/deploy.sh"
printf '#!/bin/bash\ngit add x\ngit push origin HEAD\ngh release create v1\n' > "$F/bump.sh"
printf '#!/bin/bash\ngit -C "$WT" push -u origin main\n' > "$F/lib/ship.sh"
printf '#!/bin/bash\ngh api -X PUT repos/o/r/pulls/1/merge\n' > "$F/merge-api.sh"
printf '#!/bin/bash\n# gh workflow run is refused by the hook\ngit status\n' > "$F/comment-only.sh"
printf '#!/bin/bash\ngit_filtered push -u origin "$B"\n' > "$F/git-push-pr-merge.sh"
printf '#!/bin/bash\ngh pr merge 1\n' > "$F/tests/test-x.sh"
printf '#!/bin/bash\ngh pr merge 1\n' > "$F/test-y.sh"
check "fixture reports every unlisted call, not comments, tests or ALLOWED" \
    $'bump.sh:3\nbump.sh:4\ndeploy.sh:2\nlib/ship.sh:2\nmerge-api.sh:2' "$(unguarded_calls "$F" | sort)"

echo "== this repository =="
check "every release call in bin/ is in an allowlisted script" "" "$(unguarded_calls "$REPO_DIR/bin")"

echo "== the allowlist names real files =="
for rel in "${!ALLOWED[@]}"; do
    check "ALLOWED entry exists: $rel" "yes" "$([[ -f "$REPO_DIR/bin/$rel" ]] && echo yes || echo no)"
done

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
