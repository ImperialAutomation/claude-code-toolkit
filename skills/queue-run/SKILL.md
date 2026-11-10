---
name: queue-run
description: One iteration of the local queue runner - claim the oldest agent-ready issue, refine and implement it in a sub-agent, release it. Driven by /loop
argument-hint: ""
user-invocable: true
---

# Queue Run

One iteration of the local queue runner (#183). It takes one `agent-ready` issue
through `/refine <N> auto` and `/implement <N>` to an open PR, without a human,
unless the issue hits the escalation list. Repeat it with `/loop`, self-paced:

```
/loop /queue-run
```

The labels and the escalation categories are described in
`docs/escalation-list.md` (the single source). This skill only detects an
escalation; `/refine` and the escalation hook raise it.

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

The session running the loop stays thin: it calls a few scripts, spawns one
sub-agent, measures its tokens and releases the claim. All issue work happens in the sub-agent.

`<project>` is the basename of `<repo>`, lowercase, non-alphanumerics as `-`.

### Step 1: Capacity

```bash
~/.claude/bin/agent-pr-wip.sh --repo <repo>
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

Use the Agent tool, `subagent_type: "general-purpose"`, in the foreground (do
NOT use `run_in_background`): the iteration needs its result before it can
release the claim. The spike on #188 confirmed that this sub-agent can run
`/implement` including its own Phase 3 verification sub-agent.

The report arrives as the sub-agent's hand-back message. A sub-agent that ends
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

The Agent tool result of Step 4 contains `agentId: <id>`, the issue sub-agent's
id. Measure that agent and every agent it spawned, whatever the outcome (a
failed or escalated run costs just as much):

```bash
~/.claude/bin/cmd-save.sh /tmp/<project>-queue-tokens-<N>.json ~/.claude/bin/agent-tokens.py --agent <id> --json
```

- exit 0: `/tmp/<project>-queue-tokens-<N>.json` holds the totals; Read it for
  its `summary` (Step 7) and pass it to the release in Step 5.
- exit 1 (no transcript), exit 2 (ambiguous or unreadable), or no `agentId` in
  the result: the measurement failed. That never fails the iteration: release
  without `--tokens`, report `tokens: unknown`.

The `subagent_tokens` of a completion notice is not this number: it is roughly
the final context size.

### Step 5: Release

Read the labels again yourself; the label, not the report, decides an
escalation:

```bash
~/.claude/bin/gh-save.sh /tmp/<project>-queue-labels-<N>.json issue view <N> --json labels
```

Then release in exactly one way. `agent-wip` is dropped only here, after the
outcome exists: the escalation hook treats an issue with `agent-wip` as an
autonomous run, so dropping it earlier would let a PR through unchecked.

When Step 4b measured, every release below carries
`--tokens /tmp/<project>-queue-tokens-<N>.json` right after `--repo <repo>`;
when it failed, leave the option out. Each release comments with the totals
(or `tokens: unknown`) and appends one row to `~/.claude/queue-runs.tsv`.

| Situation | Release |
|---|---|
| `needs-human` is on the issue (whatever the report says) | `queue-claim.sh --repo <repo> release <N> escalated` |
| `ESCALATED` without `needs-human` | `queue-claim.sh --repo <repo> release <N> escalated` (it adds the label and warns) |
| `PR_OPENED`, and `gh-save.sh /tmp/<project>-queue-pr-<N>.json pr view <url> --json state` reads `OPEN` | `queue-claim.sh --repo <repo> release <N> pr <url>` (it swaps `agent-ready` for `agent-pr`, so the issue is not claimed again) |
| `FAILED`, no usable report, or a PR URL that does not resolve to an open PR | `queue-claim.sh --repo <repo> release <N> failed /tmp/<project>-queue-failure-<N>.md` |

For a failure, first write `/tmp/<project>-queue-failure-<N>.md` with the
Write tool: the ERROR, ATTEMPTS and LAST_ERROR_OUTPUT of the report (or "the
sub-agent ended without a report"), and the worktree path when there is one.
`queue-claim.sh` turns it into the issue comment. A first failure adds
`agent-failed` and puts the issue back in the queue for one retry; a second
adds `needs-human` too (#188, D5). The worktree and branch of a failed run stay
in place: a retry reuses them, and a human may want to look.

A non-zero exit from `queue-claim.sh release` leaves labels half-changed:
report its stderr and stop the loop.

### Step 6: Live checkout check

```bash
git -C <repo> branch --show-current
```

It must still print the branch noted in Step 1. If it does not, something
switched the checkout the session started in (in the toolkit repo, the live
one). Stop the loop and report it; do not switch it back yourself.

### Step 7: Report

One line per iteration. A worked issue ends with its token totals: the
`summary` of Step 4b in parentheses, or `(tokens: unknown)` when the
measurement failed.

- `queue: #<N> -> PR <url> (in 0.0k / cw 95k / cr 1.47M / out 15k, 3 agents)`
- `queue: #<N> escalated (needs-human) (<summary>)`
- `queue: #<N> failed (first failure, back in queue) (<summary>)` or `(second failure, needs-human) (<summary>)`
- `queue: idle (empty queue)` or `queue: idle (WIP limit <open>/<limit>)`

## Pacing

`/loop` without an interval is self-paced: each iteration decides when the
next one runs (#188, D6).

- **Worked an issue** (released as pr, escalated or failed): run the next
  iteration right away; the queue may hold more.
- **Idle** (empty queue, WIP limit reached, or WIP count unknown): schedule the
  next iteration after 30 minutes. The queue and the review backlog change
  slowly.
- **Stop the loop** (schedule nothing, report why) when `queue-claim.sh` exits
  1, or Step 6 finds the starting checkout on another branch. Both need a
  human before the next claim.

## What this skill does not do

- Merge: the human merges every PR.
- Claim epics: `/implement-epic` stays a human choice (#188, D7).
- Answer escalations: it releases the issue with `needs-human` and moves on.
