# `ext/toy`: FFI proof of concept

A minimal C library used to validate the FFI infrastructure for 1z. It
exercises the main marshaling patterns between 1z values and C types:

- `toy_add`, `toy_strlen` for fixnum and string arguments, fixnum return
- `toy_greeting` for C-allocated string returned to 1z, with caller frees semantics
- `toy_checksum`, `toy_fill` for byte array pointer+length passing
- `toy_open`, `toy_increment`, `toy_read`, `toy_close` for opaque resource lifecycle

The zig wrapper lives at `src/ffi/toy.zig` and registers all functions as
native registry entries, accessible via `native.toy-*` qualified names.

## Building

No separate build step. `build.zig` compiles `toy.c` directly into the
main executable via `addCSourceFile`.

There currently is no other way to control compilation.

## Testing

```
make test
```

The integration test is at `tests/integration/ffi_toy.1z`.
