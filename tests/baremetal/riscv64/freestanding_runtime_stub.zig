const platform = @import("virt-platform");

extern fn onez_init_no_prelude() ?*anyopaque;
extern fn onez_last_error(ctx: ?*anyopaque) ?[*:0]const u8;
extern fn jitPushString(ctx: usize, str_ptr: usize, str_len: usize) callconv(.c) i32;
extern fn jitNativeWordCall(ctx: usize, word_id: usize, line: usize) callconv(.c) i32;

pub export fn onez_baremetal_main() noreturn {
    const ctx = onez_init_no_prelude() orelse platform.shutdown.fail(1);
    const text = "literal";
    if (jitPushString(@intFromPtr(ctx), @intFromPtr(text.ptr), text.len) != 0) {
        platform.shutdown.fail(2);
    }
    if (jitNativeWordCall(@intFromPtr(ctx), 0, 1) != 2) {
        platform.shutdown.fail(3);
    }
    if (onez_last_error(ctx) == null) {
        platform.shutdown.fail(4);
    }
    platform.shutdown.pass();
}
