#!/usr/bin/env bash
#
# Annotated-quotation-parameter per-call cost table.
#
# Usage: scripts/benchmark-param-effects.sh [1z-binary] [reps] [iterations] [probe-filter]
#
# A word whose stack effect annotates a quotation parameter re-infers that
# argument's stack delta on every call, allocating a shadow stack and doing a
# locked dictionary lookup per call_word to do it. Each probe here is a small
# self-recursive loop word run over a counting workload; the probes differ only
# in the declared effect, so the annotated-minus-unannotated delta is what the
# annotation costs per call. The balanced probes mirror the prelude `loop`'s
# annotation and the unbalanced ones mirror `keep`'s, whose row variables
# differ between the quotation's inputs and outputs.
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
# count. The settled and keep-form bodies are the two candidate rewrites of
# the prelude `loop`'s recursion step, one spelling out `keep`'s shuffle and
# one keeping the `keep` call. The unbalanced word is `keep`'s own body under
# `keep`'s own annotation.
#
# The unbalanced driver is a self-recursive counting word rather than `times`.
# `times` runs its body through `2dip`, whose annotated quot parameter
# re-validates the driver body every iteration, and that inference walks
# differently depending on whether `mykeep` declares an effect. A driver with
# no annotated word anywhere keeps the pair delta down to mykeep's own
# validation.
probes=(
    "settled/annotated|myloop: ( ... pred: ( ... -- ... ? ) -- ... ) [ dup [ call ] dip swap [ myloop ] [ drop ] if ] ;|0 [ 1 + dup %N% < ] myloop drop"
    "settled/plain-effect|myloop: ( ... pred -- ... ) [ dup [ call ] dip swap [ myloop ] [ drop ] if ] ;|0 [ 1 + dup %N% < ] myloop drop"
    "settled/no-effect|myloop: [ dup [ call ] dip swap [ myloop ] [ drop ] if ] ;|0 [ 1 + dup %N% < ] myloop drop"
    "keep-form/annotated|myloop: ( ... pred: ( ... -- ... ? ) -- ... ) [ [ call ] keep swap [ myloop ] [ drop ] if ] ;|0 [ 1 + dup %N% < ] myloop drop"
    "keep-form/no-effect|myloop: [ [ call ] keep swap [ myloop ] [ drop ] if ] ;|0 [ 1 + dup %N% < ] myloop drop"
    "unbalanced/annotated|mykeep: ( ..a x quot: ( ..a x -- ..b ) -- ..b x ) [ over [ call ] dip ] ;|run: [ dup 0 > [ 1 [ dup * drop ] mykeep drop 1 - run ] [ drop ] if ] ; %N% run"
    "unbalanced/no-effect|mykeep: [ over [ call ] dip ] ;|run: [ dup 0 > [ 1 [ dup * drop ] mykeep drop 1 - run ] [ drop ] if ] ; %N% run"
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

per_call_ns() { awk -v full="$1" -v base="$2" -v n="$3" 'BEGIN { printf "%.0f", (full - base) / n }'; }
per_call_allocs() { awk -v full="$1" -v base="$2" -v n="$3" 'BEGIN { printf "%.2f", (full - base) / n }'; }

declare -A ns_by_label allocs_by_label

echo "Annotated-quotation-parameter per-call cost"
echo "binary=$onez   reps=$reps   iterations=$iterations   mode=--compile=off"
echo ""

printf "%-24s %10s %20s %12s\n" "probe" "ns/call" "(min-max)" "allocs/call"
printf "%-24s %10s %20s %12s\n" "------------------------" "----------" \
    "--------------------" "------------"

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

    ns_call=$(per_call_ns "$(median "${ns_samples[@]}")" "$base_ns" "$iterations")
    ns_lo=$(per_call_ns "$(min "${ns_samples[@]}")" "$base_ns" "$iterations")
    ns_hi=$(per_call_ns "$(max "${ns_samples[@]}")" "$base_ns" "$iterations")
    allocs_call=$(per_call_allocs "$(median "${alloc_samples[@]}")" "$base_allocs" "$iterations")

    ns_by_label[$label]="$ns_call"
    allocs_by_label[$label]="$allocs_call"

    printf "%-24s %10s %20s %12s\n" \
        "$label" "$ns_call" "($ns_lo-$ns_hi)" "$allocs_call"
done

# The three pinned deltas, each annotated minus its no-effect control.
pair_delta() {
    local name="$1" annotated="$2" control="$3"
    if [ -n "${ns_by_label[$annotated]:-}" ] && [ -n "${ns_by_label[$control]:-}" ]; then
        printf "  %-14s %6s ns/call   %s allocs/call\n" \
            "$name" \
            "$(( ns_by_label[$annotated] - ns_by_label[$control] ))" \
            "$(awk -v a="${allocs_by_label[$annotated]}" -v b="${allocs_by_label[$control]}" 'BEGIN { printf "%.2f", a - b }')"
    fi
}

echo ""
echo "annotation cost (annotated - no-effect):"
pair_delta "settled body" "settled/annotated" "settled/no-effect"
pair_delta "keep-form" "keep-form/annotated" "keep-form/no-effect"
pair_delta "unbalanced" "unbalanced/annotated" "unbalanced/no-effect"
