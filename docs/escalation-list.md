# Escalation list

Agents working the issue queue decide everything themselves, except the
categories below. A question that falls in one of them is not answered by the
agent: it becomes an issue comment holding the question, the options and the
recommendation, the issue gets the `needs-human` label, and the run stops.

This list is the single source for `/refine`, `/implement` and the queue
runner. Change it here, not in a skill.

## Categories

1. **Widening permissions**: a hook or allowlist change that approves more
   without a prompt. Narrowing (a deny with a hint, removing an approval) is
   decided by the agent, because the worst case is an extra prompt.
2. **Public-repo leakage**: anything that could carry project names, internal
   paths or project issue references into this repo.
3. **Breaking an interface**: renaming or removing a script, or changing its
   arguments, while skills or downstream repos call it.
4. **Global behavior**: new or changed `rules/` and global CLAUDE.md content,
   because it affects every session in every project.
5. **Scope change**, or a conflict with an earlier explicit decision.

## Enforcement

Categories 1 to 4 are checked on the diff by `bin/escalation-check.sh
[--repo <worktree>] [--base <branch>]`. It compares HEAD with its merge base
against the base branch (`origin/<base>` when it exists) and prints one line
per hit, `<key>  <file>  <reason>`; exit 1 on any hit, 0 when clean, 2 when the
diff cannot be computed. Category 5 cannot be read from a diff and stays agent
judgment.

| Category | Key | Check |
|---|---|---|
| 1. Widening permissions | `permissions` | Any change to a file that can approve or that enforces the check: `bin/hook-auto-approve-bash.py` and its `.sh` wrapper, `claude-md/settings-global.jsonc`, `claude-md/settings-template.jsonc`, `.claude/settings*.json`, `bin/escalation-check.sh`, `bin/hook-escalation-check.sh`. Deny-only hooks and test files do not count. A diff cannot tell widening from narrowing, so this over-escalates on purpose |
| 2. Public-repo leakage | `leakage` | Added lines matched against the denylist (below). A missing or unreadable denylist, or an invalid pattern, is a hit |
| 3. Breaking an interface | `interface` | A file under `bin/` or `skills/` deleted or renamed, or a changed `argument-hint:` in a modified `SKILL.md`. `bin/tests/` and `bin/test-*` excluded |
| 4. Global behavior | `global` | Any change under `rules/` or `claude-md/` |
| 5. Scope change | – | Not detectable |

`bin/hook-escalation-check.sh` (PreToolUse, matcher `Bash`, registered in
`claude-md/settings-global.jsonc`) runs the check when a PR is opened with
`git-push-pr-merge.sh` or `gh pr create` at command position. It reads every
`Closes|Fixes|Resolves #N` from the PR body (`--body-file`, or the command
text for an inline body) and fetches those issues' labels:

- **Autonomous** (a closed issue has `agent-wip`): a hit whose category lacks
  `approved:<key>` on every `agent-wip` issue denies the call, with the hint to
  post the question, the options and the recommendation as an issue comment,
  add `needs-human` and stop. Approved hits pass and are listed on stderr.
- **Interactive** (no `agent-wip`, or no closing keyword): hits are listed on
  stderr and nothing is blocked.
- A missing body file, or labels `gh` cannot fetch, deny: autonomous and
  interactive cannot be told apart then. The hook denies, never asks, because
  an ask hangs an unattended session.

### Denylist

`~/.claude/escalation-denylist`, per machine. It lives outside the repo and
outside the symlinked directories on purpose: a denylist in this public repo
would itself be the leak. Format: one case-insensitive extended regex per line;
lines starting with `#` are comments, blank lines are skipped.

```
# client and project names
acme-(webshop|portal)
internal\.example\.com
```

A leakage hit names the file, the added line's number and the denylist line
number, never the matched text, so the hit can be quoted in a public issue.

## Labels

| Label | Meaning |
|---|---|
| `agent-ready` | An agent may pick this up |
| `agent-backlog` | Triaged as agent-doable, but not released to the queue: the runner ignores it. Release by swapping it for `agent-ready`; this is how the human meters the queue's token spend |
| `agent-wip` | Claimed by a session; others skip it |
| `needs-human` | Blocked on a decision; a comment holds the question, the options and the recommendation |
| `agent-failed` | Agent run failed on this issue; a second failure adds needs-human. The queue runner claims it once more (one retry) |
| `agent-pr` | The queue runner opened a PR for this issue; it replaces `agent-ready`, so the issue is not claimed again. When the PR is closed unmerged, a human swaps it back for `agent-ready` |
| `approved:permissions` | Human approved a category 1 hit on this issue |
| `approved:leakage` | Human approved a category 2 hit on this issue |
| `approved:interface` | Human approved a category 3 hit on this issue |
| `approved:global` | Human approved a category 4 hit on this issue |

These are issue labels. The PR label `agent-authored` is separate: `/implement`
puts it on every PR it opens (creating it when the repo lacks it), and
`bin/agent-pr-wip.sh` counts the open ones against the agent PR WIP limit,
which the queue runner checks before a claim. The limit is 3, or the
`--max-prs N` of `/queue-run` (passed as `agent-pr-wip.sh --limit N`). It is a
separate brake from the loop's issue budget (`--budget`): the WIP limit
protects review time, the budget protects tokens (#251, D6).

## Recalibration

The list is not fixed. A category the human always accepts drops off; a
category whose agent decisions get reverted is added. The measurement script
`bin/decision-metrics.py` supplies the numbers.
