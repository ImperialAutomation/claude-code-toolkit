---
name: test
description: Smart test runner that scopes tests based on changed files
argument-hint: "[--all|--affected]"
user-invocable: true
---

# Smart Test Runner

Run tests scoped to your changes. Avoids the false choice between running specific tests manually or the entire suite.

## Input

Mode is determined by `$ARGUMENTS`:
- **No arguments / empty / `--affected`**: run tests affected by current changes (default)
- `--all`: run the full test suite

## Phase 1: Detect Test Framework

Check which test frameworks are available:
- **pytest**: look for `pyproject.toml` with `[tool.pytest]`, `pytest.ini`, `setup.cfg` with `[tool:pytest]`, or a `tests/` directory with `test_*.py` files
- **jest**: look for `package.json` with `jest` in dependencies/devDependencies, `jest.config.*`, or `__tests__/` directories
- **vitest**: look for `vitest.config.*` or `package.json` with `vitest`

Store the detected framework(s). If multiple are detected (e.g., pytest for backend + jest for frontend), handle both.

## Phase 2: Map Changes to Tests

### Step 1: Get changed files

```bash
git diff --name-only
git diff --cached --name-only
```

Combine both lists (unstaged + staged changes). Exclude non-source files: `*.md`, `*.json`, `*.yaml`, `*.yml`, `*.toml`, `*.cfg`, `*.ini`, `*.txt`, `*.lock`, `*.svg`, `*.png`, `*.jpg`.

### Step 2: Map source files to test files

For each changed source file, find related test files using these strategies:

**Strategy 1 — Naming conventions:**
- Python: `src/auth.py` → search for `**/test_auth*.py` and `**/auth_test.py`
- JS/TS: `src/Login.tsx` → search for `**/Login.test.*`, `**/Login.spec.*`
- Nested paths: `src/services/auth.py` → also try `tests/services/test_auth*.py`

**Strategy 2 — Import analysis:**
- For each test file found via Glob (`**/test_*.py` or `**/*.test.*`), use Grep to check if it imports the changed module
- This catches tests that don't follow naming conventions

**Strategy 3 — Changed test files:**
- If a changed file is itself a test file, include it directly

### Step 3: Classify changed files for tier assignment

Determine if changes touch integration-sensitive areas:
- **Routes/endpoints**: files matching `**/routes/**`, `**/views/**`, `**/controllers/**`, `**/api/**`
- **Models/schemas**: files matching `**/models/**`, `**/schemas/**`, `**/entities/**`
- **Middleware/auth**: files matching `**/middleware/**`, `**/auth/**`, `**/security/**`
- **Database/migrations**: files matching `**/migrations/**`, `**/alembic/**`

## Phase 3: Execute Tests (Tiered)

### Tier 1: Direct affected tests (always runs)

Run only the test files mapped from Phase 2.

**For pytest:**
```bash
~/.claude/bin/project-test.sh <test_file_1> <test_file_2> ... -v
```

**For jest:**
```bash
npx jest --testPathPattern="<pattern>" --verbose
```

If no test files were mapped: report "No affected tests found for the changed files" and stop (unless `--all` was specified).

Report results: passed, failed, skipped counts + failure details.

### Tier 2: Integration tests (conditional)

**Only runs if:** Tier 1 passed AND changed files include integration-sensitive areas (routes, models, middleware, database).

Look for integration test directories:
- `tests/integration/`, `tests/e2e/`, `__tests__/integration/`
- Files matching `*integration*`, `*e2e*`

Run the integration tests:
```bash
~/.claude/bin/project-test.sh tests/integration/ -v
```

Report results separately from Tier 1.

### Tier 3: Full suite (only with `--all`)

Run the complete test suite:
```bash
~/.claude/bin/project-test.sh -v
```

Or for JS:
```bash
npx jest --verbose
```

## Phase 4: Report

Generate the test report:

```markdown
## Test Report

**Mode:** affected / all
**Framework:** pytest / jest / vitest
**Changed files:** <count> source files

### Change → Test Mapping

| Source File | Test File(s) | Strategy |
|------------|-------------|----------|
| src/auth.py | tests/test_auth.py | naming |
| src/utils.py | tests/test_helpers.py | import |
| src/models.py | — | no test found |

### Results

| Tier | Scope | Passed | Failed | Skipped |
|------|-------|--------|--------|---------|
| 1 — Affected | 3 test files | 24 | 0 | 2 |
| 2 — Integration | tests/integration/ | 8 | 0 | 0 |

### Failures (if any)

<For each failure: test name, assertion error, relevant output>

### Verdict

**<ALL PASS / FAILURES>**
```

If there are failures, include the full assertion error and relevant context so the user can decide whether to fix or investigate further.
