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

**Meerdere worktrees: zeg welke boom je bedoelt.** De venv wordt gezocht vanaf de
projectroot, en welke root dat is hangt af van wat je meegeeft:

- `project-test.sh` leidt de root af uit het testpad. Een pad in worktree B
  gebruikt de venv van B, ook als je shell in A staat; het script meldt het
  verschil. Paden uit twee roots tegelijk weigert het.
- `venv-run.sh` krijgt een commando, geen pad, en kan dus niets afleiden. Werk je
  in een andere boom dan `$PWD`, geef dan `--repo <dir>` mee:
  `~/.claude/bin/venv-run.sh --repo <worktree> alembic upgrade head`

Zonder dat draait de opdracht op de interpreter en dependency-set van de boom
waar je shell toevallig staat. Twee worktrees die maanden uit elkaar zijn
aangemaakt hebben zelden dezelfde Python-minorversie, en niets meldt dat.

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

**Co-Authored-By-trailer.** Elke agent-commit eindigt met de `Co-Authored-By`-trailer. Repo's die zwaardere review ophangen aan een `agent-authored`-label passen dat label zonder trailer nooit toe, waardoor de bijbehorende verplichte checklist stil niet draait — een groene gate die nooit gedraaid heeft. **Enforced, not advisory:** `hook-post-commit-trailer.sh` (PostToolUse op Bash) voegt de trailer alsnog toe aan een verse, ongepushte, niet-merge commit en meldt dat op stderr. Bewust NIET in `git-commit.sh`: dat script gebruik je ook zelf, en een trailer daar zou je eigen commits als agent-authored bestempelen.

### Git branches

Werk aan een issue → branchnaam VERPLICHT `issue-<nummer>-<slug>`, waar `<slug>` een korte kebab-case samenvatting van de issue-titel is. Bijv. issue #3 "Per-feature code discipline" → `issue-3-code-discipline`. Zo is elke branch traceerbaar naar zijn issue. Branches zonder issue (los experiment) mogen afwijken.

**Nooit committen op een base branch.** In repo's waar elke wijziging via een PR
binnenkomt is een commit op `develop`/`master`/`main` altijd een vergissing.
**Enforced, not advisory:** `git-commit.sh` leest de branch van de doelboom
(`--repo`, anders cwd) en weigert als die beschermd is. Welke branches dat zijn
staat per repo in `<repo>/.claude/protected-branches` (één naam per regel) of in
`git config --get-all toolkit.protectedBranch`; staat er niets, dan is niets
beschermd en verandert er niets. Commit dat bestand: ongetrackt bestaat het
alleen in de boom waar je het aanmaakte, dus een linked worktree ziet geen
config en de guard slaat daar nooit aan, precies waar de vergissing het vaakst
gebeurt. De git-config-route heeft dat probleem niet, want worktrees delen
`.git/config`. Een weigering kost één `switch -c`; een commit
op een base branch kost handwerk om te ontwarren. `--allow-protected` overrulet
het waar een directe commit de bedoeling is. Detached HEAD mag altijd (rebase,
bisect).

### Wat NIET werkt (ook al lijkt het logisch)

- `cd backend && python ...` — eerste woord is `cd`
- `source .venv/bin/activate && python ...` — eerste woord is `source`
- `/absolute/path/.venv/bin/python ...` — `*` matcht niet over `/`
- `python -m pytest ...` — alleen als `python` in PATH zit EN `Bash(python *)` allowed is

### Werkdirectory meegeven: `env -C`, nooit `cd &&`

**`cd <dir> && <cmd>` is enforced, not advisory.** `hook-auto-approve-bash.py`
denyt elke `cd` met een commando erachter, met een hint die de alternatieven
noemt. Ook binnen `~/Projects`, waar de hook zo'n keten vroeger stilletjes
goedkeurde: aan een goedgekeurde `cd`-keten zie je niet af dat dezelfde vorm
overal elders prompt, dus die uitzondering leerde juist het patroon aan dat de
frictie veroorzaakt. Een kale `cd <dir>` zonder vervolgcommando blijft ongemoeid.

Heeft een commando zijn werkdirectory echt nodig (een script dat `./.env` leest,
`npx playwright test` dat config en specs vanaf cwd resolvet), gebruik dan de
vorm die één commando blijft en dus gewoon matcht:

| In plaats van | Gebruik |
|---|---|
| `cd <dir> && git ...` | `git -C <dir> ...` |
| `cd <dir> && npm ...` | `npm --prefix <dir> ...` |
| `cd <dir> && <iets anders>` | `env -C <dir> <iets anders>` |

`env -C` wordt auto-approved onder twee voorwaarden tegelijk: `<dir>` ligt binnen
`~/Projects`, én `<cmd>` zou op zichzelf al goedgekeurd worden. Een niet-toegestaan
commando wordt er niet door witgewassen (`env -C <projectdir> ./start.sh` prompt
gewoon), en een `env -C /etc cat passwd` evenmin. `bash -c "cd x && ..."` lost
niets op; dat is net zo ongematcht als de kale `cd`.

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
- **Output van een ander commando naar een bestand: `~/.claude/bin/cmd-save.sh <outfile> <commando> [args...]`.** Een redirect verslaat permissiematching: de regel matcht op het eerste woord, dus `docker exec ... > /tmp/out` valt niet meer onder `Bash(docker *)` en prompt élke keer. De wrapper is één commando en matcht `Bash(~/.claude/bin/*)`. Hij geeft de exit-status van het commando zélf door (een mislukt commando schrijft anders een bestand en lijkt geslaagd, waarna je een foutmelding als data leest) en print het aantal bytes (een capture van 0 bytes is onzichtbaar tot iets verderop vreemd doet). stderr gaat standaard níet mee in het bestand, want een waarschuwing midden in een JSON-capture maakt die onparseerbaar; gebruik `--stderr merge` als de capture juist bedoeld is om een fout te diagnosticeren. Typisch voor database-, container- en cluster-CLI's: `cmd-save.sh /tmp/<project>-pods-<nr>.json kubectl get pods -o json`.
- **Kleurcodes in opgeslagen output: `~/.claude/bin/strip-ansi.sh <file> [<outfile>]`, nooit `| sed 's/\x1b\[[0-9;]*m//g'`.** Test-runner-output (vitest, pytest met kleur) zit vol ANSI-escapes, en een `grep ... | sed ... | head`-keten prompt élke keer op het `sed`-segment. Het script schrijft een schone kopie naar `<outfile>` (standaard `<file>.clean`) en laat de input ongemoeid; lees die kopie daarna met Read of Grep, dan verdwijnt de keten. Het verwijdert ook de cursorcodes en hyperlinks van vitest die die sed-regex laat staan. Maak je de capture zelf, gebruik dan meteen `cmd-save.sh --strip-ansi <outfile> <commando>`, dan is het bestand vanaf het begin schoon.
- Never use command substitution with pipes for API data
- Never write files via Bash (no `echo >`, `cat <<`, `tee`, heredoc). These don't match permission patterns like `Bash(git *)`. Instead: use the Write tool to write to `/tmp/` with a project+nr-specific name (see "Tmp-bestandsnamen"), then reference the file in Bash (e.g., `git commit -F /tmp/acme-webshop-commit-msg-42.txt`, `gh issue create --body-file /tmp/acme-webshop-issue-body-42.md`).
- **Tmp-bestandsnamen: ALTIJD uniek per project + taak.** NOOIT generieke namen als `/tmp/commit-msg.txt` of `/tmp/pr-body.md` — er draaien vaak meerdere agents tegelijk, ook in verschillende projecten, en die overschrijven elkaars bestand. Schema: `/tmp/<project>-<doel>-<nr>.<ext>`, waarbij `<project>` de basename van de working directory is, lowercase, niet-alfanumerieke tekens vervangen door `-` (bv. `~/Projects/Acme-Webshop` → `acme-webshop`), en `<nr>` het issue- of PR-nummer. Voorbeelden: `/tmp/acme-webshop-commit-msg-42.txt`, `/tmp/acme-webshop-pr-body-42.md`, `/tmp/acme-webshop-issue-body-42.md`. Zonder issue/PR-nummer: gebruik een kort beschrijvend doel (`/tmp/acme-webshop-deploy-log.txt`).
- Never use `python3 -c`, `sed`, or `awk` for file reading, writing, searching, or modifications. Use Grep/Read to find content, then Edit to replace. `python3 -c` is allowed for non-file operations (calculations, data transformations, etc.). **Enforced, not advisory:** `hook-auto-approve-bash.py` denies `sed -n 'X,Yp' <file>` and inline Python (`-c` or a heredoc) that opens a file for reading, with a hint naming the right tool. Writes and pure calculation still fall through to a normal prompt.
- Never wait for a file with `until <conditie>; do sleep N; done`. Dat is een compound command, dus permissiematching faalt op het tweede segment en het prompt elke keer. Gebruik `~/.claude/bin/wait-for-pattern.sh [--newer-than <epoch>] <file> <extended-regex> [timeout-seconds] [poll-seconds]`: die matcht `Bash(~/.claude/bin/*)` en draait promptloos; het bestand hoeft nog niet te bestaan. Voor containers is `~/.claude/bin/wait-for-healthy.sh <container>` het equivalent.

  **Wacht je op een bestand met een vaste naam, dan `--newer-than` meegeven.** Een voortgangsbestand per taak wordt door élke run van die taak hergebruikt, en niets leegt het tussendoor: de tweede run matcht binnen een seconde de `DONE` van de eerste, en je rapporteert het resultaat van de vorige run als dat van de nieuwe. Een volledig, plausibel, verkeerd antwoord, en niets in het bestand zegt welke run het schreef; exit 0 ook niet, de mtime wel. Leg `SPAWNED_AT=$(date +%s)` vast vóór je het proces start en geef die mee: alleen een write ná dat moment kan het patroon dan vervullen. **Enforced, not advisory:** `hook-auto-approve-bash.py` denyt de bestandsvormen (`[ -f FILE ]`, `test -f FILE`, `grep PATTERN FILE`) met een hint. Lussen die op iets anders wachten (HTTP-status, containertoestand, exit-status) worden niet geraakt en vallen door naar een normale prompt.
- Voor HTTP-smoketests: `~/.claude/bin/http-status.sh [--body] [--max-time SECS] <url> [url...]`. De directe vorm (`curl -s -o /dev/null -w "%{http_code}\n" <url>`) wil je zelden maar één keer, en twee ervan op een regel is een compound command: alles na de `;` of `&&` blijft ongematcht en prompt élke keer, ook met een brede `Bash(curl *)`-regel. De wrapper is één commando en matcht `Bash(~/.claude/bin/*)`. Eén URL geeft alleen de status (past in een `if`), meerdere geven `<status>  <url>` per regel. Een 4xx/5xx is een geldig antwoord (exit 0); alleen transportfouten (DNS, connection refused, timeout) geven `ERR` en exit 1. Voor auth-headers, retries of JSON-parsing roep je `curl` gewoon direct aan; wachten tot een service omhoog is doe je met `wait-for-pattern.sh` of `wait-for-healthy.sh`.
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
