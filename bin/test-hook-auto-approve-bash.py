#!/usr/bin/env python3
"""
Standalone tests for hook-auto-approve-bash.py.

Run directly: python3 bin/test-hook-auto-approve-bash.py
Or via venv: ~/.claude/bin/venv-run.sh python bin/test-hook-auto-approve-bash.py

Covers the miss-patterns from issue #12 (cd-prefix, ;-chains, && chains
with echo/sleep/test, command substitution, env-var prefixes) plus the
quoting edge cases required by its acceptance criteria.
"""

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

HOOK_PATH = Path(__file__).parent / "hook-auto-approve-bash.py"

spec = importlib.util.spec_from_file_location("hook_auto_approve_bash", HOOK_PATH)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

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


def run_hook(command):
    """Run the hook as a subprocess with a synthetic PreToolUse payload."""
    payload = json.dumps({"tool_input": {"command": command}})
    result = subprocess.run(
        [sys.executable, str(HOOK_PATH)],
        input=payload,
        capture_output=True,
        text=True,
    )
    approved = False
    reason = None
    if result.stdout.strip():
        try:
            out = json.loads(result.stdout)
            decision = out.get("hookSpecificOutput", {}).get("permissionDecision")
            approved = decision == "allow"
            reason = out.get("hookSpecificOutput", {}).get("permissionDecisionReason")
        except json.JSONDecodeError:
            pass
    return approved, reason, result.returncode


# --- split_segments (unit-level) ---

check(
    "split_segments: simple && chain",
    hook.split_segments("git status && git log") == [["git", "status"], ["git", "log"]],
)

check(
    "split_segments: ; chain",
    hook.split_segments("echo hi; git status") == [["echo", "hi"], ["git", "status"]],
)

check(
    "split_segments: pipe",
    hook.split_segments("git log | head -5") == [["git", "log"], ["head", "-5"]],
)

check(
    "split_segments: quoted separator is not a split point",
    hook.split_segments('echo "a && b"') == [["echo", "a && b"]],
)

check(
    "split_segments: || chain",
    hook.split_segments("git status || echo fail") == [["git", "status"], ["echo", "fail"]],
)

try:
    hook.split_segments("echo 'unterminated")
    check("split_segments: unterminated quote raises ValueError", False)
except ValueError:
    check("split_segments: unterminated quote raises ValueError", True)

# --- has_command_substitution ---

check(
    "has_command_substitution: $(...) detected",
    hook.has_command_substitution(hook.split_segments("echo $(cat /etc/passwd)")[0]),
)

check(
    "has_command_substitution: backtick detected",
    hook.has_command_substitution(hook.split_segments("echo `whoami`")[0]),
)

check(
    "has_command_substitution: plain segment is clean",
    not hook.has_command_substitution(hook.split_segments("git status")[0]),
)

check(
    "has_command_substitution: git commit with quoted $ in message not flagged as bare token",
    not hook.has_command_substitution(hook.split_segments('git commit -m "price is 5 dollars"')[0]),
)

# --- strip_env_prefix ---

check(
    "strip_env_prefix: single VAR=value prefix stripped",
    hook.strip_env_prefix(["FOO=bar", "git", "status"]) == ["git", "status"],
)

check(
    "strip_env_prefix: multiple VAR=value prefixes stripped",
    hook.strip_env_prefix(["FOO=bar", "BAZ=qux", "git", "status"]) == ["git", "status"],
)

check(
    "strip_env_prefix: no prefix is a no-op",
    hook.strip_env_prefix(["git", "status"]) == ["git", "status"],
)

check(
    "strip_env_prefix: all-assignment segment reduces to empty",
    hook.strip_env_prefix(["FOO=bar"]) == [],
)

# --- strip_cd_prefix ---

check(
    "strip_cd_prefix: cd into ~/Projects subdir is stripped",
    hook.strip_cd_prefix(["cd", os.path.expanduser("~/Projects/acme-webshop"), "git", "status"])
    == ["git", "status"],
)

check(
    "strip_cd_prefix: cd into /etc is NOT stripped (leaves cd as first token)",
    hook.strip_cd_prefix(["cd", "/etc", "rm", "-rf", "/"])
    == ["cd", "/etc", "rm", "-rf", "/"],
)

check(
    "strip_cd_prefix: cd into ~ (home, not Projects) is NOT stripped",
    hook.strip_cd_prefix(["cd", "~", "git", "status"])
    == ["cd", "~", "git", "status"],
)

check(
    "strip_cd_prefix: no cd is a no-op",
    hook.strip_cd_prefix(["git", "status"]) == ["git", "status"],
)

print(f"\nResults: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
