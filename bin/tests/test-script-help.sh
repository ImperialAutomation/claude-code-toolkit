#!/bin/bash
# Tests for the --help of the bin/ scripts that global CLAUDE.md points at.
#
# Usage:
#   bin/tests/test-script-help.sh
#
# Global CLAUDE.md keeps one line per wrapper and sends the reader to
# `<script> --help` for the rest. These tests pin both halves of that deal:
# --help exits 0 and runs nothing, and the help text still carries the detail
# that used to live in CLAUDE.md. Removing such a sentence from a header makes
# a test here fail instead of silently losing the rule.

set -uo pipefail

BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

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

# help <script> <flag>: the help text in $HELP_OUT, status in $HELP_STATUS.
# Run from a temp dir outside ~/Projects on purpose: --help must be answered
# before venv-run.sh's location check refuses the call.
help() {
    HELP_OUT=$(env -C "$T" bash "$BIN_DIR/$1" "$2" 2>"$T/stderr"); HELP_STATUS=$?
}

# script -> one phrase per line that the help must contain (moved there from
# global CLAUDE.md, or the core of what CLAUDE.md now only names).
declare -A MUST_SAY=(
    [cmd-save.sh]=$'always go BEFORE <output-file>\n--stderr merge\napproved on its own\n127  command not found\nbytes, exit <status>'
    [strip-ansi.sh]=$'<outfile> defaults to <file>.clean\ncmd-save.sh --strip-ansi'
    [repeat-cmd.sh]=$'stops at the first non-zero exit\nwould be approved too'
    [http-status.sh]=$'a 4xx/5xx IS an answer\nprints ERR\nauth headers, retries, JSON parsing\nwait-for-healthy.sh'
    [docker-scratch.sh]=$'not /tmp\nOnly for what a container must mount\nPaste the printed path literally\nno $(...)\nhook-block-destructive.sh\nreport it, and do not'
    [wait-for-pattern.sh]=$'--newer-than <epoch>\ndate +%s\nneed not exist yet\nwait-for-healthy.sh <container>'
    [venv-run.sh]=$'--repo <dir>\npip or python3 prompt\n.venv/bin/'
)

for script in "${!MUST_SAY[@]}"; do
    for flag in --help -h; do
        echo "== $script $flag =="
        help "$script" "$flag"
        check "$script $flag exits 0" "0" "$HELP_STATUS"
        check "$script $flag writes nothing to stderr" "0" "$(wc -c < "$T/stderr" | tr -d ' ')"
        check "$script $flag prints a usage line" "yes" "$(contains "$HELP_OUT" "sage")"
        check "$script $flag strips the comment markers" "no" \
            "$([[ "$HELP_OUT" =~ (^|$'\n')# ]] && echo yes || echo no)"
        check "$script $flag does not print the shebang" "no" "$(contains "$HELP_OUT" "#!/")"
    done
    help "$script" --help
    while IFS= read -r phrase; do
        [[ -n "$phrase" ]] || continue
        check "$script help says: $phrase" "yes" "$(contains "$HELP_OUT" "$phrase")"
    done <<< "${MUST_SAY[$script]}"
done

echo "== --help runs nothing =="
# cmd-save with --help must not create the file that a mistaken parse would
# treat as <output-file>; repeat-cmd must not run anything.
env -C "$T" bash "$BIN_DIR/cmd-save.sh" --help >/dev/null 2>&1
check "cmd-save --help creates no file" "0" "$(find "$T" -mindepth 1 -not -name stderr | wc -l | tr -d ' ')"
env -C "$T" bash "$BIN_DIR/docker-scratch.sh" --help >/dev/null 2>&1
check "docker-scratch --help creates no file" "0" "$(find "$T" -mindepth 1 -not -name stderr | wc -l | tr -d ' ')"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
