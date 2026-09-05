---
name: promote
description: Promote a project-local script or procedure to the shared toolkit. Generalises the implementation and creates a thin project-local wrapper.
argument-hint: <script-or-procedure>
user-invocable: true
---

# Promote to Toolkit

Move a proven project-local pattern to the shared toolkit (`claude-code-toolkit` repo) so it is available across all projects and devices.

**When to use:** When the same pattern has appeared in two or more projects, or when a `/retro` toolkit proposal is ready to be acted on.

## Input

The argument is one of: `$ARGUMENTS`
- A path to a script (e.g. `scripts/pam-login.sh`)
- A procedure name from CLAUDE.md (e.g. "FastAPI session auth")
- A toolkit proposal file (e.g. `~/.claude/toolkit-proposals/fastapi-session-login.md`)

## Phase 1: Locate Source and Toolkit

### Find the source

Read the source and understand what it does. If the argument is a procedure name, find it in the project's CLAUDE.md.

### Find the toolkit repo

Read `~/.claude/toolkit.yaml` and extract the local path of the toolkit repo:

1. Check if `~/.claude/skills` is a symlink — if so, resolve it to find the toolkit repo root
2. If not a symlink, check `toolkit.yaml` for configured sources and look for a local clone in the `cache_dir`
3. If neither works, ask the user for the toolkit repo path

Verify the toolkit repo exists and is a git repo.

## Phase 2: Generalise

Create a parameterised version that:
- Accepts project-specific values as arguments or environment variables
- Has no hardcoded project URLs, paths, or credentials
- Includes a usage comment explaining all parameters
- Works as a standalone script or can be sourced

**The toolkit repo is PUBLIC — generalise the prose too, not just the code.**

The same strip applies to comments, docs, and to the **GitHub issue bodies, PR bodies
and commit messages** you write against the toolkit repo. Remove project names,
client/person names, product URLs and hostnames, and internal issue/PR numbers from
other repos. Keep the lesson, the reasoning, and load-bearing numbers — without the
attribution. The project-local version keeps the full story.

Note that an issue number from another project renders as a link to *this* repo's issue
with that number, so it leaks and misleads at once. And `gh issue edit` does not undo a
published leak — GitHub keeps the old body in the "edited" menu, so cleaning up means
delete + recreate.

Scan before publishing:

```bash
grep -oiE "<project>|<client>|<product-domain>|#[0-9]{3}" <body-file>
```

## Phase 3: Determine Toolkit Location

Check the toolkit repo for existing similar scripts/skills before creating duplicates.

| Type | Location in toolkit repo |
|------|--------------------------|
| Reusable script | `bin/` (if it's a helper Claude calls) or `scripts/` (if user-facing) |
| Reusable skill | `skills/<name>/SKILL.md` |
| Reusable procedure | `claude-md/procedures/<name>.md` |

## Phase 4: Replace Project-Local Version

Replace the project-local version with a thin wrapper that calls the toolkit version.

**Example — script promotion:**

Before (in project repo):
```bash
#!/usr/bin/env bash
# Full implementation of session-cookie login
# ... 20 lines of curl logic ...
```

After (in project repo):
```bash
#!/usr/bin/env bash
# PAM login — wraps toolkit's fastapi-session-login
source .env
~/.claude/bin/fastapi-session-login.sh \
  "http://localhost:8000" "$PAM_DEBUG_USER" "$PAM_DEBUG_PASS"
```

New (in toolkit repo):
```bash
#!/usr/bin/env bash
# Generic FastAPI session-cookie login
# Usage: fastapi-session-login.sh <base-url> <username> <password>
# Exports: SESSION_COOKIE
# ... generalised implementation ...
```

**Example — procedure promotion:**

Before (in project CLAUDE.md):
```markdown
## Learned Procedures
### FastAPI Session Auth
1. POST /auth/login with form data
2. Extract session cookie from response
3. Include cookie in subsequent requests
```

After (in project CLAUDE.md):
```markdown
## Learned Procedures
### FastAPI Session Auth
See ~/.claude/skills/claude-code-toolkit/claude-md/procedures/fastapi-session-auth.md
Project-specific: base URL is http://localhost:8000, credentials in .env as PAM_DEBUG_USER/PAM_DEBUG_PASS
```

## Phase 5: Update References

Update the project's CLAUDE.md to reference the toolkit version instead of the local implementation.

## Phase 6: Present Summary and Confirm

Show:
- What was generalised
- The new toolkit file (with full content)
- The updated project wrapper (if applicable)
- Updated CLAUDE.md references

**Important:** The user needs to commit to TWO repos:
1. The current project repo (wrapper + CLAUDE.md update)
2. The toolkit repo (new generalised file)

Make this clear in the summary. Do NOT auto-commit to the toolkit repo.

Wait for confirmation before making any changes.

## Rules

- Do not auto-commit to the toolkit repo. Show what needs to be added; the user handles the commit.
- The project-local version must keep working after promotion (via the wrapper).
- Check the toolkit for existing similar scripts/skills before creating duplicates.
- If a toolkit proposal file exists for this pattern, use it as input but verify it is still accurate.
- Clean up the toolkit proposal file after successful promotion.
- The toolkit repo is public: never put project names, client names, product URLs or other repos' issue/PR numbers in toolkit files, issues, PRs or commit messages. Generalise the lesson, drop the attribution.
