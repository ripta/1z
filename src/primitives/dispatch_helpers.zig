const std = @import("std");
const Context = @import("../context.zig").Context;
const dispatch_mod = @import("../dispatch.zig");

/// Try to dispatch a binary operation via the dispatch table.
///
/// Peeks at the top two stack values, checks if either is a user type
/// (tagged or struct_instance), and if so, looks up a registered method.
/// If found, executes the method body; operands remain on stack for the
/// body to consume. Returns true if dispatched, false if not.
pub fn tryDispatchBinary(ctx: *Context, word_name: []const u8) !bool {
    if (ctx.stack.depth() < 2) return false;

    const a = try ctx.stack.peekN(1);
    const b = try ctx.stack.peek();
    if (!dispatch_mod.isUserType(a) and !dispatch_mod.isUserType(b)) return false;

    const a_name = dispatch_mod.dispatchTypeName(a);
    const b_name = dispatch_mod.dispatchTypeName(b);
    if (ctx.dispatch.lookupBinary(word_name, a_name, b_name)) |entry| {
        try ctx.executeQuotation(.{ .instructions = entry.body });
        return true;
    }
    return false;
}

/// Try to dispatch a unary operation via the dispatch table.
///
/// Peeks at the top stack value, checks if it's a user type (tagged or
/// struct_instance), and if so, looks up a registered method. If found,
/// executes the method body; operand remains on stack. Returns true if
/// dispatched, false if not.
pub fn tryDispatchUnary(ctx: *Context, word_name: []const u8) !bool {
    if (ctx.stack.depth() < 1) return false;

    const a = try ctx.stack.peek();
    if (!dispatch_mod.isUserType(a)) return false;

    const a_name = dispatch_mod.dispatchTypeName(a);
    if (ctx.dispatch.lookupUnary(word_name, a_name)) |entry| {
        try ctx.executeQuotation(.{ .instructions = entry.body });
        return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "tryDispatchBinary returns false with empty stack" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const result = try tryDispatchBinary(&ctx, "+");
    try std.testing.expect(!result);
}

test "tryDispatchBinary returns false with only native types" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });

    const result = try tryDispatchBinary(&ctx, "+");
    try std.testing.expect(!result);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
}

test "tryDispatchUnary returns false with empty stack" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const result = try tryDispatchUnary(&ctx, "serialize");
    try std.testing.expect(!result);
}

test "tryDispatchUnary returns false with native type" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 42 });

    const result = try tryDispatchUnary(&ctx, "serialize");
    try std.testing.expect(!result);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
}
