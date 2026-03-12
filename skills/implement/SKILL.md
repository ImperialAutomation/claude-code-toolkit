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

FOLLOW ALL STEPS STRICTLY. NO SHORTCUTS. MUST use ~/.claude/bin/git-find-base-branch for base branch detection for the PR.

## Tool Rules

- Use Glob to find files — NEVER use `find` or `ls` via Bash
- Use Grep to search file contents — NEVER use `grep` or `rg` via Bash
- Use Read to read files — NEVER use `cat`, `head`, or `tail` via Bash
- Bash is for `gh` commands, `git` commands, running tests, and `~/.claude/bin/` scripts only
- NEVER write files via Bash (no `echo >`, `cat <<`, `tee`, heredoc) — use the Write tool to write to `/tmp/`, then reference the file
- NEVER use `python3 -c`, `sed`, or `awk` for file modifications — use Grep to find occurrences, then Edit to replace them
- Use Write to create new files — NEVER use `mkdir` via Bash (Write auto-creates parent directories)
- Use `git rm` to delete files — NEVER use `rm` via Bash
- For batch operations on multiple issues, ALWAYS use `~/.claude/bin/` scripts (e.g., `batch-issue-status.sh`, `batch-issue-view.sh`) — NEVER use `for` loops or chained `&&` commands to repeat `gh` calls

Follow the Test Quality Policy and Anti-Patterns from CLAUDE.md throughout all phases.

## Phase 1: Discovery & Planning

1. Fetch issue details: `~/.claude/bin/gh-save.sh /tmp/issue-$ARGUMENTS.json issue view $ARGUMENTS --json title,body,labels`, then use the Read tool to read it
2. Read AND verify understanding of existing code:
   * Read all CLAUDE.md files (root, frontend, backend if they exist)
   * Read the ACTUAL source files you plan to modify
   * Check what attributes/methods ACTUALLY exist on models you'll use
   * Find existing patterns for similar functionality (grep/search)
   * NEVER assume a model has an attribute - READ the model first
3. Create detailed implementation plan as **numbered steps of max 5 minutes each**:
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
   * Commit with a descriptive message for this step

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

### Step 1: Run the full test suite

```bash
pytest tests/path/to/your_test.py -v
```

* Run ALL tests fresh — do not rely on earlier green runs
* Paste the actual output in your response
* If ANY test fails, fix at root cause and re-run

### Step 2: Run project validation

* Check for: `npm run validate:all`, `make validate`, `./validate.sh`
* If validation command exists, run it and show output
* If backend schemas were modified, ensure OpenAPI is regenerated
* Fix any errors before proceeding

### Step 3: Verify claims with evidence

Before proceeding to PR creation:
* Every claim ("works", "tested", "complete") must have matching test output
* No "should work", "probably fine", or "seems correct" — only proven facts
* If you cannot prove a claim, go back and add the missing test

## Phase 4: PR Creation

1. Push branch to remote
2. Create PR with:
   * Title: `<concise description of change>` (no "Closes" keyword in title)
   * Body: `Closes #$ARGUMENTS\n\n<implementation summary + test checklist>`
   * Against base branch from: `~/.claude/bin/git-find-base-branch`
3. Return PR URL for review
