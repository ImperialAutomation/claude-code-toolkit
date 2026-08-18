#!/usr/bin/env bash
# Pre-tool-use hook: refuse a PR body that would fail a checklist status gate.
#
# Some repositories label agent-opened PRs and run a CI gate that requires a
# marked checklist section in the PR body, with every box ticked. When the
# section is missing the check only goes red minutes later, after the push has
# already landed. This hook runs the same logic locally, before the `gh` call,
# so the failure is immediate and legible.
#
# It covers `gh pr create` AND `gh pr edit` — the second path is easy to forget
# and is how tracking PRs are usually updated.
#
# The failure this prevents is not a forgotten section but a plausible-looking
# heading with invented items: that passes a gate which only counts ticked
# boxes, while quietly replacing the reviewed checklist with something else.
# A heading cannot satisfy this hook, which is the point.
#
# Generic by design: every repo-specific value is configuration. Point it at a
# project with a small wrapper that exports the variables below and execs this
# script (see the example at the bottom).
#
# Configuration (environment variables):
#   CHECKLIST_REPO_MATCH   Case-insensitive extended regex matched against the
#                          `--repo owner/name` argument. Required.
#   CHECKLIST_PATH_MATCH   Glob matched against $PWD, used when the command has
#                          no --repo. Optional; no PWD fallback if unset.
#   CHECKLIST_START        Opening marker. Default: <!-- AGENT-REVIEW:START -->
#   CHECKLIST_END          Closing marker. Default: <!-- AGENT-REVIEW:END -->
#   CHECKLIST_TEMPLATE     Template path quoted in error messages.
#                          Default: .github/PULL_REQUEST_TEMPLATE.md
#   CHECKLIST_HINT         Optional extra sentence appended to the
#                          missing-markers message (e.g. why the listed items
#                          are a floor and must not be swapped out).
#
# Installation: register in settings.json under PreToolUse / matcher "Bash".
# Register the project wrapper, not this script directly:
#   { "type": "command", "command": "~/.claude/bin/<project>-check-agent-review.sh" }
#
# Example wrapper:
#   #!/usr/bin/env bash
#   export CHECKLIST_REPO_MATCH='[^ ]*/myrepo\b'
#   export CHECKLIST_PATH_MATCH="$HOME/src/myrepo*"
#   exec ~/.claude/bin/hook-check-agent-review.sh
#
# Exit codes:
#   0 = allow
#   2 = block (reason to stderr, shown to Claude)

set -euo pipefail

REPO_MATCH="${CHECKLIST_REPO_MATCH:-}"
PATH_MATCH="${CHECKLIST_PATH_MATCH:-}"
START="${CHECKLIST_START:-<!-- AGENT-REVIEW:START -->}"
END="${CHECKLIST_END:-<!-- AGENT-REVIEW:END -->}"
TEMPLATE="${CHECKLIST_TEMPLATE:-.github/PULL_REQUEST_TEMPLATE.md}"
HINT="${CHECKLIST_HINT:-}"

# Without a repo matcher this hook cannot know where it applies. Stay silent
# rather than guessing: a hook that fires everywhere would be worse than none.
[ -z "$REPO_MATCH" ] && exit 0

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

# Only gh pr create / gh pr edit.
echo "$COMMAND" | grep -qE '(^|[;&|]|\s)gh\s+pr\s+(create|edit)\b' || exit 0

# --repo wins when present, otherwise fall back to the working directory.
if echo "$COMMAND" | grep -qE -- '--repo[= ]'; then
    echo "$COMMAND" | grep -qiE -- "--repo[= ]+$REPO_MATCH" || exit 0
else
    [ -z "$PATH_MATCH" ] && exit 0
    # shellcheck disable=SC2254  # glob match is intentional
    case "$PWD" in
        $PATH_MATCH) ;;
        *) exit 0 ;;
    esac
fi

# The body must come from a file. An inline/heredoc body cannot be inspected.
# `|| true` is load-bearing: under `set -e` a non-matching grep would abort the
# script with exit 1, which the harness reads as "allow" — silently skipping the
# very check this hook exists to make.
BODY_FILE=$(echo "$COMMAND" | grep -oE -- '--body-file[= ]+[^ ]+' | head -1 | sed -E 's/--body-file[= ]+//' || true)

if [ -z "$BODY_FILE" ]; then
    echo "BLOCKED by hook-check-agent-review.sh: pass the PR body via --body-file so the checklist can be verified before the call. Write the body to a file first, then re-run." >&2
    exit 2
fi

BODY_FILE="${BODY_FILE/#\~/$HOME}"

if [ ! -f "$BODY_FILE" ]; then
    echo "BLOCKED by hook-check-agent-review.sh: --body-file '$BODY_FILE' does not exist." >&2
    exit 2
fi

if ! grep -qF "$START" "$BODY_FILE" || ! grep -qF "$END" "$BODY_FILE"; then
    echo "BLOCKED by hook-check-agent-review.sh: the checklist markers are missing from '$BODY_FILE'. The gate parses the markers literally — a matching heading does NOT satisfy it. Read $TEMPLATE and copy the block between $START and $END verbatim, then tick each box truthfully against the diff.${HINT:+ $HINT}" >&2
    exit 2
fi

# Extract the section and apply the same item regex the CI gate uses.
SECTION=$(awk -v s="$START" -v e="$END" 'index($0,s){f=1;next} index($0,e){f=0} f' "$BODY_FILE")

ITEMS=$(echo "$SECTION" | grep -cE '^[ \t]*[-*][ \t]+\[[ xX]\]' || true)
UNCHECKED=$(echo "$SECTION" | grep -cE '^[ \t]*[-*][ \t]+\[ \]' || true)

if [ "$ITEMS" -eq 0 ]; then
    echo "BLOCKED by hook-check-agent-review.sh: no checklist items found between the markers in '$BODY_FILE'. Copy the items from $TEMPLATE." >&2
    exit 2
fi

if [ "$UNCHECKED" -gt 0 ]; then
    echo "BLOCKED by hook-check-agent-review.sh: $UNCHECKED of $ITEMS checklist item(s) still unticked in '$BODY_FILE'. Verify each against the diff and tick it — truthfully, not performatively. If an item does not apply, tick it and state why rather than deleting it." >&2
    exit 2
fi

exit 0
