#!/usr/bin/env bash
#
# Loop-combinator per-iteration cost table.
#
# Usage: scripts/benchmark-loop-paths.sh [1z-binary] [reps] [iterations] [probe-filter]
#
# Every loop below `times` recurses through the prelude `loop`, so its recursion
# step is paid once per iteration by `loop`, `while`, and `until` alike. The
# prelude rows count to N through each combinator; their bodies differ by the
# predicate each combinator needs, so those rows compare combinators, not
# recursion steps. The user rows run the candidate spellings of `loop`'s
# recursion step as user words under `loop`'s own annotation, so they differ
# only in the body.
#
# Every probe runs `reps` times at N iterations, and once at zero. The time
# figure is the median user_ns delta over the zero run, divided by N; the
# allocation figure is the exact allocation-count delta over the zero run,
# divided by N. The zero run cancels prelude load and the probe's own parse.
#
# Run from the repository root. Build the binary with `make release` for
# representative numbers.

set -euo pipefail
shopt -s inherit_errexit

onez="${1:-./zig-out/bin/1z}"
reps="${2:-5}"
iterations="${3:-5000000}"
filter="${4:-}"

# The user startup file would add arbitrary load work to every run.
export ONEZ_NO_STARTUP=1

# "label|definition|driver". The driver's %N% is replaced with the iteration
# count. A prelude row has an empty definition.
effect="( ... pred: ( ... -- ... ? ) -- ... )"
driver="0 [ 1 + dup %N% < ] myloop drop"
probes=(
    "prelude/times||0 %N% [ 1 + ] times drop"
    "prelude/loop||0 [ 1 + dup %N% < ] loop drop"
    "prelude/while||0 [ dup %N% < ] [ 1 + ] while drop"
    "prelude/until||0 [ dup %N% >= ] [ 1 + ] until drop"
    "user/shipped|myloop: $effect [ [ call ] keep [ myloop ] curry when ] ;|$driver"
    "user/settled|myloop: $effect [ dup [ call ] dip swap [ myloop ] [ drop ] if ] ;|$driver"
    "user/keep-form|myloop: $effect [ [ call ] keep swap [ myloop ] [ drop ] if ] ;|$driver"
    "user/1check-form|myloop: $effect [ [ call ] 1check [ myloop ] [ drop ] if ] ;|$driver"
)

work="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

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

write_probe() {
    local definition="$1" driver="$2" n="$3"
    printf '%s\n%s\n' "$definition" "${driver//%N%/$n}" > "$work/probe.1z"
}

# One run's "user_ns allocations" pair, from the JSON report's last line.
run_probe() {
    local output json
    output=$("$onez" run --compile=off --stdlib-path=lib --benchmark=json "$work/probe.1z" 2>/dev/null)
    json=$(printf '%s\n' "$output" | tail -1)
    printf '%s\n' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['timing']['user_ns'], d['memory']['allocations'])"
}

per_iter_ns() { awk -v full="$1" -v base="$2" -v n="$3" 'BEGIN { printf "%.0f", (full - base) / n }'; }
per_iter_allocs() { awk -v full="$1" -v base="$2" -v n="$3" 'BEGIN { printf "%.2f", (full - base) / n }'; }

declare -A ns_by_label allocs_by_label

echo "Loop-combinator per-iteration cost"
echo "binary=$onez   reps=$reps   iterations=$iterations   mode=--compile=off"
echo ""

printf "%-20s %14s %20s %16s\n" "probe" "ns/iteration" "(min-max)" "allocs/iteration"
printf "%-20s %14s %20s %16s\n" "--------------------" "--------------" \
    "--------------------" "----------------"

for entry in "${probes[@]}"; do
    label="${entry%%|*}"
    rest="${entry#*|}"
    definition="${rest%%|*}"
    driver="${rest#*|}"

    if [ -n "$filter" ] && [[ "$label" != *"$filter"* ]]; then
        continue
    fi

    # A bare assignment propagates a failed probe run under errexit, where
    # feeding the command substitution straight into `read` would discard it.
    write_probe "$definition" "$driver" 0
    pair="$(run_probe)"
    read -r base_ns base_allocs <<< "$pair"

    write_probe "$definition" "$driver" "$iterations"
    ns_samples=()
    alloc_samples=()
    for _ in $(seq 1 "$reps"); do
        pair="$(run_probe)"
        read -r run_ns run_allocs <<< "$pair"
        ns_samples+=("$run_ns")
        alloc_samples+=("$run_allocs")
    done

    ns_iter=$(per_iter_ns "$(median "${ns_samples[@]}")" "$base_ns" "$iterations")
    ns_lo=$(per_iter_ns "$(min "${ns_samples[@]}")" "$base_ns" "$iterations")
    ns_hi=$(per_iter_ns "$(max "${ns_samples[@]}")" "$base_ns" "$iterations")
    allocs_iter=$(per_iter_allocs "$(median "${alloc_samples[@]}")" "$base_allocs" "$iterations")

    ns_by_label[$label]="$ns_iter"
    allocs_by_label[$label]="$allocs_iter"

    printf "%-20s %14s %20s %16s\n" \
        "$label" "$ns_iter" "($ns_lo-$ns_hi)" "$allocs_iter"
done

# The pinned delta: what the settled body saves over the shipped one. The two
# rows share a driver, so the difference is the recursion step alone.
pair_delta() {
    local name="$1" left="$2" right="$3"
    if [ -n "${ns_by_label[$left]:-}" ] && [ -n "${ns_by_label[$right]:-}" ]; then
        printf "  %-26s %6s ns/iteration   %s allocs/iteration\n" \
            "$name" \
            "$(( ns_by_label[$left] - ns_by_label[$right] ))" \
            "$(awk -v a="${allocs_by_label[$left]}" -v b="${allocs_by_label[$right]}" 'BEGIN { printf "%.2f", a - b }')"
    fi
}

echo ""
echo "delta:"
pair_delta "shipped over settled" "user/shipped" "user/settled"
