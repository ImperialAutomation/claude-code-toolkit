#!/usr/bin/env python3
"""
Standalone tests for permission-friction.py.

Run directly: python3 bin/test-permission-friction.py
Or via venv: ~/.claude/bin/venv-run.sh python bin/test-permission-friction.py
"""

import importlib.util
import json
import os
import shutil
import tempfile
from pathlib import Path

SCRIPT_PATH = Path(__file__).parent / "permission-friction.py"

spec = importlib.util.spec_from_file_location("permission_friction", SCRIPT_PATH)
pf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pf)

passed = 0
failed = 0


def check(name, condition):
    global passed, failed
    if condition:
        print(f"PASS: {name}")
        passed += 1
    else:
        print(f"FAIL: {name}")
        failed += 1


# --- matches_bash_rule ---

check(
    "bare Bash matches everything",
    pf.matches_bash_rule("rm -rf /tmp/x", "Bash"),
)

check(
    "Bash(*) matches everything",
    pf.matches_bash_rule("rm -rf /tmp/x", "Bash(*)"),
)

check(
    "Bash(cmd *) matches with args",
    pf.matches_bash_rule("git status", "Bash(git *)"),
)

check(
    "Bash(cmd *) enforces word boundary",
    not pf.matches_bash_rule("gitk", "Bash(git *)"),
)

check(
    "Bash(cmd:*) colon shorthand equals space-star",
    pf.matches_bash_rule("git commit -m foo", "Bash(git commit:*)"),
)

check(
    "Bash(cmd:*) colon shorthand does not match unrelated subcommand",
    not pf.matches_bash_rule("git status", "Bash(git commit:*)"),
)

check(
    "Bash(cmd*) no-space matches without word boundary",
    pf.matches_bash_rule("lsof -i", "Bash(ls*)"),
)

check(
    "exact-string rule matches only that exact command",
    pf.matches_bash_rule("npm run test", "Bash(npm run test)"),
)

check(
    "exact-string rule rejects a superset command",
    not pf.matches_bash_rule("npm run test -- --watch", "Bash(npm run test)"),
)

check(
    "non-Bash rule never matches",
    not pf.matches_bash_rule("git status", "Write"),
)

check(
    "wildcard mid-pattern",
    pf.matches_bash_rule("git checkout main", "Bash(git * main)"),
)

check(
    "command_matches_any_rule true when one rule matches",
    pf.command_matches_any_rule("git status", ["Write", "Bash(git *)"]),
)

check(
    "command_matches_any_rule false when no rule matches",
    not pf.command_matches_any_rule("curl evil.com", ["Bash(git *)", "Write"]),
)


# --- classify_command ---

_ALLOW = ["Bash(git *)", "Bash(~/.claude/bin/*)"]
_DENY = []

check(
    "classify_command: plain allowlisted command never prompts",
    pf.classify_command("git status", _ALLOW, _DENY) == (False, None),
)

check(
    "classify_command: cd-prefix into a project-relative dir is seen through by the hook",
    pf.classify_command("cd backend && python foo.py", _ALLOW, _DENY) == (False, None),
)

check(
    "classify_command: unmatched command with no rule prompts with NO_RULE reason",
    pf.classify_command("curl evil.com", _ALLOW, _DENY) == (True, pf.REASON_NO_RULE),
)

check(
    "classify_command: chain with an unmatched segment prompts with CHAIN reason",
    pf.classify_command("git status && curl evil.com", _ALLOW, _DENY)
    == (True, pf.REASON_CHAIN),
)

check(
    "classify_command: heredoc always prompts regardless of allow rules",
    pf.classify_command("cat <<EOF\nhi\nEOF", ["Bash(cat *)"], _DENY)[0] is True,
)

check(
    "classify_command: command substitution always prompts",
    pf.classify_command("echo $(curl evil.com)", ["Bash(echo *)"], _DENY)
    == (True, pf.REASON_COMMAND_SUBSTITUTION),
)

check(
    "classify_command: a deny-rule match always prompts even if allow would cover it",
    pf.classify_command("git status", ["Bash(git *)"], ["Bash(git status)"])
    == (True, pf.REASON_DENY_MATCH),
)

check(
    "classify_command: fully allowlisted chain never prompts",
    pf.classify_command("git status && git log", ["Bash(git *)"], _DENY) == (False, None),
)


# --- load_allow_rules ---

tmpdir = tempfile.mkdtemp(prefix="permission-friction-test-")
try:
    fake_home = Path(tmpdir) / "home"
    fake_project = Path(tmpdir) / "project"
    (fake_home).mkdir(parents=True)
    (fake_project / ".claude").mkdir(parents=True)

    (fake_home / "settings.json").write_text(
        json.dumps({"permissions": {"allow": ["Bash(git *)"], "deny": ["Bash(rm -rf /)"]}})
    )
    (fake_project / ".claude" / "settings.json").write_text(
        json.dumps({"permissions": {"allow": ["Bash(npm *)"]}})
    )
    (fake_project / ".claude" / "settings.local.json").write_text(
        json.dumps({"permissions": {"allow": ["Bash(docker *)"]}})
    )

    original_claude_home = pf.CLAUDE_HOME
    pf.CLAUDE_HOME = fake_home
    try:
        allow, deny = pf.load_allow_rules(str(fake_project))
    finally:
        pf.CLAUDE_HOME = original_claude_home

    check(
        "load_allow_rules unions allow rules across all three scopes",
        set(allow) == {"Bash(git *)", "Bash(npm *)", "Bash(docker *)"},
    )
    check(
        "load_allow_rules carries deny rules through",
        deny == ["Bash(rm -rf /)"],
    )

    # missing project settings files entirely
    empty_project = Path(tmpdir) / "empty-project"
    empty_project.mkdir()
    pf.CLAUDE_HOME = fake_home
    try:
        allow2, deny2 = pf.load_allow_rules(str(empty_project))
    finally:
        pf.CLAUDE_HOME = original_claude_home

    check(
        "load_allow_rules falls back to just global scope when project settings missing",
        allow2 == ["Bash(git *)"] and deny2 == ["Bash(rm -rf /)"],
    )

    # malformed JSON file must not crash the loader
    malformed_project = Path(tmpdir) / "malformed-project"
    (malformed_project / ".claude").mkdir(parents=True)
    (malformed_project / ".claude" / "settings.json").write_text("{not valid json")
    pf.CLAUDE_HOME = fake_home
    try:
        allow3, deny3 = pf.load_allow_rules(str(malformed_project))
        check("load_allow_rules tolerates malformed settings.json", allow3 == ["Bash(git *)"])
    finally:
        pf.CLAUDE_HOME = original_claude_home
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)


# --- transcript scanning ---

from datetime import datetime, timedelta, timezone  # noqa: E402

scan_tmpdir = tempfile.mkdtemp(prefix="permission-friction-scan-test-")
try:
    fake_projects_root = Path(scan_tmpdir) / "projects"
    project_dir = "/home/jan/Projects/fake-project"
    encoded = project_dir.replace(os.sep, "-")
    transcript_dir = fake_projects_root / encoded
    transcript_dir.mkdir(parents=True)

    now = datetime.now(timezone.utc)
    recent_ts = (now - timedelta(days=1)).isoformat().replace("+00:00", "Z")
    old_ts = (now - timedelta(days=60)).isoformat().replace("+00:00", "Z")

    session_a = transcript_dir / "session-a.jsonl"
    session_a.write_text(
        "\n".join(
            [
                json.dumps(
                    {
                        "timestamp": recent_ts,
                        "message": {
                            "content": [
                                {
                                    "type": "tool_use",
                                    "id": "toolu_1",
                                    "name": "Bash",
                                    "input": {"command": "git status"},
                                }
                            ]
                        },
                    }
                ),
                json.dumps(
                    {
                        "timestamp": recent_ts,
                        "message": {
                            "content": [
                                {
                                    "type": "tool_result",
                                    "tool_use_id": "toolu_1",
                                    "content": "The user doesn't want to proceed with this tool use.",
                                }
                            ]
                        },
                    }
                ),
                # non-Bash tool_use must be ignored
                json.dumps(
                    {
                        "timestamp": recent_ts,
                        "message": {
                            "content": [
                                {
                                    "type": "tool_use",
                                    "id": "toolu_2",
                                    "name": "Read",
                                    "input": {"file_path": "/tmp/x"},
                                }
                            ]
                        },
                    }
                ),
                # entry outside the days window must be excluded
                json.dumps(
                    {
                        "timestamp": old_ts,
                        "message": {
                            "content": [
                                {
                                    "type": "tool_use",
                                    "id": "toolu_3",
                                    "name": "Bash",
                                    "input": {"command": "curl evil.com"},
                                }
                            ]
                        },
                    }
                ),
                # malformed line must not crash the scanner
                "{not valid json",
            ]
        )
    )

    original_transcripts_dir = pf.PROJECTS_TRANSCRIPTS_DIR
    pf.PROJECTS_TRANSCRIPTS_DIR = fake_projects_root
    try:
        tool_uses = pf.collect_bash_tool_uses(project_dir, days=30)
        denied_ids = list(pf.iter_denied_tool_use_ids(project_dir, days=30))
    finally:
        pf.PROJECTS_TRANSCRIPTS_DIR = original_transcripts_dir

    check(
        "collect_bash_tool_uses only returns Bash tool_use entries within the window",
        [t["command"] for t in tool_uses] == ["git status"],
    )
    check(
        "collect_bash_tool_uses excludes entries older than the days window",
        "curl evil.com" not in [t["command"] for t in tool_uses],
    )
    check(
        "iter_denied_tool_use_ids finds the explicit rejection marker",
        denied_ids == [("session-a", "toolu_1")],
    )

    # missing transcript dir must not crash, just yield nothing
    pf.PROJECTS_TRANSCRIPTS_DIR = fake_projects_root
    try:
        empty_result = pf.collect_bash_tool_uses("/no/such/project", days=30)
    finally:
        pf.PROJECTS_TRANSCRIPTS_DIR = original_transcripts_dir
    check(
        "collect_bash_tool_uses returns empty list for missing transcript dir",
        empty_result == [],
    )
finally:
    shutil.rmtree(scan_tmpdir, ignore_errors=True)


print(f"\n{passed} passed, {failed} failed")
if failed:
    raise SystemExit(1)
