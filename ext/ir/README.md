# Vendored: dstogov/ir

JIT compilation framework by Dmitry Stogov.

- Upstream: https://github.com/dstogov/ir
- Vendored commit: 7fed7999743ba6a5ffc5535e786725d5577f6f34

## Excluded files

- `ir_disasm.c` -- requires libcapstone; replaced by `ir_disasm_stub.c`
- `ir_main.c` -- standalone driver, not library code
- `ir_load_llvm.c` -- requires LLVM headers

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
