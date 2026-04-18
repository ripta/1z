#!/bin/sh
set -eux

REPO="https://github.com/dstogov/ir.git"
TMPDIR="${TMPDIR:-/tmp}"
UPSTREAM="$TMPDIR/ir-upstream-$$"
DEST="$(cd "$(dirname "$0")" && pwd)"

echo "Cloning $REPO into $UPSTREAM..."
git clone --depth 1 "$REPO" "$UPSTREAM"

IR_COMMIT=$(git -C "$UPSTREAM" rev-parse HEAD)
echo "Commit: $IR_COMMIT"

mkdir -p "$DEST/generated" "$DEST/dynasm"

# Headers
for f in ir.h ir_private.h ir_builder.h ir_fold.h ir_elf.h ir_x86.h ir_aarch64.h; do
  cp "$UPSTREAM/$f" "$DEST/"
done

# C sources
for f in ir.c ir_strtab.c ir_cfg.c ir_sccp.c ir_gcm.c ir_ra.c \
         ir_emit.c ir_save.c ir_dump.c ir_load.c \
         ir_emit_c.c ir_emit_llvm.c \
         ir_check.c ir_cpuinfo.c ir_gdb.c ir_perf.c ir_patch.c \
         ir_mem2ssa.c; do
  cp "$UPSTREAM/$f" "$DEST/"
done

# DynASM sources
cp "$UPSTREAM/ir_aarch64.dasc" "$DEST/"
cp "$UPSTREAM/ir_x86.dasc" "$DEST/"
cp "$UPSTREAM/gen_ir_fold_hash.c" "$DEST/"

# DynASM toolkit
for f in minilua.c dynasm.lua dasm_proto.h dasm_arm64.h dasm_arm64.lua \
         dasm_x86.h dasm_x64.lua dasm_x86.lua; do
  cp "$UPSTREAM/dynasm/$f" "$DEST/dynasm/"
done

# Pre-generate headers
echo "Building minilua..."
cc -o "$TMPDIR/minilua-$$" "$DEST/dynasm/minilua.c" -lm

echo "Generating ir_emit_aarch64.h..."
"$TMPDIR/minilua-$$" "$DEST/dynasm/dynasm.lua" -M -o "$DEST/generated/ir_emit_aarch64.h" "$DEST/ir_aarch64.dasc"

echo "Generating ir_emit_x86.h..."
"$TMPDIR/minilua-$$" "$DEST/dynasm/dynasm.lua" -M -o "$DEST/generated/ir_emit_x86.h" "$DEST/ir_x86.dasc"

echo "Building gen_ir_fold_hash..."
cc -o "$TMPDIR/gen_ir_fold_hash-$$" "$DEST/gen_ir_fold_hash.c" -I "$DEST" -lm

echo "Generating ir_fold_hash.h..."
"$TMPDIR/gen_ir_fold_hash-$$" < "$DEST/ir_fold.h" > "$DEST/generated/ir_fold_hash.h"

# Cleanup temp files
rm -f "$TMPDIR/minilua-$$" "$TMPDIR/gen_ir_fold_hash-$$"
# rm -rf "$UPSTREAM"

echo ""
echo "Done. Vendored dstogov/ir at commit $IR_COMMIT"
echo "Write this commit hash into ext/ir/README.md"
