# Failure modes of the git wrapper scripts

Two scripts in `bin/` can report what looks like success while doing nothing, or
while quietly skipping a check you rely on. Both failures are readable from the
output only if you know what to look for, so this page lists the signatures.

## `git-commit.sh` — "ok N files changed" is not a commit

The script can finish without creating a commit while its output still opens
with a line that reads like progress:

```
ok 2 files changed, 183 insertions(+), 5 deletions(-)
```

That line comes from the `git add` before it. A real commit prints a
`[branch abc1234] <message>` line; if that line is absent, nothing was
committed.

**Always verify with `git log --oneline -1`, never with the tail of the output.**
The tail is the least reliable part: pre-commit prints per-hook results, so the
last line is often `Passed` from an unrelated hook even when the commit failed.

Five ways this happens:

| # | Cause | Signature |
|---|---|---|
| 1 | Pre-commit rolled back its own auto-fixes | `[WARNING] Stashed changes conflicted with hook auto-fixes... Rolling back` |
| 2 | Wrong repo (worktrees) | every hook `(no files to check) Skipped`, and a branch name you are not on |
| 3 | cwd outside any repo | `fatal: not a git repository` |
| 4 | A formatter rewrote the file you just staged | `git status --short` shows `MM` on the file afterwards |
| 5 | A hook failed on its merits (lint) | `npm error command failed` above a later `Passed` line |

Modes 1 and 4 are the same rollback with different triggers: a hook modifies a
staged file in a way that conflicts with the stashed unstaged version. The fix
is to stage the whole file (`git add <file>`) rather than partial changes, and
to re-stage after a formatter rewrites it.

Mode 5 is worth calling out because the lint command usually runs with
`--max-warnings 0`. A **warning** then blocks the commit while the linter itself
reports `0 errors, 1 warning`, which does not read as fatal. Run the linter
directly to see the real message. Note that `cd <dir> && npx eslint` is
unreliable for this — the working directory does not always take effect and
eslint then silently reports nothing, which reads as clean. Prefer
`npm --prefix <dir> exec -- eslint <file>`.

For modes 2 and 3 the script already has the option you need: `--repo <path>`.
It commits in the shell cwd, not wherever `git add -C <path>` pointed.

## `git-push-pr-merge.sh` — bypasses `gh pr create` hooks

The script creates the pull request itself. Any `PreToolUse` hook registered
against `gh pr create` therefore never fires.

This matters when a project gates PR bodies. PAM has
`hook-check-agent-review.sh`, which requires a literal marker block from
`.github/PULL_REQUEST_TEMPLATE.md` in the body of every agent-authored PR. Going
through the wrapper skips that gate entirely: the PR is created, no hook
complains, and the missing checklist is only noticed if someone reads the body.

**Until the script validates this itself, check the body before you push** when
the project has such a gate. The marker block is copied verbatim from the
template and each box ticked against the actual diff — a heading with a similar
name does not satisfy a parser that matches markers literally.

Closing the gap in the script is deliberately not done here: it would apply to
every project using the wrapper, including ones with no PR template, so it needs
a guard on whether the template actually defines the markers. That is a separate
change to make on purpose rather than as a side effect.

## `git-push-pr-merge.sh` — the CI gate cannot prove a check set is complete

The gate matches checks to the pushed commit: it records the SHA after the push
and only judges a check set once `gh pr view --json headRefOid` reports that SHA
as the PR head. That rules out verdicts about the previous head, which is the
failure that matters in practice, because the documented recovery for a blocked
gate is "fix, push to the same branch, re-run" and that re-run keeps the open PR.

What it still cannot establish is whether the set it sees is **all** of the runs
for that commit. GitHub publishes no expected count, so a commit with three
workflows whose first one has registered and gone green is indistinguishable from
a commit with one workflow that has finished. The gate reports PASS.

In practice the window is small — GitHub creates a push's check runs together,
within a second or two — and an empty set is still covered by `--ci-grace`. The
exposure is a repo where some runs are created by a *different* trigger than the
rest: a workflow started by a `workflow_run`, a `check_suite` completion, or an
external service posting a commit status after its own queue. Those can appear
tens of seconds after the push, long after the first batch is green.

**When a repo has such a staggered trigger, do not rely on the gate alone.**
Either make the slow check required via branch protection, so GitHub's own merge
button blocks on it regardless of what this script concluded, or run with
`--no-merge` and merge after reading the PR's checks yourself.

## `git-push-pr-merge.sh` — an allowed failing check is allowed by name only

`--allow-failing-check <name>` exempts one named check from blocking. It is
narrower than `--no-ci-wait` in every respect — the head still has to match the
pushed commit, pending checks are still waited for, any other red check still
blocks — but what it allows, it allows unconditionally.

The flag is opened for a specific cause: an advisory on a pinned package makes
the dependency audit red in every PR. Once it is in a command line, or in an
orchestrator's prompt, a **different** failure of that same check also passes. A
new critical advisory, or a genuinely vulnerable package the PR itself adds,
reads identically to the known one.

Two signatures to read for:

| Signature | What it means |
|---|---|
| `CI_GATE: PASS (allowed failing: <names>)` | A check was red and waved through. A weaker claim than a bare `CI_GATE: PASS`, and the only place the bypass is recorded |
| A `--allow-failing-check` that outlives its cause | The named check has been bypassed on every PR since, including ones where it was red for a new reason |

Both the bypassed list and the `CI_GATE: FAIL` list are comma-joined, so a check
whose own name contains a comma is ambiguous to read back: `lint, typecheck`
looks like two checks. The gate's decision is unaffected (matching is on whole
names, not on the joined string) — only the printed line is ambiguous, so count
the names against `gh pr checks` rather than splitting on commas.

The second is the one that bites, because nothing expires the flag. Narrowing a
bypass to its cause by matching the failed job's log is tracked in issue #92.

**How to apply:** before adding the flag, confirm the check is red on the base
branch too — that is what distinguishes "red repo-wide" from "red because of this
diff". Remove it from the command line as soon as the underlying cause is fixed,
and when a `PASS (allowed failing: ...)` line appears in a merge you did not
expect it on, read the check's log before trusting the merge.

## How to apply

- After **every** `git-commit.sh`, run `git log --oneline -1`. Treat `ok N files
  changed` as evidence of `git add` and nothing more.
- When a commit does not appear, read the output for the five signatures above
  before re-running. Re-running blind repeats the same failure.
- When a project gates PR bodies, assemble and check the body before invoking
  `git-push-pr-merge.sh` — the wrapper will not do it for you.
- `CI_GATE: PASS` means every check the gate could see on the pushed commit was
  green, not that every check that will eventually run has. In a repo with
  staggered check triggers, back it with branch protection or merge by hand.
- `CI_GATE: PASS (allowed failing: ...)` means something was red and waved
  through by name. Treat the named checks as unverified, and drop the flag once
  the cause that justified it is fixed.
