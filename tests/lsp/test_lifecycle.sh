#!/bin/bash
# LSP lifecycle tests for 1z-lsp
set -euo pipefail

LSP_BIN="${1:-./zig-out/bin/1z-lsp}"
PASS=0
FAIL=0
TMPDIR="${TMPDIR:-/tmp}"

send_lsp() {
  local input_file="$TMPDIR/lsp_input.bin"
  local output_file="$TMPDIR/lsp_output.bin"
  local stderr_file="$TMPDIR/lsp_stderr.txt"
  > "$input_file"
  for msg in "$@"; do
    printf "Content-Length: %d\r\n\r\n%s" "${#msg}" "$msg" >> "$input_file"
  done
  set +e
  "$LSP_BIN" < "$input_file" > "$output_file" 2>"$stderr_file"
  LSP_EXIT=$?
  set -e
  LSP_STDOUT="$(cat "$output_file")"
  LSP_STDERR="$(cat "$stderr_file")"
}

assert_exit() {
  local desc="$1" expected="$2"
  if [ "$LSP_EXIT" = "$expected" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected exit $expected, got $LSP_EXIT)"
    FAIL=$((FAIL + 1))
  fi
}

assert_output_contains() {
  local desc="$1" pattern="$2"
  if echo "$LSP_STDOUT" | grep -q "$pattern"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (pattern '$pattern' not found)"
    echo "  Output: $LSP_STDOUT"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_stderr_leaks() {
  if echo "$LSP_STDERR" | grep -q "leaked"; then
    echo "  FAIL: memory leaks detected"
    echo "  $LSP_STDERR" | grep "leaked" | head -3
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: no memory leaks"
    PASS=$((PASS + 1))
  fi
}

# --- Test: clean lifecycle ---
echo "Test: initialize -> initialized -> shutdown -> exit"
send_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","method":"initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"shutdown"}' \
  '{"jsonrpc":"2.0","method":"exit"}'

assert_exit "clean shutdown exit code" 0
assert_output_contains "initialize response has server name" '"1z-lsp"'
assert_output_contains "initialize response has capabilities" '"capabilities"'
assert_output_contains "shutdown response has null result" '"result":null'
assert_no_stderr_leaks

# --- Test: exit without shutdown ---
echo "Test: exit without shutdown"
send_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","method":"initialized","params":{}}' \
  '{"jsonrpc":"2.0","method":"exit"}'

assert_exit "dirty exit returns 1" 1

# --- Test: request before initialize ---
echo "Test: request before initialize"
send_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{}}' \
  '{"jsonrpc":"2.0","id":10,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":11,"method":"shutdown"}' \
  '{"jsonrpc":"2.0","method":"exit"}'

assert_exit "recovers after early request" 0
assert_output_contains "returns server_not_initialized error" '"code":-32002'

# --- Test: unknown method after initialize ---
echo "Test: unknown method"
send_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","method":"initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":5,"method":"nonexistent/method","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"shutdown"}' \
  '{"jsonrpc":"2.0","method":"exit"}'

assert_exit "clean exit after unknown method" 0
assert_output_contains "returns method_not_found error" '"code":-32601'

# --- Test: double initialize ---
echo "Test: double initialize"
send_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"shutdown"}' \
  '{"jsonrpc":"2.0","method":"exit"}'

assert_exit "clean exit after double initialize" 0
assert_output_contains "rejects second initialize" '"Server already initialized"'

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
