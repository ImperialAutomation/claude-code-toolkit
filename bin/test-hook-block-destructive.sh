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

# --- SQL: naming a statement is not running one ---
# The patterns match anywhere in the command string, so investigating the guard
# trips the guard: grepping FOR a pattern, or writing a commit message that names
# one, got blocked. Low severity on its own, but it pushes toward working around
# the hook, which is the same pressure that produced the DROP SCHEMA bypass.
# These cases are not hypothetical: all three were hit while fixing issue #67.
run "grep -n 'DROP TABLE' bin/hook-block-destructive.sh"            ALLOW
run "rg 'DROP SCHEMA' bin/"                                         ALLOW
run "cat bin/hook-block-destructive.sh"                             ALLOW
run "~/.claude/bin/git-commit.sh 'fix(hook): catch DROP SCHEMA and DROP OWNED BY'"  ALLOW
run "echo 'TRUNCATE is blocked by this hook'"                       ALLOW
# A read-only leader must not launder a real statement later in the pipeline.
run "cat schema.sql | psql -d app"                                  ALLOW
run "grep -n foo file.sql && psql -c 'DROP SCHEMA public CASCADE'"  BLOCK

# --- regression: the hook's other guards must keep firing ---
run "git push --force origin main"       BLOCK
run "git reset --hard origin/main"       BLOCK
run "git branch -D feature"              BLOCK
run "git status"                         ALLOW
run "npm run build"                      ALLOW

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
