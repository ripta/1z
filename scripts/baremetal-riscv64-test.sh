#!/usr/bin/env bash
#
# Boot an AOT-compiled freestanding riscv64 ELF under QEMU and compare its
# serial output to an expected file.
#
# Usage: scripts/baremetal-riscv64-test.sh <kernel-elf> <expected-serial> [timeout-seconds] [expected-exit]
#
# OpenSBI prints its boot banner to the same UART before handing control to the
# kernel, so the program's output is the tail of the serial stream. The
# comparison slices the tail to the expected line count, which stays correct as
# the firmware banner drifts across QEMU and OpenSBI versions. A clean run shuts
# down via the sifive_test device, which makes QEMU exit 0. A failing run shuts
# down through the same device with its status as QEMU's exit code, so a program
# expected to fail names that code as the fourth argument.

set -euo pipefail

elf="$1"
golden="$2"
timeout_secs="${3:-60}"
expected_rc="${4:-0}"

if ! command -v qemu-system-riscv64 >/dev/null 2>&1; then
    echo "FAIL: qemu-system-riscv64 not found on PATH"
    echo "       Install it to run the bare-metal end-to-end test:"
    echo "         macOS:  brew install qemu"
    echo "         Debian: apt-get install qemu-system-misc"
    exit 1
fi

serial=$(mktemp /tmp/1z-baremetal-serial-XXXXXX)
trap 'rm -f "$serial"' EXIT

rc=0
timeout "$timeout_secs" qemu-system-riscv64 -machine virt -nographic -bios default -kernel "$elf" >"$serial" 2>&1 || rc=$?

if [ "$rc" -ne "$expected_rc" ]; then
    echo "FAIL: QEMU exited with $rc (expected $expected_rc from the sifive_test sentinel)"
    echo "----- captured serial -----"
    cat "$serial"
    exit 1
fi

lines=$(wc -l <"$golden")
if ! tail -n "$lines" "$serial" | diff -u "$golden" - >/dev/null; then
    echo "FAIL: bare-metal serial output does not match $golden"
    echo "----- captured serial -----"
    cat "$serial"
    echo "----- expected tail -------"
    cat "$golden"
    exit 1
fi

echo "PASS: $(basename "$elf") booted under QEMU, serial output matched, exit $expected_rc"
