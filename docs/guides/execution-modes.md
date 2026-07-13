# Execution and Compilation Modes

1z has two main ways to run a program:

- execute source through the normal runtime, optionally with JIT compilation
- build a native executable with AOT compilation

The AOT path has several artifact classes depending on how much runtime
machinery is linked into the executable. This guide uses small programs and
repeatable commands to show the behavioral and operational differences.

For an end-to-end explanation of source loading, freezing, reachability,
codegen, runtime images, name mangling, and linking, see
[Ahead-of-Time Compilation](aot.md).

## Mode Summary

| Mode | Command shape | What runs | Main tradeoff |
|---|---|---|---|
| Interpreter | `1z run file.1z` or `1z run --compile=off file.1z` | Source is parsed and executed by the interpreter | Fastest edit/run loop, broadest runtime behavior, slowest hot code |
| Eager JIT | `1z run --compile=eager file.1z` | Each eligible word is compiled when defined | Better hot-code speed, more startup compile work |
| Hybrid JIT | `1z run --compile=hybrid file.1z` | Eligible words compile after enough calls | Lower startup cost than eager JIT, hot paths may speed up later |
| AOT, auto | `1z build file.1z -o out` | Native executable; fallback policy is automatic | Produces a binary, may link interpreter callbacks if needed |
| AOT, interpreter-linked | `1z build --interpreter-fallback=true file.1z -o out` | Native code plus full interpreter fallback | Largest, most capable AOT artifact |
| AOT, runtime image | `1z build --emit-runtime-image file.1z -o out` | Native code plus a frozen runtime program image | Keeps the full interpreter unlinked while preserving frozen dictionary/image state |
| AOT, interpreter-free | `1z build --interpreter-fallback=false --lock-interpreter-setting file.1z -o out` | Only the compiled frozen graph | Smallest/strictest capability surface; unsupported dynamic features fail at build time |

`ONEZ_COMPILE=off|eager|hybrid` can set the default compile mode for
interpreter-side commands. An explicit `--compile=...` flag wins.

## A Small All-Modes Program

Save this as `/tmp/modes-core.1z`:

```1z
"ok" print-line
```

Run it through the interpreter and JIT modes:

```sh
make build

/usr/bin/time -l ./zig-out/bin/1z run --compile=off /tmp/modes-core.1z
/usr/bin/time -l ./zig-out/bin/1z run --compile=eager /tmp/modes-core.1z
/usr/bin/time -l ./zig-out/bin/1z run --compile=hybrid /tmp/modes-core.1z
```

On Linux, use `/usr/bin/time -v` instead of `/usr/bin/time -l`.

Then build AOT artifacts:

```sh
mkdir -p /tmp/1z-modes

/usr/bin/time -l ./zig-out/bin/1z build /tmp/modes-core.1z \
  -o /tmp/1z-modes/core-auto

/usr/bin/time -l ./zig-out/bin/1z build --interpreter-fallback=true \
  /tmp/modes-core.1z -o /tmp/1z-modes/core-interpreter-linked

/usr/bin/time -l ./zig-out/bin/1z build --emit-runtime-image \
  /tmp/modes-core.1z -o /tmp/1z-modes/core-runtime-image

/usr/bin/time -l ./zig-out/bin/1z build \
  --interpreter-fallback=false --lock-interpreter-setting \
  /tmp/modes-core.1z -o /tmp/1z-modes/core-interpreter-free
```

Measure the produced binaries and run them:

```sh
ls -lh /tmp/1z-modes/core-*

/usr/bin/time -l /tmp/1z-modes/core-auto
/usr/bin/time -l /tmp/1z-modes/core-interpreter-linked
/usr/bin/time -l /tmp/1z-modes/core-runtime-image
/usr/bin/time -l /tmp/1z-modes/core-interpreter-free
```

Inspect each AOT artifact:

```sh
./zig-out/bin/1z inspect /tmp/1z-modes/core-auto
./zig-out/bin/1z inspect /tmp/1z-modes/core-interpreter-linked
./zig-out/bin/1z inspect /tmp/1z-modes/core-runtime-image
./zig-out/bin/1z inspect /tmp/1z-modes/core-interpreter-free
```

The important lines are:

- `artifact:` -- `interpreter`, `runtime-image-aot`, or `interpreter-free-aot`
- `interpreter:` -- whether the full interpreter is linked
- `runtime-image:` -- whether a full runtime image is embedded
- `aot-callbacks:` -- whether interpreter callback paths were linked

For this tiny program, the strict interpreter-free build should work because
the reachable graph is compileable and does not need runtime source loading,
runtime quotation construction, or dictionary rehydration. The program is too
small for meaningful speed comparisons, but it is useful for comparing build
time, binary size, memory floor, and artifact class.

## A Hot-Code Benchmark

For interpreter/JIT/AOT performance comparisons, use a program with enough hot
work to measure. Save this as `/tmp/modes-fib.1z`:

```1z
\ Small enough to read, large enough to measure.

fib-step: ( a b n -- result ) [
  dup 0 = [ drop drop ] [
    1 - [ swap over + ] dip fib-step
  ] if
] ;

fib: ( n -- n ) [
  dup 2 < [ ] [
    0 1 <rot- fib-step
  ] if
] ;

repeat-fib: ( n -- ) [
  dup 0 = [ drop ] [
    1 - 30 fib drop repeat-fib
  ] if
] ;

"fib(30) = " print 30 fib .
5000 repeat-fib
```

Run it under the interpreter and JIT modes:

```sh
/usr/bin/time -l ./zig-out/bin/1z run --compile=off /tmp/modes-fib.1z
/usr/bin/time -l ./zig-out/bin/1z run --compile=eager /tmp/modes-fib.1z
/usr/bin/time -l ./zig-out/bin/1z run --compile=hybrid /tmp/modes-fib.1z
```

Then compare AOT where the compiler is allowed to link the fallback surface it
needs:

```sh
/usr/bin/time -l ./zig-out/bin/1z build /tmp/modes-fib.1z \
  -o /tmp/1z-modes/fib-auto

/usr/bin/time -l ./zig-out/bin/1z build --interpreter-fallback=true \
  /tmp/modes-fib.1z -o /tmp/1z-modes/fib-interpreter-linked

/usr/bin/time -l /tmp/1z-modes/fib-auto
/usr/bin/time -l /tmp/1z-modes/fib-interpreter-linked
```

This benchmark is intentionally not the strict interpreter-free example. If
you force `--interpreter-fallback=false --lock-interpreter-setting`, the build
may reject it when a reachable path still emits a native or interpreter
callback. That rejection is useful information: it shows the program is not yet
inside the strict compiled subset.

## What to Measure

Use the same program and input when comparing modes. Record at least these:

| Measurement | How to collect it | What it usually tells you |
|---|---|---|
| Build time | `/usr/bin/time -l 1z build ...` | AOT and eager JIT pay compilation cost up front |
| Run time | `/usr/bin/time -l command` | AOT and JIT should help hot, compileable code |
| Peak memory | `maximum resident set size` from `time` | Interpreter-linked and runtime-image artifacts carry more runtime state |
| Binary size | `ls -lh out` or `stat -f %z out` on macOS | Interpreter-linked binaries are usually largest; strict artifacts are usually smaller |
| Artifact class | `1z inspect out` | Confirms which AOT variant was actually produced |

Expect small programs to be noisy. AOT build time and binary size can dominate
tiny workloads. For performance comparisons, increase the repeat count until
the fastest mode runs long enough to measure consistently.

## Capability Boundary: Runtime Image Without Full Interpreter

The Fibonacci program compares hot code across interpreter, JIT, and
fallback-permitted AOT modes. It does not show why `--emit-runtime-image`
exists. For that, use a program that needs frozen dictionary/image state but
does not need loading new source.

Save this as `/tmp/modes-runtime-image.1z`:

```1z
make-word: ( -- quotation ) [ "drop" >quotation ] ;

make-word drop
```

Strict interpreter-free AOT rejects it:

```sh
./zig-out/bin/1z build \
  --interpreter-fallback=false --lock-interpreter-setting \
  /tmp/modes-runtime-image.1z -o /tmp/1z-modes/runtime-image-strict
```

The error explains the boundary: `>quotation` constructs a quotation from a
word name at runtime, which needs dictionary lookup machinery that a strict
interpreter-free binary omits.

Build the same program with a runtime image:

```sh
./zig-out/bin/1z build --emit-runtime-image \
  /tmp/modes-runtime-image.1z -o /tmp/1z-modes/runtime-image-ok

./zig-out/bin/1z inspect /tmp/1z-modes/runtime-image-ok
/tmp/1z-modes/runtime-image-ok
```

The inspect output should classify the artifact as `runtime-image-aot` with
the interpreter not linked. That is the middle ground: the binary is not a full
interpreter-linked AOT artifact, but it carries enough frozen program image to
support this runtime lookup.

## Choosing a Mode

Use the interpreter while developing and debugging. Add `--compile=eager` when
you want to shake out JIT compilation issues or benchmark hot compileable
words. Use `--compile=hybrid` when startup cost matters and the workload has
repeated hot paths.

Use ordinary `1z build` when you want a native executable and are willing to
let the compiler choose the necessary fallback surface. Use
`--interpreter-fallback=true` when compatibility matters more than artifact
size. Use `--emit-runtime-image` when the program needs frozen dictionary or
runtime image state but should avoid linking the full interpreter. Use
`--interpreter-fallback=false --lock-interpreter-setting` when you want the
strictest compiled artifact and are prepared to rewrite unsupported dynamic
features.

## Example Timings

These measurements were taken from one run on macOS 26.5 on an Apple M3 Max,
using this repo's Debug build of `./zig-out/bin/1z`. They are not benchmark
claims; use them as a concrete example of the shape of the tradeoffs. Times
come from `/usr/bin/time -l`; memory is maximum resident set size, rounded to
MiB.

### `modes-core.1z`

The tiny `"ok" print-line` program mostly measures startup, artifact size, and
runtime footprint.

| Case | Artifact class | Build time | Run time | Max RSS while running | Size |
|---|---|---:|---:|---:|---:|
| `run --compile=off` | n/a | n/a | 0.03 s | 12.0 MiB | n/a |
| `run --compile=eager` | n/a | n/a | 0.03 s | 12.0 MiB | n/a |
| `run --compile=hybrid` | n/a | n/a | 0.02 s | 12.0 MiB | n/a |
| `build` / `core-auto` | `interpreter-free-aot` | 0.32 s | 0.01 s | 6.0 MiB | 15.6 MiB |
| `build --interpreter-fallback=true` | `interpreter` | 0.30 s | 0.03 s | 9.6 MiB | 15.7 MiB |
| `build --emit-runtime-image` | `runtime-image-aot` | 0.32 s | 0.01 s | 6.1 MiB | 15.6 MiB |
| `build --interpreter-fallback=false --lock-interpreter-setting` | `interpreter-free-aot` | 0.31 s | 0.01 s | 6.0 MiB | 15.6 MiB |

On this example, the ordinary `build` command already produced an
`interpreter-free-aot` artifact because all reachable code compiled without a
fallback. For tiny programs, elapsed time is mostly process startup noise; the
more useful differences are artifact class, linked runtime surface, and memory
floor.

### `modes-fib.1z`

The Fibonacci program is a better hot-code comparison. This run used
`5000 repeat-fib`.

| Case | Artifact class | Build time | Run time | Max RSS while running | Size |
|---|---|---:|---:|---:|---:|
| `run --compile=off` | n/a | n/a | 20.22 s | 12.2 MiB | n/a |
| `run --compile=eager` | n/a | n/a | 0.51 s | 15.3 MiB | n/a |
| `run --compile=hybrid` | n/a | n/a | 0.54 s | 15.4 MiB | n/a |
| `build` / `fib-auto` | `interpreter` | 0.33 s | 0.14 s | 39.9 MiB | 15.8 MiB |
| `build --interpreter-fallback=true` | `interpreter` | 0.33 s | 0.14 s | 39.9 MiB | 15.8 MiB |

Here the JIT modes are much faster than pure interpretation, and AOT is faster
again. The default AOT build classified as `interpreter`, not
`interpreter-free-aot`, because reachable code still emitted native callback
fallbacks. Forcing `--interpreter-fallback=false --lock-interpreter-setting`
is expected to reject this specific benchmark in the current implementation.

### Runtime-Image Boundary

The `modes-runtime-image.1z` example shows a capability difference rather than
a speed difference.

| Case | Result | Build time | Run time | Max RSS while running | Size |
|---|---|---:|---:|---:|---:|
| `build --interpreter-fallback=false --lock-interpreter-setting` | rejected: `>quotation` needs runtime dictionary/image machinery | 0.02 s | n/a | n/a | n/a |
| `build --emit-runtime-image` | `runtime-image-aot`, interpreter not linked | 0.29 s | 0.01 s | 5.8 MiB | 15.6 MiB |

`1z inspect /tmp/1z-modes/runtime-image-ok` reported
`runtime-image: present=yes`, `dynamic-features:
dynamic-quotation-construction`, and `interpreter: linked=no`.
