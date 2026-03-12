# Global CLAUDE.md

## General Preferences

- Code comments in English
- Communication in Dutch (unless context requires otherwise)
- Commit messages in English, concise and descriptive
- `docker compose` (with space), never `docker-compose` (with hyphen)

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

- Before using model attributes, verify they exist (grep/search)
- Before importing classes, verify they exist
- Follow existing patterns in the codebase — read before writing
- If ANY verification fails, STOP and reassess
- DRY: check if similar logic already exists before implementing; create shared functions instead of duplicating
- No magic strings/numbers: use constants, enums, or configuration for all business logic values
- Remove obsolete code always. Never keep old files "just in case"

## Documentation Standards

- Focus on current purpose, not implementation history
- Include usage guidance and critical warnings
- No historical changelogs in code documentation

## Frontend Standards

- Loading indicators only after >500ms delay (debounce to prevent flickering)
- All user-facing text via translation keys (`t('key')`), never hardcoded strings
- When using an API client with baseURL: use relative URLs (prevent double prefixes)

## Claude Code Workarounds

- ALWAYS prefer native tools (Read, Write, Edit, Grep, Glob) over Bash equivalents. Bash is ONLY for actual shell operations (git, docker, npm, etc.) — never for file reading, writing, searching, or editing.
- Bash tool: always save API responses to a file first, then read the file. Use `~/.claude/bin/gh-save.sh /tmp/output.json <gh-args>` to save `gh` output (shell redirects like `>` trigger permission prompts).
- Never use command substitution with pipes for API data
- Never write files via Bash (no `echo >`, `cat <<`, `tee`, heredoc). These don't match permission patterns like `Bash(git *)`. Instead: use the Write tool to write to `/tmp/`, then reference the file in Bash (e.g., `git commit -F /tmp/commit-msg`, `gh issue create --body-file /tmp/issue-body.md`).
- Never use `python3 -c`, `sed`, or `awk` for file reading, writing, searching, or modifications. Use Grep/Read to find content, then Edit to replace. `python3 -c` is allowed for non-file operations (calculations, data transformations, etc.).
- For batch operations on multiple issues, always use `~/.claude/bin/` scripts (e.g., `batch-issue-status.sh`, `batch-issue-view.sh`). Never use `for` loops or chained `&&` commands to repeat `gh` calls.
