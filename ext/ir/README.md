# Vendored: dstogov/ir

JIT compilation framework by Dmitry Stogov.

- Upstream: https://github.com/dstogov/ir
- Vendored commit: 984a435f70753db8f1e0ef0b6912002c336e4dcb

## Excluded files

- `ir_disasm.c` -- requires libcapstone; replaced by `ir_disasm_stub.c`
- `ir_main.c` -- standalone driver, not library code
- `ir_load_llvm.c` -- requires LLVM headers

## Local modifications

Local modifications live under `patches/` as unified-diff files,
applied with `patch -p1` against the pinned upstream tree by
`vendor.sh` after the upstream copy and generator runs. Each patch is
rooted at the `ext/ir/` directory.

Current set:

- `patches/0001-macos-aarch64-wx.patch` -- macOS aarch64 W^X memory
  management. Wraps `ir_mem_mmap`, `ir_mem_protect`, and
  `ir_mem_unprotect` with `__APPLE__ && __aarch64__` paths that use
  `MAP_JIT` and `pthread_jit_write_protect_np`. Not absorbed upstream
  as of the pinned commit.
- `patches/0002-emit-c-overflow-type.patch` -- two fixes in
  `ir_emit_overflow_math`: widens the declared type of the
  `overflow_N` local from `int` to `ir_type_cname[type]` so the
  address passed to `__builtin_*_overflow` matches the typed result
  pointer, and routes the intrinsic's overflow-boolean assignment to
  the `overflow` IR ref instead of `def` so the subsequent `def =
  overflow_N` line carries the computed result. Not absorbed upstream
  as of the pinned commit.

### Local-only files (preserve across upgrade)

- `README.md` -- this file
- `vendor.sh` -- vendoring script
- `check-local-patches.sh` -- verifies live tree against pin + patches
- `ir_disasm_stub.c` -- libcapstone-free stub replacing `ir_disasm.c`
- `patches/` -- the local modification set

## Verifying the local tree

Run `./check-local-patches.sh` to confirm the live tree matches
"pinned upstream + patches/" exactly. The script reports patches that
no longer apply against the pin and any vendored file that has
diverged without a patch to account for it; either condition exits
non-zero.

Pass `CHECK_UPSTREAM_HEAD=1` to additionally report whether each
patch still applies against upstream HEAD. This is informational and
useful when planning an upgrade.

`make ir-check` and `make ir-check-upstream` wrap the two modes.

## Upgrade workflow

1. `make ir-check-upstream` to see whether the local patches still
   apply at upstream HEAD.
2. `IR_COMMIT=<new sha> make ir-vendor` to re-vendor at the chosen
   commit. The script copies the upstream files, regenerates the
   DynASM and fold-hash headers, then applies each `patches/*.patch`
   in sorted order. If a patch fails to apply, the script stops with
   a message naming which patch.
3. If `ir-vendor` reported a failing patch, hand-transplant the
   change against the new upstream layout, regenerate the patch file
   (`diff -u --label a/<f> --label b/<f> <new-upstream>/<f>
   ext/ir/<f>`), and re-run `make ir-vendor`.
4. Edit the `Vendored commit:` line in this file to the new SHA.
5. `make test` to confirm the upgrade does not break callers.

## Regenerating headers

`vendor.sh` already runs the generators after copying upstream
sources. To regenerate by hand without re-vendoring:

```sh
# Build minilua
cc -o /tmp/minilua dynasm/minilua.c -lm

# Generate DynASM output
/tmp/minilua dynasm/dynasm.lua -M -o generated/ir_emit_aarch64.h ir_aarch64.dasc
/tmp/minilua dynasm/dynasm.lua -M -o generated/ir_emit_x86.h ir_x86.dasc

# Build and run fold hash generator
cc -o /tmp/gen_ir_fold_hash gen_ir_fold_hash.c -I . -lm
/tmp/gen_ir_fold_hash < ir_fold.h > generated/ir_fold_hash.h
```
