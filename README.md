# 1z

A toy implementation of a stack-oriented language, followup to `1s`, but in
zig. Originally written on zig v0.15.2, but it might work in anything newer.

Useful commands:

- `zig build` to build into `./zig-out/bin/`
- `zig build --release` to do optimized build
- `zig build test` to run tests
- `zig build integration-test` to run integration tests against golden files
- `zig build update-golden` to update the golden files for integration tests
