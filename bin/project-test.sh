#!/usr/bin/env bash
# Run pytest scoped to a project directory with automatic venv detection.
# Validates that both PWD and any test path arguments are within ~/Projects/.
# Finds and uses project venv automatically — no manual activation needed.
#
# Usage: project-test.sh [pytest-args...]
# Example: project-test.sh tests/unit/test_api/ -v --tb=short
# Example: project-test.sh -x  (runs from current directory)
set -euo pipefail

ALLOWED_ROOT="$HOME/Projects"

# Check PWD is within allowed root
if [[ "$PWD" != "$ALLOWED_ROOT"* ]]; then
  echo "ERROR: PWD ($PWD) is not within $ALLOWED_ROOT" >&2
  exit 1
fi

# Check any path arguments are within allowed root or are relative
for arg in "$@"; do
  # Skip flags (start with -)
  [[ "$arg" == -* ]] && continue

  # If it's an absolute path, validate it
  if [[ "$arg" == /* ]]; then
    if [[ "$arg" != "$ALLOWED_ROOT"* ]]; then
      echo "ERROR: Path argument '$arg' is not within $ALLOWED_ROOT" >&2
      exit 1
    fi
  fi

  # Relative paths are fine — they resolve within PWD which is already validated
done

# Warn if no test path specified (likely unintentional full suite run)
has_path_arg=false
for arg in "$@"; do
  [[ "$arg" != -* ]] && has_path_arg=true && break
done
if [[ "$has_path_arg" == false ]]; then
  echo "[project-test.sh] WARNING: No test path specified — running full suite. Use a specific path for faster runs." >&2
fi

# Auto-detect venv and use its pytest directly (no activation needed)
PYTEST_CMD=""
for venv_dir in .venv venv backend/.venv backend/venv ../.venv ../venv; do
  if [[ -f "$venv_dir/bin/pytest" ]]; then
    PYTEST_CMD="$venv_dir/bin/pytest"
    echo "[project-test.sh] Using pytest from $venv_dir" >&2
    break
  fi
done

# Fallback: venv python with -m pytest
if [[ -z "$PYTEST_CMD" ]]; then
  for venv_dir in .venv venv backend/.venv backend/venv ../.venv ../venv; do
    if [[ -f "$venv_dir/bin/python" ]]; then
      echo "[project-test.sh] Using python -m pytest from $venv_dir" >&2
      exec "$venv_dir/bin/python" -m pytest "$@"
    fi
  done
fi

# Last fallback: pytest in PATH
if [[ -z "$PYTEST_CMD" ]]; then
  PYTEST_CMD="pytest"
fi

exec $PYTEST_CMD "$@"
