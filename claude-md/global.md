# Global CLAUDE.md

## General Preferences

- Code comments in English
- Communication in Dutch (unless context requires otherwise)
- Commit messages in English, concise and descriptive
- `docker compose` (with space), never `docker-compose` (with hyphen)

## Running Tests (CRITICAL — permissions)

Claude Code permissies matchen op het EERSTE woord van Bash-commando's.
Geketende commando's als `cd X && source venv && pytest` starten met `cd`, niet `pytest`.
Dit triggert ALTIJD een permissieprompt, ook al is `Bash(pytest *)` allowed.

VERPLICHT voor alle pytest-aanroepen:

    ~/.claude/bin/project-test.sh [pytest-args...]

Dit script:
- Matcht `Bash(~/.claude/bin/*)` (altijd allowed, geen permissieprompt)
- Detecteert en gebruikt automatisch project venv (.venv, backend/.venv, etc.)
- Valideert dat je binnen ~/Projects/ draait

NOOIT gebruiken:
- `cd path && pytest ...` — eerste woord is `cd`, niet `pytest`
- `source .venv/bin/activate && pytest ...` — eerste woord is `source`
- `python -m pytest ...` (direct) — gebruik het wrapper script
- `.venv/bin/pytest ...` (direct) — gebruik het wrapper script

## Test Quality Policy

- Tests must verify real behavior through the full stack where possible
- Mocks are ONLY acceptable for external services (third-party APIs, email, payment providers)
- If you mock a database query or internal service, justify WHY in a code comment
- NEVER mock the thing you are testing
- Prefer integration-style tests over heavily mocked unit tests
- Fixtures must reflect realistic data, not minimal placeholders
- Include edge cases in fixture data (empty strings, unicode, boundary values)
- If a fixture represents a user, give it realistic attributes — not `name="test"`, `email="test@test.com"`
- For every test, ask: "If someone subtly breaks this feature, will THIS test actually fail?"
- For every test, ask: "Am I testing that the code works, or just that it runs without errors?"

## Anti-Patterns (always avoid)

- Assume a model has attributes without reading the model file
- Write tests that import non-existent classes
- Claim tests pass without showing actual test output
- Skip validation because "it should work"
- Commit code that hasn't been tested
- Mock internal code just to make tests easier to write
- Create fixtures with placeholder data like `name="test"` or `value=123`
- Write tests that only verify "no exception was raised"

## Code Review Conduct

- No performative agreement — never respond with "You're absolutely right!", "Great point!", or "Excellent feedback!"
- Verify review feedback against the codebase before implementing — reviewer may lack context
- Push back with technical reasoning when feedback is incorrect or violates YAGNI
- When feedback is correct: just fix it and describe the change. Actions over words
- Implement review items one at a time, test each individually
- If any review item is unclear: ask for clarification on ALL unclear items before implementing any

## Code Quality

- If ANY verification fails, STOP and reassess
- DRY: check if similar logic already exists before implementing; create shared functions instead of duplicating
- No magic strings/numbers: use constants, enums, or configuration for all business logic values
- Remove obsolete code always. Never keep old files "just in case"

## Documentation Standards

- Focus on current purpose, not implementation history
- Include usage guidance and critical warnings
- No historical changelogs in code documentation

## Available Utilities

- **Running tests** (`~/.claude/bin/project-test.sh`): see "Running Tests" section above
- **Project audits** (`/audit`): run one or all project audits from `~/.claude/bin/`:
  - `i18n-audit.py` — missing/unused/inconsistent translation keys (auto-detects framework)
  - `env-audit.sh` — .env vs .env.example sync, empty values, secrets tracked by git
  - `deps-audit.sh` — npm/pip dependency vulnerability scanning
  - `docker-audit.sh` — unpinned images, missing health checks, root users, hardcoded secrets
- **Security audit** (`/security-audit`): OWASP-guided security code review per domain. Uses:
  - `secret-scan.sh` — scan codebase for hardcoded secrets, API keys, tokens
  - `security-headers-check.sh <url>` — check HTTP security headers (CSP, HSTS, etc.)
  - `owasp-zap-scan.sh <url>` — OWASP ZAP baseline scan via Docker (requires running target)

## Claude Code Workarounds

- When a tool call is denied due to permissions:
  1. Check if a native tool or existing `~/.claude/bin/` script achieves the same result
  2. If not: propose a new `~/.claude/bin/` script that wraps the blocked command, so it can be allowlisted once via `Bash(~/.claude/bin/script-name.sh *)`. Present the script to the user for approval before creating it. Note: `~/.claude/bin/` is symlinked to the toolkit repo — remind the user to commit new scripts there when convenient
  3. Only ask the user for direct permission as a last resort
- ALWAYS prefer native tools (Read, Write, Edit, Grep, Glob) over Bash equivalents. Bash is ONLY for actual shell operations (git, docker, npm, etc.) — never for file reading, writing, searching, or editing.
  - Use Glob to find files — not `find` or `ls`
  - Use Grep to search file contents — not `grep` or `rg`
  - Use Read to read files — not `cat`, `head`, or `tail`
  - Use Write to create new files (auto-creates parent directories) — not `mkdir` + Bash
  - Use `git rm` to delete files — not `rm`
- Bash tool: always save API responses to a file first, then read the file. Use `~/.claude/bin/gh-save.sh /tmp/output.json <gh-args>` to save `gh` output (shell redirects like `>` trigger permission prompts).
- Never use command substitution with pipes for API data
- Never write files via Bash (no `echo >`, `cat <<`, `tee`, heredoc). These don't match permission patterns like `Bash(git *)`. Instead: use the Write tool to write to `/tmp/`, then reference the file in Bash (e.g., `git commit -F /tmp/commit-msg`, `gh issue create --body-file /tmp/issue-body.md`).
- Never use `python3 -c`, `sed`, or `awk` for file reading, writing, searching, or modifications. Use Grep/Read to find content, then Edit to replace. `python3 -c` is allowed for non-file operations (calculations, data transformations, etc.).
- For batch operations on multiple issues, always use `~/.claude/bin/` scripts (e.g., `batch-issue-status.sh`, `batch-issue-view.sh`). Never use `for` loops or chained `&&` commands to repeat `gh` calls.
