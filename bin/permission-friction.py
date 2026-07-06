#!/usr/bin/env python3
"""
Scan a project's Claude Code session transcripts for permission friction:
how often Bash commands would have triggered a permission prompt, which
patterns caused it, and how often calls were explicitly denied.

Run directly: python3 bin/permission-friction.py [project-dir] [--days N] [--json]
Or via venv: ~/.claude/bin/venv-run.sh python bin/permission-friction.py

Reads transcripts only (no network) from
~/.claude/projects/<encoded-project-dir>/*.jsonl, and derives allow/deny
rules by parsing the merged settings.json files at runtime — never a
hardcoded allowlist, so it stays correct as the user's permissions evolve.
"""

import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path

_HOOK_PATH = Path(__file__).parent / "hook-auto-approve-bash.py"
_spec = importlib.util.spec_from_file_location("hook_auto_approve_bash", _HOOK_PATH)
_hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_hook)

CLAUDE_HOME = Path(os.path.expanduser("~/.claude"))
PROJECTS_TRANSCRIPTS_DIR = CLAUDE_HOME / "projects"

SETTINGS_FILENAMES = ("settings.json", "settings.local.json")

REJECTION_MARKER = "The user doesn't want to proceed with this tool use"


def _read_json_file(path):
    """Return the parsed JSON object at `path`, or None if missing/invalid.

    Missing or malformed settings files are not a hard error — the merge
    just proceeds without that scope's rules.
    """
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def load_allow_rules(project_dir):
    """Merge `permissions.allow`/`permissions.deny` across every settings
    scope that actually exists: user global, project shared, project local.

    Returns (allow_patterns, deny_patterns) — flat lists of raw rule
    strings (e.g. "Bash(git *)"), unioned across scopes. Precedence between
    scopes does not matter here: we only need "is this command covered by
    ANY allow rule," and deny rules always win regardless of origin.
    """
    candidate_files = [
        CLAUDE_HOME / "settings.json",
        Path(project_dir) / ".claude" / "settings.json",
        Path(project_dir) / ".claude" / "settings.local.json",
    ]

    allow = []
    deny = []
    for path in candidate_files:
        data = _read_json_file(path)
        if not data:
            continue
        permissions = data.get("permissions", {})
        allow.extend(permissions.get("allow", []))
        deny.extend(permissions.get("deny", []))

    return allow, deny


def _bash_pattern_body(rule):
    """Return the inner pattern of a Bash(...) rule, or None if `rule` is
    not a Bash rule at all (e.g. "Write", "Read(~/.claude/**)")."""
    if rule == "Bash":
        return "*"
    if rule.startswith("Bash(") and rule.endswith(")"):
        return rule[len("Bash("):-1]
    return None


def matches_bash_rule(command, rule):
    """True if `command` (a full command string) is covered by a single
    Bash permission `rule`.

    Grammar (see docs.claude.com/en/permissions):
      Bash / Bash(*)      -> matches everything
      Bash(cmd *)         -> first token "cmd", "*" matches rest incl. none
      Bash(cmd:*)         -> equivalent to "Bash(cmd *)" (colon shorthand)
      Bash(cmd*)          -> literal prefix match, no word boundary
      Bash(exact string)  -> exact full-command match, no wildcard
    Wildcards may also appear mid-pattern (e.g. "Bash(git * main)"); these
    are handled generically via fnmatch after the colon-shorthand rewrite.
    """
    pattern = _bash_pattern_body(rule)
    if pattern is None:
        return False

    if pattern.endswith(":*"):
        pattern = pattern[:-2] + " *"

    import fnmatch

    return fnmatch.fnmatchcase(command, pattern)


def command_matches_any_rule(command, rules):
    return any(matches_bash_rule(command, rule) for rule in rules)


# Friction reasons, most specific first — used both to explain a verdict
# and to bucket "top prompt-causing patterns" in the report.
REASON_DENY_MATCH = "matches a deny rule"
REASON_HEREDOC = "heredoc (<<, <<<) defeats matching"
REASON_PROCESS_SUBSTITUTION = "process substitution (<(...), >(...)) defeats matching"
REASON_COMMAND_SUBSTITUTION = "command substitution ($(...), `...`) defeats matching"
REASON_CD_PREFIX = "cd-prefix defeats first-token matching"
REASON_CHAIN = "compound command (;/&&/||/|) has an unmatched segment"
REASON_NO_RULE = "no allow rule covers this command"


def classify_command(command, allow_rules, deny_rules):
    """Classify whether `command` would trigger a permission prompt.

    Returns (would_prompt: bool, reason: str | None). reason is None only
    when the command would NOT prompt. Mirrors hook-auto-approve-bash.py's
    own safety logic first — a command that hook would silently approve
    never reaches a prompt in practice, regardless of raw rule coverage.
    """
    if command_matches_any_rule(command, deny_rules):
        return True, REASON_DENY_MATCH

    if _hook.is_command_safe(command):
        return False, None

    try:
        segments = _hook.split_segments(command)
    except ValueError:
        return True, REASON_NO_RULE

    if len(segments) > 1:
        for segment_tokens in segments:
            segment_command = " ".join(segment_tokens)
            if not command_matches_any_rule(segment_command, allow_rules):
                return True, REASON_CHAIN

    segment_tokens = segments[0] if segments else []

    if _hook.has_heredoc(segment_tokens):
        return True, REASON_HEREDOC
    if _hook.has_process_substitution(segment_tokens):
        return True, REASON_PROCESS_SUBSTITUTION
    if _hook.has_command_substitution(segment_tokens):
        return True, REASON_COMMAND_SUBSTITUTION

    stripped = _hook.strip_env_prefix(_hook.strip_cd_prefix(segment_tokens))
    if stripped != _hook.strip_env_prefix(segment_tokens) and stripped and stripped != segment_tokens:
        if not command_matches_any_rule(command, allow_rules):
            return True, REASON_CD_PREFIX

    if command_matches_any_rule(command, allow_rules):
        return False, None

    return True, REASON_NO_RULE
