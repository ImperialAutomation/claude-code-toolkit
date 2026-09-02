---
name: retro
description: End-of-session retrospective. Captures knowledge from any working session (debug, implementation, config, deployment) as reusable scripts, CLAUDE.md procedures, or skill proposals. Run before ending a session to prevent knowledge loss.
argument-hint: [focus-area]
user-invocable: true
---

# Session Retrospective

Capture operational knowledge from the current session before it is lost to compaction. Turn lessons learned into permanent, reusable artefacts.

## Input

Optional focus area: `$ARGUMENTS` (e.g. "auth", "deployment", "database"). If provided, narrow the retro to that topic. If empty, review the full session.

## Phase 1: Analyse the Session

Review the conversation for knowledge worth preserving. Look for:

**From debug sessions:**
- Multiple approaches were tried before one worked
- A workaround was discovered for a known limitation
- A specific sequence of steps was required (auth flow, API call order, environment setup)
- Configuration or credentials were needed in a non-obvious way

**From implementation sessions:**
- An architectural decision was made after evaluating alternatives (capture the reasoning, not just the choice)
- A library or tool required non-obvious configuration
- A pattern emerged that should be followed consistently (e.g. how to add a new API endpoint, how to structure a migration)
- Integration between components required a specific approach (e.g. order of initialisation, correct event to hook into)

**From deployment/config sessions:**
- Infrastructure required a specific setup sequence
- Environment variables or service configuration that was non-trivial to get right
- Permissions, networking, or DNS that required specific steps

For each finding, summarise:
- **Problem:** what was being attempted
- **Failed approaches:** what did not work and why
- **Working solution:** what finally worked
- **Root cause:** why the working approach succeeds

If the session had no knowledge worth capturing, say so. Do not invent artefacts.

## Phase 1b: Permission Friction

Run the friction scanner to surface allowlist gaps the conversation itself won't mention:

```bash
python3 ~/.claude/bin/permission-friction.py --days 30
```

(Or via venv: `~/.claude/bin/venv-run.sh python ~/.claude/bin/permission-friction.py --days 30`.)

This scans the current project's transcripts and reports total Bash calls, an estimated prompted count, explicit denials, and the top prompt-causing patterns — grouped by command and the specific construct that defeated matching (no allow rule, unmatched chain segment, `cd`-prefix, command substitution, heredoc). No hardcoded allowlist: it derives rules live from the merged global + project + local `settings.json` files.

**The rule: a pattern seen in >= 2 sessions is a candidate for enforcement, not documentation.** Per the code-review rule ("a convention violated more than once is a hook, not a docs line"), for each pattern the report flags as recurring (`sessions >= 2`), propose ONE concrete remedy in the retro summary:

- **Allowlist rule** — a missing `Bash(cmd *)` entry that would cover the pattern outright (safe, read-only, or already-reviewed commands)
- **`bin/` wrapper script** — for compound commands (`&&`, `;`, `|` chains) that keep defeating first-token matching; wrap the sequence so permissions match on the wrapper path instead
- **Hook change** — for patterns already handled case-by-case by `hook-auto-approve-bash.py` logic elsewhere, extend that hook instead of adding narrow allowlist entries

If the report finds no recurring patterns (all counts are 1, or `patterns` is empty), say so — do not invent a remedy for single-occurrence noise.

For one-off, low-risk **read-only** allowlist gaps that don't recur, mention the built-in `/fewer-permission-prompts` skill as the quick path — it scans transcripts and proposes a prioritized allowlist addition directly, without going through a full retro.

## Phase 2: Classify Each Finding

Assign each finding to exactly one category:

| Category | Output | Where it goes |
|----------|--------|---------------|
| Project procedure | Section in project CLAUDE.md under `## Learned Procedures` | Project repo only |
| Architectural decision | Section in project CLAUDE.md under `## Design Decisions` | Project repo only |
| Utility script | Executable script in project `scripts/` directory | Project repo only |
| Project pattern | Section in project CLAUDE.md under `## Project Patterns` | Project repo only |
| Environment/config note | Section in project CLAUDE.md under `## Environment Notes` | Project repo only |
| Claude Code tool behaviour | Memory file in `~/.claude/projects/*/memory/` | Memory only |
| Toolkit candidate | All of the above PLUS a proposal file | Project repo + `~/.claude/toolkit-proposals/` |

**Default is always project-local.** A finding is a toolkit candidate ONLY if it meets ALL of these criteria:
- It is not tied to a specific project's URLs, endpoints, or data model
- The underlying pattern (not the specific implementation) would be useful in at least one other project
- It can be parameterised (base URL, credentials source, etc.)

**Claude Code tool behaviour** includes: Bash permission workarounds, native tool quirks, permission patterns, sandbox limitations, tool output handling. These are NOT project-specific and belong in memory regardless of whether `docs/development/` exists.

## Phase 2b: Determine Output Destination

Before generating output, detect where operational findings should be written:

**Check:** Does `docs/development/` exist in the current project root?

**If `docs/development/` EXISTS:**
- Project-specific operational findings (procedures, patterns, troubleshooting) → `docs/development/`
- Claude Code tool behaviour → memory (always)
- CLAUDE.md additions → still go to CLAUDE.md (architectural decisions, environment notes)
- After creating a new file in `docs/development/`, update the project's root CLAUDE.md "Operational Guidelines" section with a link to the new file

**If `docs/development/` does NOT exist:**
- All findings → memory (current behaviour, unchanged)
- CLAUDE.md additions → still go to CLAUDE.md

## Phase 3: Generate Output

### For CLAUDE.md additions

Read the project's CLAUDE.md first. Append findings under the appropriate section (`## Learned Procedures`, `## Design Decisions`, `## Project Patterns`, or `## Environment Notes`). Create the section if it does not exist. Format as a concise procedure with DO and DO NOT bullets. Reference any created scripts.

Before adding, check if a similar procedure already exists — update it rather than creating a duplicate.

### For utility scripts

Create in the project's `scripts/` directory. Requirements:
- Self-contained and executable (`chmod +x`)
- Usage comment at the top
- Credentials from environment variables or .env, never hardcoded
- Error handling with clear messages
- Referenced from CLAUDE.md

### For docs/development/ files (when directory exists)

Write operational findings to `docs/development/` using the project's existing structure:
- Troubleshooting procedures → `docs/development/troubleshooting/<topic>.md`
- Development patterns → `docs/development/<topic>.md`
- Backend-specific patterns → `docs/development/backend/<topic>.md`
- Frontend-specific patterns → `docs/development/frontend/<topic>.md`

Format: concise markdown with a `# Title`, a short explanation of **why** this matters, and a **How to apply** section. Match the style of existing files in the directory.

After creating a new file, add a reference to the project's root CLAUDE.md under the "Operational Guidelines" section (or equivalent docs index).

**Index-entry norm — the index is a lookup table, not a summary.** The root CLAUDE.md is
loaded on every single session, so every character in it is paid for whether or not the
doc turns out to be relevant. Entries must be:

- **One doc per line**, as a list item: `- [topic-name](docs/development/topic-name.md) — hint (#issue)`
- **Hint only when the filename does not already carry it**, and then at most 100
  characters. The hint exists to close the gap between what the name says and what you
  need in order to decide whether to open the doc. When the name already says it
  (`docker-restart`), the name *is* the hint and adding one just repeats it. When two
  docs look alike by name, the hint is what tells them apart.
- **Never appended to an existing entry's line.** Adding a clause to the neighbouring
  entry is what turns a scannable index into an unreadable 2 kB paragraph. New finding,
  new line.

If the explanation does not fit in the hint, it belongs in the doc. The doc is only read
when relevant and can be as long as it needs to be; the index is read always.

Before adding an entry, check the section for a doc that already covers the topic and
update that entry instead of adding a near-duplicate. Never let the section exceed a
scannable size — if a section passes roughly 15 entries, propose splitting it by
subtopic rather than growing the list.

**Index each doc in exactly one place.** A project may also have scoped CLAUDE.md files
(`frontend/CLAUDE.md`, `backend/app/CLAUDE.md`). Those load on demand — reading any file
under `frontend/` pulls in `frontend/CLAUDE.md`, and a backend session never pays for it.
So before adding an entry to the root index, grep the scoped files too: a doc listed
there must NOT be repeated in the root. Checking only the root is how a doc ends up
indexed twice.

Two caveats before moving entries out of the root to buy that saving. The trigger is a
**Read** on a path inside the tree — directory listings and content searches do not fire
it. And the mechanism is anchored to the session working directory, so it does **not**
fire in a sibling git worktree at all; entries moved out of the root are simply absent
there. Verify with `/context` (see "Memory files") rather than assuming either way.

If a relevant file already exists in `docs/development/`, update it rather than creating a duplicate.

### For auto-memory updates (Claude Code tool behaviour OR fallback)

Write to the project's auto-memory directory (`~/.claude/projects/*/memory/`) when:
1. The finding is about Claude Code tool behaviour (permissions, Bash workarounds, native tool quirks) — **always**, regardless of `docs/development/` existence
2. `docs/development/` does NOT exist — **all** findings go here as fallback

Steps:
- Create topic-specific files for detailed findings (e.g. `auth-patterns.md`, `deployment-notes.md`, `debugging-db.md`)
- Add a one-line link in `MEMORY.md` pointing to the topic file (e.g. `- See [auth-patterns.md](auth-patterns.md) for session auth flow`)
- Keep `MEMORY.md` entries brief — it has a 200-line limit and is always loaded into context
- If a relevant topic file already exists, append to it rather than creating a new one

### For toolkit candidates

Do everything above for the project-local version, then ALSO create a proposal file at `~/.claude/toolkit-proposals/<name>.md` containing:
- Name and one-line description
- The problem pattern it solves (generic, not project-specific)
- Which projects would benefit
- A sketch of what the generalised version would look like (parameterised script, or skill SKILL.md outline)

## Phase 4: Present Summary and Confirm

Group output into sections:

```
## Session Retro Summary

### Project artefacts
- CLAUDE.md: added/updated <section> with <description>
- docs/development/<file>.md: <what was captured> (if docs/development/ exists)
- scripts/<name>.sh: <what it does>
- memory/<topic>.md: <what was captured> (tool behaviour or fallback only)

### Toolkit candidates (if any)
- <name>: <one-line description> → ~/.claude/toolkit-proposals/<name>.md

### Permission friction (if any recurring patterns found)
- <pattern>: seen in N sessions → proposed remedy (allowlist rule / bin/ wrapper / hook change)
```

**Wait for confirmation before making any changes.**

After confirmation, make all changes and commit with message format:

```
retro: capture <brief description>

Artefacts:
- <list of files created/modified>
```

## Rules

- Never store credentials or secrets. Always reference environment variables.
- Prefer updating existing procedures over creating duplicates. Check CLAUDE.md and `docs/development/` first.
- Keep procedures concise. Future sessions need to scan them quickly.
- If the session had no knowledge worth capturing, say so. Do not invent artefacts.
- For design decisions, capture the reasoning and the alternatives considered — not just the final choice.
- When in doubt about toolkit candidacy, keep it project-local. Promote later via `/promote`.
- Claude Code tool behaviour (permissions, Bash patterns, sandbox workarounds) ALWAYS goes to memory, never to `docs/development/`.
