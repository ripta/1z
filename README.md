# 1z

A toy implementation of a stack-oriented language, followup to `1s`, but in
zig. Originally written on zig v0.15.2, but it might work in anything newer.

Useful commands:

- `make` to build into `./zig-out/bin/`
- `make run` to build and run the interpreter
- `make test` to run tests
- `make integration-test` to run integration tests against golden files
- `make update-golden` to update the golden files for integration tests
- `make release` to build with optimizations
- `make help` to list all available targets
