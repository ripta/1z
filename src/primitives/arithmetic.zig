const std = @import("std");
const Context = @import("../context.zig").Context;
const Value = @import("../value.zig").Value;
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const dispatch_helpers = @import("dispatch_helpers.zig");

const popFixnum = helpers.popFixnum;
const popNumber = helpers.popNumber;
const Number = helpers.Number;
const toFloats = helpers.toFloats;

pub const primitives = [_]Primitive{
    // Basic arithmetic
    .{ .name = "+", .stack_effect = "a b -- a+b", .doc = "Add two numbers. Promotes to float if either operand is a float.", .func = nativeAdd },
    .{ .name = "-", .stack_effect = "a b -- a-b", .doc = "Subtract: a minus b. Promotes to float if either operand is a float.", .func = nativeSub },
    .{ .name = "*", .stack_effect = "a b -- a*b", .doc = "Multiply two numbers. Promotes to float if either operand is a float.", .func = nativeMul },
    .{ .name = "/", .stack_effect = "a b -- a/b", .doc = "Divide: a divided by b. Integer division for fixnums (throws on zero); IEEE 754 division for floats.", .func = nativeDiv },
    .{ .name = "%", .stack_effect = "a b -- a%b", .doc = "Modulo for fixnums; fmod for floats. Promotes to float if either operand is a float.", .func = nativeMod },
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

/// + ( a b -- a+b ) - Add two numbers
pub fn nativeAdd(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "+")) return;
    const b = try popNumber(ctx);
    const a = try popNumber(ctx);
    if (a == .fixnum and b == .fixnum) {
        const result = @addWithOverflow(a.fixnum, b.fixnum);
        if (result[1] != 0) return error.FixnumOverflow;
        try ctx.stack.push(.{ .fixnum = result[0] });
    } else {
        const fs = toFloats(a, b);
        try ctx.stack.push(.{ .float = fs[0] + fs[1] });
    }
}

/// - ( a b -- a-b ) - Subtract: a minus b
pub fn nativeSub(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "-")) return;
    const b = try popNumber(ctx);
    const a = try popNumber(ctx);
    if (a == .fixnum and b == .fixnum) {
        const result = @subWithOverflow(a.fixnum, b.fixnum);
        if (result[1] != 0) return error.FixnumOverflow;
        try ctx.stack.push(.{ .fixnum = result[0] });
    } else {
        const fs = toFloats(a, b);
        try ctx.stack.push(.{ .float = fs[0] - fs[1] });
    }
}

/// * ( a b -- a*b ) - Multiply two numbers
pub fn nativeMul(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "*")) return;
    const b = try popNumber(ctx);
    const a = try popNumber(ctx);
    if (a == .fixnum and b == .fixnum) {
        const result = @mulWithOverflow(a.fixnum, b.fixnum);
        if (result[1] != 0) return error.FixnumOverflow;
        try ctx.stack.push(.{ .fixnum = result[0] });
    } else {
        const fs = toFloats(a, b);
        try ctx.stack.push(.{ .float = fs[0] * fs[1] });
    }
}

/// / ( a b -- a/b ) - Division
pub fn nativeDiv(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "/")) return;
    const b = try popNumber(ctx);
    const a = try popNumber(ctx);
    if (a == .fixnum and b == .fixnum) {
        if (b.fixnum == 0) return error.DivisionByZero;
        if (a.fixnum == std.math.minInt(i64) and b.fixnum == -1) return error.FixnumOverflow;
        try ctx.stack.push(.{ .fixnum = @divTrunc(a.fixnum, b.fixnum) });
    } else {
        const fs = toFloats(a, b);
        try ctx.stack.push(.{ .float = fs[0] / fs[1] });
    }
}

/// % ( a b -- a%b ) - Modulo / fmod
pub fn nativeMod(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "%")) return;
    const b = try popNumber(ctx);
    const a = try popNumber(ctx);
    if (a == .fixnum and b == .fixnum) {
        if (b.fixnum == 0) return error.DivisionByZero;
        try ctx.stack.push(.{ .fixnum = @mod(a.fixnum, b.fixnum) });
    } else {
        const fs = toFloats(a, b);
        try ctx.stack.push(.{ .float = @rem(fs[0], fs[1]) });
    }
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
    if (a == .fixnum and b == .float) {
        const af: f64 = @floatFromInt(a.fixnum);
        try ctx.stack.push(.{ .boolean = af == b.float });
    } else if (a == .float and b == .fixnum) {
        const bf: f64 = @floatFromInt(b.fixnum);
        try ctx.stack.push(.{ .boolean = a.float == bf });
    } else {
        try ctx.stack.push(.{ .boolean = a.eql(b) });
    }
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
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    switch (a) {
        .fixnum => |av| switch (b) {
            .fixnum => |bv| try ctx.stack.push(.{ .boolean = av < bv }),
            .float => |bv| try ctx.stack.push(.{ .boolean = @as(f64, @floatFromInt(av)) < bv }),
            else => {
                helpers.setTypeMismatchError(ctx, "number", b);
                return error.TypeMismatch;
            },
        },
        .float => |av| switch (b) {
            .float => |bv| try ctx.stack.push(.{ .boolean = av < bv }),
            .fixnum => |bv| try ctx.stack.push(.{ .boolean = av < @as(f64, @floatFromInt(bv)) }),
            else => {
                helpers.setTypeMismatchError(ctx, "number", b);
                return error.TypeMismatch;
            },
        },
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum or float", a);
            return error.TypeMismatch;
        },
    }
}

/// > ( a b -- ? ) - Greater than
pub fn nativeGt(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, ">")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    switch (a) {
        .fixnum => |av| switch (b) {
            .fixnum => |bv| try ctx.stack.push(.{ .boolean = av > bv }),
            .float => |bv| try ctx.stack.push(.{ .boolean = @as(f64, @floatFromInt(av)) > bv }),
            else => {
                helpers.setTypeMismatchError(ctx, "number", b);
                return error.TypeMismatch;
            },
        },
        .float => |av| switch (b) {
            .float => |bv| try ctx.stack.push(.{ .boolean = av > bv }),
            .fixnum => |bv| try ctx.stack.push(.{ .boolean = av > @as(f64, @floatFromInt(bv)) }),
            else => {
                helpers.setTypeMismatchError(ctx, "number", b);
                return error.TypeMismatch;
            },
        },
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum or float", a);
            return error.TypeMismatch;
        },
    }
}
