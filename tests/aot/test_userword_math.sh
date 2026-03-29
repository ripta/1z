#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPOUT=$(mktemp "${TMPDIR:-/tmp}/1z_aot_test_XXXXXX")
trap "rm -f $TMPOUT" EXIT

BUILD_STDOUT=$("$ROOT/zig-out/bin/1z" build "$SCRIPT_DIR/userword_math.1z" -o "$TMPOUT" 2>/dev/null)
if [ -n "$BUILD_STDOUT" ]; then
    echo "FAIL: aot-userword_math: unexpected build-time stdout: '$BUILD_STDOUT'"
    exit 1
fi

chmod +x "$TMPOUT"
OUTPUT=$("$TMPOUT" 2>/dev/null)
if [ "$OUTPUT" = "Hello from user word!" ]; then
    echo "PASS: aot-userword_math"
else
    echo "FAIL: aot-userword_math: expected 'Hello from user word!', got '$OUTPUT'"
    exit 1
fi
