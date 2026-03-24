const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const BigIntManaged = value_mod.BigIntManaged;
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "sin", .func = nativeSin },
    .{ .name = "cos", .func = nativeCos },
    .{ .name = "tan", .func = nativeTan },
    .{ .name = "asin", .func = nativeAsin },
    .{ .name = "acos", .func = nativeAcos },
    .{ .name = "atan", .func = nativeAtan },
    .{ .name = "atan2", .func = nativeAtan2 },
    .{ .name = "exp", .func = nativeExp },
    .{ .name = "log", .func = nativeLog },
    .{ .name = "log2", .func = nativeLog2 },
    .{ .name = "log10", .func = nativeLog10 },
    .{ .name = "sqrt", .func = nativeSqrt },
    .{ .name = "pow", .func = nativePow },
    .{ .name = "floor", .func = nativeFloor },
    .{ .name = "ceil", .func = nativeCeil },
    .{ .name = "round", .func = nativeRound },
    .{ .name = "truncate", .func = nativeTruncate },
    .{ .name = "float-raw-bits", .func = nativeFloatRawBits },
    .{ .name = "raw-bits-float", .func = nativeRawBitsFloat },
};

fn popFloat(ctx: *Context) !f64 {
    const val = try helpers.popNumber(ctx);
    return switch (val) {
        .fixnum => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
    };
}

fn roundHalfToEven(x: f64) f64 {
    const r = @round(x);
    if (@abs(x - r) == 0.5) {
        return 2.0 * @round(x / 2.0);
    }

    return r;
}

fn nativeSin(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @sin(x) });
}

fn nativeCos(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @cos(x) });
}

fn nativeTan(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @tan(x) });
}

fn nativeAsin(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = std.math.asin(x) });
}

fn nativeAcos(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = std.math.acos(x) });
}

fn nativeAtan(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = std.math.atan(x) });
}

fn nativeAtan2(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    const y = try popFloat(ctx);
    try ctx.stack.push(.{ .float = std.math.atan2(y, x) });
}

fn nativeExp(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @exp(x) });
}

fn nativeLog(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @log(x) });
}

fn nativeLog2(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @log2(x) });
}

fn nativeLog10(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @log10(x) });
}

fn nativeSqrt(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @sqrt(x) });
}

fn nativePow(ctx: *Context) anyerror!void {
    const exp_val = try popFloat(ctx);
    const base_val = try popFloat(ctx);
    try ctx.stack.push(.{ .float = std.math.pow(f64, base_val, exp_val) });
}

fn nativeFloor(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @floor(x) });
}

fn nativeCeil(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @ceil(x) });
}

fn nativeRound(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = roundHalfToEven(x) });
}

fn nativeTruncate(ctx: *Context) anyerror!void {
    const x = try popFloat(ctx);
    try ctx.stack.push(.{ .float = @trunc(x) });
}

// ( float width -- fixnum )
fn nativeFloatRawBits(ctx: *Context) anyerror!void {
    const width_val = try ctx.stack.pop();
    if (width_val != .fixnum or (width_val.fixnum != 32 and width_val.fixnum != 64)) {
        helpers.setErrorContext(ctx, "float-raw-bits: width must be 32 or 64", .{});
        return error.TypeMismatch;
    }
    const width: u7 = @intCast(width_val.fixnum);
    const val = try ctx.stack.pop();
    if (val != .float) {
        helpers.setTypeMismatchError(ctx, "float", val);
        return error.TypeMismatch;
    }
    if (width == 32) {
        const f32_val: f32 = @floatCast(val.float);
        const bits: u32 = @bitCast(f32_val);
        try ctx.stack.push(.{ .fixnum = @intCast(bits) });
    } else {
        const bits: u64 = @bitCast(val.float);
        if (bits >> 63 == 0) {
            try ctx.stack.push(.{ .fixnum = @intCast(bits) });
        } else {
            const alloc = ctx.arena.allocator();
            const big = try BigIntManaged.initSet(alloc, bits);
            try ctx.stack.push(.{ .bignum = big });
        }
    }
}

// ( fixnum width -- float )
fn nativeRawBitsFloat(ctx: *Context) anyerror!void {
    const width_val = try ctx.stack.pop();
    if (width_val != .fixnum or (width_val.fixnum != 32 and width_val.fixnum != 64)) {
        helpers.setErrorContext(ctx, "raw-bits-float: width must be 32 or 64", .{});
        return error.TypeMismatch;
    }
    const width: u7 = @intCast(width_val.fixnum);
    const val = try ctx.stack.pop();
    if (width == 32) {
        const bits: u32 = switch (val) {
            .fixnum => |i| blk: {
                if (i < 0 or i > std.math.maxInt(u32)) {
                    helpers.setErrorContext(ctx, "raw-bits-float: value must be in range 0..2^32-1, got {d}", .{i});
                    return error.TypeMismatch;
                }
                break :blk @intCast(i);
            },
            .bignum => |b| blk: {
                if (!b.fits(u32)) {
                    helpers.setErrorContext(ctx, "raw-bits-float: value must be in range 0..2^32-1", .{});
                    return error.TypeMismatch;
                }
                break :blk b.toInt(u32) catch unreachable;
            },
            else => {
                helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
                return error.TypeMismatch;
            },
        };
        const f32_val: f32 = @bitCast(bits);
        const f: f64 = @floatCast(f32_val);
        try ctx.stack.push(.{ .float = f });
    } else {
        const bits: u64 = switch (val) {
            .fixnum => |i| blk: {
                if (i < 0) {
                    helpers.setErrorContext(ctx, "raw-bits-float: value must be in range 0..2^64-1, got {d}", .{i});
                    return error.TypeMismatch;
                }
                break :blk @intCast(i);
            },
            .bignum => |b| blk: {
                if (!b.fits(u64)) {
                    helpers.setErrorContext(ctx, "raw-bits-float: value must be in range 0..2^64-1", .{});
                    return error.TypeMismatch;
                }
                break :blk b.toInt(u64) catch unreachable;
            },
            else => {
                helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
                return error.TypeMismatch;
            },
        };
        const f: f64 = @bitCast(bits);
        try ctx.stack.push(.{ .float = f });
    }
}
