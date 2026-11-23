#!/usr/bin/env python3
"""
The decision card of an agent PR (#376): one PR comment that holds every
question the queue runner leaves for the human, and the "Waiting on you"
block of the loop's status message, both from the same card data.

Usage:
  queue-decision-card.py render  --input <file> [--human <file>] [--gates <file>]
  queue-decision-card.py post    --repo <owner/name> --pr <N> --input <file>
                                 [--human <file>] [--gates <file>]
  queue-decision-card.py waiting --repo <owner/name> [--json]
  queue-decision-card.py handback --repo <owner/name>

Input (--input, one JSON object; an unknown key is an error):

  {
    "reason": "re-review BLOCKING",           # required: why a human is needed
    "review_url": "https://...",              # optional: the review the card is about
    "questions": [{"question": "...",         # optional: HUMAN decisions, left findings
                   "options": ["A: ...", "B: ..."], "recommendation": "A: ..."}],
    "blocking": ["..."],                      # optional: blocking reasons of the last review
    "rejected": ["<finding>: <reason>"]       # optional: findings the fix round rejected
  }

  --human  a /pre-merge HUMAN decisions file (the same question objects as a
           JSON list); its questions come after those of --input
  --gates  a pre-merge-verdict.py input; its blocking_reasons (computed with
           that helper's rules, so MEDIUM/LOW findings never count) are added
           to "blocking"

Questions, in this order:
  1. the explicit questions (--input, then --human);
  2. none, but blocking reasons and rejected findings: one derived question,
     the review against the fix round (A: rework round, B: merge as is;
     recommended A);
  3. none at all: "no decision needed; reply `go` to start a rework round".

The card: its body starts with the line `<!-- queue-runner -->` (so rework
R3 and /refine never read it as review input) and then
`<!-- queue-runner:decisions -->`, which identifies the card. Numbered
questions, each with options lettered A, B, C (a leading "A: " of an input
option is replaced, not doubled), the recommended option marked, the
recommendation line, the blocking reasons, one line on how to answer, and a
data line for scripts:

  <!-- queue-runner:decisions-data {"version": 1, "answer": "choices|go",
       "questions": [{"n": 1, "options": ["A", "B"], "recommendation": "A"}]} -->

  "recommendation" is the letter the recommendation names (a leading letter
  such as "B" or "B: ...", or the full text of an option), else null.

Answer format, what the human replies on the PR:
  choices   one <number><letter> per question, separated by spaces: `1A 2C`
  go        the word `go` (the card has no question)

render:  prints the card body; no gh call.
post:    upserts the card on the PR as the logged-in gh user (the account
         the loop comments with): the PR comments are read (paginated); the
         oldest comment whose body starts with both marker lines is edited;
         only when there is none is one created. A quoted card (lines
         starting with "> ") is not a card. Never creates a second card.
         Result on stdout:
           {"status": "created|updated", "card_url": "...", "comment_id": 1,
            "questions": 2, "answer": "choices|go", "duplicates": 0}
         "duplicates" counts further cards that were left alone.
waiting: the PRs that wait on the human: the open issues with both
         `needs-human` and `agent-pr`, mapped to the open PRs that close
         them, one row per PR with the question count of its card:

           Waiting on you (2 PRs):
           - PR #42 (issue #17): 2 questions, decision card <url>
           - PR #45 (issue #20): no decision needed, reply `go`, decision card <url>
           - PR #47 (issue #22): no decision card, <pr url>

         Prints nothing when no PR waits. --json prints a list instead:
           [{"pr": 42, "pr_url": "...", "issues": [17], "questions": 2,
             "answer": "choices", "card_url": "..."}]
           ("questions", "answer" and "card_url" are null without a card)
handback: the open PRs the human handed back to the loop for a rework
         (#377), for `queue-claim.sh claim --rework`. A PR counts when it
         closes an open `agent-pr` issue without `agent-wip` or `epic`, and
           label  the PR has `agent-rework`, or
           reply  `needs-human` is on the PR or on such an issue, the PR has
                  a decision card, and a human replied after it: a PR
                  comment without the `<!-- queue-runner -->` marker and not
                  by a bot (the loop comments as the human's own gh user, so
                  the marker, not the author, tells them apart), created
                  after the cutoff. The cutoff is the card's last edit
                  (`updated_at`: each round edits the card), or the last
                  marker comment on the PR or on one of those issues when
                  that is later, so a reply the loop already answered (a
                  rework round, a failed or escalated release) never counts
                  twice. The last such reply is the answer.
         Prints a JSON list, [] when none:
           [{"pr": 42, "pr_url": "...", "issues": [17], "trigger": "label|reply",
             "reply_url": "...", "reply": "1A 2C", "answer_problem": null}]
         "reply_url" and "reply" are null for "label". "answer_problem" says
         why a reply is not in the card's answer format (the first non-empty
         line: `go`, or one known <number><letter> per question), else null;
         such a reply still hands the PR back, as a free-text answer.

A gh failure prints {"status": "failed", "stage":
"comments|create|update|issues|prs", "error": "..."} on stdout.

Exit codes:
  0  rendered, posted, or listed
  2  usage error or invalid input; nothing was sent, stderr says why
  3  a gh or GitHub error; see the JSON result
"""

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
POST_SCRIPT = BIN_DIR / "pre-merge-post.py"

# The marker every queue-runner comment starts with (pr-review-threads.py,
# queue-claim.sh, rework.md R3); the card marker on the next line names the card.
MARKER = "<!-- queue-runner -->"
CARD_MARKER = "<!-- queue-runner:decisions -->"
CARD_HEAD = f"{MARKER}\n{CARD_MARKER}"
DATA_PREFIX = "<!-- queue-runner:decisions-data "
DATA_SUFFIX = " -->"
DATA_VERSION = 1

ANSWER_CHOICES = "choices"
ANSWER_GO = "go"
INPUT_KEYS = ("reason", "review_url", "questions", "blocking", "rejected")

PR_LABEL = "agent-pr"
REWORK_LABEL = "agent-rework"
# A closing issue with one of these is not handed back: a round runs (#377).
HANDBACK_SKIP_LABELS = {"agent-wip", "epic"}
TRIGGER_LABEL = "label"
TRIGGER_REPLY = "reply"
BOT_USER_TYPE = "Bot"
# One answer of a `choices` card: question number and option letter, "2C".
ANSWER_TOKEN = re.compile(r"^(\d+)([A-Za-z])$")
GH_FETCH_LIMIT = 200
PAGE_SIZE = 100
ERROR_LINES = 5
LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
# "A: text", "B. text", "C) text": a letter the input already put in front.
LETTER_PREFIX = re.compile(r"^([A-Z])\s*[:.)]\s*")
# A recommendation that names an option: "B", "B: ...", "B, because ...".
RECOMMENDED_LETTER = re.compile(r"^\s*([A-Z])\s*(?:$|[:.),])")

STATUS_CREATED = "created"
STATUS_UPDATED = "updated"
STATUS_FAILED = "failed"
STAGE_COMMENTS = "comments"
STAGE_CREATE = "create"
STAGE_UPDATE = "update"
STAGE_ISSUES = "issues"
STAGE_PRS = "prs"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_FAILED = 3

DERIVED_QUESTION = ("The fix round rejected findings that the review still blocks on. "
                    "Which side holds?")
DERIVED_OPTIONS = ["The review: a rework round fixes the blocking findings",
                   "The fix round: the findings do not hold; the PR can be merged as it is"]
DERIVED_RECOMMENDATION = "A: the review is the independent check"
GO_TEXT = "no decision needed; reply `go` to start a rework round"


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


P = _load_module("pre_merge_post", POST_SCRIPT)
V = P.V
Invalid = V.Invalid


class CardFailed(Exception):
    def __init__(self, stage, error):
        super().__init__(error)
        self.stage, self.error = stage, error


# --- input --------------------------------------------------------------------------

def _strings(data, key):
    value = data.get(key, [])
    if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
        raise Invalid(f"'{key}' must be a list of non-empty strings")
    return [v.strip() for v in value]


def load_input(path, human_path=None, gates_path=None):
    """The card input: (reason, review_url, questions, blocking, rejected)."""
    data = P.load_json(path, "--input file")
    if not isinstance(data, dict):
        raise Invalid("--input must be a JSON object")
    unknown = sorted(set(data) - set(INPUT_KEYS))
    if unknown:
        raise Invalid(f"--input: unknown key(s): {', '.join(unknown)}")
    reason = data.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        raise Invalid("--input: 'reason' is required")
    review_url = data.get("review_url") or ""
    if not isinstance(review_url, str):
        raise Invalid("--input: 'review_url' must be a string")
    questions = data.get("questions", [])
    if questions:
        P.validate_human(questions)
    if human_path:
        human = P.load_json(human_path, "--human file")
        P.validate_human(human)
        questions = [*questions, *human]
    blocking = _strings(data, "blocking")
    if gates_path:
        gates = P.load_json(gates_path, "--gates file")
        V.validate(gates)
        blocking += [r for r in V.evaluate(gates)["blocking_reasons"] if r not in blocking]
    return reason.strip(), review_url.strip(), questions, blocking, _strings(data, "rejected")


# --- card ---------------------------------------------------------------------------

def option_text(option):
    return LETTER_PREFIX.sub("", option.strip(), count=1)


def recommended_letter(recommendation, texts):
    """The letter of the option the recommendation names, or None."""
    letters = LETTERS[:len(texts)]
    match = RECOMMENDED_LETTER.match(recommendation)
    if match and match.group(1) in letters:
        return match.group(1)
    wanted = option_text(recommendation).casefold()
    for letter, text in zip(letters, texts):
        if text.casefold() == wanted:
            return letter
    return None


def card_questions(questions, blocking, rejected):
    """The numbered questions of the card; derived ones per the rules of --help."""
    if not questions and blocking and rejected:
        questions = [{"question": DERIVED_QUESTION, "options": DERIVED_OPTIONS,
                      "recommendation": DERIVED_RECOMMENDATION,
                      "details": ("Rejected by the fix round:", rejected)}]
    out = []
    for n, q in enumerate(questions, 1):
        texts = [option_text(o) for o in q["options"]]
        if len(texts) > len(LETTERS):
            raise Invalid(f"question {n}: at most {len(LETTERS)} options")
        out.append({"n": n, "question": q["question"].strip(), "texts": texts,
                    "recommendation": q["recommendation"].strip(),
                    "letter": recommended_letter(q["recommendation"], texts),
                    "details": q.get("details")})
    return out


def card_data(numbered):
    return {"version": DATA_VERSION, "answer": ANSWER_CHOICES if numbered else ANSWER_GO,
            "questions": [{"n": q["n"], "options": list(LETTERS[:len(q["texts"])]),
                           "recommendation": q["letter"]} for q in numbered]}


def render(reason, review_url, numbered, blocking):
    why = f"Why a human is needed: {reason}."
    if review_url:
        why += f" Review: {review_url}"
    parts = [CARD_HEAD, "## Queue runner: decision card", "", why, ""]
    for q in numbered:
        parts += [f"### {q['n']}. {q['question']}", ""]
        if q["details"]:
            title, items = q["details"]
            parts += [title, P.bullet_list(items), ""]
        for letter, text in zip(LETTERS, q["texts"]):
            mark = " (recommended)" if letter == q["letter"] else ""
            parts.append(f"- **{letter}**: {text}{mark}")
        parts += ["", f"Recommendation: {q['recommendation']}", ""]
    if blocking:
        parts += ["Still blocking:", P.bullet_list(blocking), ""]
    if numbered:
        example = " ".join(f"{q['n']}{q['letter'] or LETTERS[0]}" for q in numbered)
        parts.append("**How to answer:** reply on this PR with the number and letter of your "
                     f"choice per question, e.g. `{example}`.")
    else:
        parts.append(f"**How to answer:** {GO_TEXT}.")
    parts += ["", f"{DATA_PREFIX}{json.dumps(card_data(numbered))}{DATA_SUFFIX}"]
    return "\n".join(parts) + "\n"


def build(args):
    reason, review_url, questions, blocking, rejected = load_input(args.input, args.human, args.gates)
    numbered = card_questions(questions, blocking, rejected)
    return render(reason, review_url, numbered, blocking), card_data(numbered)


def is_card(body):
    return (body or "").replace("\r\n", "\n").startswith(CARD_HEAD)


def read_data(body):
    """The data line of a card, or None when it is missing or unreadable."""
    for line in (body or "").splitlines():
        line = line.strip()
        if line.startswith(DATA_PREFIX) and line.endswith(DATA_SUFFIX):
            try:
                data = json.loads(line[len(DATA_PREFIX):-len(DATA_SUFFIX)])
            except ValueError:
                return None
            return data if isinstance(data, dict) else None
    return None


# --- gh -----------------------------------------------------------------------------

def gh(stage, *args, payload=None):
    """Run `gh <args>` as the logged-in user; returns stdout or raises CardFailed."""
    with tempfile.TemporaryDirectory(prefix="queue-decision-card.") as work:
        cmd = ["gh", *args]
        if payload is not None:
            body = Path(work) / "request.json"
            body.write_text(json.dumps(payload), encoding="utf-8")
            cmd += ["--input", str(body)]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True)
        except OSError as exc:
            raise CardFailed(stage, f"cannot run gh: {exc}")
    if r.returncode != 0:
        lines = [l for l in r.stderr.splitlines() if l.strip()]
        raise CardFailed(stage, " | ".join(lines[-ERROR_LINES:]) or f"exit {r.returncode}, no message")
    return r.stdout


def gh_json(stage, *args):
    try:
        return P.parse_pages(gh(stage, *args))
    except ValueError as exc:
        raise CardFailed(stage, f"unreadable answer: {exc}")


def pr_comments(repo, pr):
    return gh_json(STAGE_COMMENTS, "api", "--paginate",
                   f"repos/{repo}/issues/{pr}/comments?per_page={PAGE_SIZE}")


def answer_json(stage, text):
    try:
        return json.loads(text)
    except ValueError as exc:
        raise CardFailed(stage, f"unreadable answer: {exc}")


def upsert(repo, pr, body, data):
    found = [c for c in pr_comments(repo, pr) if is_card(c.get("body"))]
    found.sort(key=lambda c: c.get("id") or 0)
    if found:
        card = answer_json(STAGE_UPDATE, gh(STAGE_UPDATE, "api", "-X", "PATCH",
                                            f"repos/{repo}/issues/comments/{found[0]['id']}",
                                            payload={"body": body}))
        status = STATUS_UPDATED
    else:
        card = answer_json(STAGE_CREATE, gh(STAGE_CREATE, "api", "-X", "POST",
                                            f"repos/{repo}/issues/{pr}/comments",
                                            payload={"body": body}))
        status = STATUS_CREATED
    return {"status": status, "card_url": card.get("html_url", ""), "comment_id": card.get("id"),
            "questions": len(data["questions"]), "answer": data["answer"],
            "duplicates": max(len(found) - 1, 0)}


def waiting_rows(repo):
    """One row per open PR that closes an issue waiting on the human."""
    issues = gh_json(STAGE_ISSUES, "api", "--paginate",
                     f"repos/{repo}/issues?state=open&labels={V.HUMAN_LABEL},{PR_LABEL}"
                     f"&per_page={PAGE_SIZE}")
    waiting = {i["number"] for i in issues if "pull_request" not in i}
    if not waiting:
        return []
    prs = answer_json(STAGE_PRS, gh(STAGE_PRS, "pr", "list", "--repo", repo, "--state", "open",
                                    "--limit", str(GH_FETCH_LIMIT),
                                    "--json", "number,url,closingIssuesReferences"))
    rows = []
    for pr in sorted(prs, key=lambda p: p["number"]):
        closes = sorted(i["number"] for i in pr.get("closingIssuesReferences") or []
                        if i.get("number") in waiting)
        if not closes:
            continue
        cards = sorted((c for c in pr_comments(repo, pr["number"]) if is_card(c.get("body"))),
                       key=lambda c: c.get("id") or 0)
        row = {"pr": pr["number"], "pr_url": pr.get("url", ""), "issues": closes,
               "questions": None, "answer": None, "card_url": None}
        if cards:
            data = read_data(cards[0].get("body")) or {}
            questions = data.get("questions")
            row.update(card_url=cards[0].get("html_url", ""), answer=data.get("answer"),
                       questions=len(questions) if isinstance(questions, list) else None)
        rows.append(row)
    return rows


def plural(count, word):
    return f"{count} {word}{'' if count == 1 else 's'}"


def waiting_text(rows):
    if not rows:
        return ""
    lines = [f"Waiting on you ({plural(len(rows), 'PR')}):"]
    for row in rows:
        issues = ", ".join(f"#{n}" for n in row["issues"])
        head = f"- PR #{row['pr']} ({'issue' if len(row['issues']) == 1 else 'issues'} {issues}): "
        if row["card_url"] is None:
            lines.append(f"{head}no decision card, {row['pr_url']}")
        elif row["answer"] == ANSWER_GO:
            lines.append(f"{head}no decision needed, reply `go`, decision card {row['card_url']}")
        elif row["questions"] is not None:
            lines.append(f"{head}{plural(row['questions'], 'question')}, "
                         f"decision card {row['card_url']}")
        else:
            lines.append(f"{head}questions unknown, decision card {row['card_url']}")
    return "\n".join(lines) + "\n"


# --- handback -----------------------------------------------------------------------

def label_names(item):
    return {label.get("name") for label in item.get("labels") or []}


def is_marked(body):
    return (body or "").replace("\r\n", "\n").startswith(MARKER)


def last_marked(comments):
    """Creation time of the last queue-runner comment, or ""."""
    return max((c.get("created_at") or "" for c in comments if is_marked(c.get("body"))), default="")


def answer_problem(text, data):
    """Why a reply is not in the card's answer format, or None when it is.

    The first non-empty line counts, without surrounding backticks."""
    line = next((l.strip().strip("`").strip() for l in (text or "").splitlines() if l.strip()), "")
    if not isinstance(data, dict):
        return "the card has no readable data line"
    if data.get("answer") == ANSWER_GO:
        return None if line.casefold() == ANSWER_GO else f"not `{ANSWER_GO}`"
    options = {q.get("n"): q.get("options") or [] for q in data.get("questions") or []
               if isinstance(q, dict)}
    seen = set()
    for token in line.split():
        match = ANSWER_TOKEN.match(token)
        if not match:
            return f"'{token}' is not <number><letter>"
        n, letter = int(match.group(1)), match.group(2).upper()
        if n not in options:
            return f"no question {n}"
        if letter not in options[n]:
            return f"question {n} has no option {letter}"
        if n in seen:
            return f"question {n} answered twice"
        seen.add(n)
    missing = sorted(set(options) - seen)
    if missing:
        return "no answer to question " + ", ".join(str(n) for n in missing)
    return None


def human_reply(repo, pr, issues):
    """The last human reply to the PR's decision card, with the card's data.

    A reply is a PR comment without the queue-runner marker, not by a bot,
    created after the cutoff: the card's last edit, or the last queue-runner
    comment on the PR or on one of the issues when that is later."""
    comments = pr_comments(repo, pr)
    cards = sorted((c for c in comments if is_card(c.get("body"))), key=lambda c: c.get("id") or 0)
    if not cards:
        return None
    card = cards[0]
    cutoff = max(card.get("updated_at") or card.get("created_at") or "", last_marked(comments))

    def replies(after):
        return [c for c in comments if not is_marked(c.get("body"))
                and (c.get("user") or {}).get("type") != BOT_USER_TYPE
                and (c.get("created_at") or "") > after]

    if not replies(cutoff):
        return None
    cutoff = max([cutoff, *(last_marked(pr_comments(repo, n)) for n in issues)])
    found = replies(cutoff)
    if not found:
        return None
    return max(found, key=lambda c: (c.get("created_at") or "", c.get("id") or 0)), read_data(card.get("body"))


def handback_rows(repo):
    """One row per open PR the human handed back to the loop for a rework."""
    issues = gh_json(STAGE_ISSUES, "api", "--paginate",
                     f"repos/{repo}/issues?state=open&labels={PR_LABEL}&per_page={PAGE_SIZE}")
    agent_issues = {i["number"]: label_names(i) for i in issues
                    if "pull_request" not in i and not label_names(i) & HANDBACK_SKIP_LABELS}
    if not agent_issues:
        return []
    prs = answer_json(STAGE_PRS, gh(STAGE_PRS, "pr", "list", "--repo", repo, "--state", "open",
                                    "--limit", str(GH_FETCH_LIMIT),
                                    "--json", "number,url,labels,closingIssuesReferences"))
    rows = []
    for pr in sorted(prs, key=lambda p: p["number"]):
        closes = sorted(i["number"] for i in pr.get("closingIssuesReferences") or []
                        if i.get("number") in agent_issues)
        if not closes:
            continue
        row = {"pr": pr["number"], "pr_url": pr.get("url", ""), "issues": closes,
               "trigger": None, "reply_url": None, "reply": None, "answer_problem": None}
        pr_labels = label_names(pr)
        waits = V.HUMAN_LABEL in pr_labels or any(V.HUMAN_LABEL in agent_issues[n] for n in closes)
        if REWORK_LABEL in pr_labels:
            row["trigger"] = TRIGGER_LABEL
        elif waits:
            found = human_reply(repo, pr["number"], closes)
            if found:
                reply, data = found
                row.update(trigger=TRIGGER_REPLY, reply_url=reply.get("html_url", ""),
                           reply=reply.get("body") or "",
                           answer_problem=answer_problem(reply.get("body"), data))
        if row["trigger"]:
            rows.append(row)
    return rows


# --- CLI ----------------------------------------------------------------------------

def repo_arg(value):
    if not re.match(r"^[^/\s]+/[^/\s]+$", value or ""):
        raise argparse.ArgumentTypeError(f"--repo must be owner/name, got {value!r}")
    return value


def pr_arg(value):
    try:
        number = int(value)
    except ValueError:
        number = 0
    if number <= 0:
        raise argparse.ArgumentTypeError(f"--pr must be a positive PR number, got {value!r}")
    return number


def add_input_args(p):
    p.add_argument("--input", required=True, help="the card input (JSON)")
    p.add_argument("--human", help="a /pre-merge HUMAN decisions file")
    p.add_argument("--gates", help="a pre-merge-verdict.py input; adds its blocking reasons")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    add_input_args(sub.add_parser("render", help="print the card body"))
    p_post = sub.add_parser("post", help="create or update the PR's decision card")
    p_post.add_argument("--repo", required=True, type=repo_arg)
    p_post.add_argument("--pr", required=True, type=pr_arg)
    add_input_args(p_post)
    p_wait = sub.add_parser("waiting", help="the 'Waiting on you' block")
    p_wait.add_argument("--repo", required=True, type=repo_arg)
    p_wait.add_argument("--json", action="store_true")
    p_back = sub.add_parser("handback", help="the PRs the human handed back for a rework (JSON)")
    p_back.add_argument("--repo", required=True, type=repo_arg)
    args = parser.parse_args(argv)

    try:
        if args.command == "handback":
            print(json.dumps(handback_rows(args.repo), indent=2))
            return EXIT_OK
        if args.command == "waiting":
            rows = waiting_rows(args.repo)
            sys.stdout.write(json.dumps(rows, indent=2) + "\n" if args.json else waiting_text(rows))
            return EXIT_OK
        body, data = build(args)
        if args.command == "render":
            sys.stdout.write(body)
            return EXIT_OK
        result = upsert(args.repo, args.pr, body, data)
    except Invalid as exc:
        print(f"queue-decision-card: invalid input: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except CardFailed as exc:
        print(json.dumps({"status": STATUS_FAILED, "stage": exc.stage, "error": exc.error}, indent=2))
        return EXIT_FAILED
    print(json.dumps(result, indent=2))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
