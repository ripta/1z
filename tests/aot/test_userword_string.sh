#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPOUT=$(mktemp "${TMPDIR:-/tmp}/1z_aot_test_XXXXXX")
trap "rm -f $TMPOUT" EXIT

BUILD_STDOUT=$("$ROOT/zig-out/bin/1z" build "$SCRIPT_DIR/userword_string.1z" -o "$TMPOUT")
BUILD_RC=$?
if [ $BUILD_RC -ne 0 ]; then
    echo "FAIL: aot-userword_string: build exited $BUILD_RC"
    exit 1
fi
if [ -n "$BUILD_STDOUT" ]; then
    echo "FAIL: aot-userword_string: unexpected build-time stdout: '$BUILD_STDOUT'"
    exit 1
fi

chmod +x "$TMPOUT"
OUTPUT=$("$TMPOUT")
RUN_RC=$?
if [ $RUN_RC -ne 0 ]; then
    echo "FAIL: aot-userword_string: binary exited $RUN_RC"
    exit 1
fi
if [ "$OUTPUT" = "Hello from user word!" ]; then
    echo "PASS: aot-userword_string"
else
    echo "FAIL: aot-userword_string: expected 'Hello from user word!', got '$OUTPUT'"
    exit 1
fi
