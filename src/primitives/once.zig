const std = @import("std");

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const OnceCell = value_mod.OnceCell;
const Value = value_mod.Value;

const container_backing = @import("../container_backing.zig");
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "force-once", .func = nativeForceOnce, .stack_effect = "cell -- value" },
};

/// force-once ( cell -- value )
///
/// The whole body of a `once`-marked word: `;` moved the source body into the cell and left a
/// `push_literal` of the cell followed by a call to this.
///
/// The entry is deliberately not `defines_word`. That flag tells the compiled tier a body needs
/// the interpreter's transient lexical frame, and this native opens that frame itself for the
/// body it runs, from `cell.may_define`. Flagging it would make every `once` word's stored body
/// pay a frame push on every read. A `;` inside the source body still reaches `defineWordLocked`
/// with `;` as the in-flight native, so the declaration assertion is satisfied.
fn nativeForceOnce(ctx: *Context) anyerror!void {
    const cell_val = try ctx.stack.pop();
    defer container_backing.releaseValue(cell_val);
    const cell = switch (cell_val) {
        .once_cell => |c| c,
        else => {
            helpers.setTypeMismatchError(ctx, "once-cell", cell_val);
            return error.TypeMismatch;
        },
    };

    if (cell.state == .forced) {
        // `push` takes the reader's reference itself, so the cell keeps the one it published.
        try ctx.stack.push(cell.value.?);
        return;
    }

    const depth_before = ctx.stack.depth();

    const saved_source = ctx.current_source;
    defer ctx.current_source = saved_source;
    ctx.enterBodySource(cell.body.instructions);

    // The source body ran in the word's place before `;` moved it here, so it resolves bare words
    // against the word's module the way the guard standing in for it does. The guard is executing
    // right now, so its own visibility names that module; the source body carries no stamp of its
    // own, because it never reached a push site that would have given it one.
    const defining_module = if (ctx.active_deps_vis) |vis| vis.defining_module else null;

    try ctx.executeQuotationWithPic(cell.body, null, defining_module, cell.owner, cell.may_define);

    const depth_after = ctx.stack.depth();
    const delta = @as(i64, @intCast(depth_after)) - @as(i64, @intCast(depth_before));
    if (delta != 1) {
        // The cell stays cold, so the next call runs the body again rather than publishing
        // whatever this one left behind.
        helpers.setErrorContext(ctx, "a 'once' body must leave exactly one value, but left {d}", .{delta});
        return error.StackEffectMismatch;
    }

    // `peek` borrows, so the cell takes a reference of its own beside the caller's. Teardown
    // releases that one; the caller's goes when its stack slot does.
    const produced = try ctx.stack.peek();
    container_backing.retainValue(produced);
    cell.value = produced;
    cell.state = .forced;
}

const testing = std.testing;

/// Drive `force-once` over a hand-built cell, the way a `once` word's stored body would.
fn forceCell(ctx: *Context, cell: *OnceCell) anyerror!void {
    try ctx.stack.push(.{ .once_cell = cell });
    try nativeForceOnce(ctx);
}

test "force-once: publishes on the first call and reuses the value afterward" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0 },
    };
    var cell = OnceCell{ .body = .{ .instructions = &body } };

    try forceCell(&ctx, &cell);
    try testing.expectEqual(value_mod.OnceCell.State.forced, cell.state);
    try testing.expectEqual(@as(i64, 7), (try ctx.stack.peek()).fixnum);

    // Overwriting the published value separates a reuse from a rerun: a second call that read the
    // cell answers 9, and one that re-entered the body would answer 7 again.
    cell.value = .{ .fixnum = 9 };
    ctx.stack.clear();
    try forceCell(&ctx, &cell);
    try testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try testing.expectEqual(@as(i64, 9), (try ctx.stack.peek()).fixnum);
}

test "force-once: a reused refcounted value gains no reference per read" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const items = try testing.allocator.alloc(value_mod.Value, 1);
    items[0] = .{ .fixnum = 1 };
    const arr = try value_mod.Array.fromOwnedSlice(testing.allocator, items);
    const literal = value_mod.Value{ .array = arr };

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = literal }, .line = 0 },
    };
    var cell = OnceCell{ .body = .{ .instructions = &body } };

    // Each read pushes and each pop releases, so the pairs below net out. What does not is a read
    // that retains on top of the push: `std.testing.allocator` then reports the array as leaked.
    for (0..3) |_| {
        try forceCell(&ctx, &cell);
        try ctx.stack.popAndRelease();
    }

    // Two references are outstanding by construction: the one the cold force published into the
    // cell, and the creation reference this test still holds.
    container_backing.releaseValue(cell.value.?);
    cell.value = null;
    cell.state = .cold;
    container_backing.releaseValue(literal);
}

test "force-once: a body leaving other than one value raises and leaves the cell cold" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const two = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 },
    };
    var two_cell = OnceCell{ .body = .{ .instructions = &two } };
    try testing.expectError(error.StackEffectMismatch, forceCell(&ctx, &two_cell));
    try testing.expectEqual(value_mod.OnceCell.State.cold, two_cell.state);
    try testing.expect(two_cell.value == null);

    ctx.stack.clear();

    var none_cell = OnceCell{ .body = .{ .instructions = &.{} } };
    try testing.expectError(error.StackEffectMismatch, forceCell(&ctx, &none_cell));
    try testing.expectEqual(value_mod.OnceCell.State.cold, none_cell.state);
}

test "force-once: a throwing body leaves the cell cold" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .call_word = "no-such-word-at-all" }, .line = 0 },
    };
    var cell = OnceCell{ .body = .{ .instructions = &body } };

    try testing.expectError(error.UnknownWord, forceCell(&ctx, &cell));
    try testing.expectEqual(value_mod.OnceCell.State.cold, cell.state);
    try testing.expect(cell.value == null);
}
