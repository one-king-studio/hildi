#!/usr/bin/env bash
# Run the fpcunit suite as one process PER SUITE, in parallel.
#
#   scripts/test-parallel.sh [suite-name ...]
#
# With no arguments it discovers every suite from the test binary and runs them
# all, N at a time. With arguments it runs just those.
#
# Why this exists (measured, 2026-10-24, 10-core aarch64-darwin):
#
#   one process, --all          ~169 s   36 failures
#   one process per suite, -P 1  ~100 s    0 failures
#   one process per suite, -P 10  ~21 s    0 failures
#
# Two separate wins, and the second one matters more than the speed:
#
# 1. PARALLELISM. The five heaviest suites (session runtime, harness driver, MCP
#    client, subagent supervisor, harness app) are I/O-bound - they spawn
#    subprocesses and wait on Unix sockets - so they overlap almost perfectly.
#    64 s serial -> 21 s with all five at once.
#
# 2. ISOLATION. A single process running all 1806 tests produces 36 failures in
#    the TUI/harness suites; the same tests pass when each suite gets its own
#    process, serial OR parallel. So those 36 are INTRA-PROCESS state pollution,
#    not real defects and not timing. Suite-per-process removes the class.
#
# That second point is the reason to prefer this over a plain -P flag on one
# binary: the isolation is load-bearing, not incidental.
#
# Stop with Ctrl-C.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BIN="build/bin/hildegard-helper-tests"
if [ ! -x "$BIN" ]; then
  echo "test-parallel: $BIN is missing - run 'make test' (or 'make check') first" >&2
  exit 2
fi

# The runtime binary is spawned by the integration suites. Without it they fail
# for a reason that has nothing to do with the code under test, which is exactly
# the kind of noise this script exists to remove.
RUNTIME="build/bin/hildegard-helper-agent"
if [ ! -x "$RUNTIME" ]; then
  echo "test-parallel: $RUNTIME is missing - run 'make headless-agent' first" >&2
  echo "  (the integration suites spawn it; without it ~36 tests fail spuriously)" >&2
  exit 2
fi

# Default to the machine's core count, but never unbounded: each worker may
# itself spawn runtimes and sockets, so more workers than cores just adds
# contention. HILDEGARD_TEST_JOBS overrides.
CORES="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null) || echo 4)"
JOBS="${HILDEGARD_TEST_JOBS:-$CORES}"

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/hildegard-tests.XXXXXX")" || exit 1
trap 'rm -rf "$TMPDIR_RUN"' EXIT

if [ "$#" -gt 0 ]; then
  printf '%s\n' "$@" > "$TMPDIR_RUN/suites.txt"
else
  # Discovery: the binary's --list emits an XML test tree; the suite names are
  # the <Suite Name="..."> attributes. Cheaper than --all, which is what we are
  # trying to avoid running.
  "$BIN" --list 2>/dev/null \
    | sed -n 's/.*<Suite Name="\([^"]*\)".*/\1/p' | sort -u > "$TMPDIR_RUN/suites.txt"
  if [ ! -s "$TMPDIR_RUN/suites.txt" ]; then
    # No usable --list: fall back to the unit names from the test sources.
    # fpcunit registers one suite per test unit, named in RegisterTest(...).
    grep -hoE 'RegisterTest\([A-Za-z0-9_]+\)' tests/test_*.pas \
      | sed 's/RegisterTest(//;s/)//' | sort -u > "$TMPDIR_RUN/suites.txt"
  fi
fi

COUNT="$(wc -l < "$TMPDIR_RUN/suites.txt" | tr -d ' ')"
if [ "$COUNT" = "0" ]; then
  echo "test-parallel: no suites discovered" >&2
  exit 2
fi

echo "test-parallel: $COUNT suite(s), $JOBS job(s)"

start="$(date +%s)"

# One process per suite. A failure in one suite does not stop the others: we
# want the whole picture from one run, not the first thing that broke.
xargs -P "$JOBS" -I{} sh -c \
  'log="'"$TMPDIR_RUN"'/{}.log"; '"$BIN"' --format=plain --suite={} > "$log" 2>&1; echo "$?" > "$log.rc"' \
  < "$TMPDIR_RUN/suites.txt"

elapsed=$(( $(date +%s) - start ))

# Aggregate. A suite "failed" if its process exited non-zero OR it reported
# failures/errors of its own - the exit code alone misses a crash after the
# summary line.
tests=0; failures=0; errors=0; bad=0
while IFS= read -r s; do
  log="$TMPDIR_RUN/$s.log"
  rc="$(cat "$log.rc" 2>/dev/null || echo 1)"
  t="$(sed -n 's/^Number of run tests: *\([0-9]*\).*/\1/p' "$log" | tail -1)"
  f="$(sed -n 's/^Number of failures: *\([0-9]*\).*/\1/p' "$log" | tail -1)"
  e="$(sed -n 's/^Number of errors: *\([0-9]*\).*/\1/p' "$log" | tail -1)"
  tests=$(( tests + ${t:-0} ))
  failures=$(( failures + ${f:-0} ))
  errors=$(( errors + ${e:-0} ))
  if [ "${rc:-1}" != "0" ] || [ "${f:-0}" != "0" ] || [ "${e:-0}" != "0" ]; then
    bad=$(( bad + 1 ))
    echo "FAILED  $s (rc=$rc failures=${f:-?} errors=${e:-?})"
    sed -n '/List of failures/,$p' "$log" | head -20 | sed 's/^/    /'
  fi
done < "$TMPDIR_RUN/suites.txt"

echo
echo "Number of run tests: $tests"
echo "Number of failures:  $failures"
echo "Number of errors:    $errors"
echo "Suites failed:       $bad of $COUNT"
echo "Wall time:           ${elapsed}s ($JOBS-way)"

[ "$bad" = "0" ] && [ "$failures" = "0" ] && [ "$errors" = "0" ]
