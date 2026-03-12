---
name: refine
description: Refine a GitHub issue through interactive Q&A to sharpen scope and acceptance criteria
argument-hint: <issue-number>
user-invocable: true
---

# Refine GitHub Issue

Refine an existing GitHub issue through interactive Q&A to produce clear scope, acceptance criteria, and size estimate — ready for `/decompose` or `/implement`.

## Input

The user provides an issue number: `$ARGUMENTS`

## Phase 1: Understand Current State

1. Fetch issue details: `~/.claude/bin/gh-save.sh /tmp/issue-$ARGUMENTS.json issue view $ARGUMENTS --json title,body,labels,assignees`, then use the Read tool to read it
2. Assess what's already defined and what's missing:
   - Action-oriented title?
   - Clear context (why this change)?
   - Defined scope (what's in/out)?
   - Specific, testable acceptance criteria?
   - Appropriate size for a single PR?
3. Explore the codebase for context:
   - Read relevant source files, models, patterns
   - Identify technical constraints and dependencies
   - Find related features or prior art

## Phase 2: Interactive Refinement

Ask focused questions to fill the gaps. Cover:

- **Scope boundaries**: What's included vs. excluded?
- **Acceptance criteria**: How do we verify this works? What edge cases matter?
- **Technical approach**: Should this follow existing patterns? Any constraints?
- **Dependencies**: Does this require other work to be done first?
- **Size**: Is this one PR or should it be split?

**Interaction style:**
- Ask ONE question at a time — don't overwhelm with a wall of questions
- When feasible, offer 2-3 concrete options instead of open-ended questions
- Validate understanding incrementally before moving on

Iterate until the issue is sharp enough to implement or decompose.

## Phase 3: Propose Updated Issue

Present the complete refined issue body with:
- Updated title (if the original is vague)
- Context section (why)
- Scope section (what's in/out)
- Acceptance criteria (specific, testable checkboxes)
- Labels suggestion
- Size estimate (S/M/L)
- Recommendation: ready for `/implement` or needs `/decompose` first

Highlight what changed compared to the original.

STOP HERE and ask for confirmation before updating.

## Phase 4: Update Issue

After approval:
1. Write updated body to `/tmp/issue-body-$ARGUMENTS.md` using the Write tool
2. Update: `gh issue edit $ARGUMENTS --body-file /tmp/issue-body-$ARGUMENTS.md`
3. Update title if needed: `gh issue edit $ARGUMENTS --title "..."`
4. Add/update labels if needed: `gh issue edit $ARGUMENTS --add-label "label"`
5. Report what was changed and recommend next step (`/implement` or `/decompose`)
