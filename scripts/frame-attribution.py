#!/usr/bin/env python3
"""Attribute a function's native stack frame to the variables and inlined callees that occupy it.

Usage: scripts/frame-attribution.py BINARY OBJECT FUNCTION [--min BYTES] [--detail]

BINARY is the linked executable, read for the function's prologue. OBJECT is the object file its
debug map points at, which carries the DWARF; on macOS find it with `nm -ap BINARY | rg OSO`.
FUNCTION is the linkage name, such as `context.Context.executeInstructions`.

Every variable and formal parameter in the function's DWARF subtree that DWARF places on the stack
is mapped to a byte range of the frame. That includes the ones under inlined subroutines. Each
range is charged to the callee the function inlined directly, which is the unit an ablation can
remove. The report lists those callees by the bytes they cover, how many of those bytes no other
callee shares, and the bytes no variable names.

Backend stack coloring lets variables with disjoint lifetimes share a slot. So the covered bytes of
two callees can overlap, and removing one callee shrinks the frame by at most its exclusive bytes,
and possibly by nothing. Ablation is what settles the actual delta.

Requires Xcode's `dwarfdump` and a macOS arm64 binary. It assumes the frame base is x29
rather than reading `DW_AT_frame_base`. Under a sandbox `xcrun` cannot write its cache, so the tool
is resolved by path.
"""

import argparse
import re
import subprocess
import sys
from collections import defaultdict

DWARFDUMP = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/dwarfdump"

DIE_RE = re.compile(r"^(0x[0-9a-f]+):(\s+)(DW_TAG_\w+|NULL)")
ATTR_RE = re.compile(r"^\s+(DW_AT_\w+)\s*\((.*)")
REF_RE = re.compile(r"^(0x[0-9a-f]+)(?: \"(.*)\")?\)?$")
BREG_SP_RE = re.compile(r"^DW_OP_breg31 WSP([+-]\d+)$")
FBREG_RE = re.compile(r"^DW_OP_fbreg (-?\d+)$")
LIST_ENTRY_RE = re.compile(r"^\[0x[0-9a-f]+, 0x[0-9a-f]+\): (.*)$")
IMM_RE = re.compile(r"#(-?0x[0-9a-f]+|-?\d+)")


class Die:
    def __init__(self, offset, tag, depth):
        self.offset = offset
        self.tag = tag
        self.depth = depth
        self.attrs = {}
        self.children = []
        self.parent = None


def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def parse_dies(text):
    """Parse dwarfdump output into a forest. Depth comes from the indentation after the offset."""
    roots = []
    stack = []
    current = None
    current_attr = None

    for line in text.splitlines():
        m = DIE_RE.match(line)
        if m:
            offset, pad, tag = m.groups()
            if tag == "NULL":
                current = None
                continue

            die = Die(int(offset, 16), tag, len(pad))

            while stack and stack[-1].depth >= die.depth:
                stack.pop()

            if stack:
                die.parent = stack[-1]
                stack[-1].children.append(die)
            else:
                roots.append(die)

            stack.append(die)
            current = die
            current_attr = None
            continue

        if current is None:
            continue

        a = ATTR_RE.match(line)
        if a:
            current_attr = a.group(1)
            current.attrs[current_attr] = a.group(2)
        elif current_attr and line.strip():
            current.attrs[current_attr] += "\n" + line.strip()

    return roots


def ref(value):
    """The DIE offset and quoted name of a reference attribute."""
    m = REF_RE.match(value.strip())
    if not m:
        return None, None
    return int(m.group(1), 16), m.group(2)


class TypeResolver:
    def __init__(self, obj):
        self.obj = obj
        self.cache = {}

    def die(self, offset):
        if offset not in self.cache:
            text = run([DWARFDUMP, f"--debug-info=0x{offset:08x}", "-c", self.obj])
            dies = parse_dies(text)
            self.cache[offset] = dies[0] if dies else None
        return self.cache[offset]

    def type_of(self, die):
        """The type reference of a variable, following its abstract origin when it has none."""
        seen = 0
        while die is not None and seen < 8:
            if "DW_AT_type" in die.attrs:
                return ref(die.attrs["DW_AT_type"])
            if "DW_AT_abstract_origin" not in die.attrs:
                return None, None
            origin, _ = ref(die.attrs["DW_AT_abstract_origin"])
            die = self.die(origin)
            seen += 1
        return None, None

    def name_of(self, die):
        if "DW_AT_name" in die.attrs:
            return die.attrs["DW_AT_name"].strip('")')
        if "DW_AT_abstract_origin" in die.attrs:
            _, name = ref(die.attrs["DW_AT_abstract_origin"])
            return name
        return "?"

    def size(self, offset):
        """Byte size of a type, through typedefs, qualifiers, and array subranges."""
        die = self.die(offset)
        if die is None:
            return None

        if "DW_AT_byte_size" in die.attrs:
            return int(die.attrs["DW_AT_byte_size"].split(")")[0], 0)

        # Zig emits pointer types without a byte size. Following their DW_AT_type would size the
        # pointee instead.
        if die.tag in ("DW_TAG_pointer_type", "DW_TAG_reference_type", "DW_TAG_rvalue_reference_type"):
            return 8

        if die.tag == "DW_TAG_array_type":
            elem, _ = ref(die.attrs["DW_AT_type"])
            elem_size = self.size(elem)
            count = 1
            for child in die.children:
                if child.tag != "DW_TAG_subrange_type":
                    continue
                if "DW_AT_count" in child.attrs:
                    count *= int(child.attrs["DW_AT_count"].split(")")[0], 0)
                elif "DW_AT_upper_bound" in child.attrs:
                    count *= int(child.attrs["DW_AT_upper_bound"].split(")")[0], 0) + 1
            return None if elem_size is None else elem_size * count

        if "DW_AT_type" in die.attrs:
            inner, _ = ref(die.attrs["DW_AT_type"])
            return self.size(inner)

        return None


def prologue(binary, function):
    """The register save area, the x29 offset into it, and the locals below it, from the prologue.

    The shape is `stp ..., [sp, #-SAVE]!`, then `add x29, sp, #FP`, then one or more `sub sp, sp`.
    """
    text = run(["objdump", "-d", "--no-show-raw-insn", f"--disassemble-symbols=_{function}", binary])
    save = fp = None
    locals_ = 0

    for line in text.splitlines()[:40]:
        if save is None and "stp" in line and "]!" in line:
            save = -int(IMM_RE.search(line).group(1), 0)
        elif fp is None and re.search(r"\badd\s+x29, sp", line):
            fp = int(IMM_RE.search(line).group(1), 0)
        elif re.search(r"\bsub\s+sp, sp", line):
            imm = int(IMM_RE.search(line).group(1), 0)
            if "lsl #12" in line:
                imm <<= 12
            locals_ += imm
        elif locals_:
            break

    if save is None or fp is None:
        sys.exit(f"could not read the prologue of {function}")

    return save, fp, locals_


def expressions(location):
    """The DWARF expressions in a location attribute, one per location-list entry."""
    location = location.strip().rstrip(")")
    lines = [line.strip() for line in location.splitlines()]

    if len(lines) > 1:
        return [m.group(1).rstrip(")") for line in lines if (m := LIST_ENTRY_RE.match(line))]

    return [location]


def stack_slots(location, fp_to_sp):
    """The (offset, size) stack slots a location names. A size of None means the whole type.

    A piece sits at its base offset for the piece's size. A bare base address holds the whole
    variable. Under `DW_OP_deref` the slot holds a pointer, and under `DW_OP_deref_size N` it holds
    N bytes. Under `DW_OP_stack_value` the address is the value itself, so no slot is named.
    """
    slots = set()

    for expr in expressions(location):
        base = None
        size = None
        storage = True

        for op in (o.strip() for o in expr.split(",")):
            m = BREG_SP_RE.match(op)
            f = FBREG_RE.match(op)

            if m:
                base, size, storage = int(m.group(1)), None, True
            elif f:
                base, size, storage = int(f.group(1)) + fp_to_sp, None, True
            elif op == "DW_OP_deref":
                size = 8
            elif op.startswith("DW_OP_deref_size"):
                size = int(op.split()[1], 0)
            elif op == "DW_OP_stack_value":
                storage = False
            elif op.startswith("DW_OP_piece"):
                if base is not None and storage:
                    slots.add((base, int(op.split()[1], 0) if size is None else size))
                base = None
            elif base is not None:
                # Arithmetic on the base names something other than a slot at that offset.
                storage = False

        if base is not None and storage:
            slots.add((base, size))

    return slots


def union_size(ranges):
    total = 0
    end = -1
    for lo, hi in sorted(ranges):
        if hi <= end:
            continue
        total += hi - max(lo, end)
        end = hi
    return total


def covered(ranges):
    bytes_ = set()
    for lo, hi in ranges:
        bytes_.update(range(lo, hi))
    return bytes_


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("binary")
    p.add_argument("object")
    p.add_argument("function")
    p.add_argument("--min", type=int, default=0, help="omit callees covering fewer bytes than this")
    p.add_argument("--detail", action="store_true", help="also list every variable range")
    args = p.parse_args()

    save, fp, locals_ = prologue(args.binary, args.function)
    fp_to_sp = fp + locals_

    short = args.function.rsplit(".", 1)[-1]
    text = run([DWARFDUMP, f"--name={short}", "-c", args.object])
    candidates = [
        d for d in parse_dies(text)
        if d.tag == "DW_TAG_subprogram"
        and args.function in d.attrs.get("DW_AT_linkage_name", "")
        and "DW_AT_low_pc" in d.attrs
    ]
    if len(candidates) != 1:
        sys.exit(f"expected one concrete subprogram for {args.function}, found {len(candidates)}")

    types = TypeResolver(args.object)
    rows = []
    unsized = []

    def walk(die, top):
        for child in die.children:
            child_top = top
            if child.tag == "DW_TAG_inlined_subroutine" and top is None:
                _, child_top = ref(child.attrs.get("DW_AT_abstract_origin", ""))

            if child.tag in ("DW_TAG_variable", "DW_TAG_formal_parameter") and "DW_AT_location" in child.attrs:
                slots = stack_slots(child.attrs["DW_AT_location"], fp_to_sp)
                if slots:
                    type_off, type_name = types.type_of(child)
                    type_size = types.size(type_off) if type_off is not None else None
                    name = types.name_of(child)

                    for off, size in slots:
                        size = type_size if size is None else size
                        if size is None:
                            unsized.append((name, type_name))
                        elif off >= 0:
                            rows.append((off, size, name, type_name, child_top or short))

            walk(child, child_top)

    walk(candidates[0], None)

    in_frame = [(o, min(o + s, locals_), n, t, c) for o, s, n, t, c in rows if o < locals_]

    by_callee = defaultdict(list)
    for lo, hi, _, _, callee in in_frame:
        by_callee[callee].append((lo, hi))

    owners = defaultdict(set)
    for callee, ranges in by_callee.items():
        for b in covered(ranges):
            owners[b].add(callee)

    print(f"{args.function}")
    print(f"  frame {save + locals_} = register saves {save} + locals {locals_}; x29 = sp + {fp_to_sp}")
    print()
    print(f"  {'covered':>8} {'exclusive':>9}  callee")

    named = covered([(lo, hi) for lo, hi, *_ in in_frame])
    for callee, ranges in sorted(by_callee.items(), key=lambda kv: -union_size(kv[1])):
        size = union_size(ranges)
        if size < args.min:
            continue
        exclusive = sum(1 for b in covered(ranges) if owners[b] == {callee})
        print(f"  {size:>8} {exclusive:>9}  {callee}")

    print()
    print(f"  named by some variable: {len(named)} of {locals_}")
    print(f"  named by no variable:   {locals_ - len(named)}")

    if unsized:
        print(f"  stack variables of unresolved size: {len(unsized)}")

    if args.detail:
        print()
        print(f"  {'offset':>7} {'size':>6}  variable : type  [callee]")
        for lo, hi, name, type_name, callee in sorted(set(in_frame)):
            print(f"  {lo:>7} {hi - lo:>6}  {name} : {type_name}  [{callee}]")


if __name__ == "__main__":
    main()
