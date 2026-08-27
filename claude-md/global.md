# Global CLAUDE.md

## General Preferences

- Code comments in English
- Communication in Dutch (unless context requires otherwise)
- Commit messages in English, concise and descriptive
- `docker compose` (with space), never `docker-compose` (with hyphen)

## Bash Permissies (CRITICAL)

Twee regels die ALTIJD gelden:

1. NOOIT `cd path &&` voor een commando zetten — permissies matchen op het EERSTE woord (`cd`), niet op het eigenlijke commando
2. NOOIT absolute paden naar venv binaries gebruiken — `*` in permissiepatronen matcht NIET over `/` heen, dus `/home/.../venv/bin/python` matcht niet op `Bash(*/python *)`

### Venv commando's

VERPLICHT `~/.claude/bin/` wrapper scripts gebruiken voor venv binaries:

    ~/.claude/bin/project-test.sh [pytest-args...]    # pytest
    ~/.claude/bin/venv-run.sh python -c "..."          # python, pip, alembic, etc.

Deze scripts:
- Matchen `Bash(~/.claude/bin/*)` (altijd allowed, geen permissieprompt)
- Detecteren automatisch de project venv (.venv, backend/.venv, etc.)
- Valideren dat je binnen ~/Projects/ draait

### Git commits

ALTIJD `~/.claude/bin/git-commit.sh` — NOOIT raw `git commit`.

**Kort** (single-line, geen body):
```bash
~/.claude/bin/git-commit.sh "feat: short description"
```

**Lang** (met body) — gebruik een project+nr-specifieke bestandsnaam (zie "Tmp-bestandsnamen" hieronder). Voorbeeld voor een project in `~/Projects/Acme-Webshop`, issue #42:
1. `Read` tool op `/tmp/acme-webshop-commit-msg-42.txt` (ook als het niet bestaat — fout is onschuldig, maakt Write mogelijk)
2. `Write` tool: commit message naar `/tmp/acme-webshop-commit-msg-42.txt`
3. `~/.claude/bin/git-commit.sh --file /tmp/acme-webshop-commit-msg-42.txt`

NOOIT: `git commit -m`, `git commit -F`, heredocs, multi-arg met veel regels, of Bash voor file-aanmaak.

### Git branches

Werk aan een issue → branchnaam VERPLICHT `issue-<nummer>-<slug>`, waar `<slug>` een korte kebab-case samenvatting van de issue-titel is. Bijv. issue #3 "Per-feature code discipline" → `issue-3-code-discipline`. Zo is elke branch traceerbaar naar zijn issue. Branches zonder issue (los experiment) mogen afwijken.

### Wat NIET werkt (ook al lijkt het logisch)

- `cd backend && python ...` — eerste woord is `cd`
- `source .venv/bin/activate && python ...` — eerste woord is `source`
- `/absolute/path/.venv/bin/python ...` — `*` matcht niet over `/`
- `python -m pytest ...` — alleen als `python` in PATH zit EN `Bash(python *)` allowed is

## Code Quality

- If ANY verification fails, STOP and reassess
- DRY: check if similar logic already exists before implementing; create shared functions instead of duplicating
- SOLID: single responsibility per class/module, open for extension but closed for modification, depend on abstractions not concretions. Apply pragmatically — don't over-engineer for hypothetical future requirements
- No magic strings/numbers: use constants, enums, or configuration for all business logic values
- Remove obsolete code always. Never keep old files "just in case" — a replacement removes the old version in the same PR (no dead parallel paths)
- Always read a model/class file before assuming its attributes
- Never skip validation because "it should work"
- Never commit code that hasn't been tested

## Available Utilities

- **Running tests** (`~/.claude/bin/project-test.sh`): see "Bash Permissies" section above
- **Venv commands** (`~/.claude/bin/venv-run.sh <cmd> [args]`): run any venv binary (python, pip, alembic, etc.)
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
- Bash tool: always save API responses to a file first, then read the file. Use `~/.claude/bin/gh-save.sh /tmp/<project>-<purpose>-<nr>.json <gh-args>` to save `gh` output (shell redirects like `>` trigger permission prompts).
- Never use command substitution with pipes for API data
- Never write files via Bash (no `echo >`, `cat <<`, `tee`, heredoc). These don't match permission patterns like `Bash(git *)`. Instead: use the Write tool to write to `/tmp/` with a project+nr-specific name (see "Tmp-bestandsnamen"), then reference the file in Bash (e.g., `git commit -F /tmp/acme-webshop-commit-msg-42.txt`, `gh issue create --body-file /tmp/acme-webshop-issue-body-42.md`).
- **Tmp-bestandsnamen: ALTIJD uniek per project + taak.** NOOIT generieke namen als `/tmp/commit-msg.txt` of `/tmp/pr-body.md` — er draaien vaak meerdere agents tegelijk, ook in verschillende projecten, en die overschrijven elkaars bestand. Schema: `/tmp/<project>-<doel>-<nr>.<ext>`, waarbij `<project>` de basename van de working directory is, lowercase, niet-alfanumerieke tekens vervangen door `-` (bv. `~/Projects/Acme-Webshop` → `acme-webshop`), en `<nr>` het issue- of PR-nummer. Voorbeelden: `/tmp/acme-webshop-commit-msg-42.txt`, `/tmp/acme-webshop-pr-body-42.md`, `/tmp/acme-webshop-issue-body-42.md`. Zonder issue/PR-nummer: gebruik een kort beschrijvend doel (`/tmp/acme-webshop-deploy-log.txt`).
- Never use `python3 -c`, `sed`, or `awk` for file reading, writing, searching, or modifications. Use Grep/Read to find content, then Edit to replace. `python3 -c` is allowed for non-file operations (calculations, data transformations, etc.).
- For batch operations on multiple issues, always use `~/.claude/bin/` scripts (e.g., `batch-issue-status.sh`, `batch-issue-view.sh`). Never use `for` loops or chained `&&` commands to repeat `gh` calls.

<!--
RTK (Rust Token Killer) — optional, install separately: https://github.com/rtk-ai/rtk
  curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
  rtk init -g          # registers the `rtk hook claude` hook in ~/.claude/settings.json
Without both steps the import below loads instructions for a tool that is not
installed. Claude Code silently ignores a missing import, so RTK.md is safe to
delete when RTK is not in use.
-->
@RTK.md
