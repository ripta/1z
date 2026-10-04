#!/usr/bin/env python3
"""Split an entry census into recursion levels and report each level's entries by class.

Usage: scripts/entry-census.py DUMP ANCHOR [--expect CLASS:NAME,...]

DUMP is the stderr of a run of an `entry-census` build, or `-` for standard input. ANCHOR is
`CLASS:NAME` for an entry that occurs once per level of the recursion being measured, usually the
recursive word itself, and a NAME of `*` matches any name in that class. A level is the run of
entries from one anchor up to the entry before the next one.

The first and last levels are dropped. The first carries whatever led into the recursion, and the
last is cut short where the recursion bottoms out. Every remaining level has to have the same
composition, and the report states it once, in stack order, with the bytes each entry costs
averaged across those levels.

With --expect, the composition must equal the given list, which is how a synthetic shape whose
makeup is known by construction checks the instrument. The exit status is nonzero on a mismatch,
or when the levels disagree with each other.
"""

import argparse
import sys
from collections import defaultdict

CLASSES = ["nontail_compound", "tail_native", "nontail_native", "propagated", "other"]


def parse(lines):
    entries = []
    for line in lines:
        fields = line.split()
        if len(fields) >= 4 and fields[0] == "entry":
            name = fields[4] if len(fields) > 4 else ""
            entries.append((fields[2], name, int(fields[3])))
    return entries


def split_levels(entries, anchor):
    anchor_class, anchor_name = anchor.split(":", 1)
    starts = [
        i
        for i, (cls, name, _) in enumerate(entries)
        if cls == anchor_class and anchor_name in ("*", name)
    ]
    levels = []
    for a, b in zip(starts, starts[1:] + [len(entries)]):
        level = list(entries[a:b])
        if anchor_name == "*":
            cls, _, size = level[0]
            level[0] = (cls, "*", size)
        levels.append(level)
    return levels


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dump")
    parser.add_argument("anchor")
    parser.add_argument("--expect")
    args = parser.parse_args()

    stream = sys.stdin if args.dump == "-" else open(args.dump)
    entries = parse(stream)

    levels = split_levels(entries, args.anchor)
    if len(levels) < 3:
        print(f"FAIL: found {len(levels)} levels anchored on {args.anchor!r}, need at least 3")
        return 1

    middle = levels[1:-1]
    shapes = {tuple((cls, name) for cls, name, _ in level) for level in middle}
    if len(shapes) != 1:
        print(f"FAIL: the {len(middle)} middle levels anchored on {args.anchor!r} disagree:")
        for shape in sorted(shapes):
            print("  " + " ".join(f"{c}:{n}" for c, n in shape))
        return 1

    shape = next(iter(shapes))
    width = len(shape)
    averages = [sum(level[i][2] for level in middle) / len(middle) for i in range(width)]

    print(f"levels {len(middle)} (anchor {args.anchor}, first and last dropped)")
    print(f"entries per level {width}")
    for (cls, name), avg in zip(shape, averages):
        print(f"  {cls:<17} {avg:>9.1f}  {name}")

    by_class = defaultdict(lambda: [0, 0.0])
    for (cls, _), avg in zip(shape, averages):
        by_class[cls][0] += 1
        by_class[cls][1] += avg

    print(f"bytes per level {sum(averages):.1f}")
    for cls in CLASSES:
        if cls in by_class:
            count, total = by_class[cls]
            print(f"class {cls} {count} {total:.1f}")

    if args.expect is not None:
        expected = tuple(tuple(item.split(":", 1)) for item in args.expect.split(","))
        if expected != shape:
            print("FAIL: composition differs from --expect " + args.expect)
            return 1
        print("PASS: composition matches --expect")

    return 0


if __name__ == "__main__":
    sys.exit(main())
