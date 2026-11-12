---
name: queue-run
description: One iteration of the local queue runner - claim the oldest agent-ready issue, refine and implement it in a sub-agent, release it. Driven by /loop
argument-hint: "[--budget N] [--max-prs N] [--max-idle N] [--model <model>]"
user-invocable: true
---

# Queue Run

One iteration of the local queue runner (#183). It takes one `agent-ready` issue
through `/refine <N> auto` and `/implement <N>` to an open PR, without a human,
unless the issue hits the escalation list. Repeat it with `/loop`, self-paced:

```
/loop /queue-run
/loop /queue-run --budget 5 --max-prs 4 --model sonnet
```

The labels and the escalation categories are described in
`docs/escalation-list.md` (the single source). This skill only detects an
escalation; `/refine` and the escalation hook raise it.

## Arguments

`/loop` passes the same arguments to every iteration.

| Argument | Default | Meaning |
|---|---|---|
| `--budget N` | 10 | Releases (pr, escalated, failed) this loop may make; then it stops. Idle iterations do not count (#251, D1, D3) |
| `--max-prs N` | 3 | Agent PR WIP limit, passed to `agent-pr-wip.sh --limit` (D6). A separate brake: review backlog, not tokens |
| `--max-idle N` | 16 | Consecutive idle iterations (8 hours at 30 minutes) before the loop stops (D4, D5) |
| `--model <model>` | the session's | Model of the sub-agents of Steps 4 and 4c (D3) |

A value that is not a positive integer (or, for `--model`, empty) or an
unknown argument: claim nothing, stop the loop and report the usage.

`<budget>`, `<max-prs>`, `<max-idle>` and `<model>` below are these values.

## Preconditions

Check these before starting a loop. They are not checked by the skill itself.

- **One runner at a time.** Claiming is two label calls, not an atomic lock.
  `queue-claim.sh` re-reads the labels before and after a claim and backs off
  when they changed, but two runners can still both claim the same issue in
  the same second.
- **Auto mode.** A permission prompt in an unattended session hangs it until
  someone looks. Run the loop in auto mode (or with an allowlist that covers
  `gh`, `git -C`, the `~/.claude/bin/` scripts and the project's test runner).
- **Toolkit work in a worktree (#158).** Every issue is implemented in a linked
  worktree, never in the checkout the session started in. In the toolkit repo
  the checkout `~/.claude/bin` points into is live in every session; it stays on
  `main` for the whole run. Step 6 checks it.
- **Start the loop from the repository's main checkout**, on its default
  branch. That checkout is `<repo>` below; it is only read, never written.

## One iteration

The session running the loop stays thin: it calls a few scripts, spawns the
sub-agents (the issue sub-agent, and on a PR a reviewer and at most one fix
round), measures their tokens and releases the claim. All issue work happens
in the sub-agents.

`<project>` is the basename of `<repo>`, lowercase, non-alphanumerics as `-`.

### Step 0: Gate

```bash
~/.claude/bin/queue-budget.sh gate <budget>
```

It checks, between issues only, the three conditions that end the loop:

- the stop file `~/.claude/queue-stop` exists. Create it (`touch`) to stop a
  running loop after its current issue. The loop never deletes it: remove it
  yourself before starting a new loop (D7);
- `CLAUDE_CODE_SESSION_ID` is missing: the budget cannot be counted, so the
  loop fails closed (D8);
- this session's releases in `~/.claude/queue-runs.tsv` reached `<budget>`.

- exit 0: prints `budget <used>/<budget>`; note `<used>` for Step 7, continue.
- exit 1: claim nothing, stop the loop (see "Pacing") and report the printed
  line.

### Step 1: Capacity

```bash
~/.claude/bin/agent-pr-wip.sh --repo <repo> --limit <max-prs>
```

- exit 0: below the agent PR WIP limit, continue.
- exit 1: the limit is reached. Claim nothing; go to "Pacing" (idle).
- exit 2: the count is unknown. Treat it as exit 1 and report the stderr.

Note the current branch of `<repo>` for Step 6:
`git -C <repo> branch --show-current`.

### Step 2: Claim

```bash
~/.claude/bin/queue-claim.sh --repo <repo> claim
```

It prints the claimed issue number `<N>`, or nothing when the queue is empty.
Epics, issues with `needs-human` and issues already claimed are never
claimed. Empty output: go to "Pacing" (idle). Exit 1: `gh` failed; nothing
was claimed or the claim may be half-set; report the stderr and stop the loop
(see "Pacing").

### Step 3: Fetch the issue

```bash
~/.claude/bin/gh-save.sh /tmp/<project>-queue-issue-<N>.json issue view <N> --json title,body,labels
```

Read it for the title. Pick `<slug>`: a short kebab-case summary of the title.

### Step 4: Spawn the issue sub-agent

Use the Agent tool, `subagent_type: "general-purpose"`, and with `--model`
also `model: "<model>"`; without it, pass no `model` (the session's model). It runs in the
background; the launch result holds its `agentId: <id>` (note it for Step 4b),
and its completion notification is the wake signal for Step 4b. Until that
notification arrives, release nothing, claim nothing and do not end the
iteration: `agent-wip` stays on until the outcome exists (see "Pacing" for the
fallback wakeup). The spike on #188 confirmed that this sub-agent can run
`/implement` including its own Phase 3 verification sub-agent.

The report arrives in the completion notification. A sub-agent that ends
without a report holding one of the three result blocks below is a failure.

Prompt, with the placeholders filled in:

```
You work GitHub issue #<N> (<title>) for the unattended queue runner in
<repo>. There is no human in this session: never wait for an answer or a
confirmation, and never ask one.

## Worktree: read before running anything

Your working directory resets between every Bash call, and exported variables
do not survive. <repo> is the checkout the runner started in: never modify it,
never run git checkout/switch/commit in it. All work happens in a linked
worktree, <worktree> below:

1. Run `env -C <repo> ~/.claude/bin/git-resolve-worktree.sh --issue <N> --create <slug>`.
   - In the toolkit repo this prints the sibling worktree `<repo>-<N>` (created
     or reused). That is <worktree>.
   - Elsewhere it prints a path. If that path is <repo> itself, there is no
     linked worktree yet: create one with
     `git -C <repo> fetch origin` and
     `git -C <repo> worktree add --no-track -b issue-<N>-<slug> <repo>-<N> origin/<default-branch>`
     (`<default-branch>` from `~/.claude/bin/git-find-base-branch --repo <repo>`);
     <worktree> is `<repo>-<N>`. If `<repo>-<N>` already exists as a worktree
     of this repo (a retry), reuse it.
2. Use `git -C <worktree> ...`, `~/.claude/bin/git-commit.sh --repo <worktree> ...`,
   and absolute paths under <worktree> for Read/Edit/Write/Glob/Grep.

## Step A: refine

Invoke the Skill tool with skill "refine" and args "<N> auto", and follow it.

Then read the labels:
`~/.claude/bin/gh-save.sh /tmp/<project>-queue-labels-<N>.json issue view <N> --json labels`.
If they include `needs-human`, or refine ended with `Escalated:` or `Waiting:`,
stop here and report ESCALATED. Do not start Step B.

## Step B: implement

Invoke the Skill tool with skill "implement" and args "<N> <worktree>", and
follow it, with these answers to its stops:

- Phase 1 "STOP HERE and ask for confirmation": the plan is confirmed, continue.
- Phase 4 opens the PR with `--no-merge`. Never merge anything.

Escalation during implement:
- If a decision falls in a category of `docs/escalation-list.md`, or would
  change scope or an active `(HIL)` decision of the issue: do not decide it.
  Post one comment on #<N> with the question, the options and your
  recommendation, add the label (`gh issue edit <N> --add-label needs-human`),
  stop and report ESCALATED.
- If hook-escalation-check.sh BLOCKS opening the PR: that is an escalation,
  not a failure. Follow the hook's message (comment with question, options and
  recommendation, add `needs-human`), never work around it, and report
  ESCALATED.

## Response format

Hand back exactly one of:

PR_OPENED:
PR_URL: <url>
WORKTREE: <worktree>

ESCALATED:
REASON: <question and category, or the hook's block>
COMMENT_URL: <url of the comment holding the question, if known>

FAILED:
ERROR: <what went wrong>
ATTEMPTS: <what was tried>
LAST_ERROR_OUTPUT: <relevant output>
WORKTREE: <worktree, if one was made>
```

### Step 4b: Measure the tokens

`<id>` is the issue sub-agent's `agentId` from the launch result of Step 4.
Measure that agent and every agent it spawned, whatever the outcome (a
failed or escalated run costs just as much):

```bash
~/.claude/bin/cmd-save.sh /tmp/<project>-queue-tokens-<N>-issue.json ~/.claude/bin/agent-tokens.py --agent <id> --json
```

- exit 0: the issue part is measured.
- exit 1 (no transcript), exit 2 (ambiguous or unreadable), or no `agentId` in
  the launch result: the measurement failed. That never fails the iteration;
  the whole-issue total is then unknown (Step 5).

Step 4c measures each sub-agent it spawns the same way, one file per agent:
`-review-1`, `-review-2` and `-fix` instead of `-issue`. Only files measured in
this iteration count; a file left from an earlier run of the issue does not.

The `subagent_tokens` of a completion notice is not this number: it is roughly
the final context size.

### Step 4c: Review the PR

Only when the report is `PR_OPENED`, `gh-save.sh /tmp/<project>-queue-pr-<N>.json pr view <url> --json number,state`
reads `OPEN`, and the labels (read as in Step 5) do not include
`needs-human`. Otherwise go to Step 5.

The prompts, their inputs and response formats are in
`~/.claude/skills/queue-run/references/review-and-fix.md`; Read it now. The
reviewer gets the issue, the PR and the worktree (`WORKTREE` of the report),
never the issue sub-agent's plan or report (#288, D1).

1. Spawn the **Reviewer**; measure it into `-review-1`. Its block is the
   first review: `VERDICT` and `FINDINGS`, or "not posted" when the block is
   `REVIEW_NOT_POSTED` or missing.
2. First review `BLOCKING`: spawn the **Fix round** with `<comments>` = its
   `REVIEW_URL`; measure it into `-fix`. On `FIXED`, spawn the Reviewer again
   with the same inputs (the re-review), measured into `-review-2`. Exactly
   one fix round and one re-review, whatever the re-review says.
3. Any other first review: no fix round. `HUMAN` wins over `BLOCKING` (D4):
   no fix round even when the review lists HIGH findings.

While a sub-agent of this step runs, the "Sub-agent running" rule of
"Pacing" holds: release nothing, claim nothing.

Then sum the tokens per phase and for the whole issue, from the files of
this iteration that measured (`agent-tokens.py --sum` adds `--json` outputs):

```bash
~/.claude/bin/cmd-save.sh /tmp/<project>-queue-tokens-<N>-review.json ~/.claude/bin/agent-tokens.py --sum <review-1> [<review-2>] --json
~/.claude/bin/cmd-save.sh /tmp/<project>-queue-tokens-<N>-fix.json ~/.claude/bin/agent-tokens.py --sum <fix> --json
```

A phase is known only when every agent in it measured; a phase with a failed
measurement gets no sum (its columns stay empty, its cost is reported
`unknown`) and is left out of the whole. The whole is the sum of the issue
part and the known phases into `/tmp/<project>-queue-tokens-<N>.json`, and
only when the issue part measured. Without Step 4c it is the issue part
alone.

### Step 5: Release

Read the labels again yourself; for an issue that skipped Step 4c the label,
not the report, decides an escalation:

```bash
~/.claude/bin/gh-save.sh /tmp/<project>-queue-labels-<N>.json issue view <N> --json labels
```

Then release in exactly one way. `agent-wip` is dropped only here, after the
outcome exists: the escalation hook treats an issue with `agent-wip` as an
autonomous run, so dropping it earlier would let a PR through unchecked.

When the whole-issue total exists, every release below carries
`--tokens /tmp/<project>-queue-tokens-<N>.json` right after `--repo <repo>`;
otherwise leave the option out. Each release comments with the totals
(or `tokens: unknown`) and appends one row to `~/.claude/queue-runs.tsv`.
Every release is `~/.claude/bin/queue-claim.sh --repo <repo> [<options>] release ...`;
the tables show it from `release` on.

An issue that went through Step 4c is released by its review outcome; the
first matching row wins. `pr <url> <note>` keeps the PR, swaps `agent-ready`
for `agent-pr` and adds `needs-human` with the text of
`/tmp/<project>-queue-review-<N>.md` in the comment: write that file first
with the Write tool (what happened, the review URLs, and the error or
`NOT_ADDRESSED` of a report). The PR is never lost.

| Review outcome (Step 4c) | Release |
|---|---|
| First review `APPROVE` | `release <N> pr <url>` |
| First review `HUMAN` (question, options and recommendation are in the review) | `release <N> pr <url> <note>` |
| First review not posted | `release <N> pr <url> <note>`, the error in the note |
| Fix round `ESCALATED`, `FAILED` or no report | `release <N> pr <url> <note>` |
| Re-review `APPROVE` | `release <N> pr <url>` |
| Re-review `BLOCKING`, `HUMAN` or not posted | `release <N> pr <url> <note>` |

These releases also pass, before `release`, each run log option that has a
value: `--review <V>` (first review: `APPROVE`, `BLOCKING`, `HUMAN`, or
`error` when not posted), `--review-final <V>` (the re-review, same values;
left out without one), `--review-findings <FINDINGS>` (of the first review,
when a count), and `--review-tokens /tmp/<project>-queue-tokens-<N>-review.json`
and `--fix-tokens /tmp/<project>-queue-tokens-<N>-fix.json` when that phase
is known.

Every other issue:

| Situation | Release |
|---|---|
| `needs-human` is on the issue (whatever the report says) | `release <N> escalated` |
| `ESCALATED` without `needs-human` | `release <N> escalated` (it adds the label and warns) |
| `FAILED`, no usable report, or a PR URL that does not resolve to an open PR | `release <N> failed /tmp/<project>-queue-failure-<N>.md` |

`pr` swaps `agent-ready` for `agent-pr`, so the issue is not claimed again.

For a failure, first write `/tmp/<project>-queue-failure-<N>.md` with the
Write tool: the ERROR, ATTEMPTS and LAST_ERROR_OUTPUT of the report (or "the
sub-agent ended without a report"), and the worktree path when there is one.
`queue-claim.sh` turns it into the issue comment. A first failure adds
`agent-failed` and puts the issue back in the queue for one retry; a second
adds `needs-human` too (#188, D5). The worktree and branch of a failed run stay
in place: a retry reuses them, and a human may want to look.

A non-zero exit from `queue-claim.sh release` leaves labels half-changed:
report its stderr and stop the loop.

After a release, reset the idle count:

```bash
~/.claude/bin/queue-budget.sh worked
```

### Step 6: Live checkout check

```bash
git -C <repo> branch --show-current
```

It must still print the branch noted in Step 1. If it does not, something
switched the checkout the session started in (in the toolkit repo, the live
one). Stop the loop and report it; do not switch it back yourself.

### Step 7: Report

One line per iteration. A worked issue ends with its token totals (the
`summary` of the whole-issue total in parentheses, or `tokens: unknown`) and
the budget used, `<used>` of Step 0 plus this release. An idle line ends with
the `queue-budget.sh idle` output.

An issue that reached a PR names its review outcome in brackets after the PR,
and its phase costs after the total: `; review out <x>` and, after a fix
round, `, fix out <y>` (the `out` of that phase's `summary`), or
`review tokens: unknown` / `fix tokens: unknown` for a phase that did not
measure.

- `queue: #<N> -> PR <url> [review: APPROVE] (in 0.0k / cw 95k / cr 1.47M / out 15k, 4 agents; review out 4k) [budget 3/10]`
- `queue: #<N> -> PR <url> [review: BLOCKING -> APPROVE after fix] (in 0.0k / cw 120k / cr 1.9M / out 21k, 6 agents; review out 4k, fix out 3k) [budget 3/10]`
- the other outcomes in the same place: `[review: HUMAN]`,
  `[review: BLOCKING -> needs-human after fix]` (re-review `BLOCKING`),
  `[review: BLOCKING -> HUMAN after fix]`,
  `[review: BLOCKING -> not posted after fix (<reason>)]`,
  `[review: BLOCKING -> fix escalated]`, `[review: BLOCKING -> fix failed]`,
  `[review: not posted (<reason>)]`
- `queue: #<N> escalated (needs-human) (<summary>) [budget 3/10]`
- `queue: #<N> failed (first failure, back in queue) (<summary>) [budget 3/10]` or `(second failure, needs-human) (<summary>) [budget 3/10]`
- `queue: idle (empty queue) [idle 2/16]` or `queue: idle (WIP limit <open>/<limit>) [idle 2/16]`
- `queue: stopped (<the line of queue-budget.sh>)`, e.g. `queue: stopped (stop: budget used up (10/10))`

## Pacing

`/loop` without an interval is self-paced: each iteration decides when the
next one runs (#188, D6).

- **Worked an issue** (released as pr, escalated or failed): run the next
  iteration right away; the queue may hold more.
- **Sub-agent running** (a sub-agent of Step 4 or 4c launched, no completion
  notification yet):
  schedule a fallback wakeup after 60 minutes, in case no notification
  arrives. A wakeup that finds the sub-agent still running claims nothing,
  skips Step 0 (a stop file or a used-up budget never interrupts a running
  issue; the next iteration's Step 0 sees it) and schedules the next fallback.
- **Idle** (empty queue, WIP limit reached, or WIP count unknown): run
  `~/.claude/bin/queue-budget.sh idle <max-idle>`. Exit 0: schedule the next
  iteration after 30 minutes; the queue and the review backlog change slowly.
  Exit 1 (the limit is reached) or 2: stop the loop.
- **Stop the loop** (schedule nothing, report why) when:
  - Step 0 exits 1: the stop file exists, the session id is missing, or the
    budget is used up;
  - `queue-budget.sh idle` reaches `<max-idle>`;
  - the arguments are invalid;
  - `queue-claim.sh` exits 1, or Step 6 finds the starting checkout on another
    branch. These need a human before the next claim.

## What this skill does not do

- Merge: the human merges every PR.
- Claim epics: `/implement-epic` stays a human choice (#188, D7).
- Answer escalations: it releases the issue with `needs-human` and moves on.
