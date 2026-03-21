const Context = @import("../context.zig").Context;
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

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
};

/// dup ( a -- a a ) - Duplicate top of stack
pub fn nativeDup(ctx: *Context) anyerror!void {
    const val = try ctx.stack.peek();
    try ctx.stack.push(val);
}

/// drop ( a -- ) - Remove top of stack
pub fn nativeDrop(ctx: *Context) anyerror!void {
    _ = try ctx.stack.pop();
}

/// swap ( a b -- b a ) - Swap top two items
pub fn nativeSwap(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    try ctx.stack.push(b);
    try ctx.stack.push(a);
}

/// over ( x y -- x y x ) - Copy second item to top
pub fn nativeOver(ctx: *Context) anyerror!void {
    const y = try ctx.stack.pop();
    const x = try ctx.stack.peek();
    try ctx.stack.push(y);
    try ctx.stack.push(x);
}

/// dip ( x quot -- x ) - Execute quotation with x temporarily removed
pub fn nativeDip(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const x = try ctx.stack.pop();
    try ctx.executeQuotationWithFrame(quot);
    try ctx.stack.push(x);
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
fn nativePickN(ctx: *Context) anyerror!void {
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
fn nativeRotUp(ctx: *Context) anyerror!void {
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
fn nativeRotDown(ctx: *Context) anyerror!void {
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
