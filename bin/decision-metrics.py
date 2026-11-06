#!/usr/bin/env python3
"""
Measure how agent decisions hold up, to recalibrate docs/escalation-list.md.

Two reports:

1. Agreement, from Claude Code transcripts: every AskUserQuestion question that
   has an option marked "(Recommended)" and an answer is classed as
     - recommendation: the answer is the recommended option;
     - other option:   the answer is another listed option;
     - free text:      the answer matches no option label. These are listed
                       with a short excerpt for a human to read; they are not
                       classified further.
   Also: how often the recommended option was listed first, and a split per
   skill (the last skill started in that session by a Skill call or a slash
   command before the question; "unknown" when none).

2. Reversals, from issues, PRs and commits (via `gh`): every `## Decisions`
   entry whose Choice is "(no HIL: ...)", in issue bodies and in the
   `## Decisions made` section of merged PRs, is checked for
     - exact reversal: the entry is "superseded by D<m>", or a commit of an
       `agent-authored` PR that carries it was reverted ("This reverts commit
       <sha>", or a merged PR body "Reverts <repo>#<n>");
     - heuristic follow-up (separate column, never summed with exact, and
       only for entries without an exact reversal): a PR or commit within
       FOLLOW_UP_DAYS of the agent PR's merge that touches at least one of
       its files and references its issue or PR together with "fix".
   Broken down by Choice kind (delegated, agent default, auto) and, where an
   issue carrying the entry has `needs-human` or `approved:<key>`, by
   escalation category.

Usage:
  decision-metrics.py [--days N] [--project NAME|PATH]... [--repo OWNER/NAME]...
                      [--report all|agreement|reversals] [--output PATH]

  --days     transcript window in days (default 42)
  --project  only these transcript projects: a directory name under
             ~/.claude/projects/ or the project path (repeatable; default all)
  --repo     repositories for the reversal report (repeatable; default the
             repository of the current directory, as gh resolves it)
  --output   write the report to PATH instead of stdout. PATH must lie under
             the temp directory (/tmp or $TMPDIR, where the session scratchpad
             lives) and outside any git work tree: transcripts carry project
             names and paths, which must never land in a repository.

Exit codes: 0 report written; 1 a gh call failed; 2 usage error or refused
--output path.

Transcripts are read with iter_transcript_events from permission-friction.py,
so free text in transcripts is only seen where that function yields it
(messages with list-shaped content).
"""

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

_PF_PATH = Path(__file__).resolve().parent / "permission-friction.py"
_pf_spec = importlib.util.spec_from_file_location("permission_friction", _PF_PATH)
_pf = importlib.util.module_from_spec(_pf_spec)
_pf_spec.loader.exec_module(_pf)
# iter_transcript_events takes a project directory and maps it to its
# transcript directory. This script walks the transcript directories
# themselves, so this private module instance maps a path to itself.
_pf._transcript_dir_for = Path

DEFAULT_DAYS = 42
FOLLOW_UP_DAYS = 14
EXCERPT_CHARS = 80
GH_LIST_LIMIT = 1000

RECOMMENDED_MARKER = "(Recommended)"
UNKNOWN_SKILL = "unknown"
AGENT_PR_LABEL = "agent-authored"
NEEDS_HUMAN_LABEL = "needs-human"
APPROVED_LABEL_PREFIX = "approved:"

CLASS_RECOMMENDATION = "recommendation"
CLASS_OTHER = "other_option"
CLASS_FREE = "free_text"
CLASSES = (CLASS_RECOMMENDATION, CLASS_OTHER, CLASS_FREE)
CLASS_TITLES = {
    CLASS_RECOMMENDATION: "picked the recommendation",
    CLASS_OTHER: "picked another listed option",
    CLASS_FREE: "free text",
}

REPORT_ALL = "all"
REPORT_AGREEMENT = "agreement"
REPORT_REVERSALS = "reversals"

COMMAND_NAME_RE = re.compile(r"<command-name>/?([^<\s]+)</command-name>")


def pct(part, whole):
    return f"{100 * part / whole:.1f}%" if whole else "-"


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


# --- agreement ------------------------------------------------------------------


def transcript_dirs(projects_root, projects=None):
    """Transcript directories under projects_root, narrowed to `projects`
    (directory names, or project paths encoded the way Claude Code names
    their transcript directory)."""
    root = Path(projects_root)
    if not root.is_dir():
        return []
    dirs = sorted(p for p in root.iterdir() if p.is_dir())
    if not projects:
        return dirs
    wanted = set(projects) | {_pf._encode_project_dir(p) for p in projects}
    return [d for d in dirs if d.name in wanted]


def parse_answers(text, questions):
    """Map question text -> answer text from an AskUserQuestion tool_result,
    which reads `... "<question>"="<answer>", "<question>"="<answer>". ...`."""
    starts = []
    for q in questions:
        marker = f'"{q}"="'
        idx = text.find(marker)
        if idx >= 0:
            starts.append((idx, idx + len(marker), q))
    starts.sort()
    answers = {}
    for i, (_idx, start, q) in enumerate(starts):
        if i + 1 < len(starts):
            end = text.rfind('"', start, starts[i + 1][0])
        else:
            end = text.rfind('".')
        if end < start:
            end = text.rfind('"')
        if end >= start:
            answers[q] = text[start:end]
    return answers


def classify_answer(answer, labels, recommended, multi_select=False):
    answer = answer.strip()
    picked = [answer]
    if answer not in labels and multi_select:
        picked = [part.strip() for part in answer.split(",")]
    if not all(p in labels for p in picked):
        return CLASS_FREE
    return CLASS_RECOMMENDATION if recommended in picked else CLASS_OTHER


def excerpt(text):
    flat = " ".join(text.split())
    return flat if len(flat) <= EXCERPT_CHARS else flat[:EXCERPT_CHARS] + "…"


def _empty_counts():
    counts = {c: 0 for c in CLASSES}
    counts["total"] = 0
    return counts


def analyze_agreement(projects_root, days=DEFAULT_DAYS, projects=None):
    classes = {c: 0 for c in CLASSES}
    per_skill = {}
    free_text = []
    recommended_first = 0
    total = 0

    for tdir in transcript_dirs(projects_root, projects):
        skill = {}
        pending = {}
        for session_id, _ts, content in _pf.iter_transcript_events(tdir, days):
            for block in content:
                if not isinstance(block, dict):
                    continue
                kind = block.get("type")
                if kind == "text":
                    m = COMMAND_NAME_RE.search(block.get("text") or "")
                    if m:
                        skill[session_id] = m.group(1)
                elif kind == "tool_use" and block.get("name") == "Skill":
                    name = (block.get("input") or {}).get("skill")
                    if name:
                        skill[session_id] = name
                elif kind == "tool_use" and block.get("name") == "AskUserQuestion":
                    questions = (block.get("input") or {}).get("questions") or []
                    pending[block.get("id")] = (questions, skill.get(session_id, UNKNOWN_SKILL))
                elif kind == "tool_result" and block.get("tool_use_id") in pending:
                    questions, active = pending.pop(block.get("tool_use_id"))
                    body = block.get("content")
                    if isinstance(body, list):
                        body = " ".join(b.get("text", "") for b in body if isinstance(b, dict))
                    if not isinstance(body, str):
                        continue
                    texts = [q.get("question", "") for q in questions if isinstance(q, dict)]
                    answers = parse_answers(body, texts)
                    for q in questions:
                        if not isinstance(q, dict):
                            continue
                        labels = [o.get("label", "") for o in q.get("options") or [] if isinstance(o, dict)]
                        recs = [lab for lab in labels if RECOMMENDED_MARKER in lab]
                        answer = answers.get(q.get("question", ""))
                        if not recs or answer is None:
                            continue
                        cls = classify_answer(answer, labels, recs[0], bool(q.get("multiSelect")))
                        total += 1
                        classes[cls] += 1
                        if labels and labels[0] == recs[0]:
                            recommended_first += 1
                        row = per_skill.setdefault(active, _empty_counts())
                        row["total"] += 1
                        row[cls] += 1
                        if cls == CLASS_FREE:
                            free_text.append({
                                "skill": active,
                                "question": excerpt(q.get("question", "")),
                                "excerpt": excerpt(answer),
                            })

    return {
        "total": total,
        "classes": classes,
        "recommended_first": recommended_first,
        "per_skill": per_skill,
        "free_text": free_text,
    }


def format_agreement(report, days):
    n = report["total"]
    lines = [
        f"Agreement with recommendations (last {days} days): "
        f"{n} question{'' if n == 1 else 's'} with a recommended option and an answer",
    ]
    for c in CLASSES:
        lines.append(f"  {CLASS_TITLES[c]:<30} {report['classes'][c]:>5}  {pct(report['classes'][c], n):>6}")
    lines.append(
        f"  {'recommendation listed first':<30} {report['recommended_first']:>5}  "
        f"{pct(report['recommended_first'], n):>6}"
    )
    lines.append("")
    lines.append(f"  {'skill':<24} {'total':>5}  {'recommendation':>14}  {'other option':>12}  {'free text':>9}")
    for name, row in sorted(report["per_skill"].items(), key=lambda kv: (-kv[1]["total"], kv[0])):
        lines.append(
            f"  {name:<24} {row['total']:>5}  {pct(row[CLASS_RECOMMENDATION], row['total']):>14}  "
            f"{pct(row[CLASS_OTHER], row['total']):>12}  {pct(row[CLASS_FREE], row['total']):>9}"
        )
    if report["free_text"]:
        lines.append("")
        lines.append("  Free-text answers (read these; not classified further):")
        for item in report["free_text"]:
            lines.append(f"    [{item['skill']}] {item['question']}")
            lines.append(f"        -> {item['excerpt']}")
    return "\n".join(lines)


# --- reversals ------------------------------------------------------------------


class GhError(RuntimeError):
    pass


def run_gh(args):
    try:
        res = subprocess.run(["gh", *args], capture_output=True, text=True)
    except OSError as exc:
        raise GhError(f"gh not runnable: {exc}") from exc
    if res.returncode != 0:
        raise GhError(f"gh {' '.join(args[:2])} failed: {res.stderr.strip()}")
    return res.stdout


SECTION_RE = re.compile(r"^##\s+(.+?)\s*$", re.M)
ENTRY_RE = re.compile(r"^###\s+D(\d+):\s*(.*?)\s*$", re.M)
ONE_LINE_RE = re.compile(r"^\s*[-*]\s+D(\d+):\s*(.+?)\s*→\s*(.+?)\s*$", re.M)
STATUS_RE = re.compile(r"\*\*Status:\*\*\s*(.+?)\s*$", re.M)
ORIGIN_RE = re.compile(r"\*\*Origin:\*\*\s*#(\d+)")
CHOICE_RE = re.compile(r"\*\*Choice:\*\*\s*(.+?)\s*$", re.M)
NO_HIL_RE = re.compile(r"\(no HIL:\s*([^)]+?)\s*\)\s*$")
IMPLEMENTS_RE = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|implements?)\s+#(\d+)", re.I)
BRANCH_ISSUE_RE = re.compile(r"^issue-(\d+)-")
REF_RE = re.compile(r"#(\d+)\b")
FIX_RE = re.compile(r"\bfix(?:e[sd])?\b", re.I)
REVERTS_COMMIT_RE = re.compile(r"This reverts commit ([0-9a-f]{7,40})")
REVERTS_PR_RE = re.compile(r"^Reverts\s+(?:[\w.-]+/[\w.-]+)?#(\d+)", re.M)


def section(body, title):
    """Text of the `## <title>` section of a markdown body, or ''."""
    body = body or ""
    heads = list(SECTION_RE.finditer(body))
    for i, h in enumerate(heads):
        if h.group(1) == title:
            end = heads[i + 1].start() if i + 1 < len(heads) else len(body)
            return body[h.end():end]
    return ""


def choice_kind(choice):
    """'delegated' / 'agent default' / 'auto' for a no-HIL Choice, else None."""
    m = NO_HIL_RE.search(choice or "")
    return m.group(1) if m else None


def parse_full_entries(text):
    """Refine-format entries: list of (n, question, status, origin, choice)."""
    heads = list(ENTRY_RE.finditer(text))
    out = []
    for i, h in enumerate(heads):
        block = text[h.end():heads[i + 1].start() if i + 1 < len(heads) else len(text)]
        status = STATUS_RE.search(block)
        origin = ORIGIN_RE.search(block)
        choice = CHOICE_RE.search(block)
        out.append((
            int(h.group(1)),
            h.group(2),
            status.group(1) if status else "active",
            int(origin.group(1)) if origin else None,
            choice.group(1) if choice else "",
        ))
    return out


def parse_one_liners(text):
    """PR issue-decision lines `- D<n>: question → choice`, before any full entry."""
    first = ENTRY_RE.search(text)
    head = text[:first.start()] if first else text
    return [(int(m.group(1)), m.group(2), m.group(3)) for m in ONE_LINE_RE.finditer(head)]


def implemented_issues(pr):
    found = {int(n) for n in IMPLEMENTS_RE.findall(pr.get("body") or "")}
    m = BRANCH_ISSUE_RE.match(pr.get("headRefName") or "")
    if m:
        found.add(int(m.group(1)))
    return found


def label_names(item):
    return {lab.get("name", "") for lab in item.get("labels") or []}


def categories(labels):
    cats = set()
    for name in labels:
        if name == NEEDS_HUMAN_LABEL:
            cats.add(NEEDS_HUMAN_LABEL)
        elif name.startswith(APPROVED_LABEL_PREFIX):
            cats.add(name[len(APPROVED_LABEL_PREFIX):])
    return cats


def _add_entry(entries, key, question, status, choice, issue=None, pr=None):
    e = entries.setdefault(key, {
        "key": key, "question": question, "status": status, "choice": choice,
        "issues": set(), "prs": set(),
    })
    if status.startswith("superseded"):
        e["status"] = status
    if issue is not None:
        e["issues"].add(issue)
    if pr is not None:
        e["prs"].add(pr)
    return e


def collect_entries(issues, prs):
    """All decision entries of a repo, keyed `<origin issue>:D<n>`."""
    entries = {}
    for issue in issues:
        for n, q, status, origin, choice in parse_full_entries(section(issue.get("body"), "Decisions")):
            _add_entry(entries, f"{origin or issue['number']}:D{n}", q, status, choice, issue=issue["number"])
    for pr in prs:
        text = section(pr.get("body"), "Decisions made")
        if not text:
            continue
        own = sorted(implemented_issues(pr))
        base = own[0] if own else f"pr{pr['number']}"
        for n, q, choice in parse_one_liners(text):
            key = f"{base}:D{n}"
            if key in entries:
                entries[key]["prs"].add(pr["number"])
                continue
            # The issue was not fetched, or its entry has another origin: find
            # it by ID among the entries the implemented issue carries.
            match = [e for e in entries.values()
                     if e["key"].endswith(f":D{n}") and set(own) & e["issues"]]
            if match:
                match[0]["prs"].add(pr["number"])
            else:
                _add_entry(entries, key, q, "active", choice, pr=pr["number"])
        for n, q, status, origin, choice in parse_full_entries(text):
            _add_entry(entries, f"{origin or base}:D{n}", q, status, choice, pr=pr["number"])
    return entries


class RepoData:
    """Lazily fetched gh data for one repository."""

    def __init__(self, repo, gh):
        self.repo = repo
        self.gh = gh
        self._pr_detail = {}
        self._commit_files = {}

    def issues(self):
        return json.loads(self.gh([
            "issue", "list", "--repo", self.repo, "--state", "all",
            "--limit", str(GH_LIST_LIMIT), "--json", "number,body,labels",
        ]))

    def merged_prs(self):
        return json.loads(self.gh([
            "pr", "list", "--repo", self.repo, "--state", "merged",
            "--limit", str(GH_LIST_LIMIT),
            "--json", "number,title,body,labels,mergedAt,mergeCommit,headRefName",
        ]))

    def pr_detail(self, number):
        if number not in self._pr_detail:
            data = json.loads(self.gh([
                "pr", "view", str(number), "--repo", self.repo, "--json", "files,commits",
            ]))
            self._pr_detail[number] = (
                {f.get("path") for f in data.get("files") or []},
                {c.get("oid") for c in data.get("commits") or [] if c.get("oid")},
            )
        return self._pr_detail[number]

    def commits_since(self, since):
        out = self.gh([
            "api", "--paginate",
            f"repos/{self.repo}/commits?since={since.strftime('%Y-%m-%dT%H:%M:%SZ')}&per_page=100",
            "--jq", ".[] | {sha: .sha, message: .commit.message, date: .commit.committer.date}",
        ])
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def commit_files(self, sha):
        if sha not in self._commit_files:
            self._commit_files[sha] = set(json.loads(self.gh([
                "api", f"repos/{self.repo}/commits/{sha}", "--jq", "[.files[].filename]",
            ])))
        return self._commit_files[sha]


def _sha_matches(short, full_set):
    return any(full.startswith(short) or short.startswith(full) for full in full_set)


def analyze_repo(repo, gh):
    data = RepoData(repo, gh)
    issues = data.issues()
    prs = data.merged_prs()
    entries = collect_entries(issues, prs)
    issue_labels = {i["number"]: label_names(i) for i in issues}

    by_issue = {}
    for pr in prs:
        for n in implemented_issues(pr):
            by_issue.setdefault(n, set()).add(pr["number"])
    pr_by_number = {pr["number"]: pr for pr in prs}
    agent = {n for n, pr in pr_by_number.items()
             if AGENT_PR_LABEL in label_names(pr) and parse_ts(pr.get("mergedAt"))}

    # Exact: reverted agent PRs.
    reverted = set()
    commits = []
    if agent:
        since = min(parse_ts(pr_by_number[n]["mergedAt"]) for n in agent)
        commits = data.commits_since(since)
        agent_shas = {}
        for n in agent:
            merge = (pr_by_number[n].get("mergeCommit") or {}).get("oid")
            agent_shas[n] = data.pr_detail(n)[1] | ({merge} if merge else set())
        for c in commits:
            for short in REVERTS_COMMIT_RE.findall(c.get("message") or ""):
                reverted |= {n for n, shas in agent_shas.items() if _sha_matches(short, shas)}
        for pr in prs:
            reverted |= {int(n) for n in REVERTS_PR_RE.findall(pr.get("body") or "")} & agent

    # Heuristic: follow-up fixes per agent PR.
    follow_ups = {}
    for n in agent:
        pr = pr_by_number[n]
        merged = parse_ts(pr["mergedAt"])
        window_end = merged + timedelta(days=FOLLOW_UP_DAYS)
        files, own_shas = data.pr_detail(n)
        refs = {n} | implemented_issues(pr)
        found = []

        def qualifies(text):
            return FIX_RE.search(text or "") and refs & {int(r) for r in REF_RE.findall(text or "")}

        for other in prs:
            t = parse_ts(other.get("mergedAt"))
            if other["number"] == n or t is None or not (merged < t <= window_end):
                continue
            if qualifies(f"{other.get('title', '')}\n{other.get('body') or ''}") \
                    and files & data.pr_detail(other["number"])[0]:
                found.append({"ref": f"PR #{other['number']}", "date": other["mergedAt"]})
        for c in commits:
            t = parse_ts(c.get("date"))
            if t is None or not (merged < t <= window_end) or _sha_matches(c["sha"], own_shas):
                continue
            if REVERTS_COMMIT_RE.search(c.get("message") or ""):
                continue
            if qualifies(c.get("message")) and files & data.commit_files(c["sha"]):
                found.append({"ref": f"commit {c['sha'][:7]}", "date": c["date"]})
        follow_ups[n] = found

    results = []
    for e in entries.values():
        kind = choice_kind(e["choice"])
        if kind is None:
            continue
        linked_issues = set(e["issues"])
        for p in e["prs"]:
            linked_issues |= implemented_issues(pr_by_number.get(p, {}))
        linked_prs = (set(e["prs"]) | {p for i in e["issues"] for p in by_issue.get(i, ())}) & agent
        superseded = e["status"].startswith("superseded")
        is_reverted = bool(linked_prs & reverted)
        fups = [f for p in sorted(linked_prs) for f in follow_ups.get(p, [])]
        exact = superseded or is_reverted
        cats = set()
        for i in linked_issues:
            cats |= categories(issue_labels.get(i, set()))
        results.append({
            "repo": repo,
            "key": e["key"],
            "question": e["question"],
            "kind": kind,
            "categories": sorted(cats),
            "prs": sorted(linked_prs),
            "superseded": superseded,
            "reverted": is_reverted,
            "exact": exact,
            "follow_ups": fups,
            "heuristic": bool(fups) and not exact,
        })
    return results


def _tally(rows):
    return {
        "entries": len(rows),
        "exact": sum(r["exact"] for r in rows),
        "superseded": sum(r["superseded"] for r in rows),
        "reverted": sum(r["reverted"] for r in rows),
        "heuristic": sum(r["heuristic"] for r in rows),
    }


def analyze_reversals(repos, gh=run_gh):
    """`repos`: OWNER/NAME strings; None means the current directory's repo.
    Time windows are relative to each agent PR's merge, not to today."""
    entries = []
    for repo in repos:
        if repo is None:
            repo = gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()
        entries.extend(analyze_repo(repo, gh))
    by_kind = {}
    by_cat = {}
    for r in entries:
        by_kind.setdefault(r["kind"], []).append(r)
        for c in r["categories"]:
            by_cat.setdefault(c, []).append(r)
    return {
        "repos": sorted({r["repo"] for r in entries}),
        "entries": entries,
        "totals": _tally(entries),
        "by_kind": {k: _tally(v) for k, v in by_kind.items()},
        "by_category": {k: _tally(v) for k, v in by_cat.items()},
    }


def format_reversals(report):
    tot = report["totals"]
    lines = [
        "Reversals of agent decisions (no-HIL entries in issue `## Decisions` and PR "
        "`## Decisions made`)",
        f"  exact = superseded entry or reverted agent-PR commit; heuristic = follow-up "
        f"fix within {FOLLOW_UP_DAYS} days touching the same files, only for entries "
        "without an exact reversal. The columns are never summed.",
        f"  entries: {tot['entries']}   exact: {tot['exact']} ({pct(tot['exact'], tot['entries'])}; "
        f"superseded {tot['superseded']}, reverted {tot['reverted']})   "
        f"heuristic: {tot['heuristic']} ({pct(tot['heuristic'], tot['entries'])})",
    ]

    def table(title, rows):
        lines.append("")
        lines.append(f"  {title:<24} {'entries':>7}  {'exact':>12}  {'heuristic':>12}")
        for name, t in sorted(rows.items()):
            lines.append(
                f"  {name:<24} {t['entries']:>7}  {t['exact']:>4} {pct(t['exact'], t['entries']):>7}  "
                f"{t['heuristic']:>4} {pct(t['heuristic'], t['entries']):>7}"
            )

    table("Choice kind", report["by_kind"])
    if report["by_category"]:
        table("escalation category", report["by_category"])
    flagged = [r for r in report["entries"] if r["exact"] or r["heuristic"]]
    if flagged:
        lines.append("")
        lines.append("  Entries:")
        for r in flagged:
            signals = [s for s in ("superseded", "reverted") if r[s]]
            if r["heuristic"]:
                signals.append("heuristic: " + ", ".join(f["ref"] for f in r["follow_ups"]))
            lines.append(f"    {r['repo']} {r['key']} ({r['kind']}): {r['question']}  [{'; '.join(signals)}]")
    return "\n".join(lines)


# --- output ---------------------------------------------------------------------


def _inside_git_work_tree(path):
    probe = path
    while not probe.exists():
        probe = probe.parent
    if not probe.is_dir():
        probe = probe.parent
    res = subprocess.run(["git", "-C", str(probe), "rev-parse", "--is-inside-work-tree"],
                         capture_output=True, text=True)
    return res.returncode == 0 and res.stdout.strip() == "true"


def output_refusal(path_str):
    """Reason to refuse writing to `path_str`, or None when it is allowed."""
    path = Path(path_str).expanduser().resolve()
    temp_roots = {Path("/tmp").resolve(), Path(tempfile.gettempdir()).resolve()}
    if not any(path.is_relative_to(root) for root in temp_roots):
        return f"--output must lie under {' or '.join(sorted(map(str, temp_roots)))}"
    if _inside_git_work_tree(path):
        return "--output lies inside a git work tree; reports derived from transcripts never go into a repository"
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Agreement with recommendations and reversals of agent decisions.",
        epilog="Report output goes to stdout, or with --output to a path under the temp "
               "directory outside any git work tree.",
    )
    parser.add_argument("--days", type=int, default=DEFAULT_DAYS,
                        help=f"transcript window in days (default {DEFAULT_DAYS})")
    parser.add_argument("--project", action="append", default=[],
                        help="only this transcript project (dir name under ~/.claude/projects or project path); repeatable")
    parser.add_argument("--repo", action="append", default=[],
                        help="OWNER/NAME for the reversal report; repeatable (default: current repo)")
    parser.add_argument("--report", choices=(REPORT_ALL, REPORT_AGREEMENT, REPORT_REVERSALS),
                        default=REPORT_ALL, help="which report to produce (default all)")
    parser.add_argument("--output", help="write to this path (temp dir only, never inside a git work tree)")
    args = parser.parse_args(argv)

    if args.output:
        reason = output_refusal(args.output)
        if reason:
            print(f"decision-metrics: refused: {reason}", file=sys.stderr)
            return 2

    parts = []
    if args.report in (REPORT_ALL, REPORT_AGREEMENT):
        rep = analyze_agreement(_pf.PROJECTS_TRANSCRIPTS_DIR, args.days, args.project or None)
        parts.append(format_agreement(rep, args.days))
    if args.report in (REPORT_ALL, REPORT_REVERSALS):
        try:
            rev = analyze_reversals(args.repo or [None])
        except GhError as exc:
            print(f"decision-metrics: {exc}", file=sys.stderr)
            return 1
        parts.append(format_reversals(rev))
    text = "\n\n".join(parts) + "\n"

    if args.output:
        out = Path(args.output).expanduser().resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
