#!/usr/bin/env bash
# Build (if needed) and run a Next.js production server for local verification
# / e2e, as a standing service that e2e can reuse instead of doing a full
# `next build` inside Playwright's webServer startup window.
#
# Uses `next start`, NOT the standalone server: callers that depend on a
# specific routing/render behaviour (e.g. next-intl prefix-less default-locale)
# may break under `output: "standalone"`. The exact same build is served
# correctly by `next start`. Caller decides whether that constraint applies.
#
# Usage:
#   next-frontend-serve.sh <frontend-dir> [port] [--build]
#     frontend-dir  path to the Next.js app (must be within ~/Projects/)
#     port          defaults to 3000
#     --build       force a rebuild even if .next/BUILD_ID exists
set -euo pipefail

ALLOWED_ROOT="$HOME/Projects"

FRONTEND_DIR="${1:-}"
if [[ -z "$FRONTEND_DIR" ]]; then
  echo "ERROR: frontend-dir is required" >&2
  echo "Usage: next-frontend-serve.sh <frontend-dir> [port] [--build]" >&2
  exit 1
fi
shift

# Resolve to an absolute path and validate it sits within the allowed root.
FRONTEND_DIR="$(cd "$FRONTEND_DIR" 2>/dev/null && pwd)" || {
  echo "ERROR: frontend-dir does not exist" >&2
  exit 1
}
if [[ "$FRONTEND_DIR" != "$ALLOWED_ROOT"* ]]; then
  echo "ERROR: frontend-dir ($FRONTEND_DIR) is not within $ALLOWED_ROOT" >&2
  exit 1
fi

PORT="3000"
FORCE_BUILD=""
for arg in "$@"; do
  case "$arg" in
    --build) FORCE_BUILD="1" ;;
    [0-9]*)  PORT="$arg" ;;
  esac
done

cd "$FRONTEND_DIR"

if [[ -n "$FORCE_BUILD" || ! -f .next/BUILD_ID ]]; then
  npm run build
fi

exec npx next start -p "$PORT"
