#!/usr/bin/env python3
"""Resolve which repository a Bash command committed to.

Used by hook-post-commit-trailer.sh, which amends HEAD of the repository this
returns. Getting the target wrong does not merely skip the trailer: it can
amend a fresh commit of another session working in the cwd's tree. So every
answer here is either the commit's own target or a refusal with a reason,
never a guess.

Usage:
    commit_target.py <cwd>        (the Bash command on stdin)

Output and exit status:
    0  line 1: the target directory (absolute)
       line 2: "push" if a `git push` segment follows the commit, else empty
    1  the command contains no commit segment; nothing printed
    2  a commit segment exists but its target cannot be resolved; the reason
       is printed on stderr

Resolution, per commit segment, first match wins:
    1. git-commit.sh --repo <dir> / --repo=<dir> (the last one, as the script
       itself applies them)
    2. the -C options of the `git ... commit` segment itself (cumulative, as
       git applies them)
    3. the cwd
Relative paths resolve against the cwd and a leading `~` against $HOME. Never
taken from another segment of the chain: `git -C <A> add && git-commit.sh
--repo <B>` commits in B.

Unresolvable: a target containing `$` or a backtick (no expansion of command
text here), a directory that does not exist, a git segment using --git-dir or
--work-tree, several commit segments with different targets, or a command that
does not tokenize.
"""

import importlib.util
import os
import sys
from pathlib import Path

# Shared with the approve hook so both read a command the same way (quotes,
# separators, cd/env/rtk prefixes).
_HOOK_PATH = Path(__file__).parent.parent / "hook-auto-approve-bash.py"
_spec = importlib.util.spec_from_file_location("hook_auto_approve_bash", _HOOK_PATH)
_hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_hook)

EXIT_RESOLVED = 0
EXIT_NO_COMMIT = 1
EXIT_UNRESOLVABLE = 2

COMMIT_WRAPPER = "git-commit.sh"
REPO_OPTION = "--repo"
# git-commit.sh options that consume the next argument, besides --repo.
WRAPPER_VALUE_OPTIONS = {"--file"}

# git global options that consume the next argument when not written as --opt=value.
GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix"}
# Options that point git at another repository than any -C says.
GIT_REPO_OVERRIDES = {"--git-dir", "--work-tree"}
UNEXPANDED_MARKERS = ("$", "`")


class Unresolvable(Exception):
    pass


def _git_invocation(tokens):
    """Return (subcommand, [-C values]) for a `git ...` segment, else None."""
    if not tokens or os.path.basename(tokens[0]) != "git":
        return None
    dirs = []
    i = 1
    while i < len(tokens):
        token = tokens[i]
        if not token.startswith("-"):
            return token, dirs
        name = token.split("=", 1)[0]
        if name in GIT_REPO_OVERRIDES:
            raise Unresolvable(f"git {name} sets the repository; not resolved from command text")
        if token in GIT_VALUE_OPTIONS:
            if token == "-C" and i + 1 < len(tokens):
                dirs.append(tokens[i + 1])
            i += 2
        else:
            i += 1
    return None, dirs


def _wrapper_repo(tokens):
    """Return the --repo value of a git-commit.sh segment, or None without one."""
    repo = None
    i = 1
    while i < len(tokens):
        token = tokens[i]
        if token == REPO_OPTION:
            repo = tokens[i + 1] if i + 1 < len(tokens) else ""
            i += 2
        elif token.startswith(REPO_OPTION + "="):
            repo = token[len(REPO_OPTION) + 1:]
            i += 1
        elif token in WRAPPER_VALUE_OPTIONS:
            i += 2
        else:
            i += 1
    return repo


def _resolve_dir(parts, cwd):
    path = cwd
    for part in parts:
        if any(marker in part for marker in UNEXPANDED_MARKERS):
            raise Unresolvable(f"target '{part}' contains a shell expansion")
        if not part:
            raise Unresolvable("empty target directory")
        path = os.path.join(path, os.path.expanduser(part))
    if not path:
        raise Unresolvable("no cwd to fall back to")
    if not os.path.isdir(path):
        raise Unresolvable(f"target '{path}' is not a directory")
    return os.path.realpath(path)


def _commit_target(tokens, cwd):
    """Target dir of a commit segment, or None if the segment does not commit."""
    if not tokens:
        return None
    if os.path.basename(tokens[0]) == COMMIT_WRAPPER:
        repo = _wrapper_repo(tokens)
        return _resolve_dir([] if repo is None else [repo], cwd)
    git = _git_invocation(tokens)
    if git and git[0] == "commit":
        return _resolve_dir(git[1], cwd)
    return None


def _is_push(tokens):
    try:
        git = _git_invocation(tokens)
    except Unresolvable:
        return False
    return bool(git) and git[0] == "push"


def resolve(command, cwd):
    """Return (target, pushed_after) or None without a commit segment.

    Raises Unresolvable with the reason.
    """
    try:
        segments = _hook.split_segments(command)
    except ValueError as exc:
        raise Unresolvable(f"command does not tokenize ({exc})")

    targets = []
    last_commit = -1
    for index, segment in enumerate(segments):
        _, tokens = _hook.strip_command_prefixes(segment)
        target = _commit_target(tokens, cwd)
        if target is not None:
            targets.append(target)
            last_commit = index

    if not targets:
        return None
    if len(set(targets)) > 1:
        raise Unresolvable("several commit segments with different targets: " + ", ".join(sorted(set(targets))))

    pushed_after = any(
        _is_push(_hook.strip_command_prefixes(segment)[1])
        for segment in segments[last_commit + 1:]
    )
    return targets[0], pushed_after


def main():
    cwd = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        result = resolve(sys.stdin.read(), cwd)
    except Unresolvable as exc:
        print(exc, file=sys.stderr)
        return EXIT_UNRESOLVABLE
    if result is None:
        return EXIT_NO_COMMIT
    target, pushed_after = result
    print(target)
    print("push" if pushed_after else "")
    return EXIT_RESOLVED


if __name__ == "__main__":
    sys.exit(main())
