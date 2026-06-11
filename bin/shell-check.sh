#!/usr/bin/env bash
# Run shellcheck + bash test-*.sh suites over a shell-lib directory, from a fixed
# root so it never depends on the caller's cwd (which can be lost after temp-dir
# cleanups). Wrap this in a project-local bin/ script that fills in the root.
#
# Usage: shell-check.sh <root> [lib-subdir]
#   root        absolute path to the repo root (used as shellcheck --source-path,
#               so `# shellcheck source=<repo-relative-path>` directives resolve)
#   lib-subdir  directory under <root> holding *.sh + test-*.sh
#               default: backend/docker/lib
#
# What it does, in order:
#   1. shellcheck every *.sh in the lib dir (with --source-path=<root> -x)
#   2. run every test-*.sh in the lib dir with bash
# Exits non-zero if any shellcheck run or any test fails.
#
# Example (project wrapper):
#   exec ~/.claude/bin/shell-check.sh "$HOME/Projects/PAM" backend/docker/lib
set -u

ROOT="${1:?repo root required (absolute path)}"
LIB_REL="${2:-backend/docker/lib}"
LIB_DIR="$ROOT/$LIB_REL"

if [ ! -d "$ROOT" ]; then
    echo "❌ root not found: $ROOT" >&2
    exit 2
fi
if [ ! -d "$LIB_DIR" ]; then
    echo "❌ lib dir not found: $LIB_DIR" >&2
    exit 2
fi

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "❌ shellcheck not installed" >&2
    exit 2
fi

rc=0

echo "=== shellcheck ($LIB_REL) ==="
for f in "$LIB_DIR"/*.sh; do
    [ -e "$f" ] || continue
    if shellcheck --source-path="$ROOT" -x "$f"; then
        echo "  ✓ $(basename "$f")"
    else
        echo "  ✗ $(basename "$f")"
        rc=1
    fi
done

echo ""
echo "=== tests ($LIB_REL) ==="
shopt -s nullglob
tests=("$LIB_DIR"/test-*.sh)
if [ ${#tests[@]} -eq 0 ]; then
    echo "  (no test-*.sh found)"
fi
for t in "${tests[@]}"; do
    echo "--- $(basename "$t") ---"
    if ! bash "$t"; then
        echo "  ✗ $(basename "$t") FAILED"
        rc=1
    fi
done

echo ""
if [ "$rc" -eq 0 ]; then
    echo "✅ shell-check passed"
else
    echo "❌ shell-check failed"
fi
exit "$rc"
