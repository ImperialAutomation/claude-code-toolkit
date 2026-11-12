#!/usr/bin/env python3
"""Tests for bin/lib/release_guard.py, the hook's guard against an agent
merging or pushing into a protected branch, starting a workflow, or creating a
tag or release (#312).

Run: python3 bin/tests/test-release-guard.py

Every route of the issue is covered allowed AND blocked: a guard that only
asserts BLOCK cannot tell "guards the route" from "blocks everything".

The fixture is a real git repository (branches, a tag, config) and a fake `gh`
on PATH that answers the PR base lookups from a file, so nothing reaches
GitHub. Pushes are never executed: the guard only reads the command.
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent.parent
_spec = importlib.util.spec_from_file_location(
    "release_guard", REPO_DIR / "bin" / "lib" / "release_guard.py"
)
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)

# The fake gh: `pr view` and `api` print the base named in $FAKE_GH_DIR/base,
# or fail like gh does when that file is absent. Every call's arguments are
# appended to $FAKE_GH_DIR/calls.
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$FAKE_GH_DIR/calls"
if [ -f "$FAKE_GH_DIR/base" ]; then
    cat "$FAKE_GH_DIR/base"
    exit 0
fi
echo "GraphQL: Could not resolve to a PullRequest" >&2
exit 1
"""


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


class GuardTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "T")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "root")
        git(self.repo, "tag", "v1.2.3")
        git(self.repo, "branch", "epic-1")
        git(self.repo, "checkout", "-q", "-b", "issue-1-x")
        self.elsewhere = self.tmp / "elsewhere"
        self.elsewhere.mkdir()

        self.gh_dir = self.tmp / "gh"
        self.gh_dir.mkdir()
        (self.gh_dir / "gh").write_text(FAKE_GH)
        (self.gh_dir / "gh").chmod(0o755)
        self._env = {k: os.environ.get(k) for k in ("PATH", "FAKE_GH_DIR")}
        os.environ["PATH"] = f"{self.gh_dir}{os.pathsep}{os.environ['PATH']}"
        os.environ["FAKE_GH_DIR"] = str(self.gh_dir)

    def tearDown(self):
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        shutil.rmtree(self.tmp)

    def set_pr_base(self, base):
        (self.gh_dir / "base").write_text(base + "\n")

    def gh_calls(self):
        path = self.gh_dir / "calls"
        return path.read_text() if path.exists() else ""

    def on(self, branch):
        git(self.repo, "checkout", "-q", branch)

    def assertBlocked(self, command, cwd=None, contains=None):
        reason = guard.judge(command, str(cwd or self.repo))
        self.assertIsNotNone(reason, f"expected BLOCK: {command}")
        if contains:
            self.assertIn(contains.lower(), reason.lower())

    def assertAllowed(self, command, cwd=None):
        reason = guard.judge(command, str(cwd or self.repo))
        self.assertIsNone(reason, f"expected ALLOW: {command} (got: {reason})")


class PushToProtectedBranch(GuardTestCase):
    """Route 4: a push to a protected branch, explicit or implicit."""

    def test_feature_pushes_are_allowed(self):
        self.assertAllowed("git push -u origin issue-1-x")
        self.assertAllowed("git push origin HEAD")
        self.assertAllowed("git push origin HEAD:issue-1-x")
        self.assertAllowed("git push origin --delete issue-1-x")
        self.assertAllowed("git push -d origin issue-1-x")
        self.assertAllowed("git push origin :issue-1-x")

    def test_explicit_protected_targets_are_blocked(self):
        for spec in ("main", "HEAD:main", "+main", "refs/heads/main",
                     "issue-1-x:master", "develop", "HEAD:refs/heads/develop"):
            with self.subTest(spec=spec):
                self.assertBlocked(f"git push origin {spec}", contains="protected branch")
        self.assertBlocked("git push --force origin main")
        self.assertBlocked("git push -u origin main")

    def test_deleting_a_protected_branch_is_blocked(self):
        self.assertBlocked("git push origin --delete main")
        self.assertBlocked("git push origin :main")

    def test_per_repo_protected_branch(self):
        git(self.repo, "config", "--add", "toolkit.protectedBranch", "release")
        self.assertBlocked("git push origin release")
        self.assertBlocked("git push origin HEAD:release")
        (self.repo / ".claude").mkdir()
        (self.repo / ".claude" / "protected-branches").write_text("production\n")
        self.assertBlocked("git push origin production")

    def test_wildcard_refspec_is_blocked(self):
        self.assertBlocked("git push origin 'refs/heads/*:refs/heads/*'")

    def test_every_branch_at_once_is_blocked(self):
        self.assertBlocked("git push --all origin")
        self.assertBlocked("git push --mirror origin")
        self.assertBlocked("git push --branches origin")

    def test_implicit_target_on_a_feature_branch_is_allowed(self):
        self.assertAllowed("git push")
        self.assertAllowed("git push origin")
        git(self.repo, "config", "branch.issue-1-x.remote", "origin")
        git(self.repo, "config", "branch.issue-1-x.merge", "refs/heads/issue-1-x")
        self.assertAllowed("git push")

    def test_implicit_target_on_a_protected_branch_is_blocked(self):
        self.on("main")
        self.assertBlocked("git push")
        self.assertBlocked("git push origin")
        self.assertBlocked("git push -u origin HEAD")

    def test_implicit_target_resolved_through_upstream(self):
        git(self.repo, "config", "branch.issue-1-x.remote", "origin")
        git(self.repo, "config", "branch.issue-1-x.merge", "refs/heads/main")
        git(self.repo, "config", "push.default", "upstream")
        self.assertBlocked("git push")

    def test_unresolvable_implicit_targets_are_blocked(self):
        git(self.repo, "config", "push.default", "matching")
        self.assertBlocked("git push")
        git(self.repo, "config", "--unset", "push.default")
        git(self.repo, "config", "remote.origin.push", "refs/heads/*:refs/heads/*")
        self.assertBlocked("git push")
        git(self.repo, "config", "--unset", "remote.origin.push")
        git(self.repo, "checkout", "-q", "--detach")
        self.assertBlocked("git push")

    def test_push_default_nothing_pushes_nothing(self):
        self.on("main")
        self.assertAllowed("git -c push.default=nothing push")


class TagPush(GuardTestCase):
    """Route 7: every tag push."""

    def test_tag_pushes_are_blocked(self):
        for command in ("git push origin v1.2.3", "git push origin refs/tags/v1.2.3",
                        "git push origin v1.2.3:v1.2.3", "git push origin v1.2.3:refs/tags/v9",
                        "git push --tags", "git push origin --tags",
                        "git push --follow-tags origin issue-1-x"):
            with self.subTest(command=command):
                self.assertBlocked(command, contains="ask the user")

    def test_follow_tags_from_config(self):
        git(self.repo, "config", "push.followTags", "true")
        self.assertBlocked("git push origin issue-1-x")
        self.assertAllowed("git push --no-follow-tags origin issue-1-x")

    def test_deleting_a_tag_is_not_a_tag_push(self):
        self.assertAllowed("git push origin --delete v1.2.3")


class MergeOnProtectedBranch(GuardTestCase):
    """The existing `git merge` guard, now on the shared parser."""

    def test_merge_on_feature_is_allowed(self):
        self.assertAllowed("git merge epic-1")

    def test_merge_on_protected_is_blocked(self):
        self.on("main")
        self.assertBlocked("git merge issue-1-x", contains="'main'")
        self.assertBlocked("git merge --no-ff issue-1-x")

    def test_per_repo_protected(self):
        git(self.repo, "config", "--add", "toolkit.protectedBranch", "epic-1")
        self.on("epic-1")
        self.assertBlocked("git merge issue-1-x")

    def test_target_repo_is_the_one_git_C_names(self):
        self.on("main")
        self.assertBlocked(f"git -C {self.repo} merge issue-1-x", cwd=self.elsewhere)
        self.assertAllowed("git merge x", cwd=self.elsewhere)


class CommandForms(GuardTestCase):
    """Route 8: the forms a guard has to see through."""

    def test_forms_in_front_of_a_protected_push(self):
        repo = self.repo
        for command in (
            f"git -C {repo} push origin main",
            f"git -C {repo} -c core.x=y push origin main",
            f"env -C {repo} git push origin main",
            f"env --chdir={repo} git push origin main",
            f"env -u FOO git -C {repo} push origin main",
            f"env FOO=1 git -C {repo} push origin main",
            f"env -i git -C {repo} push origin main",
            f"FOO=1 git -C {repo} push origin main",
            f"cd {repo} && git push origin main",
            f"~/.claude/bin/cmd-save.sh /tmp/o.txt git -C {repo} push origin main",
            f"cmd-save.sh --stderr merge /tmp/o.txt git -C {repo} push origin main",
            f"~/.claude/bin/repeat-cmd.sh 1 git -C {repo} push origin main",
            f"~/.claude/bin/venv-run.sh git -C {repo} push origin main",
            f"~/.claude/bin/venv-run.sh --repo {repo} env -C {repo} git push origin main",
            f"rtk git -C {repo} push origin main",
            f"rtk proxy git -C {repo} push origin main",
            f"/usr/bin/git -C {repo} push origin main",
            f"git status && git -C {repo} push origin main",
        ):
            with self.subTest(command=command):
                self.assertBlocked(command, cwd=self.elsewhere)

    def test_implicit_target_follows_git_C_and_cd(self):
        self.on("main")
        self.assertBlocked(f"git -C {self.repo} push", cwd=self.elsewhere)
        self.assertBlocked(f"cd {self.repo} && git push", cwd=self.elsewhere)
        self.assertBlocked(f"env -C {self.repo} git push", cwd=self.elsewhere)

    def test_the_same_forms_on_a_feature_push_are_allowed(self):
        repo = self.repo
        self.assertAllowed(f"git -C {repo} push -u origin issue-1-x", cwd=self.elsewhere)
        self.assertAllowed(f"env -C {repo} git push origin issue-1-x", cwd=self.elsewhere)
        self.assertAllowed(f"~/.claude/bin/cmd-save.sh /tmp/o git -C {repo} push origin issue-1-x")

    def test_unresolvable_target_repo_is_blocked(self):
        self.assertBlocked('git -C "$WT" push origin issue-1-x', contains="cannot")
        self.assertBlocked(f"git -C {self.tmp}/nope push origin issue-1-x")
        self.assertBlocked(f"git --git-dir={self.repo}/.git push origin issue-1-x")

    def test_quoted_text_is_not_a_command(self):
        for command in (
            '~/.claude/bin/git-commit.sh "fix: block git push origin main"',
            'echo "git push origin main"',
            "grep -n 'gh workflow run' bin/x.sh",
            "echo pulls/1/merge",
            "printf '%s' 'gh release create v1'",
            "git log --grep 'git merge main'",
        ):
            with self.subTest(command=command):
                self.assertAllowed(command)

    def test_cd_decides_the_target_repo(self):
        # From a non-repo cwd only the cd can make these refusals: the merge
        # needs the repo's branch, the push the repo's own list.
        self.on("main")
        self.assertBlocked(f"cd {self.repo} && git merge issue-1-x", cwd=self.elsewhere)
        self.assertBlocked(f"(cd {self.repo} && git merge issue-1-x)", cwd=self.elsewhere)
        self.on("issue-1-x")
        git(self.repo, "config", "--add", "toolkit.protectedBranch", "release")
        self.assertBlocked(f"cd {self.repo} && git push origin release", cwd=self.elsewhere)
        self.assertAllowed("git push origin release", cwd=self.elsewhere)

    def test_shell_grouping_and_prefixes(self):
        for command in (
            "(git push origin main)",
            "{ git push origin main; }",
            "if true; then git push origin main; fi",
            "for b in x; do git push origin main; done",
            "! git push origin main",
            "git push origin main&",
            "timeout 60 git push origin main",
            "timeout -k 5 60 git push origin main",
            "nice -n 10 git push origin main",
            "stdbuf -oL git push origin main",
            "setsid git push origin main",
            "x=$(git push origin main)",
            "echo $(git push origin main)",
            "echo `git push origin main`",
            '~/.claude/bin/git-commit.sh "fix: $(gh workflow run deploy.yml)"',
        ):
            with self.subTest(command=command):
                self.assertBlocked(command)
        for command in (
            "(git push origin issue-1-x)",
            "timeout 60 git push origin issue-1-x",
            "x=$(git rev-parse HEAD)",
            "echo $(git branch --show-current)",
            "if git diff --quiet; then echo same; fi",
        ):
            with self.subTest(command=command):
                self.assertAllowed(command)

    def test_at_is_head(self):
        self.on("main")
        self.assertBlocked("git push origin @", contains="'main'")
        self.on("issue-1-x")
        self.assertAllowed("git push origin @")

    def test_shell_expansion_in_push_is_blocked(self):
        self.assertBlocked("B=main; git push origin $B", contains="shell expansion")
        self.assertBlocked('git push origin "$(echo main)"')
        self.assertBlocked('git push "$REMOTE" issue-1-x', contains="shell expansion")

    def test_wrapper_that_runs_nothing_is_allowed(self):
        self.assertAllowed("~/.claude/bin/cmd-save.sh --help")

    def test_unparseable_command_is_blocked(self):
        self.assertBlocked("git push origin 'main", contains="parse")

    def test_git_alias(self):
        self.assertBlocked("git -c alias.p=push p origin main")
        git(self.repo, "config", "alias.ship", "push origin main")
        self.assertBlocked("git ship")
        git(self.repo, "config", "alias.sh", "!git push origin main")
        self.assertBlocked("git sh")
        git(self.repo, "config", "alias.st", "status")
        self.assertAllowed("git st")


class GhPrMerge(GuardTestCase):
    """The existing `gh pr merge` guard, now on the shared parser."""

    def test_feature_base_is_allowed(self):
        self.set_pr_base("epic-1")
        self.assertAllowed("gh pr merge 5 --merge")

    def test_protected_base_is_blocked(self):
        self.set_pr_base("main")
        self.assertBlocked("gh pr merge 5 --merge", contains="'main'")
        self.assertBlocked("gh pr merge --auto --squash")

    def test_unresolvable_base_is_blocked(self):
        self.assertBlocked("gh pr merge 5", contains="could not resolve")

    def test_per_repo_protected_base(self):
        git(self.repo, "config", "--add", "toolkit.protectedBranch", "release")
        self.set_pr_base("release")
        self.assertBlocked("gh pr merge 5")

    def test_pr_ref_and_repo_flag_are_passed_to_the_lookup(self):
        self.set_pr_base("epic-1")
        self.assertAllowed("gh pr merge -R octo/repo --subject 'x y' 5")
        calls = self.gh_calls()
        self.assertIn("pr view 5", calls)
        self.assertIn("-R octo/repo", calls)

    def test_wrapped_forms(self):
        self.set_pr_base("main")
        self.assertBlocked("~/.claude/bin/cmd-save.sh /tmp/o gh pr merge 5")
        self.assertBlocked(f"env -C {self.repo} gh pr merge 5", cwd=self.elsewhere)
        self.assertBlocked("rtk gh pr merge 5")


class Workflows(GuardTestCase):
    """Route 3 (D1: every workflow) and reruns (D11)."""

    def test_workflow_run_is_blocked(self):
        self.assertBlocked("gh workflow run deploy-production.yml", contains="ask the user")
        self.assertBlocked("gh workflow run tests.yml -f x=y")
        self.assertBlocked("~/.claude/bin/repeat-cmd.sh 1 gh workflow run x.yml")

    def test_rerun_is_blocked(self):
        self.assertBlocked("gh run rerun 123")

    def test_reading_workflows_is_allowed(self):
        self.assertAllowed("gh workflow list")
        self.assertAllowed("gh workflow view deploy.yml")
        self.assertAllowed("gh run list")
        self.assertAllowed("gh run view 123 --log-failed")


class Releases(GuardTestCase):
    """Route 6: gh release create, and publishing a draft (D11)."""

    def test_release_create_is_blocked(self):
        self.assertBlocked("gh release create v1.2.4 --generate-notes", contains="ask the user")

    def test_publishing_a_draft_is_blocked(self):
        self.assertBlocked("gh release edit v1 --draft=false")
        self.assertBlocked("gh release edit v1 --draft false")

    def test_reading_releases_is_allowed(self):
        self.assertAllowed("gh release list")
        self.assertAllowed("gh release view v1")
        self.assertAllowed("gh release edit v1 --notes x")


class GhApi(GuardTestCase):
    """Routes 2, 3 and 6 through the REST and GraphQL APIs."""

    def test_pr_merge_endpoint(self):
        self.set_pr_base("main")
        for command in (
            "gh api -X PUT repos/o/r/pulls/1/merge",
            "gh api --method PUT repos/o/r/pulls/1/merge",
            "gh api --method=PUT /repos/o/r/pulls/1/merge",
            "gh api -XPUT repos/{owner}/{repo}/pulls/1/merge",
            "gh api https://api.github.com/repos/o/r/pulls/1/merge -X PUT",
            "gh api repos/o/r/pulls/1/merge -f merge_method=squash",
        ):
            with self.subTest(command=command):
                self.assertBlocked(command)
        self.assertIn("repos/o/r/pulls/1", self.gh_calls())

    def test_pr_merge_endpoint_feature_base_and_reads(self):
        self.set_pr_base("epic-1")
        self.assertAllowed("gh api -X PUT repos/o/r/pulls/1/merge")
        self.assertAllowed("gh api repos/o/r/pulls/1/merge")
        self.assertAllowed("gh api repos/o/r/pulls/1")

    def test_pr_merge_endpoint_unresolvable_base(self):
        self.assertBlocked("gh api -X PUT repos/o/r/pulls/1/merge", contains="could not resolve")

    def test_dispatches_are_blocked(self):
        self.assertBlocked("gh api -X POST repos/o/r/actions/workflows/deploy.yml/dispatches -f ref=main")
        self.assertBlocked("gh api repos/o/r/actions/workflows/123/dispatches -f ref=main")
        self.assertBlocked("gh api repos/{owner}/{repo}/dispatches -f event_type=deploy")
        self.assertBlocked("gh api -X POST repos/o/r/actions/runs/1/rerun")

    def test_release_and_ref_creation_are_blocked(self):
        self.assertBlocked("gh api repos/o/r/releases -f tag_name=v1")
        self.assertBlocked("gh api -X PATCH repos/o/r/releases/9 -F draft=false")
        self.assertBlocked("gh api repos/o/r/git/refs -f ref=refs/tags/v1 -f sha=abc")
        self.assertBlocked("gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc")

    def test_other_writes_to_a_branch_are_blocked(self):
        self.assertBlocked("gh api -X PUT repos/o/r/contents/README.md -f message=x")
        self.assertBlocked("gh api repos/o/r/merges -f base=main -f head=x")

    def test_reads_are_allowed(self):
        self.assertAllowed("gh api repos/o/r/releases")
        self.assertAllowed("gh api repos/o/r/git/refs/heads/main")
        self.assertAllowed("gh api repos/o/r/contents/README.md")
        self.assertAllowed("gh api repos/o/r/actions/workflows")
        self.assertAllowed("gh api repos/o/r/pulls/1/comments -f body=hi")
        self.assertAllowed("gh api -X POST repos/o/r/issues/1/comments -f body=x")

    def test_graphql_mutations(self):
        self.assertBlocked(
            "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'")
        self.assertBlocked("gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {}) { x } }'")
        self.assertBlocked("gh api graphql -f query='mutation { createRef(input: {}) { x } }'")
        self.assertAllowed("gh api graphql -f query='query { viewer { login } }'")
        self.assertAllowed("gh api graphql -f query='mutation { addComment(input: {}) { x } }'")

    def test_graphql_query_from_a_file(self):
        (self.repo / "m.graphql").write_text("mutation { mergeBranch(input: {}) { x } }")
        (self.repo / "q.graphql").write_text("query { viewer { login } }")
        self.assertBlocked("gh api graphql -F query=@m.graphql")
        self.assertAllowed("gh api graphql -F query=@q.graphql")
        self.assertBlocked("gh api graphql -F query=@missing.graphql", contains="cannot")
        self.assertBlocked("gh api graphql --input body.json")


if __name__ == "__main__":
    unittest.main()
