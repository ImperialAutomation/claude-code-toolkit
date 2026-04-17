#!/usr/bin/env bash
# Copy CLAUDE.md files to /tmp/ for sub-agent consumption during epic implementation.
#
# Usage:
#   epic-prepare-context.sh <epic-number> [project-dir]
#
# Creates namespaced copies to avoid collisions when running multiple epics
# or across different projects:
#   /tmp/epic-<project>-<number>-claude-root.md
#   /tmp/epic-<project>-<number>-claude-frontend.md
#   /tmp/epic-<project>-<number>-claude-backend.md
#
# Outputs the prefix to stdout for use in sub-agent prompts.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: epic-prepare-context.sh <epic-number> [project-dir]" >&2
  exit 1
fi

EPIC_NUMBER="$1"
PROJECT_DIR="${2:-$PWD}"

# Derive project name from directory basename (lowercase)
PROJECT_NAME=$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]')
PREFIX="/tmp/epic-${PROJECT_NAME}-${EPIC_NUMBER}-claude"

# Copy CLAUDE.md files that exist
copied=0
for pair in "root:CLAUDE.md" "frontend:frontend/CLAUDE.md" "backend:backend/app/CLAUDE.md"; do
  suffix="${pair%%:*}"
  src="${pair#*:}"
  dest="${PREFIX}-${suffix}.md"
  if [[ -f "$PROJECT_DIR/$src" ]]; then
    cp "$PROJECT_DIR/$src" "$dest"
    copied=$((copied + 1))
  fi
done

if [[ $copied -eq 0 ]]; then
  echo "⚠️  No CLAUDE.md files found in $PROJECT_DIR" >&2
  exit 1
fi

echo "$PREFIX"
