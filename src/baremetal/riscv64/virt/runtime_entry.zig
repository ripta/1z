const uart = @import("uart.zig");
const shutdown = @import("shutdown.zig");

// The AOT driver emits `int kernel_main(void)` for freestanding targets; the runtime startup,
// image load, dispatch registration, and entry-word run all happen inside it.
extern fn kernel_main() c_int;
extern fn onez_init() ?*anyopaque;
extern fn onez_freestanding_init_output(
    ctx: ?*anyopaque,
    writer_ctx: ?*anyopaque,
    writer: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) usize,
) c_int;

// The bare-metal output writer: every byte 1z's `print` produces lands here and is poked into
// the NS16550 transmit register. Registered as the runtime's output writer so the in-runtime
// output stream routes through it; flush is the runtime's own no-op. Exported with a stable
// name so it is visible in the linked image's symbol table.
pub export fn onez_virt_uart_writer(_: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) usize {
    uart.writeAll(ptr[0..len]);
    return len;
}

// Boot lands here from boot.S once the stack is set up. Bring the runtime up, point its output
// at the UART, run the compiled program, and report the result to QEMU via the sifive_test device.
pub export fn onez_baremetal_main() noreturn {
    const ctx = onez_init() orelse shutdown.fail(1);
    if (onez_freestanding_init_output(ctx, null, onez_virt_uart_writer) != 0) {
        shutdown.fail(2);
    }

    const status = kernel_main();
    if (status == 0) {
        shutdown.pass();
    } else {
        shutdown.fail(@intCast(status & 0xffff));
    }
}
