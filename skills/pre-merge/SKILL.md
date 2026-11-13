---
name: pre-merge
description: Combined quality gate that orchestrates review, tests, verification, and AC checks before merge
argument-hint: "[PR-number] [--post]"
user-invocable: true
---

# Pre-Merge Quality Gate

The reviewer role: orchestrates every quality check into one gate report with one verdict, `APPROVE`, `BLOCKING` or `HUMAN`. This is a reporting tool: it does NOT auto-fix or auto-merge. The user decides what to act on. With `--post` it also submits the report as a PR review under the review app (Phase 10).

## Input

`$ARGUMENTS` can be:
- **A PR number**: scope to that PR's changes
- **Empty**: scope to current branch vs base branch
- **`--post`** (with a PR number only): after the report, run Phase 10. Without it, nothing is written to GitHub.

The local phases (review, tests, escalation check) read the checked-out tree, so for a PR number the PR's head branch should be checked out. When `HEAD` is not the PR head, say so at the top of the report.

## Phase 1: Determine Scope

### Tmp paths

Every file this skill writes is unique per project and PR, so two reviews can run in parallel:

- `<project>`: basename of `git rev-parse --show-toplevel`, lowercase, every non-alphanumeric character replaced by `-`
- `<key>`: the PR number; without one, the current branch name with every non-alphanumeric character replaced by `-`

| File | Content |
|------|---------|
| `/tmp/<project>-pre-merge-pr-<key>.json` | PR metadata |
| `/tmp/<project>-pre-merge-issue-<key>.json` | Linked issue (a second linked issue `<N>`: `/tmp/<project>-pre-merge-issue-<N>-<key>.json`) |
| `/tmp/<project>-pre-merge-gates-<key>.json` | Input of `pre-merge-verdict.py` (Phase 8) |
| `/tmp/<project>-pre-merge-report-<key>.md` | The Phase 9 report, the review body (Phase 10) |
| `/tmp/<project>-pre-merge-human-<key>.json` | `HUMAN` decisions for the review (Phase 10) |

### If PR number provided:
```bash
~/.claude/bin/gh-save.sh /tmp/<project>-pre-merge-pr-<key>.json pr view <PR> --json number,title,body,baseRefName,headRefName,files
```
Read that file to get the base branch, head branch, changed files, and PR body.

### If no PR number:
```bash
~/.claude/bin/git-find-base-branch
```
Use the current branch vs the detected base branch. Get changed files from:
```bash
git diff --name-only $(git merge-base HEAD <base-branch>)..HEAD
```

Store: `repo` (`owner/name`), `base_branch`, `head_branch`, `changed_files`, `pr_body` (if available).

## Phase 2: Code Review (conventions)

Run the `/review` skill logic on the branch changes:

1. Get the diff: `git diff $(git merge-base HEAD <base_branch>)..HEAD`
2. Run automated checks (Phase 2 of `/review`): debug statements, secrets, large changes, TODOs
3. Run structural review (Phase 3 of `/review`): DRY, magic values, error handling, pattern consistency
4. Run test coverage mapping (Phase 4 of `/review`)

Record every finding with its `/review` severity (CRITICAL / HIGH / MEDIUM / LOW / INFO), text and location.

## Phase 3: Correctness

Call the `/code-review` skill through the Skill tool, level first and always explicit (without a level it reuses the last one typed, which is unpredictable unattended):

- With a PR number: `/code-review high <PR>`
- Without one: `/code-review high <head_branch>`, which reviews the branch diff against its base

Do not pass `--comment` or `--fix`: this phase only collects findings. Each finding has a file, a line, a summary and a failure scenario.

**Every `/code-review` finding counts as HIGH for the verdict.** Next to that, assign each finding a **shadow severity** against these fixed criteria:

| Shadow severity | Criterion |
|---|---|
| HIGH | Data loss, a security hole, or a crash or wrong result on the normal path |
| MEDIUM | A wrong result in an edge case |
| LOW | Cosmetic, or unclear whether it is a bug at all |

The shadow severity is reported and logged (Phase 8), but never changes the verdict. It measures what a downgrade of MEDIUM and LOW findings would have changed.

## Phase 4: Tests

Run the `/test` skill logic in affected mode:

1. Map changed files to test files (naming conventions + import analysis)
2. Run Tier 1: direct affected tests
3. If Tier 1 passes and integration-sensitive files changed: run Tier 2

Record: passed/failed/skipped counts.

## Phase 5: Runtime Verification

Run a quick runtime check (equivalent to `/verify quick`):

1. **Container health** (if Docker detected):

   Read the project CLAUDE.md's **Integration Verification** config first. When it
   defines a `Container prefix:`, pass it; a stack started from an `include:` set
   has no compose file that names its containers, so the bare call fails on a
   healthy stack:
   ```bash
   ~/.claude/bin/docker-health-check.sh --filter <prefix>
   ```
   With no prefix configured, call it bare and let the compose lookup find the set:
   ```bash
   ~/.claude/bin/docker-health-check.sh
   ```

2. **API smoke test** (if running server detected):
   ```bash
   ~/.claude/bin/smoke-test.sh
   ```

3. **Migration check** (if alembic detected):
   - Compare `alembic current` with `alembic heads`

Skip any check that is not applicable. Record per-check status: PASS / WARN / FAIL / SKIP, and for a FAIL the check's output. A FAIL leads to `HUMAN`: a review cannot tell a code fault from an environment problem.

## Phase 6: Acceptance Criteria Check

**Only runs if a linked issue is found.**

1. Extract the issue numbers from the PR body (`Closes|Fixes|Resolves #N`) or the branch name (`issue-N-...`)
2. Fetch each linked issue, with its labels (Phase 7 needs them):
   ```bash
   ~/.claude/bin/gh-save.sh /tmp/<project>-pre-merge-issue-<key>.json issue view <N> --json number,body,labels
   ```
3. Parse acceptance criteria from the issue body (checkboxes, numbered lists, AC heading)
4. For each criterion: search for a test that verifies it, or check whether the implementation satisfies it
5. Give each criterion exactly one status:

| Status | Meaning | Verdict effect |
|---|---|---|
| `VERIFIED` | A test or an inspection of the code confirms it | none |
| `NOT MET` | The implementation demonstrably lacks it | `BLOCKING` |
| `UNVERIFIABLE` | Cannot be judged from the diff and the repo (needs a live environment, an external service, a human look) | `HUMAN` |

If no issue is found or the issue has no AC: mark the gate SKIP.

## Phase 7: Escalation Detection

The categories are in `docs/escalation-list.md` of the toolkit.

1. **Categories 1 to 4** come from the script, run on the checked-out tree:
   ```bash
   ~/.claude/bin/escalation-check.sh --repo <toplevel> --base <base_branch>
   ```
   Each output line `<key>  <file>  <reason>` is one hit. Exit 0 is clean, 1 means hits. Exit 2 (the diff could not be computed) is itself a hit: record it with category `escalation-check` and the error as reason, so the review fails closed to `HUMAN`.
2. **Category 5** is judgment: does the PR change the scope of the linked issue (does more, less or something else than its Scope section says), or conflict with an earlier explicit decision (a `D<n>` of the issue or its parent)? Each such finding is a hit with category `scope`, the file (or `-`) and a one-line reason.
3. **Approvals**: pass the labels of every linked issue along (Phase 8). A hit of category `<key>` does not escalate when every linked issue carries `approved:<key>`. Scope hits are never approved by a label. The helper applies this rule; do not filter hits yourself.

## Phase 8: Verdict

The verdict comes from one helper, so this skill and `/pre-merge --post` read the same rules. Write the gate results with the Write tool to `/tmp/<project>-pre-merge-gates-<key>.json`:

```json
{
  "repo": "owner/name",
  "pr": 295,
  "branch": "issue-295-...",
  "escalation": {
    "hits": [{"category": "interface", "file": "bin/x.sh", "reason": "deleted"}],
    "linked_issues": [{"number": 295, "labels": ["approved:interface"]}]
  },
  "acceptance": [{"criterion": "...", "status": "VERIFIED"}],
  "runtime": [{"check": "containers", "status": "PASS", "detail": ""}],
  "tests": {"passed": 10, "failed": 0, "skipped": 0},
  "review_findings": [{"severity": "MEDIUM", "finding": "...", "location": "a.py:3"}],
  "correctness_findings": [{"file": "a.py", "line": 12, "summary": "...",
                            "failure_scenario": "...", "shadow_severity": "MEDIUM"}]
}
```

`pr` is `null` without a PR number; leave a section out (or empty) when its phase did not run. Then:

```bash
~/.claude/bin/pre-merge-verdict.py --input /tmp/<project>-pre-merge-gates-<key>.json
```

It prints JSON with `verdict`, `human_reasons`, `blocking_reasons`, `listed_findings`, `approved_escalations` and `correctness.line`, and appends one row per `/code-review` finding to `~/.claude/pre-merge-findings.tsv` (date, repo, PR or branch, `file:line`, shadow severity, verdict). Exit 2 means the input was invalid: fix the JSON and run it again; never pick a verdict yourself.

The mapping it applies, top to bottom:

| Condition | Verdict |
|---|---|
| An escalation hit (category 1 to 5) without approval, an `UNVERIFIABLE` AC, or a runtime check that fails | `HUMAN` |
| Any `/code-review` finding, a `/review` HIGH/CRITICAL finding, a failing test, or a `NOT MET` AC | `BLOCKING` |
| Otherwise | `APPROVE` |

`HUMAN` takes precedence over `BLOCKING`; the `BLOCKING` reasons stay listed. MEDIUM/LOW findings are listed under every verdict.

## Phase 9: Gate Report

Generate the combined report:

```markdown
## Pre-Merge Quality Gate

**Branch:** <head_branch> → <base_branch>
**Files changed:** <count>

### Gate Results

| Gate | Status | Summary |
|------|--------|---------|
| Code Review | PASS / WARNINGS / NEEDS WORK | <finding count and top severity> |
| Correctness | PASS / FINDINGS | <count> findings (`/code-review high`) |
| Tests | PASS / FAIL | <passed>/<total> |
| Runtime | PASS / WARN / FAIL / SKIP | <check summary> |
| Acceptance | PASS / NOT MET / UNVERIFIABLE / SKIP | <verified>/<total> criteria |
| Escalation | CLEAN / HIT / APPROVED | <categories hit> |

### Verdict: **<APPROVE / BLOCKING / HUMAN>**

<One-line summary: the first human reason, or the first blocking reason, or "no blocking findings">
```

Then the detail sections, each only when it has content:

- **Needs a human** (`human_reasons`): escalation hits with the question they raise, `UNVERIFIABLE` criteria with what would verify them, failed runtime checks with their output.
- **Blocking** (`blocking_reasons`): listed under `HUMAN` too.
- **Correctness findings**: one row per `/code-review` finding, then the line from `correctness.line`:

  | # | Location | Finding | Failure scenario | Shadow severity |
  |---|----------|---------|------------------|-----------------|
  | 1 | bin/x.sh:7 | Off by one | The last item is skipped | MEDIUM |

  `1 of 1 correctness findings would have been downgraded`
- **Code Review**: the findings table from `/review`, MEDIUM/LOW included under every verdict.
- **Tests**: failure details.
- **Acceptance**: the AC table with a `VERIFIED` / `NOT MET` / `UNVERIFIABLE` status per criterion.
- **Approved escalations** (`approved_escalations`): hits that did not escalate because every linked issue carries the `approved:<key>` label.

**This is a reporting gate. Do NOT auto-fix issues or suggest automatic remediation. Present the facts and let the user decide.**

## Phase 10: Post (only with `--post`)

Submits one PR review as the repo owner's review GitHub App (`gh-app-token.sh`, `docs/review-app-runbook.md`), never as the user. Write the Phase 9 report with the Write tool to `/tmp/<project>-pre-merge-report-<key>.md`. For a `HUMAN` verdict, also write `/tmp/<project>-pre-merge-human-<key>.json`: one entry per human reason, each with the question it raises, at least two options and your recommendation:

```json
[{"question": "...", "options": ["A: ...", "B: ..."], "recommendation": "A, because ..."}]
```

Then:

```bash
~/.claude/bin/pre-merge-post.py --gates /tmp/<project>-pre-merge-gates-<key>.json --body /tmp/<project>-pre-merge-report-<key>.md [--human /tmp/<project>-pre-merge-human-<key>.json]
```

It recomputes the verdict with the Phase 8 rules and posts the matching event: `APPROVE` → `APPROVE`, `BLOCKING` → `REQUEST_CHANGES`, `HUMAN` → `COMMENT` with the decisions on top of the body. Findings on a diff line become inline comments of that review; the rest are listed in its body. On `HUMAN` it then adds `needs-human` to the PR and to every linked issue (`escalation.linked_issues`). The app has `Contents: Read-only`, so its `APPROVE` does not count toward a required-approvals rule.

| Exit | `status` | Meaning |
|---|---|---|
| 0 | `posted` | Review on the PR (and labels set on `HUMAN`) |
| 3 | `post_failed` | No token or an API error; `stage` (`files`, `review`, `label`), `error`, `review_posted` |
| 2 | (no JSON) | Invalid input, nothing sent: fix it and run again |

A post failure is not a verdict: report the verdict from Phase 8 plus `review not posted (<error>)`, and never retry as the user's own account.
