#!/usr/bin/env bash
#
# Interleaved two-binary benchmark A/B, un-instrumented.
#
# Usage: scripts/benchmark-wall-ab.sh <baseline-binary> <candidate-binary> [reps] [workload-filter]
#
# The companion to benchmark-ab.sh, and the same workloads, interleaving, and
# table. What differs is the instrument. benchmark-ab.sh passes
# `--benchmark=json`, which runs per-word bookkeeping on every word call and
# reports `timing.user_ns`. That bookkeeping sits on the interpreter's call
# path, so it dilutes a change measured in a few instructions per call: Phase
# 453.2 read 0.998 there against 0.980 here, on the same pair of binaries.
#
# This script runs the workload bare and times the whole process instead. The
# cost is that prelude load rides along in every sample, which both sides pay
# equally, and that a workload printing to a terminal would be timed doing it,
# so output is discarded.
#
# A workload filter is a substring of the workload label. It narrows the run to
# the matching rows, which is how one workload is re-measured at a higher rep
# count than a suite pass.
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

# Format: "label|path|flags", mirroring scripts/benchmark-ab.sh. Keep the two
# lists in step so a row can be taken on either instrument.
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
    "call_word_micro.1z|tests/benchmark/call_word_micro.1z|"
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

# Run one workload once under one binary and echo the elapsed wall time in
# nanoseconds. python3 does the timing because macOS `date` has no %N and
# `/usr/bin/time` resolves only to 10 ms.
run_wall_ns() {
    local onez="$1" file="$2" flags="$3"
    # flags is deliberately word-split: it carries zero or more whole flags.
    # shellcheck disable=SC2086
    python3 -c '
import subprocess, sys, time
start = time.perf_counter()
proc = subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if proc.returncode != 0:
    sys.exit("%s exited %d" % (sys.argv[1], proc.returncode))
print(int((time.perf_counter() - start) * 1000000000))
' "$onez" run --compile=off $flags "$file"
}

echo "Interleaved benchmark A/B (un-instrumented wall clock)"
echo "baseline=$baseline"
echo "candidate=$candidate"
echo "reps=$reps   mode=--compile=off, no --benchmark"
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
        base_samples+=("$(run_wall_ns "$baseline" "$file" "$flags")")
        cand_samples+=("$(run_wall_ns "$candidate" "$file" "$flags")")
    done

    printf "%-36s %28s %28s %10s\n" \
        "$label" \
        "$(cell "${base_samples[@]}")" \
        "$(cell "${cand_samples[@]}")" \
        "$(ratio "$(median "${base_samples[@]}")" "$(median "${cand_samples[@]}")")"
done
