#!/bin/sh
#
# Re-vendor dstogov/ir from upstream and re-apply the local patches under
# patches/.
#
# By default the script vendors the commit recorded as "Vendored commit:"
# in README.md. Pass IR_COMMIT=<sha> to vendor a different commit; after a
# successful run, update README.md to match.
#
# Local modifications live as unified-diff patch files under
# ext/ir/patches/, applied in sorted order with `patch -p1` after the
# upstream copy and generators run. If a patch fails to apply, the script
# stops with a non-zero exit so the operator can transplant the change
# against the new upstream layout and refresh the patch file.

set -eu

DEST="$(cd "$(dirname "$0")" && pwd)"
REPO="https://github.com/dstogov/ir.git"
TMPROOT="${TMPDIR:-/tmp}"

PIN_FROM_README=$(awk '/^- Vendored commit:/ { print $4; exit }' "$DEST/README.md")
if [ -z "$PIN_FROM_README" ]; then
  echo "ERROR: could not parse 'Vendored commit:' line from README.md" >&2
  exit 1
fi

REQUESTED="${IR_COMMIT:-$PIN_FROM_README}"
if [ "$REQUESTED" != "$PIN_FROM_README" ]; then
  echo "Note: vendoring $REQUESTED (README.md still records $PIN_FROM_README)."
  echo "      Update README.md after the run completes."
fi

UPSTREAM="$TMPROOT/ir-upstream-$$"
echo "Cloning $REPO into $UPSTREAM..."
git clone "$REPO" "$UPSTREAM"
git -C "$UPSTREAM" -c advice.detachedHead=false checkout "$REQUESTED"

IR_COMMIT_RESOLVED=$(git -C "$UPSTREAM" rev-parse HEAD)
echo "Commit: $IR_COMMIT_RESOLVED"

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
cc -o "$TMPROOT/minilua-$$" "$DEST/dynasm/minilua.c" -lm

echo "Generating ir_emit_aarch64.h..."
"$TMPROOT/minilua-$$" "$DEST/dynasm/dynasm.lua" -M -o "$DEST/generated/ir_emit_aarch64.h" "$DEST/ir_aarch64.dasc"

echo "Generating ir_emit_x86.h..."
"$TMPROOT/minilua-$$" "$DEST/dynasm/dynasm.lua" -M -o "$DEST/generated/ir_emit_x86.h" "$DEST/ir_x86.dasc"

echo "Building gen_ir_fold_hash..."
cc -o "$TMPROOT/gen_ir_fold_hash-$$" "$DEST/gen_ir_fold_hash.c" -I "$DEST" -lm

echo "Generating ir_fold_hash.h..."
"$TMPROOT/gen_ir_fold_hash-$$" < "$DEST/ir_fold.h" > "$DEST/generated/ir_fold_hash.h"

# Apply local patches. Each patch is a unified diff with a/, b/ prefixes
# rooted at the ext/ir/ directory, applied with -p1.
if [ -d "$DEST/patches" ]; then
  patches=$(find "$DEST/patches" -maxdepth 1 -name '*.patch' -print | sort)
  if [ -n "$patches" ]; then
    echo ""
    echo "Applying patches..."
    for p in $patches; do
      name=$(basename "$p")
      if ! patch -d "$DEST" -p1 --dry-run --silent -i "$p" >/dev/null 2>&1; then
        echo "ERROR: $name does not apply cleanly against $IR_COMMIT_RESOLVED." >&2
        echo "       Transplant it manually and regenerate the patch file." >&2
        exit 1
      fi
      echo "  apply $name"
      patch -d "$DEST" -p1 --silent -i "$p"
    done
  fi
fi

# Cleanup temp files
rm -f "$TMPROOT/minilua-$$" "$TMPROOT/gen_ir_fold_hash-$$"
rm -rf "$UPSTREAM"

echo ""
echo "Done. Vendored dstogov/ir at commit $IR_COMMIT_RESOLVED"
if [ "$IR_COMMIT_RESOLVED" != "$PIN_FROM_README" ]; then
  echo "Update README.md: change 'Vendored commit:' to $IR_COMMIT_RESOLVED"
fi
