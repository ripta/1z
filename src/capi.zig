const std = @import("std");
const Context = @import("context.zig").Context;
const StatementProcessor = @import("statement.zig").StatementProcessor;
const Value = @import("value.zig").Value;

const OnezHandle = struct {
    gpa: *std.heap.GeneralPurposeAllocator(.{}),
    ctx: *Context,
    last_error: ?[:0]const u8 = null,
};

const page = std.heap.page_allocator;

// Type constants for onez_stack_type return values.
pub const ONEZ_TYPE_UNKNOWN: c_int = 0;
pub const ONEZ_TYPE_FIXNUM: c_int = 1;
pub const ONEZ_TYPE_FLOAT: c_int = 2;
pub const ONEZ_TYPE_BOOLEAN: c_int = 3;
pub const ONEZ_TYPE_STRING: c_int = 4;
pub const ONEZ_TYPE_SYMBOL: c_int = 5;
pub const ONEZ_TYPE_ARRAY: c_int = 6;
pub const ONEZ_TYPE_QUOTATION: c_int = 7;
pub const ONEZ_TYPE_HASH: c_int = 8;
pub const ONEZ_TYPE_VECTOR: c_int = 9;
pub const ONEZ_TYPE_BYTE_ARRAY: c_int = 10;
pub const ONEZ_TYPE_SET: c_int = 11;
pub const ONEZ_TYPE_MUTABLE_MAP: c_int = 12;
pub const ONEZ_TYPE_STREAM: c_int = 13;
pub const ONEZ_TYPE_RESOURCE: c_int = 14;
pub const ONEZ_TYPE_TAGGED: c_int = 15;
pub const ONEZ_TYPE_ITERATOR: c_int = 16;
pub const ONEZ_TYPE_TYPE_VAL: c_int = 17;
pub const ONEZ_TYPE_UNIT: c_int = 18;

// Error code constants.
pub const ONEZ_OK: c_int = 0;
pub const ONEZ_ERR_NULL_HANDLE: c_int = -1;
pub const ONEZ_ERR_TYPE_MISMATCH: c_int = 1;
pub const ONEZ_ERR_STACK_UNDERFLOW: c_int = 2;
pub const ONEZ_ERR_ALLOC: c_int = 3;

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

    clearLastError(handle);

    handle.ctx.deinit();
    allocator.destroy(handle.ctx);
    _ = handle.gpa.deinit();
    page.destroy(handle.gpa);
    page.destroy(handle);
}

export fn onez_eval(ptr: ?*anyopaque, code: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
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

    return ONEZ_OK;
}

export fn onez_push_int(ptr: ?*anyopaque, value: i64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.stack.push(.{ .fixnum = value }) catch {
        setLastError(handle, "allocation failure pushing int", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_double(ptr: ?*anyopaque, value: f64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.stack.push(.{ .float = value }) catch {
        setLastError(handle, "allocation failure pushing double", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_bool(ptr: ?*anyopaque, value: bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.stack.push(.{ .boolean = value }) catch {
        setLastError(handle, "allocation failure pushing bool", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_string(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying string", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.stack.push(.{ .string = copy }) catch {
        setLastError(handle, "allocation failure pushing string", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_pop_int(ptr: ?*anyopaque, out: *i64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop int from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .fixnum => |v| {
            out.* = v;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected fixnum, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_double(ptr: ?*anyopaque, out: *f64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop double from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .float => |v| {
            out.* = v;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected float, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_bool(ptr: ?*anyopaque, out: *bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop bool from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .boolean => |v| {
            out.* = v;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected boolean, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_string(ptr: ?*anyopaque, out_ptr: *[*]const u8, out_len: *usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop string from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .string => |s| {
            out_ptr.* = s.ptr;
            out_len.* = s.len;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected string, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_stack_depth(ptr: ?*anyopaque) usize {
    const handle = castHandle(ptr) orelse return 0;
    return handle.ctx.stack.depth();
}

export fn onez_stack_type(ptr: ?*anyopaque, index: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.peekN(index) catch return ONEZ_ERR_NULL_HANDLE;
    return valueTypeToInt(val);
}

export fn onez_last_error(ptr: ?*anyopaque) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.last_error) |err| return err.ptr else return null;
}

export fn onez_set_stdlib_path(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying stdlib path", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.stdlib_path = copy;
    return ONEZ_OK;
}

fn castHandle(ptr: ?*anyopaque) ?*OnezHandle {
    const p = ptr orelse return null;
    return @ptrCast(@alignCast(p));
}

fn clearLastError(handle: *OnezHandle) void {
    if (handle.last_error) |msg| {
        handle.gpa.allocator().free(@as([]const u8, msg.ptr[0 .. msg.len + 1]));
        handle.last_error = null;
    }
}

fn setLastError(handle: *OnezHandle, comptime fmt: []const u8, args: anytype) void {
    clearLastError(handle);
    handle.last_error = allocPrintZ(handle.gpa.allocator(), fmt, args) catch null;
}

fn captureError(handle: *OnezHandle, err: anyerror) void {
    clearLastError(handle);

    const details = handle.ctx.error_details.items;
    if (details.len > 0) {
        const detail = details[0];
        handle.last_error = allocPrintZ(
            handle.gpa.allocator(),
            "{s}:{d}: error '{s}'",
            .{ detail.source, detail.line, detail.error_type },
        ) catch null;
    } else {
        handle.last_error = allocPrintZ(
            handle.gpa.allocator(),
            "{s}",
            .{@errorName(err)},
        ) catch null;
    }
}

fn allocPrintZ(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const str = try std.fmt.allocPrint(alloc, fmt, args);
    const buf = try alloc.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    alloc.free(str);
    return buf[0..str.len :0];
}

fn valueTypeToInt(val: Value) c_int {
    return switch (val) {
        .fixnum => ONEZ_TYPE_FIXNUM,
        .float => ONEZ_TYPE_FLOAT,
        .boolean => ONEZ_TYPE_BOOLEAN,
        .string => ONEZ_TYPE_STRING,
        .symbol => ONEZ_TYPE_SYMBOL,
        .array => ONEZ_TYPE_ARRAY,
        .quotation => ONEZ_TYPE_QUOTATION,
        .hash => ONEZ_TYPE_HASH,
        .vector => ONEZ_TYPE_VECTOR,
        .byte_array => ONEZ_TYPE_BYTE_ARRAY,
        .set => ONEZ_TYPE_SET,
        .mutable_map => ONEZ_TYPE_MUTABLE_MAP,
        .stream => ONEZ_TYPE_STREAM,
        .resource => ONEZ_TYPE_RESOURCE,
        .tagged => ONEZ_TYPE_TAGGED,
        .iterator => ONEZ_TYPE_ITERATOR,
        .type_val => ONEZ_TYPE_TYPE_VAL,
        .unit => ONEZ_TYPE_UNIT,
        else => ONEZ_TYPE_UNKNOWN,
    };
}

// =============================================================================
// Tests
// =============================================================================

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
    try std.testing.expectEqual(@as(c_int, ONEZ_ERR_NULL_HANDLE), onez_eval(null, "", 0));
    onez_deinit(null); // should not crash!
}

test "push/pop int round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
}

test "push/pop double round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_double(handle_ptr, 3.14));
    var out: f64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_double(handle_ptr, &out));
    try std.testing.expectEqual(@as(f64, 3.14), out);
}

test "push/pop bool round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_bool(handle_ptr, true));
    var out: bool = false;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_bool(handle_ptr, &out));
    try std.testing.expect(out);
}

test "push/pop string round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const input = "hello";
    try std.testing.expectEqual(ONEZ_OK, onez_push_string(handle_ptr, input.ptr, input.len));
    var out_ptr: [*]const u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_string(handle_ptr, &out_ptr, &out_len));
    try std.testing.expectEqual(@as(usize, 5), out_len);
    try std.testing.expectEqualStrings("hello", out_ptr[0..out_len]);
}

test "pop type mismatch preserves stack" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var out: f64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_pop_double(handle_ptr, &out));
    try std.testing.expectEqual(@as(usize, 1), onez_stack_depth(handle_ptr));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expect(handle.last_error != null);
}

test "pop stack underflow" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_STACK_UNDERFLOW, onez_pop_int(handle_ptr, &out));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expect(handle.last_error != null);
}

test "stack depth" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 1));
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 2));
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 3));
    try std.testing.expectEqual(@as(usize, 3), onez_stack_depth(handle_ptr));
}

test "stack type at index" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    try std.testing.expectEqual(ONEZ_OK, onez_push_string(handle_ptr, "hi", 2));

    // index 0 = top = string, index 1 = int
    try std.testing.expectEqual(ONEZ_TYPE_STRING, onez_stack_type(handle_ptr, 0));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_stack_type(handle_ptr, 1));
}

test "last_error null initially, non-null after failure" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expect(onez_last_error(handle_ptr) == null);

    var out: i64 = 0;
    _ = onez_pop_int(handle_ptr, &out);
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "set_stdlib_path updates ctx" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const path = "/custom/stdlib";
    try std.testing.expectEqual(ONEZ_OK, onez_set_stdlib_path(handle_ptr, path.ptr, path.len));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expectEqualStrings("/custom/stdlib", handle.ctx.stdlib_path.?);
}

test "null handle returns appropriate defaults" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_int(null, 42));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_double(null, 3.14));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_bool(null, true));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_string(null, "x", 1));

    var i: i64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_int(null, &i));
    var f: f64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_double(null, &f));
    var b: bool = false;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_bool(null, &b));
    var sp: [*]const u8 = undefined;
    var sl: usize = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_string(null, &sp, &sl));

    try std.testing.expectEqual(@as(usize, 0), onez_stack_depth(null));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_stack_type(null, 0));
    try std.testing.expect(onez_last_error(null) == null);
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_set_stdlib_path(null, "x", 1));
}
