#!/usr/bin/env bash
# Run a command from a project's venv without triggering permission prompts.
# Auto-detects venv location and executes the specified binary from it.
#
# The venv is searched relative to --repo when given, otherwise relative to
# $PWD. Unlike project-test.sh this script cannot derive the tree from its
# arguments: it takes a COMMAND, not a path, and `venv-run.sh python script.py`
# names no project root. With several git worktrees of one repository the shell's
# location would otherwise decide which interpreter runs — two trees created
# months apart can hold different Python minor versions, and nothing says so.
#
# Usage: venv-run.sh [--repo <dir>] <command> [args...]
# Example: venv-run.sh python -c "import sys; print(sys.version)"
# Example: venv-run.sh pip install -r requirements.txt
# Example: venv-run.sh alembic upgrade head
# Example: venv-run.sh --repo ~/Projects/billing-api-dev1 alembic upgrade head
set -euo pipefail

ALLOWED_ROOT="$HOME/Projects"

if [[ "$PWD" != "$ALLOWED_ROOT"* ]]; then
  echo "ERROR: PWD ($PWD) is not within $ALLOWED_ROOT" >&2
  exit 1
fi

# --repo is parsed before the command, and only there: everything after the
# command belongs to the command, including arguments that look like flags.
REPO=""
if [[ "${1:-}" == "--repo" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "ERROR: --repo requires a directory argument" >&2
    exit 1
  fi
  REPO="$2"
  shift 2
elif [[ "${1:-}" == --repo=* ]]; then
  REPO="${1#--repo=}"
  shift
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: venv-run.sh [--repo <dir>] <command> [args...]" >&2
  echo "Example: venv-run.sh python -c 'import sys; print(sys.version)'" >&2
  exit 1
fi

# A --repo that does not exist is a typo. Falling back to PWD there would run
# the exact tree the caller used the flag to avoid, which is the failure this
# flag exists to prevent.
if [[ -n "$REPO" ]]; then
  if [[ ! -d "$REPO" ]]; then
    echo "ERROR: --repo directory does not exist: $REPO" >&2
    exit 1
  fi
  REPO=$(cd "$REPO" && pwd)
  if [[ "$REPO" != "$ALLOWED_ROOT"* ]]; then
    echo "ERROR: --repo ($REPO) is not within $ALLOWED_ROOT" >&2
    exit 1
  fi
  cd "$REPO"
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
    echo "[venv-run.sh] Using $CMD from $(cd "$venv_dir" && pwd)" >&2
    exec "$venv_dir/bin/$CMD" "$@"
  fi
done

# Fallback: command in PATH
echo "[venv-run.sh] No venv found, using $CMD from PATH" >&2
exec "$CMD" "$@"
