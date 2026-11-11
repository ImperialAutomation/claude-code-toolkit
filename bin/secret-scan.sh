#!/usr/bin/env bash
set -euo pipefail

# Scan codebase for hardcoded secrets, API keys, tokens, and credentials.
# Uses regex patterns to detect common secret patterns in source files.
#
# Usage: secret-scan.sh [path...]
# Each path is a file or a directory; all of them are scanned in one run.
# No path scans the current directory.
# Example: secret-scan.sh /path/to/project
#          secret-scan.sh src/components src/pages/Login.tsx
#
# Exit codes: 0 clean, 1 potential secrets found, 2 a path does not exist.

(( $# == 0 )) && set -- .

# Validate every path before scanning anything: a partial scan that reports
# CLEAN is a false verdict.
for path in "$@"; do
  if [[ ! -e "$path" ]]; then
    echo "Error: path not found: $path" >&2
    echo "Usage: secret-scan.sh [path...]  (files or directories)" >&2
    exit 2
  fi
done

SCAN_PATHS=()   # absolute paths handed to the scanner
SCAN_DIRS=()    # the directory arguments, for the tracked .env check
for path in "$@"; do
  if [[ -d "$path" ]]; then
    abs="$(cd "$path" && pwd)"
    SCAN_DIRS+=("$abs")
  else
    abs="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  fi
  SCAN_PATHS+=("$abs")
done

# One directory argument keeps the old output: findings relative to it.
# Several paths show full paths, because relative ones would be ambiguous.
STRIP_PREFIX=""
if [[ ${#SCAN_PATHS[@]} -eq 1 && ${#SCAN_DIRS[@]} -eq 1 ]]; then
  STRIP_PREFIX="${SCAN_DIRS[0]}/"
fi

ISSUES=0

echo "Secret Scan Report"
echo "=================================================="
if [[ ${#SCAN_PATHS[@]} -eq 1 ]]; then
  echo "Project: ${SCAN_PATHS[0]}"
else
  echo "Paths (${#SCAN_PATHS[@]}):"
  for path in "${SCAN_PATHS[@]}"; do
    echo "  $path"
  done
fi
echo ""

# Directories and files to exclude
EXCLUDE_DIRS="node_modules|\.git|\.venv|venv|__pycache__|dist|build|\.next|\.mypy_cache|\.pytest_cache|\.ruff_cache"
EXCLUDE_FILES="\.(lock|svg|png|jpg|jpeg|gif|ico|woff|woff2|ttf|eot|map|min\.js|min\.css)$"
# Files that legitimately contain secret-like patterns
EXCLUDE_PATTERNS="\.env\.example|\.env\.template|secret-scan\.sh|CLAUDE\.md|credentials\.md"

# Build rg exclusion args
RG_ARGS=(
  --no-heading
  --with-filename
  --line-number
  --color never
  --type-add 'src:*.{py,ts,tsx,js,jsx,json,yml,yaml,toml,cfg,ini,conf,sh,sql,html,env}'
  --type src
  -g '!node_modules'
  -g '!.git'
  -g '!.venv'
  -g '!venv'
  -g '!__pycache__'
  -g '!dist'
  -g '!build'
  -g '!.next'
  -g '!*.lock'
  -g '!*.min.js'
  -g '!*.min.css'
  -g '!*.map'
  -g '!package-lock.json'
  -g '!uv.lock'
  -g '!docs/api/*'
)

scan_pattern() {
  local label="$1"
  local pattern="$2"
  local context="${3:-}"

  local results
  results="$(rg "${RG_ARGS[@]}" -e "$pattern" "${SCAN_PATHS[@]}" 2>/dev/null || true)"

  # Filter out known safe files
  if [[ -n "$results" ]]; then
    results="$(echo "$results" | grep -v -E "$EXCLUDE_PATTERNS" || true)"
  fi

  # Filter out lines that are just variable references (${VAR}, $VAR, os.environ, process.env)
  if [[ -n "$results" ]]; then
    results="$(echo "$results" | grep -v -E '(\$\{|os\.environ|process\.env|getenv|Settings\.|settings\.|config\.)' || true)"
  fi

  # Filter out comments and documentation
  if [[ -n "$results" ]]; then
    results="$(echo "$results" | grep -v -E '^\s*(#|//|/\*|\*|<!--)' || true)"
  fi

  if [[ -n "$results" ]]; then
    local count
    count="$(echo "$results" | wc -l | tr -d ' ')"
    echo "── $label ($count) ──"
    [[ -n "$context" ]] && echo "  $context"
    echo ""
    echo "$results" | while IFS= read -r line; do
      # Truncate long lines and make path relative
      local rel_line="$line"
      [[ -n "$STRIP_PREFIX" ]] && rel_line="${line#"$STRIP_PREFIX"}"
      if [[ ${#rel_line} -gt 200 ]]; then
        rel_line="${rel_line:0:200}..."
      fi
      echo "  $rel_line"
    done
    echo ""
    ISSUES=$((ISSUES + count))
  fi
}

# --- Pattern 1: Hardcoded API keys ---
scan_pattern \
  "Hardcoded API Keys" \
  "(api[_-]?key|apikey)\s*[:=]\s*[\"'][a-zA-Z0-9_\-]{16,}[\"']" \
  "API keys should be in environment variables"

# --- Pattern 2: AWS-style credentials ---
scan_pattern \
  "AWS Credentials" \
  "(AKIA[0-9A-Z]{16}|aws_secret_access_key\s*[:=]\s*[\"'][^\s\"']+[\"'])" \
  "AWS credentials must never be in source code"

# --- Pattern 3: Generic secrets/passwords with literal values ---
scan_pattern \
  "Hardcoded Passwords/Secrets" \
  "(password|secret|passwd|pwd)\s*[:=]\s*[\"'][^\"']{8,}[\"']" \
  "Passwords and secrets should be in environment variables"

# --- Pattern 4: Private keys ---
scan_pattern \
  "Private Keys" \
  "-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----" \
  "Private keys must never be committed to source control"

# --- Pattern 5: JWT/Bearer tokens ---
scan_pattern \
  "Hardcoded Tokens" \
  "(bearer|token|jwt)\s*[:=]\s*[\"']eyJ[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+" \
  "Tokens should be dynamically generated, not hardcoded"

# --- Pattern 6: Database connection strings with credentials ---
scan_pattern \
  "Database URLs with Credentials" \
  "(postgres|mysql|mongodb|redis)://[a-zA-Z0-9_]+:[^@\s\$\{]+@" \
  "Database URLs with inline passwords should use environment variables"

# --- Pattern 7: Stripe/payment keys ---
scan_pattern \
  "Payment Provider Keys" \
  "(sk_live_|pk_live_|sk_test_|rk_live_)[a-zA-Z0-9]{10,}" \
  "Payment keys should be in environment variables"

# --- Pattern 8: Generic high-entropy strings assigned to secret-like variables ---
scan_pattern \
  "Suspicious Secret Assignments" \
  "(SECRET_KEY|ENCRYPTION_KEY|SIGNING_KEY|PRIVATE_KEY)\s*[:=]\s*[\"'][a-zA-Z0-9+/=_\-]{32,}[\"']" \
  "Long secret values should come from environment variables"

# --- Check for .env files that might be committed ---
# Runs per directory argument; file arguments have no directory scope to check.
echo "── .env Files in Repository ──"
echo ""
if [[ ${#SCAN_DIRS[@]} -eq 0 ]]; then
  echo "  Only files given; skipping tracked .env check."
fi
for dir in "${SCAN_DIRS[@]}"; do
  [[ ${#SCAN_DIRS[@]} -gt 1 ]] && echo "  $dir:"
  if git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null; then
    tracked_envs="$(git -C "$dir" ls-files '*.env' '.env' '**/.env' 2>/dev/null | grep -v -E '\.(example|template|test|ci|sample)$' || true)"
    if [[ -n "$tracked_envs" ]]; then
      echo "  WARNING: .env files tracked by git:"
      echo "$tracked_envs" | while IFS= read -r f; do
        echo "    $f"
      done
      ISSUES=$((ISSUES + 1))
    else
      echo "  No .env files tracked by git."
    fi
  else
    echo "  Not a git repository — skipping tracked .env check."
  fi
done
echo ""

# Summary
echo "── Summary ──"
if [[ $ISSUES -eq 0 ]]; then
  echo "Result: CLEAN — no hardcoded secrets detected"
  exit 0
else
  echo "Result: $ISSUES POTENTIAL SECRET(S) FOUND"
  echo ""
  echo "Review each finding — some may be false positives (test fixtures, examples)."
  echo "True positives should be moved to environment variables."
  exit 1
fi
