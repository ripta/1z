# Cookbook

Recipes for common patterns and idiomatic 1z. Each recipe is self-contained
with runnable code you can paste into a file and execute. They assume you are
comfortable with the material in the [Language Tutorials](../tutorials/index.md)
-- stacks, quotations, word definitions, and control flow.

1. [Stack Idioms](stack-idioms.md) -- `dip`, `keep`, `bi`, `tri`, `curry`,
   `compose`; when to reach for a combinator instead of shuffling
2. [Error Handling](error-handling.md) -- `recover`, `try`, `cleanup`,
   custom errors, and nesting handlers
3. [Iterator Pipelines](iterator-pipelines.md) -- lazy transformation chains,
   aggregation, partitioning, and infinite ranges
4. [Data Structures](data-structures.md) -- hashes, structs, virtual types,
   enums, vectors, and sets
5. [String Processing](string-processing.md) -- splitting, joining, template
   formatting, and character-level operations
6. [Concurrency Patterns](concurrency-patterns.md) -- task scopes, channels,
   buffered backpressure, select, and timeouts
7. [Testing Patterns](testing-patterns.md) -- assertions, grouping, and
   error testing
8. [Module Organization](module-organization.md) -- imports, selective
   imports, qualified access, and shadow suppression

Runnable example files for each recipe live in `examples/cookbook/`.

For a compact reference of all syntax and words, see the
[Cheatsheet](../cheatsheet.md). For deep dives into specific subsystems,
see the [Conceptual Guides](../guides/index.md).
