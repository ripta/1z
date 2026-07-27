const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Resource = value_mod.Resource;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const dynamic = @import("../ffi/dynamic.zig");

pub const primitives = [_]Primitive{
    .{ .name = "resource-close", .stack_effect = "resource --", .doc = "Close a resource. Double-close is a no-op.", .func = nativeResourceClose },
    .{ .name = "resource?", .stack_effect = "val -- bool", .doc = "Return t if value is a resource, f otherwise.", .func = nativeResourcePredicate },
    .{ .name = "<test-resource>", .stack_effect = "name -- resource", .doc = "Create a dummy resource with the given type name for testing.", .func = nativeTestResource },
};

/// resource-close ( resource -- )
///
/// An FFI close function may invoke a 1z callback whose error lands in the callback courier; drain
/// it here so it surfaces now instead of leaking into the next unrelated ffi-call. The resource
/// still closes first.
fn nativeResourceClose(ctx: *Context) anyerror!void {
    const r = try helpers.popResource(ctx);
    if (r.closed) return;
    if (r.ptr) |ptr| {
        switch (r.close_fn) {
            .none => {},
            .native => |close_fn| close_fn(ptr),
            .ffi => |ffi_close| dynamic.ffiCloseCall(ffi_close, ptr),
        }
    }
    r.ptr = null;
    r.closed = true;

    if (ctx.callback_error) |err| {
        ctx.callback_error = null;
        if (ctx.callback_error_context) |ectx| {
            helpers.setErrorContext(ctx, "{s}", .{ectx});
            ctx.callback_error_context = null;
        }
        return err;
    }
}

/// resource? ( val -- bool )
fn nativeResourcePredicate(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .boolean = val == .resource });
}

/// <test-resource> ( name -- resource )
fn nativeTestResource(ctx: *Context) anyerror!void {
    const name = try helpers.popString(ctx);
    const alloc = ctx.arena.allocator();
    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = name,
        .ptr = @ptrCast(r),
        .closed = false,
        .close_fn = .none,
    };
    try ctx.stack.push(.{ .resource = r });
}

test "resource-close drains a callback error left by the close call" {
    const std = @import("std");
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var payload: u8 = 0;
    var r = Resource{
        .type_name = "drain-test",
        .ptr = @ptrCast(&payload),
        .closed = false,
        .close_fn = .none,
    };
    try ctx.stack.push(.{ .resource = &r });
    ctx.callback_error = error.UserThrown;

    try std.testing.expectError(error.UserThrown, nativeResourceClose(&ctx));
    try std.testing.expect(ctx.callback_error == null);
    try std.testing.expect(r.closed);
}
