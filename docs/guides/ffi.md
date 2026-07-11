# Foreign Function Interface

1z can call C functions at runtime through dynamic FFI. You load a shared
library, look up symbols, declare their signatures, and fire them directly
from the stack. No compilation step, no header files -- just `lib-open`,
bind, and call.

## Loading a Shared Library

`lib-open` loads a `.dylib` (macOS) or `.so` (Linux) and returns a library
handle:

```
use "ffi" ;

"m" lib-open
```

The bare name `"m"` resolves to the system math library (`libm`). For
custom libraries, pass a full path:

```
use "ffi" ;

environ "PWD" @get "/zig-out/ext/libtoy.dylib" #append lib-open
```

The library handle is a resource. When you are done, close it with
`resource-close` to release the OS handle.

## Low-Level FFI: `lib-symbol`, `bind-sig`, `ffi-call`

Three steps to call a C function:

1. Look up the symbol by name
2. Bind a signature describing the C types
3. Call it

```
use "testing" ;
use "ffi" ;

"m" lib-open
dup "sqrt" lib-symbol ffi{ f64 -> f64 } bind-sig
4.0 1 pick-n ffi-call
2.0 "sqrt(4.0)" assert=
drop
resource-close
```

`lib-symbol` digs out `sqrt` from the library and hands back a raw function
pointer. `ffi{ f64 -> f64 }` declares the signature: one `f64` argument, one
`f64` return. `bind-sig` wires the signature to the function pointer. Then
`ffi-call` pops the arguments from the stack, fires the C function, and
pushes the result.

The `1 pick-n` before `ffi-call` copies the bound function pointer from
below the argument. After the call, `drop` removes the function pointer
and `resource-close` releases the library.

## Signature Types

The `ffi{` syntax supports these C types:

| Type | C Equivalent | Notes |
|------|-------------|-------|
| `i32` | `int32_t` | Signed 32-bit integer |
| `i64` | `int64_t` | Signed 64-bit integer |
| `u8` | `uint8_t` | Unsigned byte |
| `f32` | `float` | 32-bit float |
| `f64` | `double` | 64-bit float |
| `cstring` | `const char*` | Null-terminated, borrowed |
| `cstring-owned` | `char*` | Null-terminated, caller frees |
| `ptr` | `void*` | Opaque pointer |
| `ptr:NAME` | `void*` | Typed pointer (see below) |
| `void` | `void` | No return value |

Arguments go left of `->`, the return type goes right:

```
ffi{ i32 i32 -> i32 }       \ two ints in, one int out
ffi{ cstring -> cstring }    \ string in, string out (borrowed)
ffi{ f64 f64 -> f64 }        \ two doubles in, double out
ffi{ -> ptr:counter }         \ no args, returns typed pointer
ffi{ ptr:counter -> void }    \ typed pointer in, no return
```

## The `ffi-def{` Macro

For multiple bindings, `ffi-def{` is more convenient. It declares several
words at once and spits out a module:

```
use "testing" ;
use "ffi" ;

"m" lib-open ffi-def{
  ffi-sqrt: "sqrt" ffi{ f64 -> f64 }
  ffi-pow:  "pow"  ffi{ f64 f64 -> f64 }
} call "ffi-math" swap >module import

25.0 ffi-sqrt 5.0 "sqrt(25)" assert=
2.0 10.0 ffi-pow 1024.0 "pow(2, 10)" assert=
```

Each entry maps a 1z word name to a C symbol name and signature. The
`call "name" swap >module import` pattern bakes the definitions into an
importable module.

## Errno-Aware Bindings

A typical libc function reports failure by returning a sentinel value and
writing the error code into the thread-local `errno`. Binding such a function
by hand means checking the return, resolving the platform-specific errno
fetcher, dereferencing it, and formatting the error. FFI does all of that for
you when a binding opts in.

An `ffi-def{` entry may carry an optional `H{ }` options hash between the
C-symbol string and the `ffi{ }` signature:

```
"c" lib-open ffi-def{
  (flock): "flock" H{ errno: neg1: cap: io/fs: } ffi{ i32 i32 -> i32 }
} call "libc" swap >module import
```

The `errno:` key names the failure sentinel. It is one of three symbols:

| Sentinel | Failure when the return value is |
|----------|----------------------------------|
| `neg1:` | equal to `-1` (the common `int`-returning case, and `MAP_FAILED`) |
| `null:` | equal to `0` / NULL (the pointer-returning case, e.g. `fopen`) |
| `neg:` | less than `0` |

When the return matches the sentinel, the runtime reads `errno` synchronously,
before any other call can clobber it, and raises a `posix-error:`. The error
carries a structured `data` hash and a `strerror`-derived message. A binding
with no `errno:` key behaves exactly as a plain binding: the raw return value
goes on the stack and `errno` is not touched.

The `data` hash has two fields. `errno:` is the raw platform integer. `name:`
is a normalized symbol (`ebadf:`, `enoent:`, `eagain:`, ...) sourced from the
build target. The `name:` symbol is the portable dispatch key: `EAGAIN` is `11`
on Linux and `35` on macOS, but the symbol is `eagain:` on both. Match on
`name:`, not the raw integer.

Catch a failure with `recover` and read the fields with `@get`:

```
use "posix" ;

[ -1 "LOCK_EX" posix-const flock ]
[ data: @get name: @get ]   \ ebadf:
recover
```

The error type is `posix-error:`, reachable through `error-type: @get`, and the
`strerror` text is `message: @get`.

The errno-on-NULL case works the same way, only the sentinel differs. A
`fopen`-style binding declares `H{ errno: null: cap: io/fs: }`, so a NULL return
triggers the errno fetch. (`fopen` is not part of the POSIX v1 surface; this
entry is illustrative.)

```
libc ffi-def{
  (fopen): "fopen" H{ errno: null: cap: io/fs: } ffi{ cstring cstring -> ptr }
}
```

The [POSIX guide](posix.md) is the worked consumer of this convention. Its
bindings are the first real libc functions bound this way.

## Per-Binding Capabilities

The `cap:` key of the same options hash names the sandbox capability the call
requires. It is checked at `ffi-call` against the active `sandbox{ }`, so the
sandbox distinguishes a file-locking call from a signal-sending call even though
both go through FFI. Absent a `cap:` key the binding requires the blanket `ffi`
capability.

The value is one of the existing sandbox capability names: `io`, `process`,
`io/fs`, `io/net`, `ffi`, `system`, `eval`, or `none`. A file-descriptor
operation declares `cap: io/fs:`; a process or memory operation declares
`cap: system:`; a harmless read like `getpid` declares `cap: none:`.

A granted capability allows its binding; a denied one is rejected before the C
code runs:

```
use "posix" ;

"cap-demo.txt" write: stream-open stream-close

\ truncate is bound with cap: io/fs:, so an io/fs grant allows it.
sandbox{ io/fs } [ "cap-demo.txt" 0 truncate drop ] with-sandbox

\ kill is bound with cap: system:, so the same io/fs grant denies it.
[ sandbox{ io/fs } [ getpid 0 kill ] with-sandbox ]
[ drop "denied" print-line ]
recover

"cap-demo.txt" delete-file
```

The [POSIX guide](posix.md) lists which capability each POSIX word requires.

## Resource Lifecycle

C libraries often hand back opaque pointers that must be freed. `bind-close`
wires a destructor to a resource so `resource-close` knows how to clean
it up:

```
use "testing" ;
use "ffi" ;

environ "PWD" @get "/zig-out/ext/libtoy.dylib" #append lib-open

dup ffi-def{
  toy-open:      "toy_open" ffi{ -> ptr:toy-counter }
  toy-increment: "toy_increment" ffi{ ptr:toy-counter -> void }
  toy-read:      "toy_read" ffi{ ptr:toy-counter -> i32 }
} call "toy-counter" swap >module import

dup "toy_close" ffi{ ptr -> void } bound-symbol
close-fn: swap ;

toy-open
dup toy-increment
dup toy-increment
dup toy-increment
dup toy-read 3 "three increments" assert=
dup close-fn bind-close
resource-close

resource-close
```

`bind-close` wires the `toy_close` function to the counter resource. When
`resource-close` fires, it calls `toy_close` automatically.

## Typed Pointers

`ptr:NAME` in a signature tags the pointer with a type name. This stops you
from accidentally passing a counter pointer where a connection pointer is
expected:

```
ffi{ -> ptr:toy-counter }       \ returns a toy-counter pointer
ffi{ ptr:toy-counter -> void }  \ accepts only toy-counter pointers
```

Passing the wrong pointer type throws a type error at call time, before
any C code runs.

## Out-Parameters

Some C functions write values through pointer arguments. Declare these
with `out-` prefixed types:

| Out Type | C Equivalent |
|----------|-------------|
| `out-i32` | `int32_t*` |
| `out-i64` | `int64_t*` |
| `out-f64` | `double*` |
| `out-bool` | `bool*` |
| `out-ptr` | `void**` |
| `out-cstring` | `char**` |

After `ffi-call`, out-parameter values are pushed onto the stack in order,
after the return value (if non-void):

```
use "testing" ;
use "ffi" ;

environ "PWD" @get "/zig-out/ext/libtoy.dylib" #append lib-open
dup "toy_divmod" lib-symbol ffi{ i32 i32 out-i32 out-i32 -> void } bind-sig
17 5 2 pick-n ffi-call
\ stack: lib ffi-fn quotient remainder
2 "remainder" assert=
3 "quotient" assert=
drop
resource-close
```

`toy_divmod(17, 5, &q, &r)` writes 3 to `q` and 2 to `r`. The out-params
appear on the stack in declaration order: quotient first, then remainder.

## Byte Buffers

`bytes>ffi-ptr+len` converts a byte array into a pointer and length pair
for C functions that expect `(const void*, size_t)`:

```
use "ffi" ;

B{ 1 2 3 4 } bytes>ffi-ptr+len
\ stack: resource fixnum
```

The resource is a pointer to the byte data; the fixnum is the length. The
pointer resource must be closed when done.

## Callbacks

`ffi-callback` wraps a 1z quotation into a C-callable function pointer:

```
use "testing" ;
use "ffi" ;

environ "PWD" @get "/zig-out/ext/libtoy.dylib" #append lib-open
dup "toy_apply2" ffi{ i32 i32 ptr:ffi-callback -> i32 } bound-symbol
[ + ] ffi{ i32 i32 -> i32 } ffi-callback
3 4 2 pick-n 4 pick-n ffi-call
7 "toy_apply2(3, 4, add) = 7" assert=
resource-close drop
resource-close
```

The `[ + ]` quotation gets baked into a C function pointer matching the
`ffi{ i32 i32 -> i32 }` signature. When C calls this pointer, 1z fires
the quotation with the arguments on the stack.

Callbacks are resources -- close them with `resource-close` when done. If
the quotation throws, the error bubbles back through `ffi-call`.

## Wrapping a C Library

The recommended pattern for a clean API: load the library, define bindings
with `ffi-def{`, and expose them as a module. Keep the raw FFI details
private; export stack-friendly words:

```
\ In lib/my-math.1z
use "ffi" ;

"m" lib-open ffi-def{
  __sqrt: "sqrt" ffi{ f64 -> f64 }
  __pow:  "pow"  ffi{ f64 f64 -> f64 }
} call "raw" swap >module import

sqrt: ( n -- n ) [ >float __sqrt ] ;
pow:  ( base exp -- n ) [ [ >float ] dip >float __pow ] ;
```

Users import `my-math` and call `sqrt` and `pow` without knowing about FFI
internals.

For exception-safe resource management, use `cleanup` to guarantee that
library handles and pointers are closed even if an error occurs:

```
use "ffi" ;

"m" lib-open
[ \ work with the library
  dup "sqrt" lib-symbol ffi{ f64 -> f64 } bind-sig
  9.0 1 pick-n ffi-call drop drop
]
[ resource-close ]  \ always runs, even on error
cleanup
```

The [guides index](index.md) has links to all conceptual guides.
