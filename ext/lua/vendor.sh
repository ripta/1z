#!/bin/sh
#
# Re-vendor the Lua embeddable library from upstream into ext/lua/.
#
# The pinned version and its SHA-256 are the LUA_VERSION and LUA_SHA256
# constants below. Pass LUA_VERSION=<x.y.z> and LUA_SHA256=<sum> to vendor a
# different release; after a successful run, update those constants and
# VENDORING.md to match.
#
# The script downloads the release tarball, verifies its checksum against the
# pin, and copies only the embeddable library into ext/lua/: the core and
# standard-library .c files and every .h header. The standalone interpreter
# (lua.c), the bytecode compiler (luac.c), the C++ wrapper (lua.hpp), the
# documentation, the tests, and the upstream Makefiles are all dropped.
#
# Lua ships no standalone LICENSE file. Its MIT text lives as the copyright
# banner at the end of src/lua.h, so the script derives ext/lua/LICENSE from
# that banner, keeping the license reproducible from the vendored source.

set -eu

LUA_VERSION="${LUA_VERSION:-5.4.7}"
LUA_SHA256="${LUA_SHA256:-9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30}"

DEST="$(cd "$(dirname "$0")" && pwd)"
TMPROOT="${TMPDIR:-/tmp}"
URL="https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz"

# The core and standard-library sources: every .c in src/ except lua.c (the
# standalone interpreter) and luac.c (the bytecode compiler).
LUA_C_FILES="lapi.c lauxlib.c lbaselib.c lcode.c lcorolib.c lctype.c ldblib.c \
ldebug.c ldo.c ldump.c lfunc.c lgc.c linit.c liolib.c llex.c lmathlib.c lmem.c \
loadlib.c lobject.c lopcodes.c loslib.c lparser.c lstate.c lstring.c lstrlib.c \
ltable.c ltablib.c ltm.c lundump.c lutf8lib.c lvm.c lzio.c"

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

TARBALL="$TMPROOT/lua-$LUA_VERSION-$$.tar.gz"
UPSTREAM="$TMPROOT/lua-upstream-$$"

cleanup() {
  rm -f "$TARBALL"
  rm -rf "$UPSTREAM"
}
trap cleanup EXIT

echo "Downloading $URL..."
curl -fsSL -o "$TARBALL" "$URL"

echo "Verifying SHA-256..."
GOT="$(sha256_of "$TARBALL")"
if [ "$GOT" != "$LUA_SHA256" ]; then
  echo "ERROR: checksum mismatch for lua-$LUA_VERSION.tar.gz" >&2
  echo "       expected $LUA_SHA256" >&2
  echo "       got      $GOT" >&2
  exit 1
fi

mkdir -p "$UPSTREAM"
tar xzf "$TARBALL" -C "$UPSTREAM"

SRC="$UPSTREAM/lua-$LUA_VERSION/src"
if [ ! -d "$SRC" ]; then
  echo "ERROR: $SRC not found in the extracted tarball" >&2
  exit 1
fi

echo "Copying library sources into $DEST..."
for f in $LUA_C_FILES; do
  cp "$SRC/$f" "$DEST/"
done

# Every header is interdependent, so keep them all. The .h glob excludes the
# C++ wrapper lua.hpp (.hpp), which the FFI does not use.
for f in "$SRC"/*.h; do
  cp "$f" "$DEST/"
done

echo "Deriving LICENSE from src/lua.h copyright banner..."
awk '
  /^\* Copyright \(C\)/ { grab = 1 }
  grab {
    if ($0 ~ /^\*+\/$/) { exit }
    line = $0
    sub(/^\* ?/, "", line)
    print line
  }
' "$SRC/lua.h" > "$DEST/LICENSE"

if [ ! -s "$DEST/LICENSE" ]; then
  echo "ERROR: failed to derive LICENSE from src/lua.h" >&2
  exit 1
fi

echo ""
echo "Done. Vendored Lua $LUA_VERSION into ext/lua/"
