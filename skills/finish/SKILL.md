---
name: finish
description: Complete issue workflow - commit, close issue, merge to base branch, cleanup
argument-hint: [issue-number] [base-branch]
user-invocable: true
---

# Finish - INTERACTIVE COMMAND

**MUST wait for user confirmation at Step 4. MUST use ~/.claude/bin/git-find-base-branch for base branch detection.**

Complete the workflow for a finished issue: commit changes (including pre-commit hook modifications), close the issue, merge to base branch, and clean up.

## Input

The user provides: `$ARGUMENTS`

**Parameters (all optional):**
- **issue_number**: Issue number to complete
  - Empty/omitted → auto-detects from current branch name (e.g., 'issue-33-user-login' → issue 33)
  - 'auto' → explicitly auto-detect from current branch name (same as empty)
  - Provided number → uses that specific issue number
- **base_branch**: Target branch for merging
  - Empty/omitted → uses 'auto' algorithm to detect base branch (DEFAULT)
  - 'auto' → auto-detects base branch using ~/.claude/bin/git-find-base-branch script
  - Any other value → uses that specific branch name

## Examples

```bash
/finish              # Auto-detect issue + auto-detect base branch
/finish 33           # Use issue 33 + auto-detect base branch
/finish 33 master    # Use issue 33 + force merge into master
```

## Implementation Steps

**Step 1:** Get current branch name using `git branch --show-current`

**Step 2:** Determine issue number:
- If issue_number parameter is provided (not 'auto'), use that value
- If issue_number parameter is empty/omitted OR 'auto':
  - Extract from current branch name using regex pattern `issue-(\d+)-.*`
  - Example: 'issue-33-user-login' → issue number 33
  - If no match found, exit with error "Cannot detect issue number from branch name"

**Step 3:** Determine base branch:
- **CRITICAL**: ALWAYS use `~/.claude/bin/git-find-base-branch` script for auto-detection
- If base_branch parameter is empty/omitted → Run `~/.claude/bin/git-find-base-branch`
- If base_branch parameter is 'auto' → Run `~/.claude/bin/git-find-base-branch`
- If base_branch parameter is provided (not 'auto') → Use that specific value
- **NEVER use fallback to 'master'** - always use the script result

**Step 4: STOP — Ask for confirmation**
- Display: current branch, issue number, base branch
- Ask: "Proceed with finishing issue #[issue_number]? (y/N)"
- Wait for user response. Exit if not confirmed.

**Step 5:** Verification gate (MANDATORY — no shortcuts):
- Run the full test suite fresh — do not rely on earlier runs
- Show actual test output — no "tests pass" claims without evidence
- Check for validation command: `npm run validate:all`, `make validate`, etc.
- Execute if available and show output
- If ANY test or validation fails: fix at root cause, re-run, show output again
- Exit with error if verification fails — do not proceed to commit

**Step 6:** Stage and commit with pre-commit hook handling:
- Run `git add .`
- Attempt initial commit with message:
  ```
  feat: complete issue #[issue_number] implementation

  🤖 Generated with [Claude Code](https://claude.ai/code)

  Co-Authored-By: Claude <noreply@anthropic.com>
  ```
- **If commit fails due to pre-commit hooks:**
  - Detect that hooks modified files
  - Run `git add .` again to stage hook modifications
  - Amend the commit with `git commit --amend --no-edit`
  - Verify all changes are committed with `git diff-index --quiet HEAD --`

**Step 7:** Push current branch:
- Try `git push origin [current_branch]`
- If fails, use `git push -u origin [current_branch]` to create upstream

**Step 8:** Close GitHub issue:
- Run `gh issue close [issue_number] --comment "✅ Implementation complete and tested. All validation passed. Merging to [base_branch]."`

**Step 9:** Switch to base branch:
- Run `git checkout [base_branch]`
- Run `git pull origin [base_branch]`

**Step 10:** Merge issue branch:
- Run `git merge --no-ff [issue_branch] -m "Merge branch '[issue_branch]' - closes #[issue_number]"`

**Step 11:** Push merged changes:
- Run `git push origin [base_branch]`

**Step 12:** Delete branches:
- Delete local: `git branch -d [issue_branch]`
- Delete remote: `git push origin --delete [issue_branch]`

**Step 13:** Show success message with summary

