const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const BigIntManaged = value_mod.BigIntManaged;
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const dispatch_helpers = @import("dispatch_helpers.zig");

const popFixnum = helpers.popFixnum;
const popNumber = helpers.popNumber;
const Number = helpers.Number;
const toFloats = helpers.toFloats;

/// Return fixnum if the bignum fits in i64, otherwise bignum.
fn demoteBignum(big: BigIntManaged) Value {
    if (big.fits(i64)) {
        return .{ .fixnum = big.toInt(i64) catch unreachable };
    }
    return .{ .bignum = big };
}

/// Promote a fixnum to a Managed bignum. Bignums are cloned so the result
/// always owns its own memory.
fn ensureBignum(alloc: Allocator, val: Value) !BigIntManaged {
    return if (val == .bignum) try val.bignum.clone() else try BigIntManaged.initSet(alloc, val.fixnum);
}

/// Convert a Value (fixnum or float) to a Number for the float promotion path.
fn popNumVal(val: Value) Number {
    return if (val == .float) .{ .float = val.float } else .{ .fixnum = val.fixnum };
}

pub const primitives = [_]Primitive{
    // Basic arithmetic
    .{
        .name = "+",
        .stack_effect = "a b -- a+b",
        .doc = "Add two numbers. Promotes to bignum on fixnum overflow, or to float if either operand is a float.",
        .func = nativeAdd,
    },
    .{
        .name = "-",
        .stack_effect = "a b -- a-b",
        .doc = "Subtract: a minus b. Promotes to bignum on fixnum overflow, or to float if either operand is a float.",
        .func = nativeSub,
    },
    .{
        .name = "*",
        .stack_effect = "a b -- a*b",
        .doc = "Multiply two numbers. Promotes to bignum on fixnum overflow, or to float if either operand is a float.",
        .func = nativeMul,
    },
    .{
        .name = "/",
        .stack_effect = "a b -- a/b",
        .doc = "Divide: a divided by b. Integer division for fixnums (throws on zero); IEEE 754 division for floats.",
        .func = nativeDiv,
    },
    .{
        .name = "%",
        .stack_effect = "a b -- a%b",
        .doc = "Modulo for fixnums and floats. Promotes to float if either operand is a float.",
        .func = nativeMod,
    },
    // Wraparound fixnum (i64) arithmetic
    .{ .name = "+%", .stack_effect = "a b -- a+b", .doc = "Add two fixnums with wraparound on overflow.", .func = nativeAddWrap },
    .{ .name = "-%", .stack_effect = "a b -- a-b", .doc = "Subtract two fixnums (a minus b) with wraparound on overflow.", .func = nativeSubWrap },
    .{ .name = "*%", .stack_effect = "a b -- a*b", .doc = "Multiply two fixnums with wraparound on overflow.", .func = nativeMulWrap },
    // Conversions
    .{ .name = ">float", .stack_effect = "x -- f", .doc = "Convert fixnum or string to float. Floats pass through. Throws on failure.", .func = nativeToFloat },
    .{ .name = ">integer", .stack_effect = "f -- n", .doc = "Convert float to fixnum, truncating toward zero. Fixnums pass through. Throws on NaN or infinity.", .func = nativeToInteger },
    // Unary
    .{ .name = "abs", .stack_effect = "n -- n", .doc = "Absolute value. Works on fixnums and floats.", .func = nativeAbs },
    // Comparators
    .{ .name = "=", .stack_effect = "a b -- ?", .doc = "Equality comparison.", .func = nativeEq },
    .{ .name = "(=)", .stack_effect = "a b -- ?", .doc = "Inner equality: unwraps one layer of tagged values, then compares.", .func = nativeInnerEq },
    .{ .name = "<", .stack_effect = "a b -- ?", .doc = "Less than.", .func = nativeLt },
    .{ .name = ">", .stack_effect = "a b -- ?", .doc = "Greater than.", .func = nativeGt },
};

/// + ( a b -- a+b ) - Add two numbers
pub fn nativeAdd(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "+")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    if (a == .fixnum and b == .fixnum) {
        const result = @addWithOverflow(a.fixnum, b.fixnum);
        if (result[1] != 0) {
            const alloc = ctx.arena.allocator();
            var ba = try BigIntManaged.initSet(alloc, a.fixnum);
            var bb = try BigIntManaged.initSet(alloc, b.fixnum);
            try ba.add(&ba, &bb);
            bb.deinit();
            try ctx.stack.push(demoteBignum(ba));
        } else {
            try ctx.stack.push(.{ .fixnum = result[0] });
        }
    } else if ((a == .bignum or a == .fixnum) and (b == .bignum or b == .fixnum)) {
        const alloc = ctx.arena.allocator();
        var ba = try ensureBignum(alloc, a);
        var bb = try ensureBignum(alloc, b);
        try ba.add(&ba, &bb);
        bb.deinit();
        try ctx.stack.push(demoteBignum(ba));
    } else if ((a == .fixnum or a == .float) and (b == .fixnum or b == .float)) {
        const fs = toFloats(popNumVal(a), popNumVal(b));
        try ctx.stack.push(.{ .float = fs[0] + fs[1] });
    } else {
        helpers.setTypeMismatchError(ctx, "number", if (a != .fixnum and a != .float and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

/// - ( a b -- a-b ) - Subtract: a minus b
pub fn nativeSub(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "-")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    if (a == .fixnum and b == .fixnum) {
        const result = @subWithOverflow(a.fixnum, b.fixnum);
        if (result[1] != 0) {
            const alloc = ctx.arena.allocator();
            var ba = try BigIntManaged.initSet(alloc, a.fixnum);
            var bb = try BigIntManaged.initSet(alloc, b.fixnum);
            try ba.sub(&ba, &bb);
            bb.deinit();
            try ctx.stack.push(demoteBignum(ba));
        } else {
            try ctx.stack.push(.{ .fixnum = result[0] });
        }
    } else if ((a == .bignum or a == .fixnum) and (b == .bignum or b == .fixnum)) {
        const alloc = ctx.arena.allocator();
        var ba = try ensureBignum(alloc, a);
        var bb = try ensureBignum(alloc, b);
        try ba.sub(&ba, &bb);
        bb.deinit();
        try ctx.stack.push(demoteBignum(ba));
    } else if ((a == .fixnum or a == .float) and (b == .fixnum or b == .float)) {
        const fs = toFloats(popNumVal(a), popNumVal(b));
        try ctx.stack.push(.{ .float = fs[0] - fs[1] });
    } else {
        helpers.setTypeMismatchError(ctx, "number", if (a != .fixnum and a != .float and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

/// * ( a b -- a*b ) - Multiply two numbers
pub fn nativeMul(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "*")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    if (a == .fixnum and b == .fixnum) {
        const result = @mulWithOverflow(a.fixnum, b.fixnum);
        if (result[1] != 0) {
            const alloc = ctx.arena.allocator();
            var ba = try BigIntManaged.initSet(alloc, a.fixnum);
            var bb = try BigIntManaged.initSet(alloc, b.fixnum);
            try ba.mul(&ba, &bb);
            bb.deinit();
            try ctx.stack.push(demoteBignum(ba));
        } else {
            try ctx.stack.push(.{ .fixnum = result[0] });
        }
    } else if ((a == .bignum or a == .fixnum) and (b == .bignum or b == .fixnum)) {
        const alloc = ctx.arena.allocator();
        var ba = try ensureBignum(alloc, a);
        var bb = try ensureBignum(alloc, b);
        try ba.mul(&ba, &bb);
        bb.deinit();
        try ctx.stack.push(demoteBignum(ba));
    } else if ((a == .fixnum or a == .float) and (b == .fixnum or b == .float)) {
        const fs = toFloats(popNumVal(a), popNumVal(b));
        try ctx.stack.push(.{ .float = fs[0] * fs[1] });
    } else {
        helpers.setTypeMismatchError(ctx, "number", if (a != .fixnum and a != .float and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

/// / ( a b -- a/b ) - Division
pub fn nativeDiv(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "/")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    if (a == .fixnum and b == .fixnum) {
        if (b.fixnum == 0) return error.DivisionByZero;
        if (a.fixnum == std.math.minInt(i64) and b.fixnum == -1) {
            const alloc = ctx.arena.allocator();
            var ba = try BigIntManaged.initSet(alloc, a.fixnum);
            var bb = try BigIntManaged.initSet(alloc, b.fixnum);
            var q = try BigIntManaged.init(alloc);
            var r = try BigIntManaged.init(alloc);
            try q.divTrunc(&r, &ba, &bb);
            ba.deinit();
            bb.deinit();
            r.deinit();
            try ctx.stack.push(demoteBignum(q));
        } else {
            try ctx.stack.push(.{ .fixnum = @divTrunc(a.fixnum, b.fixnum) });
        }
    } else if ((a == .bignum or a == .fixnum) and (b == .bignum or b == .fixnum)) {
        const alloc = ctx.arena.allocator();
        var ba = try ensureBignum(alloc, a);
        var bb = try ensureBignum(alloc, b);
        if (bb.eqlZero()) {
            ba.deinit();
            bb.deinit();
            return error.DivisionByZero;
        }
        var q = try BigIntManaged.init(alloc);
        var r = try BigIntManaged.init(alloc);
        try q.divTrunc(&r, &ba, &bb);
        ba.deinit();
        bb.deinit();
        r.deinit();
        try ctx.stack.push(demoteBignum(q));
    } else if ((a == .fixnum or a == .float) and (b == .fixnum or b == .float)) {
        const fs = toFloats(popNumVal(a), popNumVal(b));
        try ctx.stack.push(.{ .float = fs[0] / fs[1] });
    } else {
        helpers.setTypeMismatchError(ctx, "number", if (a != .fixnum and a != .float and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

/// % ( a b -- a%b ) - Modulo / fmod
pub fn nativeMod(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "%")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    if (a == .fixnum and b == .fixnum) {
        if (b.fixnum == 0) return error.DivisionByZero;
        try ctx.stack.push(.{ .fixnum = @mod(a.fixnum, b.fixnum) });
    } else if ((a == .bignum or a == .fixnum) and (b == .bignum or b == .fixnum)) {
        const alloc = ctx.arena.allocator();
        var ba = try ensureBignum(alloc, a);
        var bb = try ensureBignum(alloc, b);
        if (bb.eqlZero()) {
            ba.deinit();
            bb.deinit();
            return error.DivisionByZero;
        }
        var q = try BigIntManaged.init(alloc);
        var r = try BigIntManaged.init(alloc);
        try q.divFloor(&r, &ba, &bb);
        ba.deinit();
        bb.deinit();
        q.deinit();
        try ctx.stack.push(demoteBignum(r));
    } else if ((a == .fixnum or a == .float) and (b == .fixnum or b == .float)) {
        const fs = toFloats(popNumVal(a), popNumVal(b));
        try ctx.stack.push(.{ .float = @rem(fs[0], fs[1]) });
    } else {
        helpers.setTypeMismatchError(ctx, "number", if (a != .fixnum and a != .float and a != .bignum) a else b);
        return error.TypeMismatch;
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
    } else if (a == .fixnum and b == .bignum) {
        try ctx.stack.push(.{ .boolean = b.bignum.toConst().orderAgainstScalar(a.fixnum) == .eq });
    } else if (a == .bignum and b == .fixnum) {
        try ctx.stack.push(.{ .boolean = a.bignum.toConst().orderAgainstScalar(b.fixnum) == .eq });
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
            .bignum => |bv| try ctx.stack.push(.{ .boolean = bv.toConst().orderAgainstScalar(av) == .gt }),
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
        .bignum => |av| switch (b) {
            .bignum => |bv| try ctx.stack.push(.{ .boolean = av.toConst().order(bv.toConst()) == .lt }),
            .fixnum => |bv| try ctx.stack.push(.{ .boolean = av.toConst().orderAgainstScalar(bv) == .lt }),
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

/// >float ( x -- f ) - Convert fixnum or string to float
fn nativeToFloat(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ">float")) return;
    const val = try ctx.stack.pop();
    switch (val) {
        .fixnum => |i| try ctx.stack.push(.{ .float = @floatFromInt(i) }),
        .float => try ctx.stack.push(val),
        .string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch {
                helpers.setErrorContext(ctx, ">float: cannot parse \"{s}\" as float", .{s});
                return error.TypeMismatch;
            };
            try ctx.stack.push(.{ .float = f });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum, float, or string", val);
            return error.TypeMismatch;
        },
    }
}

/// >integer ( f -- n ) - Float to fixnum, truncate toward zero
fn nativeToInteger(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ">integer")) return;
    const val = try ctx.stack.pop();
    switch (val) {
        .float => |f| {
            if (std.math.isNan(f)) {
                helpers.setErrorContext(ctx, ">integer: NaN cannot be converted to fixnum", .{});
                return error.TypeMismatch;
            }
            if (std.math.isInf(f)) {
                helpers.setErrorContext(ctx, ">integer: infinity cannot be converted to fixnum", .{});
                return error.TypeMismatch;
            }
            const truncated = @trunc(f);
            const max_f: f64 = @floatFromInt(std.math.maxInt(i64));
            const min_f: f64 = @floatFromInt(std.math.minInt(i64));
            if (truncated >= max_f or truncated < min_f) return error.FixnumOverflow;
            const i: i64 = @intFromFloat(truncated);
            try ctx.stack.push(.{ .fixnum = i });
        },
        .fixnum => try ctx.stack.push(val),
        else => {
            helpers.setTypeMismatchError(ctx, "float or fixnum", val);
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
            .bignum => |bv| try ctx.stack.push(.{ .boolean = bv.toConst().orderAgainstScalar(av) == .lt }),
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
        .bignum => |av| switch (b) {
            .bignum => |bv| try ctx.stack.push(.{ .boolean = av.toConst().order(bv.toConst()) == .gt }),
            .fixnum => |bv| try ctx.stack.push(.{ .boolean = av.toConst().orderAgainstScalar(bv) == .gt }),
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

/// abs ( n -- n ) - Absolute value for fixnums, bignums, and floats
fn nativeAbs(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "abs")) return;
    const val = try ctx.stack.pop();
    switch (val) {
        .fixnum => |i| {
            if (i == std.math.minInt(i64)) {
                var big = try BigIntManaged.initSet(ctx.arena.allocator(), i);
                big.abs();
                try ctx.stack.push(demoteBignum(big));
            } else {
                try ctx.stack.push(.{ .fixnum = if (i < 0) -i else i });
            }
        },
        .bignum => |b| {
            var big = try b.clone();
            big.abs();
            try ctx.stack.push(demoteBignum(big));
        },
        .float => |f| {
            try ctx.stack.push(.{ .float = @abs(f) });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "number", val);
            return error.TypeMismatch;
        },
    }
}
