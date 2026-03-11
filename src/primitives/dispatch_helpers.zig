const std = @import("std");
const Context = @import("../context.zig").Context;
const dispatch_mod = @import("../dispatch.zig");
const Value = @import("../value.zig").Value;

/// Execute a dispatch entry body, handling both quotation and native_fn variants.
pub fn executeDispatchBody(ctx: *Context, body: dispatch_mod.DispatchBody) !void {
    switch (body) {
        .quotation => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
        .native_fn => |func| try func(ctx),
    }
}

/// Look up a binary dispatch entry, trying enum-level fallback.
///
/// Precedence:
/// 1. Exact variant type names (includes wildcard expansion)
/// 2. a's enum name with b's variant name
/// 3. a's variant name with b's enum name
/// 4. Both enum names
fn lookupBinaryWithFallback(ctx: *Context, word_name: []const u8, a: Value, b: Value) ?dispatch_mod.DispatchEntry {
    const a_type = dispatch_mod.dispatchTypeName(a);
    const b_type = dispatch_mod.dispatchTypeName(b);
    if (ctx.lookupBinaryDispatch(word_name, a_type, b_type)) |entry| return entry;

    const a_enum = dispatch_mod.dispatchEnumName(a);
    const b_enum = dispatch_mod.dispatchEnumName(b);
    if (a_enum) |ae| {
        if (ctx.lookupBinaryDispatch(word_name, ae, b_type)) |entry| return entry;
    }
    if (b_enum) |be| {
        if (ctx.lookupBinaryDispatch(word_name, a_type, be)) |entry| return entry;
    }

    if (a_enum) |ae| {
        if (b_enum) |be| {
            if (ctx.lookupBinaryDispatch(word_name, ae, be)) |entry| return entry;
        }
    }

    return null;
}

/// Look up a unary dispatch entry, trying enum-level fallback.
///
/// Precedence:
/// 1. Exact variant type name (includes wildcard expansion)
/// 2. Enum name fallback
fn lookupUnaryWithFallback(ctx: *Context, word_name: []const u8, a: Value) ?dispatch_mod.DispatchEntry {
    const a_type = dispatch_mod.dispatchTypeName(a);
    if (ctx.lookupUnaryDispatch(word_name, a_type)) |entry| return entry;

    if (dispatch_mod.dispatchEnumName(a)) |ae| {
        if (ctx.lookupUnaryDispatch(word_name, ae)) |entry| return entry;
    }

    return null;
}

/// Try to dispatch a binary operation via the dispatch table.
///
/// Peeks at the top two stack values, checks if either is a user type
/// (tagged or struct_instance), and if so, looks up a registered method.
/// If found, executes the method body; operands remain on stack for the
/// body to consume. Returns true if dispatched, false if not.
///
/// Each native that supports user-type dispatch must call this function
/// explicitly. Only type-switching natives that branch on operand types
/// (arithmetic, comparison, inspect, sequence ops, etc.) should opt in.
///
/// Type-agnostic natives (dup, drop, swap, etc.) must not dispatch.
///
/// See also notes in the implementation of `nativeDefineMethod`.
pub fn tryDispatchBinary(ctx: *Context, word_name: []const u8) !bool {
    if (ctx.stack.depth() < 2) return false;

    const a = try ctx.stack.peekN(1);
    const b = try ctx.stack.peek();
    if (!dispatch_mod.isUserType(a) and !dispatch_mod.isUserType(b)) return false;

    if (lookupBinaryWithFallback(ctx, word_name, a, b)) |entry| {
        try executeDispatchBody(ctx, entry.body);
        return true;
    }

    return false;
}

/// Like tryDispatchBinary, but without the isUserType guard.
///
/// Needed when a native operator has dispatch methods registered for native
/// type pairs (e.g., `/` with fixnum/fixnum methods registered by the ratio
/// library). Most operators should continue using tryDispatchBinary; only
/// operators that need native-to-native dispatch should use this variant.
pub fn tryDispatchBinaryAny(ctx: *Context, word_name: []const u8) !bool {
    if (ctx.stack.depth() < 2) return false;

    const a = try ctx.stack.peekN(1);
    const b = try ctx.stack.peek();

    if (lookupBinaryWithFallback(ctx, word_name, a, b)) |entry| {
        try executeDispatchBody(ctx, entry.body);
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
///
/// Same opt-in rules as tryDispatchBinary: each native that supports
/// user-type dispatch must call this explicitly.
pub fn tryDispatchUnary(ctx: *Context, word_name: []const u8) !bool {
    if (ctx.stack.depth() < 1) return false;

    const a = try ctx.stack.peek();
    if (!dispatch_mod.isUserType(a)) return false;

    if (lookupUnaryWithFallback(ctx, word_name, a)) |entry| {
        try executeDispatchBody(ctx, entry.body);
        return true;
    }
    return false;
}

/// Try to derive a comparison result from a `cmp` dispatch method.
///
/// When a user type has a `cmp` method but no direct `=`/`<`/`>` method,
/// this function dispatches `cmp`, pops the result, and converts it to a
/// boolean based on the requested comparison. Accepts both a raw fixnum
/// (negative/zero/positive) and an ordering enum variant (ordering:lt,
/// ordering:eq, ordering:gt).
///
/// XXX(ripta): This reaches into 1z runtime to look up ordering:* enum variants.
pub fn tryDispatchBinaryViaCmp(ctx: *Context, comptime op: enum { eq, lt, gt }) !bool {
    if (ctx.stack.depth() < 2) return false;

    const a = try ctx.stack.peekN(1);
    const b = try ctx.stack.peek();
    if (!dispatch_mod.isUserType(a) and !dispatch_mod.isUserType(b)) return false;

    if (lookupBinaryWithFallback(ctx, "cmp", a, b)) |entry| {
        try executeDispatchBody(ctx, entry.body);
        const result = try ctx.stack.pop();
        const boolean = switch (result) {
            .fixnum => |cmp_val| switch (op) {
                .eq => cmp_val == 0,
                .lt => cmp_val < 0,
                .gt => cmp_val > 0,
            },
            .tagged => |t| blk: {
                const name = t.tag.name;
                if (std.mem.eql(u8, name, "ordering:lt")) {
                    break :blk op == .lt;
                } else if (std.mem.eql(u8, name, "ordering:eq")) {
                    break :blk op == .eq;
                } else if (std.mem.eql(u8, name, "ordering:gt")) {
                    break :blk op == .gt;
                } else {
                    return error.TypeMismatch;
                }
            },
            else => return error.TypeMismatch,
        };
        try ctx.stack.push(.{ .boolean = boolean });
        return true;
    }

    return false;
}

/// Like tryDispatchUnary, but without the isUserType guard.
///
/// Needed when a native operator has dispatch methods registered for native
/// types (e.g., `abs` with fixnum/bignum/float entries registered at startup).
/// Most operators should continue using tryDispatchUnary; only operators that
/// need native-type dispatch should use this variant.
pub fn tryDispatchUnaryAny(ctx: *Context, word_name: []const u8) !bool {
    if (ctx.stack.depth() < 1) return false;

    const a = try ctx.stack.peek();

    if (lookupUnaryWithFallback(ctx, word_name, a)) |entry| {
        try executeDispatchBody(ctx, entry.body);
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
        if (lookupBinaryWithFallback(ctx, word_name, a, b)) |entry| {
            try executeDispatchBody(ctx, entry.body);
            return true;
        }
    }

    if (ctx.stack.depth() >= 1) {
        const a = try ctx.stack.peek();
        if (lookupUnaryWithFallback(ctx, word_name, a)) |entry| {
            try executeDispatchBody(ctx, entry.body);
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

    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 2 });

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

    try ctx.stack.push(.{ .fixnum = 42 });

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

    try ctx.stack.push(.{ .fixnum = 42 });

    const result = try tryDispatchGeneric(&ctx, "serialize");
    try std.testing.expect(!result);

    // Stack should be unchanged
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
}

test "tryDispatchGeneric dispatches unary method for native type" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Register a unary method for "fixnum" type
    const body = &[_]@import("../value.zig").Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    try ctx.dispatch.register(
        .{ .word_name = "serialize", .type_a = "fixnum", .type_b = dispatch_mod.unary_sentinel },
        .{ .body = .{ .quotation = body } },
        false,
    );

    try ctx.stack.push(.{ .fixnum = 42 });

    const result = try tryDispatchGeneric(&ctx, "serialize");
    try std.testing.expect(result);

    // Method should have executed (inspect converts fixnum to string)
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
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };

    try ctx.dispatch.register(
        .{ .word_name = "combine", .type_a = "fixnum", .type_b = "fixnum" },
        .{ .body = .{ .quotation = binary_body } },
        false,
    );
    try ctx.dispatch.register(
        .{ .word_name = "combine", .type_a = "fixnum", .type_b = dispatch_mod.unary_sentinel },
        .{ .body = .{ .quotation = unary_body } },
        false,
    );

    // With two fixnums on stack, binary should be chosen
    try ctx.stack.push(.{ .fixnum = 10 });
    try ctx.stack.push(.{ .fixnum = 32 });

    const result = try tryDispatchGeneric(&ctx, "combine");
    try std.testing.expect(result);

    // Binary method (addition) should have run
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const top = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 42), top.fixnum);
}
