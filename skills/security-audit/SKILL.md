---
name: security-audit
description: OWASP-guided security code review for a specific domain or issue
argument-hint: "<issue-number|domain>"
user-invocable: true
---

# Security Audit

Perform a structured, OWASP-guided security code review for a specific security domain. Designed to work with security epic sub-issues — reads the issue to understand what domain to audit, then systematically scans the codebase and produces a structured report.

## Input

`$ARGUMENTS` — either a GitHub issue number (e.g., `631`) or a security domain keyword.

**Supported domains:**
- `dependencies` — Dependency vulnerability audit (npm + pip)
- `auth` — Authentication & authorization review
- `input-validation` — OWASP Top 10 input validation (SQLi, XSS, SSRF, etc.)
- `file-uploads` — File upload security review
- `headers` — HTTP security headers audit
- `rate-limiting` — Rate limiting review
- `database` — Database security review
- `infrastructure` — Infrastructure, secrets, Docker, session security
- `pentest` — OWASP ZAP baseline scan

If a number is provided, fetch the issue and infer the domain from its title/body.

## Phase 1: Determine Scope

### If `$ARGUMENTS` is a number:

```bash
~/.claude/bin/gh-save.sh /tmp/security-audit-$ARGUMENTS.json issue view $ARGUMENTS --json title,body,labels
```

Read the file and determine which domain to audit from the issue content.

### If `$ARGUMENTS` is a domain keyword:

Use it directly.

## Phase 2: Execute Domain-Specific Audit

Each domain has a specific audit procedure. Follow the relevant one below.

---

### Domain: `dependencies`

1. Run the automated scanner:
```bash
~/.claude/bin/deps-audit.sh
```
2. Read the output and categorize findings by severity.
3. For each critical/high vulnerability, check if the package is actually used in a reachable code path (not just a transitive dependency).

**Report sections:** Findings table, remediation steps, accepted risks (if any).

---

### Domain: `auth`

Systematic code review of authentication and authorization:

1. **Find auth files:** Use Glob for `**/auth/**`, `**/security.*`, `**/middleware.*`, `**/dependencies.*`
2. **JWT review:** Read token creation and validation code. Check:
   - Algorithm (HS256 is OK for single-service, RS256 for multi-service)
   - Token expiration (should be ≤4 hours for access tokens)
   - Refresh token handling
   - Secret key source (must be from environment, not hardcoded)
3. **Password handling:** Check hashing algorithm (bcrypt/argon2 required, no MD5/SHA1)
4. **Default-deny posture:** Verify authorization defaults to deny:
   - New endpoints must require explicit permission grants (not "allow all, then restrict")
   - New roles start with zero permissions
   - Missing auth decorator = blocked request, not open access
5. **Permission system:** Read permission/role definitions. Check:
   - All protected endpoints use auth decorators
   - No endpoints accidentally public
   - Permission inheritance is correct (higher roles get lower permissions)
6. **Object-level authorization (IDOR prevention):** For every resource endpoint, verify:
   - Not just "can user access type X" but "can user access *this specific* resource"
   - Ownership checks: `WHERE user_id = current_user.id`
   - Test exists: "User A tries to access User B's resource" → must return 403/404
7. **Privilege escalation:** Search for patterns where user input could influence authorization:
   - User ID from request body instead of token
   - Missing ownership checks on resources
   - Role/permission fields in update schemas that should be read-only

**Report sections:** Auth mechanism summary, findings, risk assessment.

---

### Domain: `input-validation`

OWASP Top 10 focused review. Verify defense-in-depth: input should be validated at multiple independent layers, so removing one layer does not compromise security.

**Layer check (verify each layer is present):**
- Layer 1: Type system / schema validation (shape, presence, bounds — e.g., Pydantic, Zod)
- Layer 2: Character / format restrictions (whitelist allowed chars, reject unexpected patterns)
- Layer 3: Explicit security pattern checks (path traversal `..`, null bytes, injection patterns)
- Layer 4: Downstream sanitization (parameterized queries, shell-escaping, HTML-encoding)

**Specific vulnerability checks:**

1. **SQL Injection:**
   - Search for raw SQL: `Grep` for `text(`, `execute(`, `raw_connection`, `.raw(`, `f"SELECT`, `f"INSERT`, `f"UPDATE`, `f"DELETE`
   - Verify all queries use ORM or parameterized statements
2. **XSS:**
   - Search for `dangerouslySetInnerHTML`, `innerHTML`, `document.write`
   - Check React components for unescaped user input
   - Review any server-side HTML rendering
3. **Command Injection:**
   - Search for `subprocess`, `os.system`, `os.popen`, `exec(`, `eval(`
   - Verify user input never reaches shell commands
4. **Path Traversal:**
   - Search for file path construction with user input
   - Check for `../` sanitization, `os.path.join` with user input
5. **SSRF:**
   - Search for outbound HTTP requests (`requests.get`, `httpx`, `fetch`, `urllib`)
   - Check if user input can influence target URLs

**Report sections:** Per-category findings with file:line references, severity, remediation.

---

### Domain: `file-uploads`

1. **Find upload handling:** Glob for `**/upload*`, `**/photo*`, `**/file*`, `**/media*`
2. **Read the upload code** and check:
   - Server-side MIME type validation (not just extension)
   - File size limits enforced server-side
   - No user-controlled file paths
   - Files are processed/re-encoded (not stored raw)
   - Storage permissions (files not publicly accessible without auth)
   - Image processing library version (Pillow CVEs)
3. **Run secret scan** for any hardcoded storage credentials:
```bash
~/.claude/bin/secret-scan.sh
```

**Report sections:** Upload flow diagram, validation checks present, gaps found.

---

### Domain: `headers`

1. **Check if target is available.** Ask the user for the URL if not obvious.
2. **Run automated header check:**
```bash
~/.claude/bin/security-headers-check.sh <url>
```
3. **Review the application code** for where headers could be added:
   - Search for middleware configuration in the backend
   - Check for existing security header middleware
   - Identify the right place to add missing headers
4. **Generate implementation guidance** for missing headers with recommended values.

**Report sections:** Current header status, missing headers with recommended values, implementation location.

---

### Domain: `rate-limiting`

1. **Find existing rate limiting:** Grep for `rate_limit`, `throttle`, `slowapi`, `RateLimiter`, `limiter`
2. **Identify endpoints that need rate limiting:**
   - Auth endpoints (login, register, forgot-password, verify)
   - File upload endpoints
   - Search/query endpoints
   - Any endpoint that triggers expensive operations (AI, email, payment)
3. **Check for existing middleware:** Read `main.py` and middleware configurations
4. **Assess current coverage:** Map which endpoints have limits vs. which need them

**Report sections:** Current rate limiting map, unprotected critical endpoints, implementation recommendation.

---

### Domain: `database`

1. **ORM safety:** Verify all database operations use ORM (SQLAlchemy)
   - Grep for raw SQL patterns (see input-validation domain)
   - Check Alembic migrations for raw SQL that could be vulnerable
2. **Mass assignment:** Check Pydantic schemas for:
   - Fields that should be read-only (id, created_at, role) not in update schemas
   - No direct `**request.dict()` to ORM model without schema validation
3. **Sensitive data exposure:** Check API response schemas for:
   - Password hashes never returned
   - Internal IDs/tokens not exposed unnecessarily
   - Email addresses only returned to the owning user
4. **Credentials:** Verify database connection uses environment variables

**Report sections:** Query safety assessment, schema review, data exposure check.

---

### Domain: `infrastructure`

1. **Run automated scans:**
```bash
~/.claude/bin/secret-scan.sh
~/.claude/bin/env-audit.sh
~/.claude/bin/docker-audit.sh
```
2. **Manual checks:**
   - HTTPS enforcement configuration
   - Session/cookie security flags
   - Logging — search for patterns that might log sensitive data (passwords, tokens, PII)
   - Error handling — check if error responses leak internal details (stack traces, SQL queries)

**Report sections:** Automated scan results, manual findings, remediation steps.

---

### Domain: `pentest`

1. **Confirm target URL** with the user
2. **Run OWASP ZAP baseline scan:**
```bash
~/.claude/bin/owasp-zap-scan.sh <url>
```
3. **Read the generated reports** (JSON + markdown in `/tmp/zap-results/`)
4. **Triage findings:** Classify each as actionable vs. false positive vs. accepted risk

**Report sections:** ZAP scan summary, triaged findings, remediation priorities.

---

## Phase 3: Generate Report

Produce a structured report with:

### Report Format

```markdown
## Security Audit Report: <domain>

**Issue:** #<number> (if applicable)
**Date:** <today>
**Auditor:** Claude Code (automated)

### Executive Summary
<1-3 sentences: overall assessment and critical findings count>

### Findings

| # | Severity | Finding | File | Remediation |
|---|----------|---------|------|-------------|
| 1 | CRITICAL | ... | path:line | ... |
| 2 | HIGH | ... | path:line | ... |
| 3 | MEDIUM | ... | path:line | ... |

### Detailed Findings
<per finding: description, evidence, remediation steps>

### Verified Controls
<what was checked and found to be secure — important for audit trail>

### Recommendation
<PASS / PASS WITH WARNINGS / FAIL — and next steps>
```

## Phase 4: Post Report to Issue

If `$ARGUMENTS` was an issue number:

1. Write the report to `/tmp/security-audit-report-$ARGUMENTS.md` using the Write tool
2. Post as issue comment:
```bash
gh issue comment $ARGUMENTS --body-file /tmp/security-audit-report-$ARGUMENTS.md
```
3. If all findings are informational or verified-secure:
   - Suggest closing the issue (don't close it — let the user decide)
4. If actionable findings exist:
   - Keep the issue open
   - Suggest adding the findings as acceptance criteria checkboxes

If `$ARGUMENTS` was a domain keyword:
- Present the report directly to the user
- Suggest creating an issue if actionable findings exist
