const std = @import("std");
const Context = @import("context.zig").Context;
const StatementProcessor = @import("statement.zig").StatementProcessor;

const OnezHandle = struct {
    gpa: *std.heap.GeneralPurposeAllocator(.{}),
    ctx: *Context,
    last_error: ?[]const u8 = null,
};

const page = std.heap.page_allocator;

export fn onez_init() ?*anyopaque {
    const gpa = page.create(std.heap.GeneralPurposeAllocator(.{})) catch return null;
    gpa.* = .{};
    const allocator = gpa.allocator();

    const ctx = allocator.create(Context) catch return null;
    ctx.* = Context.init(allocator);

    // stdlib relative to the library binary for now
    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExeDirPath(&self_exe_buf)) |exe_dir| {
        const lib_path = std.fs.path.join(ctx.quotationAllocator(), &.{ exe_dir, "../lib" }) catch null;
        if (lib_path) |lp| {
            var real_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fs.cwd().realpath(lp, &real_buf)) |real| {
                ctx.stdlib_path = ctx.quotationAllocator().dupe(u8, real) catch null;
            } else |_| {}
        }
    } else |_| {}

    ctx.loadPrelude(null) catch return null;

    const handle = page.create(OnezHandle) catch return null;
    handle.* = .{
        .gpa = gpa,
        .ctx = ctx,
    };
    return handle;
}

export fn onez_deinit(ptr: ?*anyopaque) void {
    const handle = castHandle(ptr) orelse return;
    const allocator = handle.gpa.allocator();

    if (handle.last_error) |msg| {
        allocator.free(msg);
    }

    handle.ctx.deinit();
    allocator.destroy(handle.ctx);
    _ = handle.gpa.deinit();
    page.destroy(handle.gpa);
    page.destroy(handle);
}

export fn onez_eval(ptr: ?*anyopaque, code: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return -1;
    const ctx = handle.ctx;
    const alloc = ctx.quotationAllocator();
    const source = code[0..len];

    ctx.clearExecutionDetails();
    clearLastError(handle);

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..end];
        start = end + 1;

        switch (processor.feedLine(alloc, line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                captureError(handle, err);
                return 1;
            },
            .complete => |instrs| {
                if (instrs.len > 0) {
                    ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                        captureError(handle, err);
                        return 1;
                    };
                }
                processor.reset();
            },
        }
    }

    switch (processor.flush(alloc, ctx)) {
        .needs_more_input => {},
        .parse_error => |err| {
            captureError(handle, err);
            return 1;
        },
        .complete => |instrs| {
            if (instrs.len > 0) {
                ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                    captureError(handle, err);
                    return 1;
                };
            }
        },
    }

    return 0;
}

fn castHandle(ptr: ?*anyopaque) ?*OnezHandle {
    const p = ptr orelse return null;
    return @ptrCast(@alignCast(p));
}

fn clearLastError(handle: *OnezHandle) void {
    if (handle.last_error) |msg| {
        handle.gpa.allocator().free(msg);
        handle.last_error = null;
    }
}

fn captureError(handle: *OnezHandle, err: anyerror) void {
    clearLastError(handle);

    const details = handle.ctx.error_details.items;
    if (details.len > 0) {
        const detail = details[0];
        handle.last_error = std.fmt.allocPrint(
            handle.gpa.allocator(),
            "{s}:{d}: error '{s}'",
            .{ detail.source, detail.line, detail.error_type },
        ) catch null;
    } else {
        handle.last_error = std.fmt.allocPrint(
            handle.gpa.allocator(),
            "{s}",
            .{@errorName(err)},
        ) catch null;
    }
}

test "init/eval/deinit round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);

    const rc = onez_eval(handle_ptr, "1 2 +", 5);
    try std.testing.expectEqual(@as(c_int, 0), rc);

    onez_deinit(handle_ptr);
}

test "eval error returns 1" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const rc = onez_eval(handle_ptr, "1 0 /", 5);
    try std.testing.expectEqual(@as(c_int, 1), rc);

    const handle = castHandle(handle_ptr).?;
    try std.testing.expect(handle.last_error != null);
}

test "null handle returns error" {
    try std.testing.expectEqual(@as(c_int, -1), onez_eval(null, "", 0));
    onez_deinit(null); // should not crash!
}
