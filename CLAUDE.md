# Claude Code Toolkit

## Build changes in a worktree, never in the live checkout

`install.sh` symlinks `~/.claude/bin`, `~/.claude/skills`, `~/.claude/agents`,
`~/.claude/rules` and `~/.claude/CLAUDE.md` into the working tree of one checkout
of this repo. Whatever that checkout has checked out is what every project and
every Claude session runs, immediately.

So a toolkit change is built in a **linked git worktree**, never in that checkout.
A change goes live only when it lands on `main` and the live checkout pulls it.

**Why.** On a feature branch in the live checkout, every intermediate commit is
active system-wide before review. With #115, half-finished hook changes caused
permission prompts in unrelated projects for commands that were prompt-free
before, and `git switch main` was not an option while the implementing agent was
still working in that tree.

**Live checkout** = the main worktree whose top level equals
`dirname(readlink -f ~/.claude/bin)`. When `~/.claude/bin` is not a symlink,
nothing is live and none of this applies. Other repositories are never live.

**How it is enforced:**

- `/implement` and `/implement-epic` resolve their tree with
  `git-resolve-worktree.sh --issue <N> --create <slug>`. From the live checkout
  that yields the sibling `../claude-code-toolkit-<N>` on `issue-<N>-<slug>`,
  branched from `origin/main`, created on first use and reused after.
- `hook-block-toolkit-live-checkout.sh` refuses `git checkout`/`git switch` that
  would take the live checkout off `main` (new branches, existing branches,
  detached commits), and names the worktree route in its message. Path checkouts
  pass. It sees only Claude's tool calls, not a human's terminal.

**Working by hand:** create the worktree yourself and work there with
`git -C <worktree>` and absolute paths:

```bash
git -C ~/Projects/claude-code-toolkit worktree add --no-track \
    -b issue-<N>-<slug> ~/Projects/claude-code-toolkit-<N> origin/main
```

Removing the worktree and fast-forwarding the live checkout after merge: #206.
