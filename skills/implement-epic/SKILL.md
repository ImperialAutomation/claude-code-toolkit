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
- NEVER merge the tracking PR (the user reviews and merges manually)
- NEVER close the parent issue (closing happens automatically when the tracking PR is merged)
- Only merge sub-issue PRs into the **feature branch** — nothing else

## Architecture

```
Main session (orchestrator):
├── Phase 0: Setup — parse epic, determine waves, create feature branch + tracking PR
├── Wave 1:
│   ├── Classify issue #A → "implement" or "audit"
│   ├── Spawn background Task agent (run_in_background: true)
│   ├── Poll progress every 30-45s via /tmp/epic-progress-<N>.txt
│   │   └── Report phase + test results to user in real-time
│   ├── On completion: parse result (SUCCESS/AUDIT_COMPLETE/FAILED)
│   ├── Handle results: update tracking PR
│   └── (repeat for all issues in wave)
├── Wave 2-N: same pattern
└── Phase Final: summary
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

**CRITICAL: NEVER merge the tracking PR. NEVER close the parent issue. NEVER push to main or develop directly. The tracking PR stays as a draft for the user to review and merge manually.**

### Step 1: Run project validation

Checkout the feature branch and run the project validation suite:

```bash
git checkout <feature_branch>
npm run validate:all
```

If validation fails, fix issues and commit directly to the feature branch.

### Step 2: Runtime verification

Check the project's CLAUDE.md for an **Integration Verification** section. If it exists, use its configuration. Otherwise, use auto-discovery.

**Container health check:**
```bash
~/.claude/bin/docker-health-check.sh [project-dir] [--filter PREFIX] [--timeout SECS]
```

If containers are down or unhealthy:
1. Run the project's rebuild command (from Integration Verification config) or `docker compose up -d`
2. Wait 15 seconds, then re-run the health check
3. After 1 failed retry: report the failure but continue to the next check

**API smoke test:**
```bash
~/.claude/bin/smoke-test.sh [base-url] [--health-token TOKEN]
```

**Migration check (if alembic detected):**
- Run `docker exec <api-container> alembic current` and compare with `alembic heads`
- If migrations are pending: run the project's migrate command, then re-check

Skip any check that is not applicable (no compose file, no running containers, no alembic).

### Step 2b: Cross-cutting auth verification (conditional)

**Only runs if any sub-issue was marked `auth_impact: true` in Phase 1-N.**

This step catches integration issues that fall between sub-issues — particularly when new user statuses or roles are introduced but existing auth guards don't account for them.

1. Search the feature branch diff for new statuses/roles:
   ```bash
   git diff main..HEAD
   ```
   Look for: enum additions (Python `class ...Status`, `ALTER TYPE ADD VALUE`), new role constants, new permission levels.

2. For each new status/role found:
   - Identify the auth guard (e.g., `get_current_active_user`, `dependencies.py`, `auth middleware`)
   - Check if the guard explicitly handles the new status
   - Write a targeted test that:
     a. Creates a user with the new status
     b. Attempts to call `GET /auth/me` (or equivalent auth endpoint)
     c. Asserts the expected behavior (allowed or blocked)

3. Run only these targeted tests:
   ```bash
   ~/.claude/bin/project-test.sh tests/test_cross_cutting_auth.py -v
   ```

4. If tests fail: fix on the feature branch and commit. If the fix requires changes that conflict with a sub-issue's scope, create a follow-up issue instead.

5. If no new statuses/roles are found in the diff: skip this step.

### Step 3: Full test suite

Run the full test suite (not scoped — this is the one place where the full suite runs):

```bash
~/.claude/bin/project-test.sh
```

If tests fail: attempt to fix on the feature branch, commit, and retry once.

### Step 3b: Playwright E2E verification (only for projects using Playwright)

**Only runs if any sub-issue in this epic created or modified Playwright E2E test files (`.spec.ts`).**

1. **Verify seed account sync:** Compare all `key` values in `tests/e2e/fixtures/test-accounts.ts` against the keys in the Python seed script (e.g. `seed_e2e_accounts.py`). Any key present in TS but missing in Python = broken test suite. Fix before proceeding.

2. **Run Playwright tests** — scope based on what changed:
   - **Single spec changed:** `npx playwright test tests/e2e/<changed>.spec.ts`
   - **Multiple specs or shared infrastructure changed** (test-accounts.ts, playwright.config.ts, global-setup, page objects used by multiple specs): `npx playwright test --workers=1`

3. If tests fail: fix on the feature branch, commit, and retry once. If the failure is in a pre-existing test (not touched by this epic), report as WARNING and continue.

### Step 4: Browser smoke test (optional)

**Only if Playwright MCP tools (`mcp__playwright__*`) are available.**

1. Navigate to the frontend URL (from Integration Verification config or try common ports: 3000, 5173, 8080)
2. Take a screenshot with `mcp__playwright__browser_take_screenshot`
3. Check `mcp__playwright__browser_console_messages` for errors
4. Report results as WARNING only — do not block on browser test failures

### Step 5: Sync Closes statements

Ensure all completed sub-issue numbers are in the tracking PR body as `Closes #<N>` statements. Failed and skipped issues should NOT have Closes statements.

### Step 6: Show summary

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
| Containers | PASS/WARN/FAIL/SKIP | X/Y healthy |
| API Health | PASS/WARN/FAIL/SKIP | endpoints summary |
| Migrations | PASS/WARN/FAIL/SKIP | current vs head |
| Test Suite | PASS/FAIL | X/Y passed |
| Browser | PASS/WARN/FAIL/SKIP | console errors, screenshot |

### Statistics
- ✅ Implemented: X of Y
- 🔍 Audited: X (PASS: X, WARNINGS: X, FAIL: X)
- ❌ Failed: X (bug issues created: #AA, #BB)
- ⏭️ Skipped: X

### Tracking PR
<tracking-pr-url>

The tracking PR is ready for manual review and merge to develop.
```

