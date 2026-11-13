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

print("--- --sum ---")
PARTS = Path(tmp.name) / "parts"
PARTS.mkdir()
root_json = PARTS / "issue.json"
root_json.write_text(run("--agent", "root", "--json").stdout)
child2_json = PARTS / "review.json"
child2_json.write_text(run("--agent", "child2", "--json").stdout)
r = run("--sum", str(root_json), str(child2_json), "--json")
check("sum: exit 0", r.returncode == 0)
s = json.loads(r.stdout) if r.returncode == 0 else {}
check("sum: totals added per category",
      s.get("totals") == {c: EXPECTED[c] + v for c, v in
                          zip(at.CATEGORIES, (5, 500, 5000, 50))})
check("sum: agent counts added", s.get("agents") == 4 + 1)
check("sum: models merged", s.get("models") == [OPUS, SONNET])
check("sum: every measured root listed", s.get("agent_ids") == ["root", "child2"])
check("sum: summary recomputed", s.get("summary") == at.summary(s.get("totals", {}), 5))

sum_json = PARTS / "sum.json"
sum_json.write_text(r.stdout)
r = run("--sum", str(sum_json), str(root_json), "--json")
nested = json.loads(r.stdout) if r.returncode == 0 else {}
check("sum of a sum: exit 0, roots flattened",
      r.returncode == 0 and nested.get("agent_ids") == ["root", "child2", "root"])
check("sum of a sum: totals keep adding up",
      nested.get("totals", {}).get("input_tokens") == 2 * EXPECTED["input_tokens"] + 5)

r = run("--sum", str(root_json), "--json")
one = json.loads(r.stdout) if r.returncode == 0 else {}
check("sum of one part: its own totals", one.get("totals") == EXPECTED and one.get("agents") == 4)

r = run("--sum", str(root_json))
check("sum, text output: exit 0 and totals", r.returncode == 0 and str(EXPECTED["output_tokens"]) in r.stdout)

r = run("--sum", str(root_json), str(PARTS / "missing.json"), "--json")
check("sum with a missing file: exit 2, nothing on stdout", r.returncode == 2 and r.stdout == "")
bad = PARTS / "bad.json"
bad.write_text('{"totals": {"input_tokens": 1}, "agents": 1, "agent_id": "x"}')
r = run("--sum", str(root_json), str(bad), "--json")
check("sum with a malformed part: exit 2, names the file", r.returncode == 2 and "bad.json" in r.stderr)
r = run("--agent", "root", "--sum", str(root_json))
check("--agent and --sum together: usage error exit 2", r.returncode == 2)

print("--- --session (runner main transcript, #270) ---")
RUNNER = PROJECTS / "-proj-c"
RUNNER.mkdir(parents=True)


def at_time(entry, ts, sidechain=False):
    entry = dict(entry, timestamp=ts)
    if sidechain:
        entry["isSidechain"] = True
    return entry


(RUNNER / "runner1.jsonl").write_text("\n".join(json.dumps(e) for e in [
    at_time(line("r1", (1000, 1000, 1000, 1000)), "2026-11-11T09:59:59.999Z"),  # before the window
    at_time(line("r2", (1, 10, 100, 1)), "2026-11-11T10:00:00.000Z"),           # on the boundary
    at_time(line("r2", (1, 10, 100, 1)), "2026-11-11T10:00:01.000Z"),           # same message again
    at_time(line("r3", (500, 500, 500, 500)), "2026-11-11T10:30:00Z", sidechain=True),
    line("r5", (7, 7, 7, 7)),                                                   # no timestamp
    at_time(line("r4", (2, 20, 200, 2), SONNET), "2026-11-11T12:00:00Z"),
]) + "\n{partly written")
# The runner's sub-agents are measured with --agent; --session never adds them.
agent(RUNNER / "runner1", "spawned", [line("x1", (9000, 9000, 9000, 9000))])

r = run("--session", "runner1", "--since", "2026-11-11T10:00:00Z", "--json")
check("session with --since: exit 0", r.returncode == 0)
ses = json.loads(r.stdout) if r.returncode == 0 else {}
check("session with --since: only the window, each message.id once, no sidechain",
      ses.get("totals") == {"input_tokens": 3, "cache_creation_input_tokens": 30,
                            "cache_read_input_tokens": 300, "output_tokens": 3})
check("session: one agent, the session itself", ses.get("agents") == 1)
check("session: id echoed as agent_id", ses.get("agent_id") == "runner1")
check("session: models of the window", ses.get("models") == [OPUS, SONNET])
check("session: summary", ses.get("summary") == at.summary(ses.get("totals", {}), 1))

r = run("--session", "runner1", "--since", "2026-11-11T11:00:00+01:00", "--json")
off = json.loads(r.stdout) if r.returncode == 0 else {}
check("session: --since with an offset compares as UTC",
      off.get("totals", {}).get("input_tokens") == 3)

r = run("--session", "runner1", "--json")
whole = json.loads(r.stdout) if r.returncode == 0 else {}
check("session without --since: the whole main transcript, still no sidechain",
      whole.get("totals", {}).get("input_tokens") == 1000 + 1 + 7 + 2)

session_json = PARTS / "runner.json"
session_json.write_text(run("--session", "runner1", "--since", "2026-11-11T10:00:00Z", "--json").stdout)
r = run("--sum", str(session_json), str(child2_json), "--json")
check("session output is accepted by --sum",
      r.returncode == 0 and json.loads(r.stdout).get("agent_ids") == ["runner1", "child2"])

r = run("--session", "nosuch")
check("unknown session: exit 1", r.returncode == 1 and "nosuch" in r.stderr)
(PROJECTS / "-proj-b" / "runner1.jsonl").write_text("")
r = run("--session", "runner1")
check("session in two project dirs: exit 2", r.returncode == 2)
(PROJECTS / "-proj-b" / "runner1.jsonl").unlink()
r = run("--session", "runner1", "--since", "yesterday")
check("unparseable --since: exit 2", r.returncode == 2 and r.stdout == "")
r = run("--agent", "root", "--since", "2026-11-11T10:00:00Z")
check("--since without --session: exit 2", r.returncode == 2)
r = run("--agent", "root", "--session", "runner1")
check("--agent and --session together: exit 2", r.returncode == 2)
(PROJECTS / "-proj-b" / "badsess.jsonl").write_bytes(b"\xff\xfe not utf-8\n")
r = run("--session", "badsess")
check("unreadable session transcript: exit 2", r.returncode == 2)

print("--- CLI ---")
r = run("--help")
check("--help exits 0", r.returncode == 0)
check("--help names the exit codes", "Exit codes" in r.stdout)
r = run()
check("no --agent: usage error exit 2", r.returncode == 2)

tmp.cleanup()

print(f"\nResults: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
