#!/usr/bin/env bash
#
# Time the 1z formatter in every execution mode the language offers.
#
# Usage: scripts/benchmark-fmt-modes.sh <1z-binary> <driver.1z> <aot-binary-path> <file>...
#
# `scripts/benchmark-fmt.sh` answers how the 1z formatter compares to the built-in
# one. This answers a different question: how much of that gap is interpreter
# dispatch. The same driver runs interpreted, under both JIT modes, and out of two
# classes of AOT binary, so the spread between the interpreted row and the fastest
# working row bounds what any interpreter-dispatch work could ever recover. What is
# left over is algorithmic, and no amount of dispatch work reaches it.
#
# The two AOT rows are different classes. `--emit-runtime-image` keeps an interpreter
# for whatever did not compile, so a body that falls back still runs at interpreted
# speed. The locked build adds `--interpreter-fallback=false --lock-interpreter-setting`,
# which refuses to produce a binary at all unless every reached body compiled. A
# rejected build is a result rather than a script failure: its diagnostics name what
# still needs the interpreter, and they are reported in place of the row.
#
# Every mode is probed for agreement before it is timed. The driver prints one byte
# length per file, so a mode that raises or that formats to a different size is
# reported as FAILED and contributes no number. A fast row from a mode that gave up
# early is the one way this table could mislead, so the probe comes first.
#
# Timed rows report whole-process wall clock, the one instrument every mode shares.
# The interpreter rows therefore carry prelude load, which the AOT rows have no
# equivalent of; on this workload that is around ten milliseconds.
#
# Build the binary with `make release` for representative numbers.

set -uo pipefail

onez="$1"
driver="$2"
aot_bin="$3"
shift 3
files=("$@")

REPS="${REPS:-3}"

# Seconds a build or a run gets before it is cut off.
BUILD_BOUND="${BUILD_BOUND:-600}"
RUN_BOUND="${RUN_BOUND:-600}"

aot_locked_bin="$aot_bin-locked"
work="$(mktemp -d)"
cleanup() { rm -rf "$aot_bin" "$aot_locked_bin" "$work"; }
trap cleanup EXIT

export ONEZ_STDLIB="${ONEZ_STDLIB:-lib}"

median() {
    local sorted n mid
    sorted=$(printf '%s\n' "$@" | sort -n)
    n=$#
    mid=$(( (n + 1) / 2 ))
    printf '%s\n' "$sorted" | sed -n "${mid}p"
}

min() { printf '%s\n' "$@" | sort -n | head -1; }
max() { printf '%s\n' "$@" | sort -n | tail -1; }

ns_to_ms() { awk -v ns="$1" 'BEGIN { printf "%.1f", ns / 1000000.0 }'; }

# One run's wall-clock nanoseconds, with stdout and stderr left in the work
# directory under the given tag. Answers the command's exit status.
run_once() {
    local tag="$1"
    shift
    local t0 t1 status
    t0=$(gdate +%s%N)
    timeout "$RUN_BOUND" "$@" >"$work/$tag.out" 2>"$work/$tag.err"
    status=$?
    t1=$(gdate +%s%N)
    elapsed_ns=$(( t1 - t0 ))
    return $status
}

# `label|median|min|max` for a timed mode, or `label|FAILED|<why>` for one that
# did not agree with the interpreted reference.
rows=()

# Probe a mode for agreement, then time it. Everything after the label is the
# command to run.
measure() {
    local label="$1"
    shift

    if ! run_once "probe-$label" "$@"; then
        rows+=("$label|FAILED|raised")
        cp "$work/probe-$label.err" "$work/$label.why"
        return
    fi
    if ! cmp -s "$work/probe-interpreted.out" "$work/probe-$label.out"; then
        rows+=("$label|FAILED|disagreed")
        diff "$work/probe-interpreted.out" "$work/probe-$label.out" >"$work/$label.why"
        return
    fi

    local samples=()
    for _ in $(seq 1 "$REPS"); do
        run_once "time-$label" "$@"
        samples+=("$elapsed_ns")
    done
    rows+=("$label|$(median "${samples[@]}")|$(min "${samples[@]}")|$(max "${samples[@]}")")
}

# Build one AOT class, leaving its cost in build_ms and its diagnostics under the
# given tag. Answers whether a binary came out.
build_class() {
    local out="$1" tag="$2"
    shift 2
    local t0 t1 status
    t0=$(gdate +%s%N)
    timeout "$BUILD_BOUND" "$onez" build "$driver" -o "$out" "$@" >"$work/$tag.log" 2>&1
    status=$?
    t1=$(gdate +%s%N)
    build_ms=$(( (t1 - t0) / 1000000 ))
    [ "$status" -eq 0 ] && chmod +x "$out"
    return $status
}

# The interpreted row is both the first row and the reference every other mode is
# compared against, so it runs before anything else.
measure interpreted "$onez" run --compile=off "$driver" "${files[@]}"
measure hybrid "$onez" run --compile=hybrid "$driver" "${files[@]}"
measure eager "$onez" run --compile=eager "$driver" "${files[@]}"

build_class "$aot_bin" runtime-image --emit-runtime-image
image_built=$?
image_build_ms=$build_ms

build_class "$aot_locked_bin" locked --interpreter-fallback=false --lock-interpreter-setting
locked_built=$?
locked_build_ms=$build_ms

[ "$image_built" -eq 0 ] && measure aot-runtime-image "$aot_bin" "${files[@]}"
[ "$locked_built" -eq 0 ] && measure aot-locked "$aot_locked_bin" "${files[@]}"

echo "1z formatter across execution modes"
echo "binary=$onez   driver=$driver   reps=$REPS"
echo "files=${files[*]}"
echo ""

printf "%-18s %12s %12s %12s %12s\n" "mode" "median_ms" "min_ms" "max_ms" "vs interp"
printf "%-18s %12s %12s %12s %12s\n" "------------------" "------------" "------------" "------------" "------------"

baseline=""
for row in "${rows[@]}"; do
    IFS='|' read -r label a b c <<<"$row"
    if [ "$a" = "FAILED" ]; then
        printf "%-18s %12s %12s %12s %12s\n" "$label" "FAILED" "$b" "--" "--"
        continue
    fi
    [ -z "$baseline" ] && baseline="$a"
    printf "%-18s %12s %12s %12s %12s\n" "$label" \
        "$(ns_to_ms "$a")" "$(ns_to_ms "$b")" "$(ns_to_ms "$c")" \
        "$(awk -v base="$baseline" -v m="$a" 'BEGIN { printf "%.2fx", base / m }')"
done

echo ""
if [ "$image_built" -eq 0 ]; then
    echo "runtime-image build: ${image_build_ms}ms"
else
    echo "runtime-image build: REJECTED"
    sed -n '1,40p' "$work/runtime-image.log" | sed 's/^/  /'
fi
if [ "$locked_built" -eq 0 ]; then
    echo "locked build: ${locked_build_ms}ms"
else
    echo "locked build: REJECTED"
    sed -n '1,40p' "$work/locked.log" | sed 's/^/  /'
fi

for row in "${rows[@]}"; do
    IFS='|' read -r label a b c <<<"$row"
    [ "$a" = "FAILED" ] || continue
    echo ""
    echo "$label: $b"
    sed -n '1,12p' "$work/$label.why" | sed 's/^/  /'
done
