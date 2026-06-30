#!/usr/bin/env bash
#
# Measure the same-type branch-merge select optimization before/after.
#
# Usage: scripts/benchmark-merge-select.sh <1z-binary> <benchmark-file> [reps]
#
# Runs the benchmark in --compile=eager mode `reps` times with the select off
# (ONEZ_PROTOTYPE_COND_SELECT unset, the boxed merge) and on (the branchless
# IR_COND select), takes the median elapsed-ns per measured word, and prints the
# percentage improvement. The benchmark file prints lines of the form
# "<label> ns=<n>" and "<label> <checksum-name>=<v>"; the checksum lines are
# compared across off/on to confirm the select computes identical results.
#
# NOTE: the off/on comparison only differs when the supplied <1z-binary> was
# built with the env-gated IR_COND prototype that reads ONEZ_PROTOTYPE_COND_SELECT
# in emitIntrinsicIf (src/ir_codegen.zig). That prototype was scratch for the
# gating measurement and was reverted afterward, so against a stock build the env
# var is inert and both columns are identical. Reäpply the prototype to use this
# harness. Build the binary with `make release` for representative numbers.

set -euo pipefail

onez="$1"
benchmark="$2"
reps="${3:-5}"

# median of the integers passed as args
median() {
    local sorted
    sorted=$(printf '%s\n' "$@" | sort -n)
    local n=$#
    local mid=$(( (n + 1) / 2 ))
    printf '%s\n' "$sorted" | sed -n "${mid}p"
}

# Run the benchmark once and emit "label ns" pairs; capture checksum lines too.
run_once() {
    local on="$1"
    if [ "$on" = on ]; then
        ONEZ_PROTOTYPE_COND_SELECT=1 "$onez" run --compile=eager "$benchmark"
    else
        "$onez" run --compile=eager "$benchmark"
    fi
}

declare -A off_ns on_ns labels checks_off checks_on

collect() {
    local on="$1" rep="$2"
    while read -r label rest; do
        case "$rest" in
            ns=*)
                local v="${rest#ns=}"
                labels["$label"]=1
                if [ "$on" = on ]; then
                    on_ns["$label"]="${on_ns[$label]:-} $v"
                else
                    off_ns["$label"]="${off_ns[$label]:-} $v"
                fi
                ;;
            *=*)
                if [ "$on" = on ]; then
                    checks_on["$label"]="$rest"
                else
                    checks_off["$label"]="$rest"
                fi
                ;;
        esac
    done < <(run_once "$on")
}

echo "Benchmark: $benchmark   reps=$reps   binary=$onez"
echo ""

for rep in $(seq 1 "$reps"); do
    collect off "$rep"
    collect on "$rep"
done

printf "%-16s %14s %14s %9s   %s\n" "word" "off_ns(med)" "on_ns(med)" "delta" "checksum off==on"
printf "%-16s %14s %14s %9s   %s\n" "----------------" "--------------" "--------------" "---------" "----------------"

for label in $(printf '%s\n' "${!labels[@]}" | sort); do
    # shellcheck disable=SC2086
    om=$(median ${off_ns[$label]})
    # shellcheck disable=SC2086
    nm=$(median ${on_ns[$label]})
    delta=$(awk -v o="$om" -v n="$nm" 'BEGIN { if (o>0) printf "%+.1f%%", (o-n)*100.0/o; else printf "n/a" }')
    if [ "${checks_off[$label]:-}" = "${checks_on[$label]:-}" ]; then
        ok="yes (${checks_off[$label]:-?})"
    else
        ok="NO (${checks_off[$label]:-?} vs ${checks_on[$label]:-?})"
    fi
    printf "%-16s %14s %14s %9s   %s\n" "$label" "$om" "$nm" "$delta" "$ok"
done
