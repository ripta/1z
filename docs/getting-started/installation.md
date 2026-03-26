# Installation

## Prerequisites

- **Zig** -- 1z is built with Zig. See the project README for the currently
  tested version.
- **make**
- **git**

## Build

Clone the repository and build:

```
git clone https://github.com/ripta/1z.git
cd 1z
make
```

The binary is placed at `./zig-out/bin/1z`.

Verify the build worked:

```
./zig-out/bin/1z examples/showcase.1z
```

You should see output from the showcase program.

## Optimized Build

For an optimized release build:

```
make release
```

The binary location is the same (`./zig-out/bin/1z`).

## Running Tests

Confirm everything works:

```
make test
```

## Next Steps

Launch the [REPL](repl.md) to start experimenting.
