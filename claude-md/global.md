# Global CLAUDE.md

## General Preferences

- Code comments in English
- Communication in Dutch (unless context requires otherwise)
- Commit messages in English, concise and descriptive
- `docker compose` (with space), never `docker-compose` (with hyphen)

### Geen em-dashes (—)

GEEN em-dash in tekst die een mens leest: niet in antwoorden aan de gebruiker,
niet in UI-teksten/vertaalbestanden, niet in commit messages, PR-bodies of
issue-bodies.

Kies in plaats daarvan de leesteken die de zin echt nodig heeft:

| In plaats van | Gebruik |
|---|---|
| Bijzin die iets toelicht | Puntkomma, of splits in twee zinnen |
| Opsomming die volgt | Dubbele punt |
| Terzijde midden in een zin | Komma's, of haakjes |
| Bereik (2020—2024) | En-dash of "tot" |
| Attributie ("— Jan") | Laat het streepje weg |

De en-dash (–) en het koppelteken (-) blijven gewoon toegestaan waar ze
typografisch horen.

## Bash Permissies (CRITICAL)

Permissieregels matchen op het EERSTE woord van elk segment. Een vorm die daar
iets anders zet dan het eigenlijke commando (`cd x &&`, `source ... &&`, een
`for`/`until`-lus, een redirect `>`, een tweede segment na `;`/`&&`) prompt, ook
als het commando zelf allowed is. Alles in `~/.claude/bin/` matcht
`Bash(~/.claude/bin/*)` en draait promptloos; daar staan de wrappers die zo'n vorm
één commando maken.

`hook-auto-approve-bash.py` weigert de meeste van deze vormen met een deny-hint die
het alternatief en de voorwaarden noemt. **Volg de hint**, zoek geen omweg
(`bash -c "cd x && ..."` is net zo ongematcht).

| Niet | Wel |
|---|---|
| `cd <dir> && <cmd>` | `git -C <dir>`, `npm --prefix <dir>`, anders `env -C <dir> <cmd>` |
| `sed -n 'X,Yp' <file>`, inline Python die een bestand leest | Read, Grep, Edit |
| `until [ -f F ]; do sleep N; done` | `wait-for-pattern.sh`; `wait-for-healthy.sh <container>` voor containers |
| `<cmd> > /tmp/out` | `cmd-save.sh <outfile> <cmd>` |
| `for i in 1 2 3; do <cmd>; done` (metingen) | `repeat-cmd.sh <count> <cmd>` |
| `for`/`&&`-reeks van `gh`-calls | `batch-issue-status.sh`, `batch-issue-view.sh` |
| twee `curl -w "%{http_code}"` op één regel | `http-status.sh <url>...` |
| `... \| sed 's/\x1b\[[0-9;]*m//g'` | `strip-ansi.sh <file>`, of meteen `cmd-save.sh --strip-ansi` |
| `source .venv/bin/activate && python ...` | `venv-run.sh python ...` (zie Venv) |

`env -u NAME` en `env FOO=1 <cmd>` gaan net zo door als `env -C`, los of
gecombineerd; andere `env`-opties (`-i`, `-S`, `--`) en een `-u` ná `FOO=1`
prompten.

**Wrappers die een commando uitvoeren** (`cmd-save.sh`, `repeat-cmd.sh`,
`venv-run.sh`) geven niets wat het kale commando niet heeft, en ook niet minder: je
eigen allowregels voor het commando tellen mee. Weigert de hook zo'n aanroep, voer
dan het kale commando uit dat de hint noemt. Details per wrapper (opties, exit codes,
valkuilen): `~/.claude/bin/<script> --help`.

### Venv

- pytest: `~/.claude/bin/project-test.sh [pytest-args...]`; python, alembic, ruff,
  mypy, uv: `~/.claude/bin/venv-run.sh <cmd> [args...]`. Beide vinden de project-venv
  zelf en draaien alleen binnen `~/Projects`. Een directe
  `<pad>/.venv/bin/{python,pytest,alembic,ruff,mypy,uv}` wordt ook goedgekeurd;
  `pip` en `python3` prompten, ook achter `venv-run.sh`. `python -m pytest` alleen als
  `python` in PATH zit en `Bash(python *)` allowed is.
- **Meerdere worktrees: zeg welke boom je bedoelt.** `project-test.sh` leidt de venv
  af uit het testpad. `venv-run.sh` krijgt geen pad: werk je in een andere boom dan
  `$PWD`, geef `--repo <worktree>` mee. Anders draait het op de interpreter van de
  boom waar je shell staat, en een andere Python-minorversie meldt niets.

### Git commits

ALTIJD `~/.claude/bin/git-commit.sh [--repo <dir>]`. NOOIT `git commit -m`,
`git commit -F`, heredocs, multi-arg met veel regels, of Bash voor file-aanmaak.

- **Kort:** `~/.claude/bin/git-commit.sh "feat: short description"`
- **Lang:** `Read` op `/tmp/<project>-commit-msg-<nr>.txt` (ook als het niet bestaat;
  de fout is onschuldig en maakt Write mogelijk), `Write` de message daarheen, dan
  `~/.claude/bin/git-commit.sh --file /tmp/<project>-commit-msg-<nr>.txt`.
- Elke agent-commit eindigt met de `Co-Authored-By`-trailer. `hook-post-commit-trailer.sh`
  vult een vergeten trailer aan en meldt op stderr wanneer dat niet kan. Een commit
  die in dezelfde call gepusht wordt krijgt hem niet: **commit en push in aparte calls**.
- Nooit committen op een base branch. `git-commit.sh` weigert een branch die de repo
  beschermt via een gecommitte `.claude/protected-branches` (één naam per regel) of
  `git config toolkit.protectedBranch`; `--allow-protected` waar een directe commit
  de bedoeling is.

### Git branches

Werk aan een issue → branchnaam VERPLICHT `issue-<nummer>-<slug>`, waar `<slug>` een korte kebab-case samenvatting van de issue-titel is. Bijv. issue #3 "Per-feature code discipline" → `issue-3-code-discipline`. Zo is elke branch traceerbaar naar zijn issue. Branches zonder issue (los experiment) mogen afwijken.

## Code Quality

- If ANY verification fails, STOP and reassess
- DRY: check if similar logic already exists before implementing; create shared functions instead of duplicating
- SOLID: single responsibility per class/module, open for extension but closed for modification, depend on abstractions not concretions. Apply pragmatically — don't over-engineer for hypothetical future requirements
- No magic strings/numbers: use constants, enums, or configuration for all business logic values
- Remove obsolete code always. Never keep old files "just in case" — a replacement removes the old version in the same PR (no dead parallel paths). **Hetzelfde geldt voor de tests die het dekten:** een test die een verwijderd symbool importeert breekt de hele suite (collection error: geen enkele test draait meer, ook de gezonde niet), en een test die een verdwenen gedraging beschrijft staat vacuüm groen. Beide horen in dezelfde PR opgelost. Grep de testboom op de oude naam vóór je commit
- Always read a model/class file before assuming its attributes
- Never skip validation because "it should work"
- Never commit code that hasn't been tested

## Available Utilities

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
  - `python3 -c`, `sed` and `awk` never for file reading, writing, searching or modifying; `python3 -c` for calculation or data transformation is fine
- Save API responses to a file first, then read the file: `~/.claude/bin/gh-save.sh /tmp/<project>-<purpose>-<nr>.json <gh-args>` for `gh`, `cmd-save.sh` for anything else.
- Never use command substitution with pipes for API data
- Never write files via Bash (no `echo >`, `cat <<`, `tee`, heredoc): Write the file, then reference it (`git-commit.sh --file ...`, `gh issue create --body-file ...`).
- **Tmp-bestandsnamen: ALTIJD uniek per project + taak**, want parallelle agents overschrijven elkaars `/tmp/pr-body.md`. Schema: `/tmp/<project>-<doel>-<nr>.<ext>`; `<project>` is de basename van de working directory, lowercase, niet-alfanumeriek → `-` (`~/Projects/Acme-Webshop` → `acme-webshop`), `<nr>` het issue- of PR-nummer, of anders een kort beschrijvend doel (`/tmp/acme-webshop-deploy-log.txt`).
- **Scratchbestanden: in de scratchpad, anders in `/tmp`, nooit in een gebruikersmap** (`~/Downloads`, `~`, de projectboom): daar ruimt niemand ze op en elke `rm` prompt. Schrijft een recept of skill een `/tmp/<project>-...`-pad voor (commit-messages, PR/issue-bodies, `gh-save.sh`-captures), volg dat; die paden zijn hardcoded en een subagent heeft niet altijd een scratchpad.
- **De ene uitzondering: wat een container moet mounten.** Docker Desktop deelt `/tmp` niet met zijn VM, dus zo'n bestand of boom gaat alleen via `~/.claude/bin/docker-scratch.sh` (`dir`/`worktree`/`clean`; regels en exit codes in `--help`). Ruim op met `clean`, niet met `rm -rf`.

<!--
RTK (Rust Token Killer) — optional, install separately: https://github.com/rtk-ai/rtk
  curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
  rtk init -g          # registers the `rtk hook claude` hook in ~/.claude/settings.json
Without both steps the import below loads instructions for a tool that is not
installed. Claude Code silently ignores a missing import, so RTK.md is safe to
delete when RTK is not in use.
-->
@RTK.md
