#!/usr/bin/env bash
#
# A/B the freeze-time call-site parameter narrowing under AOT.
#
# Usage: scripts/benchmark-param-inference.sh <1z-binary> <work-file> <startup-file> <out-dir> [reps]
#
# Builds each source twice. Both carry the freeze-time artifact class
# interpreter_free_aot, so the inference pass runs in both, and the lock is the
# only thing that differs: it lets the pass type the result of fixnum arithmetic,
# which is what proves the Fibonacci parameters and lets codegen unbox them at
# entry. The default build leaves them opaque, so the arithmetic keeps the
# polymorphic path. The classes the finished binaries report differ, since the
# baseline emits a fallback and so links the interpreter.
#
# The two builds cannot have the same startup cost. The baseline emits a fallback
# and therefore links the interpreter; the narrowed build is interpreter-free
# because it does not. So the startup file -- the same program with its loop
# running zero times -- is timed too, and the reported loop cost is the
# difference. Attributing that fixed startup gap to the narrowing would overstate
# it several times over on a short workload.
#
# An AOT binary has no --benchmark=json, so every run is timed externally with
# gdate. Each reported figure is the median of `reps` runs, with the min/max
# spread alongside.
#
# Build the 1z binary with `make release` for representative numbers.

set -euo pipefail

# The timing helper runs inside a command substitution, which does not inherit
# errexit on its own. Without this a binary that crashes is timed as a fast
# success, which is exactly the outcome the workload's own guard exists to catch.
shopt -s inherit_errexit

onez="$1"
work_file="$2"
startup_file="$3"
out_dir="$4"
reps="${5:-7}"

work_narrowed="$out_dir/param-inference-work-narrowed"
work_baseline="$out_dir/param-inference-work-baseline"
startup_narrowed="$out_dir/param-inference-startup-narrowed"
startup_baseline="$out_dir/param-inference-startup-baseline"

cleanup() { rm -f "$work_narrowed" "$work_baseline" "$startup_narrowed" "$startup_baseline"; }
trap cleanup EXIT

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

# A rejected locked build means the narrowing regressed, which is the whole point
# of the comparison, so say so instead of reporting half a table.
build_narrowed() {
    local src="$1" out="$2"
    if ! "$onez" build "$src" -o "$out" \
        --interpreter-fallback=false --lock-interpreter-setting >/dev/null; then
        echo "FAIL: the locked interpreter-free build of $src was rejected, so there is no narrowed binary to time" >&2
        exit 1
    fi
    chmod +x "$out"
}

build_baseline() {
    local src="$1" out="$2"
    "$onez" build "$src" -o "$out" >/dev/null
    chmod +x "$out"
}

build_narrowed "$work_file" "$work_narrowed"
build_baseline "$work_file" "$work_baseline"
build_narrowed "$startup_file" "$startup_narrowed"
build_baseline "$startup_file" "$startup_baseline"

# Median wall-clock nanoseconds over `reps` runs, plus the min/max spread.
# Echoes "median min max".
time_binary() {
    local bin="$1" t0 t1
    local samples=()
    for _ in $(seq 1 "$reps"); do
        t0=$(gdate +%s%N)
        "$bin" >/dev/null
        t1=$(gdate +%s%N)
        samples+=("$(( t1 - t0 ))")
    done
    printf '%s %s %s\n' "$(median "${samples[@]}")" "$(min "${samples[@]}")" "$(max "${samples[@]}")"
}

read -r work_narrowed_med work_narrowed_lo work_narrowed_hi <<< "$(time_binary "$work_narrowed")"
read -r work_baseline_med work_baseline_lo work_baseline_hi <<< "$(time_binary "$work_baseline")"
read -r start_narrowed_med start_narrowed_lo start_narrowed_hi <<< "$(time_binary "$startup_narrowed")"
read -r start_baseline_med start_baseline_lo start_baseline_hi <<< "$(time_binary "$startup_baseline")"

echo "AOT parameter-narrowing A/B"
echo "binary=$onez   work=$work_file   startup=$startup_file   reps=$reps"
echo ""

printf "%-24s %-14s %14s %14s %14s\n" "measurement" "build" "median_ms" "min_ms" "max_ms"
printf "%-24s %-14s %14s %14s %14s\n" "------------------------" "--------------" \
    "--------------" "--------------" "--------------"

row() {
    printf "%-24s %-14s %14s %14s %14s\n" "$1" "$2" "$(ns_to_ms "$3")" "$(ns_to_ms "$4")" "$(ns_to_ms "$5")"
}

row "whole program" "narrowed" "$work_narrowed_med" "$work_narrowed_lo" "$work_narrowed_hi"
row "whole program" "baseline" "$work_baseline_med" "$work_baseline_lo" "$work_baseline_hi"
row "startup only" "narrowed" "$start_narrowed_med" "$start_narrowed_lo" "$start_narrowed_hi"
row "startup only" "baseline" "$start_baseline_med" "$start_baseline_lo" "$start_baseline_hi"

echo ""
awk -v wn="$work_narrowed_med" -v wb="$work_baseline_med" \
    -v sn="$start_narrowed_med" -v sb="$start_baseline_med" \
    'BEGIN {
        ln = wn - sn;
        lb = wb - sb;
        printf "loop only (whole program minus startup)\n";
        printf "  narrowed  %10.3f ms\n", ln / 1000000.0;
        printf "  baseline  %10.3f ms\n", lb / 1000000.0;
        printf "  narrowed is %.2fx the baseline loop\n", ln / lb;
        printf "\n";
        printf "startup gap the narrowing does not earn: %.3f ms (the baseline links the interpreter)\n",
            (sb - sn) / 1000000.0;
    }'
