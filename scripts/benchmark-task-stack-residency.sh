#!/usr/bin/env bash
#
# Task stack residency and mapping count.
#
# Usage: scripts/benchmark-task-stack-residency.sh [1z-binary] [baseline-binary]
#
# Runs tests/benchmark/task_stack_residency.1z in each mode and samples the process while its
# children are parked: resident set size, physical footprint, the number of memory mappings, and the
# peak. Each mode runs at N tasks and at zero, and the first three figures are reported per task as
# the difference, which cancels startup and prelude.
#
# The peak is the process's own high-water mark, the physical footprint peak on macOS and VmHWM on
# Linux. A mode that goes deep and then releases still shows how high it went.
#
# On macOS the release advises MADV_FREE_REUSABLE, which leaves pages counted in RSS until the
# system wants them back. Physical footprint stops counting them at once, so it is the figure that
# shows a release there. Linux advises MADV_DONTNEED, and the two figures agree.
#
# The baseline binary, when given, runs the idle mode only. It is a build without task stack growth,
# so it has no deep, released, regrown, or runaway behavior to compare against.
#
# Run from the repository root. Build the binary with `make release` for representative numbers.

set -euo pipefail

onez="${1:-./zig-out/release/bin/1z}"
baseline="${2:-}"
probe="tests/benchmark/task_stack_residency.1z"

# "mode|n|depth". The depth of 100 is about 2.6 MiB of interpreted stack, well inside the 16 MiB cap.
rows=(
    "idle|1000|0"
    "deep|32|100"
    "released|32|100"
    "regrown|32|100"
    "runaway|8|0"
)

work="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }

# The probe still running when the script bails out is stopped rather than left behind.
probe_pid=""
cleanup() {
    if [ -n "$probe_pid" ]; then
        kill "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

os="$(uname -s)"

# Converts a vmmap size such as 812K, 12.3M, or 1.1G on stdin to KiB.
to_kib() {
    awk '{
        v = $1; u = substr(v, length(v)); n = substr(v, 1, length(v) - 1)
        if (u == "K") print n
        else if (u == "M") printf "%.0f\n", n * 1024
        else if (u == "G") printf "%.0f\n", n * 1048576
        else printf "%.0f\n", v / 1024
    }'
}

# Sets rss_kib, footprint_kib, mappings, and peak_kib for a live PID.
sample() {
    local pid="$1"

    if [ "$os" = "Darwin" ]; then
        if ! rss_kib=$(ps -o rss= -p "$pid"); then
            echo "probe $pid exited before it was sampled" >&2
            exit 1
        fi
        rss_kib="${rss_kib// /}"

        local summary="$work/vmmap.txt"
        if ! vmmap -summary "$pid" >"$summary" 2>"$work/vmmap.err"; then
            echo "vmmap failed on $pid:" >&2
            cat "$work/vmmap.err" >&2
            exit 1
        fi

        footprint_kib=$(awk '/^Physical footprint:/ { print $3 }' "$summary" | to_kib)
        peak_kib=$(awk '/^Physical footprint \(peak\):/ { print $4 }' "$summary" | to_kib)
        mappings=$(awk '/^TOTAL[ ]/ { print $NF; exit }' "$summary")
    else
        rss_kib=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status")
        footprint_kib="$rss_kib"
        peak_kib=$(awk '/^VmHWM:/ { print $2 }' "/proc/$pid/status")
        mappings=$(wc -l <"/proc/$pid/maps" | tr -d ' ')
    fi

    # A reporting format the parsers above no longer match would otherwise read as zero.
    if [ -z "$rss_kib" ] || [ -z "$footprint_kib" ] || [ -z "$peak_kib" ] || [ -z "$mappings" ]; then
        echo "could not read rss=$rss_kib footprint=$footprint_kib peak=$peak_kib mappings=$mappings for $pid" >&2
        exit 1
    fi
}

# Runs one probe and samples it once every child has reported reaching its park.
measure() {
    local bin="$1" mode="$2" n="$3" depth="$4"
    local out="$work/out.txt" err="$work/err.txt"
    : >"$out"

    "$bin" run --compile=off --stdlib-path=lib "$probe" "$mode" "$n" "$depth" >"$out" 2>"$err" &
    probe_pid=$!

    local tries=0
    until grep -q '^ready$' "$out"; do
        tries=$((tries + 1))
        if [ "$tries" -gt 1000 ]; then
            echo "probe never reported ready: $mode $n" >&2
            cat "$err" >&2
            exit 1
        fi
        sleep 0.01
    done

    sample "$probe_pid"

    local pid="$probe_pid"
    probe_pid=""
    if ! wait "$pid"; then
        echo "probe failed: $mode $n" >&2
        cat "$err" >&2
        exit 1
    fi
}

per_task() { awk -v a="$1" -v b="$2" -v n="$3" 'BEGIN { printf "%.1f", (a - b) / n }'; }
mib() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1024.0 }'; }

report() {
    local label="$1" bin="$2" mode="$3" n="$4" depth="$5"

    measure "$bin" "$mode" 0 "$depth"
    local rss0="$rss_kib" fp0="$footprint_kib" map0="$mappings" peak0="$peak_kib"

    measure "$bin" "$mode" "$n" "$depth"

    printf "%-10s %-9s %6s %14s %16s %14s %10s %10s\n" \
        "$label" "$mode" "$n" \
        "$(per_task "$rss_kib" "$rss0" "$n")" \
        "$(per_task "$footprint_kib" "$fp0" "$n")" \
        "$(per_task "$mappings" "$map0" "$n")" \
        "$(mib "$peak0")" "$(mib "$peak_kib")"
}

echo "Task stack residency"
echo "binary=$onez   baseline=${baseline:-none}   os=$os   mode=--compile=off"
echo ""

printf "%-10s %-9s %6s %14s %16s %14s %10s %10s\n" \
    "build" "mode" "n" "rss_KiB/task" "footprint_KiB/t" "mappings/task" "peak0_MiB" "peak_MiB"
printf "%-10s %-9s %6s %14s %16s %14s %10s %10s\n" \
    "----------" "---------" "------" "--------------" "----------------" "--------------" \
    "----------" "----------"

if [ -n "$baseline" ]; then
    report "baseline" "$baseline" idle 1000 0
fi

for entry in "${rows[@]}"; do
    IFS='|' read -r mode n depth <<<"$entry"
    report "candidate" "$onez" "$mode" "$n" "$depth"
done
