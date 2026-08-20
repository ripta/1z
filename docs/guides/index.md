# Conceptual Guides

These guides are standalone deep dives into 1z's major subsystems. Each one
explains how a subsystem works, why it is designed the way it is, and how to
use it effectively. They assume you are comfortable with the material in the
[Language Tutorials](../tutorials/index.md) -- stacks, quotations, word
definitions, and control flow.

1. [The Type System](type-system.md) -- structs, virtual types, enums,
   polymorphic dispatch, and protocols
2. [Modules](modules.md) -- loading, importing, qualified access, and
   selective imports
3. [Redefinition and Shadowing](redefinition-and-shadowing.md) -- the
   collision guard, the `override` marker, and each construct's release valve
4. [Standard Library Resolution](stdlib-resolution.md) -- how imports are
   resolved across the interpreter, embedding hosts, and AOT binaries
5. [User Startup Configuration](startup-config.md) -- the path chain, which
   commands run the file, and how a fault in it is reported
6. [Iterators and Sequences](iterators.md) -- lazy adapters, eager consumers,
   and pipelines
7. [Concurrency](concurrency.md) -- green threads, structured scopes, channels
8. [Async I/O](async-io.md) -- transparent non-blocking I/O inside task scopes
9. [Streams](streams.md) -- the shared read / write surface over files,
   pipes, in-memory buffers, and bidirectional fd pairs
10. [HTTP](http.md) -- request/response, handler shape, routing, static files
11. [CGI](cgi.md) -- running net/http handlers as classical CGI scripts
12. [Foreign Function Interface](ffi.md) -- calling C libraries from 1z
13. [POSIX](posix.md) -- libc-bound syscalls through the errno-aware FFI
    convention, and when to use them over native primitives
14. [Execution and Compilation Modes](execution-modes.md) -- interpreter,
    JIT, runtime-image AOT, and interpreter-free AOT tradeoffs
15. [Ahead-of-Time Compilation](aot.md) -- the complete AOT pipeline from
    source loading and freezing through C emission, linking, and startup
16. [AOT Symbol Names for Profilers](aot-symbols.md) -- how `nm`, `perf`,
    and `samply` see 1z words in AOT binaries
17. [Profiling](profiling.md) -- the interpreter's pprof export and the external
    `perf` / `samply` -> pprof path for AOT binaries
18. [Bare-Metal AOT Builds](bare-metal.md) -- freestanding executables that run
    on QEMU riscv64 with no operating system
19. [Coming from Forth or Factor](coming-from-forth.md) -- side-by-side syntax
    comparison for experienced stack-language programmers
20. [Tree-sitter Grammar](tree-sitter.md) -- installing and registering the 1z
    tree-sitter parser in Neovim, Helix, and Zed

All examples are runnable. Save any snippet to a `.1z` file and run it with
`./zig-out/bin/1z file.1z`.

The [Cookbook](../cookbook/index.md) collects common patterns and idiomatic
recipes.

The [Cheatsheet](../cheatsheet.md) is a compact reference for all syntax
and standard words.

The [API Reference](../reference/index.md) documents every word in the
standard library.
