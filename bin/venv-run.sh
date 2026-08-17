#!/usr/bin/env bash
# Run a command from a project's venv without triggering permission prompts.
# Auto-detects venv location and executes the specified binary from it.
#
# Usage: venv-run.sh <command> [args...]
# Example: venv-run.sh python -c "import sys; print(sys.version)"
# Example: venv-run.sh pip install -r requirements.txt
# Example: venv-run.sh alembic upgrade head
set -euo pipefail

ALLOWED_ROOT="$HOME/Projects"

if [[ "$PWD" != "$ALLOWED_ROOT"* ]]; then
  echo "ERROR: PWD ($PWD) is not within $ALLOWED_ROOT" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: venv-run.sh <command> [args...]" >&2
  echo "Example: venv-run.sh python -c 'import sys; print(sys.version)'" >&2
  exit 1
fi

CMD="$1"
shift

# Auto-detect venv and use its binary.
# The list is ordered nearest-first and covers CWD at the project root as well
# as one level below it. `../backend/*` is the case that is easy to miss: from
# a sibling of the venv's directory (e.g. cwd=frontend/ with the venv in
# backend/), neither `.venv` nor `../.venv` matches. Without it the loop falls
# through to the system interpreter, which usually still runs — silently,
# against the wrong Python and dependency set.
for venv_dir in .venv venv backend/.venv backend/venv ../.venv ../venv ../backend/.venv ../backend/venv; do
  if [[ -f "$venv_dir/bin/$CMD" ]]; then
    echo "[venv-run.sh] Using $CMD from $venv_dir" >&2
    exec "$venv_dir/bin/$CMD" "$@"
  fi
done

# Fallback: command in PATH
echo "[venv-run.sh] No venv found, using $CMD from PATH" >&2
exec "$CMD" "$@"
