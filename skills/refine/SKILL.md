---
name: refine
description: Refine a GitHub issue through interactive Q&A to sharpen scope and acceptance criteria
argument-hint: <issue-number> [auto]
user-invocable: true
---

# Refine GitHub Issue

Refine an existing GitHub issue through interactive Q&A to produce clear scope, acceptance criteria and a size estimate, ready for `/decompose` or `/implement`. Every decision taken along the way is recorded in the issue, and a parent's refinements are carried into the sub-issues they affect.

## Input

The user provides: `$ARGUMENTS`

- `<N>`: the issue number, the first word.
- `auto` (optional second word): run without questions and without a confirmation stop. See [Auto mode](#auto-mode).

`<project>` below is the basename of the working directory, lowercase, non-alphanumerics replaced by `-`.

## Decision entries

Every decision point is recorded as an entry in a `## Decisions` section of the issue body. The body is the source of truth (`rules/git-pr-workflow.md`): whoever implements the issue later reads why a direction was chosen, and a retro can review the choices across issues. The format is identical in a parent and in its sub-issues:

```markdown
### D<n>: <decision point as a question>
- **Status:** active | superseded by D<m>
- **Origin:** #<issue where the decision was made>, <YYYY-MM-DD>
- **Options:**
  | Option | Pros | Cons |
  |---|---|---|
  | A: <option> | <pros> | <cons> |
- **Recommendation:** <option>, because <rationale>
- **Choice:** <option> (HIL) | <option> (no HIL: delegated | agent default | auto)
```

**What gets an entry:**

| Situation | `Choice` |
|---|---|
| The user picked an option | `<option> (HIL)` |
| The user delegated ("you pick") | `<option> (no HIL: delegated)` |
| The agent chose on its own and the choice affects scope, acceptance criteria or approach | `<option> (no HIL: agent default)` |
| Auto mode | `<option> (no HIL: auto)` |

An agent choice that affects none of scope, acceptance criteria or approach gets no entry.

**IDs** are numbered per issue where the decision originates: `D1`, `D2`, and so on. A sub-issue that receives a parent decision keeps the parent's ID and `Origin`, so the same decision is recognisable everywhere. A decision made on the sub-issue itself takes the next ID that is free in that sub-issue.

**Append only.** A re-run on an issue that already has a `## Decisions` section appends new entries after the existing ones. When a decision changes, the old entry stays and only its `Status` line becomes `superseded by D<m>`; the new entry gets the next free ID. No entry is ever deleted, and no other line of an existing entry is rewritten. Reversed decisions are the ones a retro most wants to see.

**No em-dashes** in anything this skill writes to an issue: use a colon, a semicolon, commas or two sentences instead.

## Phase 1: Understand Current State

1. Fetch issue details: `~/.claude/bin/gh-save.sh /tmp/<project>-issue-<N>.json issue view <N> --json title,body,labels,assignees`, then use the Read tool to read it.
2. If the body has a `## Decisions` section, read its entries: they are settled unless the user reopens them, and they fix the next free `D<n>`.
3. Assess what's already defined and what's missing:
   - Action-oriented title?
   - Clear context (why this change)?
   - Defined scope (what's in/out)?
   - Specific, testable acceptance criteria?
   - Appropriate size for a single PR?
4. Detect sub-issues from two sources only:
   - the native GitHub sub-issues: `~/.claude/bin/gh-save.sh /tmp/<project>-sub-issues-<N>.json api repos/{owner}/{repo}/issues/<N>/sub_issues`, then Read it;
   - task-list items in the body: `- [ ] #M` and `- [x] #M`.

   A loose `#M` anywhere else in the body ("see #115") is not a sub-issue. In interactive mode, show the detected list (number, title, state) and let the user add or remove items. In auto mode, use the list as detected.
5. Explore the codebase for context:
   - Read relevant source files, models, patterns
   - Identify technical constraints and dependencies
   - Find related features or prior art

## Phase 2: Refinement

Ask focused questions to fill the gaps. Cover:

- **Scope boundaries**: What's included vs. excluded?
- **Acceptance criteria**: How do we verify this works? What edge cases matter?
- **Technical approach**: Should this follow existing patterns? Any constraints?
- **Dependencies**: Does this require other work to be done first?
- **Size**: Is this one PR or should it be split?

**Interaction style:**
- Ask ONE question at a time; don't overwhelm with a wall of questions
- When feasible, offer 2-3 concrete options instead of open-ended questions
- Present each option in a table with its key characteristics and trade-offs (columns: Option | Pros | Cons). This is also the `Options` table of the decision entry
- State your recommendation explicitly with a brief rationale
- Validate understanding incrementally before moving on

Record every decision point as an entry (see [Decision entries](#decision-entries)) as soon as it is settled, including the agent-default choices you make without asking.

Iterate until the issue is sharp enough to implement or decompose.

## Phase 3: Propose Updated Issue

Present the complete refined issue body with:
- Updated title (if the original is vague)
- Context section (why)
- Scope section (what's in/out)
- Acceptance criteria (specific, testable checkboxes)
- `## Decisions` section: existing entries unchanged except superseded `Status` lines, new entries appended
- Labels suggestion
- Size estimate (S/M/L)
- Recommendation: ready for `/implement` or needs `/decompose` first

Highlight what changed compared to the original.

**Sub-issues.** Decide per detected sub-issue whether a decision applies to it, judged by its scope. Untouched sub-issues stay untouched. When in doubt, include it in the list below rather than dropping it silently. List the affected sub-issues and, per sub-issue, which decision IDs apply. Their proposed bodies are produced in Phase 4 and shown before they are written.

**Parent body when decisions move to sub-issues.** The full entries go into each sub-issue they apply to. The parent keeps entries for decisions that apply to the parent itself; for decisions that only apply to sub-issues, add a short summary (`D<n>: <question> → <choice>, see #M`) only when that adds value.

STOP HERE and ask for confirmation before updating. Auto mode does not stop.

## Phase 4: Update Issues

After approval:
1. Write updated body to `/tmp/<project>-issue-body-<N>.md` using the Write tool
2. Update: `gh issue edit <N> --body-file /tmp/<project>-issue-body-<N>.md`
3. Update title if needed: `gh issue edit <N> --title "..."`
4. Add/update labels if needed: `gh issue edit <N> --add-label "label"`

### Propagate to sub-issues

For each affected sub-issue `M`, produce an updated body: its scope and acceptance criteria adjusted to the decisions, and the full decision entries added to its `## Decisions` section (parent ID and `Origin` kept, existing entries treated append-only as above).

**Inline or sub-agents.** Use one sub-agent per sub-issue when 3 or more sub-issues are affected, or when a sub-issue needs codebase reading that Phase 1 did not already do. Otherwise work inline. Each sub-agent receives:
- the sub-issue number `M` and the repository;
- the decision entries that apply, verbatim;
- the instruction to fetch the current body to `/tmp/<project>-issue-<M>.json`, keep the entry format and the append-only rule, use no em-dashes, and return the proposed body without editing the issue.

Then, per sub-issue:
1. Interactive mode: show the proposed change and wait for approval. Nothing is written unseen.
2. Write the body to `/tmp/<project>-issue-body-<M>.md` and run `gh issue edit <M> --body-file /tmp/<project>-issue-body-<M>.md`.

### Report

Report what was changed in the parent and each sub-issue, and recommend the next step (`/implement` or `/decompose`).

## Auto mode

`/refine <N> auto` runs the same phases without a human in the loop:

- **Phase 1:** the detected sub-issue list is used as is.
- **Phase 2:** no questions. For every decision point, adopt your own recommendation and record it with `Choice: <option> (no HIL: auto)`.
- **Phases 3 and 4:** no confirmation stop. The parent and the affected sub-issues are written directly.
- **End with a summary:**

  ```markdown
  | ID | Decision | Adopted | Rationale |
  |---|---|---|---|
  | D<n> | <question> | <option> | <one line> |

  Edited: #<N>, #<M>, ...
  ```
