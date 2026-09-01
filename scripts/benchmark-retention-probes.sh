#!/usr/bin/env bash
#
# Transient-value retention probe table.
#
# Usage: scripts/benchmark-retention-probes.sh [1z-binary] [iterations]
#
# Runs each one-line probe as `N [ <body> ] times` and reports two figures per
# probe: the interpreter's own tracked peak live bytes, from --benchmark=json,
# and the process's peak resident set size, from /usr/bin/time. The tracked
# counter is the one the memory limit enforces and is deterministic; RSS is
# noisier, because it also carries arena chunk doubling and page retention, but
# it is the figure the original probe table recorded.
#
# Every probe is measured twice, at N iterations and at zero, and reported as
# the difference. That cancels whatever the probe costs to reach the loop --
# prelude load, and for a probe that imports a module, the module load too --
# leaving only what the loop itself retains. A reclaimed class reports a delta
# near zero; a retained one grows in proportion to N.
#
# Every probe runs with the memory cap raised, so a binary that does not reclaim
# still completes and reports a number instead of aborting.
#
# Run from the repository root. Build the binary with `make release` for
# representative numbers.

set -euo pipefail

onez="${1:-./zig-out/bin/1z}"
iterations="${2:-500000}"

# "label|preamble|body". The rows follow the retention classes: a non-allocating
# control, scratch buffers, string results, virtual wraps, bignums, and closures.
probes=(
    "1 2 + drop||1 2 + drop"
    "H{ } @set drop||H{ } a: 1 @set b: 2 @set drop"
    "{ } #append drop||{ 1 2 3 4 } { } #append drop"
    ">string drop||123456789 >string drop"
    "string #append drop||\"hello, \" \"world\" #append drop"
    "array #append drop||{ 1 2 3 4 } { 5 6 7 8 } #append drop"
    "#map #collect drop||{ 1 2 3 4 } [ 2 * ] #map #collect drop"
    ">symbol drop||\"some-symbol-name\" >symbol drop"
    ">duration drop|use \"time\" ;|42 >duration drop"
    "bignum + drop||99999999999999999999999 12345 + drop"
    "curry drop||2 [ * ] curry drop"
    "curry call||1 [ drop ] curry call"
    "loop||0 [ 1 + dup 10 < ] loop drop"
    "compose call||x: 5 ; [ x ] [ drop ] compose call"
)

work="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

write_probe() {
    local preamble="$1" n="$2" body="$3"
    printf '%s\n%s [ %s ] times\n' "$preamble" "$n" "$body" > "$work/probe.1z"
}

# Tracked peak live bytes, from the benchmark report's JSON.
tracked_peak() {
    local output json
    output=$("$onez" run --compile=off --stdlib-path=lib --max-memory=2G --benchmark=json "$work/probe.1z" 2>/dev/null)
    json=$(printf '%s\n' "$output" | tail -1)
    printf '%s\n' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['memory']['peak_live_bytes'])"
}

# Peak resident set size in bytes. macOS `time -l` reports bytes; GNU `time -v`
# reports kilobytes.
rss_peak() {
    local err="$work/time.err"
    /usr/bin/time -l "$onez" run --compile=off --stdlib-path=lib --max-memory=2G "$work/probe.1z" >/dev/null 2>"$err" ||
        /usr/bin/time -v "$onez" run --compile=off --stdlib-path=lib --max-memory=2G "$work/probe.1z" >/dev/null 2>"$err"
    if grep -q 'maximum resident set size' "$err"; then
        grep 'maximum resident set size' "$err" | awk '{print $1}'
    else
        grep 'Maximum resident set size' "$err" | awk '{print $NF * 1024}'
    fi
}

mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576.0 }'; }
per_iter() { awk -v d="$1" -v n="$2" 'BEGIN { printf "%.0f", d / n }'; }

echo "Transient-value retention probes"
echo "binary=$onez   iterations=$iterations   mode=--compile=off"
echo ""

printf "%-24s %12s %10s %12s\n" "probe" "tracked_MB" "bytes/it" "rss_MB"
printf "%-24s %12s %10s %12s\n" \
    "------------------------" "------------" "----------" "------------"

for entry in "${probes[@]}"; do
    label="${entry%%|*}"
    rest="${entry#*|}"
    preamble="${rest%%|*}"
    body="${rest#*|}"

    write_probe "$preamble" 0 "$body"
    base_tracked="$(tracked_peak)"
    base_rss="$(rss_peak)"

    write_probe "$preamble" "$iterations" "$body"
    full_tracked="$(tracked_peak)"
    full_rss="$(rss_peak)"

    tracked_delta=$(( full_tracked - base_tracked ))
    rss_delta=$(( full_rss - base_rss ))

    printf "%-24s %12s %10s %12s\n" \
        "$label" "$(mb "$tracked_delta")" \
        "$(per_iter "$tracked_delta" "$iterations")" "$(mb "$rss_delta")"
done
