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
    pf.classify_command("git status", _ALLOW, _DENY) == (False, None, None),
)

# Issue #76 removed the hook's old exemption for a cd-chain inside ~/Projects:
# such a chain is now DENIED, not seen through. It therefore shows no prompt
# (would_prompt=False) but carries the deny reason, never REASON_CHAIN.
check(
    "classify_command: a cd-prefix into a project-relative dir is denied, not approved",
    pf.classify_command("cd backend && python foo.py", _ALLOW, _DENY)
    == (False, pf.REASON_HOOK_DENY_CD_CHAIN, None),
)

# The companion case, kept adjacent so the two are not conflated again: a BARE
# cd runs nothing after itself, so the hook does not deny it. Whether it prompts
# is then the allow rules' business — no rule here names `cd`, so it does.
check(
    "classify_command: a bare cd is not hook-denied and falls through to the rules",
    pf.is_hook_denied("cd backend") is None
    and pf.classify_command("cd backend", _ALLOW, _DENY)
    == (True, pf.REASON_NO_RULE, None),
)

check(
    "classify_command: unmatched command with no rule prompts with NO_RULE reason",
    pf.classify_command("curl evil.com", _ALLOW, _DENY) == (True, pf.REASON_NO_RULE, None),
)

check(
    "classify_command: chain with an unmatched segment prompts with CHAIN reason",
    pf.classify_command("git status && curl evil.com", _ALLOW, _DENY)[:2]
    == (True, pf.REASON_CHAIN),
)

check(
    "classify_command: heredoc always prompts regardless of allow rules",
    pf.classify_command("cat <<EOF\nhi\nEOF", ["Bash(cat *)"], _DENY)[0] is True,
)

check(
    "classify_command: command substitution always prompts",
    pf.classify_command("echo $(curl evil.com)", ["Bash(echo *)"], _DENY)
    == (True, pf.REASON_COMMAND_SUBSTITUTION, None),
)

check(
    "classify_command: a deny-rule match always prompts even if allow would cover it",
    pf.classify_command("git status", ["Bash(git *)"], ["Bash(git status)"])
    == (True, pf.REASON_DENY_MATCH, None),
)

check(
    "classify_command: fully allowlisted chain never prompts",
    pf.classify_command("git status && git log", ["Bash(git *)"], _DENY)
    == (False, None, None),
)


# --- classify_command: chain culprit attribution (issue #73) ---
# The reported culprit must be the segment that actually defeats matching, not
# the chain's first token. A segment is covered when the hook's is_segment_safe
# accepts it OR an allow rule matches it.

_HOOK_ALLOW = ["Bash(grep *)", "Bash(head *)", "Bash(git *)"]

check(
    "classify_command: a fully hook-safe pipe is not reported at all",
    pf.classify_command("grep -n x f | head", _HOOK_ALLOW, _DENY)
    == (False, None, None),
)

check(
    "classify_command: chain culprit is the sed segment, not the leading grep",
    pf.classify_command("grep -n x f | head; sed 's/a/b/' f", _HOOK_ALLOW, _DENY)
    == (True, pf.REASON_CHAIN, ["sed", "s/a/b/", "f"]),
)

# These two exercise find_chain_culprit directly rather than through
# classify_command. Since issue #96 a cd-chain never reaches the culprit search
# at all — is_hook_denied returns first — but the attribution logic below is
# still live for every other chain, and a cd segment is still the sharpest case
# for it: it is the one segment that may or may not be seen through depending
# only on where it points.
check(
    "find_chain_culprit: a harmless leading cd is not reported as the culprit",
    pf.find_chain_culprit(
        pf._hook.split_segments(
            "cd /home/jan/Projects/x && for i in 1 2; do echo $i; done"
        ),
        _HOOK_ALLOW,
    )
    == ["for", "i", "in", "1", "2"],
)

# A cd OUTSIDE ~/Projects is genuinely the culprit: hook-auto-approve-bash.py
# deliberately refuses to see through it, so "cd" really is the first segment
# nothing covers. Reporting `for` here would name a segment that is not the
# reason the command prompts.
check(
    "find_chain_culprit: a cd outside ~/Projects IS the culprit",
    pf.find_chain_culprit(
        pf._hook.split_segments("cd /x && for i in 1 2; do echo $i; done"),
        _HOOK_ALLOW,
    )
    == ["cd", "/x"],
)

check(
    "classify_command: an allow rule covering a segment keeps it off the culprit spot",
    pf.classify_command("git status && curl evil.com", _ALLOW, _DENY)
    == (True, pf.REASON_CHAIN, ["curl", "evil.com"]),
)


# --- classify_command: hook denies are not prompts (issue #73) ---
# hook-auto-approve-bash.py DENIES these outright. A deny shows no permission
# prompt at all: it is the opposite signal (the agent reached for the wrong
# tool) and needs a different remedy, so it must not be counted as friction.

check(
    "classify_command: a sed file read is reported as a hook deny, not a prompt",
    pf.classify_command("grep x f | head; sed -n '1,5p' f", _HOOK_ALLOW, _DENY)
    == (False, pf.REASON_HOOK_DENY_SED_READ, None),
)

check(
    "classify_command: inline Python file read is reported as a hook deny",
    pf.classify_command(
        "python3 -c \"print(open('/etc/hosts').read())\"", _HOOK_ALLOW, _DENY
    )
    == (False, pf.REASON_HOOK_DENY_PYTHON_READ, None),
)

check(
    "classify_command: an until+sleep file wait loop is reported as a hook deny",
    pf.classify_command(
        "until [ -f /tmp/done ]; do sleep 2; done", _HOOK_ALLOW, _DENY
    )
    == (False, pf.REASON_HOOK_DENY_WAIT_LOOP, None),
)

check(
    "classify_command: a hook deny outranks a matching deny rule's prompt verdict",
    pf.classify_command("sed -n '1,5p' f", _HOOK_ALLOW, ["Bash(sed *)"])[1]
    == pf.REASON_HOOK_DENY_SED_READ,
)

check(
    "classify_command: a real sed stream edit still prompts, not a hook deny",
    pf.classify_command("sed -i 's/a/b/' f", _HOOK_ALLOW, _DENY)[1] == pf.REASON_NO_RULE,
)

# CLAUDE.md explicitly permits python -c for calculation. It must never land in
# a deny category — whether it prompts is a separate question decided by the
# allow rules (python3 has no rule here, so it legitimately prompts as NO_RULE).
check(
    "classify_command: python doing arithmetic is untouched by the deny category",
    pf.classify_command('python3 -c "print(2 + 2)"', _HOOK_ALLOW, _DENY)[1]
    not in pf.HOOK_DENY_REASONS,
)

check(
    "is_hook_denied exposes the matching rule name",
    pf.is_hook_denied("sed -n '1,5p' f") == pf.REASON_HOOK_DENY_SED_READ
    and pf.is_hook_denied("git status") is None,
)


# --- classify_command: the cd-chain deny (issue #96) ---
# Issue #76 made the hook deny EVERY `cd <dir> && <cmd>`, project-relative
# included. is_hook_denied() must mirror that branch, or the single most common
# denied shape gets filed as permission-rule friction and points the reader at
# the allowlist when the fix is to rewrite the command as env -C / git -C /
# npm --prefix.

check(
    "is_hook_denied: a cd-prefixed chain is a hook deny",
    pf.is_hook_denied("cd backend && python foo.py") == pf.REASON_HOOK_DENY_CD_CHAIN,
)

check(
    "is_hook_denied: the cd-chain deny is registered in HOOK_DENY_REASONS",
    pf.REASON_HOOK_DENY_CD_CHAIN in pf.HOOK_DENY_REASONS,
)

# A cd outside ~/Projects is the same deny — the hook does not distinguish, and
# neither may the report.
check(
    "is_hook_denied: a cd-chain outside ~/Projects is the same deny",
    pf.is_hook_denied("cd /etc && cat passwd") == pf.REASON_HOOK_DENY_CD_CHAIN,
)

check(
    "classify_command: a cd-prefixed chain is reported as a hook deny, not CHAIN",
    pf.classify_command("cd backend && python foo.py", _HOOK_ALLOW, _DENY)
    == (False, pf.REASON_HOOK_DENY_CD_CHAIN, None),
)

# Branch ORDER, per is_hook_denied's docstring contract: the category reported
# must be the message the agent actually saw. hook-auto-approve-bash.py's main()
# evaluates sed-read before its cd-chain check, so a command that is both lands
# on the sed deny.
check(
    "is_hook_denied: an earlier hook branch outranks the cd-chain deny",
    pf.is_hook_denied("cd backend && sed -n '1,5p' f") == pf.REASON_HOOK_DENY_SED_READ,
)

# REASON_CD_PREFIX survives the chain deny rather than being dead code: this is
# the SINGLE-segment form, `cd <dir> <cmd>` with no && between them.
# command_has_cd_prefix_chain needs a segment boundary to fire, so the hook does
# not deny this, and classify_command's line-334 branch is still the only thing
# that explains why it prompts. Both halves asserted together — the deny's
# absence is what makes the reason reachable.
check(
    "classify_command: a single-segment cd prefix still reports CD_PREFIX",
    pf.is_hook_denied("cd /home/jan/Projects/x jq .") is None
    and pf.classify_command("cd /home/jan/Projects/x jq .", _ALLOW, _DENY)
    == (True, pf.REASON_CD_PREFIX, None),
)


# --- a segment is never "covered" by a rule that glob-matched substitution ---
# An allow rule is matched against the segment's raw text, so `Bash(grep *)`
# happily matches `grep -n $(cat f) x`. The hook refuses such a segment, and
# permission matching does not see through it either, so the command really
# does prompt — it must not be written off as covered just because the glob hit.

check(
    "coverage: command substitution in a segment defeats an allow-rule match",
    not pf._is_segment_covered(["grep", "-n", "$(cat", "f)", "x"], ["Bash(grep *)"]),
)

check(
    "coverage: process substitution in a segment defeats an allow-rule match",
    not pf._is_segment_covered(["grep", "-n", "x", "<(cat", "f)"], ["Bash(grep *)"]),
)

check(
    "coverage: a heredoc in a segment defeats an allow-rule match",
    not pf._is_segment_covered(["cat", "<<", "EOF"], ["Bash(cat *)"]),
)

check(
    "coverage: a plain segment is still covered by its allow rule",
    pf._is_segment_covered(["curl", "https://example.com"], ["Bash(curl *)"]),
)

# End-to-end: the whole chain must still be reported, with the substituting
# segment named as the culprit. Before this fix these returned (False, None,
# None) — no friction at all — while the hook declined to approve them.
_SUBST_ALLOW = ["Bash(grep *)", "Bash(head *)", "Bash(git *)"]

check(
    "classify: a chain whose segments all glob-match but one substitutes still prompts",
    pf.classify_command("grep -n $(cat f) x | head", _SUBST_ALLOW, _DENY)[:2]
    == (True, pf.REASON_CHAIN),
)

# The culprit must be SELECTED, not just "the first segment": here the
# substituting segment sits in the middle, so a naive `return segments[0]`
# would answer `head` and fail.
check(
    "classify: a mid-chain substituting segment is picked out as the culprit",
    pf.classify_command("head f | grep $(cat g) y | git status", _SUBST_ALLOW, _DENY)[2]
    == ["grep", "$(cat", "g)", "y"],
)

check(
    "classify: process substitution in a chain still prompts",
    pf.classify_command("grep -n x <(cat f) | head", _SUBST_ALLOW, _DENY)[:2]
    == (True, pf.REASON_CHAIN),
)

check(
    "classify: substitution in a LATER chain segment still prompts",
    pf.classify_command("git log | head; grep -n x $(echo f)", _SUBST_ALLOW, _DENY)[:2]
    == (True, pf.REASON_CHAIN),
)


# --- rewriting hooks (issue #73) ---
# A PreToolUse hook may REWRITE a command and allow it in the same response.
# RTK's does: fed `grep -rn foo src` it answers permissionDecision "allow" with
# updatedInput.command = "rtk grep -rn foo src". Two consequences the scanner
# must model, both verified against the installed rtk 0.45.0 and 21k real
# transcript Bash calls:
#
#   1. The transcript stores what the MODEL emitted, not the rewrite — the
#      rewrite lives in the hook's RESPONSE (updatedInput), which is never
#      written back to tool_use.input. So an `rtk`-prefixed transcript entry is
#      a command the model typed itself. hook-auto-approve-bash.py judges such
#      an entry as the wrapped command (issue #102), so `rtk grep` is covered
#      the way `grep` is; `rtk jq` is still REAL friction, as `jq` would be.
#   2. The hook's own prefixed form (`rtk <cmd>`) is what it actually emits, so
#      opting in marks THAT form as covered. Bare commands are not assumed
#      covered: rtk answers "allow" for `grep` but rewrites `jq`/`curl` with no
#      permissionDecision at all, so coverage is per-command and not derivable
#      from the prefix.
#
# The prefix is configurable, not hard-coded to one tool: any rewriting hook
# has this shape.

check(
    "rewrite prefix: an rtk-prefixed segment is covered when rtk is configured",
    pf._is_segment_covered(["rtk", "grep", "foo"], [], rewrite_prefixes=("rtk",)),
)

check(
    "rewrite prefix: an rtk-wrapped non-allowlisted command is NOT covered by default",
    not pf._is_segment_covered(["rtk", "jq", "."], []),
)

# `jq` is on neither the hook's ALLOWLIST nor any allow rule here, so it is
# covered ONLY via the rewrite prefix — which is what this asserts. (`grep`
# would pass either way, proving nothing.)
check(
    "rewrite prefix: an rtk-wrapped non-allowlisted command is covered",
    pf._is_segment_covered(["rtk", "jq", "."], [], rewrite_prefixes=("rtk",)),
)

# A BARE command is deliberately NOT covered by the prefix, even though the
# hook rewrites it. Verified against rtk 0.45.0: the rewrite response carries
# `permissionDecision: "allow"` for `grep`, but for `jq` and `curl` it rewrites
# with NO permissionDecision at all — so matching still runs on the rewritten
# command and may well prompt. Which commands get the allow is RTK's internal
# business and not derivable from the prefix, so the scanner only models the
# half it can verify: the prefixed form.
check(
    "rewrite prefix: a bare command is not assumed covered by the rewriting hook",
    not pf._is_segment_covered(["jq", ".", "x.json"], [], rewrite_prefixes=("rtk",)),
)

check(
    "rewrite prefix: an unrelated uncovered command stays uncovered",
    not pf._is_segment_covered(["curl", "evil.com"], [], rewrite_prefixes=("rtk",)),
)

check(
    "rewrite prefix: classify_command threads the prefix through to the culprit",
    pf.classify_command(
        "rtk jq . x.json | head; curl evil.com", ["Bash(head *)"], [], rewrite_prefixes=("rtk",)
    )
    == (True, pf.REASON_CHAIN, ["curl", "evil.com"]),
)

check(
    "rewrite prefix: without it, the rtk segment itself is the culprit",
    pf.classify_command("rtk jq . x.json | head; curl evil.com", ["Bash(head *)"], [])
    == (True, pf.REASON_CHAIN, ["rtk", "jq", ".", "x.json"]),
)

check(
    "rewrite prefix: a wrapped command is not friction at all",
    pf.classify_command("rtk jq . x.json", [], [], rewrite_prefixes=("rtk",))[0] is False,
)


# --- model-typed rtk prefix (issue #102) ---
# The auto-approve hook judges `rtk <cmd>` / `rtk proxy <cmd>` as <cmd>, so an
# rtk-wrapped command that is approved alone never prompts and must not show up
# as friction — with or without --rewrite-prefix.

check(
    "rtk #102: rtk grep is not friction by default",
    pf.classify_command("rtk grep -rn permissionDecision bin", [], [])
    == (False, None, None),
)

check(
    "rtk #102: rtk proxy git log is not friction by default",
    pf.classify_command("rtk proxy git log --oneline -20", [], [])
    == (False, None, None),
)

check(
    "rtk #102: an rtk grep segment in a chain is not the culprit",
    pf.classify_command('rtk grep -rn "TODO" bin | sort; curl evil.com', [], [])
    == (True, pf.REASON_CHAIN, ["curl", "evil.com"]),
)

check(
    "rtk #102: rtk curl is still friction, as curl would be",
    pf.classify_command("rtk curl https://example.com", [], [])[0] is True,
)


# --- _pattern_key: group chain friction on the culprit (issue #73) ---

check(
    "_pattern_key: without a culprit, groups on the command's first token",
    pf._pattern_key("curl evil.com", pf.REASON_NO_RULE)
    == f"curl — {pf.REASON_NO_RULE}",
)

check(
    "_pattern_key: with a culprit, groups on the culprit's first token",
    pf._pattern_key("grep -n x f | head; sed 's/a/b/' f", pf.REASON_CHAIN, ["sed", "s/a/b/", "f"])
    == f"sed — {pf.REASON_CHAIN}",
)

# A `cd <dir> <cmd>` segment (no separator) keeps cd and the command in ONE
# segment, which is the shape strip_cd_prefix exists for: the key must name the
# command, since that is what an allow rule or wrapper would have to cover.
check(
    "_pattern_key: strips a cd prefix off the culprit so the real command is the key",
    pf._pattern_key(
        "cd /home/jan/Projects/x rtk grep foo",
        pf.REASON_CHAIN,
        ["cd", "/home/jan/Projects/x", "rtk", "grep", "foo"],
    )
    == f"rtk — {pf.REASON_CHAIN}",
)

# And the end-to-end path: a covered segment plus an uncovered one must key on
# the uncovered command. This used a cd-prefixed chain until issue #96 made such
# a chain a hook deny, which never reaches a culprit at all — an allowlisted
# leading segment puts the same question to the same code.
check(
    "classify+_pattern_key: a chain keys on the uncovered command, not the first",
    pf._pattern_key(
        "git status && rtk jq . x.json",
        *pf.classify_command("git status && rtk jq . x.json", ["Bash(git *)"], [])[1:],
    )
    == f"rtk — {pf.REASON_CHAIN}",
)

check(
    "_pattern_key: strips an env-var prefix off the culprit",
    pf._pattern_key("FOO=1 jq .", pf.REASON_CHAIN, ["FOO=1", "jq", "."])
    == f"jq — {pf.REASON_CHAIN}",
)

check(
    "_pattern_key: keeps the reason in the key so /retro can still read it",
    pf.REASON_CHAIN
    in pf._pattern_key("a | sed x", pf.REASON_CHAIN, ["sed", "x"]),
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


# --- analyze_friction end-to-end ---

e2e_tmpdir = tempfile.mkdtemp(prefix="permission-friction-e2e-test-")
try:
    fake_home = Path(e2e_tmpdir) / "home"
    fake_home.mkdir(parents=True)
    (fake_home / "settings.json").write_text(
        json.dumps({"permissions": {"allow": ["Bash(git *)"], "deny": []}})
    )

    fake_projects_root = Path(e2e_tmpdir) / "projects"
    project_dir = "/home/jan/Projects/fake-e2e-project"
    encoded = project_dir.replace(os.sep, "-")
    transcript_dir = fake_projects_root / encoded
    transcript_dir.mkdir(parents=True)

    now = datetime.now(timezone.utc)
    ts = now.isoformat().replace("+00:00", "Z")

    def _bash_line(tool_id, command):
        return json.dumps(
            {
                "timestamp": ts,
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": tool_id,
                            "name": "Bash",
                            "input": {"command": command},
                        }
                    ]
                },
            }
        )

    def _denial_line(tool_id):
        return json.dumps(
            {
                "timestamp": ts,
                "message": {
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": tool_id,
                            "content": "The user doesn't want to proceed with this tool use.",
                        }
                    ]
                },
            }
        )

    # session 1: two curl calls (unmatched, one denied), one clean git call
    (transcript_dir / "session-1.jsonl").write_text(
        "\n".join(
            [
                _bash_line("t1", "curl evil.com"),
                _denial_line("t1"),
                _bash_line("t2", "curl good.com"),
                _bash_line("t3", "git status"),
            ]
        )
    )
    # session 2: another curl call (unmatched) -> pattern recurs across 2 sessions
    (transcript_dir / "session-2.jsonl").write_text(
        "\n".join([_bash_line("t4", "curl third.com")])
    )

    original_claude_home = pf.CLAUDE_HOME
    original_transcripts_dir = pf.PROJECTS_TRANSCRIPTS_DIR
    pf.CLAUDE_HOME = fake_home
    pf.PROJECTS_TRANSCRIPTS_DIR = fake_projects_root
    try:
        report = pf.analyze_friction(project_dir, days=30)
    finally:
        pf.CLAUDE_HOME = original_claude_home
        pf.PROJECTS_TRANSCRIPTS_DIR = original_transcripts_dir

    check("analyze_friction: total_calls counts every Bash tool_use", report["total_calls"] == 4)
    check(
        "analyze_friction: prompted_estimate excludes the allowlisted git call",
        report["prompted_estimate"] == 3,
    )
    check("analyze_friction: denied counts the one rejected call", report["denied"] == 1)
    check("analyze_friction: exactly one pattern group (curl, NO_RULE)", len(report["patterns"]) == 1)
    curl_pattern = report["patterns"][0]
    check("analyze_friction: curl pattern count is 3", curl_pattern["count"] == 3)
    check(
        "analyze_friction: curl pattern recurs across both sessions",
        curl_pattern["sessions"] == 2,
    )

    text_report = pf.format_report_text(report, days=30)
    check("format_report_text: mentions recurring marker for sessions>=2", "recurring" in text_report)
    check("format_report_text: includes total call count", "4" in text_report)

    # --- hook denies stay out of prompted_estimate (issue #73) ---
    # A chain whose sed segment the hook DENIES shows no prompt at all. It must
    # be reported in its own bucket, never inflate the friction estimate, and
    # never create a `grep`/`sed` pattern row that /retro would act on.
    deny_dir = fake_projects_root / "-home-jan-Projects-fake-deny-project"
    deny_dir.mkdir(parents=True)
    (deny_dir / "session-d.jsonl").write_text(
        "\n".join(
            [
                _bash_line("d1", "grep -rn TODO src | head; sed -n '1,20p' src/main.py"),
                _bash_line("d2", "grep -rn TODO src | head; sed -n '5,9p' README.md"),
                _bash_line("d3", "curl https://api.example.com/health"),
            ]
        )
    )

    pf.CLAUDE_HOME = fake_home
    pf.PROJECTS_TRANSCRIPTS_DIR = fake_projects_root
    try:
        deny_report = pf.analyze_friction("/home/jan/Projects/fake-deny-project", days=30)
    finally:
        pf.CLAUDE_HOME = original_claude_home
        pf.PROJECTS_TRANSCRIPTS_DIR = original_transcripts_dir

    check(
        "analyze_friction: hook-denied sed reads are excluded from prompted_estimate",
        deny_report["prompted_estimate"] == 1,
    )
    check(
        "analyze_friction: hook-denied calls are reported in their own bucket",
        [(d["reason"], d["count"]) for d in deny_report["hook_denied"]]
        == [(pf.REASON_HOOK_DENY_SED_READ, 2)],
    )
    check(
        "analyze_friction: a hook-denied chain creates no pattern row",
        [p["pattern"] for p in deny_report["patterns"]]
        == [f"curl — {pf.REASON_NO_RULE}"],
    )
    check(
        "format_report_text: surfaces the hook-denied bucket",
        "denied by hook" in pf.format_report_text(deny_report, days=30),
    )

    # --- the culprit is explicit in both reports (issue #73) ---
    # Reading the culprit out of the `pattern` string means parsing it back
    # out, and the `example` is the whole chain — so neither tells a consumer
    # which segment prompted. Both reports name it outright.
    culprit_dir = fake_projects_root / "-home-jan-Projects-fake-culprit-project"
    culprit_dir.mkdir(parents=True)
    (culprit_dir / "session-c.jsonl").write_text(
        "\n".join(
            [
                _bash_line("c1", "git log --oneline | head -20; jq -r '.version' package.json"),
                _bash_line("c2", "git diff --stat | head; jq '.scripts' package.json"),
            ]
        )
    )

    pf.CLAUDE_HOME = fake_home
    pf.PROJECTS_TRANSCRIPTS_DIR = fake_projects_root
    try:
        culprit_report = pf.analyze_friction(
            "/home/jan/Projects/fake-culprit-project", days=30
        )
    finally:
        pf.CLAUDE_HOME = original_claude_home
        pf.PROJECTS_TRANSCRIPTS_DIR = original_transcripts_dir

    row = culprit_report["patterns"][0]
    check(
        "analyze_friction: the JSON row carries the culprit token",
        row.get("culprit") == "jq",
    )
    check(
        "analyze_friction: the JSON row carries the culprit segment verbatim",
        row.get("culprit_example") == "jq -r .version package.json",
    )
    # A non-chain reason names the whole command, so there is no sub-segment to
    # attribute — the field must be absent rather than echoing the first token.
    check(
        "analyze_friction: rows for a non-chain reason carry no culprit",
        all(
            p.get("culprit") is None
            for p in deny_report["patterns"]
            if pf.REASON_CHAIN not in p["pattern"]
        )
        and any(pf.REASON_CHAIN not in p["pattern"] for p in deny_report["patterns"]),
    )

    culprit_text = pf.format_report_text(culprit_report, days=30)
    check(
        "format_report_text: names the culprit segment, not just the full chain",
        "culprit: jq -r .version package.json" in culprit_text,
    )

    # graceful handling of a project with no transcripts at all (AC requirement)
    pf.CLAUDE_HOME = fake_home
    pf.PROJECTS_TRANSCRIPTS_DIR = fake_projects_root
    try:
        empty_report = pf.analyze_friction("/home/jan/Projects/never-scanned", days=30)
    finally:
        pf.CLAUDE_HOME = original_claude_home
        pf.PROJECTS_TRANSCRIPTS_DIR = original_transcripts_dir

    check(
        "analyze_friction: empty/missing transcript dir yields a zeroed report, not a crash",
        empty_report
        == {
            "total_calls": 0,
            "prompted_estimate": 0,
            "denied": 0,
            "hook_denied": [],
            "patterns": [],
        },
    )
finally:
    shutil.rmtree(e2e_tmpdir, ignore_errors=True)


print(f"\n{passed} passed, {failed} failed")
if failed:
    raise SystemExit(1)
