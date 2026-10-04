#!/bin/bash
# Tests for hook-check-agent-review.sh.
#
# Usage:
#   bin/tests/test-hook-check-agent-review.sh
#
# Drives the REAL hook with a JSON payload on stdin (the same shape Claude Code
# sends) and asserts on its exit code: 2 = blocked, 0 = allowed.
#
# The subject here is CHECKLIST_CMD_MATCH: which commands the hook inspects at
# all. That is tested by sending a command with NO --body-file, which an
# inspected command is always blocked for. So BLOCK means "the selector matched
# and the hook looked", ALLOW means "the selector skipped this command". The
# checklist-content cases at the bottom cover the rest of the pipeline, because
# a selector that matched nothing would leave those green too.
#
# The false positive this file pins down (issue #77): the old default let the
# match start after any whitespace, so the pattern also hit when the text was an
# ARGUMENT rather than the command being run. Harmless on the bare `gh pr`
# default, but a project override that adds its PR wrapper's script name
# inherits the same shape — and then `ls ~/.claude/bin/ <wrapper>.sh` is blocked
# with "pass the PR body via --body-file". Seen twice in one session, each time
# costing a rephrase of a read-only command. The wrapper-override cases are
# therefore the load-bearing ones; the bare-default cases exist to prove the
# anchor did not cost any real detection.
#
# When adding a case, check it actually constrains the hook: break the matching
# line in hook-check-agent-review.sh, confirm THIS test goes red, then revert.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${HOOK_UNDER_TEST:-$SCRIPT_DIR/../hook-check-agent-review.sh}"

if [ ! -x "$HOOK" ]; then
    echo "❌ hook not executable: $HOOK" >&2
    exit 2
fi

pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A body file that satisfies every content check, so any block in the selector
# cases can only come from the selector itself.
GOOD_BODY="$TMP/good-body.md"
cat >"$GOOD_BODY" <<'EOF'
## Summary

Adds the thing.

<!-- AGENT-REVIEW:START -->
- [x] Read the diff end to end
- [x] Tests cover the changed behaviour
<!-- AGENT-REVIEW:END -->
EOF

# Same markers, one box left unticked.
UNTICKED_BODY="$TMP/unticked-body.md"
cat >"$UNTICKED_BODY" <<'EOF'
<!-- AGENT-REVIEW:START -->
- [x] Read the diff end to end
- [ ] Tests cover the changed behaviour
<!-- AGENT-REVIEW:END -->
EOF

# A heading that looks like the checklist but carries no literal markers. The
# gate parses the markers, so this must not satisfy the hook.
HEADING_BODY="$TMP/heading-body.md"
cat >"$HEADING_BODY" <<'EOF'
## Agent review

- [x] Read the diff end to end
- [x] Tests cover the changed behaviour
EOF

# Every case runs against this repo, so --repo matching is never the reason a
# case is skipped.
export CHECKLIST_REPO_MATCH='[^ ]*/toolkit\b'

#  CMD_MATCH_OVERRIDE, when non-empty, is exported to the hook for that one case.
#  Deliberately NOT a subshell: counters incremented in a subshell never reach
#  the parent, so a failing wrapper case would print FAIL and still let the
#  script exit 0 — green while asserting nothing.
CMD_MATCH_OVERRIDE=""

run() { # run "<command>" <BLOCK|ALLOW> "<why>"
    local cmd="$1" expect="$2" why="${3:-}" rc got
    if [ -n "$CMD_MATCH_OVERRIDE" ]; then
        printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' \
            | CHECKLIST_CMD_MATCH="$CMD_MATCH_OVERRIDE" "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | "$HOOK" >/dev/null 2>&1
    fi
    rc=$?
    got=ALLOW
    [ "$rc" -eq 2 ] && got=BLOCK
    if [ "$got" = "$expect" ]; then
        pass=$((pass + 1))
        printf 'PASS  %-5s %s\n' "$got" "$cmd"
    else
        fail=$((fail + 1))
        printf 'FAIL  got=%-5s want=%-5s %s%s\n' "$got" "$expect" "$cmd" "${why:+  ($why)}"
    fi
}

REPO='--repo ImperialAutomation/toolkit'

echo "== default selector: the real PR commands are inspected =="
# No --body-file, so an inspected command blocks. These are the calls the hook
# exists for; if the anchor broke any of them it would stop checking entirely.
run "gh pr create $REPO --title t --body 'inline'"        BLOCK "bare create must be inspected"
run "gh pr edit 1 $REPO --body 'inline'"                  BLOCK "edit is the easy-to-forget path"
run "gh    pr   create $REPO --body x"                    BLOCK "extra whitespace is still the command"
# After a command separator the next word is a command again, so the hook must
# keep looking past the first one.
run "git fetch && gh pr create $REPO --body x"            BLOCK "command after &&"
run "git fetch; gh pr create $REPO --body x"              BLOCK "command after ;"
run "git fetch | gh pr create $REPO --body x"             BLOCK "command after |"
# A leading VAR=value assignment does not stop `gh` from being the command.
run "GH_TOKEN=x gh pr edit 1 $REPO --body x"              BLOCK "one env assignment"
run "GH_TOKEN=x GH_HOST=h gh pr create $REPO --body x"    BLOCK "several env assignments"
run "git fetch && GH_TOKEN=x gh pr create $REPO --body x" BLOCK "assignment after a separator"

echo
echo "== default selector: the name as an ARGUMENT is not a PR call =="
# The old default's `\s` alternative matched here; nothing is being opened.
run "echo gh pr create $REPO"                             ALLOW "echoing the words"
run "grep -rn 'gh pr create' docs/ $REPO"                 ALLOW "searching for the pattern"
run "printf '%s' 'run gh pr create next' $REPO"           ALLOW "the words inside a quoted string"

echo
echo "== wrapper override: the script name as an ARGUMENT is not a PR call =="
# This is issue #77's actual report. A project that opens PRs through a wrapper
# must extend the selector with the wrapper's name, because the wrapper's own
# name never contains `gh pr create`. The override below is the one the hook's
# header now documents: the wrapper name slotted into the SAME anchor the
# default uses. The old, unanchored shape is pinned as its own case at the end
# of this block, so the header's advice is tested rather than just asserted.
#
# The tilde is deliberately NOT expanded in these commands: the hook receives
# the command text exactly as the agent typed it, tilde and all, so an expanded
# $HOME here would test a string that never reaches the hook in practice.
CMD_MATCH_OVERRIDE='(^|[;&|]\s*)([A-Za-z_][A-Za-z0-9_]*=[^ ]*\s+)*([^ ]*git-push-pr-merge\.sh|gh\s+pr\s+(create|edit))\b'
run "ls ~/.claude/bin/ git-push-pr-merge.sh $REPO"                    ALLOW "a plain listing"
run "grep -n 'pr merge' ~/.claude/bin/git-push-pr-merge.sh $REPO"     ALLOW "reading the script"
run "cat bin/git-push-pr-merge.sh $REPO"                              ALLOW "reading the script"
# ...while the wrapper actually being RUN is still inspected, which is the whole
# reason the override exists.
# shellcheck disable=SC2088  # the literal tilde IS the input under test
run "~/.claude/bin/git-push-pr-merge.sh $REPO --title t"              BLOCK "wrapper run, no --body-file"
run "git fetch && ~/.claude/bin/git-push-pr-merge.sh $REPO --title t" BLOCK "wrapper run after &&"
run "bin/git-push-pr-merge.sh $REPO --title t"                        BLOCK "wrapper run via relative path"

# The old, unanchored override shape, kept as a live case so the difference is
# demonstrable rather than described. It blocks a plain listing — the exact
# false positive — and that is asserted here as the known-bad behaviour of a
# shape the header tells projects not to copy.
CMD_MATCH_OVERRIDE='(^|[;&|]|\s)([^ ]*git-push-pr-merge\.sh|gh\s+pr\s+(create|edit))\b'
run "ls ~/.claude/bin/ git-push-pr-merge.sh $REPO"                    BLOCK "unanchored override: the bug, pinned"
CMD_MATCH_OVERRIDE=""

echo
echo "== repo scoping: an inspected command outside the repo is left alone =="
run "gh pr create --repo someone/other --body x"           ALLOW "different repo"
run "gh pr create --body x"                                ALLOW "no --repo and no CHECKLIST_PATH_MATCH"

echo
echo "== checklist content: the rest of the pipeline still gates =="
run "gh pr create $REPO --body-file $GOOD_BODY"            ALLOW "markers present, all ticked"
run "gh pr create $REPO --body-file=$GOOD_BODY"            ALLOW "--body-file= spelling"
run "gh pr create $REPO --body-file $UNTICKED_BODY"        BLOCK "one box unticked"
run "gh pr create $REPO --body-file $HEADING_BODY"         BLOCK "a heading must not satisfy the markers"
run "gh pr create $REPO --body-file $TMP/missing.md"       BLOCK "body file does not exist"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
