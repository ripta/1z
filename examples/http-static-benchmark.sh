#!/usr/bin/env bash
#
# Benchmark examples/http-static.1z across the execution modes: interpreted
# (--compile=off), JIT hybrid (--compile=hybrid), and JIT eager (--compile=eager).
# The AOT mode (`1z build --interpreter-fallback=false`) is attempted last.
#
# The interpreter and runtime are built with `make release`. That is the single
# load-bearing choice: a debug build runs a safety allocator that takes a global
# lock per allocation, which serializes the allocation-heavy serve path and makes
# every mode 35-50x too slow. `make release` also installs the release lib1z.a
# that the AOT build links, so the AOT binary links the release runtime too.
#
# Each mode serves a sustained load. The old per-connection leak is fixed, so the
# server stays bounded; steady-state RSS is sampled per mode to show it.
#
# Each mode is driven across a 2x2 matrix: two connection modes by two
# concurrency levels. Plain `ab` sends HTTP/1.0 with no keep-alive header, so the
# server closes after every response: the close-per-request baseline. `ab -k`
# adds `Connection: keep-alive`, so the server reuses each connection up to its
# 100-requests-per-connection cap, amortizing the per-connection task spawn. Each
# connection mode is measured at concurrency 1 and 20, so a reader can see
# throughput scale with concurrency.
#
# Each cell runs five times and the median run by throughput is reported, with its
# latency percentile line. The interpreter mode varies enough run to run that a
# single pass cannot rank the modes.
#
# Requires ApacheBench (`ab`), which ships with macOS.
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
WARMUP_N=400           # Discarded per measured run; warms up at that run's concurrency.
REPS=5                 # Runs per cell; the median run by throughput is reported. The
                       # interpreter mode varies run to run, so a single pass cannot
                       # rank the modes.
MEASURE_N_C1=4000      # Serial runs are slower, so fewer requests still run long.
MEASURE_N_C20=8000     # Concurrent runs are long on purpose, well past the point
                       # where the old per-connection leak used to exhaust memory.
MEASURE_CONCS="1 20"   # Each connection mode is measured at each of these.
MAX_MEMORY=256M        # Bounded. The per-connection leak is fixed, so the cap holds
                       # for interpreter/JIT. AOT binaries ignore this driver flag;
                       # their memory is shown via RSS.

# Request count for a concurrency level. Serial runs get fewer requests because
# they are slower per request.
measure_n_for() {
  [ "$1" = "1" ] && echo "${MEASURE_N_C1}" || echo "${MEASURE_N_C20}"
}

command -v ab >/dev/null 2>&1 || { echo "error: ApacheBench (ab) not found" >&2; exit 1; }

echo "Building the release interpreter and runtime..."
make release >/dev/null

# Temp doc root with a small index.html.
DOCROOT="$(mktemp -d)"
printf '<h1>hello from 1z</h1>\n' > "${DOCROOT}/index.html"

SERVER_PID=""
AOT_BIN=""
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null || true
  [ -n "${AOT_BIN}" ] && rm -f "${AOT_BIN}" || true
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
  echo "Warmup:      -n ${WARMUP_N} (discarded)"
  echo "Measured:    ${REPS} runs/cell, median by req/s; -n ${MEASURE_N_C1} at c=1, -n ${MEASURE_N_C20} at c=20"
  echo "Max memory:  ${MAX_MEMORY} (interpreter/JIT; AOT is uncapped, see RSS)"
  echo "Latency:     p50/p90/p95/p99/max in ms, from the median run"
  echo
  printf '%-10s %-10s %4s %8s %5s %5s %5s %5s %6s %8s\n' "mode" "conn" "c" "req/s" "p50" "p90" "p95" "p99" "max" "RSS(MB)"
  printf '%-10s %-10s %4s %8s %5s %5s %5s %5s %6s %8s\n' "----" "----" "-" "-----" "---" "---" "---" "---" "---" "-------"
} >> "${OUT}"

# Launch an interpreter/JIT server. Sets SERVER_PID.
launch_jit() {
  local mode="$1" port="$2"
  "${BIN}" run "--compile=${mode}" "--max-memory=${MAX_MEMORY}" \
    examples/http-static.1z --port "${port}" --dir "${DOCROOT}" &
  SERVER_PID=$!
}

# Launch the prebuilt AOT binary. Sets SERVER_PID. AOT binaries take no
# --max-memory (that is a driver flag); their memory is reported via RSS.
launch_aot() {
  local port="$1"
  "${AOT_BIN}" --port "${port}" --dir "${DOCROOT}" &
  SERVER_PID=$!
}

# Run REPS measured ab passes for one cell, then record the median run by req/s
# with its full percentile line and the steady-state RSS. AB_FLAGS is empty for
# the close-per-request baseline and "-k" for keep-alive. CONC is the concurrency
# passed to `ab -c`. Assumes SERVER_PID is a running server; does not stop it.
record_row() {
  local label="$1" conn="$2" ab_flags="$3" port="$4" conc="$5"
  local n; n="$(measure_n_for "${conc}")"

  # One line per rep: "req/s p50 p90 p95 p99 max".
  local runs; runs="$(mktemp)"
  local i
  for i in $(seq 1 "${REPS}"); do
    ab ${ab_flags} -n "${n}" -c "${conc}" "http://127.0.0.1:${port}/" 2>/dev/null | awk '
      /Requests per second/ {rps=$4}
      $1=="50%"  {p50=$2}
      $1=="90%"  {p90=$2}
      $1=="95%"  {p95=$2}
      $1=="99%"  {p99=$2}
      $1=="100%" {p100=$2}
      END {printf "%.0f %s %s %s %s %s\n", rps, p50, p90, p95, p99, p100}
    ' >> "${runs}"
  done

  # Median run by req/s: sort numerically on the first field, take the middle line.
  local median; median="$(sort -n "${runs}" | sed -n "$(( (REPS + 1) / 2 ))p")"
  rm -f "${runs}"

  # Steady-state RSS of the server after the cell (KB on macOS -> MB).
  local rss_kb rss_mb
  rss_kb="$(ps -o rss= -p "${SERVER_PID}" 2>/dev/null | tr -d ' ' || true)"
  rss_mb=$(( ${rss_kb:-0} / 1024 ))

  local rps p50 p90 p95 p99 pmax
  read -r rps p50 p90 p95 p99 pmax <<< "${median}"
  printf '%-10s %-10s %4s %8s %5s %5s %5s %5s %6s %8s\n' \
    "${label}" "${conn}" "${conc}" "${rps}" "${p50}" "${p90}" "${p95}" "${p99}" "${pmax}" "${rss_mb}" >> "${OUT}"
}

# Warm up, then measure the 2x2 matrix against the same running server: both
# connection modes at each concurrency level, one recorded row each. Assumes
# SERVER_PID is a running server. Kills it afterward.
measure() {
  local label="$1" port="$2"

  echo "== mode=${label} port=${port} =="
  sleep 2   # eager/AOT modes may compile up front; give it a moment.

  local conc
  for conc in ${MEASURE_CONCS}; do
    # Close-per-request baseline: warmup (discarded) lets the JIT modes reach
    # steady state at this concurrency, then one measured run.
    ab -n "${WARMUP_N}" -c "${conc}" "http://127.0.0.1:${port}/" >/dev/null 2>&1 || true
    record_row "${label}" close "" "${port}" "${conc}"

    # Keep-alive: a separate warmup on the reused connection, then one measured run.
    ab -k -n "${WARMUP_N}" -c "${conc}" "http://127.0.0.1:${port}/" >/dev/null 2>&1 || true
    record_row "${label}" keepalive "-k" "${port}" "${conc}"
  done

  kill "${SERVER_PID}" 2>/dev/null || true
  wait "${SERVER_PID}" 2>/dev/null || true
  SERVER_PID=""
  sleep 1
}

launch_jit off    18211; measure off    18211
launch_jit hybrid 18212; measure hybrid 18212
launch_jit eager  18213; measure eager  18213

# Fill every matrix cell for a mode with a single status word (e.g. reset,
# build-fail). Used when a mode cannot be measured, so its rows are still present.
record_status_rows() {
  local label="$1" status="$2" conn conc
  for conn in close keepalive; do
    for conc in ${MEASURE_CONCS}; do
      printf '%-10s %-10s %4s %8s %5s %5s %5s %5s %6s %8s\n' "${label}" "${conn}" "${conc}" "${status}" "n/a" "n/a" "n/a" "n/a" "n/a" "n/a" >> "${OUT}"
    done
  done
}

# AOT: the example builds with --interpreter-fallback=false. Guard the build and a
# probe of the running server so a build or runtime failure records a status row
# instead of aborting the whole script.
echo "Building the AOT binary (--interpreter-fallback=false)..."
AOT_BIN="$(mktemp)"
if "${BIN}" build --interpreter-fallback=false examples/http-static.1z -o "${AOT_BIN}"; then
  chmod +x "${AOT_BIN}"
  echo "== mode=aot port=18214 =="
  launch_aot 18214
  sleep 2
  # --max-time guards against a compiled server that accepts but never responds:
  # without it a hung connection would block the probe forever.
  if curl -sf --max-time 5 -o /dev/null "http://127.0.0.1:18214/"; then
    measure aot 18214
  else
    # Built and bound, but the compiled handler did not respond to the probe.
    record_status_rows aot reset
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
  fi
else
  record_status_rows aot build-fail
fi

echo >> "${OUT}"
echo "See examples/http-static-benchmark.md for the analysis of these numbers." >> "${OUT}"

echo
echo "Results written to: ${OUT}"
cat "${OUT}"
