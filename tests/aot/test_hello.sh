#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPOUT=$(mktemp "${TMPDIR:-/tmp}/1z_aot_test_XXXXXX")
trap "rm -f $TMPOUT" EXIT

BUILD_STDOUT=$("$ROOT/zig-out/bin/1z" build "$SCRIPT_DIR/hello.1z" -o "$TMPOUT")
BUILD_RC=$?
if [ $BUILD_RC -ne 0 ]; then
    echo "FAIL: aot-hello: build exited $BUILD_RC"
    exit 1
fi
if [ -n "$BUILD_STDOUT" ]; then
    echo "FAIL: aot-hello: unexpected build-time stdout: '$BUILD_STDOUT'"
    exit 1
fi

chmod +x "$TMPOUT"
OUTPUT=$("$TMPOUT")
RUN_RC=$?
if [ $RUN_RC -ne 0 ]; then
    echo "FAIL: aot-hello: binary exited $RUN_RC"
    exit 1
fi
if [ "$OUTPUT" = "Hello, AOT!" ]; then
    echo "PASS: aot-hello"
else
    echo "FAIL: aot-hello: expected 'Hello, AOT!', got '$OUTPUT'"
    exit 1
fi
