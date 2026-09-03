#!/usr/bin/env bash
# Hang-resistant vitest probe: run each test path in isolation with a hard
# external timeout, so one hanging suite cannot block the whole run.
#
# Each path is run in a separate `vitest run` invocation under `timeout`, so a
# suite that hangs is killed after <timeout> seconds (SIGTERM, then SIGKILL 10s
# later) without affecting the other paths. Per-path wall-clock and exit code
# are written to <out-dir>/summary.txt and a per-path log.
#
# Usage: vitest-probe.sh <timeout-seconds> <out-dir> <vitest-root> <relative-test-path>...
#   timeout-seconds  hard per-suite wall-clock limit (e.g. 60)
#   out-dir          directory for logs + summary.txt (created if missing)
#   vitest-root      directory passed to `vitest --root` (the package containing
#                    vitest.config + tests, e.g. <project>/frontend)
#   relative-test-path...  one or more test paths, relative to vitest-root
#
# Example:
#   vitest-probe.sh 60 /tmp/vitest-out ~/Projects/my-project/frontend \
#     src/components/Foo.test.ts src/lib/bar.test.ts
#
# Exit codes per path (recorded in summary): 0=PASS, 124/137=HANG/TIMEOUT,
# other=FAIL(code). The script itself always exits 0 after probing all paths;
# inspect summary.txt for results.
set -u

TIMEOUT="${1:?timeout seconds required}"
OUTDIR="${2:?output dir required}"
VITEST_ROOT="${3:?vitest root dir required}"
shift 3

if [ "$#" -eq 0 ]; then
  echo "ERROR: no test paths given" >&2
  exit 1
fi

if [ ! -d "$VITEST_ROOT" ]; then
  echo "ERROR: vitest root '$VITEST_ROOT' is not a directory" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"
: > "$SUMMARY"

for path in "$@"; do
  safe=$(echo "$path" | tr '/' '_')
  logfile="$OUTDIR/${safe}.log"
  start=$(date +%s)
  timeout --kill-after=10s "${TIMEOUT}s" \
    npx vitest run --root "$VITEST_ROOT" --reporter=dot "$path" \
    > "$logfile" 2>&1
  code=$?
  end=$(date +%s)
  elapsed=$((end - start))
  if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
    status="HANG/TIMEOUT(${code})"
  elif [ "$code" -eq 0 ]; then
    status="PASS"
  else
    status="FAIL(${code})"
  fi
  printf '%-12s %4ds  %s\n' "$status" "$elapsed" "$path" | tee -a "$SUMMARY"
done

echo "=== DONE ===" | tee -a "$SUMMARY"
