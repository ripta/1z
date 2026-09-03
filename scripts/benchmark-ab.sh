#!/usr/bin/env bash
#
# Interleaved two-binary benchmark A/B.
#
# Usage: scripts/benchmark-ab.sh <baseline-binary> <candidate-binary> [reps] [workload-filter]
#
# Runs the interpreter-dispatch archetype suite and the task-shape benchmarks
# against two 1z binaries and reports the ratio per workload. Both binaries run
# the same workload back to back within every rep, so a load spike or a thermal
# shift lands on both sides instead of on whichever side happened to run during
# it. Sequential whole-suite rounds do not have that property, and the drift
# they admit is the same order as the deltas being measured.
#
# A workload filter is a substring of the workload label. It narrows the run to
# the matching rows, which is how one workload is re-measured at a higher rep
# count than the suite pass.
#
# Each binary resolves its own standard library through the `zig-out/lib`
# symlink beside it, so the two may live in different worktrees. Build both with
# `make release`.

set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <baseline-binary> <candidate-binary> [reps] [workload-filter]" >&2
    exit 2
fi

baseline="$1"
candidate="$2"
reps="${3:-7}"
filter="${4:-}"

# The user startup file would add arbitrary load work to every run.
export ONEZ_NO_STARTUP=1

for onez in "$baseline" "$candidate"; do
    if [ ! -x "$onez" ]; then
        echo "$0: not an executable: $onez" >&2
        exit 2
    fi
done

# Format: "label|path|flags". The archetypes match
# scripts/benchmark-interpreter-suite.sh; the task shapes match
# scripts/benchmark-task-shape.sh, whose thread axis makes one file two rows.
workloads=(
    "quotation_seq.1z|tests/benchmark/quotation_seq.1z|"
    "fibonacci.1z|tests/benchmark/fibonacci.1z|"
    "string_assembly_bench.1z|tests/benchmark/string_assembly_bench.1z|"
    "data_structures.1z|tests/benchmark/data_structures.1z|"
    "bench_generic_dispatch.1z|tests/benchmark/bench_generic_dispatch.1z|"
    "bench_tokenize_iso.1z|tests/benchmark/bench_tokenize_iso.1z|"
    "task_body_entry.1z --threads=auto|tests/benchmark/task_body_entry.1z|--threads=auto"
    "task_body_entry.1z --threads=1|tests/benchmark/task_body_entry.1z|--threads=1"
    "combinator_contention.1z|tests/benchmark/combinator_contention.1z|--threads=auto"
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

ns_to_ms() { awk -v ns="$1" 'BEGIN { printf "%.3f", ns / 1000000.0 }'; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b / a }'; }

# One side's cell: the median with its spread, as a single field so the column
# stays aligned under a fixed width.
cell() {
    printf '%s (%s-%s)' "$(ns_to_ms "$(median "$@")")" \
        "$(ns_to_ms "$(min "$@")")" "$(ns_to_ms "$(max "$@")")"
}

# Run one workload once under one binary and echo its timing.user_ns. The JSON
# report is the last line of stdout, after whatever the file printed.
run_user_ns() {
    local onez="$1" file="$2" flags="$3" output json
    # flags is deliberately word-split: it carries zero or more whole flags.
    # shellcheck disable=SC2086
    output=$("$onez" run --compile=off $flags --benchmark=json "$file" 2>/dev/null)
    json=$(printf '%s\n' "$output" | tail -1)
    printf '%s\n' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['timing']['user_ns'])"
}

echo "Interleaved benchmark A/B"
echo "baseline=$baseline"
echo "candidate=$candidate"
echo "reps=$reps   mode=--compile=off"
echo ""

printf "%-36s %28s %28s %10s\n" "workload" "baseline_ms" "candidate_ms" "cand/base"
printf "%-36s %28s %28s %10s\n" "------------------------------------" \
    "----------------------------" "----------------------------" "----------"

for entry in "${workloads[@]}"; do
    label="${entry%%|*}"
    rest="${entry#*|}"
    file="${rest%%|*}"
    flags="${rest#*|}"

    if [ -n "$filter" ] && [[ "$label" != *"$filter"* ]]; then
        continue
    fi

    base_samples=()
    cand_samples=()
    for _ in $(seq 1 "$reps"); do
        base_samples+=("$(run_user_ns "$baseline" "$file" "$flags")")
        cand_samples+=("$(run_user_ns "$candidate" "$file" "$flags")")
    done

    printf "%-36s %28s %28s %10s\n" \
        "$label" \
        "$(cell "${base_samples[@]}")" \
        "$(cell "${cand_samples[@]}")" \
        "$(ratio "$(median "${base_samples[@]}")" "$(median "${cand_samples[@]}")")"
done
