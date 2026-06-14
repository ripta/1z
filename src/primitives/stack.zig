const std = @import("std");
const Context = @import("../context.zig").Context;
const Value = @import("../value.zig").Value;
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const container_backing = @import("../container_backing.zig");

const popQuotation = helpers.popQuotation;

pub const primitives = [_]Primitive{
    .{ .name = "dup", .stack_effect = "a -- a a", .doc = "Duplicate top of stack.", .func = nativeDup },
    .{ .name = "drop", .stack_effect = "a --", .doc = "Remove top of stack.", .func = nativeDrop },
    .{ .name = "swap", .stack_effect = "a b -- b a", .doc = "Swap top two items.", .func = nativeSwap },
    .{ .name = "over", .stack_effect = "a b -- a b a", .doc = "Copy second item to top.", .func = nativeOver },
    .{ .name = "dip", .stack_effect = "..a x quot: ( ..a -- ..b ) -- ..b x", .doc = "Execute quotation with x temporarily removed.", .func = nativeDip, .effect_transparent = true },
    .{ .name = "wipe", .stack_effect = "... --", .doc = "Clear the entire stack.", .func = nativeWipe },
    .{ .name = "pick-n", .stack_effect = "n -- val", .doc = "Copy the item at stack depth n (0-indexed from top, before n itself).", .func = nativePickN },
    .{ .name = "<rot-n", .stack_effect = "n --", .doc = "Pull item at depth n to top, shifting items above it down.", .func = nativeRotUp },
    .{ .name = "rot-n>", .stack_effect = "n --", .doc = "Push top item to depth n, shifting items above it up.", .func = nativeRotDown },
    .{ .name = "array-n", .stack_effect = "...elems n -- array", .doc = "Pop n, then pop n elements and pack them into an array (stack-order preserved).", .func = nativeArrayN },
    .{ .name = "drop-n", .stack_effect = "x1..xn n --", .doc = "Drop n items from the stack.", .func = nativeDropN },
    .{ .name = "nip-n", .stack_effect = "...x1..xn y n -- y", .doc = "Drop n items beneath the top value, preserving the top value.", .func = nativeNipN },
    .{ .name = "apply-n", .stack_effect = "x1..xn quot: ( x -- ..results ) n -- ..results", .doc = "Apply quotation to each of the top n stack values separately, left to right.", .func = nativeApplyN },
};

/// dup ( a -- a a ) - Duplicate top of stack
pub fn nativeDup(ctx: *Context) anyerror!void {
    const val = try ctx.stack.peek();
    try ctx.stack.push(val);
}

/// drop ( a -- ) - Remove top of stack
pub fn nativeDrop(ctx: *Context) anyerror!void {
    try ctx.stack.popAndRelease();
}

/// swap ( a b -- b a ) - Swap top two items
pub fn nativeSwap(ctx: *Context) anyerror!void {
    const len = ctx.stack.items.items.len;
    if (len < 2) return error.StackUnderflow;
    const top = ctx.stack.items.items[len - 1];
    ctx.stack.items.items[len - 1] = ctx.stack.items.items[len - 2];
    ctx.stack.items.items[len - 2] = top;
}

/// over ( x y -- x y x ) - Copy second item to top
pub fn nativeOver(ctx: *Context) anyerror!void {
    const len = ctx.stack.items.items.len;
    if (len < 2) return error.StackUnderflow;
    const x = ctx.stack.items.items[len - 2];
    // The copied value becomes a second owning slot; retain explicitly
    // and use the move variant to avoid double-retain via `push`.
    container_backing.retainValue(x);
    try ctx.stack.pushMoved(x);
}

/// dip ( x quot -- x ) - Execute quotation with x temporarily removed
pub fn nativeDip(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const x = try ctx.stack.pop();
    // x was transferred to this C local by `pop`. The body may push or
    // throw; either way we must re-establish a stack slot for x on the
    // success path. On error the C local is forfeit, so release it.
    errdefer container_backing.releaseValue(x);
    try ctx.executeQuotationWithFrame(quot);
    try ctx.stack.pushMoved(x);
}

/// wipe ( ... -- ) - Clear the entire stack
pub fn nativeWipe(ctx: *Context) anyerror!void {
    ctx.stack.clear();
}

/// pick-n ( n -- val ) - Copy the item at stack depth n (0-indexed from top, before n itself)
///
/// There are equivalencies to other stack operations:
/// - dup: 0 pick-n
/// - over: 1 pick-n
/// - pick: 2 pick-n
pub fn nativePickN(ctx: *Context) anyerror!void {
    const n = try helpers.popFixnum(ctx);
    if (n < 0) return error.StackUnderflow;

    const depth: usize = @intCast(n);
    const stack_len = ctx.stack.items.items.len;
    if (depth >= stack_len) return error.StackUnderflow;

    const val = ctx.stack.items.items[stack_len - 1 - depth];
    try ctx.stack.push(val);
}

/// <rot-n ( n -- ) - Pull item at depth n to top, shifting items above it down.
///
/// Equivalencies: 0 is no-op, 1 is swap, 2 is <rot-.
pub fn nativeRotUp(ctx: *Context) anyerror!void {
    const n = try helpers.popFixnum(ctx);
    if (n < 0) return error.StackUnderflow;
    const depth: usize = @intCast(n);
    const len = ctx.stack.items.items.len;
    if (depth >= len) return error.StackUnderflow;
    if (depth == 0) return;
    const start = len - 1 - depth;
    const val = ctx.stack.items.items[start];
    var i: usize = start;
    while (i < len - 1) : (i += 1) {
        ctx.stack.items.items[i] = ctx.stack.items.items[i + 1];
    }
    ctx.stack.items.items[len - 1] = val;
}

/// rot-n> ( n -- ) - Push top item to depth n, shifting items above it up.
///
/// Equivalencies: 0 is no-op, 1 is swap, 2 is -rot>.
pub fn nativeRotDown(ctx: *Context) anyerror!void {
    const n = try helpers.popFixnum(ctx);
    if (n < 0) return error.StackUnderflow;
    const depth: usize = @intCast(n);
    const len = ctx.stack.items.items.len;
    if (depth >= len) return error.StackUnderflow;
    if (depth == 0) return;
    const start = len - 1 - depth;
    const val = ctx.stack.items.items[len - 1];
    var i: usize = len - 1;
    while (i > start) : (i -= 1) {
        ctx.stack.items.items[i] = ctx.stack.items.items[i - 1];
    }
    ctx.stack.items.items[start] = val;
}

/// array-n ( ...elems n -- array ) - Pop n elements and pack into an array.
fn nativeArrayN(ctx: *Context) anyerror!void {
    const n = try helpers.popFixnum(ctx);
    if (n < 0) return error.StackUnderflow;

    const count: usize = @intCast(n);
    if (count > ctx.stack.items.items.len) return error.StackUnderflow;

    const alloc = ctx.quotationAllocator();
    const arr = try alloc.alloc(Value, count);

    var i: usize = count;
    while (i > 0) {
        i -= 1;
        arr[i] = try ctx.stack.pop();
    }

    // Elements were popped (moved) into `arr`, so each slot already owns its
    // value; push the array without re-retaining its elements.
    try ctx.stack.pushMoved(.{ .array = arr });
}

/// drop-n ( x1...xn n -- ) - Drop n items from the stack in O(1).
fn nativeDropN(ctx: *Context) anyerror!void {
    const n = try helpers.popFixnum(ctx);
    if (n < 0) return error.StackUnderflow;

    const count: usize = @intCast(n);
    const len = ctx.stack.items.items.len;
    if (count > len) return error.StackUnderflow;
    if (count == 0) return;

    ctx.stack.releaseRange(len - count, len);
    ctx.stack.items.shrinkRetainingCapacity(len - count);
}

/// nip-n ( ...x1..xn y n -- y ) - Drop n items beneath the top value.
pub fn nativeNipN(ctx: *Context) anyerror!void {
    const n = try helpers.popFixnum(ctx);
    if (n < 0) return error.StackUnderflow;

    const count: usize = @intCast(n);
    const len = ctx.stack.items.items.len;
    if (count >= len) return error.StackUnderflow;
    if (count == 0) return;

    const new_len = len - count;
    const top = ctx.stack.items.items[len - 1];
    // Drop the count slots immediately beneath the top, releasing each
    // before overwriting `top`'s position. The slot that holds `top`
    // after the move still owns the same value, so no extra
    // retain/release for it.
    ctx.stack.releaseRange(new_len - 1, len - 1);
    ctx.stack.items.items[new_len - 1] = top;
    ctx.stack.items.shrinkRetainingCapacity(new_len);
}

/// apply-n ( x1...xn quot n -- ) - Apply quotation to each of the top n stack values.
fn nativeApplyN(ctx: *Context) anyerror!void {
    const n = try helpers.popFixnum(ctx);
    if (n < 0) return error.StackUnderflow;

    const quot = try popQuotation(ctx);

    const count: usize = @intCast(n);
    if (count > ctx.stack.items.items.len) return error.StackUnderflow;
    if (count == 0) return;

    // Copy n values into temp buffer, preserving order (deepest first).
    // The temp buffer is a transient owner that inherits the popped
    // stack slots' ownership; subsequent `pushMoved` transfers the
    // ownership back into a new stack slot without an extra retain.
    const alloc = ctx.quotationAllocator();
    const temp = try alloc.alloc(Value, count);
    defer alloc.free(temp);

    const stack_len = ctx.stack.items.items.len;
    const start = stack_len - count;
    @memcpy(temp, ctx.stack.items.items[start..stack_len]);

    ctx.stack.items.shrinkRetainingCapacity(start);

    for (temp) |val| {
        try ctx.stack.pushMoved(val);
        try ctx.executeQuotationWithFrame(quot);
    }
}

test "nip-n preserves top value while dropping beneath values" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 10 });
    try ctx.stack.push(.{ .fixnum = 20 });
    try ctx.stack.push(.{ .fixnum = 30 });
    try ctx.stack.push(.{ .fixnum = 99 });
    try ctx.stack.push(.{ .fixnum = 3 });

    try nativeNipN(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const result = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 99), result.fixnum);
}

test "nip-n keeps lower prefix intact" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .fixnum = 8 });
    try ctx.stack.push(.{ .fixnum = 9 });
    try ctx.stack.push(.{ .fixnum = 100 });
    try ctx.stack.push(.{ .fixnum = 2 });

    try nativeNipN(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    const top = try ctx.stack.pop();
    const bottom = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 100), top.fixnum);
    try std.testing.expectEqual(@as(i64, 7), bottom.fixnum);
}

test "nip-n rejects dropping past stack bottom" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 42 });
    try ctx.stack.push(.{ .fixnum = 1 });

    try std.testing.expectError(error.StackUnderflow, nativeNipN(&ctx));
}
