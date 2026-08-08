#!/usr/bin/env bash
#
# Task-shape body-entry benchmark.
#
# Usage: scripts/benchmark-task-shape.sh <1z-binary> <reps> <benchmark.1z> <threads>...
#
# Runs one task-shape benchmark once per named --threads setting, `reps` times
# each, under --compile=off so the JIT does not mask the interpreter. For every
# setting it takes the median of the internal `timing.user_ns` reported by
# --benchmark=json, and prints one row with the median plus the min/max spread.
#
# The thread axis is the point: these shapes measure what body entry costs
# across workers, so the same file at --threads=auto and --threads=1 are two
# separate rows rather than two runs of one row.
#
# Build the binary with `make release` for representative numbers.

set -euo pipefail

if [ "$#" -lt 4 ]; then
    echo "usage: $0 <1z-binary> <reps> <benchmark.1z> <threads>..." >&2
    exit 2
fi

onez="$1"
reps="$2"
benchmark="$3"
shift 3
thread_settings=("$@")

# median of the integers passed as args
median() {
    local sorted n mid
    sorted=$(printf '%s\n' "$@" | sort -n)
    n=$#
    mid=$(( (n + 1) / 2 ))
    printf '%s\n' "$sorted" | sed -n "${mid}p"
}

min() { printf '%s\n' "$@" | sort -n | head -1; }
max() { printf '%s\n' "$@" | sort -n | tail -1; }

# ns -> milliseconds with three decimals
ns_to_ms() { awk -v ns="$1" 'BEGIN { printf "%.3f", ns / 1000000.0 }'; }

# Run the benchmark once at one thread setting and echo its timing.user_ns.
# The JSON report is the last line of stdout, after whatever the file printed.
run_user_ns() {
    local threads="$1" output json
    output=$("$onez" run --compile=off "--threads=$threads" --benchmark=json "$benchmark" 2>/dev/null)
    json=$(printf '%s\n' "$output" | tail -1)
    printf '%s\n' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['timing']['user_ns'])"
}

echo "Task-shape body-entry cost: $(basename "$benchmark")"
echo "binary=$onez   reps=$reps   mode=--compile=off"
echo ""

printf "%-28s %-16s %14s %14s %14s\n" "shape" "flags" "median_ms" "min_ms" "max_ms"
printf "%-28s %-16s %14s %14s %14s\n" "----------------------------" "----------------" \
    "--------------" "--------------" "--------------"

for threads in "${thread_settings[@]}"; do
    samples=()
    for _ in $(seq 1 "$reps"); do
        samples+=("$(run_user_ns "$threads")")
    done

    med=$(median "${samples[@]}")
    lo=$(min "${samples[@]}")
    hi=$(max "${samples[@]}")

    printf "%-28s %-16s %14s %14s %14s\n" \
        "$(basename "$benchmark")" "--threads=$threads" \
        "$(ns_to_ms "$med")" "$(ns_to_ms "$lo")" "$(ns_to_ms "$hi")"
done
