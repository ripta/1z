# Vendored: Lua

The Lua programming language, embedded and driven through the dynamic FFI by
`lib/lua.1z`. Built as a standalone shared library (`liblua5.4`), not compiled
into the `1z` binary, so a program that never loads `lib/lua.1z` pays nothing.

- Upstream: <https://www.lua.org/download.html>
- Vendored version: 5.4.7
- Tarball: <https://www.lua.org/ftp/lua-5.4.7.tar.gz>
- SHA-256: `9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30`
- License: MIT (see `LICENSE`)

## Kept files

The embeddable library only: the core and standard-library `.c` sources and
every `.h` header from the upstream `src/` directory.

- 32 `.c` files: the core (`lapi`, `lcode`, `lctype`, `ldebug`, `ldo`, `ldump`,
  `lfunc`, `lgc`, `llex`, `lmem`, `lobject`, `lopcodes`, `lparser`, `lstate`,
  `lstring`, `ltable`, `ltm`, `lundump`, `lvm`, `lzio`) and the standard
  libraries (`lauxlib`, `lbaselib`, `lcorolib`, `ldblib`, `linit`, `liolib`,
  `lmathlib`, `loadlib`, `loslib`, `lstrlib`, `ltablib`, `lutf8lib`).
- 27 `.h` headers: every header in `src/`. They are interdependent, so all are
  kept.

## Dropped files

- `lua.c` -- the standalone interpreter driver, not library code.
- `luac.c` -- the bytecode compiler driver, not library code.
- `lua.hpp` -- the C++ wrapper header, unused by the FFI.
- `doc/`, the test suite, and the upstream `Makefile`s.

## LICENSE

Lua ships no standalone `LICENSE` file. Its MIT text lives as the copyright
banner at the end of `src/lua.h`. `vendor.sh` derives `LICENSE` from that banner
so the license stays reproducible from the vendored source, satisfying the one
MIT obligation to retain the copyright and permission notice.

## Local-only files (preserve across upgrade)

- `VENDORING.md` -- this file.
- `LICENSE` -- derived from `src/lua.h` by `vendor.sh`.
- `vendor.sh` -- the vendoring script.

## Re-vendoring or bumping the version

Run `make lua-vendor`. The script downloads the pinned tarball, verifies its
SHA-256, copies the kept files into this directory, and regenerates `LICENSE`.

To move to a different release, pass the version and its checksum, then update
the `LUA_VERSION` and `LUA_SHA256` constants in `vendor.sh` and the version,
tarball, and checksum lines above:

```sh
LUA_VERSION=5.4.8 LUA_SHA256=<sum> ./ext/lua/vendor.sh
```

After a version bump, run `make test` to confirm the bindings still resolve.
