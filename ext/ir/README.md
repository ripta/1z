# Vendored: dstogov/ir

JIT compilation framework by Dmitry Stogov.

- Upstream: https://github.com/dstogov/ir
- Vendored commit: 7fed7999743ba6a5ffc5535e786725d5577f6f34

## Excluded files

- `ir_disasm.c` -- requires libcapstone; replaced by `ir_disasm_stub.c`
- `ir_main.c` -- standalone driver, not library code
- `ir_load_llvm.c` -- requires LLVM headers

## Local modifications

Run `./check-local-patches.sh` to verify this inventory against the
pinned upstream commit. Pass `CHECK_UPSTREAM_HEAD=1` to additionally
report whether upstream HEAD has absorbed any of the modifications.

### Local-only files (preserve across upgrade)

- `README.md` -- this file
- `vendor.sh` -- vendoring script
- `check-local-patches.sh` -- verifies local modifications against upstream
- `ir_disasm_stub.c` -- libcapstone-free stub replacing `ir_disasm.c`

### Modified vendored files (transplant on upgrade)

- `ir.c` -- macOS aarch64 W^X memory management. Wraps `ir_mem_mmap`,
  `ir_mem_protect`, and `ir_mem_unprotect` with `__APPLE__ &&
  __aarch64__` paths that use `MAP_JIT` and
  `pthread_jit_write_protect_np`. Not absorbed upstream as of HEAD
  `984a435f`.
- `ir_emit_c.c` -- two fixes in `ir_emit_overflow_math`:
    1. Declared type of the `overflow_N` local widened from `int` to
       `ir_type_cname[type]` so the address passed to
       `__builtin_*_overflow` matches the typed result pointer the
       intrinsic writes through.
    2. The intrinsic returns a boolean indicating overflow; that
       boolean must be assigned to the overflow IR ref, not to `def`,
       so the first `ir_emit_def_ref` argument was changed from `def`
       to `overflow`. The subsequent `def = overflow_N` line carries
       the computed result.
  Neither fix is absorbed upstream as of HEAD `984a435f`.

## Regenerating headers

If updating the vendored source, regenerate the headers in `generated/`:

```sh
./vendor.sh
```

Or manually:

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
