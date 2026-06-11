---
description: Git & GitHub PR workflow mechanics — closing keywords, body vs comment
---

# Git & PR Workflow

- **Closing keywords auto-close — surrounding text does NOT negate them.** `Closes #X`, `Fixes #X`, `Resolves #X` (and `Close/Fixed/Resolved`) in a PR body or commit message close issue X the moment the PR merges, regardless of any words around them. Writing `Closes #2129 — no, this PR only unblocks` STILL closes #2129 — GitHub's parser reads the keyword, not the disclaimer. If a PR references an issue it must NOT close, use a non-keyword verb: `tracks #X`, `see #X`, `part of #X`, `unblocks #X`. Reserve `Closes/Fixes/Resolves` for the PR that genuinely completes the issue. This is the single most common accidental-close.
- **Issue/PR body is read more carefully than comments.** When status changes (reopened, scope shifted, partially done), UPDATE THE BODY — don't just add a comment. Best practice: update the body to reflect current reality AND drop a short comment pointing to the change, so watchers get a notification and the body stays the source of truth. A stale body with the real state buried in comment #14 gets missed.
- **When reopening an issue, mark what's done vs remaining in the body** with checked/unchecked boxes, and say why it was closed (e.g. accidental auto-close). Prevents redoing finished work.
