#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPOUT=$(mktemp "${TMPDIR:-/tmp}/1z_aot_test_XXXXXX")
TMPSTDERR=$(mktemp "${TMPDIR:-/tmp}/1z_aot_stderr_XXXXXX")
trap "rm -f $TMPOUT $TMPSTDERR" EXIT

BUILD_STDOUT=$("$ROOT/zig-out/bin/1z" build "$SCRIPT_DIR/stackeffect_error.1z" -o "$TMPOUT")
BUILD_RC=$?
if [ $BUILD_RC -ne 0 ]; then
    echo "FAIL: aot-stackeffect_error: build exited $BUILD_RC"
    exit 1
fi

chmod +x "$TMPOUT"
"$TMPOUT" 2>"$TMPSTDERR"
RUN_RC=$?
STDERR_CONTENT=$(cat "$TMPSTDERR")

if [ $RUN_RC -ne 1 ]; then
    echo "FAIL: aot-stackeffect_error: expected exit 1, got $RUN_RC"
    exit 1
fi
if ! echo "$STDERR_CONTENT" | grep -q "error"; then
    echo "FAIL: aot-stackeffect_error: expected error on stderr, got: '$STDERR_CONTENT'"
    exit 1
fi
echo "PASS: aot-stackeffect_error"
