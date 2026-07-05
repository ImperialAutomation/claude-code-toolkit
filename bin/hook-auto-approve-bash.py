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
    "source", "xdg-open", "sleep", "test", "true",
}

SEGMENT_SEPARATORS = {"&&", "||", ";", "|"}

ENV_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def _tokenize(command):
    """Tokenize `command` with &&, ||, ;, | as standalone punctuation tokens.

    Raises ValueError on unparseable input (unbalanced quotes, etc.) — the
    caller must treat that as "fall through to the prompt", never approval.
    """
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def split_segments(command):
    """Split `command` into token-list segments on &&, ||, ;, |.

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

    shlex (with punctuation_chars) splits "$(" into separate "$" and "("
    tokens, so this checks token contents rather than requiring an exact
    "$(" token — catches both `$(...)` and legacy backtick substitution.
    """
    for token in segment_tokens:
        if "`" in token or token == "$":
            return True
    return False


def has_heredoc(segment_tokens):
    """True if a segment uses << or <<< — shlex doesn't reject these (it
    tokenizes the body as plain words), but a heredoc body can smuggle
    arbitrary content into any command, so it is never auto-approved."""
    return "<<" in segment_tokens or "<<<" in segment_tokens


def strip_env_prefix(segment_tokens):
    """Drop leading VAR=value tokens (e.g. `FOO=bar git status` -> `git status`)."""
    i = 0
    while i < len(segment_tokens) and ENV_ASSIGNMENT_RE.match(segment_tokens[i]):
        i += 1
    return segment_tokens[i:]


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
        return segment_tokens[2:]
    return segment_tokens


def _is_allowed_bin_token(token):
    """True if `token` is a ~/.claude/bin/ script reference (any spelling).

    Normalizes with normpath (not just expanduser) so a traversal like
    "~/.claude/bin/../../../etc/passwd" is resolved to its real target
    before the prefix check, instead of matching on the raw string.
    """
    resolved = os.path.normpath(os.path.expanduser(token))
    return resolved == CLAUDE_BIN or resolved.startswith(CLAUDE_BIN + os.sep)


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

    if has_command_substitution(segment_tokens) and not is_git_commit:
        return False

    if is_git_commit:
        return True

    return first in ALLOWLIST or _is_allowed_bin_token(first)


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
