---
name: bug
description: Create a bug sub-issue interactively or with a title, or add existing issues to a tracking PR
argument-hint: "[\"<bug title>\"] | [<parent> \"<title>\"] | [add #issue [to #parent]]"
user-invocable: true
---

# Bug Sub-Issue Skill

Create a bug issue with intelligent context gathering, or add existing bug issues to a tracking PR.

## Input

The user provides: `$ARGUMENTS`

**Three modes of operation:**

### Mode 1: Add existing bug issues to tracking PR
- `add #<issue> [#<issue>...] [to #<parent>]`

**Examples:**
```bash
/bug add #1042                  # Add existing issue #1042 as bug, parent from branch
/bug add #1042 to #723         # Add existing issue #1042 as bug to epic #723
/bug add #1042 #1043           # Add multiple existing bug issues at once
```

### Mode 2: Create new bug issue with title
- `"<bug title>"` - Auto-detect parent from branch
- `<parent-issue> "<bug title>"` - Explicit parent override

**Examples:**
```bash
/bug "Webhook signature fails in test mode"        # Parent from branch
/bug 724 "Webhook signature fails in test mode"   # Explicit parent #724
```

### Mode 3: Interactive bug report (no arguments)
- No arguments → interactive mode with context gathering

**Examples:**
```bash
/bug                            # Interactive mode: gather context, write issue
```

**Disambiguation:** `add` → Mode 1. No arguments → Mode 3. Anything else → Mode 2.

## Workflow

### Mode 1: Add Existing Bug Issues

Use this when you have already-created bug issues that need to be linked to an epic's tracking PR.

#### Step B1: Parse Arguments

Extract from `$ARGUMENTS` (after stripping the `add` keyword):
- **Issue numbers**: all `#<number>` tokens before the `to` keyword (strip the `#` prefix)
- **Parent issue**: the `#<number>` after `to`, or auto-detect from branch if no `to` keyword

```bash
# Auto-detect parent from branch if needed
PARENT_ISSUE=$(~/.claude/bin/extract-issue-from-branch.sh)
```

If no parent found and no `to #<parent>` given: ask the user to provide one explicitly.

#### Step B2: Find Tracking PR

```bash
~/.claude/bin/find-tracking-pr.sh <repo> $PARENT_ISSUE
```

**If no tracking PR exists:** Inform the user and suggest using `/decompose` first.

If parent is a sub-issue, also find the grandparent tracking PR:
```bash
~/.claude/bin/gh-save.sh /tmp/parent-issue-body.json issue view [parent-issue] --json body
```
Use the Read tool to read `/tmp/parent-issue-body.json` and find `Parent issue: #\d+` to get the grandparent issue number.

#### Step B3: Fetch Issue Details

Fetch details for all issues to be added:
```bash
~/.claude/bin/batch-issue-view.sh <repo> [issue-numbers...]
```

Use the Read tool to read the output. For each issue, extract: number, title, state, labels.

#### Step B4: Add Bug Label

For each issue, ensure the `bug` label is present:
```bash
gh issue edit [issue-number] --add-label "bug"
```

Also inherit relevant labels from the parent issue (e.g., `payment`, `backend`).

#### Step B5: Update Tracking PR

**5a. Add Closes statements** for each new issue (append after existing Closes lines):
```markdown
Closes #[existing-issues]
Closes #1042  ← NEW
```

**5b. Add rows to tracking table** for each new issue (with 🐛 prefix):
```markdown
| # | Sub-Issue | Status | PR |
|---|-----------|--------|-----|
| ... existing entries ... |
| N | #1042 - 🐛 Bug: [Issue title] | ⏳ Pending | - |   ← NEW
```

Map issue state to status: OPEN → ⏳ Pending, CLOSED → ✅ Complete.

**5c. Update progress line** to reflect the new total.

#### Step B6: Link as Native GitHub Sub-Issues

Link the added bug issues to the parent issue using the GitHub GraphQL API:

1. Fetch the node IDs for parent and all bug issues in one query:
```bash
gh api graphql -f query='
{
  repository(owner: "OWNER", name: "REPO") {
    parent: issue(number: [parent-number]) { id }
    sub1: issue(number: [sub-number-1]) { id }
    ...
  }
}'
```

2. Link each bug issue to the parent:
```bash
gh api graphql -f query='
mutation {
  addSubIssue(input: {issueId: "[parent-node-id]", subIssueId: "[sub-node-id]"}) {
    issue { number }
    subIssue { number }
  }
}'
```

**Do this for ALL added issues.** This enables GitHub's native sub-issue tracking in the UI.

#### Step B7: Show Summary

```markdown
## Bug Issues Added to Epic

✅ Added #1042 - 🐛 [title] to tracking PR #[pr-number]
✅ Bug label added
✅ Closes statements updated
✅ Progress: X of Y sub-issues complete (Z%)

### Quick Links
- Tracking PR: #[pr-number]
- Parent issue: #[parent-issue]
- Bug issue: #1042
```

---

### Mode 3: Interactive Bug Report

Use this when no arguments are provided. Gathers context interactively and writes a well-structured issue.

#### Step I1: Detect Parent (optional)

Try to detect parent from the current branch:
```bash
PARENT_ISSUE=$(~/.claude/bin/extract-issue-from-branch.sh)
```

- If found: display "Detected parent: #N" and fetch issue title for context
- If not found: continue without parent — the issue will be standalone (no tracking PR updates)

#### Step I2: Auto-context (silent, before asking anything)

Gather context automatically to enrich the bug report:

1. **Recent git activity:**
   ```bash
   git log --oneline -10
   git diff --stat
   ```
2. **Branch context:** current branch name, uncommitted changes
3. **Test failures:** check for recent test output in `/tmp/` (e.g., pytest output files)
4. **Sentry:** if the project CLAUDE.md references Sentry and MCP tools (`mcp__sentry__*`) are available, fetch recent unresolved issues for the project

Store this context internally — do NOT display it to the user yet.

#### Step I3: Open prompt — let the user dump everything

Ask with AskUserQuestion (use an option that allows free text):

> "Beschrijf de bug. Je kunt hier alles kwijt: beschrijving, log output, foutmeldingen, bestandspaden, screenshots — alles door elkaar. Ik sorteer het wel uit."

The user can dump everything at once in any order:
- Error messages / stack traces / console logs
- Description of what went wrong
- File paths that are relevant
- Screenshots (if mentioned or pasted)
- Reproduction steps
- All at once, in any order

#### Step I4: Parse and classify the input

Analyze the user's dump and classify:
- **Description**: free text about the problem
- **Logs/errors**: stack traces, console output, error messages (look for patterns: `Traceback`, `Error:`, `at line`, `TypeError`, `500`, etc.)
- **File references**: paths to files → read them with the Read tool and extract relevant fragments
- **Repro steps**: if the user described steps to reproduce
- **Severity clues**: words like "crash", "data loss", "blocks" → Critical/High; "wrong color", "typo" → Low

#### Step I5: Follow-up questions (only for what's missing)

Only ask about information that was NOT in the dump. Use AskUserQuestion to ask multiple missing items at once (max 4 questions per call).

Possible follow-up questions (only if missing):
- **Severity**: "Hoe ernstig is deze bug?" → Critical (blocks work) / High (important) / Medium / Low
- **Repro steps**: "Kun je beschrijven hoe je de bug kunt reproduceren?" (only if not already in dump)
- **Expected behavior**: "Wat had er moeten gebeuren?" (only if unclear from context)
- **Title**: "Wil je een specifieke title, of genereer ik er een?" → Generate for me (Recommended) / Custom title

If the dump is already complete enough (description + evidence + severity inferable from context), skip follow-up questions and go directly to Step I6.

#### Step I6: Write issue body

Combine all user input + auto-context into a structured issue body:

```markdown
## Bug Description
<Rewritten description based on user input + auto-context>

## Steps to Reproduce
1. ...
2. ...
3. ...

## Expected Behavior
<Derived from description>

## Actual Behavior
<Derived from description>

## Evidence
<Relevant code fragments, log output, error messages — from step I3>
<If file references were provided: include relevant snippets>

## Context
- Branch: <current-branch>
- Recent changes: <summary of git log>
- Discovered while working on: #<parent-issue> (if available)
- Severity: <chosen or inferred severity>
```

#### Step I7: Review before creation

Show the generated issue (title + body) to the user.

Ask with AskUserQuestion: "Ziet dit er goed uit?"
- **Aanmaken (Recommended)**: proceed to Step I8
- **Aanpassen**: ask what needs to change, adjust, show again
- **Annuleren**: abort without creating

#### Step I8: Create + link

1. Write body to `/tmp/bug-issue.md` using the Write tool
2. Determine title format:
   - If parent found: `🐛 [Parent #XXX] Bug: <title>`
   - If standalone: `🐛 Bug: <title>`
3. Create the issue:
   ```bash
   gh issue create --title "<title>" --label "bug" --body-file /tmp/bug-issue.md
   ```
4. If severity is Critical or High: add extra label
   ```bash
   gh issue edit [new-issue] --add-label "priority: high"
   ```
5. **If parent found:**
   - Link as GitHub sub-issue (same GraphQL as Mode 2, Step 6)
   - Find and update tracking PR (same as Mode 2, Step 7)
6. **If standalone (no parent):**
   - Only create the issue, no tracking PR updates
   - Report: "Standalone bug issue — niet gekoppeld aan een epic"

#### Step I9: Summary

**If linked to parent:**
```markdown
## Bug Issue Created

✅ Created: #[new-issue-number] - 🐛 Bug: [title]
✅ Parent: #[parent-issue]
✅ Added to tracking PR #[pr-number]
✅ Will auto-close when PR merges

### Quick Links
- Bug issue: [url]
- Parent issue: #[parent-issue]
- Tracking PR: #[pr-number]
```

**If standalone:**
```markdown
## Bug Issue Created

✅ Created: #[new-issue-number] - 🐛 Bug: [title]
ℹ️ Standalone issue — not linked to an epic

### Quick Links
- Bug issue: [url]
```

---

### Mode 2: Create New Bug Issue (with title)

### Step 1: Parse Arguments and Detect Parent Issue

**Check if first argument is a number:**
- If `$ARGUMENTS` starts with a number → use that as parent issue
- Otherwise → extract from branch name

**Extract from branch:**
```bash
PARENT_ISSUE=$(~/.claude/bin/extract-issue-from-branch.sh)
```

**Example branch names:**
- `issue-724-stripe-webhook` → parent = 724
- `issue-723-stripe-payment-provider` → parent = 723

**If no parent found:** Ask the user to provide one explicitly.

### Step 2: Extract Bug Title

After determining parent issue, the rest of `$ARGUMENTS` is the bug title.

Parse:
- `/bug "Webhook fails"` → parent=from branch, title="Webhook fails"
- `/bug 724 "Webhook fails"` → parent=724, title="Webhook fails"

### Step 3: Get Parent Issue Info

```bash
~/.claude/bin/gh-save.sh /tmp/parent-issue.json issue view [parent-issue] --json number,title,labels
```

Use the Read tool to read `/tmp/parent-issue.json`.

### Step 4: Find the Tracking PR

Search for the tracking/parent PR:
```bash
~/.claude/bin/find-tracking-pr.sh <repo> [parent-issue]
```

If parent is a sub-issue (e.g., #724), also find the grandparent tracking PR:
```bash
~/.claude/bin/gh-save.sh /tmp/parent-issue-body.json issue view [parent-issue] --json body
```
Use the Read tool to read `/tmp/parent-issue-body.json` and find `Parent issue: #\d+` to get the grandparent issue number.

### Step 5: Create Bug Issue

First write the body using the Write tool to `/tmp/bug-issue.md`:
```markdown
## Parent Issue
Related to #[parent-issue] ([parent title])

## Bug Description
[To be filled in]

## Steps to Reproduce
1.
2.
3.

## Expected Behavior


## Actual Behavior


## Context
- Discovered while working on: #[parent-issue]
- Branch: [current-branch]

---
_This bug blocks the completion of #[parent-issue]_
```

Then create the issue:
```bash
gh issue create --title "🐛 [Parent #XXX] Bug: [bug title]" --label "bug" --body-file /tmp/bug-issue.md
```

### Step 6: Link as Native GitHub Sub-Issue

Link the newly created bug issue to the parent issue using the GitHub GraphQL API:

1. Fetch the node IDs for parent and the new bug issue:
```bash
gh api graphql -f query='
{
  repository(owner: "OWNER", name: "REPO") {
    parent: issue(number: [parent-number]) { id }
    bug: issue(number: [new-bug-number]) { id }
  }
}'
```

2. Link the bug issue to the parent:
```bash
gh api graphql -f query='
mutation {
  addSubIssue(input: {issueId: "[parent-node-id]", subIssueId: "[bug-node-id]"}) {
    issue { number }
    subIssue { number }
  }
}'
```

### Step 7: Add to Tracking PR

Update the tracking PR to include the new bug:

**6a. Add to Closes statements (at top of PR body):**
```
Closes #[parent-issue]
Closes #[other-sub-issues]
Closes #[NEW-BUG-ISSUE]  ← Add this
```

**6b. Add to tracking table:**
```markdown
| # | Sub-Issue | Status | PR |
|---|-----------|--------|-----|
| ... | existing entries ... | ... | ... |
| N | #[NEW] - 🐛 Bug: [title] | ⏳ Pending | - |
```

### Step 8: Show Summary

```markdown
## Bug Issue Created

✅ Created: #[new-issue-number] - 🐛 Bug: [title]
✅ Parent: #[parent-issue]
✅ Added to tracking PR #[pr-number]
✅ Will auto-close when PR merges to develop

### Quick Links
- Bug issue: [url]
- Parent issue: #[parent-issue]
- Tracking PR: #[pr-number]

### Next Steps
- Fix the bug in your current branch
- Or create a separate branch: `git checkout -b issue-[new-bug-number]-fix`
```

## Label Handling

Automatically add labels:
- `bug` - always
- Inherit relevant labels from parent (e.g., `payment`, `backend`)

```bash
gh issue edit [new-issue] --add-label "bug"
```

## Example Session

```
$ git branch --show-current
issue-724-stripe-webhook

$ /bug "Signature verification fails for test webhooks"

Detected parent issue: #724 (from branch: issue-724-stripe-webhook)

Creating bug issue...
✅ Created: #731 - 🐛 [Parent #724] Bug: Signature verification fails for test webhooks

Finding tracking PR...
✅ Found: PR #727 (Stripe Payment Provider)

Updating tracking PR...
✅ Added "Closes #731" to PR #727
✅ Added #731 to tracking table

Done! Bug #731 will auto-close when PR #727 merges.
```

