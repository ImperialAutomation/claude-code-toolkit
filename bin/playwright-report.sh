#!/usr/bin/env bash
# Parse Playwright test results and show a comprehensive summary.
#
# Usage:
#   playwright-report.sh [report-dir]     # auto-detects, shows all statuses
#   playwright-report.sh --full           # include full error details per failure
#   playwright-report.sh --test <pattern> # filter by test name (case-insensitive)
#   playwright-report.sh --status failed  # filter by status: failed, skipped, passed, interrupted
#
# Data sources (checked in order):
#   1. results.json  — JSON reporter output (complete: all statuses + errors)
#   2. data/*.md     — HTML reporter failure files (failures only, legacy fallback)

set -euo pipefail

REPORT_DIR=""
FULL=false
FILTER=""
STATUS_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL=true; shift ;;
    --test) FILTER="$2"; shift 2 ;;
    --status) STATUS_FILTER="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *) REPORT_DIR="$1"; shift ;;
  esac
done

# Auto-detect report directory
if [[ -z "$REPORT_DIR" ]]; then
  dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/playwright-report/results.json" ]] || [[ -d "$dir/playwright-report/data" ]]; then
      REPORT_DIR="$dir/playwright-report"
      break
    fi
    dir="$(dirname "$dir")"
  done
  if [[ -z "$REPORT_DIR" ]]; then
    echo "❌ No playwright-report/ found. Run tests first." >&2
    exit 1
  fi
fi

JSON_FILE="$REPORT_DIR/results.json"

# ─── JSON reporter path (preferred) ───────────────────────────
if [[ -f "$JSON_FILE" ]]; then
  python3 - "$JSON_FILE" "$FULL" "$FILTER" "$STATUS_FILTER" <<'PYEOF'
import json, sys, os
from collections import Counter, defaultdict

json_file = sys.argv[1]
show_full = sys.argv[2] == "true"
name_filter = sys.argv[3].lower() if sys.argv[3] else ""
status_filter = sys.argv[4].lower() if sys.argv[4] else ""

with open(json_file) as f:
    report = json.load(f)

# Flatten all tests from nested suites
tests = []

def walk_suites(suites, file_path=""):
    for suite in suites:
        fp = suite.get("file", file_path)
        title_parts = [suite.get("title", "")]
        for spec in suite.get("specs", []):
            for test in spec.get("tests", []):
                # Determine overall status from results
                results = test.get("results", [])
                status = test.get("status", "unknown")  # expected, unexpected, skipped, flaky
                expected = test.get("expectedStatus", "passed")

                # Map Playwright status to human-readable
                if status == "expected":
                    display_status = expected  # usually "passed"
                elif status == "unexpected":
                    display_status = "failed"
                elif status == "skipped":
                    display_status = "skipped"
                elif status == "flaky":
                    display_status = "flaky"
                else:
                    display_status = status

                # Check for "did not run" — interrupted tests with no actual results
                if results and results[-1].get("status") == "interrupted":
                    display_status = "did-not-run"

                # Build full test name
                spec_title = spec.get("title", "")
                full_title = " >> ".join([t for t in title_parts + [spec_title] if t])
                location = f"{fp}:{spec.get('line', '?')}:{spec.get('column', '?')}"

                # Collect error info
                error_msg = ""
                error_full = ""
                if results:
                    last_result = results[-1]
                    err = last_result.get("error", {})
                    error_msg = err.get("message", "").split("\n")[0][:200] if err else ""
                    error_full = err.get("message", "") if err else ""

                    # For skipped: check annotations for skip reason
                    if display_status == "skipped":
                        for ann in test.get("annotations", []):
                            if ann.get("type") == "skip":
                                error_msg = ann.get("description", "")
                                break

                tests.append({
                    "file": os.path.basename(fp),
                    "title": full_title,
                    "location": location,
                    "status": display_status,
                    "error": error_msg,
                    "error_full": error_full,
                })

        # Recurse into child suites
        walk_suites(suite.get("suites", []), suite.get("file", file_path))

walk_suites(report.get("suites", []))

# Apply filters
if name_filter:
    tests = [t for t in tests if name_filter in t["title"].lower()]
if status_filter:
    tests = [t for t in tests if t["status"] == status_filter]

# Count by status
status_counts = Counter(t["status"] for t in tests)
total = len(tests)

# Header
print(f"📊 Playwright Results: {json_file}")
print(f"   Total: {total} tests")
parts = []
for s in ["passed", "failed", "skipped", "flaky", "did-not-run"]:
    if status_counts.get(s, 0) > 0:
        icon = {"passed": "✅", "failed": "❌", "skipped": "⏭️", "flaky": "🔄", "did-not-run": "⏸️"}[s]
        parts.append(f"{icon} {s}: {status_counts[s]}")
print(f"   {' | '.join(parts)}")
print()

# Group non-passed tests by spec file
non_passed = [t for t in tests if t["status"] != "passed"]
if not non_passed:
    print("✅ All tests passed!")
    sys.exit(0)

# Summary by spec file
by_file = defaultdict(lambda: Counter())
for t in non_passed:
    by_file[t["file"]][t["status"]] += 1

print("── Non-passed by spec file ────────────────────────────────")
for spec in sorted(by_file):
    counts = by_file[spec]
    parts = [f"{s}={c}" for s, c in sorted(counts.items())]
    print(f"  {spec:<45s} {', '.join(parts)}")
print()

# Group by status
for status in ["failed", "skipped", "did-not-run", "flaky"]:
    group = [t for t in non_passed if t["status"] == status]
    if not group:
        continue

    icon = {"failed": "❌", "skipped": "⏭️", "did-not-run": "⏸️", "flaky": "🔄"}[status]
    label = {"failed": "Failed tests", "skipped": "Skipped tests", "did-not-run": "Did not run", "flaky": "Flaky tests"}[status]
    print(f"── {icon} {label} ({len(group)}) ─────────────────────────────────")

    for i, t in enumerate(group, 1):
        print()
        print(f"  {i}) {t['title']}")
        print(f"     📍 {t['location']}")
        if t["error"]:
            if status == "skipped":
                print(f"     💬 {t['error']}")
            else:
                print(f"     ❌ {t['error']}")

        if show_full and t.get("error_full") and status == "failed":
            print()
            print("     ── Full error ──")
            for line in t["error_full"].split("\n"):
                print(f"     {line}")
            print("     ──────────────")

    print()

print("💡 Tips:")
print("   --full              Show full error details for failures")
print("   --test <pattern>    Filter by test name (case-insensitive)")
print("   --status <status>   Filter: failed, skipped, did-not-run, passed")
print(f"   Open report:        xdg-open {os.path.dirname(json_file)}/index.html")
PYEOF
  exit $?
fi

# ─── Legacy fallback: parse .md failure files ─────────────────
DATA_DIR="$REPORT_DIR/data"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "❌ No results.json or data/ in $REPORT_DIR" >&2
  echo "   Add [\"json\", {\"outputFile\": \"playwright-report/results.json\"}] to playwright.config.ts reporter list." >&2
  exit 1
fi

md_count=$(find "$DATA_DIR" -name "*.md" | wc -l)
png_count=$(find "$DATA_DIR" -name "*.png" | wc -l)
webm_count=$(find "$DATA_DIR" -name "*.webm" | wc -l)

if [[ "$md_count" -eq 0 ]]; then
  echo "✅ No failure reports found — all tests passed (or report is empty)."
  exit 0
fi

echo "📊 Playwright Report: $REPORT_DIR (legacy .md mode — add JSON reporter for full details)"
echo "   Failure reports: $md_count | Screenshots: $png_count | Traces: $webm_count"
echo ""

declare -A spec_failures
failures=()

while IFS= read -r md_file; do
  test_name=$(grep -m1 "^- Name: " "$md_file" 2>/dev/null | sed 's/^- Name: //')
  test_location=$(grep -m1 "^- Location: " "$md_file" 2>/dev/null | sed 's/^- Location: //')
  error_line=$(awk '/^# Error details/{found=1; next} found && /^```$/{count++; next} found && count==1 && /[^ ]/{print; exit}' "$md_file" 2>/dev/null)

  [[ -z "$test_name" ]] && continue

  if [[ -n "$FILTER" ]] && ! echo "$test_name" | grep -qi "$FILTER"; then
    continue
  fi

  spec_file=$(echo "$test_name" | sed 's/ >> .*//')
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

echo "── Failures by spec file ──────────────────────────────────"
for spec in $(echo "${!spec_failures[@]}" | tr ' ' '\n' | sort); do
  printf "  %-45s %d\n" "$spec" "${spec_failures[$spec]}"
done
echo ""
echo "── Total: $total failures ────────────────────────────────"
echo ""

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
    awk '/^# Error details/{found=1; next} found && /^```$/{count++; next} found && count==1{print "     " $0} found && count>=2{exit}' "$md_path" 2>/dev/null
    echo "     ──────────────"
  fi
done

echo ""
echo "💡 Tips:"
echo "   --full             Show full error details"
echo "   --test <pattern>   Filter by test name (case-insensitive)"
echo "   Open report:       xdg-open $REPORT_DIR/index.html"
echo ""
echo "⚠️  Legacy mode: only failures shown. Add JSON reporter for skipped/did-not-run details:"
echo "   reporter: [..., [\"json\", {\"outputFile\": \"playwright-report/results.json\"}]]"
