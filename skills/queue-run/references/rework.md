# Queue Run: rework of an agent PR

Reference for `/queue-run` when Step 1's `queue-claim.sh claim --rework`
printed `<N>` (#300). It replaces Steps 2 to 5 of the iteration; Steps 6 and 7
and "Pacing" apply as usual. `<repo>`, `<project>` and `<model>` are those of
the skill.

Rework is a new round on the PR the queue runner already opened for the
issue, after a review that arrived once the issue was released as `agent-pr`.
Only the human starts it: they post what should change (a PR review, review
comments, or a PR or issue comment holding their decision on a `HUMAN`
question), remove `needs-human` when it is set, and add `agent-rework` to the
issue (`docs/escalation-list.md`). The loop pushes to the existing PR branch
and never opens a PR.

The sub-agents are the **Fix round** and the **Reviewer** of
`~/.claude/skills/queue-run/references/review-and-fix.md`, with unchanged
inputs; Read that file before the first spawn. While one of them runs, the
"Sub-agent running" rule of "Pacing" holds.

## R1: Issue and PR

```bash
~/.claude/bin/gh-save.sh /tmp/<project>-queue-issue-<N>.json issue view <N> --json title,body,labels
~/.claude/bin/gh-save.sh /tmp/<project>-queue-rework-pr-<N>.json pr list --state open --limit 200 --json number,url,headRefName,createdAt,closingIssuesReferences --jq '[.[] | select(any(.closingIssuesReferences[]; .number == <N>)) | {number, url, headRefName, createdAt}]'
```

`<title>` is the issue's title. Exactly one PR in the list: it is `<pr>`
(`number`), `<pr-url>` (`url`) and `<branch>` (`headRefName`). No PR, or more
than one: start no sub-agent. Comment on the issue
(`gh issue comment <N> --body-file /tmp/<project>-queue-rework-<N>.md`, the
file starting with the line `<!-- queue-runner -->`) that the rework found no
open PR closing #<N> (or which PRs it found), then release as escalated (R5).
A closed PR is a human question, not a retry (D7).

## R2: Worktree

`git -C <repo> worktree list --porcelain`: the `worktree <path>` whose
`branch` line is `refs/heads/<branch>` is `<worktree>`. When there is none
(cleaned up after the release), make it on the remote PR branch:

```bash
git -C <repo> fetch origin <branch>
git -C <repo> worktree add <repo>-<N> <branch>
git -C <repo>-<N> branch --set-upstream-to origin/<branch>
```

`<worktree>` is then `<repo>-<N>`. When `<repo>-<N>` already exists on another
branch, or a command fails, release as failed (R5) with the command and its
output.

## R3: Review input since the last round (D6)

Save the four lists (each line one JSON object):

```bash
~/.claude/bin/gh-save.sh /tmp/<project>-queue-rework-<N>-reviews.json api repos/{owner}/{repo}/pulls/<pr>/reviews --paginate --jq '.[] | {url: .html_url, at: .submitted_at, id, state, marker: ((.body // "") | startswith("<!-- queue-runner -->"))}'
~/.claude/bin/gh-save.sh /tmp/<project>-queue-rework-<N>-inline.json api repos/{owner}/{repo}/pulls/<pr>/comments --paginate --jq '.[] | {url: .html_url, at: .created_at, review: .pull_request_review_id, marker: ((.body // "") | startswith("<!-- queue-runner -->"))}'
~/.claude/bin/gh-save.sh /tmp/<project>-queue-rework-<N>-pr-comments.json api repos/{owner}/{repo}/issues/<pr>/comments --paginate --jq '.[] | {url: .html_url, at: .created_at, marker: ((.body // "") | startswith("<!-- queue-runner -->"))}'
~/.claude/bin/gh-save.sh /tmp/<project>-queue-rework-<N>-issue-comments.json api repos/{owner}/{repo}/issues/<N>/comments --paginate --jq '.[] | {url: .html_url, at: .created_at, marker: ((.body // "") | startswith("<!-- queue-runner -->"))}'
```

The cutoff is the time of the last PR comment with `marker: true` (the last
round comment, R4), or the PR's `createdAt` when there is none. `<comments>`
is, one URL per line:

- every review, inline comment, PR comment and issue comment after the
  cutoff with `marker: false`, except a review in `PENDING` state and an
  inline comment whose `review` is one of the selected reviews (the fix round
  fetches those through the review);
- the re-review named in the last round comment, when its verdict there was
  not `APPROVE`: it was posted before that comment, but no round addressed it.

Empty: start no sub-agent. Comment on the issue as in R1 that there is no
review input since the cutoff, and release as escalated (R5).

## R4: Fix round, re-review, round comment

1. Spawn the **Fix round** with `<N>`, `<title>`, `<repo>`, `<pr>`,
   `<pr-url>`, `<worktree>`, `<branch>` and `<comments>`; measure it into
   `/tmp/<project>-queue-tokens-<N>-fix.json` as in Step 4b.
2. `FIXED`: spawn the **Reviewer** with the same inputs (the re-review);
   measure it into `-review-1`. Exactly one fix round and one re-review.
   `ESCALATED`, `FAILED` or no report: no re-review and no round comment, so a
   retry or the human's answer sees the same input again; go to R5.
3. After a `FIXED`, the loop session posts the round comment (D8): Write
   `/tmp/<project>-queue-rework-round-<N>.md`, then
   `gh pr comment <pr> --body-file /tmp/<project>-queue-rework-round-<N>.md`.
   It is built from the `ROUND` lines of the fix report and the re-review:

```
<!-- queue-runner -->
## Queue runner: rework round

Addressed: <the <comments> URLs>
Re-review: <VERDICT> <REVIEW_URL>, or "not posted: <ERROR>"

Fixed:
- <sha>: <finding>
Rejected:
- <finding>: <reason>
Left for the human:
- <finding>: <question>; options: <options>; recommendation: <one>
```

A heading with no entries says `none`. The marker line comes first: R3 of the
next round finds the cutoff by it.

Tokens: sum the files that measured, as in Step 4c, into `-review.json` and
`-fix.json`, and both phases into `/tmp/<project>-queue-tokens-<N>.json` when
every agent of this iteration measured.

## R5: Release

Read the labels as in Step 5, then release in exactly one way; the first
matching row wins. Each is `~/.claude/bin/queue-claim.sh --repo <repo> [<options>] release ...`
with the options of Step 5 that have a value: `--tokens` (the whole),
`--review-final <V>` (the re-review: `APPROVE`, `BLOCKING`, `HUMAN`, or
`error` when not posted), `--review-tokens` and `--fix-tokens`. A rework has
no first review: leave out `--review` and `--review-findings`.

| Situation | Release |
|---|---|
| No open PR, more than one, or no review input (R1, R3) | `release <N> escalated` (adds `needs-human`) |
| Fix `ESCALATED`, or `needs-human` on the issue after the fix | `release <N> escalated` |
| Worktree not usable (R2), fix `FAILED` or no report | `release <N> failed /tmp/<project>-queue-failure-<N>.md` |
| Re-review `APPROVE` and no `left` finding | `release <N> rework <pr-url>` |
| Re-review `BLOCKING`, `HUMAN` or not posted, or a `left` finding | `release <N> rework <pr-url> /tmp/<project>-queue-review-<N>.md` |

`rework` swaps `agent-rework` for `agent-pr`; with the note it adds
`needs-human` and puts the note in the issue comment. Write the note first
with the Write tool: the re-review verdict and URL, the round comment's URL
and each `left` finding. `escalated` and `failed` keep `agent-rework`: a first
failure gets its one retry through the next `claim --rework`, a second one
adds `needs-human` (D5). Every rework release counts toward `--budget` (D2).
Then `queue-budget.sh worked` as in Step 5.

## Report line (Step 7)

`queue: #<N> rework PR <url> [review: APPROVE] (fixed 3, rejected 1, left 0) (<summary>; review out <x>, fix out <y>) [budget 4/10]`

The counts are the `ROUND` lines. Other outcomes in the same place:
`[review: BLOCKING, needs-human]`, `[review: HUMAN, needs-human]`,
`[review: APPROVE, needs-human (left 1)]`,
`[review: not posted (<reason>), needs-human]`. Without a fix round:
`queue: #<N> rework escalated (<no open PR | nothing to address | fix escalated>) (<summary>) [budget 4/10]`
or `queue: #<N> rework failed (first failure, back in queue) (<summary>) [budget 4/10]`.
