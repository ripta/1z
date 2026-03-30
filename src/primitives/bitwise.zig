const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const BigIntManaged = value_mod.BigIntManaged;
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const dispatch_helpers = @import("dispatch_helpers.zig");
const dispatch_mod = @import("../dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;
const unary_sentinel = dispatch_mod.unary_sentinel;
const markers_mod = @import("markers.zig");

const demoteBignum = helpers.demoteBignum;
const ensureBignum = helpers.ensureBignum;

pub const primitives = [_]Primitive{
    .{ .name = "bitand", .stack_effect = "a b -- a&b", .doc = "Bitwise AND. Works on fixnums and bignums with two's complement semantics.", .func = nativeBitand, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "bitor", .stack_effect = "a b -- a|b", .doc = "Bitwise OR. Works on fixnums and bignums with two's complement semantics.", .func = nativeBitor, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "bitxor", .stack_effect = "a b -- a^b", .doc = "Bitwise XOR. Works on fixnums and bignums with two's complement semantics.", .func = nativeBitxor, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "bitnot", .stack_effect = "a -- ~a", .doc = "Bitwise NOT (two's complement): ~x = -(x+1). Works on fixnums and bignums.", .func = nativeBitnot, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "shift-left", .stack_effect = "n count -- n'", .doc = "Left shift by count bits. Count must be a non-negative fixnum. Promotes to bignum on overflow.", .func = nativeShiftLeft, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "shift-right", .stack_effect = "n count -- n'", .doc = "Arithmetic (sign-extending) right shift by count bits. Count must be a non-negative fixnum.", .func = nativeShiftRight, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "ushift-right", .stack_effect = "n count -- n'", .doc = "Logical (zero-filling) right shift. Fixnum-only; throws on bignum.", .func = nativeUshiftRight, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "shift", .stack_effect = "n count -- n'", .doc = "Shift: positive count = left shift, negative count = arithmetic right shift.", .func = nativeShift, .markers = &.{@constCast(&markers_mod.generic_marker)} },
};

// =============================================================================
// Bitwise type enum used by comptime dispatch entry generators
// =============================================================================

const BitType = enum { fixnum, bignum };

const bit_types = [_]BitType{ .fixnum, .bignum };

fn bitTypeName(comptime t: BitType) []const u8 {
    return switch (t) {
        .fixnum => "fixnum",
        .bignum => "bignum",
    };
}

// =============================================================================
// Comptime dispatch entry generators
// =============================================================================

const BitwiseOp = enum { bitand, bitor, bitxor };

fn bignumBitwiseOp(comptime op: BitwiseOp, ba: *BigIntManaged, bb: *BigIntManaged) !void {
    switch (op) {
        .bitand => try ba.bitAnd(ba, bb),
        .bitor => try ba.bitOr(ba, bb),
        .bitxor => try ba.bitXor(ba, bb),
    }
}

fn makeBinaryBitwiseEntry(comptime op: BitwiseOp, comptime type_a: BitType, comptime type_b: BitType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const alloc = ctx.arena.allocator();
            const b = try ctx.stack.pop();
            const a = try ctx.stack.pop();

            if (type_a == .fixnum and type_b == .fixnum) {
                try ctx.stack.push(.{ .fixnum = switch (op) {
                    .bitand => a.fixnum & b.fixnum,
                    .bitor => a.fixnum | b.fixnum,
                    .bitxor => a.fixnum ^ b.fixnum,
                } });
            } else {
                var ba = try ensureBignum(alloc, a);
                var bb = try ensureBignum(alloc, b);
                try bignumBitwiseOp(op, &ba, &bb);
                bb.deinit();
                try ctx.stack.push(demoteBignum(ba));
            }
        }
    }.func;
}

fn makeBitnotEntry(comptime t: BitType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const val = try ctx.stack.pop();
            if (t == .fixnum) {
                try ctx.stack.push(.{ .fixnum = ~val.fixnum });
            } else {
                const alloc = ctx.arena.allocator();
                var result = try val.bignum.clone();
                var one = try BigIntManaged.initSet(alloc, @as(i64, 1));
                defer one.deinit();
                try result.add(&result, &one);
                result.negate();
                try ctx.stack.push(demoteBignum(result));
            }
        }
    }.func;
}

fn makeShiftLeftEntry(comptime t: BitType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const count = try popShiftCount(ctx);
            const val = try ctx.stack.pop();
            const alloc = ctx.arena.allocator();
            var big = try ensureBignum(alloc, if (t == .fixnum) val else val);
            try big.shiftLeft(&big, count);
            try ctx.stack.push(demoteBignum(big));
        }
    }.func;
}

fn makeShiftRightEntry(comptime t: BitType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const count = try popShiftCount(ctx);
            const val = try ctx.stack.pop();
            if (t == .fixnum) {
                if (count >= 64) {
                    try ctx.stack.push(.{ .fixnum = if (val.fixnum < 0) @as(i64, -1) else @as(i64, 0) });
                } else {
                    try ctx.stack.push(.{ .fixnum = std.math.shr(i64, val.fixnum, @as(u6, @intCast(count))) });
                }
            } else {
                const alloc = ctx.arena.allocator();
                var big = try ensureBignum(alloc, val);
                try big.shiftRight(&big, count);
                try ctx.stack.push(demoteBignum(big));
            }
        }
    }.func;
}

fn makeUshiftRightEntry() *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const count = try popShiftCount(ctx);
            const val = try ctx.stack.pop();
            if (count >= 64) {
                try ctx.stack.push(.{ .fixnum = 0 });
            } else {
                const unsigned: u64 = @bitCast(val.fixnum);
                const shifted = unsigned >> @intCast(count);
                try ctx.stack.push(.{ .fixnum = @bitCast(shifted) });
            }
        }
    }.func;
}

fn makeShiftEntry(comptime t: BitType) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            const count_val = try ctx.stack.pop();
            const count = count_val.fixnum;
            const val = try ctx.stack.pop();
            if (count >= 0) {
                const alloc = ctx.arena.allocator();
                var big = try ensureBignum(alloc, val);
                try big.shiftLeft(&big, @intCast(count));
                try ctx.stack.push(demoteBignum(big));
            } else {
                const abs_count: usize = @intCast(-count);
                if (t == .fixnum) {
                    if (abs_count >= 64) {
                        try ctx.stack.push(.{ .fixnum = if (val.fixnum < 0) @as(i64, -1) else @as(i64, 0) });
                    } else {
                        try ctx.stack.push(.{ .fixnum = std.math.shr(i64, val.fixnum, @as(u6, @intCast(abs_count))) });
                    }
                } else {
                    const alloc = ctx.arena.allocator();
                    var big = try ensureBignum(alloc, val);
                    try big.shiftRight(&big, abs_count);
                    try ctx.stack.push(demoteBignum(big));
                }
            }
        }
    }.func;
}

// =============================================================================
// Registration of all native dispatch entries
// =============================================================================

pub fn registerNativeDispatch(dispatch: *DispatchTable, ctx: *Context) !void {
    const unary = &dispatch_mod.unary_sentinel;
    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const bignum_tv = ctx.lookupBuiltinTypeValue("bignum").?;
    const bit_tvs = [_]*const value_mod.TypeValue{ fixnum_tv, bignum_tv };

    // bitand, bitor, bitxor: 4 entries each (2x2 bit-type matrix)
    inline for ([_]struct { op: BitwiseOp, name: []const u8 }{
        .{ .op = .bitand, .name = "bitand" },
        .{ .op = .bitor, .name = "bitor" },
        .{ .op = .bitxor, .name = "bitxor" },
    }) |item| {
        inline for (bit_types) |ta| {
            inline for (bit_types) |tb| {
                try dispatch.registerNative(item.name, bit_tvs[@intFromEnum(ta)], bit_tvs[@intFromEnum(tb)], makeBinaryBitwiseEntry(item.op, ta, tb));
            }
        }
    }

    // bitnot: 2 entries (unary)
    inline for (bit_types) |t| {
        try dispatch.registerNative("bitnot", bit_tvs[@intFromEnum(t)], unary, makeBitnotEntry(t));
    }

    // shift-left: 2 entries (fixnum x fixnum, bignum x fixnum)
    inline for (bit_types) |t| {
        try dispatch.registerNative("shift-left", bit_tvs[@intFromEnum(t)], fixnum_tv, makeShiftLeftEntry(t));
    }

    // shift-right: 2 entries (fixnum x fixnum, bignum x fixnum)
    inline for (bit_types) |t| {
        try dispatch.registerNative("shift-right", bit_tvs[@intFromEnum(t)], fixnum_tv, makeShiftRightEntry(t));
    }

    // ushift-right: 1 entry (fixnum x fixnum only)
    try dispatch.registerNative("ushift-right", fixnum_tv, fixnum_tv, makeUshiftRightEntry());

    // shift: 2 entries (fixnum x fixnum, bignum x fixnum)
    inline for (bit_types) |t| {
        try dispatch.registerNative("shift", bit_tvs[@intFromEnum(t)], fixnum_tv, makeShiftEntry(t));
    }
}

// =============================================================================
// Primitive implementations (thin dispatch-then-error wrappers)
// =============================================================================

fn isNativeBitwise(val: Value) bool {
    return val == .fixnum or val == .bignum;
}

fn nativeBitand(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "bitand")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    helpers.setErrorHint(ctx, "operands must be integers (fixnum or bignum)");
    helpers.setTypeMismatchError(ctx, "fixnum or bignum", if (!isNativeBitwise(a)) a else b);
    return error.TypeMismatch;
}

fn nativeBitor(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "bitor")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    helpers.setErrorHint(ctx, "operands must be integers (fixnum or bignum)");
    helpers.setTypeMismatchError(ctx, "fixnum or bignum", if (!isNativeBitwise(a)) a else b);
    return error.TypeMismatch;
}

fn nativeBitxor(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "bitxor")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    helpers.setErrorHint(ctx, "operands must be integers (fixnum or bignum)");
    helpers.setTypeMismatchError(ctx, "fixnum or bignum", if (!isNativeBitwise(a)) a else b);
    return error.TypeMismatch;
}

fn nativeBitnot(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "bitnot")) return;
    const val = try ctx.stack.pop();
    helpers.setErrorHint(ctx, "operand must be an integer (fixnum or bignum)");
    helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
    return error.TypeMismatch;
}

fn nativeShiftLeft(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "shift-left")) return;
    const count = try ctx.stack.pop();
    const val = try ctx.stack.pop();
    if (count != .fixnum) {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum", count);
        return error.TypeMismatch;
    }
    helpers.setErrorHint(ctx, "shift value must be an integer (fixnum or bignum)");
    helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
    return error.TypeMismatch;
}

fn nativeShiftRight(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "shift-right")) return;
    const count = try ctx.stack.pop();
    const val = try ctx.stack.pop();
    if (count != .fixnum) {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum", count);
        return error.TypeMismatch;
    }
    helpers.setErrorHint(ctx, "shift value must be an integer (fixnum or bignum)");
    helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
    return error.TypeMismatch;
}

fn nativeUshiftRight(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "ushift-right")) return;
    const count = try ctx.stack.pop();
    const val = try ctx.stack.pop();
    if (count != .fixnum) {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum", count);
        return error.TypeMismatch;
    }
    helpers.setErrorHint(ctx, "operand must be a fixnum");
    helpers.setTypeMismatchError(ctx, "fixnum", val);
    return error.TypeMismatch;
}

fn nativeShift(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "shift")) return;
    const count = try ctx.stack.pop();
    const val = try ctx.stack.pop();
    if (count != .fixnum) {
        helpers.setErrorHint(ctx, "shift count must be a fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum", count);
        return error.TypeMismatch;
    }
    helpers.setErrorHint(ctx, "shift value must be an integer (fixnum or bignum)");
    helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
    return error.TypeMismatch;
}

fn popShiftCount(ctx: *Context) !usize {
    const val = try ctx.stack.pop();
    if (val != .fixnum) {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum", val);
        return error.TypeMismatch;
    }
    if (val.fixnum < 0) {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setErrorContext(ctx, "shift count must be non-negative, got {d}", .{val.fixnum});
        return error.TypeMismatch;
    }
    return @intCast(val.fixnum);
}
