---
name: verify
description: Runtime verification - containers, API health, migrations, browser smoke test
argument-hint: "[quick|full|browser]"
user-invocable: true
---

# Runtime Verification

Verify that the application is actually running correctly after implementation. Four independent layers, each skipped if not applicable to the project.

**Modes:**
- `quick` (default) — layers 1-3
- `full` — all 4 layers including browser
- `browser` — layer 4 only

## Step 0: Read project configuration

Check the project's CLAUDE.md for an **Integration Verification** section. This section defines project-specific configuration:

- Container prefix/filter
- Health check timeout
- Rebuild command
- Smoke test URL and health token
- Migrate command
- Frontend URL

If no Integration Verification section exists, use auto-discovery for each layer.

Set MODE from $ARGUMENTS: `quick` (default if empty), `full`, or `browser`.

If MODE is `browser`, skip to Layer 4.

## Layer 1: Container Health

**Skip if:** no compose file in the project root AND no `Container prefix:` in the
Integration Verification config. A configured prefix is enough on its own — an
`include:`-based stack has no compose file that names its containers, and the check
takes the set from the prefix instead.

Run the runtime container health check:

```bash
~/.claude/bin/docker-health-check.sh [project-dir] [--filter PREFIX] [--timeout SECS]
```

Use values from the Integration Verification config if available (filter prefix, timeout).

**If issues found:**
1. Attempt auto-recovery: run the project's rebuild command if defined, otherwise `docker compose up -d`
2. Wait 15 seconds
3. Re-run the health check
4. If still failing after 1 retry: report the failure but continue to the next layer

**Report format:**
```
### Container Health: PASS|WARN|FAIL
<script output>
```

## Layer 2: API Health

**Skip if:** no base URL can be determined (not in config, not in .env, no running containers).

Run the API smoke test:

```bash
~/.claude/bin/smoke-test.sh [base-url] [--health-token TOKEN]
```

Use values from the Integration Verification config if available (URL, health token).

**If health endpoint reports unhealthy components:**
- Report which components are unhealthy
- If database is unhealthy and a migrate command is configured, suggest running it

**Report format:**
```
### API Health: PASS|WARN|FAIL
<script output>
```

## Layer 3: Migration Status

**Skip if:** no alembic directory found in the project (search for `alembic/`, `*/alembic/`).

Check if migrations are current:

1. Find the API container name (from Integration Verification config or by searching running containers for one with alembic installed)
2. Run: `docker exec <container> alembic current`
3. Run: `docker exec <container> alembic heads`
4. Compare: if current revision does not match head, migrations are pending

**If migrations are pending:**
- Report the current and head revisions
- If a migrate command is configured in Integration Verification, run it automatically
- Re-check after migration

**Report format:**
```
### Migration Status: PASS|WARN|FAIL
Current: <revision>
Head: <revision>
```

## Layer 4: Browser Smoke Test

**Skip if:** MODE is `quick`, or Playwright MCP tools are not available.

**Requires:** Playwright MCP (`mcp__playwright__*` tools).

1. Determine the frontend URL from Integration Verification config, or try `http://localhost:3000`, `http://localhost:5173`, `http://localhost:8080`
2. Navigate to the frontend: `mcp__playwright__browser_navigate` with the URL
3. Wait for the page to load: `mcp__playwright__browser_wait_for` with a short timeout
4. Take a screenshot: `mcp__playwright__browser_take_screenshot`
5. Check for console errors: `mcp__playwright__browser_console_messages`
6. If a login page is detected, report it (don't attempt to log in)

**Report format:**
```
### Browser Smoke Test: PASS|WARN|FAIL
- Page loaded: yes/no
- Console errors: <count>
- Console warnings: <count>
- Screenshot: <path or inline>
```

## Final Report

Display a combined verification report:

```markdown
## Verification Report

| Check | Status | Details |
|-------|--------|---------|
| Containers | PASS/WARN/FAIL | X/Y healthy |
| API Health | PASS/WARN/FAIL | endpoints summary |
| Migrations | PASS/WARN/FAIL | current vs head |
| Browser | PASS/WARN/FAIL/SKIP | console errors, screenshot |

**Overall: PASS/WARN/FAIL**
```

Layers that were skipped (not applicable) show as `SKIP` with the reason.

WARN means non-critical issues (e.g., console warnings in browser, slow response times).
FAIL means critical issues (containers down, 500 errors, pending migrations).
