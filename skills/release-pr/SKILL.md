---
name: release-pr
description: Create the develop → master release PR — inspect what changed since the last tag, decide the semver bump, apply the release:major/minor/patch label so the tag is generated correctly, and write the release body. Use for "release to master", "promote develop", "make a release PR", "cut a release", "new version tag".
argument-hint: [major|minor|patch]
user-invocable: true
---

# Release PR — develop → master

Promotes the accumulated `develop` batch to `master`. Merging the PR is what
creates the version tag and triggers the staging deploy, so the **label is
load-bearing**: `semver-tag.yml` reads the merged PR's `release:*` label and
computes the new tag from it. A wrong label ships a wrong version number; a
missing label fails the merge.

**You do not create the tag.** Do not run `git tag`. The workflow does it.

## Step 1 — Collect the facts

```bash
bash ~/.claude/skills/release-pr/collect.sh --repo OWNER/NAME
```

Omit `--repo` to let it resolve via `gh repo view`. Read-only: it fetches and
inspects, never writes a ref. Output sections:

| Section | What it decides |
|---|---|
| CURRENT VERSION | the three candidate tags — you pick one |
| SIZE | the "N merged PRs, N commits, N files, +N/−N" opening line |
| BEHIND CHECK | **stop condition** — see below |
| MERGED PRs IN THIS BATCH | the list you write the body from |
| SEMVER SIGNALS | migrations, lockfiles, env vars, API surface |

**BEHIND CHECK is a gate.** Merge commits from past releases are expected.
A *non-merge* commit on master only means a hotfix landed directly on master
and is not in develop — back-merge it into develop before releasing, or the
release silently ships around it.

## Step 2 — Decide the bump

Answer one question: **could a user do something after this release they could
not do before?**

| Bump | When | Real example |
|---|---|---|
| `major` | breaking change consumers must react to — removed/renamed route or response field, a migration dropping data still in use, a config rename with no fallback | (none yet in this repo) |
| `minor` | new capability that did not exist in the previous tag | v1.9.0 — registration kill-switch, unified seen-tracking |
| `patch` | fixes, refactors, docs, dependency bumps, tests. No new capability | v1.7.1 — backups produced archives that could not be restored; "fixes a path that was already supposed to work" |

Mixed batch → the highest bump present wins. A batch with one new feature and
twelve fixes is `minor`.

If the argument (`$ARGUMENTS`) names a bump, use it. Otherwise decide from the
signals and **state the reasoning in the PR body** — every past release does.

## Step 3 — Write the body

Write to `/tmp/<project>-pr-body-release-<version>.md` with the Write tool
(never a heredoc), then pass it as `--body-file`.

Structure, consistent across every release since v1.5.0:

```markdown
## Release develop → master (vOLD → vNEW)

Promotes the current `develop` batch (N merged PRs, N commits, N files,
+N/−N) to `master`, tagging a semver release and deploying to **staging**.

`release:<bump>` — <one paragraph justifying the bump, naming what is new or
what class of thing is fixed, and explicitly noting what is NOT affected:
"no breaking API change and no schema change".>

### <Thematic heading, not a PR number> (#issue, PR #n)

<What was broken or missing, why it mattered, how it was closed. Prose, not
a changelog. Group related PRs under one heading.>

### Also in this batch

- **<Short label>** (#n) — one or two lines each for the smaller items.

## Operator note          ← only if a human must DO something
## Migration note         ← only if migrations changed
## Deploy note            ← always

<!-- AGENT-REVIEW:START -->
...six checklist items, every box [x]...
<!-- AGENT-REVIEW:END -->

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Headings describe **the problem solved**, not the PR. Past releases use
"The empty string was a config hole", "The restore path did not work",
"Production health check pointed at a path that never existed".

### The three notes

- **Operator note** — anything a human must do around the deploy: renamed env
  vars (with an old→new table), a new variable to set, a feature that ships
  *off* and needs turning on. Include the restart caveat: use `stop.sh`/
  `start.sh`, since a plain `docker compose restart` leaves `pam_api` untouched
  behind its `depends_on` health gate, so a new env value never reaches the
  process.
- **Migration note** — one bullet per migration: what it does, whether it is
  additive or destructive, whether it is idempotent. Call out any drop
  explicitly and say why it is safe (e.g. expand/contract split across two
  revisions so no intermediate commit is inconsistent).
- **Deploy note** — always. State the tag and that merging triggers
  `deploy-staging`. If a lockfile changed, say **"this is a rebuild, not a
  plain restart."**

### AGENT-REVIEW section

Mandatory when the PR carries `agent-authored` (auto-applied). The
`agent-pr-checklist` gate fails if the section is missing or any box is
unticked. Copy the six items from `.github/PULL_REQUEST_TEMPLATE.md` and tick
each with a **specific justification for this batch** — not a bare `[x]`:

```
- [x] No destructive ops added without a second barrier — `20260812002` drops
      `persons.waves_last_viewed_at`, deliberately split into its own revision
      so it runs only after the data moved to `match_actions.seen_at`
```

If an item genuinely does not apply, say why it does not apply. Never tick a
box you have not checked.

## Step 4 — Create the PR

Apply the label **at creation**, so `semver-check` sees exactly one:

```bash
gh pr create --repo OWNER/NAME --base master --head develop \
  --label "release:minor" \
  --title "release: v1.9.0 — registration kill-switch (#2480), unified seen-tracking (#2466), bare-domain vhosts (#2369)" \
  --body-file /tmp/pam-pr-body-release-190.md
```

Title format: `release: vX.Y.Z — <2-3 headline items with issue numbers>`.

## Step 5 — Verify the gates

```bash
gh pr view <PR> --repo OWNER/NAME --json labels,statusCheckRollup \
  -q '{labels: [.labels[].name], checks: [.statusCheckRollup[] | {name, status, conclusion}]}'
```

Expect `Validate release label`, `agent-pr-checklist`, `agent-pr-label`,
`vitest`, `tsc --noEmit`, `dependency-audit` to pass. `Auto-merge minor/patch`
and `Playwright E2E` skip on release PRs — that is normal, not a failure.

To wait for them without polling by hand:

```bash
prev=""
while true; do
  s=$(gh pr checks <PR> --repo OWNER/NAME --json name,bucket 2>/dev/null) || { sleep 30; continue; }
  [ -z "$s" ] && { sleep 30; continue; }
  cur=$(jq -r '.[] | select(.bucket!="pending") | "\(.name): \(.bucket)"' <<<"$s" | sort -u)
  comm -13 <(echo "$prev") <(echo "$cur")
  prev=$cur
  jq -e 'all(.bucket!="pending")' <<<"$s" >/dev/null 2>&1 && { echo "ALL CHECKS COMPLETE"; break; }
  sleep 30
done
```

## Step 6 — Stop

**Do not merge.** No server-side protection on the free tier makes merging to
`master` the user's call. Report the PR URL, the bump and its reasoning, the
green checks, and any operator action needed before the deploy.

After the user merges, the tag appears automatically:

```bash
git fetch origin --tags --quiet && git tag --sort=-v:refname | head -3
git show v1.9.0 --no-patch --format='%s'
```

The tag is annotated, tagged by `github-actions[bot]`, with message
`Release vX.Y.Z (PR #N: <title>)`.

## Gotchas

- **The label must be present at merge, not just at creation.** `semver-tag.yml`
  re-reads the labels of the merged PR. Removing it after CI goes green fails
  the tag job with "Expected exactly one release:* label".
- **Exactly one `release:*` label.** Two labels fail `semver-check`; the tag job
  fails the same way as a defence in depth.
- **`--label` at creation beats `gh pr edit` after.** `semver-check` runs on
  `opened`, so creating unlabelled fires one red check before the label lands.
- **An unlabelled PR to master fails the tag job after the merge has landed.**
  PR #2205 (ad-hoc hotfix, pre-convention) merged fine, then `Semver Tag` ran
  and **failed** — `Expected exactly one release:* label, found 0`. The commit
  is on master, untagged, and the failure is only visible in the Actions tab.
  The `skip` branch covers only a *direct push* with no PR behind it, never an
  unlabelled PR. Label before merging, always.
- **Merge commits on master are not "master is ahead".** Every past release
  leaves one. Only non-merge commits there are a problem.
- **The tag is computed from the latest existing tag**, not from the PR title.
  A title saying v1.9.0 while the label says `patch` produces v1.8.1 and a
  title that lies. Recompute the title from the label.
- **`git tag` by hand breaks the next release.** The workflow reads the highest
  existing tag; a stray tag shifts every future version.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Validate release label` fails: "no release label" | created without `--label` | `gh pr edit <PR> --add-label release:minor` |
| `agent-pr-checklist` fails | AGENT-REVIEW section missing, or a box left `[ ]` | restore from `.github/PULL_REQUEST_TEMPLATE.md`, tick every box with a justification |
| `dependency-audit` fails | a time-boxed exception expired | check `docs/governance/audit-exceptions.yml`; take the fix if past cooldown, otherwise re-date to the cooldown end — never override the cooldown for a security label |
| No tag after merge | label removed before merge, or direct push | check the `Semver Tag` run; re-tagging by hand needs care since it becomes the base for the next release |
| `collect.sh` shows a non-merge commit on master | hotfix landed directly on master | back-merge master into develop before releasing |
