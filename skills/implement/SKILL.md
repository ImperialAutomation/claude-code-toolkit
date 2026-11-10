---
name: implement
description: Implement a GitHub issue with automated PR creation
argument-hint: <issue-number> [worktree]
user-invocable: true
---

# Implement GitHub Issue

Implement GitHub issue with automated workflow.

## Input

The user provides an issue number, optionally followed by a worktree hint: `$ARGUMENTS`

MUST use `~/.claude/bin/git-find-base-branch --repo <worktree>` for base branch detection for the PR.

## Worktree

Everything below operates on ONE worktree, written here as `<worktree>`. Resolve
it in Phase 1, right after fetching the issue and before reading or changing
anything else.

**Why this is explicit rather than assumed:** your working directory resets
between every Bash call, and so do exported variables. Nothing carries the target
path from one command to the next except this instruction. A repo-relative path
or a bare `git` therefore silently acts on the directory the session started in —
which is the right tree only by coincidence. The damage is quiet: a commit can
land on another session's branch, carrying that session's staged files, and exit 0.

### Resolving it

```bash
~/.claude/bin/git-resolve-worktree.sh --issue <N> --create <slug> <hint-if-given>
```

`<N>` is the issue number, the first word of `$ARGUMENTS`. `<slug>` is the short
kebab-case summary of the issue title that the branch will carry
(`issue-<N>-<slug>`), which is why the issue is fetched before this call.

The hint is the second word of `$ARGUMENTS`, if the user gave one. It may be the
exact name of a worktree (an exact name always wins over a longer sibling, so
`<repo>` means the main tree, not `<repo>-dev1`), any unique substring of its
path, or an absolute path.

`--issue` is tried when no hint resolves it: it finds the worktree already on
branch `issue-$ARGUMENTS-*`, which is how resumed work is picked up without
anyone typing a path. On new work that branch does not exist yet — that is
normal, and the script then simply reports the current worktree, exactly as it
does with no arguments at all. Single-worktree projects therefore never notice
this skill has a worktree concept.

`--create` matters in one repository only: the toolkit checkout that
`~/.claude/bin` points into, whose branch is live in every session. When the
answer would be that tree, the script answers with the sibling worktree
`../<repo>-<N>` instead, creating it on `issue-<N>-<slug>` from `origin/<base>`
or reusing it when it exists. Everywhere else `--create` changes nothing.

The script prints one absolute path and exits 0, or prints nothing to stdout and
exits non-zero. Non-zero means the user's own hint was wrong or ambiguous, or
`--create` could not make the sibling; either way its stderr says which.
**Then stop and show them its stderr** — it lists the candidates with their
branches. Do not pick one yourself and do not fall back to the current directory;
an unresolved hint is a question for the user, not a guess to make.

Then state the resolved path to the user, before the first commit:

```
Working in: <worktree>  [branch]
```

### Rules that follow from it

Apply these everywhere below, wherever a command touches the repository:

- **git** — always `git -C <worktree> ...`, never a bare `git`
- **commits** — always `~/.claude/bin/git-commit.sh --repo <worktree> ...`
- **Read / Edit / Write / Glob / Grep** — absolute paths under `<worktree>` only,
  never repo-relative ones
- **project scripts** — run `<worktree>/bin/<script>`, not `bin/<script>`;
  `~/.claude/bin/` scripts are unaffected, they are the same files for every tree
- **sub-agents** — pass `<worktree>` in the prompt; a sub-agent has its own
  context and inherits none of this

### Test containers

A long-lived test container usually bind-mounts the **main** worktree. Run tests
through it from a linked worktree and you test the wrong source, and it may write
files back into a tree the user never touched. Where the project offers an
isolated runner (a disposable container, a per-worktree compose project), use it
and say so; where it does not, note in the PR body which tree the tests actually
ran against.

## Tool Rules

- Use Glob/Grep/Read instead of Bash equivalents (find, grep, cat, head, tail)
- Use Write/Edit for file creation and modification — not Bash (echo, cat, sed, awk)
- Bash is for: git, gh, npm, npx, docker, python, ruff, uv, and `~/.claude/bin/` scripts only
- For tests, use the project's documented test entry point and its path convention (project CLAUDE.md, test docs); only when the project names none, fall back to `~/.claude/bin/project-test.sh` with absolute paths under `<worktree>`
- For other venv binaries (python, alembic, ruff), use `~/.claude/bin/venv-run.sh <cmd>`
- Never use `python3 -c` for file operations — use Read/Edit/Grep instead

## Phase 1: Discovery & Planning

0. Fetch issue details: `~/.claude/bin/gh-save.sh /tmp/<project>-issue-<N>.json issue view <N> --json title,body,labels`, then use the Read tool to read it.
   Pick the branch `<slug>` from its title. `gh` finds the repository from any of
   its worktrees, so this is safe before `<worktree>` is known.
1. **Resolve `<worktree>`** as described in the Worktree section above, and report
   it to the user. Every path and git command in the phases below assumes this is
   settled — do it before reading any source file, or you will read the wrong one.
2. **Check for linked Sentry issues** in the issue body:
   * Look for Sentry issue references — short IDs of the form `<PROJECT>-<PLATFORM>-<SUFFIX>`, Sentry URLs, or "Sentry Issues" sections
   * If found, note the Sentry issue IDs — these will be referenced in commit messages and the PR body for automatic resolution
   * Store as a list, e.g. `SENTRY_ISSUES=["MYAPP-BACKEND-G", "MYAPP-BACKEND-H"]`
3. Read AND verify understanding of existing code (all paths absolute, under `<worktree>`):
   * Read all CLAUDE.md files (`<worktree>/CLAUDE.md`, and the frontend/backend ones if they exist)
   * Read the ACTUAL source files you plan to modify
   * Check what attributes/methods ACTUALLY exist on models you'll use
   * Find existing patterns for similar functionality (grep/search)
   * NEVER assume a model has an attribute - READ the model first
4. **Parse acceptance criteria** from the issue body:
   * Look for checkbox patterns: `- [ ]` / `- [x]`
   * Look for numbered lists under an "Acceptance Criteria" heading
   * Fallback: bullet points under an AC heading
   * If no AC found: warn "No acceptance criteria found — consider running `/refine` first"
   * Store the AC list for verification in Phase 3

5. Create detailed implementation plan as **numbered steps of max 5 minutes each**:
   * Issue requirements understanding
   * Existing code patterns you found and will follow
   * Files to modify/create
   * Per step: what test to write, what code to implement, what to verify
   * Each step must be self-contained: one test + one piece of functionality + one commit
   * Steps must be ordered so each builds on the previous commit

6. **One PR by default.** The whole issue goes into one PR. Split part of it off
   into a follow-up only when that part is independently mergeable (the rest
   merges and works without it) AND independently verifiable (it has its own
   test or check). Size, effort or "cleaner history" is not a reason. When you
   do split, the plan names the part and the reason, and Phase 4 puts both in
   the PR body.
7. **Collect your own decisions.** Read the issue's `## Decisions` section, if it
   has one: active entries are settled, and the highest `D<n>` in it fixes the
   next free ID. From here to Phase 4, every choice you make yourself that
   affects scope, acceptance criteria or approach (a split under step 6 is one)
   is noted in the refine entry format (`skills/refine/SKILL.md`, "Decision
   entries"), for the `## Decisions made` section of the PR body. Choices that
   affect none of the three get no entry.

STOP HERE and ask for confirmation before proceeding to implementation.

## Phase 2: Branch & TDD Implementation

1. Create and checkout branch in the target tree:
   `git -C <worktree> checkout -b issue-<N>-<slug>`
   If `<worktree>` was resolved via `--issue`, or created by `--create`, it is
   already on that branch: check with `git -C <worktree> branch --show-current`
   before creating it.
2. Before writing new code, verify your assumptions:
   * If using model attributes, confirm they exist: `grep "attribute_name" models.py`
   * If importing classes, confirm they exist: `python -c "from module import Class"`
   * If ANY verification fails, STOP and reassess your approach
3. **Removing or renaming a public symbol** (function, class, module, route)?
   Grep the whole test tree for the old name BEFORE you commit. For every hit,
   decide which of two things it is:
   * the coverage moves with the symbol — migrate the test in this same commit;
   * the covered behaviour no longer exists — delete the test and **write down in
     the PR body which behaviour lapsed**. "The test no longer imports" is not a
     reason; "this behaviour is gone, deliberately" is.

   The collection check in Phase 3 catches the broken import. It cannot catch the
   test whose import still resolves but whose subject is gone: that one stays
   vacuously green while asserting nothing, which is worse than red because
   nothing ever reports it.

### Execute each plan step using the TDD cycle:

**For each step in the plan, follow this exact sequence:**

1. **RED — Write a failing test first**
   * Write the minimal test that demonstrates the desired behavior
   * Run the test — it MUST fail
   * If it passes immediately, the test proves nothing — rewrite it
   * Show the failing output

2. **GREEN — Write the simplest code to pass**
   * Implement only what's needed to make the test pass
   * Run the test — it MUST pass now
   * Show the passing output

3. **REFACTOR — Clean up, then commit**
   * Remove duplication, improve naming if needed
   * Run tests again to confirm nothing broke
   * Stage and commit in the target tree — `--repo` is not optional, without it
     the commit is judged against the session's start directory:
     `git -C <worktree> add <paths>` then
     `~/.claude/bin/git-commit.sh --repo <worktree> "descriptive message for this step"`
   * If SENTRY_ISSUES were found in Phase 1, add `Fixes <ID>` to the **final commit only** (the last step before PR creation), e.g.: `~/.claude/bin/git-commit.sh --repo <worktree> "final step description" "" "Fixes MYAPP-BACKEND-G" "Fixes MYAPP-BACKEND-H"`

4. **Move on — Focus shifts to the next step**
   * Do not revisit completed steps unless a later test breaks them
   * Each commit is a checkpoint — previous context can be released

**When TDD doesn't apply** (config files, migrations, static assets):
* Implement the change, verify it works, commit. Skip red/green.

### Self-review between steps

After every 2-3 steps, briefly check:
* Are tests testing real behavior or just that code runs without errors?
* Are mocks hiding bugs? (only mock external services)
* Do fixtures use realistic data?

Fix weaknesses immediately before continuing.

## Phase 3: Final Verification (MANDATORY — delegated to sub-agent)

DO NOT SKIP THIS PHASE. NO COMPLETION CLAIMS WITHOUT FRESH EVIDENCE.

**Verification runs in a sub-agent with its own context window.** Test output, validation output, review findings, and smoke test logs pollute the orchestrator's context window heavily. Delegating to a sub-agent keeps the main session lightweight for the PR creation phase and avoids context degradation mid-implementation.

The orchestrator (main session) only:
- Spawns the verification sub-agent
- Receives a structured summary
- Decides whether to proceed to Phase 4 or fix issues

### Step 0: Scope the verification to the diff's blast radius

MANDATORY means "verify with fresh evidence", not "always run everything". Run
the checks that could actually fail because of THIS diff. A check that cannot
fail from the change is not evidence; it is wall-clock.

Classify the diff first:

**Test-only diff** — every changed file is a test, fixture, scanner or snapshot,
and no file ships to a container or user. Then the test IS the subject, there is
no runtime surface to diverge from, and the strongest available evidence is:

1. the targeted test file(s), green;
2. a mutation probe per behavioural claim (break it, confirm the intended check
   goes red, revert) — this is the step that separates a real fix from a green
   stamp, and it is cheap;
3. one A/B of the affected test(s) on base vs branch.

Do NOT run the full suite or the full validate chain for this class. Prefer the
project's changed-files test selection (e.g. `vitest run --changed=origin/<base>`)
plus any repo-wide scanner tests, which read the whole tree and so are not
selected by `--changed`. Skip the sub-agent when the above fits in a handful of
calls; run the probes inline and report them.

The collection check in Step A is not part of what this class skips — run it
here too. Renaming a fixture or helper is a test-only diff that breaks the
imports of test files you never opened, which is the exact class collection
exists to catch.

**Everything else** — anything that reaches a container, a user, an API, a
schema or a migration. Full Phase 3 below applies unchanged, including the
container check: a green suite is not a claim that the running app works.

Never invoke a formatter or generator as verification. Commands like
`npm run format` and OpenAPI regeneration MUTATE the tree, producing unrelated
churn you then have to revert and risk committing. Use the check-only variant
(`--check`, `generate:check`, `lint`) instead.

### Step 1: Gather context for the sub-agent

Before spawning, collect:
- `base_branch` — from `~/.claude/bin/git-find-base-branch --repo <worktree>`
- `acceptance_criteria` — the AC list parsed in Phase 1 (or "none" if not found)
- `modified_files` — `~/.claude/bin/git-diff-base.sh --repo <worktree> <base-branch>`
- `worktree` — the absolute path resolved in Phase 1
- `has_backend_endpoints` — true if any modified file matches `**/api/**`, `**/routes/**`, `**/endpoints/**`
- `has_schema_changes` — true if any modified file matches `**/schemas/**`, `**/models/**`, `**/migrations/**`

### Step 2: Spawn verification sub-agent

Use the Task tool with `subagent_type: "general-purpose"` and the prompt below. Wait for completion (do NOT use `run_in_background: true` — Phase 4 depends on the result).

```
## Task: Final verification for issue #$ARGUMENTS

Verify the implementation on the current branch is ready for PR creation.
Run each step below and report results in the structured format at the end.

## Context
- Issue: #$ARGUMENTS
- Worktree: <worktree>
- Base branch: <base_branch>
- Modified files: <modified_files>
- Acceptance criteria: <acceptance_criteria or "none parsed">
- Has backend endpoints: <true/false>
- Has schema changes: <true/false>

## Worktree — read before running anything

The work under verification lives in `<worktree>`. That is NOT necessarily the
directory you start in, and your working directory resets to the start directory
between every Bash call, so `cd` cannot fix it once and exported variables do not
survive either. Every command must carry the path:

- `git -C <worktree> ...` — never a bare `git`
- `~/.claude/bin/git-diff-base.sh --repo <worktree> <base_branch>`
- `~/.claude/bin/git-find-base-branch --repo <worktree>`
- commits (if a fix needs one): `~/.claude/bin/git-commit.sh --repo <worktree> "..."`
- Read/Edit/Write/Glob/Grep: absolute paths under `<worktree>` only
- project scripts: `<worktree>/bin/<script>`; `~/.claude/bin/` scripts are shared
  and need no prefix

A verification run against the wrong tree reports green for code that is not the
code under review — silently, because both trees are valid checkouts.

Project policies — read these BEFORE verifying:
- <worktree>/CLAUDE.md (project root)
- <worktree>/frontend/CLAUDE.md (if frontend changes)
- <worktree>/backend/app/CLAUDE.md or <worktree>/backend/CLAUDE.md (if backend changes)

## Tool Rules
- Use Glob/Grep/Read instead of Bash equivalents (find, grep, cat, head, tail)
- Use Write/Edit for file creation and modification — not Bash (echo, cat, sed, awk)
- Bash is for: git, gh, npm, npx, docker, python, ruff, uv, and `~/.claude/bin/` scripts only
- For tests, use the project's documented test entry point and its path convention (project CLAUDE.md, test docs); only when the project names none, fall back to `~/.claude/bin/project-test.sh` with absolute paths under `<worktree>`
- For other venv binaries, use `~/.claude/bin/venv-run.sh <cmd>`

## Verification Steps

### Step A: Targeted tests
Run ONLY the test files relevant to the modified files — never the full suite,
and never a whole test directory. Use the project's documented test entry point
and its path convention (project CLAUDE.md, test docs): a runner that executes
inside a container usually wants paths relative to its workdir, not absolute
worktree paths. Only when the project names none, fall back to:
`~/.claude/bin/project-test.sh <worktree>/tests/path/to/your_test.py -v`
If any test fails, fix at root cause and re-run.

Then verify the whole test tree still **loads**, which is a different and far
cheaper question than whether it passes. Pass `--collect-only -q` to the same
entry point; the fallback form is:
`~/.claude/bin/project-test.sh --collect-only -q`

A test that imports a symbol you removed or renamed is by definition a file you
did not touch, so "relevant to the modified files" excludes it at precisely the
moment it became relevant. Name-matching does not find it either: the coupling
is the import, not the filename. Collection imports every test module without
running a single test, so it catches exactly that class in seconds. Treat a
collection error as a hard failure, not a warning: it aborts the whole suite, so
the thousands of tests that *would* have passed never run either — which is also
why such a break can sit unnoticed for months.

The cost does not scale with the diff: two changed files or twenty, collection
costs the same, so the reason to skip it never arrives.

The command above is pytest's form. Use the project's equivalent — the question
is "can the test tree still be loaded", not pytest:

| Ecosystem | Collection-only check |
|---|---|
| pytest | `<project test entry point> --collect-only -q` (fallback: `~/.claude/bin/project-test.sh --collect-only -q`) |
| vitest / jest | `npx vitest run --reporter=dot --passWithNoTests` |
| TypeScript | `npx tsc --noEmit` |
| Go | `go vet ./...` |

If the project runs tests through a long-lived container, check what that
container bind-mounts before trusting the result: it commonly mounts the MAIN
worktree, so a run started from a linked one tests the wrong source and can write
files back into a tree nobody is working in. Prefer the project's isolated runner
where it has one; otherwise report which tree the tests actually ran against.

### Step B: Project validation
Check for one of: `npm run validate:all`, `make validate`, `./validate.sh` — in
`<worktree>`, and run it from there. If backend schemas changed, ensure OpenAPI is
regenerated. Fix any errors before proceeding.

### Step C: Integration verification (conditional)
Check `<worktree>/CLAUDE.md` for an **Integration Verification** section.
If it exists AND modified files match a trigger pattern, run the defined steps.
Otherwise skip.

### Step D: Acceptance criteria verification (skip if AC = "none parsed")
For each criterion, find evidence (test name, assertion, config/UI change).
Produce a table:

| # | Criterion | Evidence | Status |
|---|-----------|----------|--------|

For UNVERIFIED items: write a test if testable, else flag for manual review.

### Step E: Self-review (max 2 fix iterations)
Run the `/review` analysis on the branch diff:
`~/.claude/bin/git-diff-base.sh --repo <worktree> --patch <base-branch>`

If findings with severity > INFO:
- Fix automatically, re-run Step A, re-run review
- Max 2 iterations — remaining findings go into the PR body as "Known Issues"

### Step F: API smoke test (skip if has_backend_endpoints = false)
First establish the project's own names — read `<worktree>/CLAUDE.md` and the
compose file for the API container, the restart command and the login helper.
Never guess a container name or script path; if the project defines none, skip
this step and report SKIP with the reason.
1. Restart the API container, then wait for it to come back up: `~/.claude/bin/wait-for-healthy.sh <api_container>`
2. Seed test accounts if the project has a seed command
3. Log in with the project's login helper and capture the token it writes
4. Call each new/modified endpoint, verify 2xx + correct JSON structure
5. On 500: check `docker logs <api_container> --tail 30`, fix root cause, re-run

## Execute — do not describe or delegate

You are the agent that performs this verification. There is no other agent to hand off to or wait for. Actually run each verification step below — do not respond with a description of what you would do or a status update implying work is happening elsewhere.

## Response Format

Respond with EXACTLY this format ONLY once you have actually performed the verification steps above — not as a status update:

VERIFICATION_COMPLETE:
TESTS: PASS/FAIL — <passed>/<total> tests (e.g., 12/12)
COLLECTION: PASS/FAIL — <collected count, errors> (e.g., 6032 collected, 0 errors)
VALIDATION: PASS/FAIL/SKIP — <validate command used or reason for skip>
INTEGRATION: PASS/FAIL/SKIP — <what was verified or reason for skip>
AC_VERIFIED: <verified count>/<total count> or SKIP — <one-line summary>
REVIEW: PASS/WARN/FAIL — <iterations used, findings remaining>
SMOKE_TEST: PASS/FAIL/SKIP — <endpoints tested or reason for skip>
KNOWN_ISSUES: <list of remaining review findings, or "none">
AC_UNVERIFIED: <list of UNVERIFIED criteria needing manual review, or "none">

FAILED:
ERROR: <description of what blocked verification>
STEP: <which step failed>
LAST_OUTPUT: <relevant error output>
```

### Step 3: Handle sub-agent result

**On VERIFICATION_COMPLETE:**
- If any of TESTS/COLLECTION/VALIDATION/INTEGRATION/REVIEW/SMOKE_TEST is FAIL → fix the issue at root cause, then re-run Step 2 (spawn a fresh verification sub-agent — do NOT proceed to Phase 4 with failures)
- A COLLECTION failure is never a "known issue" to carry into the PR body: an
  unloadable test tree means no test in the project runs, so there is no green
  evidence for anything else in this report
- If all are PASS/WARN/SKIP → store `KNOWN_ISSUES` and `AC_UNVERIFIED` for inclusion in the PR body, proceed to Phase 4

**On FAILED:**
- Investigate the error in the orchestrator (the sub-agent couldn't complete verification)
- Fix and re-spawn

### Step 4: Verify claims with evidence

Before proceeding to PR creation:
* The sub-agent's structured response IS your evidence — no "should work" or "probably fine"
* If any claim in the response is unsupported (e.g., TESTS: PASS without numbers), re-spawn the sub-agent

## Phase 4: PR Creation

1. Determine base branch: `~/.claude/bin/git-find-base-branch --repo <worktree>`
2. Write PR body to `/tmp/<project>-pr-body-$ARGUMENTS.md` using the Write tool —
   a per-project, per-issue name, because parallel worktrees mean parallel
   sessions and a shared `/tmp/pr-body.md` gets overwritten by whichever writes
   last. Include:
   - `Closes #$ARGUMENTS`
   - Implementation summary
   - Test checklist (test counts from the verification sub-agent's TESTS line)
   - A `## Decisions made` section, always (format below)
   - If part of the issue was split off (Phase 1 step 6): a `## Split off`
     section naming the follow-up and why it is independently mergeable and
     verifiable
   - If the diff removed or renamed a public symbol and tests were deleted as a
     result (Phase 2 step 3): add a `## Removed Behaviour` section naming each
     behaviour that no longer exists and the test that covered it
   - If `KNOWN_ISSUES` from Phase 3 is not "none": add a `## Known Issues` section listing them
   - If `AC_UNVERIFIED` from Phase 3 is not "none": add a `## Manual Review Needed` section listing the UNVERIFIED criteria
   - If SENTRY_ISSUES were found in Phase 1, add a `## Sentry` section: `Resolves: MYAPP-BACKEND-G, MYAPP-BACKEND-H`
3. Push + create PR in one command:
   `~/.claude/bin/git-push-pr-merge.sh --repo <worktree> --base <base-branch> --title "<concise description>" --body-file /tmp/<project>-pr-body-$ARGUMENTS.md --no-merge`
   `--no-merge` means the CI gate is skipped — the PR is left open for human review regardless of check status
4. Label the PR `agent-authored` (`<PR>` is the script's `PR_NUMBER:` line). The
   label marks every PR an agent opened, which is what `agent-pr-wip.sh` counts
   against the agent PR WIP limit; review time is what that limit protects.
   Create the label first when the repository lacks it:
   ```bash
   ~/.claude/bin/gh-save.sh /tmp/<project>-labels-$ARGUMENTS.json label list --search agent-authored --json name
   # Read it; only when no entry has "name": "agent-authored":
   env -C <worktree> gh label create agent-authored --color 5319e7 --description "Opened by an agent; counts toward the agent PR WIP limit"
   env -C <worktree> gh pr edit <PR> --add-label agent-authored
   ```
   Never `gh label create --force`: a repo that already has the label (often
   applied by a workflow) keeps its own colour and description. A failed label
   call does not undo the PR; report it with the PR URL.
5. Return PR URL for review

`/implement` does not check the WIP limit itself: a human starting it is already
deciding to add review load. `agent-pr-wip.sh` is the gate for unattended runs.

### `## Decisions made`

The reviewer sees every decision behind the PR in one place. Two shapes, in this
order:

1. **Issue decisions**, one line per active entry of the issue's `## Decisions`
   section, keeping its ID and its HIL marker exactly as the `Choice` line has it.
   Superseded entries are skipped. The full entries stay in the issue; do not copy
   them.
   ```markdown
   - D2: Which decision-record format do the queue skills use? → A (no HIL: auto)
   - D3: Which runs does the agent PR WIP limit apply to? → A (HIL)
   ```
2. **Your own decisions** (Phase 1 step 7), each as a full entry in the refine
   format, numbered from the next free `D<n>` of the issue, with
   `Origin: #$ARGUMENTS, <date>` and
   `Choice: <option> (no HIL: agent default)`. These exist nowhere else, so they
   carry their options and trade-offs in full. They are not written back to the
   issue.

When there is neither, the section reads `None.`

## Phase 5: Epic Tracking Update (automatic, if applicable)

After PR creation, check if this issue is a sub-issue of an epic and update the tracking PR accordingly.

### Step 1: Detect Parent Epic

Read the issue body (already fetched in Phase 1) and search for parent references:
- `Parent issue: #XXX`
- `Part of #XXX`
- `Related to #XXX`

If no parent reference found → skip this phase entirely (not a sub-issue).

### Step 2: Find Tracking PR

```bash
~/.claude/bin/find-tracking-pr.sh <repo> $PARENT_ISSUE
```

If no tracking PR exists → skip (inform user: "Note: no tracking PR found for parent #XXX").

### Step 3: Update Tracking PR

Read the tracking PR body and make two updates:

**3a. Ensure Closes statement exists:**
If `Closes #$ARGUMENTS` is not already in the PR body, add it after the last existing `Closes` line.

**3b. Update tracking table row:**
Find the row for this issue (`#$ARGUMENTS`) in the tracking table and update:
- Status: `⏳ Pending` → `🔄 In Progress`
- PR column: `-` → `PR #[new-pr-number]`

If no row exists for this issue, add one:
```markdown
| N | #$ARGUMENTS - [Issue title] | 🔄 In Progress | PR #[new-pr-number] |
```

**3c. Write updated body and apply:**
```bash
# Write updated body to /tmp/<project>-tracking-pr-body-$ARGUMENTS.md using the Write tool
gh pr edit [tracking-pr-number] --body-file /tmp/<project>-tracking-pr-body-$ARGUMENTS.md
```

### Step 4: Confirm

```markdown
✅ Updated tracking PR #[tracking-pr-number] for parent epic #[parent-issue]
   - Status: 🔄 In Progress
   - Linked: PR #[new-pr-number]
```
