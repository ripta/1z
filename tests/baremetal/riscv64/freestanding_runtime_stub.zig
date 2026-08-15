const platform = @import("virt-platform");

extern fn onez_init_no_prelude() ?*anyopaque;
extern fn onez_freestanding_init_output(ctx: ?*anyopaque, writer_ctx: ?*anyopaque, writer: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) usize) c_int;
extern fn onez_freestanding_write_output(ctx: ?*anyopaque, ptr: [*]const u8, len: usize) c_int;
extern fn onez_last_error(ctx: ?*anyopaque) ?[*:0]const u8;
extern fn jitPushString(ctx: usize, str_ptr: usize, str_len: usize) callconv(.c) i32;
extern fn jitNativeWordCall(ctx: usize, word_id: usize, src_ptr: usize, src_len: usize, line: usize) callconv(.c) i32;

fn platformWrite(_: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) usize {
    platform.uart.writeAll(ptr[0..len]);
    return len;
}

pub export fn onez_baremetal_main() noreturn {
    const ctx = onez_init_no_prelude() orelse platform.shutdown.fail(1);
    if (onez_freestanding_init_output(ctx, null, platformWrite) != 0) {
        platform.shutdown.fail(5);
    }
    const output = "boot";
    if (onez_freestanding_write_output(ctx, output.ptr, output.len) != 0) {
        platform.shutdown.fail(6);
    }
    const text = "literal";
    if (jitPushString(@intFromPtr(ctx), @intFromPtr(text.ptr), text.len) != 0) {
        platform.shutdown.fail(2);
    }
    if (jitNativeWordCall(@intFromPtr(ctx), 0, 0, 0, 1) != 2) {
        platform.shutdown.fail(3);
    }
    if (onez_last_error(ctx) == null) {
        platform.shutdown.fail(4);
    }
    platform.shutdown.pass();
}
