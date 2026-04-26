# 1z

`1z` is an experimental stack-oriented programming language implemented in Zig.

This repository contains the language implementation itself: parser, evaluator,
formatter, REPL / debugger, stdlib, examples, and the test corpus that defines
and protects the language's behavior.

It started as a follow-up to `1s`, but it has since grown into a broader
language and runtime playground rather than a minimal toy interpreter.

## Scope

The project currently spans several layers:

- A core implementation of a concatenative, stack-based language
- Language features such as quotations, modules, structs, enums, protocols,
  parse-time words, and introspection metadata
- Runtime facilities for tasks, channels, async IO, and sockets
- Library layers including HTTP serving
- Foreign-function support via libffi, with higher-level bindings for SQLite and
  zlib
- A test suite built around unit tests, integration tests, and golden-file
  verification

## Repository Layout

- `src/`: Zig implementation of the language runtime and native primitives
- `lib/`: stdlib modules written in `1z`
- `examples/`: Representative programs and feature demonstrations
- `tests/integration/`: End-to-end language tests with golden outputs
- `tests/formatting/`: Formatter input/output golden cases
- `ext/`: Small native support code used by FFI and integration coverage

## Development Workflow

Common entry points are intentionally simple:

- `make build`: build the interpreter
- `make test`: run the full test suite
- `make integration-test`: run integration tests
- `make fmt-test`: run formatter golden tests
- `make fmt`: format Zig and `1z` sources

The build and test setup is designed to keep the implementation, stdlib, and
golden outputs evolving together.

## What This README Is Not?

This README is not intended to be a user guide or language tutorial. If you
want to understand the language surface area, the best starting points are:

- `examples/` for representative programs
- `lib/` for the current stdlib
- `tests/integration/` for executable semantic coverage
- `src/` for implementation details

## Status

`1z` is an experimental project. Semantics, stdlib APIs, formatting behavior,
and diagnostics are still being refined as new capabilities are added.
