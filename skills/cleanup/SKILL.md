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
6. Optionally delete the remote branch

## Important

- Only run this AFTER merging the PR in GitHub
- The script uses `git branch -d` (safe delete) - will warn if branch isn't fully merged
- Will prompt before deleting remote branches
- Checks for uncommitted changes and warns you
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
```
