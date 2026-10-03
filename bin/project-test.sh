#!/usr/bin/env bash
# Run pytest scoped to a project directory with automatic venv detection.
# Validates that both PWD and any test path arguments are within ~/Projects/.
# Finds and uses project venv automatically — no manual activation needed.
#
# The venv is searched relative to the root of the TEST PATH you give, not
# relative to $PWD. With several git worktrees of one repository that is the
# difference between testing the code you changed and testing a sibling tree:
# an absolute path collects the right file but, resolved against $PWD, would run
# it on another tree's interpreter and dependency set — with no signal at all.
# Without a path argument there is nothing to derive a root from and $PWD decides,
# exactly as before.
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

# Warn if no test path specified (likely unintentional full suite run).
# Collection-only runs are exempt: they import every test module without
# running a single test, so "no path given" is deliberate there and costs
# seconds. Warning about a full suite on the one invocation that runs zero
# tests only teaches the reader to ignore this warning.
has_path_arg=false
is_collect_only=false
for arg in "$@"; do
  case "$arg" in
    --collect-only|--co) is_collect_only=true ;;
    -*) ;;
    *) has_path_arg=true ;;
  esac
done
if [[ "$has_path_arg" == false && "$is_collect_only" == false ]]; then
  echo "[project-test.sh] WARNING: No test path specified — running full suite. Use a specific path for faster runs." >&2
fi

# Derive the project root from the first test path argument.
#
# The caller already says which tree they mean — it is in the path they typed —
# and the old code threw that away in favour of $PWD. `rev-parse --show-toplevel`
# is what makes this worktree-aware: each linked worktree reports its own root,
# so a path inside one resolves to that one. Outside a git repository there is no
# toplevel, and the directory holding the path is the best available answer.
#
# Paths from two different roots cannot both be satisfied by one venv. That is a
# mistake worth an exit code, not a tree to pick between.
TEST_ROOT=""
TEST_ROOT_SOURCE=""
for arg in "$@"; do
  [[ "$arg" == -* ]] && continue
  # Only real paths carry tree information; `-k expr`, node ids and bare words do not.
  candidate="${arg%%::*}"
  [[ -e "$candidate" ]] || continue

  if [[ -d "$candidate" ]]; then
    arg_dir="$candidate"
  else
    arg_dir=$(dirname "$candidate")
  fi
  arg_root=$(git -C "$arg_dir" rev-parse --show-toplevel 2>/dev/null) || arg_root=""
  [[ -n "$arg_root" ]] || arg_root=$(cd "$arg_dir" && pwd)

  if [[ -z "$TEST_ROOT" ]]; then
    TEST_ROOT="$arg_root"
    TEST_ROOT_SOURCE="$arg"
  elif [[ "$TEST_ROOT" != "$arg_root" ]]; then
    echo "ERROR: test paths come from multiple project roots — refusing to guess which venv to use." >&2
    echo "  $TEST_ROOT_SOURCE -> $TEST_ROOT" >&2
    echo "  $arg -> $arg_root" >&2
    echo "Run them as separate invocations, one per project root." >&2
    exit 1
  fi
done

# Run from the derived root so pytest's rootdir, conftest.py discovery and the
# paths it prints all refer to the same tree the venv came from.
PWD_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [[ -n "$TEST_ROOT" && "$TEST_ROOT" != "$PWD_ROOT" ]]; then
  echo "[project-test.sh] tests resolved to $TEST_ROOT (PWD is $PWD_ROOT)" >&2
fi
SEARCH_ROOT="${TEST_ROOT:-$PWD}"
cd "$SEARCH_ROOT"

# Auto-detect venv and use its pytest directly (no activation needed).
# The list is ordered nearest-first and covers CWD at the project root as well
# as one level below it. `../backend/*` is the case that is easy to miss: from
# a sibling of the venv's directory (e.g. cwd=frontend/ with the venv in
# backend/), neither `.venv` nor `../.venv` matches. Without it the loop falls
# through to the system pytest, which usually still runs — silently, against
# the wrong interpreter and dependency set.
# Keep this list in sync with the fallback loop below and with venv-run.sh.
PYTEST_CMD=""
for venv_dir in .venv venv backend/.venv backend/venv ../.venv ../venv ../backend/.venv ../backend/venv; do
  if [[ -f "$venv_dir/bin/pytest" ]]; then
    PYTEST_CMD="$SEARCH_ROOT/$venv_dir/bin/pytest"
    echo "[project-test.sh] Using pytest from $(cd "$venv_dir" && pwd)" >&2
    break
  fi
done

# Fallback: venv python with -m pytest (same search list as above)
if [[ -z "$PYTEST_CMD" ]]; then
  for venv_dir in .venv venv backend/.venv backend/venv ../.venv ../venv ../backend/.venv ../backend/venv; do
    if [[ -f "$venv_dir/bin/python" ]]; then
      echo "[project-test.sh] Using python -m pytest from $(cd "$venv_dir" && pwd)" >&2
      exec "$venv_dir/bin/python" -m pytest "$@"
    fi
  done
fi

# Last fallback: pytest in PATH
if [[ -z "$PYTEST_CMD" ]]; then
  PYTEST_CMD="pytest"
fi

exec $PYTEST_CMD "$@"
