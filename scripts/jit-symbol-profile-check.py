#!/usr/bin/env python3
"""Read a gzipped samply profile for the names of JIT-compiled words.

Usage: jit-symbol-profile-check.py PROFILE.json.gz WORD [WORD...]
       jit-symbol-profile-check.py --top=N PROFILE.json.gz

The word form counts the samples whose stack names each given word. A word counts when a frame on a
sample's stack has exactly that function name. Finding the string in the profile is not enough: a
load record stamped at the wrong time leaves the name in the table while the samples that landed in
the code stay anonymous. It exits 0 when every word has samples, 1 when a word has none, and 2 when
the arguments are wrong or the profile is missing or cannot be parsed.

The --top form prints the N named frames with the most self samples and the N with the most samples
anywhere on the stack. It also counts the samples that carry an anonymous JIT frame. It exits 0 when
the profile is read, and 2 when N is not a positive integer or the profile cannot be read.
"""

import gzip
import json
import sys

USAGE = (
    "usage: jit-symbol-profile-check.py PROFILE.json.gz WORD [WORD...]\n"
    "       jit-symbol-profile-check.py --top=N PROFILE.json.gz"
)


def is_address(name):
    """An unsymbolicated frame is named by its hex address."""
    return name.startswith("0x")


def top_frames(threads, limit):
    """Print the frames with the most self and total samples.

    A frame is an anonymous JIT frame when its name is a bare address and its function has no
    resource. samply gives every address inside a loaded library a library resource, so an address
    outside all of them is JIT code the map did not name.
    """
    self_counts = {}
    total_counts = {}
    total = 0
    anonymous_jit = 0
    anonymous_leaf = 0

    for thread in threads:
        strings = thread["stringArray"]
        func_names = thread["funcTable"]["name"]
        frame_funcs = thread["frameTable"]["func"]
        stack_prefix = thread["stackTable"]["prefix"]
        stack_frame = thread["stackTable"]["frame"]

        func_resources = thread["funcTable"]["resource"]

        def name_of(node):
            return strings[func_names[frame_funcs[stack_frame[node]]]]

        def is_anonymous_jit(node):
            func = frame_funcs[stack_frame[node]]
            resource = func_resources[func]
            return is_address(strings[func_names[func]]) and (resource is None or resource < 0)

        for stack in thread["samples"]["stack"]:
            total += 1
            if stack is None:
                continue
            self_name = name_of(stack)
            self_counts[self_name] = self_counts.get(self_name, 0) + 1

            seen = set()
            has_anonymous = False
            walk = stack
            while walk is not None:
                seen.add(name_of(walk))
                has_anonymous = has_anonymous or is_anonymous_jit(walk)
                walk = stack_prefix[walk]
            for name in seen:
                total_counts[name] = total_counts.get(name, 0) + 1

            if has_anonymous:
                anonymous_jit += 1
            if is_anonymous_jit(stack):
                anonymous_leaf += 1

    print(f"samples: {total}")
    print(f"samples with an anonymous JIT frame: {anonymous_jit}")
    print(f"samples whose leaf is an anonymous JIT frame: {anonymous_leaf}")
    for label, counts in (("self", self_counts), ("total", total_counts)):
        named = {name: count for name, count in counts.items() if not is_address(name)}
        print(f"top {limit} named frames by {label}:")
        for name, count in sorted(named.items(), key=lambda item: -item[1])[:limit]:
            print(f"  {count:7d}  {name}")


def main():
    if len(sys.argv) < 2:
        print(USAGE, file=sys.stderr)
        return 2

    if sys.argv[1].startswith("--top"):
        value = sys.argv[1][len("--top="):] if sys.argv[1].startswith("--top=") else ""
        if len(sys.argv) != 3 or not value.isascii() or not value.isdigit() or int(value) < 1:
            print("ERROR: --top needs a positive integer, as in --top=20", file=sys.stderr)
            print(USAGE, file=sys.stderr)
            return 2

        try:
            with gzip.open(sys.argv[2], "rt") as handle:
                profile = json.load(handle)
            top_frames(profile["threads"], int(value))
        except (OSError, ValueError, KeyError) as err:
            print(f"ERROR: cannot read profile {sys.argv[2]}: {err}", file=sys.stderr)
            return 2
        return 0

    path = sys.argv[1]
    words = sys.argv[2:]
    if not words:
        print(USAGE, file=sys.stderr)
        return 2

    try:
        with gzip.open(path, "rt") as handle:
            profile = json.load(handle)
        threads = profile["threads"]
    except (OSError, ValueError, KeyError) as err:
        print(f"ERROR: cannot read profile {path}: {err}", file=sys.stderr)
        return 2

    counts = {word: 0 for word in words}
    total = 0

    for thread in threads:
        strings = thread["stringArray"]
        func_names = thread["funcTable"]["name"]
        frame_funcs = thread["frameTable"]["func"]
        stack_prefix = thread["stackTable"]["prefix"]
        stack_frame = thread["stackTable"]["frame"]

        names_by_stack = {}

        def names_of(stack):
            if stack is None:
                return frozenset()
            cached = names_by_stack.get(stack)
            if cached is not None:
                return cached
            chain = []
            walk = stack
            while walk is not None and walk not in names_by_stack:
                chain.append(walk)
                walk = stack_prefix[walk]
            names = names_by_stack[walk] if walk is not None else frozenset()
            for node in reversed(chain):
                names = names | {strings[func_names[frame_funcs[stack_frame[node]]]]}
                names_by_stack[node] = names
            return names_by_stack[stack]

        samples = thread["samples"]
        for stack in samples["stack"]:
            total += 1
            names = names_of(stack)
            for word in words:
                if word in names:
                    counts[word] += 1

    failed = False
    print(f"samples: {total}")
    for word in words:
        status = "PASS" if counts[word] > 0 else "FAIL"
        print(f"{status} samply: {word} on {counts[word]} samples")
        if counts[word] == 0:
            failed = True

    return 1 if failed else 0


sys.exit(main())
