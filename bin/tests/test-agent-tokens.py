#!/usr/bin/env python3
"""
Standalone tests for agent-tokens.py.

Run directly: python3 bin/tests/test-agent-tokens.py

Hermetic: transcripts are small synthetic fixtures under a temp $HOME. No real
transcript is read.

When adding a case, check it actually constrains the script: break the rule
in agent-tokens.py, confirm THIS test goes red, then revert.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "agent-tokens.py"

spec = importlib.util.spec_from_file_location("agent_tokens", SCRIPT_PATH)
at = importlib.util.module_from_spec(spec)
spec.loader.exec_module(at)

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


# --- fixtures -----------------------------------------------------------------

OPUS = "claude-opus-5-5"
SONNET = "claude-sonnet-5-5"


def line(msg_id, usage, model=OPUS):
    """One assistant transcript line; usage = (input, cache write, cache read, output)."""
    i, cw, cr, o = usage
    return {
        "type": "assistant",
        "message": {
            "id": msg_id,
            "model": model,
            "role": "assistant",
            "usage": {
                "input_tokens": i,
                "cache_creation_input_tokens": cw,
                "cache_read_input_tokens": cr,
                "output_tokens": o,
            },
        },
    }


def agent(session_dir, agent_id, lines, parent=None, depth=1, meta=True):
    sub = session_dir / "subagents"
    sub.mkdir(parents=True, exist_ok=True)
    text = "\n".join(l if isinstance(l, str) else json.dumps(l) for l in lines) + "\n"
    (sub / f"agent-{agent_id}.jsonl").write_text(text)
    if meta:
        m = {"agentType": "general-purpose", "spawnDepth": depth}
        if parent:
            m["parentAgentId"] = parent
        (sub / f"agent-{agent_id}.meta.json").write_text(json.dumps(m))


tmp = tempfile.TemporaryDirectory()
HOME = Path(tmp.name) / "home"
PROJECTS = HOME / ".claude" / "projects"
S1 = PROJECTS / "-proj-a" / "sess1"
S2 = PROJECTS / "-proj-b" / "sess2"

# Main session transcript: never counted.
S1.parent.mkdir(parents=True)
(S1.parent / "sess1.jsonl").write_text(json.dumps(line("main1", (9, 9, 9, 9))) + "\n")

# Tree under root: root -> child -> grandchild (depth 3), plus a second child.
agent(S1, "root", [
    line("m1", (1, 100, 1000, 10)),
    line("m1", (1, 100, 1000, 10)),  # same message on several lines
    line("m1", (1, 100, 1000, 10)),
    {"type": "user", "message": {"role": "user", "content": "hi"}},
    "{not json",
    line("m2", (2, 200, 2000, 20)),
])
agent(S1, "child", [line("m3", (3, 300, 3000, 30), SONNET), line("m3", (3, 300, 3000, 30), SONNET)],
      parent="root", depth=2)
agent(S1, "grand", [line("m4", (4, 400, 4000, 40))], parent="child", depth=3)
agent(S1, "child2", [line("m5", (5, 500, 5000, 50))], parent="root", depth=2)
# Siblings outside the tree, same session directory.
agent(S1, "sibling", [line("m6", (1000, 1000, 1000, 1000))])
agent(S1, "nephew", [line("m7", (1000, 1000, 1000, 1000))], parent="sibling", depth=2)
# An older agent without a meta file: no parent, not in the tree.
agent(S1, "nometa", [line("m8", (1000, 1000, 1000, 1000))], meta=False)

EXPECTED = {
    "input_tokens": 1 + 2 + 3 + 4 + 5,
    "cache_creation_input_tokens": 100 + 200 + 300 + 400 + 500,
    "cache_read_input_tokens": 1000 + 2000 + 3000 + 4000 + 5000,
    "output_tokens": 10 + 20 + 30 + 40 + 50,
}


def run(*args):
    env = dict(os.environ, HOME=str(HOME))
    return subprocess.run([sys.executable, str(SCRIPT_PATH), *args], env=env,
                          capture_output=True, text=True, stdin=subprocess.DEVNULL)


print("--- tree totals ---")
r = run("--agent", "root", "--json")
check("found: exit 0", r.returncode == 0)
data = json.loads(r.stdout) if r.returncode == 0 else {}
check("totals match the hand-computed values (dedup on message.id)", data.get("totals") == EXPECTED)
check("agent count is the tree: root, child, grandchild, child2", data.get("agents") == 4)
check("models seen in the tree", data.get("models") == [OPUS, SONNET])
check("agent id echoed", data.get("agent_id") == "root")
check("summary in the report-line format",
      data.get("summary") == "in 0.0k / cw 1.5k / cr 15k / out 0.1k, 4 agents")

r = run("--agent", "child", "--json")
sub = json.loads(r.stdout) if r.returncode == 0 else {}
check("a subtree counts only itself and its descendants",
      sub.get("totals", {}).get("input_tokens") == 3 + 4 and sub.get("agents") == 2)

r = run("--agent", "root")
check("text output: exit 0", r.returncode == 0)
check("text output: one line per category",
      all(f"{k}" in r.stdout and str(v) in r.stdout for k, v in EXPECTED.items()))
check("text output: agent count and models", "agents" in r.stdout and SONNET in r.stdout)

print("--- humanized numbers ---")
check("42 -> 0.0k", at.human(42) == "0.0k")
check("14878 -> 15k", at.human(14878) == "15k")
check("94872 -> 95k", at.human(94872) == "95k")
check("1470008 -> 1.47M", at.human(1470008) == "1.47M")
check("issue example summary",
      at.summary({"input_tokens": 42, "cache_creation_input_tokens": 94872,
                  "cache_read_input_tokens": 1470008, "output_tokens": 14878}, 3)
      == "in 0.0k / cw 95k / cr 1.47M / out 15k, 3 agents")
check("one agent is singular", at.summary(EXPECTED, 1).endswith(", 1 agent"))

print("--- not found / ambiguous / unreadable ---")
r = run("--agent", "nosuch")
check("unknown id: exit 1", r.returncode == 1)
check("unknown id: says so on stderr", "nosuch" in r.stderr and r.stdout == "")

agent(S2, "dup", [line("d1", (1, 1, 1, 1))])
agent(S1, "dup", [line("d2", (1, 1, 1, 1))])
r = run("--agent", "dup")
check("id in two places: exit 2", r.returncode == 2)
check("id in two places: names both", str(S1) in r.stderr and str(S2) in r.stderr)

agent(S2, "broken", [])
(S2 / "subagents" / "agent-broken.jsonl").write_bytes(b"\xff\xfe not utf-8\n")
r = run("--agent", "broken")
check("unreadable root transcript: exit 2", r.returncode == 2)

agent(S2, "top", [line("t1", (1, 1, 1, 1))])
agent(S2, "kid", [], parent="top", depth=2)
(S2 / "subagents" / "agent-kid.jsonl").write_bytes(b"\xff\xfe not utf-8\n")
r = run("--agent", "top")
check("unreadable descendant transcript: exit 2", r.returncode == 2)

agent(S2, "top2", [line("t2", (1, 1, 1, 1))])
(S2 / "subagents" / "agent-odd.jsonl").write_text(json.dumps(line("o1", (1, 1, 1, 1))) + "\n")
(S2 / "subagents" / "agent-odd.meta.json").write_text("{broken")
r = run("--agent", "top2")
check("malformed meta in the session: exit 2 (tree undeterminable)", r.returncode == 2)

print("--- CLI ---")
r = run("--help")
check("--help exits 0", r.returncode == 0)
check("--help names the exit codes", "Exit codes" in r.stdout)
r = run()
check("no --agent: usage error exit 2", r.returncode == 2)

tmp.cleanup()

print(f"\nResults: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
