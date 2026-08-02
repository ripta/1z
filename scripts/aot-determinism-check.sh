#!/usr/bin/env bash
#
# Verify that two runs of the AOT compiler on the same source emit byte-identical
# C. Builds each corpus file twice with --save-temps and diffs the emitted C, in
# both metadata-only and runtime-image modes. The comparison stops at the C: the
# image tables are emitted as C arrays, so the C diff covers them, and a
# linked-binary compare would test the C toolchain's own determinism.
#
# The lint driver's metadata-only leg builds with --interpreter-fallback=false,
# the same flag the lint_driver_free AOT fixture uses. Under the default flags
# that build is a designed fail-clean rejection, because interpreted quotations
# would reach empty-bodied metadata-image words, and no C is emitted.
#
# Usage: scripts/aot-determinism-check.sh <1z-binary>

set -uo pipefail

onez="$1"

workdir="$(mktemp -d)"
if [ -z "$workdir" ]; then
    echo "FAIL: mktemp -d failed"
    exit 1
fi
trap 'rm -rf "$workdir"' EXIT

# build_once <leg> <run> <file> [extra-flags...]
#
# Runs one build, requires it to succeed, and moves the saved C (the first
# `Saved:` stderr line) to a stable per-run name. The saved object (the second
# `Saved:` line) is deleted so the PID-named temps never accumulate.
build_once() {
    local leg="$1" run="$2" file="$3"
    shift 3

    local stderr_file="$workdir/stderr"
    if ! "$onez" build --save-temps --stdlib-path=lib "$@" "$file" -o "$workdir/bin" 2>"$stderr_file"; then
        echo "FAIL: $leg run $run: build failed for $file"
        cat "$stderr_file"
        exit 1
    fi

    local saved_c saved_o
    saved_c="$(grep -m1 '^Saved: ' "$stderr_file" | sed 's/^Saved: //')"
    saved_o="$(grep '^Saved: ' "$stderr_file" | sed -n '2s/^Saved: //p')"
    if [ -z "$saved_c" ]; then
        echo "FAIL: $leg run $run: build reported no saved C file (missing --save-temps output)"
        cat "$stderr_file"
        exit 1
    fi

    mv "$saved_c" "$workdir/$leg-$run.c"
    rm -f "$saved_o" "$workdir/bin"
}

# check_leg <leg> <file> [extra-flags...]
check_leg() {
    local leg="$1" file="$2"
    shift 2

    build_once "$leg" 1 "$file" "$@"
    build_once "$leg" 2 "$file" "$@"

    if ! cmp -s "$workdir/$leg-1.c" "$workdir/$leg-2.c"; then
        echo "FAIL: $leg: two builds of $file emitted different C"
        diff "$workdir/$leg-1.c" "$workdir/$leg-2.c" | head -40
        exit 1
    fi
}

check_leg loop-combinators-metadata tests/aot/aot_loop_combinators.1z
check_leg loop-combinators-image tests/aot/aot_loop_combinators.1z --emit-runtime-image
check_leg lint-driver-metadata tests/benchmark/lint_bench.1z --interpreter-fallback=false
check_leg lint-driver-image tests/benchmark/lint_bench.1z --emit-runtime-image

echo "PASS: double builds emit byte-identical C (loop-combinators and lint driver, metadata-only and runtime-image)"
