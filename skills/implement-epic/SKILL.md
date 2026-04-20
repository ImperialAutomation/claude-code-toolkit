---
name: implement-epic
description: Automatically implement all sub-issues of an epic in dependency order
argument-hint: <parent-issue>
user-invocable: true
---

# Implement Epic

Automatically implement all sub-issues of a parent epic in dependency order. Each sub-issue is implemented by a **sub-agent with its own context window**, keeping the main session lightweight for orchestration.

## Input

The user provides a parent issue number: `$ARGUMENTS`

This skill runs autonomously — no confirmation stops between sub-issues.

**HARD BOUNDARIES — NEVER cross these:**
- NEVER merge PRs into `develop` or `main` — those merges are always done by the user
- NEVER close the parent issue (closing happens automatically when the tracking PR is merged)
- Sub-issue PRs into the **feature branch** may be merged freely by sub-agents

## Architecture

```
Main session (orchestrator):
├── Phase 0: Setup — parse epic, determine waves, create feature branch + tracking PR
├── Wave 1:
│   ├── Classify issue #A → "implement" or "audit"
│   ├── Spawn background agent (run_in_background: true)
│   ├── Poll progress every 30-45s via /tmp/epic-progress-<N>.txt
│   │   └── Report phase + test results to user in real-time
│   ├── On completion: parse result (SUCCESS/AUDIT_COMPLETE/FAILED)
│   ├── Handle results: update tracking PR
│   └── (repeat for all issues in wave)
├── Wave 2-N: same pattern
└── Phase Final: Verification (ALL via sub-agents)
    ├── Agent: Validation & Test Suite
    ├── Agent: Runtime & Smoke Test (containers, API, login)
    ├── Agent: Cross-cutting Auth (conditional)
    ├── Agent: E2E Smoke Test (conditional)
    └── Orchestrator: collect results, sync Closes, show summary
```

The main session NEVER implements code itself. It only:
- Parses the epic and determines execution order
- Spawns background Task agents for each sub-issue
- **Monitors progress via `/tmp/epic-progress-<N>.txt` and reports to user**
- Handles results (success/failure/skip)
- Updates the tracking PR
- Creates bug issues on failure

## Phase 0: Setup

### Step 1: Read parent issue

```bash
~/.claude/bin/gh-save.sh /tmp/epic-$ARGUMENTS.json issue view $ARGUMENTS --json title,body,labels
```

Use the Read tool to read `/tmp/epic-$ARGUMENTS.json`.

### Step 2: Parse sub-issues and implementation order

Parse the issue body for:
- **Sub-issues:** Extract issue numbers from the tracking table or checklist
- **Implementation order:** Look for explicit ordering, dependency info, or phase numbers
- **Dependencies:** Which sub-issues depend on others (from "Depends On", "Blocked by" fields)

### Step 3: Determine waves

Group sub-issues into waves based on dependencies:
- **Wave 1:** Issues with no dependencies (can be implemented first)
- **Wave 2:** Issues that only depend on wave 1 issues
- **Wave N:** Issues that only depend on issues in earlier waves

Issues within the same wave are implemented sequentially (each needs the branch state from the previous).

### Step 4: Prepare project context for sub-agents

Copy all CLAUDE.md files to `/tmp/` so sub-agents can lazy-load them (avoids embedding 20-30 KB of identical context in every sub-agent prompt):

```bash
cp CLAUDE.md /tmp/epic-claude-root.md
cp frontend/CLAUDE.md /tmp/epic-claude-frontend.md 2>/dev/null || true
cp backend/app/CLAUDE.md /tmp/epic-claude-backend.md 2>/dev/null || true
```

Also read the root CLAUDE.md yourself to extract the **one-line tech stack summary** and **test/validation commands** — store these as `project_summary` (max 5 lines). This small summary goes into every sub-agent prompt; the full CLAUDE.md files are read by the sub-agent on demand.

### Step 5: Check/create feature branch

```bash
git fetch origin
git branch -a --list "*issue-$ARGUMENTS*"
```

If the feature branch exists, check it out. Otherwise create it:
```bash
git checkout -b issue-$ARGUMENTS-<description>
```

Store the feature branch name as `feature_branch`.

### Step 6: Check/create tracking PR

Find existing tracking PR:
```bash
~/.claude/bin/find-tracking-pr.sh <repo> $ARGUMENTS
```

If no tracking PR exists, create a draft PR against `develop` using the Write tool to write the body to `/tmp/tracking-pr-body.md`, then:
```bash
gh pr create --draft --title "<Epic title>" --base develop --body-file /tmp/tracking-pr-body.md
```

Store the tracking PR number as `tracking_pr`.

### Step 7: Show overview and start

Display a summary of:
- Total sub-issues and wave structure
- Dependency graph
- Feature branch and tracking PR

Then proceed immediately — no confirmation stop.

## Phase 1-N: Per Wave

Process each wave sequentially. Within each wave, process sub-issues sequentially.

### Per sub-issue:

#### Step 1: Prepare the feature branch

Before spawning the sub-agent, ensure the feature branch is up to date:

```bash
git checkout <feature_branch>
git pull origin <feature_branch>
```

#### Step 2: Fetch issue details and classify

```bash
~/.claude/bin/gh-save.sh /tmp/sub-issue-<N>.json issue view <N> --json title,body,labels
```

Use the Read tool to read `/tmp/sub-issue-<N>.json`. Store the issue title, body, and labels.

**Classify the issue as `audit` or `implement`:**

An issue is an **audit** issue if ANY of these match:
- Title contains: "review", "audit", "scan", "check", "verify", "assessment"
- Labels include: `security` combined with words like "review" or "audit" in the title
- Body focuses on verification/scanning rather than code changes (checklist of things to check, not things to build)
- The issue explicitly says "no code changes" or "document findings"

An issue is an **implement** issue if it requires writing/changing application code (adding middleware, creating endpoints, modifying configuration, etc.).

**When in doubt:** classify as `implement` — it's better to write code and discover it's an audit than to only audit when code was needed.

#### Step 2b: Detect auth impact

Scan the issue body for auth-related keywords: `status`, `UserStatus`, `role`, `permission`, `auth`, `login`, `PENDING`, `SUSPENDED`, `DELETED`, `BLOCKED`, `INACTIVE`.

If any keywords are found, mark the issue as `auth_impact: true`. This flag is used in Step 3A to inject an additional auth impact check into the sub-agent prompt.

#### Step 3: Spawn sub-agent via Task tool

Use the Task tool with `subagent_type: "general-purpose"` and `run_in_background: true`. The sub-agent gets its own context window and full tool access.

**The prompt depends on the issue classification.**

---

##### Step 3A: Prompt for `implement` issues

```
Implement GitHub issue #<N> for epic #$ARGUMENTS.

## Issue
Title: <title>
Body: <full issue body>

## Project Context
<project_summary — max 5 lines: tech stack, test command, validation command>

Project policies are in these files — read them BEFORE writing code:
- /tmp/epic-claude-root.md (project overview, naming conventions, dev commands)
- /tmp/epic-claude-frontend.md (frontend architecture — read if modifying frontend)
- /tmp/epic-claude-backend.md (backend architecture — read if modifying backend)
Read only the files relevant to your issue. Do NOT skip this step.

## Branch Setup
- Feature branch: <feature_branch>
- Create sub-branch: issue-<N>-<description>
- Base your work on the feature branch (already checked out)

## Instructions

1. Create and checkout branch: `git checkout -b issue-<N>-<description>`
2. Read the codebase: use Glob, Grep, Read to understand relevant files.
   **For E2E/Playwright tests:** also read the frontend components you are writing selectors for. Never guess heading text, aria-labels, CSS classes, or DOM structure — look them up in the React/Vue/Svelte source. Grep for the component name, read it, and extract the exact strings and attributes you need for locators.
3. Implement the changes following the project policies above
4. Write tests following the Test Quality Policy
5. Run ONLY the tests relevant to your changes — NEVER the full test suite:
   `~/.claude/bin/project-test.sh tests/unit/test_<relevant>/ -v`
   The full suite and project validation run after all sub-issues are done — not here.
6. If tests fail: fix and retry (up to 3 attempts total)
7. If tests pass:
   - Commit: `~/.claude/bin/git-commit.sh "concise descriptive message"`
   - Write PR body to /tmp/pr-body.md using the Write tool, then push + PR + merge in one command:
     `~/.claude/bin/git-push-pr-merge.sh --base <feature_branch> --title "<title>" --body-file /tmp/pr-body.md`
   - This script pushes, creates the PR, merges it, and returns to the feature branch automatically

## Auth Impact Check (only include if auth_impact is true)
This issue changes user status/role/auth fields. BEFORE writing tests:
1. Read auth/dependencies.py (or equivalent auth guard file)
2. Check which statuses/roles the guard currently allows
3. Determine: should the NEW status pass the guard or be blocked?
4. Write a test that verifies this explicitly
5. If the new status SHOULD pass but the guard blocks it: note this in the PR body as a required follow-up

## Playwright E2E Test Account Checklist (only for projects using Playwright)
If this issue creates or modifies Playwright E2E tests that require test accounts, ensure ALL THREE files are in sync:
1. `tests/e2e/fixtures/test-accounts.ts` — TS fixture with key, email, tier, storageState
2. `playwright.config.ts` — project entry with testMatch and storageState path
3. The Python seed script (e.g. `backend/app/scripts/seed_e2e_accounts.py`) — account with matching key, email, tier, and person data
Missing any one of these three causes global-setup to fail with a login error at test runtime.

## HARD BOUNDARIES
- Your PR target is the FEATURE BRANCH (`<feature_branch>`) — NEVER target `main` or `develop`
- NEVER close any issues — that happens automatically when the tracking PR is merged by the user
- Your scope is ONE sub-issue only — do not touch other issues or the tracking PR

## Tool Rules
- Use Glob/Grep/Read instead of Bash equivalents (find, grep, cat, head, tail)
- Use Write/Edit for file creation and modification — not Bash (echo, cat, sed, awk)
- Bash is for: git, gh, npm, docker, and `~/.claude/bin/` scripts only

## Progress Reporting

Write your current phase to `/tmp/epic-progress-<N>.txt` using the Write tool at each milestone.
Format (one line per field, only PHASE is required):

PHASE: <milestone-name>
DETAIL: <optional context>
TESTS: <passed>/<total> passed, <failed> failed

Milestones to report (update the file BEFORE starting each phase):
- READING_CODEBASE — when you start exploring files. DETAIL: which directories/files
- WRITING_TESTS — when you start writing test code. DETAIL: number of test classes/cases
- RUNNING_TESTS_RED — after running tests that should fail. TESTS: 0/8 passed, 8 failed
- IMPLEMENTING — when writing production code. DETAIL: which files you're modifying
- RUNNING_TESTS_GREEN — after running tests that should pass. TESTS: 8/8 passed, 0 failed
- COMMITTING — when staging and committing. DETAIL: number of files staged
- CREATING_PR — when pushing and creating PR
- MERGING_PR — after merging the PR. DETAIL: PR number

This is critical for the orchestrator to track and report your progress to the user.

## Response Format

When done, respond with EXACTLY one of these formats:

SUCCESS:
PR_NUMBER: <number>
SUMMARY: <one-line description of what was implemented>
FILES_CHANGED: <count of files added or modified>
TESTS_WRITTEN: <count of test functions written>
TESTS_PASSED: <passed>/<total>

FAILED:
ERROR: <description of what went wrong>
ATTEMPTS: <what was tried>
LAST_ERROR_OUTPUT: <relevant error output>
```

---

##### Step 3B: Prompt for `audit` issues

Audit issues do NOT produce code or PRs. They scan the codebase and post a report as a comment on the issue.

```
Perform a security audit for GitHub issue #<N> (part of epic #$ARGUMENTS).

## Issue
Title: <title>
Body: <full issue body>

## Project Context
<project_summary — max 5 lines: tech stack, test command, validation command>

Project policies are in these files — read them BEFORE starting your audit:
- /tmp/epic-claude-root.md (project overview, naming conventions)
- /tmp/epic-claude-backend.md (backend architecture, security patterns)
Read only the files relevant to your audit domain. Do NOT skip this step.

## Audit Instructions

You are performing a security AUDIT — your output is a structured report, NOT code changes.

1. Read the issue body carefully to understand which security domain to review.
2. Determine which domain this issue covers. Use the mapping below:

   - "dependency" / "dependencies" / "npm audit" / "pip-audit" → Run: `~/.claude/bin/deps-audit.sh`
   - "authentication" / "authorization" / "JWT" / "auth" → Review auth code: Glob for `**/auth/**`, read security.py, dependencies.py, permissions.py
   - "input validation" / "OWASP" / "XSS" / "SQL injection" → Search for injection patterns: raw SQL, dangerouslySetInnerHTML, subprocess, eval, user-controlled URLs
   - "file upload" / "photo" / "image" → Review upload handlers: Glob for `**/upload*`, `**/photo*`, check MIME validation, size limits, processing
   - "security headers" / "HTTP headers" / "CSP" / "HSTS" → Run: `~/.claude/bin/security-headers-check.sh <target-url-if-known>` and review middleware config
   - "rate limit" / "throttle" / "brute force" → Search for rate limiting: Grep for `rate_limit`, `throttle`, `slowapi`, `RateLimiter`. Map which endpoints are protected
   - "database" / "SQL" / "mass assignment" → Review ORM usage, check for raw SQL, verify sensitive fields excluded from responses
   - "infrastructure" / "secrets" / "Docker" / "session" / "cookie" → Run: `~/.claude/bin/secret-scan.sh` + `~/.claude/bin/env-audit.sh` + `~/.claude/bin/docker-audit.sh`
   - "pentest" / "ZAP" / "penetration" → Run: `~/.claude/bin/owasp-zap-scan.sh <target-url>` (only if a target URL is available, otherwise note it requires a running target)

3. Perform the domain-specific audit:
   - Run applicable `~/.claude/bin/` scripts
   - Use Glob, Grep, Read to systematically review relevant code
   - For each finding, record: severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, description, remediation

4. Generate the audit report in this format:

```markdown
## Security Audit Report: <domain>

**Issue:** #<N>
**Date:** <today>
**Auditor:** Claude Code (automated)

### Executive Summary
<1-3 sentences: overall assessment>

### Findings

| # | Severity | Finding | File | Remediation |
|---|----------|---------|------|-------------|
| 1 | HIGH | ... | path:line | ... |

### Detailed Findings
<per finding: description, evidence, fix>

### Verified Controls
<what was checked and found secure — audit trail>

### Recommendation
<PASS / PASS WITH WARNINGS / FAIL>
```

5. Post the report as an issue comment:
   - Write report to `/tmp/security-audit-report-<N>.md` using the Write tool
   - Post: `gh issue comment <N> --body-file /tmp/security-audit-report-<N>.md`

## Tool Rules
- Use Glob/Grep/Read instead of Bash equivalents (find, grep, cat, head, tail)
- Use Write/Edit for file creation and modification — not Bash (echo, cat, sed, awk)
- Bash is for: git, gh, `~/.claude/bin/` scripts only

## Progress Reporting

Write your current phase to `/tmp/epic-progress-<N>.txt` using the Write tool at each milestone.
Format (one line per field, only PHASE is required):

PHASE: <milestone-name>
DETAIL: <optional context>

Milestones to report (update the file BEFORE starting each phase):
- SCANNING_CODEBASE — when you start reviewing code. DETAIL: which directories
- RUNNING_AUDIT_SCRIPTS — when running audit scripts. DETAIL: which script
- ANALYZING_RESULTS — when processing results. DETAIL: findings count so far
- WRITING_REPORT — when writing the report. DETAIL: total findings and critical count
- POSTING_REPORT — when posting the comment

This is critical for the orchestrator to track and report your progress to the user.

## Response Format

When done, respond with EXACTLY one of these formats:

AUDIT_COMPLETE:
FINDINGS: <number of findings>
CRITICAL: <number of critical findings>
RECOMMENDATION: <PASS / PASS WITH WARNINGS / FAIL>
SUMMARY: <one-line summary>

FAILED:
ERROR: <description of what went wrong>
ATTEMPTS: <what was tried>
LAST_ERROR_OUTPUT: <relevant error output>
```

#### Step 3C: Monitor sub-agent progress

**⚠️ TOOL RULE: Use the Read tool to read progress files and TaskOutput to check agent status. NEVER use Bash commands like `tail`, `cat`, `grep`, or `head` for monitoring — these will be blocked by permissions and stall the epic.**

After spawning the background sub-agent:

1. Store the `task_id` from the Task tool response
2. **Poll every 30-45 seconds** until the agent completes:
   a. Use the **Read tool** on `/tmp/epic-progress-<N>.txt` (ignore if file doesn't exist yet — agent is still starting)
   b. Parse the `PHASE:`, `DETAIL:`, and `TESTS:` fields
   c. **Report to the user** with a human-readable status message:
      ```
      ⏳ #<N> (<title>): <human-readable phase>
      ```
      - If TESTS line is present, append: `— X/Y passed, Z failed`
      - If DETAIL line is present, append in parentheses: `(modifying auth_service.py)`
   d. Call `TaskOutput` with `block: false, timeout: 1000` to check if the agent is done
   e. If not completed → continue polling (next iteration ~30-45s later)
   f. If completed → extract the result text and proceed to Step 4

3. **Phase display mapping** (use these human-readable labels):

   | Progress file value | Display to user |
   |---|---|
   | READING_CODEBASE | Analyzing codebase |
   | WRITING_TESTS | Writing tests |
   | RUNNING_TESTS_RED | Running tests (RED phase) |
   | IMPLEMENTING | Writing implementation |
   | RUNNING_TESTS_GREEN | Running tests |
   | REFACTORING | Refactoring |
   | COMMITTING | Committing changes |
   | CREATING_PR | Creating pull request |
   | MERGING_PR | Merging PR |
   | SCANNING_CODEBASE | Scanning codebase |
   | RUNNING_AUDIT_SCRIPTS | Running audit scripts |
   | ANALYZING_RESULTS | Analyzing results |
   | WRITING_REPORT | Writing report |
   | POSTING_REPORT | Posting report |
   | DONE | Complete |

4. **On completion**, report the final result to the user before proceeding:
   - For implement: `✅ #<N> — <summary> | PR #<pr> | <files> files | <tests_passed>/<tests_total> tests`
   - For audit: `🔍 #<N> — <summary> | <findings> findings, <critical> critical | <recommendation>`
   - For failure: `❌ #<N> — Failed: <error summary>`

#### Step 4: Handle sub-agent result

Parse the sub-agent's response:

**On audit complete** (response contains `AUDIT_COMPLETE`):
- Extract findings count, critical count, recommendation, and summary
- Record: issue #N → 🔍 Audited (<recommendation>)
- If recommendation is PASS: mark as ✅ in tracking PR
- If recommendation is PASS WITH WARNINGS: mark as ⚠️ in tracking PR
- If recommendation is FAIL: mark as ❌ in tracking PR, create follow-up issue for critical findings
- No PR is created for audit issues — the report is posted as an issue comment by the sub-agent

**On success** (response contains `SUCCESS`):
- Extract PR number, summary, files changed, tests written, and tests passed
- Record: issue #N → ✅ Complete, PR #X

**On failure** (response contains `FAILED`):
1. **Create bug issue** — write body to `/tmp/bug-epic-<N>.md`:

```markdown
## Context
- Epic: #$ARGUMENTS
- Sub-issue: #<N> — <title>
- Feature branch: <feature_branch>

## Error
<error from sub-agent response>

## What Was Attempted
<attempts from sub-agent response>

## Last Error Output
<last_error_output from sub-agent response>

## Suggested Next Steps
- Investigate the error manually
- Check if dependencies are correctly set up
```

```bash
gh issue create --title "🐛 [Epic #$ARGUMENTS] Bug: <description>" --label bug --body-file /tmp/bug-epic-<N>.md
```

2. **Clean up failed branch** (if it was pushed):

```bash
git checkout <feature_branch>
git branch -D issue-<N>-<description>
```

3. **Mark dependent issues as skipped** — any issue in later waves that depends on this failed issue cannot proceed. Track which issues are skipped and why.

#### Step 5: Update tracking PR

After each sub-issue (success or failure), update the tracking PR:
- Update status in the tracking table (✅ Complete, ❌ Failed, ⏭️ Skipped)
- Update progress percentage
- Add PR link for successful issues
- Add bug issue link for failures

Write updated body to `/tmp/tracking-pr-update.md`, then:
```bash
gh pr edit <tracking_pr> --body-file /tmp/tracking-pr-update.md
```

## Phase Final: Verification & Wrap-up

**CRITICAL: NEVER merge PRs into `develop` or `main`. NEVER close the parent issue. NEVER push to `main` or `develop` directly. The tracking PR stays as a draft for the user to review and merge manually.**

**CRITICAL: Phase Final runs ALL verification steps as sub-agents.** The orchestrator's context is depleted after polling waves of sub-issues. Each verification step gets a fresh context window to do its job properly. The orchestrator only collects results and builds the summary.

### Step 1: Spawn verification sub-agent — Validation & Tests

Spawn a background agent:

```
## Task: Project Validation & Test Suite for Epic #<epic_number>

You are verifying the feature branch `<feature_branch>` after all sub-issues have been merged.

Project policies are in these files — read them BEFORE starting:
- /tmp/epic-claude-root.md (project overview, dev commands)
- /tmp/epic-claude-backend.md (backend architecture — if backend changes)
- /tmp/epic-claude-frontend.md (frontend architecture — if frontend changes)

### Step 1: Run project validation

```bash
git checkout <feature_branch>
npm run validate:all
```

If validation fails, fix issues and commit directly to the feature branch.

### Step 2: Full test suite

Run the full backend test suite:

```bash
~/.claude/bin/project-test.sh
```

If tests fail: attempt to fix on the feature branch, commit, and retry once.

### Step 3: Report

Write progress to `/tmp/epic-verify-validation.txt`:

PHASE: RUNNING_VALIDATION / RUNNING_TESTS / FIXING / DONE
DETAIL: <what's happening>

## Response Format

VALIDATION_COMPLETE:
VALIDATE_ALL: PASS/FAIL — <details>
TEST_SUITE: PASS/FAIL — <passed>/<total> tests
FIXES_COMMITTED: <number of fix commits, 0 if none>

FAILED:
ERROR: <description>
```

### Step 2: Spawn verification sub-agent — Runtime & Smoke Test

Spawn a background agent:

```
## Task: Runtime Verification & Smoke Test for Epic #<epic_number>

You are verifying that the application works at runtime after all sub-issues for epic #<epic_number> have been merged into `<feature_branch>`.

Project policies are in these files — read them BEFORE starting:
- /tmp/epic-claude-root.md (project overview, dev commands)

### Step 1: Rebuild containers if dependencies changed

Check if dependency files were modified:

```bash
git diff develop..<feature_branch> --name-only | grep -E "(package\.json|package-lock\.json|requirements\.txt|pyproject\.toml|uv\.lock)"
```

If any dependency file changed:
- Frontend: `cd backend/docker && ./stop.sh && ./start.sh`
- Backend only: `docker restart pam_api && sleep 15`
Wait for containers to be healthy.

### Step 2: Container health check

```bash
~/.claude/bin/docker-health-check.sh [project-dir] [--filter PREFIX] [--timeout SECS]
```

If containers are down or unhealthy:
1. Run `cd backend/docker && ./stop.sh && ./start.sh`
2. Wait 15 seconds, re-check
3. After 1 failed retry: report failure but continue

### Step 3: API smoke test

```bash
~/.claude/bin/smoke-test.sh [base-url] [--health-token TOKEN]
```

### Step 4: Migration check (if alembic detected)

- Run `docker exec pam_api alembic current` and verify no errors
- Check `docker logs pam_api --tail 20` for migration failures
- If migrations failed: investigate and fix

### Step 5: Login smoke test

Use the project's API login script to verify a test account can log in:
```bash
./scripts/api-login.sh admin
```
If it fails with 502/500: the API is broken — investigate container logs.

### Step 6: Report

Write progress to `/tmp/epic-verify-runtime.txt`:

PHASE: REBUILDING / HEALTH_CHECK / SMOKE_TEST / MIGRATION_CHECK / LOGIN_TEST / DONE
DETAIL: <what's happening>

## Response Format

RUNTIME_COMPLETE:
DEP_REBUILD: PASS/SKIP — <details>
CONTAINERS: PASS/WARN/FAIL — <X/Y healthy>
API_HEALTH: PASS/WARN/FAIL — <details>
MIGRATIONS: PASS/WARN/FAIL — <current vs head>
LOGIN_TEST: PASS/FAIL — <details>

FAILED:
ERROR: <description>
```

### Step 3: Spawn verification sub-agent — Cross-cutting auth (conditional)

**Only spawn if any sub-issue was marked `auth_impact: true` in Phase 1-N.**

```
## Task: Cross-cutting Auth Verification for Epic #<epic_number>

You are checking that new user statuses or roles introduced by epic #<epic_number> are properly handled by existing auth guards.

### Step 1: Find new statuses/roles

Search the feature branch diff for new statuses/roles:
```bash
git diff develop..<feature_branch>
```
Look for: enum additions (Python `class ...Status`, `ALTER TYPE ADD VALUE`), new role constants, new permission levels.

### Step 2: Verify auth guards

For each new status/role found:
- Read the auth guard (e.g., `auth/dependencies.py`)
- Check if the guard explicitly handles the new status
- Write a targeted test that creates a user with the new status and verifies expected behavior

### Step 3: Run tests

```bash
~/.claude/bin/project-test.sh <test-file> -v
```

If tests fail: fix on the feature branch and commit.
If no new statuses/roles found: report SKIP.

## Response Format

AUTH_CHECK_COMPLETE:
NEW_STATUSES: <list or "none found">
RESULT: PASS/FAIL/SKIP — <details>
```

### Step 4: Spawn verification sub-agent — E2E Smoke Test (conditional)

**Skip if the epic is a pure backend/infrastructure change with no user-facing effect.**

```
## Task: E2E Smoke Test for Epic #<epic_number>

You are writing and running a minimal Playwright smoke test to verify that the UI changes from epic #<epic_number> work at runtime.

Project policies are in these files — read them BEFORE starting:
- /tmp/epic-claude-root.md (project overview)
- /tmp/epic-claude-frontend.md (frontend architecture, testing patterns)

### Step 1: Determine the epic's UI domain

Based on the epic scope, classify what area was touched:

| Epic domain | Auth needed? | What to test |
|---|---|---|
| Public pages (landing, pricing, legal) | No | Pages load, content renders |
| Auth flow (login, register, password) | No | Forms render, validation works |
| Profile/search/matching | Yes (test account) | Key pages load, data displays |
| Admin panel | Yes (admin account) | Admin pages load, tables render |

### Step 2: Write a targeted smoke test

Create `tests/e2e/<epic-domain>-smoke.spec.ts`

Read the actual frontend components you are writing selectors for — never guess headings, aria-labels, or DOM structure.

Keep it minimal:
- Each touched page/route loads without errors
- Key content visible (headings, data)
- No JavaScript console errors

### Step 3: Run the smoke test

```bash
npx playwright test tests/e2e/<epic-domain>-smoke.spec.ts --project=<project-name>
```

If tests fail: fix and retry once.

### Step 4: Commit the smoke test

The smoke test is a permanent artefact — commit it to the feature branch.

## Response Format

E2E_COMPLETE:
DOMAIN: <epic domain>
TESTS: <passed>/<total>
COMMITTED: true/false

FAILED:
ERROR: <description>
```

### Step 5: Collect results and show summary

Wait for all verification sub-agents to complete (use `TaskOutput` with `block: true`). Parse each result.

**Sync Closes statements:** Ensure all completed sub-issue numbers are in the tracking PR body as `Closes #<N>` statements. Failed and skipped issues should NOT have Closes statements.

Display a final report:

```markdown
## Epic #$ARGUMENTS — Implementation Complete

### Results
| # | Issue | Type | Status | PR/Report |
|---|-------|------|--------|-----------|
| 1 | #XX — Title | impl | ✅ Merged | PR #YY — 4 files, 12/12 tests |
| 2 | #XX — Title | audit | 🔍 PASS | 3 findings, 0 critical |
| 3 | #XX — Title | audit | ⚠️ WARNINGS | 5 findings, 1 critical |
| 4 | #XX — Title | impl | ❌ Failed → Bug #ZZ | - |
| 5 | #XX — Title | impl | ⏭️ Skipped (depends on #XX) | - |

### Verification
| Check | Status | Details |
|-------|--------|---------|
| Validation | PASS/FAIL | validate:all result |
| Test Suite | PASS/FAIL | X/Y passed |
| Dep Rebuild | PASS/SKIP | containers rebuilt for new deps |
| Containers | PASS/WARN/FAIL/SKIP | X/Y healthy |
| API Health | PASS/WARN/FAIL/SKIP | endpoints summary |
| Migrations | PASS/WARN/FAIL/SKIP | current vs head |
| Login Test | PASS/FAIL/SKIP | admin login result |
| Auth Check | PASS/FAIL/SKIP | cross-cutting auth |
| E2E Smoke | PASS/WARN/FAIL/SKIP | X/Y passed |

### Statistics
- ✅ Implemented: X of Y
- 🔍 Audited: X (PASS: X, WARNINGS: X, FAIL: X)
- ❌ Failed: X (bug issues created: #AA, #BB)
- ⏭️ Skipped: X

### Tracking PR
<tracking-pr-url>

The tracking PR is ready for manual review and merge to develop.
```

