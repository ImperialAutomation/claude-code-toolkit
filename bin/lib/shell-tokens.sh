#!/usr/bin/env bash
# shell-tokens.sh: split a command line into words and operators like a shell.
#
# Source this, then read the tokens into an array:
#
#     # shellcheck source=bin/lib/shell-tokens.sh
#     . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/shell-tokens.sh"
#     mapfile -d '' TOKENS < <(shell_tokens "$COMMAND")
#
# WHY THIS EXISTS
#
# Hooks that judge a Bash command by its git invocations need the words the
# shell would pass to git: quotes removed, a quoted path with spaces kept as one
# word, chain operators (`;`, `&&`, `|`, ...) and redirects (`>`, `2>&1`) as
# separate tokens instead of glued to an argument. hook-block-toolkit-live-checkout.sh
# and hook-block-foreign-worktree-git.sh both need that, so it is defined once.
#
# Output: one NUL-terminated token per word or operator. Consecutive operator
# characters come out as one token (`);` or `>&`), so callers classify a token
# by its characters. A backslash-newline joins two lines into one command; any
# other newline ends a command and comes out as `;`.
#
# Unparseable input (an unbalanced quote) yields nothing. The shell refuses such
# a line too, so nothing runs, and a guard that blocks on its own parse errors
# gets disabled.

shell_tokens() { # command
    python3 -c '
import shlex, sys
cmd = sys.argv[1].replace("\\\n", " ").replace("\n", ";")
try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    tokens = list(lex)
except ValueError:
    sys.exit(0)
for t in tokens:
    sys.stdout.write(t + "\0")
' "$1"
}
