---
name: review
description: On-demand code review of current changes with automated checks and structural analysis
argument-hint: "[--staged|--branch|--file PATH]"
user-invocable: true
---

# Code Review

On-demand code review of current changes. Combines automated checks (fast, deterministic) with structural analysis (Claude reasoning about patterns and quality).

## Input

Scope is determined by `$ARGUMENTS`:
- **No arguments / empty**: unstaged changes (`git diff`)
- `--staged`: staged changes only (`git diff --cached`)
- `--branch`: all changes on current branch vs base (`git diff $(git merge-base HEAD $(~/.claude/bin/git-find-base-branch))..HEAD`)
- `--file PATH`: single file review (read file + `git diff -- PATH`)

## Phase 1: Scope & Diff

1. Determine scope from `$ARGUMENTS` as described above
2. Run the appropriate `git diff` command and capture the output
3. Extract the list of changed files from `git diff --name-only` (with the same scope flags)
4. If no changes found: report "No changes to review" and stop

Store the diff output and changed file list for subsequent phases.

## Phase 2: Automated Checks

Run these deterministic checks on the diff output. These are fast pattern matches — do not reason about context yet.

For each check, record findings with severity and location.

### 2a. Debug statements

Search the diff for added lines (`+` prefix) containing:
- Python: `print(`, `breakpoint()`, `import pdb`, `pdb.set_trace`, `import ipdb`
- JavaScript/TypeScript: `console.log`, `console.debug`, `console.warn`, `debugger`
- Generic: `TODO REMOVE`, `HACK`, `XXX`

Severity: **MEDIUM** (debug statements should not ship)

### 2b. Secret patterns

Search added lines for:
- `API_KEY=`, `SECRET_KEY=`, `PASSWORD=`, `TOKEN=` followed by a literal value (not env var reference)
- Hardcoded URLs with credentials (`https://user:pass@`)
- Private key markers (`-----BEGIN.*PRIVATE KEY-----`)

Severity: **CRITICAL**

### 2c. Large change detection

For each changed file, count the number of changed lines. Flag files with:
- More than 300 added lines → suggest splitting

Severity: **LOW** (informational)

### 2d. TODO/FIXME without issue reference

Search added lines for `TODO` or `FIXME` not followed by `#<number>` or a URL.

Severity: **LOW**

## Phase 3: Structural Review

Now reason about the changes in context. For each check below, read relevant source files as needed.

### 3a. DRY violations

For each new function or significant code block in the diff:
- Use Grep to search for similar logic elsewhere in the codebase
- Flag if substantially similar code already exists that could be reused or extracted

Severity: **MEDIUM**

### 3b. Magic strings and numbers

Flag hardcoded values in the diff that should be constants, enums, or configuration:
- HTTP status codes used as raw numbers
- String literals used as keys or identifiers in multiple places
- Numeric thresholds without explanation

Severity: **MEDIUM**

### 3c. Error handling at boundaries

Check if new code at system boundaries (API endpoints, external service calls, file I/O) has appropriate error handling:
- Uncaught exceptions from external calls
- Missing input validation on API endpoints
- Silent error swallowing (empty `except:` or `.catch(() => {})`)

Severity: **HIGH** (at boundaries), **LOW** (internal code)

### 3d. Pattern consistency

Compare the changed code against existing patterns in the same codebase:
- Naming conventions (function names, variable names, file names)
- Import ordering and style
- Error handling patterns
- API response format consistency

Severity: **MEDIUM**

## Phase 4: Test Coverage Mapping

For each changed **source file** (skip test files, configs, docs):

1. Determine the test file naming convention by checking existing tests:
   - Python: `test_<name>.py`, `<name>_test.py`
   - JS/TS: `<name>.test.ts`, `<name>.spec.ts`, `<name>.test.tsx`, `<name>.spec.tsx`

2. Search for matching test files using Glob:
   - `**/test_<basename>*` / `**/<basename>.test.*` / `**/<basename>.spec.*`

3. If a test file exists, check if it imports or references the changed module:
   - Use Grep to search the test file for imports of the changed module
   - Check if the test file covers the changed functions/classes

4. Classify coverage:
   - **COVERED**: test file exists AND imports/references changed code
   - **PARTIAL**: test file exists but does NOT reference the changed code
   - **MISSING**: no matching test file found

Report the mapping as a table.

## Phase 5: Report

Generate the review report in this format:

```markdown
## Code Review Report

**Scope:** <git diff description>
**Files reviewed:** <count>

### Findings

| # | Severity | Category | Finding | Location | Suggestion |
|---|----------|----------|---------|----------|------------|
| 1 | CRITICAL | Secret | Hardcoded API key | src/config.py:42 | Move to environment variable |
| 2 | HIGH | Error handling | Uncaught exception from external API | src/api.py:88 | Add try/except with proper error response |
| ... | ... | ... | ... | ... | ... |

### Test Coverage

| Source File | Test File | Coverage | Notes |
|------------|-----------|----------|-------|
| src/auth.py | tests/test_auth.py | COVERED | Imports changed functions |
| src/utils.py | — | MISSING | No test file found |

### Verdict

**<PASS / WARNINGS / NEEDS WORK>**

<Summary: what's good, what needs attention>
```

**Verdict rules:**
- **PASS**: no findings, or only INFO/LOW findings
- **WARNINGS**: MEDIUM findings but no HIGH or CRITICAL
- **NEEDS WORK**: any HIGH or CRITICAL findings
