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

/// Try to dispatch a generic word via the dispatch table.
///
/// Unlike the tryDispatchBinary / tryDispatchUnary versions used by native ops,
/// this does not restrict dispatch to user types. Generic words may have methods
/// registered for any type combination, including native types.
///
/// Tries binary dispatch first (if stack depth >= 2), then unary.
/// Returns true if dispatched, false if not.
pub fn tryDispatchGeneric(ctx: *Context, word_name: []const u8) !bool {
    if (ctx.stack.depth() >= 2) {
        const a = try ctx.stack.peekN(1);
        const b = try ctx.stack.peek();
        const a_name = dispatch_mod.dispatchTypeName(a);
        const b_name = dispatch_mod.dispatchTypeName(b);
        if (ctx.dispatch.lookupBinary(word_name, a_name, b_name)) |entry| {
            try ctx.executeQuotation(.{ .instructions = entry.body });
            return true;
        }
    }

    if (ctx.stack.depth() >= 1) {
        const a = try ctx.stack.peek();
        const a_name = dispatch_mod.dispatchTypeName(a);
        if (ctx.dispatch.lookupUnary(word_name, a_name)) |entry| {
            try ctx.executeQuotation(.{ .instructions = entry.body });
            return true;
        }
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

test "tryDispatchGeneric returns false with empty stack" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const result = try tryDispatchGeneric(&ctx, "serialize");
    try std.testing.expect(!result);
}

test "tryDispatchGeneric returns false when no method registered" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 42 });

    const result = try tryDispatchGeneric(&ctx, "serialize");
    try std.testing.expect(!result);

    // Stack should be unchanged
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
}

test "tryDispatchGeneric dispatches unary method for native type" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Register a unary method for "integer" type
    const body = &[_]@import("../value.zig").Instruction{
        .{ .op = .{ .call_word = "to-string" }, .line = 0 },
    };
    try ctx.dispatch.register(
        .{ .word_name = "serialize", .type_a = "integer", .type_b = dispatch_mod.unary_sentinel },
        .{ .body = body },
        false,
    );

    try ctx.stack.push(.{ .integer = 42 });

    const result = try tryDispatchGeneric(&ctx, "serialize");
    try std.testing.expect(result);

    // Method should have executed (to-string converts integer to string)
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const top = try ctx.stack.pop();
    try std.testing.expectEqualStrings("42", top.string);
}

test "tryDispatchGeneric tries binary before unary" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Register both binary and unary methods
    const binary_body = &[_]@import("../value.zig").Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const unary_body = &[_]@import("../value.zig").Instruction{
        .{ .op = .{ .call_word = "to-string" }, .line = 0 },
    };

    try ctx.dispatch.register(
        .{ .word_name = "combine", .type_a = "integer", .type_b = "integer" },
        .{ .body = binary_body },
        false,
    );
    try ctx.dispatch.register(
        .{ .word_name = "combine", .type_a = "integer", .type_b = dispatch_mod.unary_sentinel },
        .{ .body = unary_body },
        false,
    );

    // With two integers on stack, binary should be chosen
    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 32 });

    const result = try tryDispatchGeneric(&ctx, "combine");
    try std.testing.expect(result);

    // Binary method (addition) should have run
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const top = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 42), top.integer);
}
