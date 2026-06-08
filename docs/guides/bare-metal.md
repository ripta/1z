# Bare-Metal AOT Builds

1z can compile a program to a freestanding executable that runs on bare metal,
with no host operating system, no libc, no filesystem, and no `stdio`. The first
supported target is QEMU's `virt` machine on riscv64: an AOT-compiled program
boots through OpenSBI, writes to the simulated UART, and shuts down cleanly.

This guide covers what the freestanding build mode is, how to build for it, and
how to run the end-to-end test.

## What the freestanding mode is

`1z build` normally emits C with a `main` that links against libc and reads the
environment. When the target triple resolves to a freestanding OS
(`riscv64-freestanding-none`), the backend instead emits a `kernel_main` entry,
drops the libc headers and the environment sniff, and links with `-nostdlib`.
The runtime substrate comes from a separate freestanding C API root rather than
the hosted one: it allocates from a statically reserved `FixedBufferAllocator`,
omits the parser, debugger, module loader, FFI, sockets, TLS, child process, and
signals, and routes all output through a writer the platform layer supplies.

The capability tier is print-only. Filesystem, networking, TLS, dynamic FFI,
child process, environment variables, and signals are unavailable; reaching one
of those paths fails with a clear "not available on this build" error.

Because the module loader is absent, freestanding programs are restricted to
prelude words. A program that imports a standard-library module via `use` is out
of scope for this tier.

## The platform layer

The riscv64 `virt` platform lives at `src/baremetal/riscv64/virt/`:

- `boot.S` sets up the stack and calls the runtime entry shim.
- `linker.ld` places the kernel at the OpenSBI handoff address and reserves the
  BSS and stack regions.
- `uart.zig` drives the NS16550 UART at MMIO base `0x10000000`.
- `shutdown.zig` reports the result to QEMU through the `sifive_test` device; a
  success exits QEMU with code 0.
- `runtime_entry.zig` brings the runtime up, binds the UART writer as the output
  stream, runs the compiled program, and reports its status.

`print`, `print-line`, and every other word that writes through the
`output-stream` parameter work unchanged; only the underlying writer differs
from a hosted build.

## Building and running

QEMU is required for the emulation run and is not part of the default test loop.
Install it first:

- macOS: `brew install qemu`
- Debian/Ubuntu: `apt-get install qemu-system-misc`

The end-to-end test compiles a hello-world program to a freestanding ELF, boots
it under QEMU, and compares the captured serial output to an expected file:

```
make baremetal-riscv64-test
```

The target builds the platform library, the freestanding runtime, and the AOT
ELF, installs the ELF at `zig-out/baremetal/riscv64/1z-hello.elf`, then runs:

```
qemu-system-riscv64 -machine virt -nographic -bios default -kernel <elf>
```

OpenSBI prints its own boot banner to the same UART before handing control to
the kernel, so the captured serial begins with firmware output and ends with the
program's lines. The test compares the tail of the serial against the expected
output, which is robust to banner drift across QEMU and OpenSBI versions. If
QEMU is not on `PATH`, the target prints an install hint and fails rather than
silently passing.

To build a freestanding ELF directly, drive `1z build` with the cross target,
the platform linker script, and the platform/runtime/entry archives:

```
1z build --target=riscv64-freestanding-none --interpreter-fallback=false \
  --linker-script=src/baremetal/riscv64/virt/linker.ld \
  --link-object=<entry.a> --link-object=<platform.a> --link-object=<runtime.a> \
  -o kernel.elf program.1z
```

The archives are produced by `zig build baremetal-riscv64-test`; see `build.zig`
for how they are assembled.
