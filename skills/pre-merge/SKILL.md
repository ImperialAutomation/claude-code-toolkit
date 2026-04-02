---
name: pre-merge
description: Combined quality gate that orchestrates review, tests, verification, and AC checks before merge
argument-hint: "[PR-number]"
user-invocable: true
---

# Pre-Merge Quality Gate

Orchestrates all quality checks into a single gate report. This is a reporting tool — it does NOT auto-fix or auto-merge. The user decides what to act on.

## Input

`$ARGUMENTS` can be:
- **A PR number**: scope to that PR's changes
- **Empty**: scope to current branch vs base branch

## Phase 1: Determine Scope

### If PR number provided:
```bash
~/.claude/bin/gh-save.sh /tmp/pre-merge-pr.json pr view $ARGUMENTS --json number,title,body,baseRefName,headRefName,files
```
Read `/tmp/pre-merge-pr.json` to get the base branch, head branch, changed files, and PR body.

### If no PR number:
```bash
~/.claude/bin/git-find-base-branch
```
Use the current branch vs the detected base branch. Get changed files from:
```bash
git diff --name-only $(git merge-base HEAD <base-branch>)..HEAD
```

Store: `base_branch`, `head_branch`, `changed_files`, `pr_body` (if available).

## Phase 2: Code Review

Run the `/review` skill logic on the branch changes:

1. Get the diff: `git diff $(git merge-base HEAD <base_branch>)..HEAD`
2. Run automated checks (Phase 2 of `/review`): debug statements, secrets, large changes, TODOs
3. Run structural review (Phase 3 of `/review`): DRY, magic values, error handling, pattern consistency
4. Run test coverage mapping (Phase 4 of `/review`)

Record the verdict: PASS / WARNINGS / NEEDS WORK

## Phase 3: Tests

Run the `/test` skill logic in affected mode:

1. Map changed files to test files (naming conventions + import analysis)
2. Run Tier 1: direct affected tests
3. If Tier 1 passes and integration-sensitive files changed: run Tier 2

Record: passed/failed/skipped counts, verdict

## Phase 4: Runtime Verification

Run a quick runtime check (equivalent to `/verify quick`):

1. **Container health** (if Docker detected):
   ```bash
   ~/.claude/bin/docker-health-check.sh
   ```

2. **API smoke test** (if running server detected):
   ```bash
   ~/.claude/bin/smoke-test.sh
   ```

3. **Migration check** (if alembic detected):
   - Compare `alembic current` with `alembic heads`

Skip any check that is not applicable. Record per-check status.

## Phase 5: Acceptance Criteria Check

**Only runs if a linked issue is found.**

1. Extract issue number from PR body (`Closes #N`) or branch name (`issue-N-...`)
2. Fetch the issue:
   ```bash
   ~/.claude/bin/gh-save.sh /tmp/pre-merge-issue.json issue view <N> --json body
   ```
3. Parse acceptance criteria from issue body (checkboxes, numbered lists, AC heading)
4. For each criterion: search for a test that verifies it, or check if the implementation satisfies it
5. Generate AC coverage table with VERIFIED / UNVERIFIED status

If no issue found or no AC in the issue: mark as SKIP.

## Phase 6: Gate Report

Generate the combined report:

```markdown
## Pre-Merge Quality Gate

**Branch:** <head_branch> → <base_branch>
**Files changed:** <count>

### Gate Results

| Gate | Status | Summary |
|------|--------|---------|
| Code Review | PASS / WARNINGS / NEEDS WORK | <finding count and top severity> |
| Tests | PASS / FAIL | <passed>/<total> |
| Runtime | PASS / WARN / FAIL / SKIP | <check summary> |
| Acceptance | PASS / WARN / SKIP | <verified>/<total> criteria |

### Verdict: **<READY TO MERGE / NEEDS ATTENTION / NOT READY>**

<One-line summary of what needs attention, if anything>
```

**Verdict rules:**
- **READY TO MERGE**: all gates PASS or SKIP
- **NEEDS ATTENTION**: any gate has WARNINGS/WARN but no FAIL/NEEDS WORK
- **NOT READY**: any gate has FAIL or NEEDS WORK

### Detailed sections (only for non-PASS gates):

For each gate that is not PASS, include the detailed output:
- Code Review: findings table from `/review`
- Tests: failure details
- Runtime: which checks failed and why
- Acceptance: AC table with UNVERIFIED items highlighted

**This is a reporting gate. Do NOT auto-fix issues or suggest automatic remediation. Present the facts and let the user decide.**
