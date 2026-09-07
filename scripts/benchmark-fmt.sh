#!/usr/bin/env bash
#
# Benchmark the 1z formatter against the Zig formatter.
#
# Usage: scripts/benchmark-fmt.sh <1z-binary> <file|@tree>...
#
# For each file, times both engines of `1z fmt --stdout` and reports the cost of
# one run in milliseconds plus the ratio between them. The Zig formatter is well
# below the clock's resolution on a single file, so each engine formats its file
# a set number of times inside one process and the total is divided down.
#
# `@tree` stands for every `.1z` file in the repository, the set `make fmt`
# rewrites, formatted in one process per engine. That row is the one the
# replacement decision rests on.
#
# The comparison also diffs the two engines' output, so the sample records that
# they agree on real sources rather than only on the tests/formatting corpus.

set -uo pipefail

onez="$1"
shift

# Runs per engine. The clock reports hundredths of a second, so the Zig side needs
# enough passes to land around a second. A single 1z pass already dwarfs that.
ZIG_REPS="${ZIG_REPS:-2000}"
ONEZ_REPS="${ONEZ_REPS:-1}"

# Seconds the 1z engine gets before it is cut off.
FMT_BOUND="${FMT_BOUND:-600}"

tree_files() {
    find . \( -path './.zig-cache' -o -path './zig-out' \) -prune -o -name '*.1z' -print
}

# Wall-clock seconds for one command, from `/usr/bin/time -l`. A run whose report
# has no `real` line reads as zero, which the caller treats as below the clock.
elapsed() {
    local tmp seconds
    tmp="$(mktemp)"
    ONEZ_STDLIB=lib /usr/bin/time -l "$@" >/dev/null 2>"$tmp"
    seconds="$(grep -E ' real ' "$tmp" | head -1 | awk '{ print $1 }')"
    rm -f "$tmp"
    printf '%s' "${seconds:-0.00}"
}

measurable() {
    awk -v t="$1" 'BEGIN { exit !(t + 0 > 0) }'
}

# One engine's per-run cost in milliseconds, given its total and its run count.
per_run_ms() {
    awk -v total="$1" -v reps="$2" 'BEGIN { printf "%.2f", total * 1000 / reps }'
}

# Fill REPEATED with the given files listed count times over.
repeat_into() {
    local count="$1"
    shift
    local i file
    REPEATED=()
    for ((i = 0; i < count; i++)); do
        for file in "$@"; do
            REPEATED+=("$file")
        done
    done
}

report_engine() {
    local label="$1" total="$2" reps="$3"
    if measurable "$total"; then
        printf '  %-22s %11s ms/run (%sx, %s s total)\n' "$label" "$(per_run_ms "$total" "$reps")" "$reps" "$total"
    else
        printf '  %-22s %14s (%sx, under 0.01 s total)\n' "$label" "below the clock" "$reps"
    fi
}

bench_one() {
    local label="$1" compare="$2"
    shift 2
    local files=("$@")

    local bytes lines
    bytes="$(cat "${files[@]}" | wc -c | tr -d ' ')"
    lines="$(cat "${files[@]}" | wc -l | tr -d ' ')"
    echo "=== $label (${#files[@]} files, $lines lines, $bytes bytes) ==="

    repeat_into "$ZIG_REPS" "${files[@]}"
    local zig_total
    zig_total="$(elapsed "$onez" fmt --stdout "${REPEATED[@]}")"

    repeat_into "$ONEZ_REPS" "${files[@]}"
    local onez_total
    onez_total="$(elapsed timeout "$FMT_BOUND" "$onez" fmt --engine=1z --stdout "${REPEATED[@]}")"

    report_engine "zig formatter" "$zig_total" "$ZIG_REPS"
    report_engine "1z formatter" "$onez_total" "$ONEZ_REPS"

    if measurable "$zig_total"; then
        local zig_ms onez_ms
        zig_ms="$(per_run_ms "$zig_total" "$ZIG_REPS")"
        onez_ms="$(per_run_ms "$onez_total" "$ONEZ_REPS")"
        printf '  %-22s %14s\n' "1z / zig" "$(awk -v a="$onez_ms" -v z="$zig_ms" 'BEGIN { printf "%.0fx", a / z }')"
    else
        printf '  %-22s %14s\n' "1z / zig" "n/a"
    fi

    if [ "$compare" != "compare" ]; then
        printf '  %-22s %14s\n' "output" "not compared"
        return
    fi

    local zig_out onez_out
    zig_out="$(mktemp)"
    onez_out="$(mktemp)"
    "$onez" fmt --stdout "${files[@]}" >"$zig_out" 2>/dev/null
    ONEZ_STDLIB=lib timeout "$FMT_BOUND" "$onez" fmt --engine=1z --stdout "${files[@]}" >"$onez_out" 2>/dev/null
    if cmp -s "$zig_out" "$onez_out"; then
        printf '  %-22s %14s\n' "output" "identical"
    else
        printf '  %-22s %14s\n' "output" "DIFFERS"
    fi
    rm -f "$zig_out" "$onez_out"
}

for arg in "$@"; do
    if [ "$arg" = "@tree" ]; then
        all_files=()
        while IFS= read -r file; do
            all_files+=("$file")
        done < <(tree_files)
        # The tree holds `tests/fixtures/fmt/nested/.fmt.1z`, whose own directory
        # configures an eight-space indent. Only the 1z engine reads it, so the two
        # engines disagree there by design and the output column is left off.
        # Five passes, not the per-file count: the whole tree repeated much further
        # overruns the argument-list limit.
        ZIG_REPS="${TREE_ZIG_REPS:-5}" ONEZ_REPS=1 bench_one "every .1z file" no-compare "${all_files[@]}"
    else
        bench_one "$arg" compare "$arg"
    fi
done
