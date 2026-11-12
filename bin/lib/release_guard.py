#!/usr/bin/env python3
"""Refuse the Bash commands that would let an agent release (#312).

Used by hook-block-destructive.sh. An agent acts on GitHub as the human's own
account, so no server-side setting can tell the two apart: this hook is the
only layer that can. Releases are the human's act.

Usage:
    release_guard.py <cwd>        (the Bash command on stdin)

Exit status:
    0   allowed
    10  refused; the reason is printed on stdout
    any other: the guard itself failed, which the hook turns into a refusal

What is refused, for every segment of the command:
    git merge          while the target repo is on a protected branch
    git push           to a protected branch (<b>, HEAD:<b>, +<b>,
                       refs/heads/<b>, :<b>, --delete <b>), to every branch
                       (--all, --branches, --mirror, a wildcard refspec), or
                       without a refspec when the target it resolves to is
                       protected or cannot be resolved; and every tag push
                       (refs/tags/..., a local tag as source, --tags,
                       --follow-tags, push.followTags=true)
    gh pr merge        when the PR's base is protected or cannot be resolved
    gh workflow run    every one (D1), and gh run rerun
    gh release create  and gh release edit --draft=false
    gh api             a write to pulls/<n>/merge with a protected or
                       unresolvable base; any write to .../merges,
                       .../contents/..., .../git/refs..., .../releases...,
                       .../dispatches or .../actions/runs/<id>/rerun...;
                       a GraphQL mutation that merges, or creates or moves a
                       ref
    git <alias>        an alias that expands to any of the above

Protected = develop, master, main, plus the target repo's own list
(bin/lib/protected-branches.sh). The target repo is the one `git -C`,
`env -C` or a preceding `cd` points at, else <cwd>.

A segment is judged after removing what runs a command without being it:
VAR=value assignments, `env` and its options, `rtk` / `rtk proxy`, `time`,
`nohup`, `command`, `exec`, `sudo`, `timeout`, `nice`, `ionice`, `stdbuf`,
`setsid`, the shell's own leaders (`(`, `{`, `!`, `if`, `then`, `else`,
`elif`, `do`, `while`, `until`), and the command-running wrappers
cmd-save.sh, repeat-cmd.sh, venv-run.sh and gh-app-token.sh. The body of a
command substitution, `$(...)` or backticks, is judged as a command of its
own. Quoted text is an argument, never a command: `echo "git push origin
main"` is an echo. A push whose remote or refspec is a shell expansion
(`$B`) is refused: its target cannot be read from the text.

Out of reach, as for the rest of the hook: a command run by another
interpreter (`bash -c`, `eval`, `xargs`, `ssh`), and gh aliases.
"""

import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

_LIB_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_LIB_DIR))
import commit_target  # noqa: E402  (shares the approve hook's command parsing)

_hook = commit_target._hook
Unresolvable = commit_target.Unresolvable

EXIT_ALLOWED = 0
EXIT_REFUSED = 10

PROTECTED_BRANCHES_SCRIPT = _LIB_DIR / "protected-branches.sh"
# What protected-branches.sh always includes; used alone when no repository
# can be read.
FIXED_PROTECTED = ("develop", "master", "main")
SUBPROCESS_TIMEOUT = 20

GIT = "git"
GH = "gh"
ENV = _hook.ENV_COMMAND
RTK = _hook.RTK_PREFIX
# Prefixes that run the rest of the segment as the command.
PLAIN_PREFIXES = {"time", "nohup", "command", "exec", "sudo"}
# Prefixes that take options first, mapped to the options that take a separate
# value; `timeout` also takes a duration before the command.
OPTION_PREFIXES = {
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "--class", "-n", "--classdata", "-p", "--pid", "-P", "--pgid", "-u", "--uid"},
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
    "setsid": set(),
}
TIMEOUT = "timeout"
# Shell words that start a compound command or negate one; what follows them
# in the segment is the command.
SHELL_LEADERS = {"!", "{", "(", "if", "then", "else", "elif", "do", "while", "until"}
# Grouping characters glued to the first or last word: `(git ...)`, `main&`.
LEADING_GROUP_CHARS = "({!"
TRAILING_GROUP_CHARS = ")&"
# The body of a command substitution, innermost first.
SUBSTITUTION_RES = (re.compile(r"\$\(([^()]*)\)"), re.compile(r"`([^`]*)`"))
SHELL_EXPANSION_CHARS = ("$", "`")
ENV_SPLIT_OPTION = ("-S", "--split-string")
END_OF_OPTIONS = "--"

HEADS_PREFIX = "refs/heads/"
TAGS_PREFIX = "refs/tags/"
REFS_PREFIX = "refs/"
HEAD = "HEAD"
# `@` alone is git's shorthand for HEAD, in a refspec too.
HEAD_NAMES = (HEAD, "@")
WILDCARD = "*"

# git push options that take the next argument as their value.
PUSH_VALUE_OPTIONS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}
PUSH_TAG_OPTIONS = ("--tags", "--follow-tags")
PUSH_NO_FOLLOW_TAGS = "--no-follow-tags"
PUSH_EVERY_BRANCH_OPTIONS = ("--all", "--branches", "--mirror")
PUSH_DELETE_OPTION = "--delete"
PUSH_DELETE_SHORT = "d"
PUSH_DEFAULT_KEY = "push.default"
PUSH_DEFAULT_FALLBACK = "simple"
PUSH_FOLLOW_TAGS_KEY = "push.followtags"
GIT_TRUE = {"true", "yes", "on", "1"}
DEFAULT_REMOTE = "origin"

# How many alias expansions to follow; git itself refuses a loop.
MAX_ALIAS_DEPTH = 10
ALIAS_SHELL_MARKER = "!"
ALIAS_SHELL_DANGER_RE = re.compile(r"\b(push|merge)\b")

# gh pr merge options that take the next argument as their value.
GH_PR_MERGE_VALUE_OPTIONS = {
    "-t", "--subject", "-b", "--body", "-F", "--body-file",
    "-A", "--author-email", "--match-head-commit", "-R", "--repo",
}
GH_REPO_OPTIONS = ("-R", "--repo")
GH_DRAFT_OPTION = "--draft"
GH_FALSE = "false"

# gh api.
GH_API_METHOD_OPTIONS = ("-X", "--method")
GH_API_FIELD_OPTIONS = ("-f", "--raw-field", "-F", "--field")
GH_API_INPUT_OPTION = "--input"
GH_API_VALUE_OPTIONS = {
    "-H", "--header", "-q", "--jq", "-t", "--template", "--cache",
    "-p", "--preview", "--hostname",
}
GH_API_READ_METHODS = {"GET", "HEAD"}
GH_API_HOST_RE = re.compile(r"^https?://[^/]+/(api/v3/)?")
GH_API_PR_MERGE_RE = re.compile(r"(^|/)pulls/\d+/merge$")
GH_API_WRITE_REFUSALS = (
    (re.compile(r"(^|/)actions/workflows/[^/]+/dispatches$"),
     "starts a workflow (workflow_dispatch)", True),
    (re.compile(r"^repos/[^/]+/[^/]+/dispatches$"),
     "starts workflows (repository_dispatch)", True),
    (re.compile(r"(^|/)actions/runs/\d+/rerun"),
     "re-runs a workflow run", True),
    (re.compile(r"(^|/)releases(/|$)"),
     "creates or changes a release", True),
    (re.compile(r"(^|/)git/refs(/|$)"),
     "creates or moves a ref (a branch or a tag)", True),
    (re.compile(r"(^|/)merges$"),
     "merges a branch through the API", False),
    (re.compile(r"(^|/)contents/"),
     "commits a file straight to a branch", False),
)
GH_GRAPHQL_ENDPOINT = "graphql"
GH_GRAPHQL_QUERY_FIELD = "query"
GH_GRAPHQL_DANGER_RE = re.compile(
    r"\b(mergePullRequest|enablePullRequestAutoMerge|mergeBranch|createRef|"
    r"updateRef|updateRefs|createCommitOnBranch)\b"
)
FILE_VALUE_MARKER = "@"

ASK_USER = "Ask the user to do this themselves; do not look for another route."
PROTECTED_HINT = (
    "Changes reach a protected branch only through a PR the user merges. "
    "Open the PR (git-push-pr-merge.sh --no-merge) and leave the merge to them."
)


class Refusal(Exception):
    """A command the guard refuses; the message is the reason."""


# --- helpers --------------------------------------------------------------------


def _run(args, cwd):
    """stdout of `args` run in `cwd`, stripped, or None when it fails."""
    try:
        result = subprocess.run(
            args, cwd=cwd, capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def _protected(repo):
    """The protected branch names of `repo` (a directory, or an Unresolvable)."""
    if isinstance(repo, Unresolvable):
        return set(FIXED_PROTECTED)
    output = _run(["bash", str(PROTECTED_BRANCHES_SCRIPT), repo], repo)
    if output is None:
        raise Refusal(f"cannot read the protected-branch list of {repo}.")
    return set(output.split())


def _join(cwd, parts):
    """`cwd` moved by `parts` (as `git -C` does), or the Unresolvable why not."""
    if isinstance(cwd, Unresolvable):
        return cwd
    if not parts:
        return cwd
    try:
        return commit_target._resolve_dir(parts, cwd)
    except Unresolvable as exc:
        return exc


def _require_repo(repo, what):
    if isinstance(repo, Unresolvable):
        raise Refusal(f"{what}: cannot tell which repository it acts on ({repo}), so cannot check its branch.")
    return repo


def _is_long(arg, option):
    return commit_target._is_long_option(arg, option)


# --- prefixes -------------------------------------------------------------------


def _strip_env(args, cwd):
    """The command after an `env` invocation's arguments, and the cwd its
    -C/--chdir options leave. Unknown options are skipped, never trusted to
    end the prefix: an `env -i git push` is still a git push."""
    index = 0
    while index < len(args):
        arg = args[index]
        if _hook.ENV_ASSIGNMENT_RE.match(arg):
            index += 1
            continue
        chdir = _hook._env_option_value(args, index, _hook.ENV_CHDIR_OPTION)
        if chdir is not None:
            cwd = _join(cwd, [chdir[0]])
            index += chdir[1]
            continue
        split = _hook._env_option_value(args, index, ENV_SPLIT_OPTION)
        if split is not None:
            return shlex.split(split[0]) + args[index + split[1]:], cwd
        unset = _hook._env_option_value(args, index, _hook.ENV_UNSET_OPTION)
        if unset is not None:
            index += unset[1]
            continue
        if arg == END_OF_OPTIONS:
            index += 1
            break
        if arg.startswith("-"):
            index += 1
            continue
        break
    return args[index:], cwd


def _strip_option_prefix(name, args):
    """`args` after the options (and a timeout's duration) of prefix `name`."""
    value_options = OPTION_PREFIXES[name]
    index = 0
    while index < len(args) and args[index].startswith("-"):
        if args[index] == END_OF_OPTIONS:
            index += 1
            break
        index += 2 if args[index] in value_options else 1
    if name == TIMEOUT and index < len(args):
        index += 1
    return args[index:]


def _strip_grouping(tokens):
    """`tokens` without the subshell/brace characters glued to the first and
    last word: `(git push origin main)` is a git push."""
    tokens = list(tokens)
    if tokens:
        tokens[-1] = tokens[-1].rstrip(TRAILING_GROUP_CHARS) or tokens[-1]
    while tokens and tokens[0][:1] in tuple(LEADING_GROUP_CHARS) and tokens[0] not in SHELL_LEADERS:
        stripped = tokens[0].lstrip(LEADING_GROUP_CHARS)
        tokens = ([stripped] if stripped else []) + tokens[1:]
    return tokens


def _unwrap(tokens, cwd):
    """The command a segment runs and its cwd, or (None, cwd) when a wrapper
    in front runs nothing (a malformed call or its --help)."""
    tokens = _strip_grouping(tokens)
    while tokens:
        first = tokens[0]
        name = os.path.basename(first)
        if first in SHELL_LEADERS:
            tokens = _strip_grouping(tokens[1:])
        elif first in OPTION_PREFIXES:
            tokens = _strip_option_prefix(first, tokens[1:])
        elif _hook.ENV_ASSIGNMENT_RE.match(first):
            tokens = tokens[1:]
        elif first == ENV:
            tokens, cwd = _strip_env(tokens[1:], cwd)
        elif first == RTK:
            tokens = _hook.strip_rtk_prefix(tokens)
        elif first in PLAIN_PREFIXES:
            tokens = tokens[1:]
        elif name in _hook.COMMAND_RUNNING_WRAPPERS:
            tokens = _hook.COMMAND_RUNNING_WRAPPERS[name].parse(tokens[1:])
            if tokens is None:
                return None, cwd
        else:
            break
    return tokens, cwd


# --- git ------------------------------------------------------------------------


def _git_config_overrides(tokens):
    """The `-c key=value` options of a git invocation, keys lowercased."""
    overrides = {}
    index = 1
    while index < len(tokens) and tokens[index].startswith("-"):
        token = tokens[index]
        if token == "-c" and index + 1 < len(tokens):
            key, assigned, value = tokens[index + 1].partition("=")
            overrides[key.lower()] = value if assigned else "true"
        index += 2 if token in commit_target.GIT_VALUE_OPTIONS else 1
    return overrides


def _git_config(repo, key, overrides):
    """The value of git config `key` in `repo`, -c overrides first, or None."""
    if key.lower() in overrides:
        return overrides[key.lower()]
    if isinstance(repo, Unresolvable):
        return _run(["git", "config", "--global", "--get", key], None)
    return _run(["git", "-C", repo, "config", "--get", key], repo)


def _current_branch(repo):
    return _run(["git", "-C", repo, "symbolic-ref", "--short", "-q", "HEAD"], repo) or None


def _ref_exists(repo, ref):
    return _run(["git", "-C", repo, "show-ref", "--verify", "--quiet", ref], repo) is not None


def _expand_alias(subcommand, args, repo, overrides):
    """(subcommand, args) after expanding git aliases."""
    for _ in range(MAX_ALIAS_DEPTH):
        alias = _git_config(repo, f"alias.{subcommand}", overrides)
        if not alias:
            return subcommand, args
        if alias.startswith(ALIAS_SHELL_MARKER):
            if ALIAS_SHELL_DANGER_RE.search(alias):
                raise Refusal(f"git alias '{subcommand}' runs a shell command that pushes or merges ({alias}). {ASK_USER}")
            return None, []
        try:
            expanded = shlex.split(alias)
        except ValueError:
            raise Refusal(f"git alias '{subcommand}' cannot be parsed ({alias}).")
        if not expanded:
            return subcommand, args
        subcommand, args = expanded[0], expanded[1:] + args
    return subcommand, args


def _judge_git(tokens, cwd):
    parsed = commit_target._git_invocation(tokens)
    if not parsed:
        return
    subcommand, dirs, override, args = parsed
    if subcommand is None:
        return
    repo = _join(cwd, dirs)
    if override:
        repo = Unresolvable(f"git {override} sets the repository")
    overrides = _git_config_overrides(tokens)
    subcommand, args = _expand_alias(subcommand, args, repo, overrides)
    if subcommand == commit_target.MERGE_SUBCOMMAND:
        _judge_merge(repo)
    elif subcommand == commit_target.PUSH_SUBCOMMAND:
        _judge_push(repo, args, overrides)


def _judge_merge(repo):
    repo = _require_repo(repo, "git merge")
    branch = _current_branch(repo)
    if branch and branch in _protected(repo):
        raise Refusal(
            f"refusing 'git merge' while {repo} is on protected branch '{branch}'. "
            "Merges into a protected branch go through a PR the user merges. To sync the "
            "other way, check out the feature branch first (git-merge-branch.sh does this)."
        )


def _parse_push_args(args):
    """(long options, short flags, positional arguments) of `git push`."""
    longs, shorts, positional = [], set(), []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == END_OF_OPTIONS:
            positional.extend(args[index + 1:])
            break
        if arg in PUSH_VALUE_OPTIONS:
            index += 2
            continue
        if arg.startswith("--"):
            longs.append(arg)
        elif arg.startswith("-") and len(arg) > 1:
            shorts.update(arg[1:])
        else:
            positional.append(arg)
        index += 1
    return longs, shorts, positional


def _refuse_tag_push(detail):
    raise Refusal(
        f"refusing a tag push ({detail}). A tag starts the release workflows; "
        f"tagging is the user's act. {ASK_USER}"
    )


def _refuse_protected_push(branch, repo):
    raise Refusal(
        f"refusing 'git push' to protected branch '{branch}' of {repo}. {PROTECTED_HINT}"
    )


def _branch_of(dst, repo):
    """The branch name a push destination names, or None for a ref that is
    neither a branch nor a tag (refs/notes/..., say)."""
    if dst.startswith(TAGS_PREFIX):
        _refuse_tag_push(dst)
    if dst.startswith(HEADS_PREFIX):
        return dst[len(HEADS_PREFIX):]
    if dst.startswith(REFS_PREFIX):
        return None
    if dst in HEAD_NAMES:
        current = _current_branch(repo)
        if not current:
            raise Refusal(f"'git push ... HEAD' from a detached HEAD in {repo}: cannot tell which branch it updates.")
        return current
    return dst


def _is_local_tag(name, repo):
    if name.startswith(TAGS_PREFIX):
        return True
    if name.startswith(REFS_PREFIX) or name in HEAD_NAMES:
        return False
    return _ref_exists(repo, TAGS_PREFIX + name) and not _ref_exists(repo, HEADS_PREFIX + name)


def _judge_refspec(spec, repo, protected, deleting):
    if deleting:
        branch = spec[len(HEADS_PREFIX):] if spec.startswith(HEADS_PREFIX) else spec
        if branch in protected:
            _refuse_protected_push(branch, repo)
        return
    spec = spec.lstrip("+")
    src, colon, dst = spec.partition(":")
    if not colon:
        dst = src
    if WILDCARD in spec:
        raise Refusal(f"refusing 'git push' with the wildcard refspec '{spec}': it can update a protected branch. {PROTECTED_HINT}")
    if src and not dst.startswith(REFS_PREFIX) and _is_local_tag(src, repo):
        _refuse_tag_push(f"'{src}' is a tag")
    branch = _branch_of(dst, repo)
    if branch is not None and branch in protected:
        _refuse_protected_push(branch, repo)


def _implicit_push_target(repo, remote, overrides):
    """The branch a `git push [<remote>]` without refspec updates, or None
    when push.default is `nothing`. Refuses what it cannot resolve."""
    current = _current_branch(repo)
    if not current:
        raise Refusal(f"'git push' without a refspec from a detached HEAD in {repo}: cannot tell what it pushes.")
    if remote is None:
        remote = (_git_config(repo, f"branch.{current}.pushRemote", overrides)
                  or _git_config(repo, "remote.pushDefault", overrides)
                  or _git_config(repo, f"branch.{current}.remote", overrides)
                  or DEFAULT_REMOTE)
    if _git_config(repo, f"remote.{remote}.push", overrides):
        raise Refusal(f"'git push' without a refspec while remote.{remote}.push is configured: its target is not resolved here. Name the branch explicitly.")
    mode = (_git_config(repo, PUSH_DEFAULT_KEY, overrides) or PUSH_DEFAULT_FALLBACK).lower()
    if mode == "nothing":
        return None
    if mode == "current":
        return [current]
    if mode in ("simple", "upstream", "tracking"):
        merge = _git_config(repo, f"branch.{current}.merge", overrides)
        target = merge[len(HEADS_PREFIX):] if merge and merge.startswith(HEADS_PREFIX) else current
        return [current, target]
    raise Refusal(f"'git push' without a refspec under push.default={mode}: it can push every matching branch. Name the branch explicitly.")


def _judge_push(repo, args, overrides):
    repo = _require_repo(repo, "git push")
    longs, shorts, positional = _parse_push_args(args)
    for option in PUSH_TAG_OPTIONS:
        if any(_is_long(arg, option) for arg in longs):
            _refuse_tag_push(option)
    follow = (_git_config(repo, PUSH_FOLLOW_TAGS_KEY, overrides) or "").lower()
    if follow in GIT_TRUE and PUSH_NO_FOLLOW_TAGS not in longs:
        _refuse_tag_push("push.followTags is set; pass --no-follow-tags")
    for option in PUSH_EVERY_BRANCH_OPTIONS:
        if any(_is_long(arg, option) for arg in longs):
            raise Refusal(f"refusing 'git push {option}': it pushes every branch, protected ones included. {PROTECTED_HINT}")

    expanded = [arg for arg in positional if any(char in arg for char in SHELL_EXPANSION_CHARS)]
    if expanded:
        raise Refusal(f"'git push' with a shell expansion as remote or refspec ({expanded[0]}): its target cannot be read from the command. Name the remote and branch literally.")

    protected = _protected(repo)
    deleting = PUSH_DELETE_SHORT in shorts or any(_is_long(arg, PUSH_DELETE_OPTION) for arg in longs)
    remote, refspecs = (positional[0], positional[1:]) if positional else (None, [])
    if refspecs:
        for spec in refspecs:
            _judge_refspec(spec, repo, protected, deleting)
        return
    for branch in _implicit_push_target(repo, remote, overrides) or []:
        if branch in protected:
            _refuse_protected_push(branch, repo)


# --- gh -------------------------------------------------------------------------


def _option_value(args, index, options):
    """(value, tokens consumed) when args[index] is one of `options` in any
    spelling (-X v, -Xv, --long v, --long=v), else None."""
    arg = args[index]
    for option in options:
        if arg == option:
            return (args[index + 1] if index + 1 < len(args) else ""), 2
        if option.startswith("--") and arg.startswith(option + "="):
            return arg[len(option) + 1:], 1
        if not option.startswith("--") and arg.startswith(option) and not arg.startswith("--"):
            return arg[len(option):], 1
    return None


def _refuse_protected_merge(base, what):
    raise Refusal(f"refusing {what} into protected base branch '{base}'. {PROTECTED_HINT}")


def _require_cwd(cwd, what):
    if isinstance(cwd, Unresolvable):
        raise Refusal(f"{what}: cannot tell which directory it runs in ({cwd}), so cannot resolve the PR's base.")
    return cwd


def _judge_gh_pr_merge(args, cwd):
    pr_ref, repo_flag = None, []
    index = 0
    while index < len(args):
        arg = args[index]
        repo = _option_value(args, index, GH_REPO_OPTIONS)
        if repo is not None:
            repo_flag = ["-R", repo[0]]
            index += repo[1]
        elif arg in GH_PR_MERGE_VALUE_OPTIONS:
            index += 2
        elif arg.startswith("-"):
            index += 1
        else:
            pr_ref = pr_ref or arg
            index += 1
    cwd = _require_cwd(cwd, "'gh pr merge'")
    base = _run([GH, "pr", "view", *([pr_ref] if pr_ref else []), *repo_flag,
                 "--json", "baseRefName", "--jq", ".baseRefName"], cwd)
    if not base:
        raise Refusal("refusing 'gh pr merge': could not resolve the PR's base branch to verify it is not protected. Ask the user to merge it.")
    if base in _protected(cwd):
        _refuse_protected_merge(base, "'gh pr merge'")


def _gh_api_request(args):
    """(endpoint, method, fields as (name, value, is_typed), has --input)."""
    endpoint, method, fields, has_input = None, None, [], False
    index = 0
    while index < len(args):
        arg = args[index]
        value = _option_value(args, index, GH_API_METHOD_OPTIONS)
        if value is not None:
            method = value[0].upper()
            index += value[1]
            continue
        field = _option_value(args, index, GH_API_FIELD_OPTIONS)
        if field is not None:
            name, _, field_value = field[0].partition("=")
            fields.append((name, field_value, arg.startswith(("-F", "--field"))))
            index += field[1]
            continue
        value = _option_value(args, index, (GH_API_INPUT_OPTION,))
        if value is not None:
            has_input = True
            index += value[1]
            continue
        if arg in GH_API_VALUE_OPTIONS:
            index += 2
        elif arg.startswith("-"):
            index += 1
        else:
            endpoint = endpoint or arg
            index += 1
    if method is None:
        method = "POST" if fields or has_input else "GET"
    endpoint = GH_API_HOST_RE.sub("", endpoint or "").lstrip("/").split("?", 1)[0]
    return endpoint, method, fields, has_input


def _graphql_query(fields, has_input, cwd):
    if has_input:
        raise Refusal("'gh api graphql --input': cannot read the query to check it for a merge or ref mutation.")
    texts = []
    for name, value, typed in fields:
        if name != GH_GRAPHQL_QUERY_FIELD:
            continue
        if typed and value.startswith(FILE_VALUE_MARKER):
            path = Path(value[1:])
            if not path.is_absolute() and not isinstance(cwd, Unresolvable):
                path = Path(cwd) / path
            try:
                value = path.read_text()
            except OSError:
                raise Refusal(f"'gh api graphql': cannot read the query file {path} to check it for a merge or ref mutation.")
        texts.append(value)
    return "\n".join(texts)


def _judge_gh_api(args, cwd):
    endpoint, method, fields, has_input = _gh_api_request(args)
    if endpoint == GH_GRAPHQL_ENDPOINT:
        match = GH_GRAPHQL_DANGER_RE.search(_graphql_query(fields, has_input, cwd))
        if match:
            raise Refusal(f"refusing the GraphQL mutation {match.group(1)}: it merges, or creates or moves a ref. {ASK_USER}")
        return
    if method in GH_API_READ_METHODS:
        return
    if GH_API_PR_MERGE_RE.search(endpoint):
        cwd = _require_cwd(cwd, "'gh api' PR merge")
        base = _run([GH, "api", endpoint[:-len("/merge")], "--jq", ".base.ref"], cwd)
        if not base:
            raise Refusal(f"refusing 'gh api {method} {endpoint}': could not resolve the PR's base branch to verify it is not protected. Ask the user to merge it.")
        if base in _protected(cwd):
            _refuse_protected_merge(base, f"'gh api {method} {endpoint}'")
        return
    for pattern, effect, ask_user in GH_API_WRITE_REFUSALS:
        if pattern.search(endpoint):
            hint = ASK_USER if ask_user else PROTECTED_HINT
            raise Refusal(f"refusing 'gh api {method} {endpoint}': it {effect}. {hint}")


def _judge_gh(tokens, cwd):
    args = tokens[1:]
    command = tuple(args[:2])
    if command == ("pr", "merge"):
        _judge_gh_pr_merge(args[2:], cwd)
    elif command == ("workflow", "run"):
        raise Refusal(f"refusing 'gh workflow run': starting a workflow is the user's act (#312, D1). {ASK_USER}")
    elif command == ("run", "rerun"):
        raise Refusal(f"refusing 'gh run rerun': re-running a workflow starts it again. {ASK_USER}")
    elif command == ("release", "create"):
        raise Refusal(f"refusing 'gh release create': a release creates a tag and starts the release workflows. {ASK_USER}")
    elif command == ("release", "edit") and _publishes_draft(args[2:]):
        raise Refusal(f"refusing 'gh release edit --draft=false': publishing a release starts the release workflows. {ASK_USER}")
    elif args[:1] == ["api"]:
        _judge_gh_api(args[1:], cwd)


def _publishes_draft(args):
    for index, arg in enumerate(args):
        if arg == f"{GH_DRAFT_OPTION}={GH_FALSE}":
            return True
        if arg == GH_DRAFT_OPTION and args[index + 1:index + 2] == [GH_FALSE]:
            return True
    return False


# --- entry ----------------------------------------------------------------------


def _judge_segment(tokens, cwd):
    tokens, cwd = _unwrap(tokens, cwd)
    if not tokens:
        return
    name = os.path.basename(tokens[0])
    if name == GIT:
        _judge_git(tokens, cwd)
    elif name == GH:
        _judge_gh(tokens, cwd)


def judge(command, cwd):
    """The reason `command`, run in `cwd`, is refused, or None when allowed."""
    # A substitution runs its body wherever it sits, even inside double quotes
    # or as an argument of a read-only command. Judged against the starting cwd;
    # a body is strictly shorter than the command, so this ends.
    for pattern in SUBSTITUTION_RES:
        for body in pattern.findall(command):
            reason = judge(body, cwd)
            if reason is not None:
                return reason
    try:
        segments = _hook.split_segments(command)
    except ValueError as exc:
        return f"could not parse the command ({exc}), so cannot check it for a push, merge or release. Rephrase it."
    try:
        for segment in segments:
            segment = _strip_grouping(segment)
            while segment and segment[0] in SHELL_LEADERS:
                segment = _strip_grouping(segment[1:])
            if not segment:
                continue
            if segment[0] == commit_target.CD:
                try:
                    if isinstance(cwd, Unresolvable):
                        continue
                    cwd = commit_target._cd_target(segment, cwd)
                except Unresolvable as exc:
                    cwd = exc
                continue
            _judge_segment(segment, cwd)
    except Refusal as refusal:
        return str(refusal)
    return None


def main():
    cwd = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else os.getcwd()
    reason = judge(sys.stdin.read(), cwd)
    if reason is None:
        return EXIT_ALLOWED
    print(reason)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main())
