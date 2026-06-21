# Standard Library Resolution

When you write `use "testing" ;` or `"./helpers.1z" load`, 1z has to turn that
string into a concrete module source. This guide explains how that resolution
works, where the standard library is found, and how the answer changes between
the interpreter, an embedding host, and an AOT binary.

The resolution *algorithm* is the same everywhere -- it is a single native code
path shared by every execution mode. What differs between modes is how the
search paths are initialized and whether module loading happens at runtime at
all.

## Path Mode vs Search Mode

The first thing the resolver does is classify the import string.

A string is a **path** when it starts with `./`, `../`, or `/`, or when it ends
in `.1z`. A path is resolved directly:

- An absolute path is canonicalized as-is.
- A relative path is resolved against the directory of the file doing the
  import, not the current working directory.

```
use "./helpers.1z" ;       \ next to the importing file
use "../shared/util.1z" ;  \ one directory up from it
```

Everything else is a **search name** -- a bare module name, which may contain
slashes to address subdirectories:

```
use "testing" ;     \ search name
use "net/tcp" ;     \ hierarchical search name -> lib/net/tcp.1z
```

A search name has `.1z` appended and is looked up in a series of search
locations, in order:

1. The **load paths**, in the order they were configured.
2. The **standard library path**.
3. The **embedded stdlib bundle**, if the runtime was built with one.

The first location that contains the module wins. Path-mode imports never
consult the standard library path or the embedded bundle; they are always
resolved relative to a real file or an absolute location.

## The Standard Library Path

The standard library path is the directory the resolver searches after the
load paths and before the embedded bundle. It is where `lib/` lives -- the
modules `testing`, `math`, `net/tcp`, and so on.

How it is set depends on the execution mode.

### Interpreter (the `1z` CLI)

The CLI determines the standard library path from the first of these that is
present:

1. `--stdlib-path=PATH` on the command line.
2. The `ONEZ_STDLIB` environment variable.
3. A default of `../lib` relative to the `1z` executable.

The load paths are seeded from the `ONEZ_LOAD_PATH` environment variable
(colon-separated) plus any `--load-path=PATH` flags (repeatable).

Because of the `../lib` default, a normal interpreter run in an installed or
in-tree layout finds the standard library with no configuration.

### Embedding Host (the C API)

When a host program initializes a runtime through the C API, the default
standard library path is `../lib` relative to the *host* executable. The host
can override it with `onez_set_stdlib_path`. On a freestanding build there is no
filesystem to discover, so the path stays unset and stdlib imports rely entirely
on the embedded bundle.

### AOT Binary

An AOT-compiled binary is different in a way that surprises people: its
generated entry point honors `ONEZ_STDLIB` if it is set, but it has **no
`../lib` default and no `--stdlib-path` flag**. If an AOT program resolves
imports at runtime and `ONEZ_STDLIB` is unset, the only remaining source is the
embedded bundle.

This matters only for imports an AOT program resolves *at runtime*. Imports
reached while the program is being built are resolved at build time by the
building `1z`, using the interpreter rules above, and baked into the binary. A
program that does its own dynamic loading -- for example, a linter that loads the
files it is checking, and those files import stdlib modules -- needs a runtime
standard library source, which is where `ONEZ_STDLIB` or the embedded bundle
comes in.

Interpreter-free AOT binaries (`--interpreter-fallback=false`) cannot parse and
load new source at runtime at all, so runtime stdlib resolution does not apply
to them; everything must be resolved at build time.

## The Embedded Standard Library Bundle

The standard library can be compiled directly into a binary as a fallback module
source. Building the runtime with `-Dembed-stdlib=true` walks the whole `lib/`
tree and embeds each module's source text into the binary. At resolution time
the bundle is consulted last, after the load paths and the standard library
path, so a stdlib on disk always wins over the embedded copy and the normal
development loop is unchanged.

The bundle holds source text, not compiled state: an embedded module is parsed
and executed through the interpreter exactly as if it had been read from disk,
under a stable `<stdlib>/name.1z` virtual path used for diagnostics and cache
keys. Two consequences follow. First, the bundle serves search names only
(`use "testing"`); a path-mode lookup goes through the filesystem and never sees
it. Second, because loading an embedded module runs the interpreter, the bundle
only helps modes that link the interpreter -- the interpreter itself, an
embedding host, and runtime-image AOT binaries -- not interpreter-free AOT
binaries.

Whether a given binary carries the bundle depends on whether the runtime it
links was built with `-Dembed-stdlib=true`: the interpreter binary for CLI runs,
or the runtime archive (`lib1z.a`) an AOT build links against. With an embedded
bundle present, a runtime-image AOT program resolves stdlib imports at runtime
with no `ONEZ_STDLIB` and no `lib/` on disk.

## Summary by Mode

| Mode | Standard library path source | Embedded bundle usable | Runtime loading |
|------|------------------------------|------------------------|-----------------|
| Interpreter (`1z`) | `--stdlib-path`, then `ONEZ_STDLIB`, then `../lib` default | Yes, if built with it | Yes |
| Embedding host (C API) | `../lib` default, or `onez_set_stdlib_path` | Yes, if built with it | Yes |
| Runtime-image AOT | `ONEZ_STDLIB` only | Yes, if `lib1z.a` built with it | Yes |
| Interpreter-free AOT | n/a (build-time only) | No | No |

## See Also

- [Modules](modules.md) -- importing, qualified access, hierarchical paths
- [Execution and Compilation Modes](execution-modes.md) -- the artifact
  classes referenced above
