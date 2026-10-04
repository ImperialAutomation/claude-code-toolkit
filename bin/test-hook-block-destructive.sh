#!/bin/bash
# Standalone tests for hook-block-destructive.sh.
#
# Run: bash bin/test-hook-block-destructive.sh
#
# Drives the REAL hook with a JSON payload on stdin (the same shape Claude Code
# sends) and asserts on its exit code: 2 = blocked, 0 = allowed.
#
# The rm cases carry the most weight. The guard's rule is "a force-recursive rm
# may target a path UNDER /tmp, nothing else", which the earlier substring
# patterns could not express: they blocked every /tmp scratch cleanup (a false
# positive agents hit routinely) while letting `rm -rf /tmp/a /usr` through on
# the strength of its first operand.
#
# The SQL cases are paired on purpose: each destructive statement sits next to
# the form that must still be allowed (an unqualified delete against a qualified
# one, a statement being executed against the same statement being grepped for).
# A guard is only as good as its agreement across equivalent phrasings — the
# issue #67 bypass was not a missing pattern so much as two phrasings of one
# action getting two different answers.
#
# When adding a case, check it actually constrains the hook: break the matching
# line in hook-block-destructive.sh, confirm THIS test goes red, then revert. A
# case that stays green under that mutation documents an intention without
# testing it. Two cases here exist only because that check caught them passing
# for the wrong reason.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook-block-destructive.sh"
pass=0
fail=0

run() { # run "<command>" <BLOCK|ALLOW>
    local cmd="$1" expect="$2" rc got
    printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | "$HOOK" >/dev/null 2>&1
    rc=$?
    got=ALLOW
    [ "$rc" -eq 2 ] && got=BLOCK
    if [ "$got" = "$expect" ]; then
        pass=$((pass + 1))
        printf 'PASS  %-6s %s\n' "$got" "$cmd"
    else
        fail=$((fail + 1))
        printf 'FAIL  got=%-6s want=%-6s %s\n' "$got" "$expect" "$cmd"
    fi
}

# --- rm: scratch cleanup under /tmp is allowed ---
# Agents write temp files to /tmp by convention (see global CLAUDE.md's
# tmp-filename scheme), so removing their own scratch dirs is routine work.
run "rm -rf /tmp/mutdir"                 ALLOW
run "rm -rf /tmp/claude-scratch/foo"     ALLOW
run "rm -fr /tmp/mutdir"                 ALLOW
run "rm -rf /tmp/x.json"                 ALLOW
run "git status; rm -rf /tmp/scratch"    ALLOW
run "mkdir -p /tmp/a && rm -rf /tmp/a"   ALLOW

# --- rm: everything else stays blocked ---
# Bare /tmp is NOT scratch cleanup — it wipes every concurrent agent's files.
run "rm -rf /tmp"                        BLOCK
run "rm -rf /tmp/"                       BLOCK
run "rm -rf /"                           BLOCK
run "rm -rf /usr"                        BLOCK
run "rm -rf /etc"                        BLOCK
run "rm -rf /var/log"                    BLOCK
run "rm -rf /home/jan/Projects/x"        BLOCK
# /tmpfoo is a sibling of /tmp, not a child — the prefix must not be enough.
run "rm -rf /tmpfoo"                     BLOCK
# The old "rm -rf ~" pattern needed a trailing space, so ~/... slipped through.
run "rm -rf ~/Projects/x"                BLOCK
# EVERY operand must be safe, not just the first — the multi-operand hole.
run "rm -rf /tmp/a /usr"                 BLOCK
run "echo cleaning && rm -rf /usr"       BLOCK

# --- rm: relative paths are ordinary build hygiene, never matched ---
run "rm -rf ./build"                     ALLOW
run "rm -rf build/"                      ALLOW
run "rm -rf node_modules"                ALLOW
# Without -f it is not a force-removal; the guard requires both flags.
run "rm -r /tmp/mutdir"                  ALLOW

# --- SQL: the loud form and its quiet equivalents must agree ---
# The point is consistency, not volume. A guard that stops DROP DATABASE while
# DROP SCHEMA public CASCADE passes teaches rephrasing rather than asking, which
# is how the real-session bypass in issue #67 happened: the obvious form was
# refused, so the next thing reached for was the equivalent the guard missed.
run "psql -c 'DROP TABLE users'"                  BLOCK
run "psql -c 'DROP DATABASE myapp'"               BLOCK
run "psql -c 'TRUNCATE users'"                    BLOCK
# Destroys every object in the schema: same effect as dropping the database.
run "psql -c 'DROP SCHEMA public CASCADE'"        BLOCK
run "psql -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'"  BLOCK
# Destroys everything a role owns, across every schema in the database.
run "psql -c 'DROP OWNED BY report_writer'"       BLOCK
# SQL keywords are case-insensitive; so is the guard.
run "psql -c 'drop schema public cascade'"        BLOCK
# Realistic shapes these arrive in, not just bare statements.
run "docker compose exec -T db psql -U app -d app -c 'DROP SCHEMA public CASCADE'"  BLOCK
run "mysql -u root -e 'DROP DATABASE staging'"    BLOCK

# --- SQL: an unqualified DELETE empties the table ---
# The pattern this replaces was "DELETE FROM.*WITHOUT.*WHERE", which matches the
# literal word WITHOUT and so matched nothing anyone types. A pattern that reads
# as covered while matching nothing real is worse than an honest gap. The intent
# was "DELETE FROM <table> with no WHERE clause", which needs two steps: find the
# statement, then check whether it is qualified.
run "psql -c 'DELETE FROM users'"                      BLOCK
run "psql -c 'DELETE FROM users;'"                     BLOCK
run "psql -c 'delete from audit_log'"                  BLOCK
# A qualified delete is ordinary data work and must stay allowed, or the guard
# becomes noise people route around.
run "psql -c 'DELETE FROM users WHERE id = 42'"        ALLOW
run "psql -c 'delete from sessions where expires_at < now()'"  ALLOW
# Qualified by a subquery rather than a literal: still a WHERE clause.
run "psql -c 'DELETE FROM carts WHERE user_id IN (SELECT id FROM users WHERE banned)'"  ALLOW
# Each statement is judged separately: one qualified delete does not cover an
# unqualified one sharing the command line. The WHERE must be in the SAME
# statement as the DELETE, which is why the check runs per segment rather than
# over the whole command string — a WHERE anywhere on the line would otherwise
# vouch for a bare delete somewhere else on it.
run "psql -c 'DELETE FROM a WHERE id = 1; DELETE FROM b'"  BLOCK
run "psql -c 'SELECT * FROM a WHERE id = 1' && psql -c 'DELETE FROM audit_log'"  BLOCK

# --- SQL: naming a statement is not running one ---
# The patterns match anywhere in the command string, so investigating the guard
# trips the guard: grepping FOR a pattern, or writing a commit message that names
# one, got blocked. Low severity on its own, but it pushes toward working around
# the hook, which is the same pressure that produced the DROP SCHEMA bypass.
# These cases are not hypothetical: all three were hit while fixing issue #67.
run "grep -n 'DROP TABLE' bin/hook-block-destructive.sh"            ALLOW
run "rg 'DROP SCHEMA' bin/"                                         ALLOW
run "cat bin/hook-block-destructive.sh"                             ALLOW
# SC2088 is intentional: the tilde is fixture TEXT, the command string a wrapper
# script arrives as. Expanding it would stop testing what the hook actually sees.
# shellcheck disable=SC2088
run "~/.claude/bin/git-commit.sh 'fix(hook): catch DROP SCHEMA and DROP OWNED BY'"  ALLOW
run "echo 'TRUNCATE is blocked by this hook'"                       ALLOW
# A read-only leader must not launder a real statement later in the pipeline.
run "cat schema.sql | psql -d app"                                  ALLOW
run "grep -n foo file.sql && psql -c 'DROP SCHEMA public CASCADE'"  BLOCK
# Both halves read-only: the search term names a statement, and nothing runs it.
# This is the shape that fails if the destructive find ever widens from the
# segment to the whole command line, which would skip the grep segment and then
# re-scan the full string anyway, quietly undoing the skip above.
run "git log --oneline | grep 'DROP SCHEMA'"                        ALLOW
run "echo 'DROP OWNED BY is now blocked' && git status"             ALLOW
# sed and awk lead the read-only list although both CAN write (sed -i). They
# cannot execute SQL, and per-segment classification means leading with one
# never shields a real statement elsewhere on the line — which is the property
# that makes their presence in that list safe. Pinned here so it stays true.
run "sed -n '/DROP SCHEMA/p' schema.sql"                            ALLOW
run "sed -n 1,5p f.sql && psql -c 'DROP SCHEMA public CASCADE'"     BLOCK
run "awk '{print}' f.sql; psql -c 'DROP TABLE users'"               BLOCK

# --- SQL: boundaries and delivery forms ---
# Identifiers that merely CONTAIN a keyword are ordinary table names. Without
# the word-boundary anchors these block, and a guard that stops SELECT is one
# people switch off.
run "psql -c 'SELECT * FROM truncated_reports'"                     ALLOW
run "psql -c 'SELECT * FROM dropped_tables'"                        ALLOW
run "psql -c 'SELECT count(*) FROM users'"                          ALLOW
run "psql -c 'CREATE TABLE users (id int)'"                         ALLOW
run "alembic upgrade head"                                          ALLOW
# A statement reaches psql by more routes than -c. Both of these arrive as one
# command string with the statement on its own line, so segment splitting on
# ; && || | alone would miss them if the match were anchored per line.
run "$(printf 'psql -c "SELECT 1"\npsql -c "DROP SCHEMA public CASCADE"')"  BLOCK
run "$(printf 'psql -d app <<SQL\nDROP SCHEMA public CASCADE;\nSQL')"       BLOCK

# --- pattern list: naming a destructive command is not running one (issue #70) ---
# BLOCKED_PATTERNS and CASE_SENSITIVE_PATTERNS used to grep the whole command
# string, so a keyword appearing only as DATA blocked the command: a search term,
# a word in an echo, a commit message subject. Three of these were hit in a single
# session, the third being a grep over this hook's own source — the guard blocked
# the investigation INTO the guard, with no phrasing available that got past it.
#
# The fix reuses what _sql_destructive_hit() already does rather than stripping
# quotes: split into segments, and skip a segment whose LEADING word is read-only.
# Quote-stripping was the obvious move and is wrong here — see the "quotes do not
# launder a real operand" block below for the two patterns it would have opened.
run "grep -n 'git push --force' bin/hook-block-destructive.sh"       ALLOW
run "echo 'killall is in the blocked list'"                          ALLOW
run "grep -rn 'mkfs' docs/"                                          ALLOW
run "echo 'shutdown the service gracefully'"                         ALLOW
# SC2088 is intentional: the tilde is fixture TEXT, exactly as a wrapper-script
# command string reaches the hook. Expanding it would stop testing what it sees.
# shellcheck disable=SC2088
run "~/.claude/bin/git-commit.sh 'fix: do not reboot the machine'"    ALLOW

# One ALLOW case per pattern the hook knows (AC: shown per pattern). These are
# the searches that must stay possible — without them a pattern cannot be looked
# up, documented or tested without tripping the thing being looked up.
run "grep -n 'rm -rf \$HOME' bin/hook-block-destructive.sh"          ALLOW
run "grep -n 'git push.*--force' bin/hook-block-destructive.sh"      ALLOW
run "grep -n 'git push -f' bin/hook-block-destructive.sh"            ALLOW
run "grep -n 'git reset --hard' bin/hook-block-destructive.sh"       ALLOW
run "grep -n 'git checkout -- .' bin/hook-block-destructive.sh"      ALLOW
run "grep -n 'git clean -f' bin/hook-block-destructive.sh"           ALLOW
run "grep -n 'kill -9 1' bin/hook-block-destructive.sh"              ALLOW
run "grep -n 'killall' bin/hook-block-destructive.sh"                ALLOW
run "grep -n 'shutdown' bin/hook-block-destructive.sh"               ALLOW
run "grep -n 'reboot' bin/hook-block-destructive.sh"                 ALLOW
run "grep -n 'mkfs' bin/hook-block-destructive.sh"                   ALLOW
run "grep -n 'dd if=.* of=/dev/' bin/hook-block-destructive.sh"      ALLOW
run "grep -n 'git branch.*-D' bin/hook-block-destructive.sh"         ALLOW

# --- pattern list: the real operation still blocks, per pattern ---
# The mirror of the block above. Each ALLOW case there is only safe because the
# bare form here still fires; a relaxation is a gap unless both sides are pinned.
run "git push --force origin main"                                   BLOCK
run "git push -f origin main"                                        BLOCK
run "git reset --hard origin/main"                                   BLOCK
run "git checkout -- ."                                              BLOCK
run "git clean -fd"                                                  BLOCK
run "killall node"                                                   BLOCK
run "shutdown -h now"                                                BLOCK
run "reboot"                                                         BLOCK
run "mkfs.ext4 /dev/sda1"                                            BLOCK
run "dd if=/dev/zero of=/dev/sda"                                     BLOCK
run "git branch -D feature"                                          BLOCK
# Case-sensitive by design: -d refuses to delete an unmerged branch, -D forces it.
run "git branch -d feature"                                          ALLOW

# --- pattern list: data AND a real operation in one command still blocks ---
# Per-segment classification is what makes this work: a read-only leader excuses
# its OWN segment only. Were the skip applied to the whole command string, the
# search term in the first half would vouch for the operation in the second.
run "grep -n 'git push --force' README.md && git push --force origin main"  BLOCK
run "echo 'about to force push' && git push --force origin main"      BLOCK
run "echo 'killall note'; killall node"                              BLOCK
run "grep -rn 'reboot' docs/ | head -5 && reboot"                    BLOCK

# --- pattern list: quotes do not launder a real operand ---
# This is the case that rules out stripping quoted segments before matching, the
# first thing to reach for and a false negative in two places. Quoting an operand
# is normal shell hygiene, not a signal that the text is data: both commands below
# destroy exactly as much with the quotes as without them. The leader is what
# distinguishes data from operation, so the leader is what the skip looks at.
run "rm -rf \"\$HOME\""                                              BLOCK
run "rm -rf '\$HOME'"                                                BLOCK
run "dd if=/dev/zero of=\"/dev/sda\""                                BLOCK
run "git push \"--force\" origin main"                               BLOCK

# --- pattern list: a heredoc body is input to a program, not a command ---
# Text between the delimiters is data for whatever reads stdin. The leader of such
# a segment is the heredoc body itself, which matches no read-only command, so
# fail-closed is the default and these cases pin the exception as narrow.
run "$(printf 'cat <<EOF\nkillall and reboot are blocked\nEOF')"     ALLOW
run "$(printf 'python3 - <<%s\nprint("git push --force is blocked")\n%s' "'PY'" "PY")"  ALLOW
# A heredoc does not shield a real command on another line.
run "$(printf 'cat <<EOF\njust text\nEOF\nkillall node')"            BLOCK

# --- pattern list: fail closed on anything not recognised as read-only ---
# At the boundary the answer must be BLOCK, not ALLOW. An unknown leader gets no
# skip, so a keyword inside quotes under one still blocks — noisier than ideal and
# deliberately so: a false negative here is a destroyed working tree, a false
# positive is one rephrasing. Pinned so a later widening of the leader list has
# to break a test rather than pass silently.
run "mystery-tool 'git push --force'"                                BLOCK
run "eval 'killall node'"                                            BLOCK
run "bash -c 'git reset --hard origin/main'"                         BLOCK
run "xargs -I{} git push --force {}"                                 BLOCK

# --- regression: the hook's other guards must keep firing ---
run "git push --force origin main"       BLOCK
run "git reset --hard origin/main"       BLOCK
run "git branch -D feature"              BLOCK
run "git status"                         ALLOW
run "npm run build"                      ALLOW

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
