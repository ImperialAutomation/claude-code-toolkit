#!/usr/bin/env bash
# Serve a directory over HTTP for local development.
# Usage: http-serve.sh [port] [directory]
# Defaults: port=8765, directory=current working directory
set -euo pipefail

PORT="${1:-8765}"
DIR="${2:-.}"

exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR"
