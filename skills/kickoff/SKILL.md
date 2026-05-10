---
name: kickoff
description: Project kickoff checklist based on lessons learned from previous projects. Generates a tailored checklist and optionally creates GitHub issues.
argument-hint: [project-name or description]
user-invocable: true
---

# Project Kickoff

Generate a tailored project kickoff checklist based on accumulated lessons learned from previous projects.

## Input

Project name or description: `$ARGUMENTS`

If no arguments provided, ask the user:
1. What is the project? (name + one-line description)
2. What tech stack are you planning? (backend, frontend, database, hosting)
3. Will there be payments/subscriptions?
4. Is there a legal entity established?
5. What external services/APIs will you integrate?

## Phase 1: Read Lessons Learned

Read the lessons learned document:

```
~/GoogleDrive/3_Resources/Werk/project-lessons-learned.md
```

This is a growing document with concrete lessons from previous projects, categorized as:
- **B** — Business & Legal
- **A** — Architecture & Design
- **D** — Dependencies & Integraties
- **P** — Development Practices

## Phase 2: Assess Relevance

For each lesson in the document, determine if it's relevant to this project based on the tech stack and project description:

- Payment integration planned? → B1, B2, D1 are critical
- External APIs/SDKs? → D1, A7 are critical
- Multi-tier/subscription model? → A4 is critical
- Database with migrations? → A2, A5 are critical
- Real-time features (chat, notifications)? → A6, A7 are critical
- Frontend + backend with shared types? → A1, P2 are critical
- Any project → P1, A1, A2, A3 always apply

Mark each lesson as:
- **CRITICAL** — directly applicable, has caused major problems before
- **RELEVANT** — applicable but lower risk
- **NOT APPLICABLE** — skip (e.g., no payments = skip B1/B2)

## Phase 3: Generate Kickoff Checklist

Present a tailored checklist grouped by timing:

### Week 1 — Foundation
Items that must be done before writing feature code.

### Per Feature — During Development
Items to check for every feature/epic.

### Pre-Launch — Before Going Live
Items to verify before any public release.

For each checklist item:
- Reference the lesson ID (e.g., "B1")
- Include the concrete action (not just "think about X")
- Note what went wrong last time (one sentence, for motivation)

## Phase 4: Offer Next Steps

Ask the user which of these they want:

1. **Create as GitHub issues** — Convert the checklist into GitHub issues in the project repo (one issue per category, or one per item)
2. **Add to project CLAUDE.md** — Add the relevant lessons as project-specific rules
3. **Create ADR templates** — Pre-create ADR files for architectural decisions that need to be made
4. **Just the checklist** — Output only, no file changes

Wait for the user's choice before taking action.

## Phase 5: Execute Choice

### If GitHub issues:
Create issues with label `kickoff` in the project repo. Group related items into single issues (e.g., all legal items in one issue).

### If CLAUDE.md:
Add a `## Project Kickoff Decisions` section to the project's CLAUDE.md with the relevant lessons as rules. Include links back to the lessons learned document for context.

### If ADR templates:
Create `docs/architecture/decisions/` directory with template ADR files for each decision that needs to be made (e.g., `adr-payment-provider.md`, `adr-external-services.md`).

## Rules

- Always read the lessons learned document fresh — it grows over time
- Do not invent lessons that are not in the document
- Be concrete: "Set up GitHub Actions with lint + typecheck + unit tests" not "Think about CI/CD"
- Keep the checklist actionable and concise — no essays
- If the lessons learned document doesn't exist or is empty, inform the user and suggest running `/retro` on completed projects first
