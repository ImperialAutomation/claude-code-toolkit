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
    3. the segment's working directory
The working directory is the cwd, moved by any `cd <dir>` segment before the
commit and by an `env -C <dir>` prefix on the commit segment itself. Relative
paths resolve against it and a leading `~` against $HOME. A target is never
taken from another segment of the chain: `git -C <A> add && git-commit.sh
--repo <B>` commits in B.

Unresolvable: a target containing `$` or a backtick (no expansion of command
text here), a directory that does not exist, `cd -`, a commit segment using
--git-dir or --work-tree, several commit segments with different targets, or a
command that does not tokenize.
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

GIT = "git"
COMMIT_SUBCOMMAND = "commit"
PUSH_SUBCOMMAND = "push"
# Second output line when a push follows the commit; the hook compares against it.
PUSH_MARKER = "push"

COMMIT_WRAPPER = "git-commit.sh"
REPO_OPTION = "--repo"
# git-commit.sh options that consume the next argument, besides --repo.
WRAPPER_VALUE_OPTIONS = {"--file"}

# git global options that consume the next argument when not written as --opt=value.
GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix"}
# Options that point git at another repository than any -C says.
GIT_REPO_OVERRIDES = {"--git-dir", "--work-tree"}
UNEXPANDED_MARKERS = ("$", "`")

CD = "cd"
# `cd -` returns to a directory the command text does not show.
CD_PREVIOUS = "-"
HOME = "~"


class Unresolvable(Exception):
    pass


def _git_invocation(tokens):
    """Return (subcommand, [-C values], repo override or None) for a `git ...`
    segment, else None."""
    if not tokens or os.path.basename(tokens[0]) != GIT:
        return None
    dirs = []
    override = None
    i = 1
    while i < len(tokens):
        token = tokens[i]
        if not token.startswith("-"):
            return token, dirs, override
        name = token.split("=", 1)[0]
        if name in GIT_REPO_OVERRIDES:
            override = name
        if token in GIT_VALUE_OPTIONS:
            if token == "-C" and i + 1 < len(tokens):
                dirs.append(tokens[i + 1])
            i += 2
        else:
            i += 1
    return None, dirs, override


def _strip_env_chdir(tokens):
    """Drop leading `env` invocations, returning ([-C/--chdir values], rest).

    Done here rather than by the approve hook's strip_env_invocation, which
    only sees through a -C inside ~/Projects: the commit lands in the -C
    directory wherever it is. An env option this does not know stops the
    stripping; the segment then does not read as a commit.
    """
    dirs = []
    while tokens and tokens[0] == _hook.ENV_COMMAND:
        i = 1
        while i < len(tokens):
            if _hook.ENV_ASSIGNMENT_RE.match(tokens[i]):
                i += 1
                continue
            chdir = _hook._env_option_value(tokens, i, _hook.ENV_CHDIR_OPTION)
            unset = _hook._env_option_value(tokens, i, _hook.ENV_UNSET_OPTION)
            if chdir is not None:
                dirs.append(chdir[0])
                i += chdir[1]
            elif unset is not None:
                i += unset[1]
            elif tokens[i].startswith("-"):
                return dirs, tokens
            else:
                break
        tokens = tokens[i:]
    return dirs, tokens


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


def _commit_target(segment, cwd):
    """Target dir of a commit segment, or None if the segment does not commit."""
    chdirs, tokens = _strip_env_chdir(segment)
    _, tokens = _hook.strip_command_prefixes(tokens)
    if not tokens:
        return None
    if os.path.basename(tokens[0]) == COMMIT_WRAPPER:
        repo = _wrapper_repo(tokens)
        return _resolve_dir(chdirs + ([] if repo is None else [repo]), cwd)
    git = _git_invocation(tokens)
    if git and git[0] == COMMIT_SUBCOMMAND:
        if git[2]:
            raise Unresolvable(f"git {git[2]} sets the repository; not resolved from command text")
        return _resolve_dir(chdirs + git[1], cwd)
    return None


def _cd_target(tokens, cwd):
    """The directory a `cd` segment moves to, or None if it is no `cd`."""
    if not tokens or tokens[0] != CD:
        return None
    if len(tokens) > 1 and tokens[1] == CD_PREVIOUS:
        raise Unresolvable(f"'{CD} {CD_PREVIOUS}' before the commit")
    return _resolve_dir([tokens[1] if len(tokens) > 1 else HOME], cwd)


def _is_push(segment):
    _, tokens = _hook.strip_command_prefixes(_strip_env_chdir(segment)[1])
    git = _git_invocation(tokens)
    return bool(git) and git[0] == PUSH_SUBCOMMAND


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
    # A `cd` that cannot be followed only matters if a commit comes after it.
    cd_error = None
    for index, segment in enumerate(segments):
        try:
            moved = _cd_target(segment, cwd)
        except Unresolvable as exc:
            cd_error = exc
            continue
        if moved is not None:
            cwd = moved
            continue
        target = _commit_target(segment, cwd)
        if target is not None:
            if cd_error is not None:
                raise cd_error
            targets.append(target)
            last_commit = index

    if not targets:
        return None
    if len(set(targets)) > 1:
        raise Unresolvable("several commit segments with different targets: " + ", ".join(sorted(set(targets))))

    pushed_after = any(_is_push(segment) for segment in segments[last_commit + 1:])
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
    print(PUSH_MARKER if pushed_after else "")
    return EXIT_RESOLVED


if __name__ == "__main__":
    sys.exit(main())
