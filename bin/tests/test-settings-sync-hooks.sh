#!/bin/bash
# Tests for settings-sync-hooks.sh.
#
# Usage:
#   bin/tests/test-settings-sync-hooks.sh
#
# Every run passes --settings and --template, so the real ~/.claude/settings.json
# is never read or written. The live fixture mirrors the shape of a real
# settings.json that drifted from the template: two template groups merged into
# one, hooks the template never had, keys the sync must not touch.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../settings-sync-hooks.sh}"

if [[ ! -f "$SCRIPT" ]]; then
    echo "script not found: $SCRIPT" >&2
    exit 1
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi
}

contains() { # haystack needle -> yes/no
    case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac
}

same() { cmp -s "$1" "$2" && echo same || echo differs; }

# Evaluates a Python expression over the JSON file $1, bound to `d`.
jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($2)" < "$1"; }

# Lists every hook entry of the JSON file $1 as "event|matcher|command".
entries() {
    python3 -c '
import json, sys
d = json.load(sys.stdin)
for event, groups in d.get("hooks", {}).items():
    for group in groups:
        for hook in group.get("hooks", []):
            print(event, group.get("matcher"), hook.get("command"), sep="|")
' < "$1"
}

count_entry() { entries "$1" | grep -cxF "$2"; }

# Backups written by the sync for settings file $1, one per line, oldest first.
backups() { compgen -G "$1.*.bak" | sort; }
count_backups() { backups "$1" | grep -c .; }

FAKE_HOME="$T/home"
mkdir -p "$FAKE_HOME"

run() { env HOME="$FAKE_HOME" bash "$SCRIPT" --template "$T/template.jsonc" "$@"; }

cat > "$T/template.jsonc" <<'EOF'
// Template fixture: the hooks the toolkit ships.
{
  "permissions": {"allow": ["Bash(git *)"]},
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "~/.claude/bin/approve.sh"},
          {"type": "command", "command": "~/.claude/bin/destructive.sh"},
          // New since the live file was installed:
          {"type": "command", "command": "~/.claude/bin/foreign-worktree.sh"}
        ]
      }
    ],
    "PostToolUse": [
      {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "~/.claude/bin/lint.sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/bin/trailer.sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/bin/prune.sh"}]},
      {"matcher": "Write", "hooks": [{"type": "command", "command": "__HOME__/bin/home-hook.sh"}]}
    ],
    // An event the live file does not have at all, without a matcher.
    "Stop": [
      {"hooks": [{"type": "command", "command": "~/.claude/bin/escalate.sh", "timeout": 5}]}
    ]
  }
}
EOF

# Live fixture. home-hook.sh is written with HOME already expanded, as
# install.sh would have written it.
write_live() { # path
    cat > "$1" <<EOF
{
  "permissions": {"allow": ["Bash(git *)", "Bash(rtk *)"]},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "~/.claude/bin/approve.sh"},
        {"type": "command", "command": "~/.claude/bin/destructive.sh"}
      ]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook claude"}]}
    ],
    "PostToolUse": [
      {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "~/.claude/bin/lint.sh"}]},
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "~/.claude/bin/trailer.sh"},
        {"type": "command", "command": "~/.claude/bin/prune.sh"}
      ]},
      {"matcher": "Write", "hooks": [{"type": "command", "command": "$FAKE_HOME/bin/home-hook.sh"}]}
    ],
    "SessionStart": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "bash herdr.sh session", "timeout": 10}]}
    ]
  },
  "sandbox": {"network": {"allowedDomains": ["localhost"]}},
  "theme": "dark-daltonized"
}
EOF
}

echo "== 1. missing template hooks are added =="
LIVE="$T/live.json"
write_live "$LIVE"
cp "$LIVE" "$T/live.orig"
chmod 600 "$LIVE"
# A backup someone made by hand under the obvious name must survive the sync.
printf 'hand-made backup\n' > "$LIVE.bak"
out=$(run --settings "$LIVE" 2>&1); status=$?
check "exit 0" "0" "$status"
check "foreign-worktree added once" "1" \
    "$(count_entry "$LIVE" "PreToolUse|Bash|~/.claude/bin/foreign-worktree.sh")"
check "added to the first Bash group, after its own hooks" \
    "['~/.claude/bin/approve.sh', '~/.claude/bin/destructive.sh', '~/.claude/bin/foreign-worktree.sh']" \
    "$(jq_py "$LIVE" "[h['command'] for h in d['hooks']['PreToolUse'][0]['hooks']]")"
check "missing event created" "1" \
    "$(count_entry "$LIVE" "Stop|None|~/.claude/bin/escalate.sh")"
check "entry copied verbatim, extra fields included" "5" \
    "$(jq_py "$LIVE" "d['hooks']['Stop'][0]['hooks'][0]['timeout']")"
check "new event group has no matcher key" "False" \
    "$(jq_py "$LIVE" "'matcher' in d['hooks']['Stop'][0]")"
check "reports the added foreign-worktree hook" "yes" \
    "$(contains "$out" "added: PreToolUse [Bash] ~/.claude/bin/foreign-worktree.sh")"
check "reports the added Stop hook" "yes" \
    "$(contains "$out" "added: Stop [no matcher] ~/.claude/bin/escalate.sh")"
check "reports exactly two additions" "2" "$(grep -c '^added: ' <<< "$out")"

echo "== 2. entries already present are not added again =="
# trailer.sh and prune.sh are separate groups in the template but share one
# group live; comparing whole groups would wrongly add them back.
check "trailer.sh still once" "1" \
    "$(count_entry "$LIVE" "PostToolUse|Bash|~/.claude/bin/trailer.sh")"
check "prune.sh still once" "1" \
    "$(count_entry "$LIVE" "PostToolUse|Bash|~/.claude/bin/prune.sh")"
check "no new PostToolUse group" "3" "$(jq_py "$LIVE" "len(d['hooks']['PostToolUse'])")"
check "__HOME__ command compared after expansion" "1" \
    "$(count_entry "$LIVE" "PostToolUse|Write|$FAKE_HOME/bin/home-hook.sh")"

echo "== 3. everything else in the live file is preserved =="
check "user hook rtk kept" "1" "$(count_entry "$LIVE" "PreToolUse|Bash|rtk hook claude")"
check "SessionStart kept with its timeout" "10" \
    "$(jq_py "$LIVE" "d['hooks']['SessionStart'][0]['hooks'][0]['timeout']")"
check "permissions untouched (not merged from template)" "['Bash(git *)', 'Bash(rtk *)']" \
    "$(jq_py "$LIVE" "d['permissions']['allow']")"
check "other keys untouched" "dark-daltonized localhost" \
    "$(jq_py "$LIVE" "d['theme'] + ' ' + d['sandbox']['network']['allowedDomains'][0]")"
check "top-level key order kept" "['permissions', 'hooks', 'sandbox', 'theme']" \
    "$(jq_py "$LIVE" "list(d)")"
check "event order kept, new event last" "['PreToolUse', 'PostToolUse', 'SessionStart', 'Stop']" \
    "$(jq_py "$LIVE" "list(d['hooks'])")"
check "file mode kept" "600" "$(stat -c %a "$LIVE")"

echo "== 4. a backup of the original is written =="
check "exactly one backup written" "1" "$(count_backups "$LIVE")"
BAK=$(backups "$LIVE")
check "backup named <settings>.<timestamp>.bak" "yes" \
    "$([[ "$BAK" =~ \.[0-9]{8}-[0-9]{6}(-[0-9]+)?\.bak$ ]] && echo yes || echo no)"
check "backup holds the original bytes" "same" "$(same "$T/live.orig" "$BAK")"
check "summary names the backup" "yes" "$(contains "$out" "$BAK")"
check "existing .bak left alone" "hand-made backup" "$(cat "$LIVE.bak")"

echo "== 5. a second run changes nothing =="
cp "$LIVE" "$T/after-first"
cp "$BAK" "$T/bak-after-first"
out=$(run --settings "$LIVE" 2>&1); status=$?
check "second run exit 0" "0" "$status"
check "second run file byte-identical" "same" "$(same "$T/after-first" "$LIVE")"
check "second run writes no new backup" "1" "$(count_backups "$LIVE")"
check "second run leaves the backup alone" "same" "$(same "$T/bak-after-first" "$BAK")"
check "second run reports up to date" "yes" "$(contains "$out" "up to date")"
check "second run adds nothing" "0" "$(grep -c '^added: ' <<< "$out")"

echo "== 6. --dry-run reports and writes nothing =="
DRY="$T/dry.json"
write_live "$DRY"
cp "$DRY" "$T/dry.orig"
out=$(run --settings "$DRY" --dry-run 2>&1); status=$?
check "dry-run exit 0" "0" "$status"
check "dry-run names the missing hook" "yes" \
    "$(contains "$out" "would add: PreToolUse [Bash] ~/.claude/bin/foreign-worktree.sh")"
check "dry-run reports two" "2" "$(grep -c '^would add: ' <<< "$out")"
check "dry-run leaves the file alone" "same" "$(same "$T/dry.orig" "$DRY")"
check "dry-run writes no backup" "0" "$(count_backups "$DRY")"

echo "== 6b. two syncs within one second keep both backups =="
# Timestamps have one-second resolution; the second backup must not replace
# the first.
QUICK="$T/quick.json"
write_live "$QUICK"
cp "$QUICK" "$T/quick.first-orig"
run --settings "$QUICK" >/dev/null 2>&1
printf '{\n  "theme": "second"\n}\n' > "$QUICK"
cp "$QUICK" "$T/quick.second-orig"
run --settings "$QUICK" >/dev/null 2>&1
check "two backups" "2" "$(count_backups "$QUICK")"
matches() { # original -> how many backups of $QUICK equal it
    local n=0 b
    while read -r b; do cmp -s "$1" "$b" && n=$((n+1)); done < <(backups "$QUICK")
    echo "$n"
}
check "first original kept" "1" "$(matches "$T/quick.first-orig")"
check "second original kept" "1" "$(matches "$T/quick.second-orig")"

echo "== 7. a live file without hooks gets every template hook =="
BARE="$T/bare.json"
printf '{\n  "theme": "dark"\n}\n' > "$BARE"
run --settings "$BARE" >/dev/null 2>&1
check "all eight template hooks added" "8" "$(entries "$BARE" | wc -l | tr -d ' ')"
check "groups keep the template's matchers" "['Bash']" \
    "$(jq_py "$BARE" "[g.get('matcher') for g in d['hooks']['PreToolUse']]")"
check "theme kept" "dark" "$(jq_py "$BARE" "d['theme']")"

echo "== 8. a live event without a matching matcher gets a new group =="
OTHER="$T/other.json"
cat > "$OTHER" <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Write", "hooks": [{"type": "command", "command": "mine.sh"}]}]}}
EOF
run --settings "$OTHER" >/dev/null 2>&1
check "own group untouched" "['mine.sh']" \
    "$(jq_py "$OTHER" "[h['command'] for h in d['hooks']['PreToolUse'][0]['hooks']]")"
check "Bash group appended after it" "['Write', 'Bash']" \
    "$(jq_py "$OTHER" "[g.get('matcher') for g in d['hooks']['PreToolUse']]")"

echo "== 9. invalid or missing live settings are refused =="
BROKEN="$T/broken.json"
printf '{ "hooks": \n' > "$BROKEN"
cp "$BROKEN" "$T/broken.orig"
out=$(run --settings "$BROKEN" 2>&1); status=$?
check "invalid JSON exits 1" "1" "$status"
check "invalid JSON is named" "yes" "$(contains "$out" "not valid JSON")"
check "invalid file left alone" "same" "$(same "$T/broken.orig" "$BROKEN")"
check "invalid file gets no backup" "0" "$(count_backups "$BROKEN")"
run --settings "$T/nope.json" >/dev/null 2>&1
check "missing live file exits 1" "1" "$?"
check "missing live file is not created" "absent" \
    "$([[ -e "$T/nope.json" ]] && echo present || echo absent)"
printf '[1, 2]\n' > "$T/array.json"
run --settings "$T/array.json" >/dev/null 2>&1
check "non-object JSON exits 1" "1" "$?"

echo "== 10. usage errors =="
run --settings "$LIVE" --bogus >/dev/null 2>&1
check "unknown option exits 2" "2" "$?"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
