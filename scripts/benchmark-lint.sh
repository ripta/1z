#!/usr/bin/env bash
#
# Benchmark the runtime-image AOT lint driver against interpreted `1z lint`.
#
# Usage: scripts/benchmark-lint.sh <1z-binary> <aot-driver> <file>...
#
# Times wall/user/sys for each file under the interpreter, then runs the
# runtime-image AOT binary under a bound. The AOT binary resolves a linted
# file's own `use` imports through ONEZ_STDLIB, mirroring the interpreter's
# stdlib path. The interpreter-free artifact class is reported separately in
# the written finding: it does not build (three row-variable lexer / lint words
# require an interpreter fallback).
#
# The runtime-image AOT lint is orders of magnitude slower than the interpreter
# -- the per-token lexer runs through the compiled<->interpreter boundary -- so
# the AOT run is bounded; the bound is the reported number.

set -uo pipefail

onez="$1"
aot="$2"
shift 2

AOT_BOUND="${AOT_BOUND:-90}"

# Run a command under /usr/bin/time -l and print its `real/user/sys` line.
time_one() {
    local label="$1"
    shift
    local tmp
    tmp="$(mktemp)"
    ONEZ_STDLIB=lib /usr/bin/time -l "$@" >/dev/null 2>"$tmp" || true
    printf '  %-24s %s\n' "$label" "$(grep -E ' real ' "$tmp" | head -1 | sed 's/^ *//')"
    rm -f "$tmp"
}

for file in "$@"; do
    echo "=== $file ($(wc -l < "$file" | tr -d ' ') lines) ==="
    time_one "interpreted 1z lint" "$onez" lint "$file"
    time_one "runtime-image AOT (<=${AOT_BOUND}s)" timeout "${AOT_BOUND}" "$aot" "$file"
done
