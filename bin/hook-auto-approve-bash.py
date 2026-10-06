#!/usr/bin/env python3
"""
PreToolUse hook for Claude Code — auto-approves safe Bash commands.

Permission matching only checks the first token of a command. Compound
shapes (cd-prefixed, ;-chains, && chains with a harmless segment, command
substitution, env-var prefixes, a model-typed `rtk` prefix) defeat that matching and fall through to a
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


def _is_inside_projects_root(path):
    """True if `path` resolves to ~/Projects or something under it.

    Normalizes with abspath (not just expanduser) so a traversal like
    "~/Projects/x/../../etc" is resolved to its real target before the
    prefix check, instead of matching on the raw string. A RELATIVE path
    resolves against this hook's own working directory, which is not the
    one the command will run in — so it can never be proven inside the
    root and is rejected outright.
    """
    if not os.path.isabs(os.path.expanduser(path)):
        return False

    target = os.path.abspath(os.path.expanduser(path))
    return target == PROJECTS_ROOT or target.startswith(PROJECTS_ROOT + os.sep)


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

    if _is_inside_projects_root(segment_tokens[1]):
        return _strip_trailing_redirect_to_devnull(segment_tokens[2:])
    return segment_tokens


# --- env -C <dir> <cmd> -------------------------------------------------------
# The sanctioned replacement for `cd <dir> && <cmd>` where the command genuinely
# needs its working directory (a script reading ./.env, npx resolving config
# from cwd). It is one command, so permission matching works on it normally.
#
# It cannot just be allowlisted as `Bash(env -C *)`: that would allow every
# command behind an env prefix. Approval therefore requires BOTH halves — the
# directory inside ~/Projects, AND the command after it approved on its own
# merits by the very same rules. Every guard the hook applies elsewhere (git -c,
# find -exec, command substitution) still applies, because the remainder is run
# back through the normal segment check rather than trusted.


def strip_env_c_prefix(segment_tokens):
    """Drop a leading `env [-C <dir>|--chdir=<dir>]` when <dir> is inside
    ~/Projects, returning the command that follows.

    Returns the tokens unchanged when this is not an `env -C` invocation, when
    the directory is outside the root, or when no command follows — in each of
    those cases the segment's first token stays "env", which is not on
    ALLOWLIST, so the segment is not approved. `env` with only assignments and
    no -C is therefore left exactly as it was before this rule existed.
    """
    if not segment_tokens or segment_tokens[0] != "env":
        return segment_tokens

    rest = segment_tokens[1:]
    directory = None

    # Accept `-C <dir>`, `--chdir <dir>` and `--chdir=<dir>`. Assignments may
    # precede the flag (`env FOO=bar -C <dir> cmd`), so skip over them.
    index = 0
    while index < len(rest) and ENV_ASSIGNMENT_RE.match(rest[index]):
        index += 1

    if index < len(rest) and rest[index] in ("-C", "--chdir"):
        if index + 1 >= len(rest):
            return segment_tokens
        directory = rest[index + 1]
        remainder = rest[index + 2:]
    elif index < len(rest) and rest[index].startswith("--chdir="):
        directory = rest[index].split("=", 1)[1]
        remainder = rest[index + 1:]
    else:
        return segment_tokens

    if not directory or not remainder:
        return segment_tokens

    if not _is_inside_projects_root(directory):
        return segment_tokens

    return remainder


# --- repeat-cmd.sh <count> <cmd> ----------------------------------------------
# The sanctioned replacement for `for i in 1 2 3; do <cmd>; done` in timing
# measurements. Unlike env -C it IS matched by an allow rule on its own,
# Bash(~/.claude/bin/*), which is exactly the problem: it runs whatever it is
# handed, so that rule alone would approve `repeat-cmd.sh 1 <anything>`.
#
# The hook therefore judges the command after the count by the same rules as a
# bare segment, and main() answers "ask" when it fails — not merely "no
# decision", which would leave the allow rule to approve it anyway.

REPEAT_CMD_SCRIPT = "repeat-cmd.sh"
# fullmatch, not match with ^...$: Python's $ also matches before a trailing
# newline, which the wrapper's bash =~ does not.
REPEAT_COUNT_RE = re.compile(r"[1-9][0-9]*")


def is_repeat_cmd_invocation(tokens):
    """True if `tokens` invokes ~/.claude/bin/repeat-cmd.sh, any spelling."""
    return (
        bool(tokens)
        and _is_allowed_bin_token(tokens[0])
        and os.path.basename(tokens[0]) == REPEAT_CMD_SCRIPT
    )


def repeat_cmd_inner(tokens):
    """The command a repeat-cmd.sh invocation runs, or None when the shape is
    not `repeat-cmd.sh <positive-integer> <cmd> [args...]`.

    A malformed shape returns None rather than a best guess: the wrapper itself
    rejects it, and approving a guess would mean judging a command it never runs
    while the real argument vector goes unchecked.
    """
    if len(tokens) < 3 or not REPEAT_COUNT_RE.fullmatch(tokens[1]):
        return None
    return tokens[2:]


def command_has_unapprovable_repeat_cmd(command):
    """True if any segment of `command` mentions repeat-cmd.sh and is not one
    the hook will approve.

    Per segment, not per command: permission rules are matched per segment of a
    chain, so `git status && repeat-cmd.sh 1 curl x` would otherwise be approved
    by two rules that each match their own half.

    Any token, not just the first after the known prefixes: Claude Code strips
    wrappers like `timeout 5`, `time` and `nohup` before matching, so behind one
    of them the allow rule still matches the script. Recognising every flag of
    every such wrapper is a losing game; a segment that names the script and is
    not approvable asks, whatever stands in front. Never raises — on
    unparseable input the caller falls through.
    """
    try:
        segments = split_segments(command)
    except ValueError:
        return False

    for tokens in segments:
        mentions = any(is_repeat_cmd_invocation([token]) for token in tokens)
        if mentions and not is_segment_safe(tokens):
            return True

    return False


# --- model-typed rtk prefix -----------------------------------------------------
# The RTK hook rewrites commands itself (`grep ...` -> `rtk grep ...`), so the
# model never needs to type `rtk`. When it does anyway, the first word becomes
# `rtk`, which no allow rule names, and a command that is fine on its own
# prompts. `rtk <cmd>` and `rtk proxy <cmd>` both run <cmd> (filtered or raw),
# so the prefix is stripped and the remainder judged by the same rules as a
# bare segment — the prefix itself grants nothing.
#
# Stripping and trusting are separate. The deny rules strip ANY `rtk` prefix:
# seeing a sed read or cd chain behind it can only make the hook stricter.
# Approval trusts the prefix only for `rtk proxy` and for subcommands rtk
# documents as compacting the native tool of the same name. A colliding name
# can mean something else entirely — `rtk test curl x` RUNS `curl x`, while
# stripped it would read as the allowlisted builtin `test` — so every other
# subcommand, including names a later rtk release may add, falls through to
# the prompt.

RTK_PREFIX = "rtk"
RTK_PROXY_SUBCOMMAND = "proxy"
# ALLOWLIST names that `rtk --help` (0.45) lists as a proxy for the native tool.
RTK_NATIVE_PASSTHROUGH = frozenset({
    "git", "gh", "npm", "npx", "docker", "grep", "find", "ls", "wc",
    "ruff", "uv", "mypy", "pytest",
})


def strip_rtk_prefix(segment_tokens):
    """Drop a leading `rtk` or `rtk proxy`, returning the wrapped command.

    Says nothing about whether that command may be trusted; approval checks
    is_trusted_rtk_wrap separately.
    """
    if not segment_tokens or segment_tokens[0] != RTK_PREFIX:
        return segment_tokens

    rest = segment_tokens[1:]
    if rest[:1] == [RTK_PROXY_SUBCOMMAND]:
        rest = rest[1:]
    return rest


def is_trusted_rtk_wrap(segment_tokens):
    """True if `segment_tokens` is no rtk invocation at all, or one that runs
    the wrapped command as that command: `rtk proxy <cmd>`, or `rtk <tool>`
    for a tool in RTK_NATIVE_PASSTHROUGH."""
    if not segment_tokens or segment_tokens[0] != RTK_PREFIX:
        return True

    subcommand = segment_tokens[1] if len(segment_tokens) > 1 else None
    return subcommand == RTK_PROXY_SUBCOMMAND or subcommand in RTK_NATIVE_PASSTHROUGH


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


# --- Python used as a file reader -------------------------------------------
# CLAUDE.md forbids python3 -c for file reading/writing/searching: Read, Grep
# and Edit do it natively, with line numbers and no permission prompt. Python
# for CALCULATION or data transformation stays explicitly allowed, so this
# matches the file-access call itself, never the interpreter invocation.

# An inline program: `python -c "..."` or a heredoc (`python - <<'PY'`). The
# heredoc form is why the check below runs on the RAW command string rather
# than on tokens: shlex tokenizes a heredoc body as loose words, and real
# multi-line Python (apostrophes in comments, nested quotes) often fails to
# tokenize at all — so a token-based test would miss the very shape that
# produced most of these calls.
_PYTHON_INLINE_RE = re.compile(
    r"(^|[;&|]|\s)(python3?|py)\s+(-[A-Za-z]*c\b|-\s*(?=<<))", re.MULTILINE
)

# The file-reading calls themselves. Each requires a literal path argument, so
# a program that merely mentions `open` in a string is not matched.
_PYTHON_READ_RE = re.compile(
    r"""(
        json\.load\s*\(\s*open\s*\(          # json.load(open(...))
      | \bopen\s*\(\s*['"][^'"]*['"]\s*\)    # open('path') — no mode: read
      | \bopen\s*\(\s*['"][^'"]*['"]\s*,\s*['"][rb]{1,2}['"]   # open('path','r')
      | \.read_text\s*\(                     # Path(...).read_text()
      | \.read_bytes\s*\(
      | \breadlines\s*\(\s*\)
    )""",
    re.VERBOSE,
)


def command_has_python_file_read(command):
    """True if `command` runs inline Python that opens a file for reading.

    Deliberately narrow, in the same spirit as is_sed_file_read: it fires only
    when BOTH an inline-program invocation (-c or a heredoc) and a literal
    file-reading call are present. Never raises — the caller falls through.

    NOT matched, and must keep falling through to a normal prompt:
      - `python3 -c` doing arithmetic or data transformation (no file access),
        which CLAUDE.md explicitly permits;
      - `python3 script.py` — running a real script, not an inline program;
      - writes (`open(p, 'w')`) and other genuine shell work that happens to
        name a path;
      - venv-run.sh / .venv/bin/python wrappers, which are the sanctioned way
        to reach a project interpreter.
    """
    if not isinstance(command, str):
        return False
    if not _PYTHON_INLINE_RE.search(command):
        return False
    return bool(_PYTHON_READ_RE.search(command))


# --- until+sleep wait loops ---------------------------------------------------
# `until <cond>; do sleep N; done` is a compound command, so permission matching
# fails on its second segment and it prompts on every call. wait-for-pattern.sh
# exists for exactly this shape and matches Bash(~/.claude/bin/*).
#
# The deny below covers ONLY the conditions that wrapper actually handles:
# waiting for a file to exist, or for a regex to appear in a file. A loop
# polling an HTTP status, a container state or a command's exit status has no
# wrapper to point at, so it is left alone — a hint naming the wrong tool sends
# the reader down a dead end, which is worse than the prompt it replaces.

# test/[ operators that ask "does this file exist / is it non-empty yet".
_FILE_TEST_OPERATORS = {"-f", "-e", "-s", "-r"}


def _is_file_existence_test(tokens):
    """True for `[ -f FILE ]`, `[[ -s FILE ]]`, `test -e FILE` and friends.

    Requires a literal path operand: `[ -f "$var" ]` still matches structurally,
    which is fine — the wrapper takes a path either way.
    """
    if not tokens:
        return False

    if tokens[0] in ("[", "[["):
        inner = tokens[1:-1] if tokens[-1] in ("]", "]]") else tokens[1:]
    elif tokens[0] == "test":
        inner = tokens[1:]
    else:
        return False

    return len(inner) == 2 and inner[0] in _FILE_TEST_OPERATORS


def _is_grep_on_file(tokens):
    """True for `grep [flags] PATTERN FILE` — grep used to wait for a regex to
    appear in a file.

    A grep reading stdin (no file operand) is NOT matched: there is no file for
    wait-for-pattern.sh to poll, so the wrapper cannot replace it.
    """
    if not tokens or tokens[0] != "grep":
        return False

    operands = [t for t in tokens[1:] if not t.startswith("-")]
    # Need both a pattern and at least one file operand.
    return len(operands) >= 2


def _is_wait_for_pattern_condition(condition_tokens):
    """True if an until-loop condition is one wait-for-pattern.sh can replace."""
    tokens = strip_env_prefix(condition_tokens)
    return _is_file_existence_test(tokens) or _is_grep_on_file(tokens)


def _loop_body_sleeps(segments, start):
    """True if the loop body starting at `segments[start]` calls sleep.

    The body is every segment from the one opening with `do` up to the `done`
    that closes the loop. `sleep` is what identifies the construct as a WAIT
    loop rather than a counter or a busy loop, so a body without it is not
    matched at all.
    """
    for index in range(start, len(segments)):
        tokens = segments[index]
        # The body's first segment carries `do` as its leading token
        # (`; do sleep 10` tokenizes as ["do", "sleep", "10"]).
        body = tokens[1:] if index == start and tokens[:1] == ["do"] else tokens
        if "done" in body or body[:1] == ["done"]:
            return False
        if "sleep" in body:
            return True
    return False


def command_has_until_sleep_wait_loop(command):
    """True if `command` contains `until <file-condition>; do ... sleep N ...; done`.

    Both halves must hold: the loop structure (an `until` whose body sleeps) AND
    a condition wait-for-pattern.sh can actually replace. Never raises — on
    unparseable input the caller falls through to the normal prompt.
    """
    try:
        segments = split_segments(command)
    except ValueError:
        return False

    for index, tokens in enumerate(segments):
        if tokens[:1] != ["until"]:
            continue
        if not _is_wait_for_pattern_condition(tokens[1:]):
            continue
        if _loop_body_sleeps(segments, index + 1):
            return True

    return False


# --- cd-prefixed chains -------------------------------------------------------
# `cd <dir> && <cmd>` is the single most common cause of permission prompts:
# matching only looks at the first word, so the rule that would allow <cmd>
# never applies and the whole command prompts. git -C, npm --prefix and
# env -C <dir> <cmd> all express the same intent as one command, which does
# match.
#
# The rule fires inside ~/Projects as well, even though strip_cd_prefix would
# see through such a chain and approve it. An approved cd chain is
# indistinguishable, from the agent's side, from one that merely has not
# prompted yet — so auto-approving it teaches exactly the shape that prompts
# everywhere else. Denying it uniformly is what makes the alternative stick.


def command_has_cd_prefix_chain(command):
    """True if `command` has a `cd` segment with another command after it.

    A BARE `cd <dir>` is deliberately not matched: it runs nothing after
    itself, so it defeats no permission match and there is no alternative to
    point the reader at. Never raises — on unparseable input the caller falls
    through to the normal prompt.
    """
    try:
        segments = split_segments(command)
    except ValueError:
        return False

    for index, tokens in enumerate(segments):
        # strip_env_c_prefix too: `env -C <dir> cd /tmp && ...` is the same
        # mistake wearing the approved prefix, and must not launder past it.
        # Likewise a model-typed `rtk cd ...`.
        if strip_rtk_prefix(strip_env_prefix(strip_env_c_prefix(tokens)))[:1] != ["cd"]:
            continue
        # Only a cd with a command after it defeats a permission match.
        if index + 1 < len(segments):
            return True

    return False


def is_segment_safe(segment_tokens):
    """A segment is safe if, after stripping cd/env prefixes, its first
    token is on ALLOWLIST or a ~/.claude/bin/ script — with no command
    substitution anywhere in it (git commit is the sole carve-out, since
    git-commit.sh already handles quoting/heredoc bodies safely).

    `env -C <dir>` is stripped BEFORE plain VAR=value assignments: the
    remainder of an `env -C <dir> FOO=bar git status` still carries its own
    assignments, which strip_env_prefix then removes as usual. A model-typed
    `rtk` / `rtk proxy` prefix is stripped last, so `FOO=1 rtk grep ...` is
    judged as `grep ...`.
    """
    if not segment_tokens:
        return True

    env_stripped = strip_env_prefix(
        strip_env_c_prefix(strip_cd_prefix(segment_tokens))
    )
    if not is_trusted_rtk_wrap(env_stripped):
        return False
    stripped = strip_rtk_prefix(env_stripped)
    if not stripped:
        # A bare `rtk` / `rtk proxy` runs no wrapped command; never approve it.
        return not env_stripped

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

    if is_repeat_cmd_invocation(stripped):
        inner = repeat_cmd_inner(stripped)
        return inner is not None and is_segment_safe(inner)

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
        is_sed_file_read(strip_rtk_prefix(strip_env_prefix(strip_cd_prefix(segment))))
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

    if command_has_python_file_read(command):
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    "Hook: inline Python that opens a file is a file read. Use "
                    "Read (with offset/limit), Grep to search, or Edit to "
                    "modify — they are allowlisted and need no permission "
                    "prompt. Python for calculation or data transformation "
                    "with no file access stays fine."
                ),
            }
        }
        print(json.dumps(output))
        return 0

    if command_has_until_sleep_wait_loop(command):
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    "Hook: `until ...; do sleep N; done` waiting on a file is a "
                    "wait loop. Use ~/.claude/bin/wait-for-pattern.sh <file> "
                    "<extended-regex> [timeout-seconds] [poll-seconds] instead: "
                    "it matches Bash(~/.claude/bin/*) and needs no permission "
                    "prompt. The file need not exist yet. Loops waiting on "
                    "anything else (an HTTP status, a container state, a "
                    "command's exit status) are not affected by this rule."
                ),
            }
        }
        print(json.dumps(output))
        return 0

    if command_has_cd_prefix_chain(command):
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    "Hook: `cd <dir> && <cmd>` defeats permission matching — "
                    "rules match the first word, which is `cd`, so the rule "
                    "that would allow <cmd> never applies and this prompts "
                    "every time. Use `git -C <dir> <args>` for git, "
                    "`npm --prefix <dir> <args>` for npm, or "
                    "`env -C <dir> <cmd>` for anything else that genuinely "
                    "needs its working directory. All three are a single "
                    "command, so they match normally."
                ),
            }
        }
        print(json.dumps(output))
        return 0

    # "ask", not silence: Bash(~/.claude/bin/*) would approve the wrapper
    # without a prompt, whatever command it was handed.
    if command_has_unapprovable_repeat_cmd(command):
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": (
                    "Hook: repeat-cmd.sh runs the command it is given, so it is "
                    "approved only when `repeat-cmd.sh <count> <cmd>` has a "
                    "positive integer count and <cmd> would be approved on its "
                    "own. This one is not, so it needs your confirmation."
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
