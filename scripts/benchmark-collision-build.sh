#!/usr/bin/env bash
#
# Record the AOT build cost of the shipped stdlib collision pairs. Each driver
# `use`s both modules of one same-named-export pair, so the build compiles both
# colliding bodies instead of one bare-name winner.
#
# Usage: scripts/benchmark-collision-build.sh <1z-binary>
#
# Builds each driver in metadata-only and runtime-image mode, printing build
# wall time and artifact size. A pair that does not build records its punch
# list instead of numbers: tcp+tls hits the row-variable codegen limit on two
# net words, and sqlite+lua is blocked on ffi-def{-generated words carrying no
# stack effect declarations.

set -uo pipefail

onez="$1"

build_one() {
    local label="$1" mode_flag="$2" file="$3"
    local out tmp
    out="$(mktemp)"
    tmp="$(mktemp)"
    if /usr/bin/time -l "$onez" build $mode_flag --allow-interpreter-fallback --stdlib-path=lib "$file" -o "$out" >/dev/null 2>"$tmp"; then
        local real size
        real="$(grep -E ' real ' "$tmp" | head -1 | sed 's/^ *//')"
        size="$(stat -f %z "$out")"
        printf '  %-16s %s bytes  %s\n' "$label" "$size" "$real"
    else
        printf '  %-16s build rejected:\n' "$label"
        grep -E "^Error|^  word" "$tmp" | sed 's/^/    /'
    fi
    rm -f "$out" "$tmp"
}

for file in tests/benchmark/collision_url_base64.1z tests/benchmark/collision_tcp_tls.1z tests/benchmark/collision_sqlite_lua.1z; do
    echo "=== $file ==="
    build_one "metadata-only" "" "$file"
    build_one "runtime-image" "--emit-runtime-image" "$file"
done
