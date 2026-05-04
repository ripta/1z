const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const BigIntManaged = value_mod.BigIntManaged;
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const dispatch_helpers = @import("dispatch_helpers.zig");

const demoteBignum = helpers.demoteBignum;
const ensureBignum = helpers.ensureBignum;

pub const primitives = [_]Primitive{
    .{ .name = "bitand", .stack_effect = "a b -- a&b", .doc = "Bitwise AND. Works on fixnums and bignums with two's complement semantics.", .func = nativeBitand },
    .{ .name = "bitor", .stack_effect = "a b -- a|b", .doc = "Bitwise OR. Works on fixnums and bignums with two's complement semantics.", .func = nativeBitor },
    .{ .name = "bitxor", .stack_effect = "a b -- a^b", .doc = "Bitwise XOR. Works on fixnums and bignums with two's complement semantics.", .func = nativeBitxor },
    .{ .name = "bitnot", .stack_effect = "a -- ~a", .doc = "Bitwise NOT (two's complement): ~x = -(x+1). Works on fixnums and bignums.", .func = nativeBitnot },
    .{ .name = "shift-left", .stack_effect = "n count -- n'", .doc = "Left shift by count bits. Count must be a non-negative fixnum. Promotes to bignum on overflow.", .func = nativeShiftLeft },
    .{ .name = "shift-right", .stack_effect = "n count -- n'", .doc = "Arithmetic (sign-extending) right shift by count bits. Count must be a non-negative fixnum.", .func = nativeShiftRight },
    .{ .name = "ushift-right", .stack_effect = "n count -- n'", .doc = "Logical (zero-filling) right shift. Fixnum-only; throws on bignum.", .func = nativeUshiftRight },
    .{ .name = "shift", .stack_effect = "n count -- n'", .doc = "Shift: positive count = left shift, negative count = arithmetic right shift.", .func = nativeShift },
};

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

fn nativeBitand(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "bitand")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    if (a == .fixnum and b == .fixnum) {
        try ctx.stack.push(.{ .fixnum = a.fixnum & b.fixnum });
    } else if ((a == .fixnum or a == .bignum) and (b == .fixnum or b == .bignum)) {
        const alloc = ctx.arena.allocator();
        var ba = try ensureBignum(alloc, a);
        var bb = try ensureBignum(alloc, b);
        try ba.bitAnd(&ba, &bb);
        bb.deinit();
        try ctx.stack.push(demoteBignum(ba));
    } else {
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", if (a != .fixnum and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

fn nativeBitor(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "bitor")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    if (a == .fixnum and b == .fixnum) {
        try ctx.stack.push(.{ .fixnum = a.fixnum | b.fixnum });
    } else if ((a == .fixnum or a == .bignum) and (b == .fixnum or b == .bignum)) {
        const alloc = ctx.arena.allocator();
        var ba = try ensureBignum(alloc, a);
        var bb = try ensureBignum(alloc, b);
        try ba.bitOr(&ba, &bb);
        bb.deinit();
        try ctx.stack.push(demoteBignum(ba));
    } else {
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", if (a != .fixnum and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

fn nativeBitxor(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "bitxor")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    if (a == .fixnum and b == .fixnum) {
        try ctx.stack.push(.{ .fixnum = a.fixnum ^ b.fixnum });
    } else if ((a == .fixnum or a == .bignum) and (b == .fixnum or b == .bignum)) {
        const alloc = ctx.arena.allocator();
        var ba = try ensureBignum(alloc, a);
        var bb = try ensureBignum(alloc, b);
        try ba.bitXor(&ba, &bb);
        bb.deinit();
        try ctx.stack.push(demoteBignum(ba));
    } else {
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", if (a != .fixnum and a != .bignum) a else b);
        return error.TypeMismatch;
    }
}

fn nativeBitnot(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "bitnot")) return;
    const val = try ctx.stack.pop();
    if (val == .fixnum) {
        try ctx.stack.push(.{ .fixnum = ~val.fixnum });
    } else if (val == .bignum) {
        const alloc = ctx.arena.allocator();
        var result = try val.bignum.clone();
        var one = try BigIntManaged.initSet(alloc, @as(i64, 1));
        defer one.deinit();
        try result.add(&result, &one);
        result.negate();
        try ctx.stack.push(demoteBignum(result));
    } else {
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
        return error.TypeMismatch;
    }
}

fn nativeShiftLeft(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "shift-left")) return;
    const count = try popShiftCount(ctx);
    const val = try ctx.stack.pop();
    if (val == .fixnum or val == .bignum) {
        const alloc = ctx.arena.allocator();
        var big = try ensureBignum(alloc, val);
        try big.shiftLeft(&big, count);
        try ctx.stack.push(demoteBignum(big));
    } else {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
        return error.TypeMismatch;
    }
}

fn nativeShiftRight(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "shift-right")) return;
    const count = try popShiftCount(ctx);
    const val = try ctx.stack.pop();
    if (val == .fixnum) {
        if (count >= 64) {
            try ctx.stack.push(.{ .fixnum = if (val.fixnum < 0) @as(i64, -1) else @as(i64, 0) });
        } else {
            try ctx.stack.push(.{ .fixnum = std.math.shr(i64, val.fixnum, @as(u6, @intCast(count))) });
        }
    } else if (val == .bignum) {
        const alloc = ctx.arena.allocator();
        var big = try ensureBignum(alloc, val);
        try big.shiftRight(&big, count);
        try ctx.stack.push(demoteBignum(big));
    } else {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
        return error.TypeMismatch;
    }
}

fn nativeUshiftRight(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "ushift-right")) return;
    const count = try popShiftCount(ctx);
    const val = try ctx.stack.pop();
    if (val != .fixnum) {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum", val);
        return error.TypeMismatch;
    }
    if (count >= 64) {
        try ctx.stack.push(.{ .fixnum = 0 });
    } else {
        const unsigned: u64 = @bitCast(val.fixnum);
        const shifted = unsigned >> @intCast(count);
        try ctx.stack.push(.{ .fixnum = @bitCast(shifted) });
    }
}

fn nativeShift(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "shift")) return;
    const count_val = try ctx.stack.pop();
    if (count_val != .fixnum) {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum", count_val);
        return error.TypeMismatch;
    }
    const count = count_val.fixnum;
    const val = try ctx.stack.pop();
    if (val != .fixnum and val != .bignum) {
        helpers.setErrorHint(ctx, "shift count must be a non-negative fixnum");
        helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
        return error.TypeMismatch;
    }
    if (count >= 0) {
        const alloc = ctx.arena.allocator();
        var big = try ensureBignum(alloc, val);
        try big.shiftLeft(&big, @intCast(count));
        try ctx.stack.push(demoteBignum(big));
    } else {
        const abs_count: usize = @intCast(-count);
        if (val == .fixnum) {
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
