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

## Labels

| Label | Meaning |
|---|---|
| `agent-ready` | An agent may pick this up |
| `agent-wip` | Claimed by a session; others skip it |
| `needs-human` | Blocked on a decision; a comment holds the question, the options and the recommendation |

## Recalibration

The list is not fixed. A category the human always accepts drops off; a
category whose agent decisions get reverted is added. The measurement script
supplies the numbers.
