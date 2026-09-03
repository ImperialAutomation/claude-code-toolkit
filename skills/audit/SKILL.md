---
name: audit
description: Run project audits - i18n, env, deps, docker
argument-hint: "[i18n|env|deps|docker|all]"
user-invocable: true
---

# Project Audit

Run one or more project audits to check for common issues before deployment.

For security-specific audits (OWASP, secrets, headers), use `/security-audit` instead.

## Input

Audit type: `$ARGUMENTS` (default: all)
Valid values: `i18n`, `env`, `deps`, `docker`, `all`

## Execution

Run the requested audit(s). When `$ARGUMENTS` is empty or `all`, run all audits that are applicable (skip those that exit with code 2 — no relevant files found).

### Individual audits

**i18n** — Translation key audit:
```bash
~/.claude/bin/i18n-audit.py
```
Finds missing/unused/inconsistent i18n keys. Only applicable to frontend projects with locale files.

Keys sitting under a detected dynamic prefix (`t(\`admin.roles.${role}\`)`) land in a separate
**Undeterminable** bucket: they are reachable at runtime, so they are not counted as issues and
never appear in the unused list. Use `--json` for the full undeterminable key list, and
`--dynamic-limit N` to shorten the dynamic-key listing in the text report.

**env** — Environment variable audit:
```bash
~/.claude/bin/env-audit.sh
```
Checks .env vs .env.example sync, empty values, secrets in git. Only applicable if .env.example exists.

**deps** — Dependency vulnerability audit:
```bash
~/.claude/bin/deps-audit.sh
```
Runs npm audit and/or pip-audit. Requires package-lock.json or pyproject.toml.

**docker** — Docker configuration audit:
```bash
~/.claude/bin/docker-audit.sh
```
Checks for unpinned images, missing health checks, root users, hardcoded secrets.

## After running

1. Present a combined summary of all audit results.
2. For any issues found, offer concrete next steps:
   - **i18n**: add missing keys, remove unused keys. Never propose deleting an
     **undeterminable** key — the audit reports it precisely because it cannot tell
     whether the key is live. When the report carries the dynamic-key warning, the
     unused list still deserves a manual check before anything is deleted.
   - **env**: create missing variables, fill empty values
   - **deps**: suggest `npm audit fix` or package updates
   - **docker**: suggest specific fixes (pin versions, add HEALTHCHECK, add USER)
3. Exit code 2 means "not applicable" (no relevant files) — this is not a failure, just skip that audit.
