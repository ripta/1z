#!/usr/bin/env bash
#
# Time what a word that binds named locals costs, in every execution mode.
#
# Usage: scripts/benchmark-local-binding.sh <1z-binary> <aot-binary-path>
#
# tests/benchmark/local_binding.1z times itself with `benchmark` and prints one row per case, so
# this script takes no wall clock of its own. It runs the file interpreted, under both JIT modes,
# and out of the two AOT classes, and prints each mode's rows under a heading.
#
# A single run moves a row by a few hundred nanoseconds, which is the size of the gaps the file
# exists to measure. So each mode runs REPS times and each row reports its median.
#
# The file checks itself before it times anything. It prints a line when `bound-reads` and
# `shuffled` disagree, so a mode that computes differently shows up in its own rows. A mode that
# raises, or an AOT class that refuses to build, is reported in place of its rows.
#
# Build the binary with `make release` for representative numbers.

set -uo pipefail

onez="$1"
aot_bin="$2"

driver="tests/benchmark/local_binding.1z"

REPS="${REPS:-5}"
BUILD_BOUND="${BUILD_BOUND:-600}"
RUN_BOUND="${RUN_BOUND:-600}"

aot_free_bin="$aot_bin-free"
work="$(mktemp -d)"
cleanup() { rm -rf "$aot_bin" "$aot_free_bin" "$work"; }
trap cleanup EXIT

export ONEZ_STDLIB="${ONEZ_STDLIB:-lib}"

# Run one mode REPS times and print each row's median, or the reason the mode produced none.
report() {
    local label="$1"
    shift

    echo "$label"
    : >"$work/$label.out"
    for _ in $(seq 1 "$REPS"); do
        if ! timeout "$RUN_BOUND" "$@" >>"$work/$label.out" 2>"$work/$label.err"; then
            echo "  FAILED"
            sed -n '1,12p' "$work/$label.err" | sed 's/^/    /'
            echo ""
            return
        fi
    done

    # A row is `label  n=N  ns/iter=X`. Any other line is the file's own disagreement report.
    awk '
        $3 ~ /^ns\/iter=/ {
            if (!($1 in seen)) { seen[$1] = 1; order[++rows] = $1; n[$1] = $2 }
            v = $3
            sub(/^ns\/iter=/, "", v)
            samples[$1, ++count[$1]] = v + 0
            next
        }
        { print "  " $0 }
        END {
            for (r = 1; r <= rows; r++) {
                label = order[r]
                k = count[label]
                for (i = 1; i <= k; i++) sorted[i] = samples[label, i]
                for (i = 2; i <= k; i++) {
                    x = sorted[i]
                    for (j = i - 1; j >= 1 && sorted[j] > x; j--) sorted[j + 1] = sorted[j]
                    sorted[j + 1] = x
                }
                printf "  %-12s %-10s median_ns/iter=%d\n", label, n[label], sorted[int((k + 1) / 2)]
            }
        }
    ' "$work/$label.out"
    echo ""
}

# Build one AOT class. A rejected build prints its diagnostics in place of the rows.
build_and_report() {
    local label="$1" out="$2"
    shift 2

    if timeout "$BUILD_BOUND" "$onez" build "$driver" -o "$out" "$@" >"$work/$label.build" 2>&1; then
        chmod +x "$out"
        report "$label" "$out"
    else
        echo "$label"
        echo "  build REJECTED"
        sed -n '1,20p' "$work/$label.build" | sed 's/^/    /'
        echo ""
    fi
}

echo "Named-local binding cost across execution modes"
echo "binary=$onez   driver=$driver   reps=$REPS"
echo ""

report interpreted "$onez" run --compile=off "$driver"
report hybrid "$onez" run --compile=hybrid "$driver"
report eager "$onez" run --compile=eager "$driver"
build_and_report aot-runtime-image "$aot_bin" --emit-runtime-image
build_and_report aot-interpreter-free "$aot_free_bin" --interpreter-fallback=false
