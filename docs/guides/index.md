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
3. [Iterators and Sequences](iterators.md) -- lazy adapters, eager consumers,
   and pipelines
4. [Concurrency](concurrency.md) -- green threads, structured scopes, channels
5. [Async I/O](async-io.md) -- transparent non-blocking I/O inside task scopes
6. [HTTP](http.md) -- request/response, handler shape, routing, static files
7. [Foreign Function Interface](ffi.md) -- calling C libraries from 1z
8. [AOT Symbol Names for Profilers](aot-symbols.md) -- how `nm`, `perf`,
   and `samply` see 1z words in AOT binaries
9. [Coming from Forth or Factor](coming-from-forth.md) -- side-by-side syntax
   comparison for experienced stack-language programmers

All examples are runnable. Save any snippet to a `.1z` file and run it with
`./zig-out/bin/1z file.1z`.

The [Cookbook](../cookbook/index.md) collects common patterns and idiomatic
recipes.

The [Cheatsheet](../cheatsheet.md) is a compact reference for all syntax
and standard words.

The [API Reference](../reference/index.md) documents every word in the
standard library.
