#!/usr/bin/env bash
#
# Run fibonacci benchmark across all execution modes and print a comparison.
#
# Usage: scripts/benchmark-fib.sh <1z-binary> <benchmark-file> <aot-binary-path>
#
# The script builds an AOT binary, runs the benchmark in interpreted, hybrid,
# eager, and AOT modes, then prints a timing comparison table.

set -euo pipefail

onez="$1"
benchmark="$2"
aot_bin="$3"

cleanup() { rm -f "$aot_bin"; }
trap cleanup EXIT

echo "Building AOT binary..."
"$onez" build "$benchmark" -o "$aot_bin"
echo ""

echo "Running $benchmark in all modes..."
echo ""

results=()

for mode in interpreted hybrid eager aot; do
    if [ "$mode" = "aot" ]; then
        cmd="$aot_bin"
    elif [ "$mode" = "interpreted" ]; then
        cmd="$onez run --compile=off $benchmark"
    else
        cmd="$onez run --compile=$mode $benchmark"
    fi

    t0=$(gdate +%s%N)
    output=$($cmd 2>/dev/null)
    t1=$(gdate +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))

    results+=("$mode $ms")

    echo "--- $mode ---"
    echo "$output"
    echo ""
done

echo "=== Summary ==="
echo ""
printf "%-15s %10s\n" "Mode" "Time"
printf "%-15s %10s\n" "---------------" "----------"

for entry in "${results[@]}"; do
    read -r mode ms <<< "$entry"
    if [ "$ms" -ge 1000 ]; then
        secs=$(echo "scale=3; $ms / 1000" | bc)
        printf "%-15s %9ss\n" "$mode" "$secs"
    else
        printf "%-15s %8sms\n" "$mode" "$ms"
    fi
done
