#!/usr/bin/env bash
# Parse Playwright HTML report and show test failures summary.
#
# Usage:
#   playwright-report.sh [report-dir]    # defaults to auto-detect
#   playwright-report.sh --full          # show full error details per test
#   playwright-report.sh --test <pattern> # filter by test name pattern
#
# The Playwright HTML reporter stores failure data as .md files in data/.
# Each .md has: # Test info (name + location), # Error details (error message).
# Screenshots (.png) and traces (.webm) are also in data/ but not parsed here.

set -euo pipefail

REPORT_DIR=""
FULL=false
FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL=true; shift ;;
    --test) FILTER="$2"; shift 2 ;;
    *) REPORT_DIR="$1"; shift ;;
  esac
done

# Auto-detect report directory
if [[ -z "$REPORT_DIR" ]]; then
  # First: check for playwright-report/ in project root (Playwright default)
  dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/playwright-report/data" ]]; then
      REPORT_DIR="$dir/playwright-report"
      break
    fi
    dir="$(dirname "$dir")"
  done
  if [[ -z "$REPORT_DIR" ]]; then
    echo "❌ No playwright-report/data/ found. Run tests first." >&2
    exit 1
  fi
fi

DATA_DIR="$REPORT_DIR/data"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "❌ No data/ directory in $REPORT_DIR" >&2
  exit 1
fi

# Count files by type
md_count=$(find "$DATA_DIR" -name "*.md" | wc -l)
png_count=$(find "$DATA_DIR" -name "*.png" | wc -l)
webm_count=$(find "$DATA_DIR" -name "*.webm" | wc -l)

if [[ "$md_count" -eq 0 ]]; then
  echo "✅ No failure reports found — all tests passed (or report is empty)."
  exit 0
fi

echo "📊 Playwright Report: $REPORT_DIR"
echo "   Failure reports: $md_count | Screenshots: $png_count | Traces: $webm_count"
echo ""

# Parse each .md file and extract test info + error summary
declare -A spec_failures  # spec file → count
failures=()

while IFS= read -r md_file; do
  # Extract test name (line after "- Name: ")
  test_name=$(grep -m1 "^- Name: " "$md_file" 2>/dev/null | sed 's/^- Name: //')
  # Extract location
  test_location=$(grep -m1 "^- Location: " "$md_file" 2>/dev/null | sed 's/^- Location: //')
  # Extract first error line (first non-empty line in Error details code block)
  error_line=$(awk '/^# Error details/{found=1; next} found && /^```$/{count++; next} found && count==1 && /[^ ]/{print; exit}' "$md_file" 2>/dev/null)

  [[ -z "$test_name" ]] && continue

  # Apply filter if set
  if [[ -n "$FILTER" ]] && ! echo "$test_name" | grep -qi "$FILTER"; then
    continue
  fi

  # Extract spec file from name (everything before " >> ")
  spec_file=$(echo "$test_name" | sed 's/ >> .*//')

  # Track per-spec counts
  spec_failures["$spec_file"]=$(( ${spec_failures["$spec_file"]:-0} + 1 ))

  failures+=("$test_name|$test_location|$error_line|$md_file")
done < <(find "$DATA_DIR" -name "*.md" -type f | sort)

total=${#failures[@]}

if [[ "$total" -eq 0 ]]; then
  if [[ -n "$FILTER" ]]; then
    echo "No failures matching '$FILTER'."
  else
    echo "✅ No failures found."
  fi
  exit 0
fi

# Summary by spec file
echo "── Failures by spec file ──────────────────────────────────"
for spec in $(echo "${!spec_failures[@]}" | tr ' ' '\n' | sort); do
  printf "  %-45s %d\n" "$spec" "${spec_failures[$spec]}"
done
echo ""
echo "── Total: $total failures ────────────────────────────────"
echo ""

# Detail per failure
echo "── Failed tests ───────────────────────────────────────────"
i=0
for entry in "${failures[@]}"; do
  i=$((i + 1))
  IFS='|' read -r name location error md_path <<< "$entry"

  echo ""
  echo "  $i) $name"
  echo "     📍 $location"
  echo "     ❌ $error"

  if $FULL; then
    echo ""
    echo "     ── Full error ──"
    # Print everything between first ``` pair after "# Error details"
    awk '/^# Error details/{found=1; next} found && /^```$/{count++; next} found && count==1{print "     " $0} found && count>=2{exit}' "$md_path" 2>/dev/null
    echo "     ──────────────"
  fi
done

echo ""
echo "💡 Tips:"
echo "   --full             Show full error details"
echo "   --test <pattern>   Filter by test name (case-insensitive)"
echo "   Open report:       xdg-open $REPORT_DIR/index.html"
