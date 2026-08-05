#!/usr/bin/env bash
# Runs the XCTest bundle in a loop to measure how often the intermittent
# SIGABRT reproduces, and to capture a backtrace when it does.
#
# The abort prints "freed pointer was not the last allocation" and exits with
# signal 6. It comes from the Swift concurrency task allocator, lands at the
# moment the XCTest phase hands off to the swift-testing runner, and has never
# reproduced on a developer machine — only on CI. Two fixes were shipped on the
# strength of a plausible-looking suspect and neither removed it, so this exists
# to get a rate and a stack before anyone guesses a third time.
#
#   scripts/flake-hunt.sh                 # 20 iterations, plain
#   ITERATIONS=50 scripts/flake-hunt.sh   # more samples
#   MODE=lldb scripts/flake-hunt.sh       # capture a backtrace on abort
#
# MODE=lldb runs every iteration under the debugger, which changes timing and
# may itself mask the abort. That is a real outcome worth recording, not a
# failure of the script: run both modes and compare the rates.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITERATIONS="${ITERATIONS:-20}"
MODE="${MODE:-plain}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/.build/flake-hunt}"

cd "$ROOT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "Building test bundle."
swift build --build-tests

BUNDLE_PATH="$(swift build --build-tests --show-bin-path)/KurottyPackageTests.xctest"
if [[ ! -d "$BUNDLE_PATH" ]]; then
  echo "test bundle not found at $BUNDLE_PATH" >&2
  exit 1
fi

# Swift's own backtracer would print a stack without needing a crash report,
# but `xctest` is a privileged executable and the runtime refuses to install the
# handler for those ("backtrace-on-crash is not supported for privileged
# executables"). It is set anyway in case that changes; MODE=lldb is the path
# that actually yields a stack today.
export SWIFT_BACKTRACE="enable=yes,interactive=no,color=no,threads=all"

run_once() {
  local log="$1"
  if [[ "$MODE" == "lldb" ]]; then
    xcrun lldb \
      --batch \
      -o "run" \
      -k "thread backtrace all" \
      -k "quit 1" \
      -- "$(xcrun -f xctest)" "$BUNDLE_PATH" \
      >"$log" 2>&1
    return $?
  fi
  xcrun xctest "$BUNDLE_PATH" >"$log" 2>&1
}

# A crash report can take a moment to land, and the name is not always
# xctest-prefixed, so this scans everything newer than the run rather than
# globbing one prefix the way the CI step used to.
collect_crash_reports() {
  local destination="$1"
  sleep 5
  for directory in "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports; do
    [[ -d "$directory" ]] || continue
    find "$directory" -type f -newermt '-5 minutes' -print0 2>/dev/null |
      while IFS= read -r -d '' report; do
        cp "$report" "$destination/" 2>/dev/null || true
      done
  done
}

failures=0
aborts=0
echo "Running $ITERATIONS iterations in $MODE mode."
for ((iteration = 1; iteration <= ITERATIONS; iteration++)); do
  log="$OUT_DIR/run-$iteration.log"
  run_once "$log"
  status=$?

  if [[ $status -eq 0 ]]; then
    printf 'run %3d: ok\n' "$iteration"
    rm -f "$log"
    continue
  fi

  failures=$((failures + 1))
  if grep -q "freed pointer was not the last allocation" "$log"; then
    aborts=$((aborts + 1))
    printf 'run %3d: ABORT (task allocator) exit=%d -> %s\n' "$iteration" "$status" "$log"
    mkdir -p "$OUT_DIR/crash-$iteration"
    collect_crash_reports "$OUT_DIR/crash-$iteration"
  else
    printf 'run %3d: failed exit=%d (not the known abort) -> %s\n' "$iteration" "$status" "$log"
  fi
done

echo
echo "iterations       : $ITERATIONS"
echo "failures         : $failures"
echo "task-allocator   : $aborts"
if [[ $ITERATIONS -gt 0 ]]; then
  echo "abort rate       : $((aborts * 100 / ITERATIONS))%"
fi
echo "logs             : $OUT_DIR"

# The point is the measurement, so a reproduction is not a script failure. Only
# report nonzero when nothing ran.
exit 0
