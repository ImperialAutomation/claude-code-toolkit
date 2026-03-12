---
name: update-tracking
description: Update a tracking PR with current sub-issue status and progress
argument-hint: <pr-number>
user-invocable: true
---

# Update Tracking PR Skill

Update a tracking/parent PR with the current status of all linked sub-issues.

## Input

The user provides a PR number: `$ARGUMENTS`

## Workflow

### Step 1: Fetch Current PR

```bash
~/.claude/bin/gh-save.sh /tmp/pr-$ARGUMENTS.json pr view $ARGUMENTS --json number,title,body,state
```

Use the Read tool to read `/tmp/pr-$ARGUMENTS.json` and extract:
- The parent issue number (from "Closes #XXX")
- All sub-issue numbers (from the tracking table)
- Current status of each sub-issue in the table

### Step 2: Check Status of All Sub-Issues

Fetch all sub-issue statuses in one batch (outputs a JSON array):
```bash
~/.claude/bin/batch-issue-status.sh <repo> [sub-issue-numbers...]
```

Also check merged and open PRs for all sub-issues in one batch:
```bash
~/.claude/bin/batch-pr-for-issues.sh <repo> [sub-issue-numbers...]
```

### Step 3: Build Updated Status Table

Map states to status indicators:
- **OPEN + no PR**: ⏳ Pending
- **OPEN + has PR draft**: 🔄 In Progress
- **OPEN + has PR ready**: 🔄 In Progress (PR #XXX)
- **CLOSED + PR merged**: ✅ Complete (PR #XXX merged)
- **CLOSED + no PR**: ✅ Complete

### Step 4: Calculate Progress

```
completed = count of ✅ items
total = count of all sub-issues
percentage = (completed / total) * 100
```

Format: `**Progress:** X of Y sub-issues complete (Z%)`

If 100%: `**Progress:** Y of Y sub-issues complete (100%)! 🎉`

### Step 5: Generate Updated PR Body

Replace the sub-issues table section with updated status:

```markdown
### Sub-Issues

| # | Sub-Issue | Status | PR |
|---|-----------|--------|-----|
| 1 | #123 - Foundation setup | ✅ Complete | PR #125 merged |
| 2 | #124 - Core feature | 🔄 In Progress | PR #130 |
| 3 | #125 - Integration | ⏳ Pending | - |

**Progress:** 1 of 3 sub-issues complete (33%)
```

### Step 6: Show Preview and Confirm

Display the changes to the user:

```markdown
## PR #[number] Update Preview

### Changes:
- Sub-issue #123: ⏳ Pending → ✅ Complete (PR #125 merged)
- Sub-issue #124: ⏳ Pending → 🔄 In Progress (PR #130)
- Progress: 0% → 33%

Apply this update? (y/n)
```

### Step 7: Update the PR

Only after user confirmation. Write the updated body to a temp file first, then use `--body-file` to avoid long inline arguments:
```bash
# Write updated body to temp file using the Write tool
# Then apply it:
gh pr edit $ARGUMENTS --body-file /tmp/pr_body.md
```

## Status Emoji Reference

| Emoji | Meaning | Condition |
|-------|---------|-----------|
| ⏳ | Pending | Issue open, no PR |
| 🔄 | In Progress | Issue open, has PR (draft or ready) |
| ✅ | Complete | Issue closed |
| ❌ | Blocked | Issue has "blocked" label |
| 🎉 | All Done | 100% complete (add to progress line) |

## Branch Structure Update

If sub-branches have been merged, update the branch structure section:

```markdown
## Branch Structure
```
develop
  ↑
issue-689-admin-dashboard (this PR)
  ↑
issue-690-foundation (✅ merged)
issue-691-home-page (✅ merged)
issue-692-backend (🔄 in progress)
issue-693-frontend (⏳ pending)
```
```

## Example Usage

```
/update-tracking 696
```

This will:
1. Fetch PR #696
2. Find all sub-issues referenced in the PR
3. Check current state of each sub-issue
4. Show a preview of changes
5. Update the PR body after confirmation

