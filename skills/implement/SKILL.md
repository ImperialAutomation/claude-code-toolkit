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

## Tool Rules

- Use Glob/Grep/Read instead of Bash equivalents (find, grep, cat, head, tail)
- Use Write/Edit for file creation and modification — not Bash (echo, cat, sed, awk)
- Bash is for: git, gh, npm, npx, docker, python, ruff, uv, and `~/.claude/bin/` scripts only
- For venv binaries (python, pytest, alembic, pip), use `~/.claude/bin/venv-run.sh <cmd>` or `~/.claude/bin/project-test.sh`
- Never use `python3 -c` for file operations — use Read/Edit/Grep instead

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

## Phase 3: Final Verification (MANDATORY — delegated to sub-agent)

DO NOT SKIP THIS PHASE. NO COMPLETION CLAIMS WITHOUT FRESH EVIDENCE.

**Verification runs in a sub-agent with its own context window.** Test output, validation output, review findings, and smoke test logs pollute the orchestrator's context window heavily. Delegating to a sub-agent keeps the main session lightweight for the PR creation phase and avoids context degradation mid-implementation.

The orchestrator (main session) only:
- Spawns the verification sub-agent
- Receives a structured summary
- Decides whether to proceed to Phase 4 or fix issues

### Step 1: Gather context for the sub-agent

Before spawning, collect:
- `base_branch` — from `~/.claude/bin/git-find-base-branch`
- `acceptance_criteria` — the AC list parsed in Phase 1 (or "none" if not found)
- `modified_files` — `~/.claude/bin/git-diff-base.sh <base-branch>`
- `has_backend_endpoints` — true if any modified file matches `**/api/**`, `**/routes/**`, `**/endpoints/**`
- `has_schema_changes` — true if any modified file matches `**/schemas/**`, `**/models/**`, `**/migrations/**`

### Step 2: Spawn verification sub-agent

Use the Task tool with `subagent_type: "general-purpose"` and the prompt below. Wait for completion (do NOT use `run_in_background: true` — Phase 4 depends on the result).

```
## Task: Final verification for issue #$ARGUMENTS

Verify the implementation on the current branch is ready for PR creation.
Run each step below and report results in the structured format at the end.

## Context
- Issue: #$ARGUMENTS
- Base branch: <base_branch>
- Modified files: <modified_files>
- Acceptance criteria: <acceptance_criteria or "none parsed">
- Has backend endpoints: <true/false>
- Has schema changes: <true/false>

Project policies — read these BEFORE verifying:
- ./CLAUDE.md (project root)
- ./frontend/CLAUDE.md (if frontend changes)
- ./backend/app/CLAUDE.md or ./backend/CLAUDE.md (if backend changes)

## Tool Rules
- Use Glob/Grep/Read instead of Bash equivalents (find, grep, cat, head, tail)
- Use Write/Edit for file creation and modification — not Bash (echo, cat, sed, awk)
- Bash is for: git, gh, npm, npx, docker, python, ruff, uv, and `~/.claude/bin/` scripts only
- For venv binaries, use `~/.claude/bin/venv-run.sh <cmd>` or `~/.claude/bin/project-test.sh`

## Verification Steps

### Step A: Targeted tests
Run ONLY tests relevant to the modified files — never the full suite:
`~/.claude/bin/project-test.sh tests/path/to/your_test.py -v`
If any test fails, fix at root cause and re-run.

### Step B: Project validation
Check for one of: `npm run validate:all`, `make validate`, `./validate.sh`.
If found, run it. If backend schemas changed, ensure OpenAPI is regenerated.
Fix any errors before proceeding.

### Step C: Integration verification (conditional)
Check the project's CLAUDE.md for an **Integration Verification** section.
If it exists AND modified files match a trigger pattern, run the defined steps.
Otherwise skip.

### Step D: Acceptance criteria verification (skip if AC = "none parsed")
For each criterion, find evidence (test name, assertion, config/UI change).
Produce a table:

| # | Criterion | Evidence | Status |
|---|-----------|----------|--------|

For UNVERIFIED items: write a test if testable, else flag for manual review.

### Step E: Self-review (max 2 fix iterations)
Run the `/review` analysis on the branch diff:
`~/.claude/bin/git-diff-base.sh --patch <base-branch>`

If findings with severity > INFO:
- Fix automatically, re-run Step A, re-run review
- Max 2 iterations — remaining findings go into the PR body as "Known Issues"

### Step F: API smoke test (skip if has_backend_endpoints = false)
1. Restart API container: `docker restart pam_api`, then wait for it to come back up: `~/.claude/bin/wait-for-healthy.sh pam_api`
2. Seed E2E accounts if needed: `npm run db:seed:e2e`
3. Login: `./scripts/api-login.sh premium` then read `/tmp/pam-token.txt`
4. Call each new/modified endpoint, verify 2xx + correct JSON structure
5. On 500: check `docker logs pam_api --tail 30`, fix root cause, re-run

## Execute — do not describe or delegate

You are the agent that performs this verification. There is no other agent to hand off to or wait for. Actually run each verification step below — do not respond with a description of what you would do or a status update implying work is happening elsewhere.

## Response Format

Respond with EXACTLY this format ONLY once you have actually performed the verification steps above — not as a status update:

VERIFICATION_COMPLETE:
TESTS: PASS/FAIL — <passed>/<total> tests (e.g., 12/12)
VALIDATION: PASS/FAIL/SKIP — <validate command used or reason for skip>
INTEGRATION: PASS/FAIL/SKIP — <what was verified or reason for skip>
AC_VERIFIED: <verified count>/<total count> or SKIP — <one-line summary>
REVIEW: PASS/WARN/FAIL — <iterations used, findings remaining>
SMOKE_TEST: PASS/FAIL/SKIP — <endpoints tested or reason for skip>
KNOWN_ISSUES: <list of remaining review findings, or "none">
AC_UNVERIFIED: <list of UNVERIFIED criteria needing manual review, or "none">

FAILED:
ERROR: <description of what blocked verification>
STEP: <which step failed>
LAST_OUTPUT: <relevant error output>
```

### Step 3: Handle sub-agent result

**On VERIFICATION_COMPLETE:**
- If any of TESTS/VALIDATION/INTEGRATION/REVIEW/SMOKE_TEST is FAIL → fix the issue at root cause, then re-run Step 2 (spawn a fresh verification sub-agent — do NOT proceed to Phase 4 with failures)
- If all are PASS/WARN/SKIP → store `KNOWN_ISSUES` and `AC_UNVERIFIED` for inclusion in the PR body, proceed to Phase 4

**On FAILED:**
- Investigate the error in the orchestrator (the sub-agent couldn't complete verification)
- Fix and re-spawn

### Step 4: Verify claims with evidence

Before proceeding to PR creation:
* The sub-agent's structured response IS your evidence — no "should work" or "probably fine"
* If any claim in the response is unsupported (e.g., TESTS: PASS without numbers), re-spawn the sub-agent

## Phase 4: PR Creation

1. Determine base branch: `~/.claude/bin/git-find-base-branch`
2. Write PR body to `/tmp/pr-body.md` using the Write tool. Include:
   - `Closes #$ARGUMENTS`
   - Implementation summary
   - Test checklist (test counts from the verification sub-agent's TESTS line)
   - If `KNOWN_ISSUES` from Phase 3 is not "none": add a `## Known Issues` section listing them
   - If `AC_UNVERIFIED` from Phase 3 is not "none": add a `## Manual Review Needed` section listing the UNVERIFIED criteria
   - If SENTRY_ISSUES were found in Phase 1, add a `## Sentry` section: `Resolves: PAM-BACKEND-G, PAM-BACKEND-H`
3. Push + create PR in one command:
   `~/.claude/bin/git-push-pr-merge.sh --base <base-branch> --title "<concise description>" --body-file /tmp/pr-body.md --no-merge`
   `--no-merge` means the CI gate is skipped — the PR is left open for human review regardless of check status
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
