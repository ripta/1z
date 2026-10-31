#!/usr/bin/env python3
"""Count the samples whose stack names each given word in a gzipped samply profile.

Usage: jit-symbol-profile-check.py PROFILE.json.gz WORD [WORD...]

A word counts when a frame on a sample's stack has exactly that function name. Finding the string
in the profile is not enough: a load record stamped at the wrong time leaves the name in the table
while the samples that landed in the code stay anonymous.

Exits 0 when every word has samples, 1 when a word has none, and 2 when the profile is missing or
cannot be parsed.
"""

import gzip
import json
import sys


def main():
    path = sys.argv[1]
    words = sys.argv[2:]
    if not words:
        print("usage: jit-symbol-profile-check.py PROFILE.json.gz WORD [WORD...]", file=sys.stderr)
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
