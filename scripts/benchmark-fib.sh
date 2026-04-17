#!/usr/bin/env bash
#
# Run fibonacci benchmark across all execution modes and print a comparison.
#
# Usage: scripts/benchmark-fib.sh <1z-binary> <benchmark-file> <aot-binary-path>
#
# The script builds an AOT binary, runs the benchmark in interpreted, hybrid,
# eager, and AOT modes, then prints a timing breakdown table.
#
# For interpreter modes, --benchmark=json provides internal timing (prelude
# load, user code, JIT compilation). For AOT, external wall-clock timing is
# used for the build and run steps separately.

set -euo pipefail

onez="$1"
benchmark="$2"
aot_bin="$3"

cleanup() { rm -f "$aot_bin"; }
trap cleanup EXIT

fmt_ms() {
    local ms="$1"
    if [ "$ms" -ge 1000 ]; then
        echo "$(echo "scale=3; $ms / 1000" | bc)s"
    else
        echo "${ms}ms"
    fi
}

# Build AOT binary and time the build step.
echo "Building AOT binary..."
aot_build_t0=$(gdate +%s%N)
"$onez" build "$benchmark" -o "$aot_bin"
aot_build_t1=$(gdate +%s%N)
aot_build_ms=$(( (aot_build_t1 - aot_build_t0) / 1000000 ))
echo ""

echo "Running $benchmark in all modes..."
echo ""

# Collect results: mode prelude_ms jit_ms user_ms total_ms
results=()

for mode in interpreted hybrid eager; do
    if [ "$mode" = "interpreted" ]; then
        compile_flag="--compile=off"
    else
        compile_flag="--compile=$mode"
    fi

    output=$($onez run "$compile_flag" --benchmark=json "$benchmark" 2>/dev/null)

    # Program output is everything before the JSON line.
    program_output=$(echo "$output" | sed '$d')
    json=$(echo "$output" | tail -1)

    prelude_ms=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['timing']['prelude_ns'] // 1000000)")
    user_ms=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['timing']['user_ns'] // 1000000)")
    total_ms=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['timing']['total_ns'] // 1000000)")
    jit_ms=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['timing'].get('jit_compile_ns', d.get('jit',{}).get('compile_time_ns', 0)) // 1000000)")

    results+=("$mode $prelude_ms $jit_ms $user_ms $total_ms")

    echo "--- $mode ---"
    echo "$program_output"
    echo ""
done

# AOT: time the run externally. No prelude, no JIT.
aot_t0=$(gdate +%s%N)
aot_output=$("$aot_bin" 2>/dev/null)
aot_t1=$(gdate +%s%N)
aot_run_ms=$(( (aot_t1 - aot_t0) / 1000000 ))

results+=("aot 0 0 $aot_run_ms $aot_run_ms")

echo "--- aot ---"
echo "$aot_output"
echo ""

echo "=== Summary ==="
echo ""
printf "%-15s %10s %10s %10s %10s\n" "Mode" "Prelude" "JIT" "User" "Total"
printf "%-15s %10s %10s %10s %10s\n" "---------------" "----------" "----------" "----------" "----------"

for entry in "${results[@]}"; do
    read -r mode prelude_ms jit_ms user_ms total_ms <<< "$entry"
    if [ "$mode" = "aot" ]; then
        printf "%-15s %10s %10s %10s %10s\n" "$mode" "--" "--" "$(fmt_ms "$user_ms")" "$(fmt_ms "$total_ms")"
    else
        printf "%-15s %10s %10s %10s %10s\n" "$mode" "$(fmt_ms "$prelude_ms")" "$(fmt_ms "$jit_ms")" "$(fmt_ms "$user_ms")" "$(fmt_ms "$total_ms")"
    fi
done

echo ""
echo "AOT build time: $(fmt_ms "$aot_build_ms")"
