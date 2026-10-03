#!/usr/bin/env bash
# Save gh command output to a file.
# Usage: gh-save.sh <output-file> <gh-args...>
# Example: gh-save.sh /tmp/issue-795.json issue view 795 --json title,body,labels
#
# The gh-shaped special case of cmd-save.sh, kept because it is shorter to type
# and is referenced from the skills and from claude-md/global.md. The capture
# logic lives in cmd-save.sh so there is one implementation of the parts that
# are easy to get wrong: propagating the command's exit status (so a failed gh
# call is never read back as issue data) and keeping gh's stderr out of the
# JSON (so a rate-limit warning does not make the capture unparseable).
set -uo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $(basename "$0") <output-file> <gh-args...>" >&2
    exit 2
fi

OUTFILE="$1"; shift

exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/cmd-save.sh" "$OUTFILE" gh "$@"
