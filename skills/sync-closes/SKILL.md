---
name: sync-closes
description: Synchronize all sub-issues to Closes statements in tracking PR
argument-hint: <pr-number>
user-invocable: true
---

# Sync Closes Statements Skill

Ensure all sub-issues referenced in a tracking PR are included in the "Closes #XXX" statements, so they auto-close when the PR merges.

## Input

The user provides a PR number: `$ARGUMENTS`

## Workflow

### Step 1: Fetch PR Body

```bash
~/.claude/bin/gh-save.sh /tmp/pr-$ARGUMENTS.json pr view $ARGUMENTS --json number,title,body,baseRefName
```

Use the Read tool to read `/tmp/pr-$ARGUMENTS.json`.

### Step 2: Extract Current Closes Statements

Parse the PR body for existing closes:
```
Closes #689
Closes #690
Closes #691
```

Regex pattern: `[Cc]loses?\s+#(\d+)`

Also catch variations:
- `Closes #XXX`
- `closes #XXX`
- `Close #XXX`
- `Fixes #XXX`
- `fixes #XXX`
- `Resolves #XXX`

### Step 3: Extract Sub-Issues from Tracking Table

Find all issue references in the tracking table:
```markdown
| # | Sub-Issue | Status | PR |
|---|-----------|--------|-----|
| 1 | #690 - Foundation | ✅ | PR #701 |
| 2 | #691 - Home Page | ✅ | PR #702 |
| 3 | #724 - 🐛 Bug fix | ⏳ | - |
```

Extract: `#690`, `#691`, `#724`

Also scan for:
- Issues mentioned in "Related Issues" section
- Issues in branch structure section
- Bug issues added later

### Step 4: Compare and Find Missing

```
Current Closes: [689, 690, 691]
Found in Table: [689, 690, 691, 724]
Missing:        [724]
```

### Step 5: Show Diff to User

```markdown
## Sync Closes - PR #[number]

### Current Closes Statements
- Closes #689 (parent)
- Closes #690
- Closes #691

### Found in Tracking Table (not in Closes)
- ❌ #724 - 🐛 Bug: Webhook fails (MISSING)
- ❌ #725 - 🐛 Bug: Amount calc error (MISSING)

### Recommended Action
Add these to PR body:
```
Closes #724
Closes #725
```

Apply changes? (y/n)
```

### Step 6: Update PR Body

After confirmation, prepend missing Closes statements:

**Before:**
```markdown
Closes #689
Closes #690
Closes #691

This PR tracks...
```

**After:**
```markdown
Closes #689
Closes #690
Closes #691
Closes #724
Closes #725

This PR tracks...
```

Write the updated body to a temp file first, then use `--body-file`:
```bash
# Write updated body to temp file using the Write tool
# Then apply it:
gh pr edit $ARGUMENTS --body-file /tmp/pr_body.md
```

### Step 6b: Verify Issue States (if needed)

If you need to check whether any referenced issues are already closed, fetch their status in one batch:
```bash
~/.claude/bin/batch-issue-status.sh <repo> [issue-numbers...]
```

### Step 7: Verify

```bash
~/.claude/bin/gh-save.sh /tmp/pr-$ARGUMENTS-verify.json pr view $ARGUMENTS --json body
```

Use the Read tool to read `/tmp/pr-$ARGUMENTS-verify.json` and extract all `Closes #\d+` statements.

Show confirmation:
```markdown
## Sync Complete

✅ PR #[number] now closes [N] issues:
- #689 (parent)
- #690, #691, #692 (original sub-issues)
- #724, #725 (bugs added during development)

When this PR merges to [base-branch], all [N] issues will auto-close.
```

## Edge Cases

### Duplicate Detection
Don't add if already present (case-insensitive):
```
Closes #724
closes #724  ← Don't add duplicate
```

### Closed Issues
Warn about already-closed issues:
```markdown
⚠️ Warning: #691 is already closed (was it merged separately?)
```

### PR vs Issue References
Only add issues, not PR references:
```markdown
Skip: PR #701 (this is a PR, not an issue)
Add:  #724 (this is an issue)
```

## Example Usage

```
/sync-closes 696
```

Output:
```
## Sync Closes - PR #696

Found 3 issues not in Closes statements:
- #724 - 🐛 Bug: Settings display
- #725 - 🐛 Bug: Feature flags
- #726 - 🐛 Bug: System config

Add "Closes #724, #725, #726" to PR? (y/n)
```

