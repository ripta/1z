#!/bin/sh
#
# Re-vendor font8x8_basic.h from upstream into ext/font8x8/.
#
# The pinned commit and its SHA-256 are the FONT8X8_COMMIT and FONT8X8_SHA256
# constants below. Pass FONT8X8_COMMIT=<sha> and FONT8X8_SHA256=<sum> to
# vendor a different commit; after a successful run, update those constants
# and VENDORING.md to match.
#
# The script downloads font8x8_basic.h at the pinned commit, verifies its
# checksum against the pin, and copies it into ext/font8x8/. Every other file
# in the upstream repository (the other Unicode-block headers, the umbrella
# font8x8.h, render.c, README) is dropped; see VENDORING.md for why.
#
# The upstream repository ships no standalone LICENSE file. Its public-domain
# declaration lives as the comment banner at the top of font8x8_basic.h, so
# the script derives ext/font8x8/LICENSE from that banner, keeping the license
# reproducible from the vendored source.

set -eu

FONT8X8_COMMIT="${FONT8X8_COMMIT:-4876b70490600222f30bb9acd2c02868e390bb56}"
FONT8X8_SHA256="${FONT8X8_SHA256:-49d8df366296b203ca3211bc0672cf2a762135bf12710735b6292756b19dffd5}"

DEST="$(cd "$(dirname "$0")" && pwd)"
TMPROOT="${TMPDIR:-/tmp}"
URL="https://raw.githubusercontent.com/dhepper/font8x8/$FONT8X8_COMMIT/font8x8_basic.h"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    echo "ERROR: need sha256sum or shasum to verify the download" >&2
    exit 1
  fi
}

DOWNLOAD="$TMPROOT/font8x8_basic-$$.h"

cleanup() {
  rm -f "$DOWNLOAD"
}
trap cleanup EXIT

echo "Downloading $URL..."
curl -fsSL -o "$DOWNLOAD" "$URL"

echo "Verifying SHA-256..."
GOT="$(sha256_of "$DOWNLOAD")"
if [ "$GOT" != "$FONT8X8_SHA256" ]; then
  echo "ERROR: checksum mismatch for font8x8_basic.h" >&2
  echo "       expected $FONT8X8_SHA256" >&2
  echo "       got      $GOT" >&2
  exit 1
fi

cp "$DOWNLOAD" "$DEST/font8x8_basic.h"

echo "Deriving LICENSE from font8x8_basic.h comment banner..."
awk '
  /^\/\*\*/ { grab = 1; next }
  grab {
    if ($0 ~ /^ \*+\//) { exit }
    line = $0
    sub(/^ \* ?/, "", line)
    print line
  }
' "$DEST/font8x8_basic.h" > "$DEST/LICENSE"

if [ ! -s "$DEST/LICENSE" ]; then
  echo "ERROR: failed to derive LICENSE from font8x8_basic.h" >&2
  exit 1
fi

echo ""
echo "Done. Vendored font8x8_basic.h at $FONT8X8_COMMIT into ext/font8x8/"
