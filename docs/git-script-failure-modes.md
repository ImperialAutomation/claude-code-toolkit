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

## How to apply

- After **every** `git-commit.sh`, run `git log --oneline -1`. Treat `ok N files
  changed` as evidence of `git add` and nothing more.
- When a commit does not appear, read the output for the five signatures above
  before re-running. Re-running blind repeats the same failure.
- When a project gates PR bodies, assemble and check the body before invoking
  `git-push-pr-merge.sh` — the wrapper will not do it for you.
