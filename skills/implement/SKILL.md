---
name: implement
description: Implement a GitHub issue with automated PR creation
argument-hint: <issue-number>
user-invocable: true
---

# Implement GitHub Issue

Implement GitHub issue with automated workflow.

## Input

The user provides an issue number: `$ARGUMENTS`

MUST use ~/.claude/bin/git-find-base-branch for base branch detection for the PR.

## Phase 1: Discovery & Planning

1. Fetch issue details: `~/.claude/bin/gh-save.sh /tmp/issue-$ARGUMENTS.json issue view $ARGUMENTS --json title,body,labels`, then use the Read tool to read it
2. **Check for linked Sentry issues** in the issue body:
   * Look for Sentry issue references like `PAM-BACKEND-X`, Sentry URLs, or "Sentry Issues" sections
   * If found, note the Sentry issue IDs — these will be referenced in commit messages and the PR body for automatic resolution
   * Store as a list, e.g. `SENTRY_ISSUES=["PAM-BACKEND-G", "PAM-BACKEND-H"]`
3. Read AND verify understanding of existing code:
   * Read all CLAUDE.md files (root, frontend, backend if they exist)
   * Read the ACTUAL source files you plan to modify
   * Check what attributes/methods ACTUALLY exist on models you'll use
   * Find existing patterns for similar functionality (grep/search)
   * NEVER assume a model has an attribute - READ the model first
4. **Parse acceptance criteria** from the issue body:
   * Look for checkbox patterns: `- [ ]` / `- [x]`
   * Look for numbered lists under an "Acceptance Criteria" heading
   * Fallback: bullet points under an AC heading
   * If no AC found: warn "No acceptance criteria found — consider running `/refine` first"
   * Store the AC list for verification in Phase 3

5. Create detailed implementation plan as **numbered steps of max 5 minutes each**:
   * Issue requirements understanding
   * Existing code patterns you found and will follow
   * Files to modify/create
   * Per step: what test to write, what code to implement, what to verify
   * Each step must be self-contained: one test + one piece of functionality + one commit
   * Steps must be ordered so each builds on the previous commit

STOP HERE and ask for confirmation before proceeding to implementation.

## Phase 2: Branch & TDD Implementation

1. Create and checkout branch: `issue-$ARGUMENTS-<descriptive-label>`
2. Before writing new code, verify your assumptions:
   * If using model attributes, confirm they exist: `grep "attribute_name" models.py`
   * If importing classes, confirm they exist: `python -c "from module import Class"`
   * If ANY verification fails, STOP and reassess your approach

### Execute each plan step using the TDD cycle:

**For each step in the plan, follow this exact sequence:**

1. **RED — Write a failing test first**
   * Write the minimal test that demonstrates the desired behavior
   * Run the test — it MUST fail
   * If it passes immediately, the test proves nothing — rewrite it
   * Show the failing output

2. **GREEN — Write the simplest code to pass**
   * Implement only what's needed to make the test pass
   * Run the test — it MUST pass now
   * Show the passing output

3. **REFACTOR — Clean up, then commit**
   * Remove duplication, improve naming if needed
   * Run tests again to confirm nothing broke
   * Commit: `~/.claude/bin/git-commit.sh "descriptive message for this step"`
   * If SENTRY_ISSUES were found in Phase 1, add `Fixes <ID>` to the **final commit only** (the last step before PR creation), e.g.: `~/.claude/bin/git-commit.sh "final step description" "" "Fixes PAM-BACKEND-G" "Fixes PAM-BACKEND-H"`

4. **Move on — Focus shifts to the next step**
   * Do not revisit completed steps unless a later test breaks them
   * Each commit is a checkpoint — previous context can be released

**When TDD doesn't apply** (config files, migrations, static assets):
* Implement the change, verify it works, commit. Skip red/green.

### Self-review between steps

After every 2-3 steps, briefly check:
* Are tests testing real behavior or just that code runs without errors?
* Are mocks hiding bugs? (only mock external services)
* Do fixtures use realistic data?

Fix weaknesses immediately before continuing.

## Phase 3: Final Verification (MANDATORY)

DO NOT SKIP THIS PHASE. NO COMPLETION CLAIMS WITHOUT FRESH EVIDENCE.

### Step 1: Run targeted tests for your changes

```bash
~/.claude/bin/project-test.sh tests/path/to/your_test.py -v
```

* Run your feature's tests fresh — do not rely on earlier green runs
* DO NOT run the entire test suite — that runs in CI after PR creation
* Paste the actual output in your response
* If ANY test fails, fix at root cause and re-run

### Step 2: Run project validation

* Check for: `npm run validate:all`, `make validate`, `./validate.sh`
* If validation command exists, run it and show output
* If backend schemas were modified, ensure OpenAPI is regenerated
* Fix any errors before proceeding

### Step 2b: Project integration verification (if defined)

Check the project's CLAUDE.md for an **Integration Verification** section. If it exists and defines file patterns with verification steps:

1. Compare the files you modified against the trigger patterns
2. If any modified files match a trigger pattern, run the verification steps defined in CLAUDE.md
3. If no files match any trigger patterns, skip this step
4. If the CLAUDE.md has no Integration Verification section, skip this step

This step ensures that Docker containers still start, migrations are applied, and API health checks pass after implementation — but only when relevant files were changed.

### Step 2c: Acceptance criteria verification

**Skip if no AC were parsed in Phase 1.**

For each acceptance criterion from Phase 1, find evidence that it is satisfied:

1. Search for a test that explicitly verifies this criterion (by name, assertion, or test docstring)
2. If no test found, check if the implementation clearly satisfies it (e.g., a config change, a UI element)

Generate an AC verification table:

| # | Criterion | Evidence | Status |
|---|-----------|----------|--------|
| 1 | User can reset password | `test_password_reset_flow` (PASS) | VERIFIED |
| 2 | Reset link expires after 24h | `test_expired_token` (PASS) | VERIFIED |
| 3 | Email uses branded template | No test, visual check needed | UNVERIFIED |

For UNVERIFIED items:
- If testable: write a test, run it, update the table
- If not testable (visual, manual): flag for manual review in PR body

### Step 2d: Self-review (max 2 iterations)

Run the `/review` analysis (Phases 2-4: automated checks, structural review, test coverage mapping) on the current branch diff:

```bash
git diff $(git merge-base HEAD <base-branch>)..HEAD
```

1. If findings with severity > INFO are found:
   - Fix the issues automatically
   - Re-run the targeted tests from Step 1 to catch regressions
   - Run the review analysis again
2. **Max 2 fix iterations.** If findings remain after 2 iterations:
   - Include them in the PR body under a "Known Issues" section
   - Do not continue fixing — proceed to Step 3

This prevents infinite fix loops while still catching obvious issues before PR creation.

### Step 3: Verify claims with evidence

Before proceeding to PR creation:
* Every claim ("works", "tested", "complete") must have matching test output
* No "should work", "probably fine", or "seems correct" — only proven facts
* If you cannot prove a claim, go back and add the missing test

## Phase 4: PR Creation

1. Determine base branch: `~/.claude/bin/git-find-base-branch`
2. Write PR body to `/tmp/pr-body.md` using the Write tool (include `Closes #$ARGUMENTS` + implementation summary + test checklist). If SENTRY_ISSUES were found in Phase 1, add a "Sentry" section: `## Sentry\nResolves: PAM-BACKEND-G, PAM-BACKEND-H`
3. Push + create PR in one command:
   `~/.claude/bin/git-push-pr-merge.sh --base <base-branch> --title "<concise description>" --body-file /tmp/pr-body.md --no-merge`
4. Return PR URL for review

## Phase 5: Epic Tracking Update (automatic, if applicable)

After PR creation, check if this issue is a sub-issue of an epic and update the tracking PR accordingly.

### Step 1: Detect Parent Epic

Read the issue body (already fetched in Phase 1) and search for parent references:
- `Parent issue: #XXX`
- `Part of #XXX`
- `Related to #XXX`

If no parent reference found → skip this phase entirely (not a sub-issue).

### Step 2: Find Tracking PR

```bash
~/.claude/bin/find-tracking-pr.sh <repo> $PARENT_ISSUE
```

If no tracking PR exists → skip (inform user: "Note: no tracking PR found for parent #XXX").

### Step 3: Update Tracking PR

Read the tracking PR body and make two updates:

**3a. Ensure Closes statement exists:**
If `Closes #$ARGUMENTS` is not already in the PR body, add it after the last existing `Closes` line.

**3b. Update tracking table row:**
Find the row for this issue (`#$ARGUMENTS`) in the tracking table and update:
- Status: `⏳ Pending` → `🔄 In Progress`
- PR column: `-` → `PR #[new-pr-number]`

If no row exists for this issue, add one:
```markdown
| N | #$ARGUMENTS - [Issue title] | 🔄 In Progress | PR #[new-pr-number] |
```

**3c. Write updated body and apply:**
```bash
# Write updated body to /tmp/pr_body.md using the Write tool
gh pr edit [tracking-pr-number] --body-file /tmp/pr_body.md
```

### Step 4: Confirm

```markdown
✅ Updated tracking PR #[tracking-pr-number] for parent epic #[parent-issue]
   - Status: 🔄 In Progress
   - Linked: PR #[new-pr-number]
```
