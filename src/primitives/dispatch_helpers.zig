const std = @import("std");
const Context = @import("../context.zig").Context;
const dispatch_mod = @import("../dispatch.zig");
const pic_mod = @import("../pic.zig");
const PolymorphicCache = pic_mod.PolymorphicCache;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;

/// Execute a dispatch entry body, handling both quotation and native_fn variants.
pub fn executeDispatchBody(ctx: *Context, body: dispatch_mod.DispatchBody) !void {
    switch (body) {
        .quotation => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
        .native_fn => |func| try func(ctx),
        .host_callback => |host| {
            const rc = host.callback(host.handle, host.user_data);
            if (rc != 0) return error.HostCallbackFailed;
        },
    }
}

/// Auto-unwrap the top stack operand from a tagged value to its inner value.
fn autoUnwrapTopOperand(ctx: *Context) !void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(val.tagged.inner.*);
}

/// Auto-unwrap binary operands on the stack. The top of stack is b (peek),
/// the next is a (peekN(1)). Pop both, push back unwrapped versions in order.
fn autoUnwrapBinaryOperands(ctx: *Context, unwrap_a: bool, unwrap_b: bool) !void {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    const new_a = if (unwrap_a) a.tagged.inner.* else a;
    const new_b = if (unwrap_b) b.tagged.inner.* else b;
    try ctx.stack.push(new_a);
    try ctx.stack.push(new_b);
}

/// Look up a binary dispatch entry, trying enum-level fallback.
///
/// Precedence:
/// 1. Exact variant type names (includes wildcard expansion)
/// 2. a's enum name with b's variant name
/// 3. a's variant name with b's enum name
/// 4. Both enum names
const AutoUnwrap = struct {
    entry: dispatch_mod.DispatchEntry,
    unwrap_a: bool,
    unwrap_b: bool,
};

fn lookupBinaryWithFallback(ctx: *Context, dispatch_id: u32, a: Value, b: Value) ?AutoUnwrap {
    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
    const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
    if (ctx.lookupBinaryDispatch(dispatch_id, a_type, b_type)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };

    const a_enum = dispatch_mod.dispatchEnumTypeValue(a);
    const b_enum = dispatch_mod.dispatchEnumTypeValue(b);
    if (a_enum) |ae| {
        if (ctx.lookupBinaryDispatch(dispatch_id, ae.descriptor.?, b_type)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };
    }
    if (b_enum) |be| {
        if (ctx.lookupBinaryDispatch(dispatch_id, a_type, be.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };
    }

    if (a_enum) |ae| {
        if (b_enum) |be| {
            if (ctx.lookupBinaryDispatch(dispatch_id, ae.descriptor.?, be.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };
        }
    }

    const a_base = dispatch_mod.dispatchBaseTypeValue(a);
    const b_base = dispatch_mod.dispatchBaseTypeValue(b);
    if (a_base) |ab| {
        if (ctx.lookupBinaryDispatch(dispatch_id, ab.descriptor.?, b_type)) |entry| return .{ .entry = entry, .unwrap_a = true, .unwrap_b = false };
    }
    if (b_base) |bb| {
        if (ctx.lookupBinaryDispatch(dispatch_id, a_type, bb.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = true };
    }
    if (a_base) |ab| {
        if (b_base) |bb| {
            if (ctx.lookupBinaryDispatch(dispatch_id, ab.descriptor.?, bb.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = true, .unwrap_b = true };
        }
    }

    return null;
}

/// Look up a unary dispatch entry, trying enum-level fallback.
///
/// Precedence:
/// 1. Exact variant type name (includes wildcard expansion)
/// 2. Enum name fallback
fn lookupUnaryWithFallback(ctx: *Context, dispatch_id: u32, a: Value) ?AutoUnwrap {
    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
    if (ctx.lookupUnaryDispatch(dispatch_id, a_type)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };

    if (dispatch_mod.dispatchEnumTypeValue(a)) |ae| {
        if (ctx.lookupUnaryDispatch(dispatch_id, ae.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };
    }

    if (dispatch_mod.dispatchBaseTypeValue(a)) |ab| {
        if (ctx.lookupUnaryDispatch(dispatch_id, ab.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = true, .unwrap_b = false };
    }

    return null;
}

/// Try to dispatch a binary operation via the dispatch table.
///
/// Peeks at the top two stack values and looks up a registered method.
/// If found, executes the method body; operands remain on stack for the
/// body to consume. Returns true if dispatched, false if not.
///
/// Each native that supports dispatch must call this function explicitly.
/// Only type-switching natives that branch on operand types (arithmetic,
/// comparison, inspect, sequence ops, etc.) should opt in.
///
/// Type-agnostic natives (dup, drop, swap, etc.) must not dispatch.
///
/// See also notes in the implementation of `nativeDefineMethod`.
pub fn tryDispatchBinary(ctx: *Context, word_name: []const u8) !bool {
    const dispatch_id = ctx.resolveDispatchId(word_name) orelse return false;
    return tryDispatchBinaryById(ctx, dispatch_id);
}

fn tryDispatchBinaryById(ctx: *Context, dispatch_id: u32) !bool {
    if (ctx.stack.depth() < 2) return false;

    const a = try ctx.stack.peekN(1);
    const b = try ctx.stack.peek();

    if (ctx.current_pic_entry) |cache| {
        if (!cache.megamorphic) {
            if (cache.count > 0 and cache.generation != ctx.dispatch.generation) {
                cache.count = 0;
            } else if (cache.count > 0) {
                const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
                if (cache.lookup(a_type, b_type)) |entry| {
                    if (entry.unwrap_a or entry.unwrap_b) {
                        try autoUnwrapBinaryOperands(ctx, entry.unwrap_a, entry.unwrap_b);
                    }
                    try executeDispatchBody(ctx, entry.entry.body);
                    return true;
                }
            }
        }
    }

    if (lookupBinaryWithFallback(ctx, dispatch_id, a, b)) |result| {
        if (ctx.current_pic_entry) |cache| {
            if (!cache.megamorphic) {
                const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
                cache.insert(.{
                    .type_a = a_type,
                    .type_b = b_type,
                    .entry = result.entry,
                    .unwrap_a = result.unwrap_a,
                    .unwrap_b = result.unwrap_b,
                });
                cache.generation = ctx.dispatch.generation;
            }
        }
        if (result.unwrap_a or result.unwrap_b) {
            try autoUnwrapBinaryOperands(ctx, result.unwrap_a, result.unwrap_b);
        }
        try executeDispatchBody(ctx, result.entry.body);
        return true;
    }

    return false;
}

/// Try to dispatch a unary operation via the dispatch table.
///
/// Peeks at the top stack value and looks up a registered method. If found,
/// executes the method body; operand remains on stack. Returns true if
/// dispatched, false if not.
///
/// Same opt-in rules as tryDispatchBinary: each native that supports
/// dispatch must call this explicitly.
pub fn tryDispatchUnary(ctx: *Context, word_name: []const u8) !bool {
    const dispatch_id = ctx.resolveDispatchId(word_name) orelse return false;
    return tryDispatchUnaryById(ctx, dispatch_id);
}

fn tryDispatchUnaryById(ctx: *Context, dispatch_id: u32) !bool {
    if (ctx.stack.depth() < 1) return false;

    const a = try ctx.stack.peek();

    if (ctx.current_pic_entry) |cache| {
        if (!cache.megamorphic) {
            if (cache.count > 0 and cache.generation != ctx.dispatch.generation) {
                cache.count = 0;
            } else if (cache.count > 0) {
                const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                if (cache.lookup(a_type, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| {
                    if (entry.unwrap_a) {
                        try autoUnwrapTopOperand(ctx);
                    }
                    try executeDispatchBody(ctx, entry.entry.body);
                    return true;
                }
            }
        }
    }

    if (lookupUnaryWithFallback(ctx, dispatch_id, a)) |result| {
        if (ctx.current_pic_entry) |cache| {
            if (!cache.megamorphic) {
                const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                cache.insert(.{
                    .type_a = a_type,
                    .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
                    .entry = result.entry,
                    .unwrap_a = result.unwrap_a,
                    .unwrap_b = false,
                });
                cache.generation = ctx.dispatch.generation;
            }
        }
        if (result.unwrap_a) {
            try autoUnwrapTopOperand(ctx);
        }
        try executeDispatchBody(ctx, result.entry.body);
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
    const cmp_id = ctx.resolveDispatchId("cmp") orelse return false;

    const a = try ctx.stack.peekN(1);
    const b = try ctx.stack.peek();
    if (lookupBinaryWithFallback(ctx, cmp_id, a, b)) |result| {
        if (result.unwrap_a or result.unwrap_b) {
            try autoUnwrapBinaryOperands(ctx, result.unwrap_a, result.unwrap_b);
        }
        try executeDispatchBody(ctx, result.entry.body);
        const cmp_result = try ctx.stack.pop();
        const boolean = switch (cmp_result) {
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

/// Try to dispatch a generic word via the dispatch table.
///
/// Unlike the tryDispatchBinary / tryDispatchUnary versions used by native ops,
/// this does not restrict dispatch to user types. Generic words may have methods
/// registered for any type combination, including native types.
///
/// Tries binary dispatch first (if stack depth >= 2), then unary.
/// Returns true if dispatched, false if not.
pub fn tryDispatchGeneric(ctx: *Context, word_name: []const u8) !bool {
    const dispatch_id = ctx.resolveDispatchId(word_name) orelse return false;
    return tryDispatchGenericById(ctx, dispatch_id, null);
}

/// Convenience wrapper: resolve word name, then dispatch with PIC.
pub fn tryDispatchGenericWithPic(ctx: *Context, word_name: []const u8, pic: ?*PolymorphicCache) !bool {
    const dispatch_id = ctx.resolveDispatchId(word_name) orelse return false;
    return tryDispatchGenericById(ctx, dispatch_id, pic);
}

/// Try to dispatch a generic word by dispatch ID, with optional PIC.
///
/// Used by the execution loop where the WordDefinition (and its dispatch_id)
/// is already in hand, avoiding an extra dictionary lookup.
pub fn tryDispatchGenericById(ctx: *Context, dispatch_id: u32, pic: ?*PolymorphicCache) !bool {
    if (pic) |cache| {
        if (!cache.megamorphic) {
            if (cache.count > 0 and cache.generation != ctx.dispatch.generation) {
                cache.count = 0;
            } else if (cache.count > 0) {
                if (ctx.stack.depth() >= 2) {
                    const a = try ctx.stack.peekN(1);
                    const b = try ctx.stack.peek();
                    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                    const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
                    if (cache.lookup(a_type, b_type)) |entry| {
                        if (entry.unwrap_a or entry.unwrap_b) {
                            try autoUnwrapBinaryOperands(ctx, entry.unwrap_a, entry.unwrap_b);
                        }
                        try executeDispatchBody(ctx, entry.entry.body);
                        return true;
                    }
                } else if (ctx.stack.depth() >= 1) {
                    const a = try ctx.stack.peek();
                    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                    if (cache.lookup(a_type, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| {
                        if (entry.unwrap_a) {
                            try autoUnwrapTopOperand(ctx);
                        }
                        try executeDispatchBody(ctx, entry.entry.body);
                        return true;
                    }
                }
            }
        }
    }

    if (ctx.stack.depth() >= 2) {
        const a = try ctx.stack.peekN(1);
        const b = try ctx.stack.peek();
        if (lookupBinaryWithFallback(ctx, dispatch_id, a, b)) |result| {
            if (pic) |cache| {
                if (!cache.megamorphic) {
                    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                    const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
                    cache.insert(.{
                        .type_a = a_type,
                        .type_b = b_type,
                        .entry = result.entry,
                        .unwrap_a = result.unwrap_a,
                        .unwrap_b = result.unwrap_b,
                    });
                    cache.generation = ctx.dispatch.generation;
                }
            }
            if (result.unwrap_a or result.unwrap_b) {
                try autoUnwrapBinaryOperands(ctx, result.unwrap_a, result.unwrap_b);
            }
            try executeDispatchBody(ctx, result.entry.body);
            return true;
        }
    }

    if (ctx.stack.depth() >= 1) {
        const a = try ctx.stack.peek();
        if (lookupUnaryWithFallback(ctx, dispatch_id, a)) |result| {
            if (pic) |cache| {
                if (!cache.megamorphic) {
                    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                    cache.insert(.{
                        .type_a = a_type,
                        .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
                        .entry = result.entry,
                        .unwrap_a = result.unwrap_a,
                        .unwrap_b = false,
                    });
                    cache.generation = ctx.dispatch.generation;
                }
            }
            if (result.unwrap_a) {
                try autoUnwrapTopOperand(ctx);
            }
            try executeDispatchBody(ctx, result.entry.body);
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

test "tryDispatchBinary returns false when no method registered" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 2 });

    const result = try tryDispatchBinary(&ctx, "no-such-word");
    try std.testing.expect(!result);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
}

test "tryDispatchUnary returns false with empty stack" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const result = try tryDispatchUnary(&ctx, "serialize");
    try std.testing.expect(!result);
}

test "tryDispatchUnary returns false when no method registered" {
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

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    // Register a unary method for "fixnum" type
    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    const dispatch_id: u32 = 1;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    try ctx.stack.push(.{ .fixnum = 42 });

    const result = try tryDispatchGenericById(&ctx, dispatch_id, null);
    try std.testing.expect(result);

    // Method should have executed (inspect converts fixnum to string)
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const top = try ctx.stack.pop();
    try std.testing.expectEqualStrings("42", top.string);
}

test "tryDispatchGeneric tries binary before unary" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    // Register both binary and unary methods
    const binary_body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const unary_body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };

    const dispatch_id: u32 = 2;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = binary_body } },
        false,
    );
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = unary_body } },
        false,
    );

    // With two fixnums on stack, binary should be chosen
    try ctx.stack.push(.{ .fixnum = 10 });
    try ctx.stack.push(.{ .fixnum = 32 });

    const result = try tryDispatchGenericById(&ctx, dispatch_id, null);
    try std.testing.expect(result);

    // Binary method (addition) should have run
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const top = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 42), top.fixnum);
}

test "tryDispatchGenericWithPic populates cache on miss" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const dispatch_id: u32 = 3;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    var cache = PolymorphicCache{};

    try ctx.stack.push(.{ .fixnum = 3 });
    try ctx.stack.push(.{ .fixnum = 4 });

    const result = try tryDispatchGenericById(&ctx, dispatch_id, &cache);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(i64, 7), (try ctx.stack.pop()).fixnum);

    // Cache should now be populated
    try std.testing.expectEqual(@as(u8, 1), cache.count);
    try std.testing.expectEqual(fixnum_tv.descriptor.?, cache.entries[0].type_a);
    try std.testing.expectEqual(fixnum_tv.descriptor.?, cache.entries[0].type_b);
    try std.testing.expectEqual(ctx.dispatch.generation, cache.generation);
}

test "tryDispatchGenericWithPic hits cache on matching types" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const dispatch_id: u32 = 3;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    var cache = PolymorphicCache{};

    // First call: populates cache
    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 2 });
    _ = try tryDispatchGenericById(&ctx, dispatch_id, &cache);
    _ = try ctx.stack.pop();

    // Second call: should hit cache (same types)
    try ctx.stack.push(.{ .fixnum = 10 });
    try ctx.stack.push(.{ .fixnum = 20 });
    const result = try tryDispatchGenericById(&ctx, dispatch_id, &cache);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(i64, 30), (try ctx.stack.pop()).fixnum);
}

test "tryDispatchGenericWithPic invalidates on generation change" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const add_id: u32 = 3;
    try ctx.dispatch.register(
        .{ .dispatch_id = add_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    var cache = PolymorphicCache{};

    // Populate cache
    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 2 });
    _ = try tryDispatchGenericById(&ctx, add_id, &cache);
    _ = try ctx.stack.pop();

    const gen_before = cache.generation;

    // Register a new method, bumping generation
    const body2 = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    try ctx.dispatch.register(
        .{ .dispatch_id = 4, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body2 } },
        false,
    );

    try std.testing.expect(ctx.dispatch.generation > gen_before);

    // Cache should be stale: generation no longer matches
    try ctx.stack.push(.{ .fixnum = 5 });
    try ctx.stack.push(.{ .fixnum = 6 });
    const result = try tryDispatchGenericById(&ctx, add_id, &cache);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(i64, 11), (try ctx.stack.pop()).fixnum);

    // Cache should be re-populated with new generation
    try std.testing.expectEqual(ctx.dispatch.generation, cache.generation);
}

test "tryDispatchGenericWithPic with null pic_entry falls back to full lookup" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const dispatch_id: u32 = 3;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    try ctx.stack.push(.{ .fixnum = 10 });
    try ctx.stack.push(.{ .fixnum = 20 });

    const result = try tryDispatchGenericById(&ctx, dispatch_id, null);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(i64, 30), (try ctx.stack.pop()).fixnum);
}

test "tryDispatchGenericWithPic caches unary dispatch" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    const dispatch_id: u32 = 4;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    var cache = PolymorphicCache{};

    try ctx.stack.push(.{ .fixnum = 42 });
    const result = try tryDispatchGenericById(&ctx, dispatch_id, &cache);
    try std.testing.expect(result);
    try std.testing.expectEqualStrings("42", (try ctx.stack.pop()).string);

    // Cache should record unary dispatch (type_b is unary_sentinel)
    try std.testing.expectEqual(@as(u8, 1), cache.count);
    try std.testing.expectEqual(fixnum_tv.descriptor.?, cache.entries[0].type_a);
    try std.testing.expectEqual(ctx.getDispatchUnarySentinel().descriptor.?, cache.entries[0].type_b);
}
