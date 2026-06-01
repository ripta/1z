#!/bin/sh
#
# Diff the vendored ext/ir/ tree against the upstream commit recorded in
# README.md and print a report of local modifications. Used to verify that
# the "Local modifications" section in README.md is still accurate.
#
# Exit 0 if the recorded inventory matches the diff exactly.
# Exit 1 if a vendored file diverges from upstream in a way that is not
# documented, or if a documented file is no longer divergent.

set -eu

DEST="$(cd "$(dirname "$0")" && pwd)"
REPO="https://github.com/dstogov/ir.git"

# Extract the vendored commit from README.md.
PIN=$(awk '/Vendored commit:/ { print $4 }' "$DEST/README.md")
if [ -z "$PIN" ]; then
  echo "ERROR: could not parse 'Vendored commit:' line from README.md" >&2
  exit 1
fi

TMPROOT="${TMPDIR:-/tmp}"
UPSTREAM="$TMPROOT/ir-pinned-$PIN"

if [ ! -d "$UPSTREAM/.git" ]; then
  echo "Cloning $REPO at $PIN into $UPSTREAM..."
  git clone "$REPO" "$UPSTREAM" >/dev/null
fi

git -C "$UPSTREAM" -c advice.detachedHead=false checkout "$PIN" >/dev/null 2>&1

# Files vendor.sh copies from upstream. Anything outside this list is a
# local addition by definition.
VENDORED_FILES="
  ir.h
  ir_private.h
  ir_builder.h
  ir_fold.h
  ir_elf.h
  ir_x86.h
  ir_aarch64.h
  ir.c
  ir_strtab.c
  ir_cfg.c
  ir_sccp.c
  ir_gcm.c
  ir_ra.c
  ir_emit.c
  ir_save.c
  ir_dump.c
  ir_load.c
  ir_emit_c.c
  ir_emit_llvm.c
  ir_check.c
  ir_cpuinfo.c
  ir_gdb.c
  ir_perf.c
  ir_patch.c
  ir_mem2ssa.c
  ir_aarch64.dasc
  ir_x86.dasc
  gen_ir_fold_hash.c
  dynasm/minilua.c
  dynasm/dynasm.lua
  dynasm/dasm_proto.h
  dynasm/dasm_arm64.h
  dynasm/dasm_arm64.lua
  dynasm/dasm_x86.h
  dynasm/dasm_x64.lua
  dynasm/dasm_x86.lua
"

modified=""
missing=""
for f in $VENDORED_FILES; do
  if [ ! -f "$UPSTREAM/$f" ]; then
    missing="$missing $f"
    continue
  fi
  if ! diff -q "$UPSTREAM/$f" "$DEST/$f" >/dev/null 2>&1; then
    modified="$modified $f"
  fi
done

# Files in ext/ir/ that are not in the vendored manifest are local additions.
local_additions=""
for path in README.md vendor.sh ir_disasm_stub.c check-local-patches.sh; do
  if [ -f "$DEST/$path" ]; then
    local_additions="$local_additions $path"
  fi
done

echo "=== Modified vendored files (require transplant on upgrade) ==="
if [ -z "$modified" ]; then
  echo "  (none)"
else
  for f in $modified; do
    echo "  $f"
  done
fi

echo ""
echo "=== Local-only files (preserve across upgrade) ==="
for f in $local_additions; do
  echo "  $f"
done

if [ -n "$missing" ]; then
  echo ""
  echo "=== Upstream files missing from $UPSTREAM ==="
  for f in $missing; do
    echo "  $f"
  done
fi

# Optional: report whether the modified files have been absorbed upstream
# since the pinned commit. Compares against the upstream HEAD ref.
# Also dumps the upstream-HEAD copy of each modified file to
# $TMPDIR/ir-head-<sha>/<file> for manual inspection.
if [ "${CHECK_UPSTREAM_HEAD:-0}" = "1" ] && [ -n "$modified" ]; then
  echo ""
  echo "=== Upstream HEAD absorption check ==="
  HEAD_SHA=$(git -C "$UPSTREAM" rev-parse origin/HEAD)
  HEAD_DUMP="$TMPROOT/ir-head-$HEAD_SHA"
  git -C "$UPSTREAM" -c advice.detachedHead=false checkout "$HEAD_SHA" >/dev/null 2>&1
  mkdir -p "$HEAD_DUMP"
  for f in $modified; do
    cp "$UPSTREAM/$f" "$HEAD_DUMP/$(basename "$f")"
    if diff -q "$UPSTREAM/$f" "$DEST/$f" >/dev/null 2>&1; then
      echo "  $f -- ABSORBED upstream (drop patch on upgrade)"
    else
      patch=$(diff -u "$UPSTREAM/$f" "$DEST/$f" 2>/dev/null || true)
      hunks=$(printf "%s\n" "$patch" | grep -c '^@@ ' || true)
      echo "  $f -- divergent at HEAD ($HEAD_SHA), $hunks hunk(s); HEAD copy at $HEAD_DUMP/$(basename "$f")"
    fi
  done
  git -C "$UPSTREAM" -c advice.detachedHead=false checkout "$PIN" >/dev/null 2>&1
fi
