pub const uart = @import("uart.zig");
pub const shutdown = @import("shutdown.zig");

pub export fn onez_virt_uart_write(ptr: [*]const u8, len: usize) void {
    uart.writeAll(ptr[0..len]);
}

pub export fn onez_virt_shutdown_pass() noreturn {
    shutdown.pass();
}

pub export fn onez_virt_shutdown_fail(code: u16) noreturn {
    shutdown.fail(code);
}
