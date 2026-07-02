#!/usr/bin/env bash
#
# Interpreter-dispatch representative-suite baseline.
#
# Usage: scripts/benchmark-interpreter-suite.sh [1z-binary] [reps]
#
# Runs a curated archetype microbenchmark suite plus a real-program
# macrobenchmark under --compile=off (so the JIT does not mask the interpreter),
# `reps` times each. For every workload it takes the median of the internal
# `timing.user_ns` reported by --benchmark=json -- a uniform per-workload
# wall-time that ignores prelude load and whatever the file prints itself -- and
# prints one row per workload with the median plus the min/max spread.
#
# There is deliberately NO suite-wide aggregate row: a single number would let a
# regression in one archetype hide behind a win in another. Per-workload rows
# are the reported result. Absolute times are non-deterministic across
# machines and runs; the recorded medians are the captured baseline.
#
# Build the binary with `make release` for representative numbers.

set -euo pipefail

onez="${1:-./zig-out/bin/1z}"
reps="${2:-7}"

# Curated one-per-archetype suite, all from the existing tests/benchmark/ corpus.
# Format: "archetype|path". Order is stable so the table reads archetype-first.
suite=(
    "combinator-heavy|tests/benchmark/quotation_seq.1z"
    "numeric/recursive|tests/benchmark/fibonacci.1z"
    "string-building|tests/benchmark/string_assembly_bench.1z"
    "data-structure|tests/benchmark/data_structures.1z"
    "dispatch-heavy|tests/benchmark/bench_generic_dispatch.1z"
    "macro/tokenizer|tests/benchmark/bench_tokenize_iso.1z"
)

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

# Run one workload once and echo its timing.user_ns (the JSON is the last line).
run_user_ns() {
    local file="$1" output json
    output=$("$onez" run --compile=off --benchmark=json "$file" 2>/dev/null)
    json=$(printf '%s\n' "$output" | tail -1)
    printf '%s\n' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['timing']['user_ns'])"
}

echo "Interpreter-dispatch representative-suite baseline"
echo "binary=$onez   reps=$reps   mode=--compile=off"
echo ""

printf "%-18s %-40s %14s %14s %14s\n" "archetype" "benchmark" "median_ms" "min_ms" "max_ms"
printf "%-18s %-40s %14s %14s %14s\n" "------------------" "----------------------------------------" \
    "--------------" "--------------" "--------------"

for entry in "${suite[@]}"; do
    archetype="${entry%%|*}"
    file="${entry#*|}"

    samples=()
    for _ in $(seq 1 "$reps"); do
        samples+=("$(run_user_ns "$file")")
    done

    med=$(median "${samples[@]}")
    lo=$(min "${samples[@]}")
    hi=$(max "${samples[@]}")

    printf "%-18s %-40s %14s %14s %14s\n" \
        "$archetype" "$(basename "$file")" \
        "$(ns_to_ms "$med")" "$(ns_to_ms "$lo")" "$(ns_to_ms "$hi")"
done
