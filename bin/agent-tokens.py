#!/usr/bin/env python3
"""
Token usage of one sub-agent and every agent it spawned, from the transcripts.

Usage:
  agent-tokens.py --agent <id> [--json]
  agent-tokens.py --sum <json-file>... [--json]

Finds ~/.claude/projects/*/*/subagents/agent-<id>.jsonl, takes the agents in
that session directory whose `parentAgentId` (in agent-<id>.meta.json) leads
back to <id>, and sums `message.usage` per category over all of them. One
message can sit on several transcript lines; each `message.id` counts once.

Output: one line per category, the agent count and the model(s) seen. With
--json one object: agent_id, totals (the four categories), agents, models and
summary, the short form the queue runner reports, e.g.
`in 0.0k / cw 95k / cr 1.47M / out 15k, 3 agents`.

The id is the `agentId: <id>` of the Agent tool result. The `subagent_tokens`
of a completion notice is roughly the final context size, not this.

An agent without a meta file has no parent. A meta file that does not parse
makes the tree undeterminable, so it is an error.

--sum adds up earlier --json outputs (of --agent or of --sum) into one, in
the same format: the totals and agent counts added, the models merged, and
`agent_ids` listing every measured root. The queue runner measures each
sub-agent it spawns on its own (issue, reviews, fix round) and sums them per
phase and for the whole issue. Only pass files that measured: a part whose
measurement failed is left out by the caller, never guessed here.

Exit codes:
  0  found, totals printed
  1  no transcript for <id>
  2  usage error, <id> found in more than one place, or a transcript or meta
     file of the session is unreadable; with --sum, a file that is missing or
     not --json output of this script
"""

import argparse
import json
import sys
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"
SUBAGENTS_DIR = "subagents"
TRANSCRIPT_PATTERN = "agent-{}.jsonl"
META_SUFFIX = ".meta.json"
PARENT_KEY = "parentAgentId"

CATEGORIES = (
    "input_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "output_tokens",
)
SHORT_NAMES = dict(zip(CATEGORIES, ("in", "cw", "cr", "out")))

EXIT_FOUND = 0
EXIT_NOT_FOUND = 1
EXIT_ERROR = 2


class Unreadable(Exception):
    pass


def human(n):
    """42 -> 0.0k, 14878 -> 15k, 1470008 -> 1.47M."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 10_000:
        return f"{n / 1000:.0f}k"
    return f"{n / 1000:.1f}k"


def summary(totals, agents):
    parts = " / ".join(f"{SHORT_NAMES[c]} {human(totals[c])}" for c in CATEGORIES)
    return f"{parts}, {agents} agent{'' if agents == 1 else 's'}"


def find_transcripts(agent_id, projects_dir=PROJECTS_DIR):
    return sorted(projects_dir.glob(f"*/*/{SUBAGENTS_DIR}/{TRANSCRIPT_PATTERN.format(agent_id)}"))


def agent_id_of(transcript):
    return transcript.name[len("agent-"):-len(".jsonl")]


def parents(subagents_dir):
    """agent id -> parent agent id (None for a top-level agent) for every
    transcript in the directory."""
    out = {}
    for transcript in subagents_dir.glob(TRANSCRIPT_PATTERN.format("*")):
        aid = agent_id_of(transcript)
        meta = transcript.with_name(f"agent-{aid}{META_SUFFIX}")
        if not meta.exists():
            out[aid] = None
            continue
        try:
            data = json.loads(meta.read_text())
        except (OSError, UnicodeDecodeError, ValueError) as exc:
            raise Unreadable(f"{meta}: {exc}") from exc
        out[aid] = data.get(PARENT_KEY) if isinstance(data, dict) else None
    return out


def tree(root, parent_of):
    """root and every agent whose parent chain leads to it."""
    members = {root}
    changed = True
    while changed:
        changed = False
        for aid, parent in parent_of.items():
            if aid not in members and parent in members:
                members.add(aid)
                changed = True
    return members


def usage_by_message(transcript):
    """message.id -> (model, usage) for every assistant line; the last line of
    a message wins."""
    try:
        text = transcript.read_text()
    except (OSError, UnicodeDecodeError) as exc:
        raise Unreadable(f"{transcript}: {exc}") from exc
    found = {}
    for raw in text.splitlines():
        try:
            entry = json.loads(raw)
        except ValueError:
            continue  # a partly written last line
        msg = entry.get("message") if isinstance(entry, dict) else None
        if not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict) or not msg.get("id"):
            continue
        found[msg["id"]] = (msg.get("model"), msg["usage"])
    return found


def measure(transcript):
    subagents_dir = transcript.parent
    root = agent_id_of(transcript)
    members = tree(root, parents(subagents_dir))
    messages = {}
    for aid in sorted(members):
        messages.update(usage_by_message(subagents_dir / TRANSCRIPT_PATTERN.format(aid)))
    totals = {c: 0 for c in CATEGORIES}
    models = set()
    for model, usage in messages.values():
        for c in CATEGORIES:
            totals[c] += int(usage.get(c) or 0)
        if model:
            models.add(model)
    return {
        "agent_id": root,
        "totals": totals,
        "agents": len(members),
        "models": sorted(models),
        "summary": summary(totals, len(members)),
    }


def roots_of(report):
    """The measured root ids of a --json output: agent_id of a measurement,
    agent_ids of a sum."""
    if "agent_ids" in report:
        return list(report["agent_ids"])
    return [report["agent_id"]]


def load_report(path):
    """One --json output, validated; raises Unreadable when it is not one."""
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise Unreadable(f"{path}: {exc}") from exc
    totals = data.get("totals") if isinstance(data, dict) else None
    valid = (
        isinstance(totals, dict)
        and all(isinstance(totals.get(c), int) for c in CATEGORIES)
        and isinstance(data.get("agents"), int)
        and isinstance(data.get("models", []), list)
        and ("agent_id" in data or isinstance(data.get("agent_ids"), list))
    )
    if not valid:
        raise Unreadable(f"{path}: not --json output of agent-tokens.py")
    return data


def sum_reports(reports):
    totals = {c: sum(r["totals"][c] for r in reports) for c in CATEGORIES}
    agents = sum(r["agents"] for r in reports)
    return {
        "agent_ids": [aid for r in reports for aid in roots_of(r)],
        "totals": totals,
        "agents": agents,
        "models": sorted({m for r in reports for m in r.get("models", [])}),
        "summary": summary(totals, agents),
    }


def format_text(report):
    width = max(len(c) for c in CATEGORIES)
    lines = [f"{c:<{width}}  {report['totals'][c]}" for c in CATEGORIES]
    lines.append(f"{'agents':<{width}}  {report['agents']}")
    lines.append(f"{'models':<{width}}  {', '.join(report['models']) or '-'}")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--agent", help="agent id (from `agentId: <id>`)")
    source.add_argument("--sum", nargs="+", metavar="JSON_FILE",
                        help="add up earlier --json outputs")
    parser.add_argument("--json", action="store_true", help="print one JSON object")
    args = parser.parse_args(argv)

    if args.sum:
        try:
            report = sum_reports([load_report(p) for p in args.sum])
        except Unreadable as exc:
            print(f"agent-tokens: --sum: {exc}", file=sys.stderr)
            return EXIT_ERROR
        print(json.dumps(report) if args.json else format_text(report))
        return EXIT_FOUND

    found = find_transcripts(args.agent)
    if not found:
        print(f"agent-tokens: no transcript for agent '{args.agent}' under {PROJECTS_DIR}",
              file=sys.stderr)
        return EXIT_NOT_FOUND
    if len(found) > 1:
        print(f"agent-tokens: agent '{args.agent}' found in more than one place:", file=sys.stderr)
        for path in found:
            print(f"  {path}", file=sys.stderr)
        return EXIT_ERROR
    try:
        report = measure(found[0])
    except Unreadable as exc:
        print(f"agent-tokens: unreadable: {exc}", file=sys.stderr)
        return EXIT_ERROR

    print(json.dumps(report) if args.json else format_text(report))
    return EXIT_FOUND


if __name__ == "__main__":
    sys.exit(main())
