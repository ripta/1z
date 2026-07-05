#!/usr/bin/env bash
#
# Benchmark examples/http-static.1z across the three execution modes:
# interpreted (--compile=off), JIT hybrid (--compile=hybrid), and JIT eager
# (--compile=eager). AOT is intentionally not covered here; see
# examples/http-static-benchmark.md.
#
# Requires ApacheBench (`ab`), which ships with macOS. `wrk` is not used because
# the server sends `Connection: close` (no keep-alive) and `wrk` is not present
# on a stock macOS.
#
# Usage:
#   examples/http-static-benchmark.sh [OUTPUT_FILE]
#
# OUTPUT_FILE defaults to ./http-static-bench-results.txt. The script prints the
# final path on completion.

set -euo pipefail

# Resolve repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

OUT="${1:-${REPO_ROOT}/http-static-bench-results.txt}"
BIN="${REPO_ROOT}/zig-out/bin/1z"

# Benchmark knobs.
WARMUP_N=200
WARMUP_C=10
MEASURE_N=1000
MEASURE_C=20
MAX_MEMORY=2G          # Raised so the per-connection leak (see the .md) does not
                       # kill the server mid-run at the default 256M.

command -v ab >/dev/null 2>&1 || { echo "error: ApacheBench (ab) not found" >&2; exit 1; }

echo "Building the interpreter..."
make build >/dev/null

# Temp doc root with a small index.html.
DOCROOT="$(mktemp -d)"
printf '<h1>hello from 1z</h1>\n' > "${DOCROOT}/index.html"

SERVER_PID=""
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null || true
}
trap cleanup EXIT

: > "${OUT}"
{
  echo "# http-static.1z benchmark"
  echo
  echo "Date:        $(date)"
  echo "Host:        $(uname -mrs)"
  echo "ab:          $(ab -V 2>&1 | head -1)"
  echo "Doc size:    $(wc -c < "${DOCROOT}/index.html") bytes"
  echo "Warmup:      -n ${WARMUP_N} -c ${WARMUP_C} (discarded)"
  echo "Measured:    -n ${MEASURE_N} -c ${MEASURE_C}"
  echo "Max memory:  ${MAX_MEMORY}"
  echo
  printf '%-10s %14s %18s %14s\n' "mode" "req/s" "ms/req(concurrent)" "p50(ms)"
  printf '%-10s %14s %18s %14s\n' "----" "-----" "------------------" "-------"
} >> "${OUT}"

run_mode() {
  local mode="$1" port="$2"

  echo "== mode=${mode} port=${port} =="
  "${BIN}" run "--compile=${mode}" "--max-memory=${MAX_MEMORY}" \
    examples/http-static.1z --port "${port}" --dir "${DOCROOT}" &
  SERVER_PID=$!
  sleep 2   # eager mode compiles up front; give it a moment.

  # Warmup (discarded): lets the JIT modes reach steady state.
  ab -n "${WARMUP_N}" -c "${WARMUP_C}" "http://127.0.0.1:${port}/" >/dev/null 2>&1 || true

  # Measured run.
  local report
  report="$(ab -n "${MEASURE_N}" -c "${MEASURE_C}" "http://127.0.0.1:${port}/" 2>/dev/null)"

  local rps mspr p50
  rps="$(echo "${report}"  | awk '/Requests per second/ {print $4}')"
  mspr="$(echo "${report}" | awk '/across all concurrent/ {print $4}')"
  p50="$(echo "${report}"  | awk '/^  50%/ {print $2}')"

  printf '%-10s %14s %18s %14s\n' "${mode}" "${rps}" "${mspr}" "${p50}" >> "${OUT}"

  kill "${SERVER_PID}" 2>/dev/null || true
  wait "${SERVER_PID}" 2>/dev/null || true
  SERVER_PID=""
  sleep 1
}

run_mode off    18211
run_mode hybrid 18212
run_mode eager  18213

echo >> "${OUT}"
echo "Note: throughput is expected to be nearly identical across modes. The" >> "${OUT}"
echo "server is spawn-bound (one coroutine + context allocated per connection)," >> "${OUT}"
echo "not compute-bound, so the compile mode barely affects it." >> "${OUT}"

echo
echo "Results written to: ${OUT}"
cat "${OUT}"
