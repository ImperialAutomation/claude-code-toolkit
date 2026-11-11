---
name: cleanup
description: Clean up after merging a PR - checkout base, fetch, pull, delete feature branch
user-invocable: true
---

# Cleanup After PR Merge

Clean up git repository after merging a PR by running the cleanup script.

## Usage

```
/cleanup
```

## What This Does

Run the cleanup script:
```bash
~/.claude/bin/git-cleanup-merged-branch.sh
```

The script will:
1. Auto-detect the current feature branch
2. Find the appropriate base branch (develop/master/main)
3. Checkout the base branch
4. Fetch the remote holding the base branch's upstream, then fast-forward to it
5. Delete the merged feature branch (with safety checks)
6. Optionally delete the remote branch (`--delete-remote` / `--keep-remote`)

## Toolkit repository

When the repository's main worktree is the live toolkit checkout (the one
`~/.claude/bin` points into), the script takes the toolkit route instead. Work
there is built in a linked worktree `../claude-code-toolkit-<N>`, and going live
means fast-forwarding the live checkout. Run `/cleanup` from either tree:

- **From the linked worktree:** cleans up that worktree's branch.
- **From the live checkout:** cleans up the branch you pass, or, without one, the
  single linked worktree on an `issue-*` branch merged into `origin/main`. With
  several merged worktrees it lists them and asks for the branch.

It checks everything first (live checkout clean and on `main`, fast-forward
possible, branch merged into `origin/main`, its worktree clean and unlocked) and
changes nothing when a check fails. Then it fast-forwards the live checkout to
`origin/main`, removes the worktree with `git worktree remove`, deletes the
branch with `git branch -d`, and handles the remote branch as below. A
squash-merged branch is refused; delete it by hand.

## Important

- Only run this AFTER merging the PR in GitHub
- The script uses `git branch -d` (safe delete) - will warn if branch isn't fully merged
- On a terminal it prompts before deleting remote branches. Without one (an agent
  session) it never prompts: the remote branch is kept, the delete command is
  printed, and it exits 0. Pass `--delete-remote` to delete it instead
- Checks for uncommitted changes and warns you; without a terminal it stops there
- `--help` prints the full usage, including the other no-terminal defaults
- The base branch must have an upstream; the script stops with the `git branch -u`
  remedy if it has none. It follows that upstream rather than assuming
  `origin/<base-name>`, so a linked worktree parked on its own branch works
- A base branch that has diverged from its upstream is reported, not merged: the
  fast-forward refuses rather than creating a merge commit on the base branch

## Manual Usage Options

```bash
# Auto-detect everything
~/.claude/bin/git-cleanup-merged-branch.sh

# Specify feature branch
~/.claude/bin/git-cleanup-merged-branch.sh issue-123-my-feature

# Specify both branches
~/.claude/bin/git-cleanup-merged-branch.sh issue-123-my-feature develop

# Also delete the remote branch, without a prompt
~/.claude/bin/git-cleanup-merged-branch.sh --delete-remote
```
