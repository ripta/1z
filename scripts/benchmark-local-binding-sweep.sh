#!/usr/bin/env bash
#
# Tally which standard-library words that bind a named local compile to C.
#
# Usage: scripts/benchmark-local-binding-sweep.sh <1z-binary> <work-dir>
#
# A word binds a local with `name: swap ;` or `name: <expr> ;` inside its body. A compiled read
# of such a local needs the bound value proven to push one value, so whether a word compiles
# depends on how its inputs are declared. This sweep answers how far that reach extends across
# `lib/`, and names the reason for each word that still refuses.
#
# Each module with an in-body binding gets a driver that names every public multi-line word
# inside a quotation. Naming a word makes it reachable without calling it, so the build compiles
# it and everything it calls, private helpers included. Test modules are skipped.
#
# Two AOT classes are built per driver. The runtime-image class keeps an interpreter for what
# does not compile. The interpreter-free class refuses the whole build instead. The outcome for
# each word is read from `--trace-aot=codegen`, which reports every word the codegen pass
# reached, so a build that is rejected still reports every word it reached.
#
# A binding word is found by a line scan rather than a parse. A word opens at column 0, or at
# column 2 inside `private{ }`, on a line ending in `[`. A binding is an indented line inside it
# that ends in ` ;` and carries a `name:` token. A word defined on one line is not counted.

set -uo pipefail

onez="$1"
work="$2"

BUILD_BOUND="${BUILD_BOUND:-600}"

mkdir -p "$work"
export ONEZ_STDLIB="${ONEZ_STDLIB:-lib}"

binding_line='^[[:space:]]+([^\\].*[[:space:]])?[^[:space:]\\"]+:[[:space:]].*[[:space:]];[[:space:]]*$'

# `<word> <binding count> <public|private>` for every word in the file that binds a local.
scan_words() {
    BINDING_LINE="$binding_line" awk '
        BEGIN { binding = ENVIRON["BINDING_LINE"] }
        /^private\{/ { in_private = 1 }
        /^\}/ { in_private = 0; cur = "" }

        {
            indent = match($0, /[^ ]/) - 1
            opener_indent = in_private ? 2 : 0

            if (indent == opener_indent && $0 ~ /^ *[^ \\]+:[ ].*\[[ ]*$/ && $0 !~ /parse-time/) {
                cur = $1
                sub(/:$/, "", cur)
                vis[cur] = in_private ? "private" : "public"
                next
            }

            if (indent == opener_indent && $0 ~ /^ *\] *;/) cur = ""

            if (cur != "" && indent > opener_indent && $0 ~ binding) sites[cur]++
        }

        END { for (w in sites) print w, sites[w], vis[w] }
    ' "$1" | sort
}

# Every public multi-line word, bindings or not, so private helpers are reached through them.
public_words() {
    awk '
        /^private\{/ { in_private = 1 }
        /^\}/ { in_private = 0 }
        !in_private && /^[^ \\]+:[ ].*\[[ ]*$/ && !/parse-time/ {
            w = $1
            sub(/:$/, "", w)
            print w
        }
    ' "$1"
}

build_class() {
    local driver="$1" tag="$2"
    shift 2
    timeout "$BUILD_BOUND" "$onez" build "$driver" -o "$work/$tag.bin" --trace-aot=codegen "$@" \
        >"$work/$tag.log" 2>&1
}

# `ok` or the refusal's code for one word, from the last trace line naming it.
outcome() {
    local log="$1" qualified="$2"
    grep -F "AOT codegen word $qualified -> " "$log" | tail -1 | sed -E 's/.* -> (ok|REJECT (NC\.[0-9]+)).*/\1/; s/REJECT //'
}

modules=()
while IFS= read -r file; do
    modules+=("$file")
done < <(grep -rlE "$binding_line" lib --include='*.1z' | grep -v '_test\.1z$' | sort)

total_sites=0
tally="$work/tally"
: >"$tally"

echo "Named-local binding words across lib/"
echo "binary=$onez"
echo ""

for file in "${modules[@]}"; do
    module="${file#lib/}"
    module="${module%.1z}"
    tag="${module//\//_}"

    words="$(scan_words "$file")"
    [ -n "$words" ] || continue

    driver="$work/$tag.1z"
    {
        echo "use \"$module\" ;"
        public_words "$file" | while IFS= read -r w; do echo "[ $w ] drop"; done
    } >"$driver"

    build_class "$driver" "$tag-image" --emit-runtime-image
    build_class "$driver" "$tag-free" --interpreter-fallback=false

    module_sites=0
    echo "$module"
    printf "  %-36s %6s  %-14s %-16s\n" "word" "sites" "runtime-image" "interpreter-free"
    while read -r word sites _vis; do
        module_sites=$(( module_sites + sites ))
        image="$(outcome "$work/$tag-image.log" "$module/$word")"
        free="$(outcome "$work/$tag-free.log" "$module/$word")"
        image="${image:-unreached}"
        free="${free:-unreached}"
        echo "runtime-image $image" >>"$tally"
        echo "interpreter-free $free" >>"$tally"
        printf "  %-36s %6s  %-14s %-16s\n" "$word" "$sites" "$image" "$free"
    done <<<"$words"
    total_sites=$(( total_sites + module_sites ))

    for class in image free; do
        if ! grep -q 'AOT codegen word ' "$work/$tag-$class.log"; then
            echo "  $class build stopped before codegen:"
            grep -E '^Error' "$work/$tag-$class.log" | sed -n '1,5p' | sed 's/^/    /'
        fi
    done
    echo ""
done

echo "binding sites: $total_sites"
echo "binding words by outcome:"
sort "$tally" | uniq -c | awk '{ printf "  %-18s %-10s %4s\n", $2, $3, $1 }'
