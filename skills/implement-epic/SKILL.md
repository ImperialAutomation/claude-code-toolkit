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
│   ├── If implement: Task agent → write code, test, PR, merge into feature branch
│   │   └── returns: SUCCESS (pr: 42) or FAILED (error)
│   ├── If audit: Task agent → scan codebase, run scripts, post report as issue comment
│   │   └── returns: AUDIT_COMPLETE (findings, recommendation) or FAILED (error)
│   ├── Handle results: update tracking PR
│   └── (repeat for all issues in wave)
├── Wave 2-N: same pattern
└── Phase Final: summary
```

The main session NEVER implements code itself. It only:
- Parses the epic and determines execution order
- Spawns Task agents for each sub-issue
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

### Step 4: Read project context

Read all CLAUDE.md files in the project (root, frontend, backend — whatever exists) and collect:
- Tech stack and project structure
- Test commands and validation commands
- Code quality policies

Store this as `project_context` — you will pass it to each sub-agent.

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

#### Step 3: Spawn sub-agent via Task tool

Use the Task tool with `subagent_type: "general-purpose"`. The sub-agent gets its own context window and full tool access.

**The prompt depends on the issue classification.**

---

##### Step 3A: Prompt for `implement` issues

```
Implement GitHub issue #<N> for epic #$ARGUMENTS.

## Issue
Title: <title>
Body: <full issue body>

## Project Context
<project_context from Phase 0 Step 4 — CLAUDE.md contents, tech stack, test commands>

## Branch Setup
- Feature branch: <feature_branch>
- Create sub-branch: issue-<N>-<description>
- Base your work on the feature branch (already checked out)

## Instructions

1. Create and checkout branch: `git checkout -b issue-<N>-<description>`
2. Read the codebase: use Glob, Grep, Read to understand relevant files
3. Implement the changes following the project policies above
4. Write tests following the Test Quality Policy
5. Run ONLY the tests relevant to your changes — NEVER the full test suite:
   `~/.claude/bin/project-test.sh tests/unit/test_<relevant>/ -v`
   The full suite and project validation run after all sub-issues are done — not here.
6. If tests fail: fix and retry (up to 3 attempts total)
7. If tests pass:
   - Commit with a descriptive message (use Write to /tmp/commit-msg.txt, then `git commit -F /tmp/commit-msg.txt`)
   - Push: `git push -u origin issue-<N>-<description>`
   - Write PR body to /tmp/pr-body.md, then create PR:
     `gh pr create --title "<title>" --base <feature_branch> --body-file /tmp/pr-body.md`
   - Auto-merge: `gh pr merge <pr-number> --merge --delete-branch`
   - Return to feature branch: `git checkout <feature_branch>`, then `git pull origin <feature_branch>`

## HARD BOUNDARIES
- Your PR target is the FEATURE BRANCH (`<feature_branch>`) — NEVER target `main` or `develop`
- NEVER close any issues — that happens automatically when the tracking PR is merged by the user
- Your scope is ONE sub-issue only — do not touch other issues or the tracking PR

## Tool Rules
- Use Glob to find files — NEVER use `find` or `ls` via Bash
- Use Grep to search file contents — NEVER use `grep` or `rg` via Bash
- Use Read to read files — NEVER use `cat`, `head`, or `tail` via Bash
- Bash is for `gh` commands, `git` commands, running tests, and `~/.claude/bin/` scripts only
- NEVER write files via Bash (no `echo >`, `cat <<`, `tee`, heredoc) — use the Write tool to write to `/tmp/`, then reference the file
- NEVER use `python3 -c`, `sed`, or `awk` for file modifications — use Grep to find occurrences, then Edit to replace them
- Use Write to create new files — NEVER use `mkdir` via Bash
- Use `git rm` to delete files — NEVER use `rm` via Bash

## Response Format

When done, respond with EXACTLY one of these formats:

SUCCESS:
PR_NUMBER: <number>
SUMMARY: <one-line description of what was implemented>

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
<project_context from Phase 0 Step 4 — CLAUDE.md contents, tech stack, test commands>

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
- Use Glob to find files — NEVER use `find` or `ls` via Bash
- Use Grep to search file contents — NEVER use `grep` or `rg` via Bash
- Use Read to read files — NEVER use `cat`, `head`, or `tail` via Bash
- Bash is for `gh` commands, `git` commands, `~/.claude/bin/` scripts only
- NEVER write files via Bash — use the Write tool to write to `/tmp/`, then reference the file

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
- Extract PR number and summary
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

## Phase Final: Wrap-up

**CRITICAL: NEVER merge the tracking PR. NEVER close the parent issue. NEVER push to main or develop directly. The tracking PR stays as a draft for the user to review and merge manually.**

### Step 1: Run project validation

Checkout the feature branch and run the project validation suite:

```bash
git checkout <feature_branch>
npm run validate:all
```

If validation fails, fix issues and commit directly to the feature branch.

### Step 2: Sync Closes statements

Ensure all completed sub-issue numbers are in the tracking PR body as `Closes #<N>` statements. Failed and skipped issues should NOT have Closes statements.

### Step 3: Show summary

Display a final report:

```markdown
## Epic #$ARGUMENTS — Implementation Complete

### Results
| # | Issue | Type | Status | PR/Report |
|---|-------|------|--------|-----------|
| 1 | #XX — Title | impl | ✅ Merged | #YY |
| 2 | #XX — Title | audit | 🔍 PASS | comment |
| 3 | #XX — Title | audit | ⚠️ WARNINGS | comment |
| 4 | #XX — Title | impl | ❌ Failed → Bug #ZZ | - |
| 5 | #XX — Title | impl | ⏭️ Skipped (depends on #XX) | - |

### Statistics
- ✅ Implemented: X of Y
- 🔍 Audited: X (PASS: X, WARNINGS: X, FAIL: X)
- ❌ Failed: X (bug issues created: #AA, #BB)
- ⏭️ Skipped: X

### Tracking PR
<tracking-pr-url>

The tracking PR is ready for manual review and merge to develop.
```

