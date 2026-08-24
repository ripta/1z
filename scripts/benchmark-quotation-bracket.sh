#!/usr/bin/env bash
#
# A/B what the transient lexical frame costs a flagged quotation body.
#
# Usage: scripts/benchmark-quotation-bracket.sh <1z-binary> <out-dir> <reps> <pair>...
#
# A pair is "label|bare-file|flagged-file". The two files differ in one word. The bare one reads a
# hash with `@has?` and the flagged one with `@get`. Only `@get` can install a word, through its
# module arm, so the may-define analysis brackets only the flagged body.
#
# Both natives pop the key and the receiver, extract the key string, and read the same map. One
# pushes the value and the other a boolean. So the lookup either side pays is the same, and the
# ratio is close to what the frame costs.
#
# Both halves of a pair run back to back within every rep, so a load spike or a thermal shift lands
# on both instead of on whichever half happened to run during it.
#
# An AOT binary has no --benchmark=json, so its runs are timed externally with gdate. Every other
# mode reads timing.user_ns out of the report, which excludes prelude load and JIT compilation.
#
# Build the 1z binary with `make build` to compare against the other quotation samples, which are
# recorded from a Debug build.

set -euo pipefail

# The timing helpers run inside command substitutions, which do not inherit errexit on their own.
# Without this a binary that crashes is timed as a fast success.
shopt -s inherit_errexit

if [ "$#" -lt 4 ]; then
    echo "usage: $0 <1z-binary> <out-dir> <reps> <pair>..." >&2
    echo "       a pair is \"label|bare-file|flagged-file\"" >&2
    exit 2
fi

onez="$1"
out_dir="$2"
reps="$3"
shift 3
pairs=("$@")

built=()
cleanup() {
    if [ "${#built[@]}" -gt 0 ]; then
        rm -f "${built[@]}"
    fi
}
trap cleanup EXIT

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

ns_to_ms() { awk -v ns="$1" 'BEGIN { printf "%.3f", ns / 1000000.0 }'; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b / a }'; }

# One side's cell: the median with its spread, as a single field so the column stays aligned under a
# fixed width.
cell() {
    printf '%s (%s-%s)' "$(ns_to_ms "$(median "$@")")" \
        "$(ns_to_ms "$(min "$@")")" "$(ns_to_ms "$(max "$@")")"
}

# A rejected build means there is no AOT row to report, and the AOT tier is the one the bracket was
# added for, so say so instead of printing half a table.
build_aot() {
    local src="$1" out="$2"
    if ! "$onez" build "$src" -o "$out" >/dev/null; then
        echo "FAIL: the AOT build of $src was rejected, so there is no binary to time" >&2
        exit 1
    fi
    chmod +x "$out"
    built+=("$out")
}

# timing.user_ns for one interpreter-mode run. The JSON report is the last line of stdout, after
# whatever the file printed.
run_user_ns() {
    local flag="$1" file="$2" output json
    output=$("$onez" run "$flag" --benchmark=json "$file" 2>/dev/null)
    json=$(printf '%s\n' "$output" | tail -1)
    printf '%s\n' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['timing']['user_ns'])"
}

# Wall-clock nanoseconds for one AOT binary run.
time_binary_ns() {
    local bin="$1" t0 t1
    t0=$(gdate +%s%N)
    "$bin" >/dev/null
    t1=$(gdate +%s%N)
    printf '%s\n' "$(( t1 - t0 ))"
}

echo "Quotation bracket A/B"
echo "binary=$onez   reps=$reps"
echo ""

printf "%-12s %-12s %28s %28s %10s\n" "path" "mode" "bare_ms" "flagged_ms" "flag/bare"
printf "%-12s %-12s %28s %28s %10s\n" "------------" "------------" \
    "----------------------------" "----------------------------" "----------"

for entry in "${pairs[@]}"; do
    label="${entry%%|*}"
    rest="${entry#*|}"
    bare_file="${rest%%|*}"
    flagged_file="${rest#*|}"

    bare_bin="$out_dir/quotation-bracket-$label-bare"
    flagged_bin="$out_dir/quotation-bracket-$label-flagged"
    build_aot "$bare_file" "$bare_bin"
    build_aot "$flagged_file" "$flagged_bin"

    for mode in interpreted hybrid eager aot; do
        bare_samples=()
        flagged_samples=()
        for _ in $(seq 1 "$reps"); do
            case "$mode" in
                aot)
                    bare_samples+=("$(time_binary_ns "$bare_bin")")
                    flagged_samples+=("$(time_binary_ns "$flagged_bin")")
                    ;;
                interpreted)
                    bare_samples+=("$(run_user_ns --compile=off "$bare_file")")
                    flagged_samples+=("$(run_user_ns --compile=off "$flagged_file")")
                    ;;
                *)
                    bare_samples+=("$(run_user_ns "--compile=$mode" "$bare_file")")
                    flagged_samples+=("$(run_user_ns "--compile=$mode" "$flagged_file")")
                    ;;
            esac
        done

        printf "%-12s %-12s %28s %28s %10s\n" \
            "$label" \
            "$mode" \
            "$(cell "${bare_samples[@]}")" \
            "$(cell "${flagged_samples[@]}")" \
            "$(ratio "$(median "${bare_samples[@]}")" "$(median "${flagged_samples[@]}")")"
    done
done
