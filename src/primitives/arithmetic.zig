const std = @import("std");
const Context = @import("../context.zig").Context;
const Value = @import("../value.zig").Value;
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const dispatch_helpers = @import("dispatch_helpers.zig");

const popFixnum = helpers.popFixnum;

pub const primitives = [_]Primitive{
    // Basic arithmetic
    .{ .name = "+", .stack_effect = "a b -- a+b", .doc = "Add two fixnums.", .func = nativeAdd },
    .{ .name = "-", .stack_effect = "a b -- a-b", .doc = "Subtract: a minus b.", .func = nativeSub },
    .{ .name = "*", .stack_effect = "a b -- a*b", .doc = "Multiply two fixnums.", .func = nativeMul },
    .{ .name = "/", .stack_effect = "a b -- a/b", .doc = "Integer division.", .func = nativeDiv },
    .{ .name = "%", .stack_effect = "a b -- a%b", .doc = "Modulo (remainder).", .func = nativeMod },
    // Wraparound arithmetic
    .{ .name = "+%", .stack_effect = "a b -- a+b", .doc = "Add two fixnums with wraparound on overflow.", .func = nativeAddWrap },
    .{ .name = "-%", .stack_effect = "a b -- a-b", .doc = "Subtract with wraparound on overflow.", .func = nativeSubWrap },
    .{ .name = "*%", .stack_effect = "a b -- a*b", .doc = "Multiply with wraparound on overflow.", .func = nativeMulWrap },
    // Comparators
    .{ .name = "=", .stack_effect = "a b -- ?", .doc = "Equality comparison.", .func = nativeEq },
    .{ .name = "(=)", .stack_effect = "a b -- ?", .doc = "Inner equality: unwraps one layer of tagged values, then compares.", .func = nativeInnerEq },
    .{ .name = "<", .stack_effect = "a b -- ?", .doc = "Less than.", .func = nativeLt },
    .{ .name = ">", .stack_effect = "a b -- ?", .doc = "Greater than.", .func = nativeGt },
};

/// + ( a b -- a+b ) - Add two fixnums
pub fn nativeAdd(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "+")) return;
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return error.FixnumOverflow;
    try ctx.stack.push(.{ .fixnum = result[0] });
}

/// - ( a b -- a-b ) - Subtract: a minus b
pub fn nativeSub(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "-")) return;
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    const result = @subWithOverflow(a, b);
    if (result[1] != 0) return error.FixnumOverflow;
    try ctx.stack.push(.{ .fixnum = result[0] });
}

/// * ( a b -- a*b ) - Multiply two fixnums
pub fn nativeMul(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "*")) return;
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return error.FixnumOverflow;
    try ctx.stack.push(.{ .fixnum = result[0] });
}

/// / ( a b -- a/b ) - Integer division
pub fn nativeDiv(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "/")) return;
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    if (b == 0) return error.DivisionByZero;
    if (a == std.math.minInt(i64) and b == -1) return error.FixnumOverflow;
    try ctx.stack.push(.{ .fixnum = @divTrunc(a, b) });
}

/// % ( a b -- a%b ) - Modulo (remainder)
pub fn nativeMod(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "%")) return;
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    if (b == 0) return error.DivisionByZero;
    try ctx.stack.push(.{ .fixnum = @mod(a, b) });
}

/// +% ( a b -- a+b ) - Add two fixnums with wraparound on overflow
pub fn nativeAddWrap(ctx: *Context) anyerror!void {
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    try ctx.stack.push(.{ .fixnum = a +% b });
}

/// -% ( a b -- a-b ) - Subtract with wraparound on overflow
pub fn nativeSubWrap(ctx: *Context) anyerror!void {
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    try ctx.stack.push(.{ .fixnum = a -% b });
}

/// *% ( a b -- a*b ) - Multiply with wraparound on overflow
pub fn nativeMulWrap(ctx: *Context) anyerror!void {
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    try ctx.stack.push(.{ .fixnum = a *% b });
}

/// = ( a b -- ? ) - Equality comparison
pub fn nativeEq(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "=")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    try ctx.stack.push(.{ .boolean = a.eql(b) });
}

/// (=) ( a b -- ? ) - Inner equality: unwraps one layer of tagged values, then compares
pub fn nativeInnerEq(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    const a_inner: Value = if (a == .tagged) a.tagged.inner.* else a;
    const b_inner: Value = if (b == .tagged) b.tagged.inner.* else b;
    try ctx.stack.push(.{ .boolean = a_inner.eql(b_inner) });
}

/// < ( a b -- ? ) - Less than
pub fn nativeLt(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "<")) return;
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    try ctx.stack.push(.{ .boolean = a < b });
}

/// > ( a b -- ? ) - Greater than
pub fn nativeGt(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, ">")) return;
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    try ctx.stack.push(.{ .boolean = a > b });
}
