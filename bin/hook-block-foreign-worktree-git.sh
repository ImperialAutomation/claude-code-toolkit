#!/usr/bin/env bash
# Pre-tool-use hook: refuse a destructive git operation aimed at a DIFFERENT
# worktree than the one the command runs from.
#
# Why this exists
# ---------------
# Linked worktrees share one repository but have independent working trees, each
# with its own uncommitted work. `git -C <other-worktree> checkout -- <files>`
# discards changes in a tree the caller is not working in and cannot see. The
# files come back at HEAD, so anything uncommitted there is gone — including work
# belonging to another session that is editing that tree right now.
#
# That is not hypothetical. A common route: a test runner copies sources into a
# long-lived container whose bind-mount points at ANOTHER worktree, so the run
# writes files into a tree the caller never touched. Cleaning up with
# `git -C <that-tree> checkout -- <files>` then restores to HEAD and takes any
# uncommitted work there with it. The correct cleanup is to save the originals
# aside first and restore those, i.e. restore to WHAT WAS THERE, not to HEAD.
#
# Scope: only cross-worktree operations. Inside your own tree these commands stay
# untouched — that is your own work to discard, and guarding it would add friction
# to routine reverts (e.g. undoing a mutation test) for no safety gain.
#
# hook-block-destructive.sh blocks `git checkout -- .` (whole tree) but not
# `git checkout -- <files>`, which is the form an agent naturally reaches for
# because it names the files it touched. This closes that path for the case where
# it can damage someone else's tree.
#
# Generic by design: nothing here names a project. Where a repository has its own
# safe alternative (an isolated test runner, a documented restore procedure),
# surface it through WORKTREE_GUARD_HINT from a small project wrapper rather than
# hardcoding it — a suggestion pointing at a script that does not exist in the
# caller's repo is worse than no suggestion.
#
# Configuration (environment variables):
#   WORKTREE_GUARD_HINT   Optional project-specific text appended to the block
#                         message, e.g. the repo's isolated test-runner command.
#
# Installation: register in settings.json under PreToolUse / matcher "Bash".
# Register a project wrapper when you have a hint to add, otherwise this script:
#   { "type": "command", "command": "~/.claude/bin/hook-block-foreign-worktree-git.sh" }
#
# Example wrapper:
#   #!/usr/bin/env bash
#   export WORKTREE_GUARD_HINT='Run tests in a disposable container instead:
#     bin/<your-isolated-test-runner>.sh <args>'
#   exec ~/.claude/bin/hook-block-foreign-worktree-git.sh
#
# Exit codes:
#   0 = allow
#   2 = block (reason to stderr, shown to Claude)

set -uo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

# Only look at git commands carrying an explicit -C/--git-dir target. Without one
# git acts on the current directory, which by definition is the caller's own tree
# and therefore out of scope.
#
# This is also the escape hatch. Working in another worktree the normal way --
# `cd <wt> && git reset --hard` -- carries no -C and so never gets here. Only the
# redundant `cd <wt> && git -C <wt> ...`, where the -C repeats the cd, is judged
# against this process's working directory and blocked. Rewriting it the natural
# way is the fix; the hook errs toward over-blocking, never under-blocking.
echo "$COMMAND" | grep -qE '(^|[;&|]|\s)git\s' || exit 0
echo "$COMMAND" | grep -qE -- '-C[= ]|--git-dir[= ]' || exit 0

# The destructive verbs: each one can discard uncommitted work in the target.
# `git restore` is the modern spelling of `checkout --` and is included for the
# same reason. `stash` is here because `stash push` REMOVES changes from the tree
# (`stash list`/`show` are read-only and filtered out below).
DESTRUCTIVE_RE='(checkout[[:space:]]+--|checkout[[:space:]]+-f|restore\b|reset\b|clean\b|stash\b)'

echo "$COMMAND" | grep -qE "$DESTRUCTIVE_RE" || exit 0

# Read-only stash subcommands. Bare `git stash` is NOT here: it stashes the whole
# tree, which is exactly the destructive case. Only the inspecting verbs are safe.
echo "$COMMAND" | grep -qE 'stash[[:space:]]+(list|show)\b' && exit 0

# Extract the -C target. Only the first is considered: git applies them
# cumulatively, and a command with several is unusual enough to warrant blocking
# on the first anyway.
TARGET=$(echo "$COMMAND" | grep -oE -- '-C[= ]+[^ ]+' | head -1 | sed -E 's/-C[= ]+//' || true)
[ -z "$TARGET" ] && exit 0

# Strip surrounding quotes and expand a leading ~.
TARGET="${TARGET%\"}"; TARGET="${TARGET#\"}"
TARGET="${TARGET%\'}"; TARGET="${TARGET#\'}"
case "$TARGET" in "~"/*) TARGET="$HOME/${TARGET#\~/}" ;; esac

# Resolve both sides to their worktree roots. If either resolution fails the
# command is not something this hook understands (not a repo, path does not
# exist), so allow it and let git report the real error.
TARGET_ROOT=$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$TARGET_ROOT" ] && exit 0

CWD_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$CWD_ROOT" ] && exit 0

# Same tree: this is the caller's own working directory, out of scope.
[ "$TARGET_ROOT" = "$CWD_ROOT" ] && exit 0

# Different trees that do not share a repository are unrelated checkouts. The
# worktree hazard is specifically about trees sharing one .git, where the sibling
# is easy to mistake for your own; leave the unrelated case alone.
TARGET_COMMON=$(git -C "$TARGET_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
CWD_COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
[ "$TARGET_COMMON" != "$CWD_COMMON" ] && exit 0

cat >&2 <<EOF
BLOCKED by hook-block-foreign-worktree-git.sh: this discards uncommitted work in
a worktree you are not working in.

  you are in : $CWD_ROOT
  target     : $TARGET_ROOT

Both are worktrees of the same repository, so the target may hold another
session's uncommitted changes. Restoring it to HEAD destroys them silently.

If you are undoing files you wrote into that tree yourself (e.g. a container
bind-mount wrote them back), restore to WHAT WAS THERE, not to HEAD: copy the
originals aside before the operation that writes, then copy them back and verify
by checksum.

Better still, avoid writing into the other tree in the first place.
EOF

[ -n "${WORKTREE_GUARD_HINT:-}" ] && printf '\n%s\n' "$WORKTREE_GUARD_HINT" >&2

cat >&2 <<'EOF'

If you genuinely need this, ask the user first — they may have work in progress
there.
EOF
exit 2
