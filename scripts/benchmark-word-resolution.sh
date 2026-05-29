#!/usr/bin/env bash
#
# Run the word-resolution benchmark across interpreter execution modes
# (off, hybrid, eager) and print a timing breakdown.
#
# Usage: scripts/benchmark-word-resolution.sh <1z-binary> <benchmark-file>
#
# AOT is skipped because the optimization being measured (call_word_direct)
# affects only the interpreter dispatch path. The headline number is from
# --compile=off; the hybrid/eager rows confirm the benefit fades as
# compilation kicks in.

set -euo pipefail

onez="$1"
benchmark="$2"

fmt_ms() {
    local ms="$1"
    if [ "$ms" -ge 1000 ]; then
        echo "$(echo "scale=3; $ms / 1000" | bc)s"
    else
        echo "${ms}ms"
    fi
}

echo "Running $benchmark in all interpreter modes..."
echo ""

# Collect results: mode prelude_ms jit_ms user_ms total_ms
results=()

for mode in interpreted hybrid eager; do
    if [ "$mode" = "interpreted" ]; then
        compile_flag="--compile=off"
    else
        compile_flag="--compile=$mode"
    fi

    output=$($onez run "$compile_flag" --benchmark=json "$benchmark" 2>/dev/null)

    # Program output is everything before the JSON line.
    program_output=$(echo "$output" | sed '$d')
    json=$(echo "$output" | tail -1)

    prelude_ms=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['timing']['prelude_ns'] // 1000000)")
    user_ms=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['timing']['user_ns'] // 1000000)")
    total_ms=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['timing']['total_ns'] // 1000000)")
    jit_ms=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['timing'].get('jit_compile_ns', d.get('jit',{}).get('compile_time_ns', 0)) // 1000000)")

    results+=("$mode $prelude_ms $jit_ms $user_ms $total_ms")

    echo "--- $mode ---"
    echo "$program_output"
    echo ""
done

echo "=== Summary ==="
echo ""
printf "%-15s %10s %10s %10s %10s\n" "Mode" "Prelude" "JIT" "User" "Total"
printf "%-15s %10s %10s %10s %10s\n" "---------------" "----------" "----------" "----------" "----------"

for entry in "${results[@]}"; do
    read -r mode prelude_ms jit_ms user_ms total_ms <<< "$entry"
    printf "%-15s %10s %10s %10s %10s\n" "$mode" "$(fmt_ms "$prelude_ms")" "$(fmt_ms "$jit_ms")" "$(fmt_ms "$user_ms")" "$(fmt_ms "$total_ms")"
done

echo ""
echo "(AOT skipped: optimization affects interpreter dispatch only.)"
