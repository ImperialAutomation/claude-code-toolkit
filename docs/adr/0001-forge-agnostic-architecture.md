# ADR-0001: Forge-Agnostic Architecture

**Status:** Accepted
**Date:** 2026-04-29
**Decision makers:** Jan Keijzer

## Context

The claude-code-toolkit is currently tightly coupled to GitHub:

- **8+ shell scripts** use the `gh` CLI directly (`gh-save.sh`, `git-push-pr-merge.sh`, `batch-issue-view.sh`, `batch-issue-status.sh`, `batch-pr-for-issues.sh`, `find-tracking-pr.sh`, `gh-issues-export.sh`, `release.sh`)
- **10+ skills** assume GitHub issue/PR workflows (`/decompose`, `/implement`, `/implement-epic`, `/finish`, `/bug`, `/extend`, `/refine`, `/update-tracking`, `/sync-closes`, `/review`)
- **Agents** reference GitHub-specific concepts (`issue-crafter`, `devops-automator`)
- **CI/CD skills** assume GitHub Actions
- **Search syntax** is GitHub-specific (`gh pr list --search "closes #123"`)

This creates three problems:

1. **Vendor lock-in** — users who prefer Forgejo, GitLab, or other forges cannot use the toolkit
2. **Data sovereignty** — GitHub (Microsoft) may use hosted code for AI training despite opt-out settings
3. **Fragility** — the toolkit is also coupled to Claude Code; as AI tooling evolves rapidly, betting on a single stack is risky

## Decision

Introduce a **forge abstraction layer** that decouples the toolkit from any specific forge platform. The migration follows the strangler fig pattern — gradual replacement, not big-bang rewrite.

### Architecture

Three abstraction layers, in order of priority:

```
Layer 1: Forge abstraction (GitHub, Forgejo, GitLab)
         ├── Issue operations (create, read, update, close, search, list)
         ├── PR operations (create, merge, update, search, list)
         ├── Label management (create, add, remove, list)
         ├── Release management (create, list)
         └── Repository metadata (branches, tags, remotes)

Layer 2: CI/CD abstraction (GitHub Actions, Forgejo Actions, GitLab CI)
         ├── Workflow definitions
         ├── Secrets management
         └── Runner configuration

Layer 3: AI agent abstraction (Claude Code, future tools)
         ├── Tool interface definitions
         ├── Skill execution model
         └── Agent orchestration
```

### Interface definition

The forge abstraction exposes these operations (preliminary):

```
forge issue create --title "..." --body "..." [--labels "..."]
forge issue view <number> [--json <fields>]
forge issue list [--state open|closed] [--search "..."] [--limit N]
forge issue edit <number> [--title "..."] [--body "..."] [--add-labels "..."]
forge issue close <number>

forge pr create --title "..." --body "..." --base <branch> --head <branch>
forge pr list [--state open|merged|closed] [--search "..."]
forge pr view <number> [--json <fields>]
forge pr merge <number> [--squash|--rebase|--merge] [--delete-branch]

forge label list
forge label create --name "..." [--color "..."]

forge release create <tag> [--title "..."] [--generate-notes]
```

### Adapter implementations

Each forge gets an adapter in `adapters/<forge>/`:

```
adapters/
  github/     # Wraps `gh` CLI — first adapter, extracted from current code
  forgejo/    # Wraps `tea` CLI + Forgejo REST API
  gitlab/     # Wraps `glab` CLI — future
```

Detection is automatic based on git remote URL:
- `github.com` → github adapter
- Known Forgejo/Gitea instances → forgejo adapter
- `gitlab.com` or self-hosted GitLab → gitlab adapter
- Override via environment variable `FORGE_ADAPTER=forgejo`

### Migration strategy

1. **Document** — this ADR (done)
2. **Extract** — when touching a GitHub-specific script, extract the forge operations into the adapter interface
3. **Second adapter** — build the Forgejo adapter when there is an actual need (migration or contributor request)
4. **Layer 2 and 3** — defer until the landscape stabilizes

Do NOT preemptively rewrite working code. Apply the abstraction only when code is being modified for other reasons, or when a second forge is actively needed.

## Consequences

### Positive
- Toolkit becomes usable with Forgejo, GitLab, and future forges
- Reduced vendor lock-in for both forge and AI tooling
- Cleaner separation of concerns in the codebase
- More attractive for open-source contributors on non-GitHub platforms

### Negative
- Additional indirection layer adds complexity
- `tea` CLI and `glab` CLI are less mature than `gh`
- Some GitHub-specific features (e.g., `actions/github-script`) have no direct equivalent
- JSON output formats differ between forges — adapter must normalize

### Risks
- Over-engineering: building adapters for forges nobody uses yet
- Lowest common denominator: losing GitHub-specific features that are genuinely useful
- Maintenance burden: keeping multiple adapters in sync

Mitigations: strangler fig pattern (gradual), only build adapters when needed, accept forge-specific extensions where the abstraction would be too leaky.

## References

- Forgejo REST API: https://forgejo.org/docs/latest/developer/api-usage/
- `tea` CLI: https://gitea.com/gitea/tea
- GitLab CLI (`glab`): https://gitlab.com/gitlab-org/cli
- Strangler fig pattern: https://martinfowler.com/bliki/StranglerFigApplication.html
