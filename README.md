# Claude Code Toolkit

A collection of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills, a global CLAUDE.md, and a project template for GitHub issue management, PR workflows, and development utilities.

## Philosophy

This toolkit separates concerns into four layers:

- **Skills** define **procedures** — the steps to follow when performing a task (e.g., how to implement an issue, how to decompose work)
- **Agents** define **constrained roles** — specialized sub-agents with restricted tool access for specific domains (e.g., read-only infrastructure analysis, deployment-scoped automation)
- **Rules** define **contextual policies** — standards that load only when relevant files are being edited (e.g., test quality rules load only for test files, documentation standards only for .md files)
- **CLAUDE.md** defines **global policies** — the standards and conventions that apply to every conversation (e.g., permission workarounds, code quality, communication preferences)

Rules keep the global CLAUDE.md lean by moving context-specific instructions out of the always-loaded file. Skills and agents reference policies from CLAUDE.md and rules rather than duplicating them.

## Installation

```bash
git clone https://github.com/JanKeijzer/claude-code-toolkit.git ~/Projects/claude-code-toolkit
cd ~/Projects/claude-code-toolkit
./install.sh
```

This creates five symlinks and copies one file:
- `~/.claude/skills` → `skills/` (all skills auto-discovered)
- `~/.claude/agents` → `agents/` (sub-agents auto-discovered)
- `~/.claude/bin` → `bin/` (helper scripts)
- `~/.claude/rules` → `rules/` (contextual rules, loaded based on file patterns)
- `~/.claude/CLAUDE.md` → `claude-md/global.md` (global policies)
- `~/.claude/settings.json` ← copied from `claude-md/settings-global.jsonc` (global permissions)

The settings file is copied (not symlinked) because Claude Code writes to it when you approve permissions during a session. Restart Claude Code after installation.

Skills are auto-discovered from `~/.claude/skills/*/SKILL.md`. Agents are auto-discovered from `~/.claude/agents/*.md`.

### Project Template

To set up a new project with a CLAUDE.md and settings:

```bash
# Project-specific policies
cp ~/Projects/claude-code-toolkit/claude-md/project-template.md /path/to/your/project/CLAUDE.md

# Project-specific permissions (remove comments and keep what applies)
mkdir -p /path/to/your/project/.claude
cp ~/Projects/claude-code-toolkit/claude-md/settings-template.jsonc /path/to/your/project/.claude/settings.json
```

Then fill in the sections relevant to your project. The settings template includes commented-out permissions for common tools (Docker, Python, Node, etc.) — uncomment what you need.

## Sub-Agents

The toolkit includes specialized sub-agents for issue creation, infrastructure management, and deployment. They work together with a clear separation of concerns:

```
Rough idea → issue-crafter → Well-defined issues → /decompose (if large) → /implement or /implement-epic
                  ↑                                                             ↓
         /refine (existing issues)                                      devops-automator (deploy)
                                                                             ↑
infra-maintainer (advises) → GitHub issue → /implement (code) ───────────────┘
                                           ↑
                              or: human creates issue directly
```

| Agent | Role | Tools | Model |
|-------|------|-------|-------|
| `issue-crafter` | Translates rough ideas into well-structured GitHub issues. Asks clarifying questions, proposes issues for approval, then creates them. | Read, Grep, Glob, Bash, Write | Sonnet |
| `infra-maintainer` | Read-only infrastructure advisor. Analyzes, diagnoses, and recommends — never makes direct changes. | Read, Grep, Glob, Bash (diagnostics only) | Sonnet |
| `devops-automator` | Deployment engineer. The only path to production — always through the pipeline. | Read, Write, Edit, Grep, Glob, Bash | Sonnet |

### issue-crafter

Translates rough ideas and descriptions into well-structured GitHub issues. Explores the codebase for context, asks clarifying questions about scope and acceptance criteria, and presents structured proposals for approval before creating anything. Recommends `/decompose` for issues that are too large for a single PR.

**Workflow (create):** rough idea → codebase exploration → clarifying questions → issue proposal → human approval → `gh issue create`
**Workflow (refine):** existing issue → read & assess → interactive Q&A → updated proposal → human approval → `gh issue edit`

The `/refine` skill provides a shortcut to invoke the refine workflow for a specific issue.

### infra-maintainer

Infrastructure advisor for self-managed VPS servers. Operates in **read-only** mode (no Write/Edit tools). Runs diagnostic commands, assesses risks, and proposes improvements as GitHub issues (with `proposal` + `infra` labels) — but only after human confirmation.

**Analysis domains:** server hardening, reverse proxy & SSL, backup & disaster recovery, monitoring & uptime, Docker management, security updates & vulnerability management.

### devops-automator

Deployment engineer responsible for CI/CD pipelines and the path to production. Every change follows the same path: branch → test → PR → review → merge → deploy. No exceptions.

**Scope:** GitHub Actions workflows, deployment strategies (lightweight restart vs. full rebuild), Docker image management, environment & secret management, branch protection rules.

### Why no "software engineer" agent?

Agents are valuable because of their **constraints**: infra-maintainer is read-only, devops-automator is deployment-scoped. A "software engineer" agent would need all tools with no specific restrictions — that's just Claude Code itself. The `/implement` skill already encapsulates the full workflow: issue → branch → code + tests → PR.

## Helper Scripts

The `bin/` directory contains reusable shell scripts that skills call instead of using inline `for` loops.

**Why?** Claude Code permissions match on the **first word** of a Bash command. An inline loop like `for issue in 15 16 17; do gh issue view $issue ...; done` gets blocked because the first word is `for`, not `gh`. By wrapping batch operations in scripts, permissions can match on the script path (`~/.claude/bin/*`).

### Issue & PR management

| Script | Usage | Description |
|--------|-------|-------------|
| `batch-issue-view.sh` | `batch-issue-view.sh [--output FILE] <repo> <issues...>` | Fetch full issue details as JSON array |
| `batch-issue-status.sh` | `batch-issue-status.sh <repo> <issues...>` | Fetch issue number/state/closed as JSON array |
| `batch-pr-for-issues.sh` | `batch-pr-for-issues.sh <repo> <issues...>` | Find merged/open PRs linked to issues |
| `find-tracking-pr.sh` | `find-tracking-pr.sh <repo> <issue>` | Find the tracking PR for a parent issue |
| `gh-issues-export.sh` | `gh-issues-export.sh [--repo R] [--state S] [--output F]` | Export GitHub issues to JSON file with search/filter |
| `gh-save.sh` | `gh-save.sh <output-file> <gh-args...>` | Save `gh` command output to file (avoids redirect prompts) |

### Git utilities

| Script | Usage | Description |
|--------|-------|-------------|
| `git-find-base-branch` | `git-find-base-branch` | Detect the base branch of the current branch |
| `git-cleanup-merged-branch.sh` | `git-cleanup-merged-branch.sh [feature] [base]` | Checkout base, pull, delete merged feature branch |
| `extract-issue-from-branch.sh` | `extract-issue-from-branch.sh` | Extract issue number from current branch name |

### Project audits

| Script | Usage | Description |
|--------|-------|-------------|
| `i18n-audit.py` | `i18n-audit.py [project-dir]` | Audit i18n translation keys (missing, unused, cross-locale) |
| `env-audit.sh` | `env-audit.sh [project-dir]` | Audit .env vs .env.example sync, empty values, secrets in git |
| `deps-audit.sh` | `deps-audit.sh [project-dir]` | Audit npm/pip dependencies for known vulnerabilities |
| `docker-audit.sh` | `docker-audit.sh [project-dir]` | Audit Docker config (unpinned images, health checks, secrets) |

### Security

| Script | Usage | Description |
|--------|-------|-------------|
| `secret-scan.sh` | `secret-scan.sh [project-dir]` | Scan codebase for hardcoded secrets, API keys, tokens |
| `security-headers-check.sh` | `security-headers-check.sh <url>` | Check HTTP security headers (CSP, HSTS, X-Frame-Options, etc.) |
| `owasp-zap-scan.sh` | `owasp-zap-scan.sh <url>` | OWASP ZAP baseline scan via Docker (requires running target) |

### Runtime verification

| Script | Usage | Description |
|--------|-------|-------------|
| `docker-health-check.sh` | `docker-health-check.sh [project-dir] [--timeout S] [--filter PREFIX]` | Runtime Docker container health verification (status, restarts, error logs) |
| `smoke-test.sh` | `smoke-test.sh [base-url] [--health-token TOKEN]` | API endpoint smoke testing with auto-discovery |

### Development tools

| Script | Usage | Description |
|--------|-------|-------------|
| `project-test.sh` | `project-test.sh [pytest-args...]` | Run pytest with automatic venv detection (guardrailed to ~/Projects/) |
| `venv-run.sh` | `venv-run.sh <cmd> [args...]` | Run any venv binary (python, pip, alembic) with auto-detection |
| `sync-toolkit.sh` | `sync-toolkit.sh <pull\|status\|drift>` | Sync toolkit from git sources (used by `/sync-toolkit` skill) |

### Hooks

| Script | Usage | Description |
|--------|-------|-------------|
| `hook-auto-approve-bash.sh` | PreToolUse hook in settings.json | Auto-approve safe compound commands (redirects, pipes, && chains, for loops) |
| `hook-block-destructive.sh` | PreToolUse hook in settings.json | Block destructive Bash commands (force push, rm -rf, DROP TABLE, etc.) |

All scripts are already allowed in the global settings (`~/.claude/settings.json`) installed by the toolkit.

## Repository Structure

```
claude-code-toolkit/
├── agents/                    ← sub-agent definitions
│   ├── issue-crafter.md       ← idea → well-defined GitHub issues
│   ├── infra-maintainer.md    ← read-only infrastructure advisor
│   └── devops-automator.md    ← deployment engineer
├── bin/                       ← helper scripts (batch operations, git utilities)
│   ├── batch-issue-view.sh    ← fetch multiple issues as JSON array
│   ├── batch-issue-status.sh  ← fetch issue status as JSON array
│   ├── git-find-base-branch   ← detect base branch of current branch
│   ├── git-cleanup-merged-branch.sh ← cleanup after PR merge
│   ├── batch-pr-for-issues.sh ← find merged/open PRs linked to issues
│   ├── find-tracking-pr.sh   ← find tracking PR for a parent issue
│   ├── extract-issue-from-branch.sh ← extract issue number from branch name
│   ├── i18n-audit.py              ← audit i18n translation keys across a project
│   ├── env-audit.sh               ← audit .env vs .env.example sync
│   ├── deps-audit.sh              ← audit npm/pip dependencies for vulnerabilities
│   ├── docker-audit.sh            ← audit Docker config for common issues
│   ├── docker-health-check.sh     ← runtime Docker container health verification
│   ├── smoke-test.sh              ← API endpoint smoke testing with auto-discovery
│   ├── project-test.sh            ← run pytest with automatic venv detection
│   ├── venv-run.sh                ← run any venv binary (python, pip, alembic)
│   ├── secret-scan.sh             ← scan for hardcoded secrets and API keys
│   ├── security-headers-check.sh  ← check HTTP security headers
│   ├── owasp-zap-scan.sh          ← OWASP ZAP baseline security scan
│   ├── gh-issues-export.sh        ← export GitHub issues to JSON file
│   ├── gh-save.sh                 ← save gh command output to file
│   ├── sync-toolkit.sh            ← sync toolkit from configured git sources
│   ├── hook-auto-approve-bash.sh  ← PreToolUse hook: auto-approve safe compound commands
│   └── hook-block-destructive.sh  ← PreToolUse hook: block destructive commands
├── skills/                    ← skill definitions (procedures)
│   ├── refine/
│   ├── implement/
│   ├── implement-epic/
│   ├── decompose/
│   ├── bug/
│   ├── cleanup/
│   ├── extend/
│   ├── finish/
│   ├── help-issues/
│   ├── audit/
│   ├── security-audit/
│   ├── debug/
│   ├── ss/
│   ├── sync-closes/
│   ├── update-tracking/
│   ├── verify/
│   ├── retro/
│   ├── promote/
│   └── sync-toolkit/
├── rules/                     ← contextual rules → ~/.claude/rules/
│   ├── testing.md             ← test quality policy (loads for test files only)
│   ├── code-review.md         ← code review conduct
│   └── documentation.md       ← documentation standards (loads for .md files only)
├── claude-md/                 ← CLAUDE.md files (policies) and settings
│   ├── global.md              ← global policies → ~/.claude/CLAUDE.md
│   ├── settings-global.jsonc  ← global permissions → ~/.claude/settings.json
│   ├── project-template.md    ← template for project-specific CLAUDE.md
│   ├── settings-template.jsonc ← template for project-specific settings
│   └── procedures/            ← shared procedure snippets (created via /promote)
├── install.sh                 ← creates symlinks + copies settings
└── README.md
```

## Configuration Files

### Global Settings (`claude-md/settings-global.jsonc`)

Copied to `~/.claude/settings.json` by install.sh. Pre-configures permissions so Claude Code can work without constant approval prompts:

- **File operations** — Write, Edit, MultiEdit (always needed)
- **Shell utilities** — cat, grep, find, ls, etc. (read-only, low risk)
- **File management** — mkdir, cp, mv, chmod (project scaffolding)
- **Git & GitHub** — git, gh (with destructive operations caught by hook)
- **Docker** — docker commands
- **Node.js** — npm, npx
- **Python** — python, ruff, uv, source
- **Toolkit** — helper scripts from `~/.claude/bin/`

This is a copy (not symlink) because Claude Code writes to it when you approve permissions during a session.

### Hooks (`settings-global.jsonc` → `~/.claude/settings.json`)

The global settings include two `PreToolUse` hooks that run **in all permission modes**, including bypass-permissions:

1. **`hook-auto-approve-bash.sh`** — Auto-approves safe compound commands that permission matching would otherwise block (shell redirects to `/tmp/`, pipes to `jq`/`head`/`tail`, `&&` chains of allowed commands, `for` loops around `gh`/`git`). This solves the first-word matching problem for complex commands.

2. **`hook-block-destructive.sh`** — Blocks destructive patterns: `rm -rf /`, `git push --force`, `git reset --hard`, `DROP TABLE`, `TRUNCATE`, `git clean -f`, `dd if=... of=/dev/`, and more. When blocked, Claude sees the reason and adjusts its approach.

To use bypass-permissions mode with these safety nets:

```bash
claude --dangerously-skip-permissions -p "your task here"
```

### Global CLAUDE.md (`claude-md/global.md`)

Symlinked to `~/.claude/CLAUDE.md`, applies to all projects. Contains only what's needed in every conversation:

- **General Preferences** — language and communication conventions
- **Bash Permissies** — permission matching rules for venv and wrapper scripts
- **Code Quality** — verification-before-coding rules
- **Available Utilities** — references to wrapper scripts and audit skills
- **Claude Code Workarounds** — native tool preferences, file writing rules

Contextual rules (test quality, code review conduct, documentation standards) live in `rules/` and load only when relevant files are being edited.

### Project Template (`claude-md/project-template.md`)

Copy to a project root as `CLAUDE.md` and fill in:

- Project overview, tech stack, project structure
- Development commands (run, test, lint, validate)
- API and database conventions
- Project-specific patterns and deployment notes

### Settings Template (`claude-md/settings-template.jsonc`)

Copy to `.claude/settings.json` in your project. Contains commented-out permissions for common tools (Docker, Python, Node, project scripts) and safe deny-defaults for destructive git operations. Uncomment what applies to your project.

Global permissions (git, gh, edit, file operations) are in `~/.claude/settings.json` — don't repeat them in project settings.

### Hooks (`settings-global.jsonc` → `~/.claude/settings.json`)

The global settings include a `PreToolUse` hook that blocks destructive Bash commands. This hook runs **in all permission modes**, including bypass-permissions — making it a safety net for autonomous operation.

**Blocked patterns:** `rm -rf /`, `git push --force`, `git reset --hard`, `DROP TABLE`, `TRUNCATE`, `git clean -f`, `dd if=... of=/dev/`, and more. See `bin/hook-block-destructive.sh` for the full list.

When a command is blocked, Claude sees the reason and adjusts its approach. To use bypass-permissions mode with this safety net:

```bash
claude --dangerously-skip-permissions -p "your task here"
```

## All Skills

| Skill | Syntax | Description |
|-------|--------|-------------|
| `/refine` | `/refine <issue>` | Refine a GitHub issue through interactive Q&A to sharpen scope and criteria |
| `/decompose` | `/decompose <issue>` | Break down a large issue into sub-issues with a tracking PR |
| `/extend` | `/extend <issue>` | Add more sub-issues to an existing tracking PR |
| `/implement` | `/implement <issue>` | Implement a GitHub issue with automated PR creation |
| `/implement-epic` | `/implement-epic <parent-issue>` | Implement all sub-issues of an epic in dependency order |
| `/finish` | `/finish [issue] [base]` | Commit, close issue, merge to base branch, cleanup |
| `/bug` | `/bug "<title>"` | Create a bug sub-issue and add it to the tracking PR |
| `/update-tracking` | `/update-tracking <pr>` | Update tracking PR with current sub-issue status |
| `/sync-closes` | `/sync-closes <pr>` | Sync all Closes statements in tracking PR |
| `/cleanup` | `/cleanup` | Clean up after merging a PR (checkout base, delete branch) |
| `/help-issues` | `/help-issues` | Show quick reference for issue management |
| `/audit` | `/audit [i18n\|env\|deps\|docker\|all]` | Run project audits (i18n, env, deps, docker) |
| `/security-audit` | `/security-audit [domain\|issue]` | OWASP-guided security code review per domain |
| `/debug` | `/debug <description>` | Systematic debugging — find root cause before fixes |
| `/ss` | `/ss [number]` | Find recent screenshots |
| `/retro` | `/retro [focus-area]` | End-of-session retrospective — capture knowledge as scripts, procedures, decisions, or skill proposals |
| `/promote` | `/promote <script-or-procedure>` | Promote a project-local script or procedure to the shared toolkit |
| `/verify` | `/verify [quick\|full\|browser]` | Runtime verification — containers, API health, migrations, browser smoke test |
| `/sync-toolkit` | `/sync-toolkit <pull\|status\|drift>` | Sync toolkit across devices from configured git sources |

---

## Issue Management Quick Reference

| Skill | Syntax | When to Use |
|-------|--------|-------------|
| `/refine` | `/refine <issue>` | Sharpen scope & acceptance criteria |
| `/decompose` | `/decompose <issue>` | Start: break down large issue |
| `/implement-epic` | `/implement-epic <parent-issue>` | Auto-implement all sub-issues |
| `/extend` | `/extend <issue>` | Later: add more sub-issues |
| `/bug` | `/bug "<title>"` | Bug found during work |
| `/update-tracking` | `/update-tracking <pr>` | Update status table |
| `/sync-closes` | `/sync-closes <pr>` | Sync Closes statements |

---

## Workflow Overview

```mermaid
flowchart TD
    subgraph phase0 [Phase 0: Refinement]
        R[Rough Issue] -->|refine| A[Well-defined Issue]
    end

    subgraph phase1 [Phase 1: Decomposition]
        A -->|decompose| B[Draft PR]
        B --> C[Sub-issues]
    end

    subgraph phase2 [Phase 2: Implementation]
        C -->|manual| D{Work on sub-issue}
        C -->|automated| AUTO[implement-epic]
        AUTO --> J
        D -->|Bug found| E[bug command]
        E --> F[Bug issue]
        F --> G[Added to PR]
        D -->|Done| H[Sub-issue complete]
        H --> I[update-tracking]
        I --> J[Progress 33%]
    end

    subgraph phase2b [Phase 2b: Verification]
        J -->|verify| V1[Container Health]
        J -->|verify| V2[API Smoke Test]
        J -->|verify| V3[Migration Check]
        J -->|verify| V4[Browser Test]
        V1 --> VR[Verification Report]
        V2 --> VR
        V3 --> VR
        V4 --> VR
    end

    subgraph phase3 [Phase 3: Extension]
        VR -->|More work needed| K[extend command]
        K --> L[New sub-issues]
        L --> D
    end

    subgraph phase4 [Phase 4: Completion]
        VR -->|All done| M[sync-closes]
        M --> N[All Closes statements]
        N --> O[Merge PR]
        O --> P[Auto-close issues]
    end

    style R fill:#f3e5f5
    style A fill:#e1f5fe
    style B fill:#fff3e0
    style VR fill:#e8f5e9
    style P fill:#c8e6c9
```

---

## Knowledge Capture

Two skills work together to prevent knowledge loss across sessions:

- `/retro` captures knowledge from any working session — debug, implementation, configuration, deployment — as project-local artefacts (scripts, CLAUDE.md procedures, design decisions, auto-memory entries). Findings that look reusable across projects are flagged as toolkit candidates.
- `/promote` generalises a project-local script or procedure into the shared toolkit, leaving a thin wrapper in the original project.

The rule: capture locally first, promote when you have seen the pattern twice.

## Multi-Device Sync

For use across multiple devices (laptop, servers, cloud sandboxes):

1. Run `install.sh` on the first device (creates symlinks + `toolkit.yaml`)
2. On additional devices, use `/sync-toolkit pull` to install from configured sources
3. Use `/sync-toolkit drift` to check for local modifications

Configuration lives in `~/.claude/toolkit.yaml`. Add private repos there for proprietary skills.

---

## Skills in Detail

### 1. `/refine` - Refine Issue

**When:** You have a rough issue that needs sharper scope and acceptance criteria before implementation or decomposition.

**What it does:**
1. Reads the existing issue and explores the codebase for context
2. Asks focused questions in rounds of 2-4 to clarify scope, criteria, and dependencies
3. Proposes an updated issue body with clear structure
4. Updates the issue after confirmation

**Syntax:**
```bash
/refine 42
```

**Example output:**
```
Reading issue #42: Add invoice attachment storage...

Current issue is missing:
- Specific acceptance criteria
- Scope boundaries (which file types? size limits?)
- Storage strategy

Questions:
1. Should attachments be stored on local disk or S3?
2. What file types need to be supported?
3. Is there a maximum file size?

[... Q&A rounds until sharp ...]

Proposed updated issue: [full body with Context, Scope, Acceptance Criteria]
Update issue #42 with this? (y/n)
```

---

### 2. `/decompose` - Break Down Issue

**When:** You have a large issue that's too complex for a single PR.

**What it does:**
1. Fetches issue and analyzes its structure
2. Proposes sub-issues based on phases/tasks
3. Creates a draft tracking PR
4. Creates sub-issues (after confirmation)
5. Adds all `Closes #XXX` statements

**Syntax:**
```bash
/decompose 723
```

**Example output:**
```
Analyzing issue #723: Stripe Payment Provider

Proposed breakdown:
| # | Sub-Issue | Scope |
|---|-----------|-------|
| 1 | Phase 1: Abstraction Layer | Backend |
| 2 | Phase 2: Stripe Integration | Backend |
| 3 | Phase 3: Frontend Updates | Frontend |

Create draft PR and sub-issues? (A/B/C)
```

---

### 3. `/implement-epic` - Implement All Sub-Issues

**When:** You've decomposed an epic into sub-issues and want to implement them all automatically.

**What it does:**
1. Reads the parent issue and parses sub-issues with dependencies
2. Groups sub-issues into waves (dependency order)
3. Per sub-issue: branch, implement, test, PR, auto-merge
4. On failure: creates bug issue, skips dependent issues, continues
5. Runs runtime verification (container health, API smoke test, migrations, browser)
6. Updates tracking PR after each sub-issue

**Syntax:**
```bash
/implement-epic 723
```

**Workflow position:**
```
/refine → /decompose → /implement-epic → tracking PR (manual merge to develop)
```

**Difference from /implement:**

| Aspect | /implement | /implement-epic |
|--------|-----------|-----------------|
| Scope | Single issue | All sub-issues of an epic |
| Confirmation | Stops for plan approval | Runs autonomously |
| PRs | One PR against base branch | One PR per sub-issue against feature branch |
| Failure | Stops on failure | Creates bug issue, skips dependents, continues |
| Verification | CLAUDE.md pattern-based (only when Docker files changed) | Always runs full verification |

---

### 4. `/extend` - Add More Sub-Issues

**When:** You've completed the first batch of sub-issues and want to tackle the next phase.

**What it does:**
1. Finds existing tracking PR
2. Analyzes which tasks don't have sub-issues yet
3. Proposes new sub-issues
4. Adds to tracking PR

**Syntax:**
```bash
/extend 723        # Explicit issue number
/extend            # Detect from branch
```

**Difference from /decompose:**

| Aspect | /decompose | /extend |
|--------|-----------|---------|
| Creates PR | Yes (new) | No (updates existing) |
| Focus | Everything | Only remaining tasks |

---

### 5. `/bug` - Create Bug Issue

**When:** You find a bug while working on a sub-issue.

**What it does:**
1. Detects parent issue from branch (or explicit)
2. Creates bug issue with 🐛 prefix
3. Adds to tracking PR
4. Updates `Closes #XXX` statements

**Syntax:**
```bash
/bug "Webhook signature fails"           # Parent from branch
/bug 724 "Webhook signature fails"       # Explicit parent #724
```

**Example:**
```
$ git branch
issue-724-stripe-webhook

$ /bug "Signature verification fails in test mode"

✅ Created: #730 - 🐛 [Parent #724] Bug: Signature verification fails
✅ Added to tracking PR #727
✅ Will auto-close on merge
```

---

### 6. `/update-tracking` - Update Status

**When:** You want to update the progress in the tracking PR.

**What it does:**
1. Checks status of all sub-issues
2. Finds merged PRs
3. Updates the status table
4. Calculates progress percentage

**Syntax:**
```bash
/update-tracking 727
```

**Status indicators:**
| Emoji | Meaning |
|-------|---------|
| ⏳ | Pending - not started |
| 🔄 | In Progress - has open PR |
| ✅ | Complete - issue closed |
| ❌ | Blocked |
| 🎉 | 100% done |

---

### 7. `/sync-closes` - Sync Closes Statements

**When:** Before merging, to ensure all issues will auto-close.

**What it does:**
1. Finds all sub-issues in tracking table
2. Compares with `Closes #XXX` statements
3. Adds missing ones

**Syntax:**
```bash
/sync-closes 727
```

**Example:**
```
Current Closes: #723, #724, #725
Found in table: #723, #724, #725, #730 (bug)

Missing: #730

Add "Closes #730" to PR? (y/n)
```

---

### 8. `/verify` - Runtime Verification

**When:** After implementation, after Docker changes, or whenever you want to check if the application is actually running correctly.

**What it does:**
1. **Container Health** — checks all Docker containers are running, healthy, not restart-looping, no errors in logs
2. **API Health** — hits health endpoints and key API routes, checks for 5xx errors
3. **Migration Status** — verifies alembic migrations are current (current == head)
4. **Browser Smoke Test** — navigates to frontend via Playwright MCP, takes screenshot, checks console errors

**Syntax:**
```bash
/verify              # quick mode (layers 1-3)
/verify quick        # same as above
/verify full         # all 4 layers including browser
/verify browser      # browser smoke test only
```

**Project configuration:** Add an `Integration Verification` section to your project's CLAUDE.md to configure URLs, container prefixes, health tokens, and trigger patterns. See the project template for the format.

**Example output:**
```
## Verification Report

| Check | Status | Details |
|-------|--------|---------|
| Containers | PASS | 5/5 healthy |
| API Health | PASS | 200 OK, all components healthy |
| Migrations | PASS | Current matches head |
| Browser | WARN | 2 console warnings (non-critical) |

Overall: PASS
```

---

## Complete Example Workflow

### Step 0: Refine the rough issue

```bash
# Issue #723 exists but is vague: "Add Stripe payments"
/refine 723

# Output:
# Reading issue #723...
# Questions about scope, payment methods, error handling...
# [Q&A rounds]
# ✅ Updated issue #723 with clear scope and acceptance criteria
```

### Step 1: Decompose the refined issue

```bash
# Issue #723: Stripe Payment Provider (now well-defined, 5 phases)
/decompose 723

# Output:
# ✅ Created draft PR #727
# ✅ Created sub-issues: #724, #725, #726
# ✅ Progress: 0/3 (0%)
```

### Step 2: Implement all sub-issues (automated)

```bash
# Option A: Implement all sub-issues automatically
/implement-epic 723

# Output:
# Wave 1: #724 (no deps)
# Wave 2: #725 (depends on #724), #726 (depends on #724)
#
# Implementing #724... ✅ PR #731 merged
# Implementing #725... ✅ PR #732 merged
# Implementing #726... ❌ Failed → bug #730 created
#
# Results: 2/3 complete, 1 bug created

# Option B: Implement sub-issues manually one by one
/implement 724
/implement 725
```

### Step 3: Bug found!

```bash
# On branch issue-724-abstraction-layer
/bug "Factory pattern doesn't work with async"

# Output:
# ✅ Created #730 - 🐛 Bug: Factory pattern doesn't work
# ✅ Added to PR #727
```

### Step 4: Update progress

```bash
/update-tracking 727

# Output:
# #724 - Abstraction: ⏳ → ✅ (PR #731 merged)
# #725 - Stripe: ⏳ → 🔄 (PR #732 open)
# #730 - Bug: ⏳ → ✅ (fixed in #731)
# Progress: 2/4 (50%)
```

### Step 5: Add next phase

```bash
/extend 723

# Output:
# Existing: #724 ✅, #725 🔄, #726 ⏳, #730 ✅
# Remaining tasks: Phase 4 (Frontend), Phase 5 (Testing)
#
# Create #733, #734? (y/n)
```

### Step 6: Sync before merge

```bash
/sync-closes 727

# Output:
# All 7 issues have Closes statements ✅
# Ready to merge!
```

### Step 7: Merge

```bash
# Merge PR #727 → develop
# Auto-closes: #723, #724, #725, #726, #730, #733, #734
```

---

## Hierarchy Structure

```
#723 (Parent Issue)
│
├── PR #727 (Tracking PR)
│   ├── Closes #723
│   ├── Closes #724
│   ├── Closes #725
│   └── ...
│
├── #724 (Sub-issue: Phase 1)
│   └── #730 (Bug found in #724)
│
├── #725 (Sub-issue: Phase 2)
│
├── #726 (Sub-issue: Phase 3)
│
└── #733, #734 (Added later via /extend)
```

---

## Tips

1. **Start small**: Decompose into 3-5 sub-issues first, extend later
2. **Update regularly**: Run `/update-tracking` after each merge
3. **Sync before merge**: Always `/sync-closes` before final merge
4. **Branch naming**: Use `issue-XXX-description` for auto-detection
5. **Inline bugs**: Fix small bugs in current branch, only create issues for larger bugs

---

## Skill Format

Each skill is a directory containing a `SKILL.md` file with YAML frontmatter:

```yaml
---
name: my-skill
description: What this skill does
argument-hint: <required-arg> [optional-arg]
user-invocable: true
---

Instructions for Claude Code when the skill is invoked...
```

## License

MIT
