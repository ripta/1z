# Vendored: font8x8

A public-domain 8x8 monochrome bitmap font, used by `lib/game/font.1z` as the
source for the browser game platform's text-rendering glyph data.
`lib/game/font.1z` is generated from `font8x8_basic.h` at vendoring time; this
directory holds the pristine upstream source for provenance and re-vendoring,
not something loaded at runtime.

- Upstream: <https://github.com/dhepper/font8x8>
- Vendored commit: `4876b70490600222f30bb9acd2c02868e390bb56`
- File: <https://raw.githubusercontent.com/dhepper/font8x8/4876b70490600222f30bb9acd2c02868e390bb56/font8x8_basic.h>
- SHA-256: `49d8df366296b203ca3211bc0672cf2a762135bf12710735b6292756b19dffd5`
- License: Public Domain (see `LICENSE`)

## Kept files

- `font8x8_basic.h` -- the ASCII basic-Latin glyph table (unicode points
  U+0000-U+007F). The only file the platform needs: `lib/game/font.1z` covers
  the printable range, U+0020-U+007E.

## Dropped files

- `font8x8_block.h`, `font8x8_box.h`, `font8x8_control.h`,
  `font8x8_ext_latin.h`, `font8x8_greek.h`, `font8x8_hiragana.h`,
  `font8x8_latin.h`, `font8x8_misc.h`, `font8x8_sga.h`, `font8x8.h` -- other
  Unicode blocks and the umbrella header, outside the platform's ASCII-only
  coverage decision.
- `render.c` -- a demo CLI renderer, not library code. Its `render()` function
  is the reference used to confirm the glyph bit-order convention (row byte
  `b`, column `c`, pixel set iff `(b >> c) & 1` -- bit 0 is the leftmost
  pixel).
- `README` -- project documentation, not needed at build or run time.

## Glyph encoding

Each glyph is `char[8]`, one byte per row, top to bottom. Within a row byte,
bit `c` (0-7) is the pixel at column `c`, where column 0 is leftmost. Bit 7 is
always unset in this font; it is the font's built-in one-pixel inter-character
gutter.

## LICENSE

The upstream repository ships no standalone `LICENSE` file. Its public-domain
declaration lives as the comment banner at the top of `font8x8_basic.h`.
`vendor.sh` derives `LICENSE` from that banner, mirroring `ext/lua/vendor.sh`'s
approach to Lua's embedded MIT notice.

## Local-only files (preserve across re-vendoring)

- `VENDORING.md` -- this file.
- `LICENSE` -- derived from `font8x8_basic.h`'s banner by `vendor.sh`.
- `vendor.sh` -- the vendoring script.

## Re-vendoring or moving to a different commit

Run `make font8x8-vendor`. The script downloads the pinned file, verifies its
SHA-256, copies it into this directory, and regenerates `LICENSE`.

To move to a different commit, pass the commit and its checksum, then update
the `FONT8X8_COMMIT` and `FONT8X8_SHA256` constants in `vendor.sh` and the
commit, file, and checksum lines above:

```sh
FONT8X8_COMMIT=<sha> FONT8X8_SHA256=<sum> ./ext/font8x8/vendor.sh
```

After moving to a different commit, regenerate `lib/game/font.1z` from the
updated `font8x8_basic.h` and run `make test` to confirm the glyph data still
round-trips through `lib/game/font_test.1z`'s pinned-glyph assertions.
