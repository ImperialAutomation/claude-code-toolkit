#!/usr/bin/env bash
set -euo pipefail

# Audit Docker configuration for security, reliability, and optimization issues.
# Checks Dockerfiles and docker-compose files for:
#   - Unpinned images, missing health checks, root user, hardcoded secrets
#   - Missing multi-stage builds, layer optimization, unnecessary packages
#   - Missing .dockerignore, npm install vs npm ci
#
# Usage: docker-audit.sh [project-dir]
# Example: docker-audit.sh /path/to/project

PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Error: directory not found: $PROJECT_DIR" >&2
  exit 2
fi

ISSUES=0

# Collect Docker files
DOCKERFILES=()
COMPOSE_FILES=()

while IFS= read -r f; do
  [[ -n "$f" ]] && DOCKERFILES+=("$f")
done < <(find "$PROJECT_DIR" -name 'Dockerfile*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | sort)

while IFS= read -r f; do
  [[ -n "$f" ]] && COMPOSE_FILES+=("$f")
done < <(find "$PROJECT_DIR" \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose*.yml' -o -name 'compose*.yaml' \) -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | sort)

if [[ ${#DOCKERFILES[@]} -eq 0 && ${#COMPOSE_FILES[@]} -eq 0 ]]; then
  echo "Error: no Dockerfiles or docker-compose files found in $PROJECT_DIR" >&2
  exit 2
fi

echo "Docker Configuration Audit"
echo "=================================================="
echo "Project:    $PROJECT_DIR"
echo "Dockerfiles: ${#DOCKERFILES[@]}"
echo "Compose:     ${#COMPOSE_FILES[@]}"
echo ""

# Build tool patterns (used in multi-stage and unnecessary package checks)
BUILD_TOOL_PATTERN='build-essential|gcc|g[+][+]|make|cmake|python[0-9]*-dev|libffi-dev'

# --- Dockerfile checks ---
if [[ ${#DOCKERFILES[@]} -gt 0 ]]; then
  echo "── Dockerfiles ──"
  echo ""

  for dockerfile in "${DOCKERFILES[@]}"; do
    rel="${dockerfile#"$PROJECT_DIR"/}"
    file_issues=()

    # Read file content once for multi-line analysis
    file_content="$(cat "$dockerfile" 2>/dev/null || true)"

    # Count FROM statements (for multi-stage detection)
    from_count=$(grep -ci '^FROM ' "$dockerfile" 2>/dev/null || echo 0)

    # Collect stage names (for COPY --from validation)
    stage_names=()
    while IFS= read -r line; do
      if [[ "$line" =~ [Aa][Ss][[:space:]]+([a-zA-Z0-9_-]+) ]]; then
        stage_names+=("${BASH_REMATCH[1]}")
      fi
    done < <(grep -i '^FROM ' "$dockerfile" 2>/dev/null || true)

    # --- Existing checks ---

    # Check for unpinned base images
    while IFS= read -r line; do
      image="${line#FROM }"
      # Strip --platform and AS alias
      image="$(echo "$image" | sed 's/--platform=[^ ]* //' | awk '{print $1}')"
      if [[ "$image" == *":latest" ]] || [[ "$image" != *":"* && "$image" != "scratch" && "$image" != *'$'* ]]; then
        file_issues+=("Unpinned base image: $image")
      fi
    done < <(grep -i '^FROM ' "$dockerfile" 2>/dev/null || true)

    # Check for missing HEALTHCHECK
    if ! grep -qi '^HEALTHCHECK' "$dockerfile" 2>/dev/null; then
      file_issues+=("No HEALTHCHECK directive")
    fi

    # Check for missing USER directive (runs as root)
    if ! grep -qi '^USER' "$dockerfile" 2>/dev/null; then
      file_issues+=("No USER directive (runs as root)")
    fi

    # --- New optimization checks ---

    # Check for build tools without multi-stage build
    if [[ "$from_count" -le 1 ]]; then
      # Single-stage build — check if build tools are installed but never removed
      if grep -qE "(apt-get install|apk add).*($BUILD_TOOL_PATTERN)" "$dockerfile" 2>/dev/null; then
        # Check if build tools are removed later (apt-get purge/remove or apk del)
        if ! grep -qE '(apt-get (purge|remove)|apk del)' "$dockerfile" 2>/dev/null; then
          file_issues+=("Build tools in final image without multi-stage build (gcc/build-essential remain in image)")
        fi
      fi
    fi

    # Check for apt-get install without --no-install-recommends
    while IFS= read -r line; do
      if [[ "$line" != *"--no-install-recommends"* ]]; then
        file_issues+=("apt-get install without --no-install-recommends (installs unnecessary packages)")
      fi
    done < <(grep -E 'apt-get\s+install' "$dockerfile" 2>/dev/null || true)

    # Check for pip install without --no-cache-dir (and no PIP_NO_CACHE_DIR env)
    if grep -qE '(^RUN|&&)\s*pip install' "$dockerfile" 2>/dev/null; then
      if ! grep -qE 'PIP_NO_CACHE_DIR' "$dockerfile" 2>/dev/null; then
        if grep -E '(^RUN|&&)\s*pip install' "$dockerfile" 2>/dev/null | grep -qvF -- '--no-cache-dir'; then
          file_issues+=("pip install without --no-cache-dir (cache bloats image)")
        fi
      fi
    fi

    # Check for npm install instead of npm ci (production builds)
    if grep -qE '(^RUN|&&)\s*npm install' "$dockerfile" 2>/dev/null; then
      # Only flag if it's not explicitly a dev dockerfile
      if [[ "$rel" != *".dev"* && "$rel" != *"dev."* ]]; then
        file_issues+=("'npm install' used instead of 'npm ci' (non-deterministic builds)")
      fi
    fi

    # Check for COPY . . without .dockerignore
    if grep -qE '^COPY\s+(--[a-z]+=\S+\s+)*\.\s' "$dockerfile" 2>/dev/null; then
      dockerfile_dir="$(dirname "$dockerfile")"
      # Check for .dockerignore in same dir or build context parent
      if [[ ! -f "$dockerfile_dir/.dockerignore" && ! -f "$dockerfile_dir/../.dockerignore" ]]; then
        file_issues+=("COPY . . without .dockerignore (sends entire context including .git, node_modules, etc.)")
      fi
    fi

    # Check for apt-get update without cleanup in same RUN layer
    # Join continuation lines (backslash + newline) to analyze full RUN instructions
    joined_content="$(sed -z 's/\\\n/ /g' "$dockerfile" 2>/dev/null || true)"
    while IFS= read -r line; do
      if echo "$line" | grep -qE 'apt-get\s+update' 2>/dev/null; then
        if ! echo "$line" | grep -qE 'rm\s+-rf\s+/var/lib/apt/lists' 2>/dev/null; then
          file_issues+=("apt-get update without 'rm -rf /var/lib/apt/lists/*' in same RUN layer")
        fi
      fi
    done < <(echo "$joined_content" | grep -E '^RUN ' 2>/dev/null || true)

    # Check for unpinned COPY --from (external images only)
    while IFS= read -r line; do
      if [[ "$line" =~ COPY[[:space:]]+--from=([^[:space:]]+) ]]; then
        copy_from="${BASH_REMATCH[1]}"
        # Skip numeric stage references (e.g., --from=0)
        if [[ "$copy_from" =~ ^[0-9]+$ ]]; then
          continue
        fi
        # Skip local stage names
        is_local=false
        for stage in "${stage_names[@]+"${stage_names[@]}"}"; do
          if [[ "$copy_from" == "$stage" ]]; then
            is_local=true
            break
          fi
        done
        if [[ "$is_local" == "false" ]]; then
          # External image reference — check for tag
          if [[ "$copy_from" == *":latest" ]] || [[ "$copy_from" != *":"* && "$copy_from" != *'$'* ]]; then
            file_issues+=("Unpinned COPY --from=$copy_from (external image without version tag)")
          fi
        fi
      fi
    done < <(grep -i 'COPY.*--from=' "$dockerfile" 2>/dev/null || true)

    if [[ ${#file_issues[@]} -gt 0 ]]; then
      echo "  $rel:"
      for issue in "${file_issues[@]}"; do
        echo "    - $issue"
      done
      ISSUES=$((ISSUES + ${#file_issues[@]}))
      echo ""
    fi
  done

  # Report clean Dockerfiles
  clean=$((${#DOCKERFILES[@]} - $(echo "$ISSUES" | head -1)))
  # Recount: iterate and check which files had zero issues
  clean=0
  for dockerfile in "${DOCKERFILES[@]}"; do
    rel="${dockerfile#"$PROJECT_DIR"/}"
    has_issue=false

    from_count=$(grep -ci '^FROM ' "$dockerfile" 2>/dev/null || echo 0)

    # Unpinned base image
    if grep -qi '^FROM.*:latest' "$dockerfile" 2>/dev/null; then
      has_issue=true
    fi
    while IFS= read -r line; do
      image="${line#FROM }"
      image="$(echo "$image" | sed 's/--platform=[^ ]* //' | awk '{print $1}')"
      if [[ "$image" != *":"* && "$image" != "scratch" && "$image" != *'$'* ]]; then
        has_issue=true
      fi
    done < <(grep -i '^FROM ' "$dockerfile" 2>/dev/null || true)

    # Missing HEALTHCHECK or USER
    if ! grep -qi '^HEALTHCHECK' "$dockerfile" 2>/dev/null || \
       ! grep -qi '^USER' "$dockerfile" 2>/dev/null; then
      has_issue=true
    fi

    # Build tools without multi-stage
    if [[ "$from_count" -le 1 ]]; then
      if grep -qE "(apt-get install|apk add).*($BUILD_TOOL_PATTERN)" "$dockerfile" 2>/dev/null; then
        if ! grep -qE '(apt-get (purge|remove)|apk del)' "$dockerfile" 2>/dev/null; then
          has_issue=true
        fi
      fi
    fi

    # apt-get install without --no-install-recommends
    if grep -E 'apt-get\s+install' "$dockerfile" 2>/dev/null | grep -qvF -- '--no-install-recommends'; then
      has_issue=true
    fi

    # pip install without --no-cache-dir
    if grep -qE '(^RUN|&&)\s*pip install' "$dockerfile" 2>/dev/null; then
      if ! grep -qE 'PIP_NO_CACHE_DIR' "$dockerfile" 2>/dev/null; then
        if grep -E '(^RUN|&&)\s*pip install' "$dockerfile" 2>/dev/null | grep -qvF -- '--no-cache-dir'; then
          has_issue=true
        fi
      fi
    fi

    # npm install instead of npm ci
    if grep -qE '(^RUN|&&)\s*npm install' "$dockerfile" 2>/dev/null; then
      if [[ "$rel" != *".dev"* && "$rel" != *"dev."* ]]; then
        has_issue=true
      fi
    fi

    # COPY . . without .dockerignore
    if grep -qE '^COPY\s+(--[a-z]+=\S+\s+)*\.\s' "$dockerfile" 2>/dev/null; then
      dockerfile_dir="$(dirname "$dockerfile")"
      if [[ ! -f "$dockerfile_dir/.dockerignore" && ! -f "$dockerfile_dir/../.dockerignore" ]]; then
        has_issue=true
      fi
    fi

    # apt-get update without cleanup
    joined_content="$(sed -z 's/\\\n/ /g' "$dockerfile" 2>/dev/null || true)"
    while IFS= read -r line; do
      if echo "$line" | grep -qE 'apt-get\s+update' 2>/dev/null; then
        if ! echo "$line" | grep -qE 'rm\s+-rf\s+/var/lib/apt/lists' 2>/dev/null; then
          has_issue=true
        fi
      fi
    done < <(echo "$joined_content" | grep -E '^RUN ' 2>/dev/null || true)

    if [[ "$has_issue" != "true" ]]; then
      clean=$((clean + 1))
    fi
  done
  if [[ $clean -gt 0 ]]; then
    echo "  $clean Dockerfile(s) passed all checks."
    echo ""
  fi
fi

# --- docker-compose checks ---
if [[ ${#COMPOSE_FILES[@]} -gt 0 ]]; then
  echo "── Compose Files ──"
  echo ""

  for compose_file in "${COMPOSE_FILES[@]}"; do
    rel="${compose_file#"$PROJECT_DIR"/}"
    file_issues=()

    # Check for unpinned images (:latest or no tag)
    while IFS= read -r line; do
      # Extract image name from "image: name:tag" lines
      image="$(echo "$line" | sed 's/.*image:\s*//' | tr -d '"'"'" | xargs)"
      if [[ "$image" == *":latest" ]]; then
        file_issues+=("Unpinned image: $image")
      fi
    done < <(grep -E '^\s*image:' "$compose_file" 2>/dev/null || true)

    # Check for hardcoded secrets in environment sections
    # Look for PASSWORD=, SECRET=, API_KEY= with literal values (not ${VAR} references)
    while IFS= read -r line; do
      # Skip lines that use variable substitution ${...} or are commented
      if [[ "$line" == *'${'* ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      # Extract the key=value, check if key contains secret-like patterns
      key_part="$(echo "$line" | sed 's/.*- //' | sed 's/.*: //' | tr -d '"'"'" | xargs)"
      if echo "$key_part" | grep -qiE '^(.*_)?(PASSWORD|SECRET|API_KEY|TOKEN|PRIVATE_KEY)=.+'; then
        # Has a non-empty literal value — potential hardcoded secret
        key_name="$(echo "$key_part" | cut -d= -f1)"
        file_issues+=("Possible hardcoded secret: $key_name")
      fi
    done < <(grep -E '(PASSWORD|SECRET|API_KEY|TOKEN|PRIVATE_KEY)=' "$compose_file" 2>/dev/null || true)

    if [[ ${#file_issues[@]} -gt 0 ]]; then
      echo "  $rel:"
      for issue in "${file_issues[@]}"; do
        echo "    - $issue"
      done
      ISSUES=$((ISSUES + ${#file_issues[@]}))
      echo ""
    fi
  done
fi

# Summary
echo "── Summary ──"
if [[ $ISSUES -eq 0 ]]; then
  echo "Result: CLEAN"
  exit 0
else
  echo "Result: $ISSUES ISSUE(S) FOUND"
  exit 1
fi
