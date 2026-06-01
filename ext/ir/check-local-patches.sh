#!/bin/sh
#
# Verify the vendored ext/ir/ tree matches "pinned upstream + patches/".
#
# Exits 0 when each tracked vendored file matches "pin + patches" exactly
# and every patch under patches/ applies cleanly against the pin.
#
# Exits 1 when:
#   - a vendored file diverges from "pin + patches/" without a patch to
#     account for it (someone hand-edited ext/ir/ outside the patch flow),
#   - a patch under patches/ no longer applies cleanly against the pin
#     (patch drift),
#   - a file listed in the manifest is missing from the pinned upstream.
#
# Pass CHECK_UPSTREAM_HEAD=1 to additionally report whether the patches
# still apply against upstream HEAD, as an informational signal for
# upgrade planning.

set -eu

DEST="$(cd "$(dirname "$0")" && pwd)"
REPO="https://github.com/dstogov/ir.git"

PIN=$(awk '/^- Vendored commit:/ { print $4; exit }' "$DEST/README.md")
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

# Build a working copy of the pinned upstream so we can apply patches/
# against it and diff the result.
WORK="$TMPROOT/ir-pinned-check-$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
for f in $VENDORED_FILES; do
  src="$UPSTREAM/$f"
  if [ ! -f "$src" ]; then
    continue
  fi
  mkdir -p "$WORK/$(dirname "$f")"
  cp "$src" "$WORK/$f"
done

missing=""
for f in $VENDORED_FILES; do
  if [ ! -f "$UPSTREAM/$f" ]; then
    missing="$missing $f"
  fi
done

status=0

# Apply patches against the working copy with --check first, then for
# real. Track per-patch apply success so the report can attribute
# divergence below to either patch drift or undocumented hand-edits.
patches=""
if [ -d "$DEST/patches" ]; then
  patches=$(find "$DEST/patches" -maxdepth 1 -name '*.patch' -print | sort)
fi

apply_failures=""
for p in $patches; do
  name=$(basename "$p")
  if ! patch -d "$WORK" -p1 --dry-run --silent -i "$p" >/dev/null 2>&1; then
    apply_failures="$apply_failures $name"
    continue
  fi
  patch -d "$WORK" -p1 --silent -i "$p" >/dev/null
done

# Compare the patched working copy against the live tree.
undocumented=""
for f in $VENDORED_FILES; do
  if [ ! -f "$DEST/$f" ]; then
    continue
  fi
  if [ ! -f "$WORK/$f" ]; then
    continue
  fi
  if ! diff -q "$WORK/$f" "$DEST/$f" >/dev/null 2>&1; then
    undocumented="$undocumented $f"
  fi
done

# Local-only files in ext/ir/ (preserved across upgrade).
local_additions=""
for path in README.md vendor.sh ir_disasm_stub.c check-local-patches.sh; do
  if [ -f "$DEST/$path" ]; then
    local_additions="$local_additions $path"
  fi
done

echo "=== Patches applied against pin ==="
if [ -z "$patches" ]; then
  echo "  (none)"
else
  for p in $patches; do
    name=$(basename "$p")
    case " $apply_failures " in
      *" $name "*) echo "  FAIL: $name does not apply cleanly against $PIN" ;;
      *)           echo "  ok:   $name" ;;
    esac
  done
fi

if [ -n "$apply_failures" ]; then
  status=1
fi

echo ""
echo "=== Undocumented divergence (live ext/ir/ vs. pin + patches) ==="
if [ -z "$undocumented" ]; then
  echo "  (none)"
else
  for f in $undocumented; do
    echo "  FAIL: $f differs without a patch to account for it"
  done
  status=1
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
  status=1
fi

# Optional: report whether the local patches still apply against upstream
# HEAD. Informational only; does not affect exit status.
if [ "${CHECK_UPSTREAM_HEAD:-0}" = "1" ] && [ -n "$patches" ]; then
  echo ""
  echo "=== Upstream HEAD apply check ==="
  HEAD_SHA=$(git -C "$UPSTREAM" rev-parse origin/HEAD)
  HEAD_WORK="$TMPROOT/ir-head-check-$$"
  mkdir -p "$HEAD_WORK"
  git -C "$UPSTREAM" -c advice.detachedHead=false checkout "$HEAD_SHA" >/dev/null 2>&1
  for f in $VENDORED_FILES; do
    src="$UPSTREAM/$f"
    if [ ! -f "$src" ]; then
      continue
    fi
    mkdir -p "$HEAD_WORK/$(dirname "$f")"
    cp "$src" "$HEAD_WORK/$f"
  done
  for p in $patches; do
    name=$(basename "$p")
    if patch -d "$HEAD_WORK" -p1 --dry-run --silent -i "$p" >/dev/null 2>&1; then
      patch -d "$HEAD_WORK" -p1 --silent -i "$p" >/dev/null 2>&1 || true
      echo "  $name -- applies against HEAD ($HEAD_SHA)"
    else
      echo "  $name -- DOES NOT apply against HEAD ($HEAD_SHA); transplant required"
    fi
  done
  rm -rf "$HEAD_WORK"
  git -C "$UPSTREAM" -c advice.detachedHead=false checkout "$PIN" >/dev/null 2>&1
fi

exit $status
