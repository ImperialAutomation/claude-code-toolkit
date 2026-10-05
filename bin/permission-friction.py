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

Attribution: friction in a compound command is attributed to the SEGMENT that
defeats matching, not the command's first token. `grep ... | head; sed ...`
prompts because of `sed`; `grep` and `head` are both already approved, so a
report blaming `grep` sends the remedy to a command that never prompted.

Three things can cover a segment, and all are consulted: the auto-approve
hook's own safety logic, an allow rule matching the segment alone, and an
opted-in rewriting-hook prefix (--rewrite-prefix).

Hook denies (`sed -n 'X,Yp' <file>`, inline Python that opens a file, an
until+sleep file wait loop) are reported in their own bucket and excluded from
the prompted estimate: a deny shows no prompt at all. It is the opposite
signal — a native tool exists — and the remedy is that tool, not an allowlist
entry.

Rewriting hooks: a PreToolUse hook may rewrite a command and allow it in one
response, so a command no allow rule covers never prompts. Verified against
rtk 0.45.0: fed `grep -rn foo src` it answers permissionDecision "allow" with
updatedInput.command = "rtk grep -rn foo src". The transcript nevertheless
stores what the MODEL emitted — the rewrite lives in the hook's response and
is never written back to tool_use.input. Measured over ~21k real transcript
Bash calls: 516 start with `rtk`, dominated by `rtk proxy` (243) and `rtk
grep` (222), and `rtk proxy` is RTK's own documented escape hatch, a form no
rewrite produces. Those are commands the model typed itself, i.e. real
friction — so prefixed commands count as friction BY DEFAULT. Pass
--rewrite-prefix to opt out per tool. Only the prefixed form is modelled:
rtk answers "allow" for `grep` but rewrites `jq`/`curl` with no
permissionDecision at all, so per-command coverage is not derivable from the
prefix.
"""

import argparse
import fnmatch
import importlib.util
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

_HOOK_PATH = Path(__file__).parent / "hook-auto-approve-bash.py"
_spec = importlib.util.spec_from_file_location("hook_auto_approve_bash", _HOOK_PATH)
_hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_hook)

CLAUDE_HOME = Path(os.path.expanduser("~/.claude"))
PROJECTS_TRANSCRIPTS_DIR = CLAUDE_HOME / "projects"

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

# Commands hook-auto-approve-bash.py DENIES. A deny is not friction: no prompt
# is ever shown, so counting these as "prompted" overstates the estimate and
# points /retro at the wrong remedy. They are the opposite signal — the agent
# reached for a shell command where a native tool exists — and the fix is to
# use that tool, never an allowlist entry. Reported separately for that reason.
REASON_HOOK_DENY_SED_READ = "denied by hook: sed used as a file reader"
REASON_HOOK_DENY_PYTHON_READ = "denied by hook: inline Python opens a file"
REASON_HOOK_DENY_WAIT_LOOP = "denied by hook: until+sleep wait loop on a file"
REASON_HOOK_DENY_CD_CHAIN = "denied by hook: cd-prefixed chain (use env -C / git -C)"

HOOK_DENY_REASONS = (
    REASON_HOOK_DENY_SED_READ,
    REASON_HOOK_DENY_PYTHON_READ,
    REASON_HOOK_DENY_WAIT_LOOP,
    REASON_HOOK_DENY_CD_CHAIN,
)


# --- rewriting PreToolUse hooks ------------------------------------------------
# A PreToolUse hook may REWRITE a command and allow it in the same response,
# which makes a command that no allow rule covers never prompt. RTK's hook does
# exactly this: fed `grep -rn foo src` it answers permissionDecision "allow"
# with updatedInput.command = "rtk grep -rn foo src" (verified against the
# installed rtk 0.45.0).
#
# What the transcript stores: the command the MODEL emitted, NOT the rewrite.
# The rewrite is in the hook's RESPONSE (updatedInput), which is never written
# back to the tool_use input. Measured over ~21k real transcript Bash calls:
# 516 entries start with `rtk`, dominated by `rtk proxy` (243) and `rtk grep`
# (222) — `rtk proxy` is RTK's own documented escape hatch, a form no rewrite
# ever produces. So those are commands the model typed itself, i.e. REAL
# friction, and an `rtk`-prefixed segment is NOT treated as covered by default.
#
# Opting in with --rewrite-prefix marks the PREFIXED form (`rtk <cmd>`) as
# covered — that is the form the hook emits, and the one a user would allowlist
# as `Bash(rtk *)`. A BARE command is deliberately not assumed covered: rtk
# answers "allow" for `grep` but rewrites `jq`/`curl` with no permissionDecision
# at all, so matching still runs on the rewritten command and may still prompt.
# Which commands get the allow is the tool's internal business and not derivable
# from the prefix, so only the half that is verifiable is modelled. Configurable
# rather than hard-coded to one tool, since any rewriting hook has this shape.
DEFAULT_REWRITE_PREFIXES = ()


def _is_rewrite_covered(segment_tokens, rewrite_prefixes):
    """True if a rewriting hook in `rewrite_prefixes` would allow this segment.

    Matches the prefixed form only (`rtk grep ...`) — see the note above on why
    a bare wrapped command is not assumed covered. An empty `rewrite_prefixes`
    disables this entirely.
    """
    if not rewrite_prefixes:
        return False

    stripped = _hook.strip_env_prefix(_hook.strip_cd_prefix(segment_tokens))
    if not stripped:
        return False

    return stripped[0] in rewrite_prefixes


def is_hook_denied(command):
    """Return the REASON_HOOK_DENY_* constant for `command`, or None.

    Mirrors hook-auto-approve-bash.py's deny branches in the same order the
    hook itself evaluates them, so the category a command lands in here is
    the message the agent actually saw.
    """
    if _hook.command_has_sed_file_read(command):
        return REASON_HOOK_DENY_SED_READ
    if _hook.command_has_python_file_read(command):
        return REASON_HOOK_DENY_PYTHON_READ
    if _hook.command_has_until_sleep_wait_loop(command):
        return REASON_HOOK_DENY_WAIT_LOOP
    # Last, matching main()'s own branch order: a command that is both a
    # cd-chain and, say, a sed read must report the sed deny, because that is
    # the message the hook emitted. Not the same check as REASON_CD_PREFIX
    # below, which covers the single-segment `cd <dir> <cmd>` form the hook's
    # chain check cannot see (it needs a segment boundary).
    if _hook.command_has_cd_prefix_chain(command):
        return REASON_HOOK_DENY_CD_CHAIN
    return None


def _is_segment_covered(segment_tokens, allow_rules, rewrite_prefixes=()):
    """True if a chain segment would NOT, on its own, cause a prompt.

    Three independent things can cover a segment, and all must be consulted —
    checking only allow rules (as this code once did) reports a harmless
    leading `cd /home/jan/Projects/x` as the culprit, because no rule names
    `cd` even though the hook sees straight through it:

      1. hook-auto-approve-bash.py's `is_segment_safe` — the hook approves the
         whole command before permission matching ever runs, so a segment it
         accepts never reaches a prompt;
      2. an allow rule matching the segment on its own;
      3. a REWRITING hook named in `rewrite_prefixes` (see
         `DEFAULT_REWRITE_PREFIXES`), for a segment already carrying that
         hook's prefix.
    """
    if _hook.is_segment_safe(segment_tokens):
        return True
    if _is_rewrite_covered(segment_tokens, rewrite_prefixes):
        return True

    # An allow rule is glob-matched against the segment's RAW text, so
    # `Bash(grep *)` matches `grep -n $(cat f) x`. That match is meaningless
    # here: the hook refuses a segment carrying substitution or a heredoc, and
    # permission matching does not see through one either, so the command does
    # reach a prompt. Treating the glob hit as coverage would silently drop it
    # from the report.
    if (
        _hook.has_command_substitution(segment_tokens)
        or _hook.has_process_substitution(segment_tokens)
        or _hook.has_heredoc(segment_tokens)
    ):
        return False

    return command_matches_any_rule(" ".join(segment_tokens), allow_rules)


def find_chain_culprit(segments, allow_rules, rewrite_prefixes=()):
    """Return the first segment in `segments` that nothing covers, or None.

    This is the segment that actually defeats permission matching, which is
    what a remedy has to address. The chain's first token is usually NOT it:
    `grep ... | head; sed ...` prompts because of `sed`, while `grep` and
    `head` are both already approved.
    """
    for segment_tokens in segments:
        if not _is_segment_covered(segment_tokens, allow_rules, rewrite_prefixes):
            return segment_tokens
    return None


def classify_command(command, allow_rules, deny_rules, rewrite_prefixes=DEFAULT_REWRITE_PREFIXES):
    """Classify whether `command` would trigger a permission prompt.

    Returns (would_prompt: bool, reason: str | None, culprit: list[str] | None).
    `reason` is None only when the command would NOT prompt. `culprit` is the
    offending segment's tokens for REASON_CHAIN, and None for every other
    reason — those name the whole command, so there is no sub-segment to
    attribute them to.

    Mirrors hook-auto-approve-bash.py's own safety logic first — a command
    that hook would silently approve never reaches a prompt in practice,
    regardless of raw rule coverage.

    A hook DENY is checked before anything else, because the hook runs before
    permission matching: once it denies, no prompt is shown and no allow or
    deny rule is ever consulted. Such a command returns would_prompt=False
    with a REASON_HOOK_DENY_* reason — reported, but not as friction.
    """
    hook_deny = is_hook_denied(command)
    if hook_deny is not None:
        return False, hook_deny, None

    if command_matches_any_rule(command, deny_rules):
        return True, REASON_DENY_MATCH, None

    if _hook.is_command_safe(command):
        return False, None, None

    try:
        segments = _hook.split_segments(command)
    except ValueError:
        return True, REASON_NO_RULE, None

    if len(segments) > 1:
        culprit = find_chain_culprit(segments, allow_rules, rewrite_prefixes)
        if culprit is not None:
            return True, REASON_CHAIN, culprit
        return False, None, None

    segment_tokens = segments[0] if segments else []

    if _is_rewrite_covered(segment_tokens, rewrite_prefixes):
        return False, None, None

    if _hook.has_heredoc(segment_tokens):
        return True, REASON_HEREDOC, None
    if _hook.has_process_substitution(segment_tokens):
        return True, REASON_PROCESS_SUBSTITUTION, None
    if _hook.has_command_substitution(segment_tokens):
        return True, REASON_COMMAND_SUBSTITUTION, None

    stripped = _hook.strip_env_prefix(_hook.strip_cd_prefix(segment_tokens))
    if stripped != _hook.strip_env_prefix(segment_tokens) and stripped and stripped != segment_tokens:
        if not command_matches_any_rule(command, allow_rules):
            return True, REASON_CD_PREFIX, None

    if command_matches_any_rule(command, allow_rules):
        return False, None, None

    return True, REASON_NO_RULE, None


def _encode_project_dir(project_dir):
    """Mirror Claude Code's transcript-directory naming: absolute path with
    every "/" replaced by "-"."""
    return str(Path(project_dir).resolve()).replace(os.sep, "-")


def _transcript_dir_for(project_dir):
    return PROJECTS_TRANSCRIPTS_DIR / _encode_project_dir(project_dir)


def _parse_timestamp(value):
    """Parse a transcript ISO-8601 timestamp ("...Z") to a comparable
    value, or None if missing/malformed."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _cutoff(days):
    return datetime.now(timezone.utc) - timedelta(days=days)


def iter_transcript_events(project_dir, days=30):
    """Yield (session_id, timestamp, message_content_list) for every
    transcript line within the last `days` days that carries a message
    with list-shaped content (tool_use/tool_result entries live there).

    Silently yields nothing if the transcript directory doesn't exist or
    contains no matching files — scanning transcripts is best-effort, not
    a hard requirement.
    """
    transcript_dir = _transcript_dir_for(project_dir)
    if not transcript_dir.is_dir():
        return

    cutoff = _cutoff(days)

    for jsonl_path in sorted(transcript_dir.glob("*.jsonl")):
        session_id = jsonl_path.stem
        try:
            lines = jsonl_path.read_text().splitlines()
        except OSError:
            continue

        for line in lines:
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            ts = _parse_timestamp(obj.get("timestamp"))
            if ts is not None and ts < cutoff:
                continue

            message = obj.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content")
            if not isinstance(content, list):
                continue

            yield session_id, ts, content


def iter_denied_tool_use_ids(project_dir, days=30):
    """Yield (session_id, tool_use_id) for every tool_result whose content
    carries the explicit user-rejection marker. This is the only reliable
    transcript signal for a denial — Claude Code does not log a distinct
    event for "prompt shown and approved.\""""
    for session_id, _ts, content in iter_transcript_events(project_dir, days):
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            block_content = block.get("content")
            text = block_content if isinstance(block_content, str) else json.dumps(block_content)
            if REJECTION_MARKER in text:
                tool_use_id = block.get("tool_use_id")
                if tool_use_id:
                    yield session_id, tool_use_id


def collect_bash_tool_uses(project_dir, days=30):
    """Return a list of dicts {session_id, tool_use_id, command} for every
    Bash tool_use in the scanned window, keyed so denials can be joined
    back to the command that was denied."""
    results = []
    for session_id, _ts, content in iter_transcript_events(project_dir, days):
        for block in content:
            if (
                isinstance(block, dict)
                and block.get("type") == "tool_use"
                and block.get("name") == "Bash"
            ):
                command = block.get("input", {}).get("command")
                tool_use_id = block.get("id")
                if command:
                    results.append(
                        {
                            "session_id": session_id,
                            "tool_use_id": tool_use_id,
                            "command": command,
                        }
                    )
    return results


def _culprit_token(culprit_tokens):
    """The token a remedy for `culprit_tokens` would have to name.

    Strips the cd/env prefixes first: `cd /x && rtk grep ...` must group under
    `rtk`, not `cd`, since an allow rule or wrapper targets the real command.
    """
    stripped = _hook.strip_env_prefix(_hook.strip_cd_prefix(culprit_tokens))
    tokens = stripped or culprit_tokens
    return tokens[0] if tokens else ""


def _pattern_key(command, reason, culprit=None):
    """Normalize a command into a grouping key for the report: a command token
    plus the friction reason, e.g. "curl (no allow rule covers this command)".

    Which token depends on the reason. For a chain it is the CULPRIT segment's
    first token — grouping chain friction under the command's own first token
    names a command that is usually already approved (`grep ... | head; sed ...`
    is a `sed` problem, not a `grep` one), so /retro proposes a remedy for a
    command that never prompted. For every other reason the whole command is
    the subject, so its first token is the right key.
    """
    if culprit is not None:
        key_token = _culprit_token(culprit)
    else:
        key_token = command.strip().split(" ", 1)[0] if command.strip() else command
    return f"{key_token} — {reason}"


def analyze_friction(project_dir, days=30, rewrite_prefixes=DEFAULT_REWRITE_PREFIXES):
    """Scan `project_dir`'s transcripts and return a friction report dict:

    {
      "total_calls": int,
      "prompted_estimate": int,
      "denied": int,
      "patterns": [
        {"pattern": str, "count": int, "sessions": int, "example": str},
        ...
      ],
    }

    Patterns are sorted by call count descending. `sessions` counts the
    number of distinct sessions a pattern appeared in — the basis for the
    "seen in >= 2 sessions" recurring-pattern rule used by /retro.
    """
    allow_rules, deny_rules = load_allow_rules(project_dir)
    tool_uses = collect_bash_tool_uses(project_dir, days)
    denied_tool_use_ids = {tid for _sid, tid in iter_denied_tool_use_ids(project_dir, days)}

    pattern_counts = {}
    pattern_sessions = {}
    pattern_examples = {}
    pattern_culprits = {}
    hook_denied_counts = {}
    hook_denied_examples = {}
    denied = 0

    for entry in tool_uses:
        command = entry["command"]
        session_id = entry["session_id"]

        if entry["tool_use_id"] in denied_tool_use_ids:
            denied += 1

        would_prompt, reason, culprit = classify_command(
            command, allow_rules, deny_rules, rewrite_prefixes
        )

        if reason in HOOK_DENY_REASONS:
            hook_denied_counts[reason] = hook_denied_counts.get(reason, 0) + 1
            hook_denied_examples.setdefault(reason, command)
            continue

        if not would_prompt:
            continue

        key = _pattern_key(command, reason, culprit)
        pattern_counts[key] = pattern_counts.get(key, 0) + 1
        pattern_sessions.setdefault(key, set()).add(session_id)
        pattern_examples.setdefault(key, command)
        if culprit is not None:
            pattern_culprits.setdefault(key, culprit)

    patterns = []
    for key, count in pattern_counts.items():
        row = {
            "pattern": key,
            "count": count,
            "sessions": len(pattern_sessions[key]),
            "example": pattern_examples[key],
        }
        culprit_tokens = pattern_culprits.get(key)
        if culprit_tokens is not None:
            # Both halves are useful to a consumer: the token a remedy would
            # name, and the segment verbatim so the full `example` chain does
            # not have to be re-parsed to see what actually prompted.
            row["culprit"] = _culprit_token(culprit_tokens)
            row["culprit_example"] = " ".join(culprit_tokens)
        patterns.append(row)
    patterns.sort(key=lambda p: p["count"], reverse=True)

    hook_denied = [
        {
            "reason": reason,
            "count": count,
            "example": hook_denied_examples[reason],
        }
        for reason, count in hook_denied_counts.items()
    ]
    hook_denied.sort(key=lambda d: d["count"], reverse=True)

    return {
        "total_calls": len(tool_uses),
        "prompted_estimate": sum(p["count"] for p in patterns),
        "denied": denied,
        "hook_denied": hook_denied,
        "patterns": patterns,
    }


def format_report_text(report, days):
    lines = [
        f"Permission friction report (last {days} days)",
        f"  Total Bash calls:        {report['total_calls']}",
        f"  Estimated prompted:      {report['prompted_estimate']}",
        f"  Explicit denials:        {report['denied']}",
    ]

    if report["patterns"]:
        lines.append("")
        lines.append("  Top prompt-causing patterns:")
        for p in report["patterns"][:10]:
            recurring = " [recurring: seen in >= 2 sessions]" if p["sessions"] >= 2 else ""
            lines.append(
                f"    {p['count']:>3}x  {p['pattern']}  (sessions: {p['sessions']}){recurring}"
            )
            if p.get("culprit_example"):
                lines.append(f"           culprit: {p['culprit_example']}")
            lines.append(f"           e.g. {p['example']}")
    else:
        lines.append("")
        lines.append("  No prompt-causing patterns found.")

    if report.get("hook_denied"):
        lines.append("")
        lines.append("  Denied by hook (no prompt shown — use the native tool instead):")
        for d in report["hook_denied"]:
            lines.append(f"    {d['count']:>3}x  {d['reason']}")
            lines.append(f"           e.g. {d['example']}")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Scan Claude Code session transcripts for permission friction.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                        Scan the current project, last 30 days
  %(prog)s /path/to/project       Scan a specific project directory
  %(prog)s --days 7               Narrow the scan window
  %(prog)s --json                 Output as JSON
  %(prog)s --rewrite-prefix rtk   Don't count commands a rewriting hook allows
        """,
    )
    parser.add_argument(
        "project_dir",
        nargs="?",
        default=os.getcwd(),
        help="Project root directory (default: current directory)",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=30,
        help="How many days of transcript history to scan (default: 30)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Output in JSON format",
    )
    parser.add_argument(
        "--rewrite-prefix",
        action="append",
        default=[],
        dest="rewrite_prefixes",
        metavar="CMD",
        help=(
            "Treat a segment starting with CMD as already covered, for a "
            "PreToolUse hook that rewrites commands to that prefix and allows "
            "them (e.g. --rewrite-prefix rtk). Repeatable. Off by default: the "
            "transcript records what the model emitted, so a prefixed command "
            "there is one the model typed itself and is real friction."
        ),
    )

    args = parser.parse_args()

    report = analyze_friction(
        args.project_dir, args.days, tuple(args.rewrite_prefixes)
    )

    if args.json_output:
        print(json.dumps(report, indent=2))
    else:
        print(format_report_text(report, args.days))

    return 0


if __name__ == "__main__":
    sys.exit(main())
