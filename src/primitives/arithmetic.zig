const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const BigIntManaged = value_mod.BigIntManaged;
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const RegistryEntry = @import("types.zig").RegistryEntry;
const dispatch_helpers = @import("dispatch_helpers.zig");
const dispatch_mod = @import("../dispatch.zig");
const container_backing = @import("../container_backing.zig");
const DispatchTable = dispatch_mod.DispatchTable;
const markers_mod = @import("markers.zig");

const popFixnum = helpers.popFixnum;
const popNumber = helpers.popNumber;
const Number = helpers.Number;
const toFloats = helpers.toFloats;
const demoteBignum = helpers.demoteBignum;
const ensureBignum = helpers.ensureBignum;

/// Convert a Value (fixnum, float, or bignum) to f64 for the float promotion path.
fn valToFloat(alloc: Allocator, val: Value) f64 {
    return switch (val) {
        .float => |f| f,
        .fixnum => |i| @floatFromInt(i),
        .bignum => |b| blk: {
            const str = b.toConst().toStringAlloc(alloc, 10, .lower) catch break :blk std.math.nan(f64);
            break :blk std.fmt.parseFloat(f64, str) catch std.math.nan(f64);
        },
        else => unreachable,
    };
}

fn isNativeNumeric(val: Value) bool {
    return val == .fixnum or val == .float or val == .bignum;
}

/// Convert a Value (fixnum or float) to a Number for the float promotion path.
pub fn popNumVal(val: Value) Number {
    return if (val == .float) .{ .float = val.float } else .{ .fixnum = val.fixnum };
}

pub const primitives = [_]Primitive{
    // Basic arithmetic
    .{
        .name = "+",
        .stack_effect = "a b -- a+b",
        .doc = "Add two numbers. Promotes to bignum on fixnum overflow, or to float if either operand is a float.",
        .func = nativeAdd,
        .markers = &.{@constCast(&markers_mod.generic_marker)},
    },
    .{
        .name = "-",
        .stack_effect = "a b -- a-b",
        .doc = "Subtract: a minus b. Promotes to bignum on fixnum overflow, or to float if either operand is a float.",
        .func = nativeSub,
        .markers = &.{@constCast(&markers_mod.generic_marker)},
    },
    .{
        .name = "*",
        .stack_effect = "a b -- a*b",
        .doc = "Multiply two numbers. Promotes to bignum on fixnum overflow, or to float if either operand is a float.",
        .func = nativeMul,
        .markers = &.{@constCast(&markers_mod.generic_marker)},
    },
    .{
        .name = "/",
        .stack_effect = "a b -- a/b",
        .doc = "Divide: a divided by b. Truncating integer division; ratio library registers dispatch methods for inexact promotion. IEEE 754 division for floats.",
        .func = nativeDiv,
        .markers = &.{@constCast(&markers_mod.generic_marker)},
    },
    .{
        .name = "%",
        .stack_effect = "a b -- a%b",
        .doc = "Modulo for fixnums and floats. Promotes to float if either operand is a float.",
        .func = nativeMod,
        .markers = &.{@constCast(&markers_mod.generic_marker)},
    },
    // Integer-only truncating division and remainder
    .{ .name = "div", .stack_effect = "a b -- q", .doc = "Truncating integer division toward zero. Integer-only.", .func = nativeTruncDiv },
    .{ .name = "rem", .stack_effect = "a b -- r", .doc = "Truncating integer remainder. Satisfies a = (a div b) * b + (a rem b). Integer-only.", .func = nativeTruncRem },
    .{ .name = "gcd", .stack_effect = "a b -- gcd", .doc = "Greatest common divisor via Euclidean algorithm. Always non-negative. gcd(0,0) = 0. Integer-only.", .func = nativeGcd },
    // Wraparound fixnum (i64) arithmetic
    .{ .name = "+%", .stack_effect = "a b -- a+b", .doc = "Add two fixnums with wraparound on overflow.", .func = nativeAddWrap },
    .{ .name = "-%", .stack_effect = "a b -- a-b", .doc = "Subtract two fixnums (a minus b) with wraparound on overflow.", .func = nativeSubWrap },
    .{ .name = "*%", .stack_effect = "a b -- a*b", .doc = "Multiply two fixnums with wraparound on overflow.", .func = nativeMulWrap },
    // Conversions
    .{ .name = ">float", .stack_effect = "x -- f", .doc = "Convert fixnum or string to float. Floats pass through. Throws on failure.", .func = nativeToFloat, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = ">integer", .stack_effect = "f -- n", .doc = "Convert float to fixnum, truncating toward zero. Fixnums pass through. Throws on NaN or infinity.", .func = nativeToInteger, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "float-parts", .stack_effect = "f -- mantissa exponent sign", .doc = "Decompose an IEEE 754 double into mantissa, exponent, and sign. value = sign * mantissa * 2^exponent. Throws on NaN or infinity.", .func = nativeFloatParts },
    // Unary
    .{ .name = "abs", .stack_effect = "n -- n", .doc = "Absolute value. Works on fixnums and floats.", .func = nativeAbs, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    // Comparators
    .{ .name = "=", .stack_effect = "a b -- ?", .doc = "Equality comparison.", .func = nativeEq, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "(=)", .stack_effect = "a b -- ?", .doc = "Inner equality: unwraps one layer of tagged values, then compares.", .func = nativeInnerEq },
    .{ .name = "<", .stack_effect = "a b -- ?", .doc = "Less than.", .func = nativeLt, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = ">", .stack_effect = "a b -- ?", .doc = "Greater than.", .func = nativeGt, .markers = &.{@constCast(&markers_mod.generic_marker)} },
};

// =============================================================================
// Numeric type enum used by comptime dispatch entry generators
// =============================================================================

const NumType = enum { fixnum, bignum, float };

const num_types = [_]NumType{ .fixnum, .bignum, .float };

fn numTypeName(comptime t: NumType) []const u8 {
    return switch (t) {
        .fixnum => "fixnum",
        .bignum => "bignum",
        .float => "float",
    };
}

// =============================================================================
// Comptime dispatch entry generators
// =============================================================================

const ArithOp = enum { add, sub, mul };

fn bignumOp(comptime op: ArithOp, ba: *BigIntManaged, bb: *BigIntManaged) !void {
    switch (op) {
        .add => try ba.add(ba, bb),
        .sub => try ba.sub(ba, bb),
        .mul => try ba.mul(ba, bb),
    }
}

/// Generate a native dispatch function for binary arithmetic (+, -, *).
fn makeBinaryArithEntry(comptime op: ArithOp, comptime type_a: NumType, comptime type_b: NumType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const alloc = ctx.arena.allocator();
            const b = try ctx.stack.pop();
            defer container_backing.releaseValue(b);
            const a = try ctx.stack.pop();
            defer container_backing.releaseValue(a);

            if (type_a == .fixnum and type_b == .fixnum) {
                const result = switch (op) {
                    .add => @addWithOverflow(a.fixnum, b.fixnum),
                    .sub => @subWithOverflow(a.fixnum, b.fixnum),
                    .mul => @mulWithOverflow(a.fixnum, b.fixnum),
                };
                if (result[1] != 0) {
                    var ba = try BigIntManaged.initSet(alloc, a.fixnum);
                    var bb = try BigIntManaged.initSet(alloc, b.fixnum);
                    try bignumOp(op, &ba, &bb);
                    bb.deinit();
                    try ctx.stack.push(try demoteBignum(alloc, ba));
                } else {
                    try ctx.stack.push(.{ .fixnum = result[0] });
                }
            } else if ((type_a == .bignum or type_a == .fixnum) and (type_b == .bignum or type_b == .fixnum)) {
                var ba = try ensureBignum(alloc, a);
                var bb = try ensureBignum(alloc, b);
                try bignumOp(op, &ba, &bb);
                bb.deinit();
                try ctx.stack.push(try demoteBignum(alloc, ba));
            } else {
                const fa = valToFloat(alloc, a);
                const fb = valToFloat(alloc, b);
                try ctx.stack.push(.{ .float = switch (op) {
                    .add => fa + fb,
                    .sub => fa - fb,
                    .mul => fa * fb,
                } });
            }
        }
    }.func;
}

/// Generate a native dispatch function for division (/).
fn makeDivEntry(comptime type_a: NumType, comptime type_b: NumType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const alloc = ctx.arena.allocator();
            const b = try ctx.stack.pop();
            defer container_backing.releaseValue(b);
            const a = try ctx.stack.pop();
            defer container_backing.releaseValue(a);

            if (type_a == .fixnum and type_b == .fixnum) {
                if (b.fixnum == 0) return error.DivisionByZero;
                if (a.fixnum == std.math.minInt(i64) and b.fixnum == -1) {
                    var ba = try BigIntManaged.initSet(alloc, a.fixnum);
                    var bb = try BigIntManaged.initSet(alloc, b.fixnum);
                    var q = try BigIntManaged.init(alloc);
                    var r = try BigIntManaged.init(alloc);
                    try q.divTrunc(&r, &ba, &bb);
                    ba.deinit();
                    bb.deinit();
                    r.deinit();
                    try ctx.stack.push(try demoteBignum(alloc, q));
                } else {
                    try ctx.stack.push(.{ .fixnum = @divTrunc(a.fixnum, b.fixnum) });
                }
            } else if ((type_a == .bignum or type_a == .fixnum) and (type_b == .bignum or type_b == .fixnum)) {
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
                try ctx.stack.push(try demoteBignum(alloc, q));
            } else {
                try ctx.stack.push(.{ .float = valToFloat(alloc, a) / valToFloat(alloc, b) });
            }
        }
    }.func;
}

/// Generate a native dispatch function for modulo (%).
fn makeModEntry(comptime type_a: NumType, comptime type_b: NumType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const alloc = ctx.arena.allocator();
            const b = try ctx.stack.pop();
            defer container_backing.releaseValue(b);
            const a = try ctx.stack.pop();
            defer container_backing.releaseValue(a);

            if (type_a == .fixnum and type_b == .fixnum) {
                if (b.fixnum == 0) return error.DivisionByZero;
                try ctx.stack.push(.{ .fixnum = @mod(a.fixnum, b.fixnum) });
            } else if ((type_a == .bignum or type_a == .fixnum) and (type_b == .bignum or type_b == .fixnum)) {
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
                try ctx.stack.push(try demoteBignum(alloc, r));
            } else {
                try ctx.stack.push(.{ .float = @rem(valToFloat(alloc, a), valToFloat(alloc, b)) });
            }
        }
    }.func;
}

/// Generate a native dispatch function for cross-type equality (=).
fn makeEqCrossTypeEntry(comptime type_a: NumType, comptime type_b: NumType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const b = try ctx.stack.pop();
            defer container_backing.releaseValue(b);
            const a = try ctx.stack.pop();
            defer container_backing.releaseValue(a);

            if (type_a == .fixnum and type_b == .float) {
                const af: f64 = @floatFromInt(a.fixnum);
                try ctx.stack.push(.{ .boolean = af == b.float });
            } else if (type_a == .float and type_b == .fixnum) {
                const bf: f64 = @floatFromInt(b.fixnum);
                try ctx.stack.push(.{ .boolean = a.float == bf });
            } else if (type_a == .fixnum and type_b == .bignum) {
                try ctx.stack.push(.{ .boolean = b.bignum.toConst().orderAgainstScalar(a.fixnum) == .eq });
            } else if (type_a == .bignum and type_b == .fixnum) {
                try ctx.stack.push(.{ .boolean = a.bignum.toConst().orderAgainstScalar(b.fixnum) == .eq });
            } else if (type_a == .bignum and type_b == .float) {
                const alloc = ctx.arena.allocator();
                try ctx.stack.push(.{ .boolean = valToFloat(alloc, a) == b.float });
            } else if (type_a == .float and type_b == .bignum) {
                const alloc = ctx.arena.allocator();
                try ctx.stack.push(.{ .boolean = a.float == valToFloat(alloc, b) });
            }
        }
    }.func;
}

/// Generate a native dispatch function for < comparison.
fn makeLtEntry(comptime type_a: NumType, comptime type_b: NumType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const b = try ctx.stack.pop();
            defer container_backing.releaseValue(b);
            const a = try ctx.stack.pop();
            defer container_backing.releaseValue(a);

            if (type_a == .fixnum and type_b == .fixnum) {
                try ctx.stack.push(.{ .boolean = a.fixnum < b.fixnum });
            } else if (type_a == .fixnum and type_b == .float) {
                try ctx.stack.push(.{ .boolean = @as(f64, @floatFromInt(a.fixnum)) < b.float });
            } else if (type_a == .fixnum and type_b == .bignum) {
                try ctx.stack.push(.{ .boolean = b.bignum.toConst().orderAgainstScalar(a.fixnum) == .gt });
            } else if (type_a == .float and type_b == .fixnum) {
                try ctx.stack.push(.{ .boolean = a.float < @as(f64, @floatFromInt(b.fixnum)) });
            } else if (type_a == .float and type_b == .float) {
                try ctx.stack.push(.{ .boolean = a.float < b.float });
            } else if (type_a == .float and type_b == .bignum) {
                try ctx.stack.push(.{ .boolean = a.float < valToFloat(ctx.arena.allocator(), b) });
            } else if (type_a == .bignum and type_b == .fixnum) {
                try ctx.stack.push(.{ .boolean = a.bignum.toConst().orderAgainstScalar(b.fixnum) == .lt });
            } else if (type_a == .bignum and type_b == .float) {
                try ctx.stack.push(.{ .boolean = valToFloat(ctx.arena.allocator(), a) < b.float });
            } else if (type_a == .bignum and type_b == .bignum) {
                try ctx.stack.push(.{ .boolean = a.bignum.toConst().order(b.bignum.toConst()) == .lt });
            }
        }
    }.func;
}

/// Generate a native dispatch function for > comparison.
fn makeGtEntry(comptime type_a: NumType, comptime type_b: NumType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const b = try ctx.stack.pop();
            defer container_backing.releaseValue(b);
            const a = try ctx.stack.pop();
            defer container_backing.releaseValue(a);

            if (type_a == .fixnum and type_b == .fixnum) {
                try ctx.stack.push(.{ .boolean = a.fixnum > b.fixnum });
            } else if (type_a == .fixnum and type_b == .float) {
                try ctx.stack.push(.{ .boolean = @as(f64, @floatFromInt(a.fixnum)) > b.float });
            } else if (type_a == .fixnum and type_b == .bignum) {
                try ctx.stack.push(.{ .boolean = b.bignum.toConst().orderAgainstScalar(a.fixnum) == .lt });
            } else if (type_a == .float and type_b == .fixnum) {
                try ctx.stack.push(.{ .boolean = a.float > @as(f64, @floatFromInt(b.fixnum)) });
            } else if (type_a == .float and type_b == .float) {
                try ctx.stack.push(.{ .boolean = a.float > b.float });
            } else if (type_a == .float and type_b == .bignum) {
                try ctx.stack.push(.{ .boolean = a.float > valToFloat(ctx.arena.allocator(), b) });
            } else if (type_a == .bignum and type_b == .fixnum) {
                try ctx.stack.push(.{ .boolean = a.bignum.toConst().orderAgainstScalar(b.fixnum) == .gt });
            } else if (type_a == .bignum and type_b == .float) {
                try ctx.stack.push(.{ .boolean = valToFloat(ctx.arena.allocator(), a) > b.float });
            } else if (type_a == .bignum and type_b == .bignum) {
                try ctx.stack.push(.{ .boolean = a.bignum.toConst().order(b.bignum.toConst()) == .gt });
            }
        }
    }.func;
}

/// Generate a native dispatch function for cmp.
fn makeCmpEntry(comptime type_a: NumType, comptime type_b: NumType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const b = try ctx.stack.pop();
            defer container_backing.releaseValue(b);
            const a = try ctx.stack.pop();
            defer container_backing.releaseValue(a);

            const result: i64 = blk: {
                if (type_a == .fixnum and type_b == .fixnum) {
                    break :blk if (a.fixnum < b.fixnum) @as(i64, -1) else if (a.fixnum > b.fixnum) @as(i64, 1) else @as(i64, 0);
                } else if (type_a == .fixnum and type_b == .float) {
                    if (std.math.isNan(b.float)) {
                        helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                        return error.NotComparable;
                    }
                    const af: f64 = @floatFromInt(a.fixnum);
                    break :blk if (af < b.float) @as(i64, -1) else if (af > b.float) @as(i64, 1) else @as(i64, 0);
                } else if (type_a == .fixnum and type_b == .bignum) {
                    break :blk switch (b.bignum.toConst().orderAgainstScalar(a.fixnum)) {
                        .lt => @as(i64, 1),
                        .gt => @as(i64, -1),
                        .eq => @as(i64, 0),
                    };
                } else if (type_a == .float and type_b == .fixnum) {
                    if (std.math.isNan(a.float)) {
                        helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                        return error.NotComparable;
                    }
                    const bf: f64 = @floatFromInt(b.fixnum);
                    break :blk if (a.float < bf) @as(i64, -1) else if (a.float > bf) @as(i64, 1) else @as(i64, 0);
                } else if (type_a == .float and type_b == .float) {
                    if (std.math.isNan(a.float) or std.math.isNan(b.float)) {
                        helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                        return error.NotComparable;
                    }
                    break :blk if (a.float < b.float) @as(i64, -1) else if (a.float > b.float) @as(i64, 1) else @as(i64, 0);
                } else if (type_a == .float and type_b == .bignum) {
                    if (std.math.isNan(a.float)) {
                        helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                        return error.NotComparable;
                    }
                    const bf = valToFloat(ctx.arena.allocator(), b);
                    if (std.math.isNan(bf)) {
                        helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                        return error.NotComparable;
                    }
                    break :blk if (a.float < bf) @as(i64, -1) else if (a.float > bf) @as(i64, 1) else @as(i64, 0);
                } else if (type_a == .bignum and type_b == .fixnum) {
                    break :blk switch (a.bignum.toConst().orderAgainstScalar(b.fixnum)) {
                        .lt => @as(i64, -1),
                        .gt => @as(i64, 1),
                        .eq => @as(i64, 0),
                    };
                } else if (type_a == .bignum and type_b == .float) {
                    if (std.math.isNan(b.float)) {
                        helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                        return error.NotComparable;
                    }
                    const af = valToFloat(ctx.arena.allocator(), a);
                    if (std.math.isNan(af)) {
                        helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                        return error.NotComparable;
                    }
                    break :blk if (af < b.float) @as(i64, -1) else if (af > b.float) @as(i64, 1) else @as(i64, 0);
                } else if (type_a == .bignum and type_b == .bignum) {
                    break :blk switch (a.bignum.toConst().order(b.bignum.toConst())) {
                        .lt => @as(i64, -1),
                        .gt => @as(i64, 1),
                        .eq => @as(i64, 0),
                    };
                } else unreachable;
            };

            try ctx.stack.push(.{ .fixnum = result });
        }
    }.func;
}

// =============================================================================
// Individual unary dispatch entries
// =============================================================================

fn nativeAbsFixnum(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const i = val.fixnum;
    if (i == std.math.minInt(i64)) {
        const alloc = ctx.arena.allocator();
        var big = try BigIntManaged.initSet(alloc, i);
        big.abs();
        try ctx.stack.push(try demoteBignum(alloc, big));
    } else {
        try ctx.stack.push(.{ .fixnum = if (i < 0) -i else i });
    }
}

fn nativeAbsBignum(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    var big = try val.bignum.clone();
    big.abs();
    try ctx.stack.push(try demoteBignum(ctx.arena.allocator(), big));
}

fn nativeAbsFloat(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    try ctx.stack.push(.{ .float = @abs(val.float) });
}

fn nativeToFloatFixnum(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    try ctx.stack.push(.{ .float = @floatFromInt(val.fixnum) });
}

fn nativeToFloatPassthrough(ctx: *Context) anyerror!void {
    // float is already on the stack; nothing to do
    _ = ctx;
}

fn nativeToFloatBignum(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const alloc = ctx.arena.allocator();
    const str = try val.bignum.toConst().toStringAlloc(alloc, 10, .lower);
    const f = std.fmt.parseFloat(f64, str) catch {
        helpers.setErrorContext(ctx, ">float: cannot convert bignum to float", .{});
        return error.TypeMismatch;
    };
    try ctx.stack.push(.{ .float = f });
}

fn nativeToFloatString(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const f = std.fmt.parseFloat(f64, val.string.bytes) catch {
        helpers.setErrorContext(ctx, ">float: cannot parse \"{s}\" as float", .{val.string.bytes});
        return error.TypeMismatch;
    };
    try ctx.stack.push(.{ .float = f });
}

fn nativeToIntegerFloat(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const f = val.float;
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
}

fn nativeToIntegerPassthrough(ctx: *Context) anyerror!void {
    // fixnum is already on the stack; nothing to do
    _ = ctx;
}

// =============================================================================
// String / byte-array lexicographic comparison helpers and dispatch entries
// =============================================================================

const ByteType = enum { string, byte_array };

fn extractBytes(comptime bt: ByteType, val: Value) []const u8 {
    return switch (bt) {
        .string => val.string.bytes,
        .byte_array => val.byte_array.slice(),
    };
}

fn lexOrder(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

fn makeBytesLtEntry(comptime ta: ByteType, comptime tb: ByteType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const b = try ctx.stack.pop();
            defer container_backing.releaseValue(b);
            const a = try ctx.stack.pop();
            defer container_backing.releaseValue(a);
            try ctx.stack.push(.{ .boolean = lexOrder(extractBytes(ta, a), extractBytes(tb, b)) == .lt });
        }
    }.func;
}

fn makeBytesGtEntry(comptime ta: ByteType, comptime tb: ByteType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const b = try ctx.stack.pop();
            defer container_backing.releaseValue(b);
            const a = try ctx.stack.pop();
            defer container_backing.releaseValue(a);
            try ctx.stack.push(.{ .boolean = lexOrder(extractBytes(ta, a), extractBytes(tb, b)) == .gt });
        }
    }.func;
}

const byte_types = [_]ByteType{ .string, .byte_array };

fn byteTypeName(comptime bt: ByteType) []const u8 {
    return switch (bt) {
        .string => "string",
        .byte_array => "byte_array",
    };
}

// =============================================================================
// Registration of all native dispatch entries
// =============================================================================

pub fn registerNativeDispatch(dispatch: *DispatchTable, ctx: *Context) !void {
    const unary = ctx.getDispatchUnarySentinel();

    // Look up builtin TypeValue pointers
    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const bignum_tv = ctx.lookupBuiltinTypeValue("bignum").?;
    const float_tv = ctx.lookupBuiltinTypeValue("float").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const byte_array_tv = ctx.lookupBuiltinTypeValue("byte-array").?;

    const num_tvs = [_]*const value_mod.TypeValue{ fixnum_tv, bignum_tv, float_tv };
    const byte_tvs = [_]*const value_mod.TypeValue{ string_tv, byte_array_tv };

    // +, -, * : 9 entries each (3x3 numeric matrix)
    inline for ([_]struct { op: ArithOp, name: []const u8 }{
        .{ .op = .add, .name = "+" },
        .{ .op = .sub, .name = "-" },
        .{ .op = .mul, .name = "*" },
    }) |item| {
        const did = ctx.resolveDispatchId(item.name).?;
        inline for (num_types) |ta| {
            inline for (num_types) |tb| {
                try dispatch.registerNative(did, num_tvs[@intFromEnum(ta)].descriptor.?, num_tvs[@intFromEnum(tb)].descriptor.?, makeBinaryArithEntry(item.op, ta, tb));
            }
        }
    }

    // / : 9 entries
    const div_did = ctx.resolveDispatchId("/").?;
    inline for (num_types) |ta| {
        inline for (num_types) |tb| {
            try dispatch.registerNative(div_did, num_tvs[@intFromEnum(ta)].descriptor.?, num_tvs[@intFromEnum(tb)].descriptor.?, makeDivEntry(ta, tb));
        }
    }

    // % : 9 entries
    const mod_did = ctx.resolveDispatchId("%").?;
    inline for (num_types) |ta| {
        inline for (num_types) |tb| {
            try dispatch.registerNative(mod_did, num_tvs[@intFromEnum(ta)].descriptor.?, num_tvs[@intFromEnum(tb)].descriptor.?, makeModEntry(ta, tb));
        }
    }

    // = : 6 cross-type numeric entries, plus same-type entries for every
    // comparable builtin. The same-type entries keep `=` on native value
    // equality instead of deriving it from `cmp` (which throws on NaN) once the
    // comparable builtins gained `cmp` methods.
    const eq_did = ctx.resolveDispatchId("=").?;
    inline for (num_types) |ta| {
        inline for (num_types) |tb| {
            if (ta != tb) {
                try dispatch.registerNative(eq_did, num_tvs[@intFromEnum(ta)], num_tvs[@intFromEnum(tb)], makeEqCrossTypeEntry(ta, tb));
            } else {
                try dispatch.registerNative(eq_did, num_tvs[@intFromEnum(ta)], num_tvs[@intFromEnum(tb)], nativeEqSameType);
            }
        }
    }
    inline for (byte_types) |t| {
        try dispatch.registerNative(eq_did, byte_tvs[@intFromEnum(t)], byte_tvs[@intFromEnum(t)], nativeEqSameType);
    }

    // < : 9 entries
    const lt_did = ctx.resolveDispatchId("<").?;
    inline for (num_types) |ta| {
        inline for (num_types) |tb| {
            try dispatch.registerNative(lt_did, num_tvs[@intFromEnum(ta)], num_tvs[@intFromEnum(tb)], makeLtEntry(ta, tb));
        }
    }

    // > : 9 entries
    const gt_did = ctx.resolveDispatchId(">").?;
    inline for (num_types) |ta| {
        inline for (num_types) |tb| {
            try dispatch.registerNative(gt_did, num_tvs[@intFromEnum(ta)], num_tvs[@intFromEnum(tb)], makeGtEntry(ta, tb));
        }
    }

    // abs : 3 entries
    const abs_did = ctx.resolveDispatchId("abs").?;
    try dispatch.registerNative(abs_did, fixnum_tv, unary, nativeAbsFixnum);
    try dispatch.registerNative(abs_did, bignum_tv, unary, nativeAbsBignum);
    try dispatch.registerNative(abs_did, float_tv, unary, nativeAbsFloat);

    // >float : 4 entries
    const to_float_did = ctx.resolveDispatchId(">float").?;
    try dispatch.registerNative(to_float_did, fixnum_tv, unary, nativeToFloatFixnum);
    try dispatch.registerNative(to_float_did, float_tv, unary, nativeToFloatPassthrough);
    try dispatch.registerNative(to_float_did, bignum_tv, unary, nativeToFloatBignum);
    try dispatch.registerNative(to_float_did, string_tv, unary, nativeToFloatString);

    // >integer : 2 entries
    const to_integer_did = ctx.resolveDispatchId(">integer").?;
    try dispatch.registerNative(to_integer_did, float_tv, unary, nativeToIntegerFloat);
    try dispatch.registerNative(to_integer_did, fixnum_tv, unary, nativeToIntegerPassthrough);

    // <, > for string/byte_array : 4 entries each (2x2 matrix)
    inline for (byte_types) |ta| {
        inline for (byte_types) |tb| {
            try dispatch.registerNative(lt_did, byte_tvs[@intFromEnum(ta)], byte_tvs[@intFromEnum(tb)], makeBytesLtEntry(ta, tb));
            try dispatch.registerNative(gt_did, byte_tvs[@intFromEnum(ta)], byte_tvs[@intFromEnum(tb)], makeBytesGtEntry(ta, tb));
        }
    }
}

// =============================================================================
// Primitive implementations (thin dispatch-then-error wrappers)
// =============================================================================

pub fn nativeAdd(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "+")) return;
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    helpers.setErrorHint(ctx, "operands must be numbers (fixnum, float, bignum, or ratio)");
    helpers.setTypeMismatchError(ctx, "number", if (!isNativeNumeric(a)) a else b);
    return error.TypeMismatch;
}

pub fn nativeSub(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "-")) return;
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    helpers.setErrorHint(ctx, "operands must be numbers (fixnum, float, bignum, or ratio)");
    helpers.setTypeMismatchError(ctx, "number", if (!isNativeNumeric(a)) a else b);
    return error.TypeMismatch;
}

pub fn nativeMul(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "*")) return;
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    helpers.setErrorHint(ctx, "operands must be numbers (fixnum, float, bignum, or ratio)");
    helpers.setTypeMismatchError(ctx, "number", if (!isNativeNumeric(a)) a else b);
    return error.TypeMismatch;
}

/// / ( a b -- a/b ) - Division
pub fn nativeDiv(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "/")) return;
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    helpers.setErrorHint(ctx, "operands must be numbers (fixnum, float, bignum, or ratio)");
    helpers.setTypeMismatchError(ctx, "number", if (!isNativeNumeric(a)) a else b);
    return error.TypeMismatch;
}

/// % ( a b -- a%b ) - Modulo / fmod
pub fn nativeMod(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "%")) return;
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    helpers.setErrorHint(ctx, "operands must be numbers (fixnum, float, bignum, or ratio)");
    helpers.setTypeMismatchError(ctx, "number", if (!isNativeNumeric(a)) a else b);
    return error.TypeMismatch;
}

fn wrapArithOp(ctx: *Context, comptime op: ArithOp) anyerror!void {
    const b = try popFixnum(ctx);
    const a = try popFixnum(ctx);
    try ctx.stack.push(.{ .fixnum = switch (op) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
    } });
}

pub fn nativeAddWrap(ctx: *Context) anyerror!void {
    return wrapArithOp(ctx, .add);
}
pub fn nativeSubWrap(ctx: *Context) anyerror!void {
    return wrapArithOp(ctx, .sub);
}
pub fn nativeMulWrap(ctx: *Context) anyerror!void {
    return wrapArithOp(ctx, .mul);
}

/// = ( a b -- ? ) - Equality comparison
pub fn nativeEq(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "=")) return;
    if (try dispatch_helpers.tryDispatchBinaryViaCmp(ctx, .eq)) return;
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    try ctx.stack.push(.{ .boolean = a.eql(b) });
}

/// = same-type dispatch entry for the builtin comparable types. Uses native
/// value equality directly, so `=` does not derive from `cmp` via
/// `tryDispatchBinaryViaCmp` for these types -- `cmp` throws on NaN, whereas
/// `=` must report NaN as unequal rather than raise.
fn nativeEqSameType(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    try ctx.stack.push(.{ .boolean = a.eql(b) });
}

/// (=) ( a b -- ? ) - Inner equality: unwraps one layer of tagged values, then compares
pub fn nativeInnerEq(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    const a_inner: Value = if (a == .tagged) a.tagged.inner.* else a;
    const b_inner: Value = if (b == .tagged) b.tagged.inner.* else b;
    try ctx.stack.push(.{ .boolean = a_inner.eql(b_inner) });
}

/// < ( a b -- ? ) - Less than
pub fn nativeLt(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "<")) return;
    if (try dispatch_helpers.tryDispatchBinaryViaCmp(ctx, .lt)) return;
    try ctx.stack.popAndRelease();
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    helpers.setTypeMismatchError(ctx, "fixnum or float", a);
    return error.TypeMismatch;
}

/// > ( a b -- ? ) - Greater than
pub fn nativeGt(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, ">")) return;
    if (try dispatch_helpers.tryDispatchBinaryViaCmp(ctx, .gt)) return;
    try ctx.stack.popAndRelease();
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    helpers.setTypeMismatchError(ctx, "fixnum or float", a);
    return error.TypeMismatch;
}

/// >float ( x -- f ) - Convert fixnum or string to float
fn nativeToFloat(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ">float")) return;
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    helpers.setTypeMismatchError(ctx, "fixnum, bignum, float, or string", val);
    return error.TypeMismatch;
}

/// >integer ( f -- n ) - Float to fixnum, truncate toward zero
fn nativeToInteger(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ">integer")) return;
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    helpers.setTypeMismatchError(ctx, "float or fixnum", val);
    return error.TypeMismatch;
}

/// float-parts ( f -- mantissa exponent sign ) - Decompose an IEEE 754 double
fn nativeFloatParts(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    if (val != .float) {
        helpers.setTypeMismatchError(ctx, "float", val);
        return error.TypeMismatch;
    }
    const f = val.float;
    if (std.math.isNan(f)) {
        helpers.setErrorContext(ctx, "float-parts: NaN has no finite decomposition", .{});
        return error.TypeMismatch;
    }
    if (std.math.isInf(f)) {
        helpers.setErrorContext(ctx, "float-parts: infinity has no finite decomposition", .{});
        return error.TypeMismatch;
    }
    const sign: i64 = if (std.math.signbit(f)) -1 else 1;
    if (f == 0.0) {
        try ctx.stack.push(.{ .fixnum = 0 });
        try ctx.stack.push(.{ .fixnum = 0 });
        try ctx.stack.push(.{ .fixnum = sign });
        return;
    }
    const bits: u64 = @bitCast(f);
    const raw_exp = @as(i64, @intCast((bits >> 52) & 0x7FF));
    const raw_mantissa = bits & 0x000FFFFFFFFFFFFF;
    if (raw_exp == 0) {
        // Subnormal: mantissa is raw_mantissa, exponent is 1 - 1023 - 52 = -1074
        try ctx.stack.push(.{ .fixnum = @intCast(raw_mantissa) });
        try ctx.stack.push(.{ .fixnum = -1074 });
    } else {
        // Normal: mantissa has implicit 1 bit
        const mantissa: i64 = @intCast(raw_mantissa | (1 << 52));
        const exponent: i64 = raw_exp - 1023 - 52;
        try ctx.stack.push(.{ .fixnum = mantissa });
        try ctx.stack.push(.{ .fixnum = exponent });
    }
    try ctx.stack.push(.{ .fixnum = sign });
}

/// abs ( n -- n ) - Absolute value for fixnums, bignums, and floats
fn nativeAbs(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "abs")) return;
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    helpers.setTypeMismatchError(ctx, "number", val);
    return error.TypeMismatch;
}

/// div ( a b -- q ) - Truncating integer division toward zero
fn nativeTruncDiv(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
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
            try ctx.stack.push(try demoteBignum(alloc, q));
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
        try ctx.stack.push(try demoteBignum(alloc, q));
    } else {
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", if (a != .fixnum and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

/// rem ( a b -- r ) - Truncating integer remainder
fn nativeTruncRem(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    if (a == .fixnum and b == .fixnum) {
        if (b.fixnum == 0) return error.DivisionByZero;
        if (a.fixnum == std.math.minInt(i64) and b.fixnum == -1) {
            try ctx.stack.push(.{ .fixnum = 0 });
            return;
        }
        try ctx.stack.push(.{ .fixnum = @rem(a.fixnum, b.fixnum) });
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
        q.deinit();
        try ctx.stack.push(try demoteBignum(alloc, r));
    } else {
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", if (a != .fixnum and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "float-approx-ratio", .func = nativeFloatApproxRatio },
    .{ .name = "cmp", .stack_effect = "a b -- n", .func = nativeCmp },
};

/// float-approx-ratio ( f -- numer denom ) - Continued fraction approximation
fn nativeFloatApproxRatio(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    if (val != .float) {
        helpers.setTypeMismatchError(ctx, "float", val);
        return error.TypeMismatch;
    }
    const f = val.float;
    if (std.math.isNan(f) or std.math.isInf(f)) {
        helpers.setErrorContext(ctx, "float-approx-ratio: NaN and infinity have no rational representation", .{});
        return error.TypeMismatch;
    }
    if (f == 0.0) {
        try ctx.stack.push(.{ .fixnum = 0 });
        try ctx.stack.push(.{ .fixnum = 1 });
        return;
    }

    const sign: i64 = if (f < 0) -1 else 1;
    var x: f64 = @abs(f);
    var h0: i64 = 1;
    var h1: i64 = 0;
    var k0: i64 = 0;
    var k1: i64 = 1;

    for (0..50) |_| {
        const a: i64 = @intFromFloat(@floor(x));
        const h = a *% h0 +% h1;
        const k = a *% k0 +% k1;
        h1 = h0;
        h0 = h;
        k1 = k0;
        k0 = k;
        const approx = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(k));
        if (@abs(approx - @abs(f)) <= @abs(f) * 1e-15) break;
        const remainder = x - @as(f64, @floatFromInt(a));
        if (remainder == 0.0) break;
        x = 1.0 / remainder;
    }

    try ctx.stack.push(.{ .fixnum = sign *% h0 });
    try ctx.stack.push(.{ .fixnum = k0 });
}

/// gcd ( a b -- gcd ) - Greatest common divisor, always non-negative
fn nativeGcd(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    if (a == .fixnum and b == .fixnum) {
        const av = a.fixnum;
        const bv = b.fixnum;
        if (av == 0 and bv == 0) {
            try ctx.stack.push(.{ .fixnum = 0 });
        } else if (av == std.math.minInt(i64) or bv == std.math.minInt(i64)) {
            const alloc = ctx.arena.allocator();
            var ba = try BigIntManaged.initSet(alloc, av);
            ba.abs();
            var bb = try BigIntManaged.initSet(alloc, bv);
            bb.abs();
            var result = try BigIntManaged.init(alloc);
            try result.gcd(&ba, &bb);
            ba.deinit();
            bb.deinit();
            try ctx.stack.push(try demoteBignum(alloc, result));
        } else {
            const abs_a: u64 = @intCast(if (av < 0) -av else av);
            const abs_b: u64 = @intCast(if (bv < 0) -bv else bv);
            if (abs_a == 0) {
                try ctx.stack.push(.{ .fixnum = @intCast(abs_b) });
            } else if (abs_b == 0) {
                try ctx.stack.push(.{ .fixnum = @intCast(abs_a) });
            } else {
                const g = std.math.gcd(abs_a, abs_b);
                try ctx.stack.push(.{ .fixnum = @intCast(g) });
            }
        }
    } else if ((a == .bignum or a == .fixnum) and (b == .bignum or b == .fixnum)) {
        const alloc = ctx.arena.allocator();
        var ba = try ensureBignum(alloc, a);
        ba.abs();
        var bb = try ensureBignum(alloc, b);
        bb.abs();
        if (ba.eqlZero() and bb.eqlZero()) {
            ba.deinit();
            bb.deinit();
            try ctx.stack.push(.{ .fixnum = 0 });
        } else {
            var result = try BigIntManaged.init(alloc);
            try result.gcd(&ba, &bb);
            ba.deinit();
            bb.deinit();
            try ctx.stack.push(try demoteBignum(alloc, result));
        }
    } else {
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", if (a != .fixnum and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

/// cmp ( a b -- fixnum ) - Raw three-way comparison returning -1, 0, or 1.
///
/// Handles the built-in comparable types directly. Polymorphic dispatch to
/// user types is the job of the `cmp` generic, so this primitive does not
/// dispatch itself. NaN on either operand produces NotComparable.
fn nativeCmp(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();

    const b = try ctx.stack.pop();
    defer container_backing.releaseValue(b);
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);

    const result: i64 = switch (a) {
        .fixnum => |av| switch (b) {
            .fixnum => |bv| if (av < bv) @as(i64, -1) else if (av > bv) @as(i64, 1) else @as(i64, 0),
            .float => |bv| blk: {
                if (std.math.isNan(bv)) {
                    helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                    return error.NotComparable;
                }
                const af: f64 = @floatFromInt(av);
                break :blk if (af < bv) @as(i64, -1) else if (af > bv) @as(i64, 1) else @as(i64, 0);
            },
            .bignum => |bv| switch (bv.toConst().orderAgainstScalar(av)) {
                .lt => @as(i64, 1),
                .gt => @as(i64, -1),
                .eq => @as(i64, 0),
            },
            else => {
                helpers.setErrorContext(ctx, "cmp: values are not comparable", .{});
                return error.NotComparable;
            },
        },
        .float => |av| switch (b) {
            .float => |bv| blk: {
                if (std.math.isNan(av) or std.math.isNan(bv)) {
                    helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                    return error.NotComparable;
                }
                break :blk if (av < bv) @as(i64, -1) else if (av > bv) @as(i64, 1) else @as(i64, 0);
            },
            .fixnum => |bv| blk: {
                if (std.math.isNan(av)) {
                    helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                    return error.NotComparable;
                }
                const bf: f64 = @floatFromInt(bv);
                break :blk if (av < bf) @as(i64, -1) else if (av > bf) @as(i64, 1) else @as(i64, 0);
            },
            .bignum => blk: {
                if (std.math.isNan(av)) {
                    helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                    return error.NotComparable;
                }
                const bf = valToFloat(alloc, b);
                if (std.math.isNan(bf)) {
                    helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                    return error.NotComparable;
                }
                break :blk if (av < bf) @as(i64, -1) else if (av > bf) @as(i64, 1) else @as(i64, 0);
            },
            else => {
                helpers.setErrorContext(ctx, "cmp: values are not comparable", .{});
                return error.NotComparable;
            },
        },
        .bignum => |av| switch (b) {
            .bignum => |bv| switch (av.toConst().order(bv.toConst())) {
                .lt => @as(i64, -1),
                .gt => @as(i64, 1),
                .eq => @as(i64, 0),
            },
            .fixnum => |bv| switch (av.toConst().orderAgainstScalar(bv)) {
                .lt => @as(i64, -1),
                .gt => @as(i64, 1),
                .eq => @as(i64, 0),
            },
            .float => |bv| blk: {
                if (std.math.isNan(bv)) {
                    helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                    return error.NotComparable;
                }
                const af = valToFloat(alloc, a);
                if (std.math.isNan(af)) {
                    helpers.setErrorContext(ctx, "cmp: NaN is not comparable", .{});
                    return error.NotComparable;
                }
                break :blk if (af < bv) @as(i64, -1) else if (af > bv) @as(i64, 1) else @as(i64, 0);
            },
            else => {
                helpers.setErrorContext(ctx, "cmp: values are not comparable", .{});
                return error.NotComparable;
            },
        },
        .string => |av| switch (b) {
            .string => |bv| switch (std.mem.order(u8, av.bytes, bv.bytes)) {
                .lt => @as(i64, -1),
                .gt => @as(i64, 1),
                .eq => @as(i64, 0),
            },
            .byte_array => |bv| switch (std.mem.order(u8, av.bytes, bv.slice())) {
                .lt => @as(i64, -1),
                .gt => @as(i64, 1),
                .eq => @as(i64, 0),
            },
            else => {
                helpers.setErrorContext(ctx, "cmp: values are not comparable", .{});
                return error.NotComparable;
            },
        },
        .byte_array => |av| switch (b) {
            .string => |bv| switch (std.mem.order(u8, av.slice(), bv.bytes)) {
                .lt => @as(i64, -1),
                .gt => @as(i64, 1),
                .eq => @as(i64, 0),
            },
            .byte_array => |bv| switch (std.mem.order(u8, av.slice(), bv.slice())) {
                .lt => @as(i64, -1),
                .gt => @as(i64, 1),
                .eq => @as(i64, 0),
            },
            else => {
                helpers.setErrorContext(ctx, "cmp: values are not comparable", .{});
                return error.NotComparable;
            },
        },
        else => {
            helpers.setErrorContext(ctx, "cmp: values are not comparable", .{});
            return error.NotComparable;
        },
    };

    try ctx.stack.push(.{ .fixnum = result });
}
