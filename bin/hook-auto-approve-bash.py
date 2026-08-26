#!/usr/bin/env python3
"""
PreToolUse hook for Claude Code — auto-approves safe Bash commands.

Permission matching only checks the first token of a command. Compound
shapes (cd-prefixed, ;-chains, && chains with a harmless segment, command
substitution, env-var prefixes) defeat that matching and fall through to a
permission prompt even when every actual command in them is already
allowlisted. This hook tokenizes the full command with shlex and approves
it only when every segment is provably safe.

Fails open to the normal prompt, never to approval: any parse error or
unrecognized segment exits 0 without a decision.
"""

import json
import os
import re
import shlex
import sys

PROJECTS_ROOT = os.path.expanduser("~/Projects")
CLAUDE_BIN = os.path.expanduser("~/.claude/bin")

# Commands already unconditionally allowed standalone in settings.json,
# plus echo/sleep/test/true for harmless chain glue.
ALLOWLIST = {
    "gh", "git", "npm", "npx", "docker",
    "cat", "grep", "find", "head", "tail", "ls",
    "wc", "sort", "echo", "printf", "mkdir", "cp",
    "mv", "chmod", "tee", "python", "ruff", "uv",
    "mypy", "pytest", "alembic",
    "source", "xdg-open", "sleep", "test", "true",
}

# Bare "&" can never actually reach this set as its own token since & was
# removed from _tokenize's punctuation_chars (see that docstring) — kept
# here so a background operator glued to punctuation_chars again in the
# future still splits correctly without needing to touch this set too.

# Bare venv-tool names a project's own .venv/bin/<name> may invoke — matched
# against the LAST path component so both "backend/.venv/bin/mypy" (relative,
# post-cd-strip) and an absolute "/home/.../backend/.venv/bin/mypy" resolve
# the same way. Deliberately the same set already trusted as bare ALLOWLIST
# tokens (python/ruff/uv/mypy/pytest/alembic) — a .venv/bin/ prefix does not
# change what the tool itself can do, only how it's invoked (CLAUDE.md's
# documented "absolute venv paths don't match Bash(*/python *)" gap).
_VENV_BIN_TOOLS = {"python", "ruff", "uv", "mypy", "pytest", "alembic"}


def _is_venv_bin_token(token):
    """True if `token` ends in .venv/bin/<trusted-tool>, any path prefix."""
    normalized = token.replace(os.sep, "/")
    parts = normalized.split("/")
    if len(parts) < 3:
        return False
    tool, bin_dir, venv_dir = parts[-1], parts[-2], parts[-3]
    return venv_dir == ".venv" and bin_dir == "bin" and tool in _VENV_BIN_TOOLS


SEGMENT_SEPARATORS = {"&&", "||", ";", "|", "&", "\n"}

ENV_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def _tokenize(command):
    """Tokenize `command` with &&, ||, ;, |, and newline as standalone
    punctuation tokens.

    Raises ValueError on unparseable input (unbalanced quotes, etc.) — the
    caller must treat that as "fall through to the prompt", never approval.

    Newline is deliberately pulled OUT of shlex's default whitespace set and
    into punctuation_chars: bash treats a bare newline as a statement
    separator exactly like ";", but shlex's default whitespace_split mode
    silently swallows it, which let an unrelated, unvalidated command ride
    along after a newline and still get the whole compound command
    approved. A newline still stays glued inside a quoted token (shlex's
    quote handling takes priority over punctuation splitting), so
    `echo "line1\nline2"` is unaffected — only a *bare* newline splits.

    A bare `&` is deliberately EXCLUDED from punctuation_chars (unlike &&,
    which stays split via the two-char punctuation run). Fd-redirects like
    `2>&1` / `1>&2` are extremely common in agent-generated commands and
    contain a glued `&` with no surrounding whitespace; shlex only splits
    punctuation_chars at token boundaries, so keeping `&` out of that set
    leaves `2>&1` as a single token while `&&` (whitespace-delimited on
    both sides in practice) still tokenizes as its own two-char punctuation
    run. The cost: a real background operator (`cmd &`) no longer acts as
    a segment separator — it rides along as a trailing word in the same
    segment instead of splitting into a new one. That is safe here: only
    the segment's first token is ever checked against the allowlist, so an
    inert trailing `&` token changes no safety decision, and any command
    genuinely appended after it would need its own `&&`/`;`/`|` to run as
    a separate statement, which still splits correctly.
    """
    lexer = shlex.shlex(command, posix=True, punctuation_chars="|;\n")
    lexer.whitespace = " \t"
    lexer.whitespace_split = True
    return list(lexer)


def split_segments(command):
    """Split `command` into token-list segments on &&, ||, ;, |, &, newline.

    Returns a list of token lists (one per segment). Raises ValueError on
    unparseable input — see _tokenize.
    """
    tokens = _tokenize(command)

    segments = []
    current = []
    for token in tokens:
        if token in SEGMENT_SEPARATORS:
            segments.append(current)
            current = []
        else:
            current.append(token)
    segments.append(current)

    return [s for s in segments if s]


def has_command_substitution(segment_tokens):
    """True if any token in a segment contains $( or a backtick.

    Checks token substrings rather than requiring an exact "$(" or "$"
    token, since where "(" falls glued to "$(cat" vs split into separate
    "$"/"(" tokens depends on which characters are in punctuation_chars —
    substring matching is robust to either tokenization. Catches both
    `$(...)` and legacy backtick substitution.
    """
    for token in segment_tokens:
        if "`" in token or "$(" in token or token == "$":
            return True
    return False


def has_heredoc(segment_tokens):
    """True if a segment uses << or <<< — shlex doesn't reject these (it
    tokenizes the body as plain words), but a heredoc body can smuggle
    arbitrary content into any command, so it is never auto-approved."""
    return "<<" in segment_tokens or "<<<" in segment_tokens


def has_process_substitution(segment_tokens):
    """True if a segment uses process substitution: >(...) or <(...).

    This spawns a subshell running an arbitrary command wired to a pipe —
    a full command-execution vector riding on an allowlisted first token
    like `echo` or `cat`. shlex glues "<(" / ">(" to the following word
    (e.g. "<(echo"), so this checks substrings, not standalone tokens.
    """
    for token in segment_tokens:
        if "<(" in token or ">(" in token:
            return True
    return False


def strip_env_prefix(segment_tokens):
    """Drop leading VAR=value tokens (e.g. `FOO=bar git status` -> `git status`)."""
    i = 0
    while i < len(segment_tokens) and ENV_ASSIGNMENT_RE.match(segment_tokens[i]):
        i += 1
    return segment_tokens[i:]


def _strip_trailing_redirect_to_devnull(tokens):
    """Drop a single trailing `2>/dev/null`-style redirect glued to `cd`.

    `cd X 2>/dev/null; real-command ...` puts the redirect on the cd
    itself, not on a following command — but shlex tokenizes it as a
    plain word following the path, so after dropping `cd <dir>` the
    segment would otherwise end with a lone `N>/dev/null` token that
    looks like (and is treated as) the segment's first/only token. Only
    strips a redirect to /dev/null specifically (the overwhelmingly
    common "silence errors" idiom on a cd) — a redirect to a real file
    is left in place, which keeps the segment unrecognized/unsafe rather
    than silently approving an unreviewed file write.
    """
    if tokens and re.fullmatch(r"\d*>/dev/null", tokens[-1]):
        return tokens[:-1]
    return tokens


def strip_cd_prefix(segment_tokens):
    """Drop a leading `cd <dir>` when <dir> resolves inside ~/Projects.

    A cd into anywhere else (e.g. /etc, ~, a symlinked escape) is left
    in place, which means the segment's first token stays "cd" — "cd" is
    not in ALLOWLIST, so the segment (and the whole command) will not be
    approved. This is deliberate: only cd's the user's own project tree
    are considered safe to see through.
    """
    if len(segment_tokens) < 2 or segment_tokens[0] != "cd":
        return segment_tokens

    target = os.path.abspath(os.path.expanduser(segment_tokens[1]))
    if target == PROJECTS_ROOT or target.startswith(PROJECTS_ROOT + os.sep):
        return _strip_trailing_redirect_to_devnull(segment_tokens[2:])
    return segment_tokens


def _is_allowed_bin_token(token):
    """True if `token` is a ~/.claude/bin/ script reference (any spelling).

    Normalizes with normpath (not just expanduser) so a traversal like
    "~/.claude/bin/../../../etc/passwd" is resolved to its real target
    before the prefix check, instead of matching on the raw string.
    """
    resolved = os.path.normpath(os.path.expanduser(token))
    return resolved == CLAUDE_BIN or resolved.startswith(CLAUDE_BIN + os.sep)


# git flags/subcommands that execute arbitrary commands or rewrite config
# persistently — a bare "git is allowlisted" check doesn't see these.
# core.sshCommand/fsmonitor/pager/editor and diff.external all run a
# shell command git itself invokes later (incl. on other allowlisted
# calls like `git status`); --upload-pack and the ext:: transport run a
# command immediately as part of `git clone`/`git fetch`.
_DANGEROUS_GIT_CONFIG_KEYS = (
    "core.sshcommand", "core.fsmonitor", "core.pager", "core.editor",
    "diff.external",
)


def _has_denied_git_config_flag(tokens):
    """True if a git invocation sets a config key that runs shell commands,
    via -c KEY=VAL, `git config KEY VAL`, or --upload-pack/ext:: transports."""
    joined = " ".join(tokens).lower()
    if "--upload-pack" in joined or "ext::" in joined:
        return True

    for i, token in enumerate(tokens):
        if token in ("-c", "--config"):
            value = tokens[i + 1] if i + 1 < len(tokens) else ""
            if any(value.lower().startswith(k) for k in _DANGEROUS_GIT_CONFIG_KEYS):
                return True
        if token == "config":
            rest = " ".join(tokens[i + 1:]).lower()
            if any(rest.startswith(k) for k in _DANGEROUS_GIT_CONFIG_KEYS):
                return True

    return False


def _is_safe_git_invocation(tokens):
    """git is allowlisted for its normal porcelain use, but is itself a
    command-execution framework via -c/config/--upload-pack/ext:: — deny
    those regardless of subcommand (git commit has its own carve-out
    caller-side; this covers every other git invocation)."""
    return not _has_denied_git_config_flag(tokens)


# docker flags that escape container isolation or grant host access.
_DANGEROUS_DOCKER_FLAGS = (
    "--privileged", "--pid=host", "--net=host", "--network=host",
    "--cap-add", "--device", "--entrypoint",
)


def _is_safe_docker_invocation(tokens):
    """docker is allowlisted for build/ps/logs/etc, but `docker run` can
    bind-mount the host root or drop container isolation entirely — deny
    known escape flags rather than trusting "docker" as just a binary name."""
    joined = " ".join(tokens).lower()
    if any(flag in joined for flag in _DANGEROUS_DOCKER_FLAGS):
        return False

    for i, token in enumerate(tokens):
        if token in ("-v", "--volume") and i + 1 < len(tokens):
            spec = tokens[i + 1]
            host_side = spec.split(":")[0]
            if os.path.abspath(os.path.expanduser(host_side)) == "/":
                return False

    return True


def _is_safe_find_invocation(tokens):
    """find is allowlisted as a read/search tool, but -exec/-execdir/-ok/
    -okdir run an arbitrary command per match — deny those regardless of
    what command they invoke."""
    danger_flags = {"-exec", "-execdir", "-ok", "-okdir", "-fprintf", "-delete"}
    return not any(token in danger_flags for token in tokens)


def is_sed_file_read(tokens):
    """True for `sed -n 'X,Yp' <file>` and friends — sed used as a plain file
    reader, which is Read with offset/limit written as a shell command.

    Deliberately narrow. A real stream edit (-i, a substitution, reading from a
    pipe) is NOT matched: those are legitimate shell work and must keep falling
    through to a normal prompt rather than being denied."""
    if not tokens or tokens[0] != "sed":
        return False
    if "-n" not in tokens and "--quiet" not in tokens and "--silent" not in tokens:
        return False

    operands = [t for t in tokens[1:] if not t.startswith("-")]
    # Need both a script and at least one file operand; `sed -n 1,5p` alone
    # reads stdin, so there is no file for Read to open instead.
    if len(operands) < 2:
        return False

    # The script is the first operand. Match a line-range print: N p, N,M p,
    # N,$ p — optionally with the whole thing wrapped in braces.
    script = operands[0].strip("{} ")
    return bool(re.fullmatch(r"\d+(,(\d+|\$))?\s*p", script))


def is_segment_safe(segment_tokens):
    """A segment is safe if, after stripping cd/env prefixes, its first
    token is on ALLOWLIST or a ~/.claude/bin/ script — with no command
    substitution anywhere in it (git commit is the sole carve-out, since
    git-commit.sh already handles quoting/heredoc bodies safely)."""
    if not segment_tokens:
        return True

    stripped = strip_env_prefix(strip_cd_prefix(segment_tokens))
    if not stripped:
        return True

    first = stripped[0]
    is_git_commit = first == "git" and len(stripped) > 1 and stripped[1] == "commit"

    if has_heredoc(segment_tokens):
        return False

    if has_process_substitution(segment_tokens):
        return False

    if has_command_substitution(segment_tokens) and not is_git_commit:
        return False

    if is_git_commit:
        return not _has_denied_git_config_flag(stripped)

    if (
        first not in ALLOWLIST
        and not _is_allowed_bin_token(first)
        and not _is_venv_bin_token(first)
    ):
        return False

    if first == "git":
        return _is_safe_git_invocation(stripped)
    if first == "docker":
        return _is_safe_docker_invocation(stripped)
    if first == "find":
        return _is_safe_find_invocation(stripped)

    return True


def command_has_sed_file_read(command):
    """True if any segment of `command` uses sed as a file reader. False
    (never raises) on unparseable input — the caller falls through."""
    try:
        segments = split_segments(command)
    except ValueError:
        return False

    return any(
        is_sed_file_read(strip_env_prefix(strip_cd_prefix(segment)))
        for segment in segments
    )


def is_command_safe(command):
    """True if every segment of `command` is safe. False (never raises)
    on unparseable input — the caller falls through to the normal prompt."""
    try:
        segments = split_segments(command)
    except ValueError:
        return False

    return all(is_segment_safe(segment) for segment in segments)


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return 0

    command = payload.get("tool_input", {}).get("command", "")
    if not command:
        return 0

    # Deny wins over allow: a chain that is otherwise fully allowlisted is
    # still denied when one of its segments reads a file through sed.
    if command_has_sed_file_read(command):
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    "Hook: `sed -n 'X,Yp' <file>` is a file read. Use the Read "
                    "tool with offset/limit instead — it is allowlisted, shows "
                    "line numbers, and needs no permission prompt."
                ),
            }
        }
        print(json.dumps(output))
        return 0

    if is_command_safe(command):
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "Hook: all command segments allowlisted",
            }
        }
        print(json.dumps(output))

    return 0


if __name__ == "__main__":
    sys.exit(main())
