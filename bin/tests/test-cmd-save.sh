#!/bin/bash
# Tests for cmd-save.sh.
#
# Usage:
#   bin/tests/test-cmd-save.sh
#
# Runs against real commands (echo, sh -c, printf) rather than mocks: the thing
# under test is how the wrapper wires a child process's stdout, stderr and exit
# status to a file, and a mock would replace exactly that wiring.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../cmd-save.sh}"

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

run() { bash "$SCRIPT" "$@"; }

echo "== 1. the command's output lands in the file =="
run "$T/hello.txt" echo hello >/dev/null 2>&1
check "file created"  "hello" "$(cat "$T/hello.txt")"
check "exit 0 on success" "0" "$(run "$T/hello.txt" echo hello >/dev/null 2>&1; echo $?)"
# The capture is the file, not the terminal: a caller that reads stdout instead
# of the file must not accidentally get the data and think it worked. Asserted
# with a payload that cannot collide with the filename in the summary line.
check "data does not leak to stdout" "yes" \
    "$(case "$(run "$T/leak.txt" echo PAYLOAD-MARKER 2>/dev/null)" in
         *PAYLOAD-MARKER*) echo no ;; *) echo yes ;;
       esac)"
check "summary names the file" "yes" \
    "$(case "$(run "$T/leak.txt" echo PAYLOAD-MARKER 2>/dev/null)" in
         *leak.txt*) echo yes ;; *) echo no ;;
       esac)"

echo "== 2. a second run truncates rather than appends =="
run "$T/trunc.txt" printf 'first\n'  >/dev/null 2>&1
run "$T/trunc.txt" printf 'second\n' >/dev/null 2>&1
check "old content gone" "second" "$(cat "$T/trunc.txt")"
check "one line only"    "1"      "$(wc -l < "$T/trunc.txt" | tr -d ' ')"

echo "== 3. argument validation =="
check "no args exits 2"       "2" "$(run >/dev/null 2>&1; echo $?)"
check "only outfile exits 2"  "2" "$(run "$T/x.txt" >/dev/null 2>&1; echo $?)"
check "usage goes to stderr"  "yes" \
    "$(case "$(run 2>&1 >/dev/null)" in *usage*) echo yes ;; *) echo no ;; esac)"
# A usage error must not leave a half-made file behind that a later step reads
# as a real capture.
run "$T/never.txt" >/dev/null 2>&1
check "no file on usage error" "absent" \
    "$([[ -e "$T/never.txt" ]] && echo present || echo absent)"

echo "== 4. the command's exit status is the wrapper's exit status =="
# Without this, a failed command still writes a file and reports success, so the
# caller reads an error message as data. This is the whole reason the wrapper
# cannot be a bare redirect.
check "failing command propagates 3" "3" \
    "$(run "$T/fail.txt" sh -c 'exit 3' >/dev/null 2>&1; echo $?)"
check "failing command propagates 1" "1" \
    "$(run "$T/fail.txt" sh -c 'exit 1' >/dev/null 2>&1; echo $?)"
# ...and what it managed to write before failing is still kept, because that
# partial output is usually the diagnosis.
run "$T/partial.txt" sh -c 'printf "half\n"; exit 4' >/dev/null 2>&1
check "partial output kept" "half" "$(cat "$T/partial.txt")"
# The summary must still print on failure: a non-zero exit with no report tells
# the caller nothing about whether anything was captured.
check "summary printed on failure" "yes" \
    "$(case "$(run "$T/fail.txt" sh -c 'exit 3' 2>/dev/null)" in *fail.txt*) echo yes ;; *) echo no ;; esac)"
# A command that does not exist is a failure to capture, not an empty capture.
check "missing command exits 127" "127" \
    "$(run "$T/nope.txt" this-command-does-not-exist-xyz >/dev/null 2>&1; echo $?)"

echo "== 5. the summary reports the real byte count =="
check "counts bytes written" "$T/six.txt (6 bytes, exit 0)" \
    "$(run "$T/six.txt" printf 'abcde\n' 2>/dev/null)"
# A command that produced nothing is the case worth seeing: without the count it
# is indistinguishable from a successful capture until something downstream
# chokes on an empty file.
check "zero-byte capture is visible" "$T/empty.txt (0 bytes, exit 0)" \
    "$(run "$T/empty.txt" true 2>/dev/null)"
check "byte count matches file on disk" "yes" \
    "$(run "$T/count.txt" printf 'abc' >/dev/null 2>&1
       bytes=$(wc -c < "$T/count.txt" | tr -d ' ')
       case "$(run "$T/count.txt" printf 'abc' 2>/dev/null)" in
         *"($bytes bytes"*) echo yes ;; *) echo no ;;
       esac)"

echo "== 6. stderr stays out of the file by default =="
# The reason separation is the default: a command that warns on stderr would
# otherwise silently corrupt what the caller reads back as clean data. Here the
# "data" is valid JSON and the warning would make it unparseable.
NOISY='printf "{\"ok\": true}\n"; printf "WARNING: deprecated flag\n" >&2'
run "$T/noisy.json" sh -c "$NOISY" >/dev/null 2>&1
check "file holds only stdout" '{"ok": true}' "$(cat "$T/noisy.json")"
check "captured data still parses" "ok" \
    "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' "$T/noisy.json" 2>&1)"
# Separated is not discarded: the diagnostic must still reach the caller, or a
# failure becomes unexplainable.
check "stderr reaches the caller" "yes" \
    "$(case "$(run "$T/noisy.json" sh -c "$NOISY" 2>&1 >/dev/null)" in
         *"WARNING: deprecated flag"*) echo yes ;; *) echo no ;;
       esac)"

echo "== 7. --stderr merge folds stderr into the file =="
run --stderr merge "$T/merged.txt" sh -c "$NOISY" >/dev/null 2>&1
check "stdout present"   "1" "$(grep -c '{"ok": true}' "$T/merged.txt")"
check "stderr present"   "1" "$(grep -c 'WARNING: deprecated flag' "$T/merged.txt")"
# Merging is what you want when the capture exists to diagnose a failure.
run --stderr merge "$T/diag.txt" sh -c 'printf "boom\n" >&2; exit 5' >/dev/null 2>&1
check "diagnostic captured on failure" "boom" "$(cat "$T/diag.txt")"
check "merge still propagates status" "5" \
    "$(run --stderr merge "$T/diag.txt" sh -c 'exit 5' >/dev/null 2>&1; echo $?)"
check "--stderr separate is the default spelling" '{"ok": true}' \
    "$(run --stderr separate "$T/sep.json" sh -c "$NOISY" >/dev/null 2>&1; cat "$T/sep.json")"

echo "== 8. flag validation =="
check "--stderr without value exits 2" "2" \
    "$(run --stderr >/dev/null 2>&1; echo $?)"
check "--stderr with bad value exits 2" "2" \
    "$(run --stderr sideways "$T/x.txt" echo hi >/dev/null 2>&1; echo $?)"
check "unknown option exits 2" "2" \
    "$(run --nope "$T/x.txt" echo hi >/dev/null 2>&1; echo $?)"
# Everything after the output file is the command, so a flag belonging to the
# command must not be eaten as a wrapper flag. `printf %s --stderr` would exit 2
# if the wrapper kept parsing past the output file.
check "command flags are not wrapper flags" "--stderr" \
    "$(run "$T/dash.txt" printf '%s' --stderr >/dev/null 2>&1; cat "$T/dash.txt")"
check "-- ends flag parsing" "hi" \
    "$(run -- "$T/ddash.txt" echo hi >/dev/null 2>&1; cat "$T/ddash.txt")"

echo "== 9. paths and arguments survive intact =="
# A missing parent directory is the common case when writing into a per-task
# scratch path, so the wrapper creates it rather than failing the capture.
run "$T/nested/deeper/out.txt" echo nested >/dev/null 2>&1
check "parent directories created" "nested" "$(cat "$T/nested/deeper/out.txt")"
# Unquoted expansions inside the wrapper would split these; the capture would
# land somewhere else or vanish.
run "$T/has space/out.txt" echo spaced >/dev/null 2>&1
check "space in output path" "spaced" "$(cat "$T/has space/out.txt")"
check "space in command argument" "two words" \
    "$(run "$T/arg.txt" echo "two words" >/dev/null 2>&1; cat "$T/arg.txt")"
check "empty argument preserved" "2" \
    "$(run "$T/empty-arg.txt" printf '%s\n' "" "" >/dev/null 2>&1; wc -l < "$T/empty-arg.txt" | tr -d ' ')"
# A bare filename has no directory part; dirname gives ".", which must not break.
check "relative filename works" "relative" \
    "$(cd "$T" && run rel.txt echo relative >/dev/null 2>&1; cat "$T/rel.txt")"
# Binary-ish output must not be mangled: captures get diffed and fed back in.
run "$T/tabs.txt" printf 'a\tb\n' >/dev/null 2>&1
check "tabs preserved" "$(printf 'a\tb')" "$(cat "$T/tabs.txt")"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
