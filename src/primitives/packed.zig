const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const ByteArray = value_mod.ByteArray;
const VirtualType = value_mod.VirtualType;
const BigIntManaged = value_mod.BigIntManaged;
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;
const packed_kernels = @import("../packed.zig");
const container_backing = @import("../container_backing.zig");

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "packed-from-array", .func = nativePackedFromArray, .stack_effect = "array elem-type-str -- byte-array" },
    .{ .name = "packed-fill-impl", .func = nativePackedFill, .stack_effect = "n value elem-type-str -- byte-array" },
    .{ .name = "packed-to-array", .func = nativePackedToArray, .stack_effect = "packed-T -- array" },
    .{ .name = "packed-add", .func = nativePackedAdd, .stack_effect = "packed-T packed-T -- packed-T" },
    .{ .name = "packed-sub", .func = nativePackedSub, .stack_effect = "packed-T packed-T -- packed-T" },
    .{ .name = "packed-mul", .func = nativePackedMul, .stack_effect = "packed-T packed-T -- packed-T" },
    .{ .name = "packed-div", .func = nativePackedDiv, .stack_effect = "packed-T packed-T -- packed-T" },
    .{ .name = "packed-scalar-add", .func = nativePackedScalarAdd, .stack_effect = "packed-T scalar -- packed-T" },
    .{ .name = "packed-scalar-sub", .func = nativePackedScalarSub, .stack_effect = "packed-T scalar -- packed-T" },
    .{ .name = "packed-scalar-mul", .func = nativePackedScalarMul, .stack_effect = "packed-T scalar -- packed-T" },
    .{ .name = "packed-scalar-div", .func = nativePackedScalarDiv, .stack_effect = "packed-T scalar -- packed-T" },
    .{ .name = "packed-sum-impl", .func = nativePackedSum, .stack_effect = "packed-T -- number" },
    .{ .name = "packed-product-impl", .func = nativePackedProduct, .stack_effect = "packed-T -- number" },
    .{ .name = "packed-min-impl", .func = nativePackedMin, .stack_effect = "packed-T -- number" },
    .{ .name = "packed-max-impl", .func = nativePackedMax, .stack_effect = "packed-T -- number" },
    .{ .name = "packed-dot-impl", .func = nativePackedDot, .stack_effect = "packed-T packed-T -- number" },
    .{ .name = "packed-len", .func = nativePackedLen, .stack_effect = "packed-T -- fixnum" },
    .{ .name = "packed-nth", .func = nativePackedNth, .stack_effect = "packed-T fixnum -- value" },
};

const PackedElementType = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,

    fn fromString(s: []const u8) ?PackedElementType {
        const map = std.StaticStringMap(PackedElementType).initComptime(.{
            .{ "i8", .i8 },
            .{ "i16", .i16 },
            .{ "i32", .i32 },
            .{ "i64", .i64 },
            .{ "u8", .u8 },
            .{ "u16", .u16 },
            .{ "u32", .u32 },
            .{ "u64", .u64 },
            .{ "f32", .f32 },
            .{ "f64", .f64 },
        });
        return map.get(s);
    }

    fn fromTagName(name: []const u8) ?PackedElementType {
        if (std.mem.startsWith(u8, name, "packed-")) {
            return fromString(name["packed-".len..]);
        }
        return null;
    }

    fn elemSize(self: PackedElementType) usize {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .i64, .u64, .f64 => 8,
        };
    }

    fn typeName(self: PackedElementType) []const u8 {
        return switch (self) {
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .f32 => "f32",
            .f64 => "f64",
        };
    }
};

// ---------------------------------------------------------------------------
// Construction: packed-from-array ( array elem-type-str -- byte-array )
// ---------------------------------------------------------------------------

/// Convert a 1z array of numbers to a byte-array with packed element encoding.
fn nativePackedFromArray(ctx: *Context) anyerror!void {
    const alloc = ctx.allocator;
    const arena = ctx.arena.allocator();

    const type_str_val = try ctx.stack.pop();
    defer container_backing.releaseValue(type_str_val);
    const arr_val = try ctx.stack.pop();
    defer container_backing.releaseValue(arr_val);

    const type_str = switch (type_str_val) {
        .string => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "string", type_str_val);
            return error.TypeMismatch;
        },
    };

    const elem_type = PackedElementType.fromString(type_str) orelse {
        helpers.setErrorContext(ctx, "packed-from-array: unknown element type \"{s}\"", .{type_str});
        return error.TypeMismatch;
    };

    const items = switch (arr_val) {
        .array => |a| a.items,
        else => {
            helpers.setTypeMismatchError(ctx, "array", arr_val);
            return error.TypeMismatch;
        },
    };

    const byte_len = items.len * elem_type.elemSize();
    const ba = try ByteArray.create(alloc);
    errdefer container_backing.releaseValue(.{ .byte_array = ba });
    try ba.ensureTotalCapacity(alloc, byte_len);
    ba.items.len = byte_len;

    switch (elem_type) {
        .f64 => try writeElements(f64, ctx, arena, items, ba.items),
        .f32 => try writeElements(f32, ctx, arena, items, ba.items),
        .i8 => try writeElements(i8, ctx, arena, items, ba.items),
        .i16 => try writeElements(i16, ctx, arena, items, ba.items),
        .i32 => try writeElements(i32, ctx, arena, items, ba.items),
        .i64 => try writeElements(i64, ctx, arena, items, ba.items),
        .u8 => try writeElements(u8, ctx, arena, items, ba.items),
        .u16 => try writeElements(u16, ctx, arena, items, ba.items),
        .u32 => try writeElements(u32, ctx, arena, items, ba.items),
        .u64 => try writeElements(u64, ctx, arena, items, ba.items),
    }

    try ctx.stack.pushMoved(.{ .byte_array = ba });
}

fn writeElements(comptime T: type, ctx: *Context, arena: Allocator, items: []const Value, out: []u8) !void {
    for (items, 0..) |val, i| {
        packed_kernels.writeElement(T, out, i, try valueToElement(T, ctx, arena, val));
    }
}

fn valueToElement(comptime T: type, ctx: *Context, arena: Allocator, val: Value) !T {
    const info = @typeInfo(T);
    if (info == .float) {
        return switch (val) {
            .float => |f| @floatCast(f),
            .fixnum => |n| @floatFromInt(n),
            .bignum => |b| blk: {
                const str = b.toConst().toStringAlloc(arena, 10, .lower) catch {
                    helpers.setErrorContext(ctx, "packed-from-array: bignum too large for {s}", .{@typeName(T)});
                    return error.TypeMismatch;
                };
                break :blk std.fmt.parseFloat(T, str) catch {
                    helpers.setErrorContext(ctx, "packed-from-array: cannot convert bignum to {s}", .{@typeName(T)});
                    return error.TypeMismatch;
                };
            },
            else => {
                helpers.setErrorContext(ctx, "packed-from-array: expected number, got {s}", .{helpers.valueTypeName(val)});
                return error.TypeMismatch;
            },
        };
    } else if (info == .int) {
        const n: i64 = switch (val) {
            .fixnum => |f| f,
            .float => |f| blk: {
                if (f != @trunc(f)) {
                    helpers.setErrorContext(ctx, "packed-from-array: float {d} is not an integer", .{f});
                    return error.TypeMismatch;
                }
                break :blk @intFromFloat(f);
            },
            .bignum => |b| {
                if (b.fits(T)) return b.toInt(T) catch unreachable;
                helpers.setErrorContext(ctx, "packed-from-array: bignum out of range for {s}", .{@typeName(T)});
                return error.TypeMismatch;
            },
            else => {
                helpers.setErrorContext(ctx, "packed-from-array: expected number, got {s}", .{helpers.valueTypeName(val)});
                return error.TypeMismatch;
            },
        };
        return std.math.cast(T, n) orelse {
            helpers.setErrorContext(ctx, "packed-from-array: value {d} out of range for {s}", .{ n, @typeName(T) });
            return error.TypeMismatch;
        };
    } else {
        unreachable;
    }
}

// ---------------------------------------------------------------------------
// Construction: packed-fill-impl ( n value elem-type-str -- byte-array )
// ---------------------------------------------------------------------------

fn nativePackedFill(ctx: *Context) anyerror!void {
    const alloc = ctx.allocator;
    const arena = ctx.arena.allocator();

    const type_str_val = try ctx.stack.pop();
    defer container_backing.releaseValue(type_str_val);
    const value_val = try ctx.stack.pop();
    defer container_backing.releaseValue(value_val);
    const n_val = try ctx.stack.pop();
    defer container_backing.releaseValue(n_val);

    const type_str = switch (type_str_val) {
        .string => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "string", type_str_val);
            return error.TypeMismatch;
        },
    };

    const elem_type = PackedElementType.fromString(type_str) orelse {
        helpers.setErrorContext(ctx, "packed-fill: unknown element type \"{s}\"", .{type_str});
        return error.TypeMismatch;
    };

    const count: usize = switch (n_val) {
        .fixnum => |n| blk: {
            if (n < 0) {
                helpers.setErrorContext(ctx, "packed-fill: count must be non-negative, got {d}", .{n});
                return error.TypeMismatch;
            }
            break :blk @intCast(n);
        },
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum", n_val);
            return error.TypeMismatch;
        },
    };

    const byte_len = count * elem_type.elemSize();
    const ba = try ByteArray.create(alloc);
    errdefer container_backing.releaseValue(.{ .byte_array = ba });
    try ba.ensureTotalCapacity(alloc, byte_len);
    ba.items.len = byte_len;

    switch (elem_type) {
        .f64 => packed_kernels.fillPacked(f64, ba.items, try valueToElement(f64, ctx, arena, value_val)),
        .f32 => packed_kernels.fillPacked(f32, ba.items, try valueToElement(f32, ctx, arena, value_val)),
        .i8 => packed_kernels.fillPacked(i8, ba.items, try valueToElement(i8, ctx, arena, value_val)),
        .i16 => packed_kernels.fillPacked(i16, ba.items, try valueToElement(i16, ctx, arena, value_val)),
        .i32 => packed_kernels.fillPacked(i32, ba.items, try valueToElement(i32, ctx, arena, value_val)),
        .i64 => packed_kernels.fillPacked(i64, ba.items, try valueToElement(i64, ctx, arena, value_val)),
        .u8 => packed_kernels.fillPacked(u8, ba.items, try valueToElement(u8, ctx, arena, value_val)),
        .u16 => packed_kernels.fillPacked(u16, ba.items, try valueToElement(u16, ctx, arena, value_val)),
        .u32 => packed_kernels.fillPacked(u32, ba.items, try valueToElement(u32, ctx, arena, value_val)),
        .u64 => packed_kernels.fillPacked(u64, ba.items, try valueToElement(u64, ctx, arena, value_val)),
    }

    try ctx.stack.pushMoved(.{ .byte_array = ba });
}

// ---------------------------------------------------------------------------
// Conversion: packed-to-array ( packed-T -- array )
// ---------------------------------------------------------------------------

fn nativePackedToArray(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const tagged = switch (val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "packed-*", val);
            return error.TypeMismatch;
        },
    };

    const elem_type = PackedElementType.fromTagName(tagged.tag.name) orelse {
        helpers.setErrorContext(ctx, "packed-to-array: not a packed type: {s}", .{tagged.tag.name});
        return error.TypeMismatch;
    };

    const ba = switch (tagged.inner.*) {
        .byte_array => |b| b,
        else => {
            helpers.setErrorContext(ctx, "packed-to-array: inner value is not byte-array", .{});
            return error.TypeMismatch;
        },
    };

    const bytes = ba.slice();
    const count = bytes.len / elem_type.elemSize();
    const result = try alloc.alloc(Value, count);

    switch (elem_type) {
        inline .f64, .f32, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |et| {
            try readElements(etToType(et), ctx, bytes, result);
        },
    }

    try helpers.pushAdoptedArray(ctx, alloc, result);
}

fn readElements(comptime T: type, ctx: *Context, bytes: []const u8, out: []Value) !void {
    const n = packed_kernels.elementCount(T, bytes);
    for (0..n) |i| {
        out[i] = try elementToValue(T, ctx, packed_kernels.readElement(T, bytes, i));
    }
}

fn elementToValue(comptime T: type, ctx: *Context, elem: T) !Value {
    const info = @typeInfo(T);
    if (info == .float) {
        return .{ .float = @floatCast(elem) };
    } else if (info == .int) {
        if (info.int.signedness == .unsigned and @sizeOf(T) == 8) {
            // u64 is the one element type whose range exceeds fixnum; the upper half boxes as bignum
            if (elem > std.math.maxInt(i64)) {
                const alloc = ctx.arena.allocator();
                const big = try BigIntManaged.initSet(alloc, elem);
                return .{ .bignum = try value_mod.boxBigInt(alloc, big) };
            }
            return .{ .fixnum = @intCast(elem) };
        }
        return .{ .fixnum = @intCast(elem) };
    } else {
        unreachable;
    }
}

// ---------------------------------------------------------------------------
// Arithmetic helpers
// ---------------------------------------------------------------------------

fn packedArithmeticOp(comptime op: packed_kernels.Op, ctx: *Context) anyerror!void {
    const alloc = ctx.allocator;

    const b_val = try ctx.stack.pop();
    defer container_backing.releaseValue(b_val);
    const a_val = try ctx.stack.pop();
    defer container_backing.releaseValue(a_val);

    const a_tagged = switch (a_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "packed-*", a_val);
            return error.TypeMismatch;
        },
    };
    const b_tagged = switch (b_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "packed-*", b_val);
            return error.TypeMismatch;
        },
    };

    // validate both must be the same packed type
    if (a_tagged.tag != b_tagged.tag) {
        const op_name = switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
        };
        helpers.setErrorContext(ctx, "{s} {s} {s}: element type mismatch", .{ a_tagged.tag.name, op_name, b_tagged.tag.name });
        return error.TypeMismatch;
    }

    const a_ba = switch (a_tagged.inner.*) {
        .byte_array => |b| b,
        else => {
            helpers.setErrorContext(ctx, "packed arithmetic: inner value is not byte-array", .{});
            return error.TypeMismatch;
        },
    };
    const b_ba = switch (b_tagged.inner.*) {
        .byte_array => |b| b,
        else => {
            helpers.setErrorContext(ctx, "packed arithmetic: inner value is not byte-array", .{});
            return error.TypeMismatch;
        },
    };

    const elem_type = PackedElementType.fromTagName(a_tagged.tag.name) orelse {
        helpers.setErrorContext(ctx, "packed arithmetic: not a packed type: {s}", .{a_tagged.tag.name});
        return error.TypeMismatch;
    };

    // check lenghts match
    const a_bytes = a_ba.slice();
    const b_bytes = b_ba.slice();
    if (a_bytes.len != b_bytes.len) {
        const a_count = a_bytes.len / elem_type.elemSize();
        const b_count = b_bytes.len / elem_type.elemSize();
        const op_name = switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
        };
        helpers.setErrorContext(ctx, "{s} {s}: length mismatch ({d} vs {d} elements)", .{ a_tagged.tag.name, op_name, a_count, b_count });
        return error.TypeMismatch;
    }

    const out_ba = try ByteArray.create(alloc);
    errdefer container_backing.releaseValue(.{ .byte_array = out_ba });
    try out_ba.ensureTotalCapacity(alloc, a_bytes.len);
    out_ba.items.len = a_bytes.len;

    try callKernel(op, elem_type, a_bytes, b_bytes, out_ba.items);

    const inner = try ctx.quotationAllocator().create(Value);
    inner.* = .{ .byte_array = out_ba };
    try ctx.stack.pushMoved(.{
        .tagged = .{
            .tag = a_tagged.tag,
            .inner = inner,
        },
    });
}

fn callKernel(comptime op: packed_kernels.Op, elem_type: PackedElementType, a: []const u8, b: []const u8, out: []u8) packed_kernels.DivideError!void {
    switch (elem_type) {
        inline .f64, .f32, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |et| {
            const T = switch (et) {
                .f64 => f64,
                .f32 => f32,
                .i8 => i8,
                .i16 => i16,
                .i32 => i32,
                .i64 => i64,
                .u8 => u8,
                .u16 => u16,
                .u32 => u32,
                .u64 => u64,
            };
            switch (op) {
                .add => packed_kernels.addPacked(T, a, b, out),
                .sub => packed_kernels.subPacked(T, a, b, out),
                .mul => packed_kernels.mulPacked(T, a, b, out),
                .div => try packed_kernels.divPacked(T, a, b, out),
            }
        },
    }
}

fn nativePackedAdd(ctx: *Context) anyerror!void {
    return packedArithmeticOp(.add, ctx);
}

fn nativePackedSub(ctx: *Context) anyerror!void {
    return packedArithmeticOp(.sub, ctx);
}

fn nativePackedMul(ctx: *Context) anyerror!void {
    return packedArithmeticOp(.mul, ctx);
}

fn nativePackedDiv(ctx: *Context) anyerror!void {
    return packedArithmeticOp(.div, ctx);
}

// ---------------------------------------------------------------------------
// Scalar broadcast arithmetic: packed-T op scalar -> packed-T
// ---------------------------------------------------------------------------

fn packedScalarArithmeticOp(comptime op: packed_kernels.Op, ctx: *Context) anyerror!void {
    const alloc = ctx.allocator;
    const arena = ctx.arena.allocator();

    const scalar_val = try ctx.stack.pop();
    defer container_backing.releaseValue(scalar_val);
    const a_val = try ctx.stack.pop();
    defer container_backing.releaseValue(a_val);

    const a_tagged = switch (a_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "packed-*", a_val);
            return error.TypeMismatch;
        },
    };

    const a_ba = switch (a_tagged.inner.*) {
        .byte_array => |b| b,
        else => {
            helpers.setErrorContext(ctx, "packed scalar arithmetic: inner value is not byte-array", .{});
            return error.TypeMismatch;
        },
    };

    const elem_type = PackedElementType.fromTagName(a_tagged.tag.name) orelse {
        helpers.setErrorContext(ctx, "packed scalar arithmetic: not a packed type: {s}", .{a_tagged.tag.name});
        return error.TypeMismatch;
    };

    const out_ba = try ByteArray.create(alloc);
    errdefer container_backing.releaseValue(.{ .byte_array = out_ba });
    const a_bytes = a_ba.slice();
    try out_ba.ensureTotalCapacity(alloc, a_bytes.len);
    out_ba.items.len = a_bytes.len;

    switch (elem_type) {
        inline .f64, .f32, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |et| {
            const T = comptime etToType(et);
            const scalar = try valueToElement(T, ctx, arena, scalar_val);
            if (comptime op == .div) {
                try packed_kernels.scalarBinaryOp(T, op, a_bytes, scalar, out_ba.items);
            } else {
                packed_kernels.scalarBinaryOp(T, op, a_bytes, scalar, out_ba.items);
            }
        },
    }

    const inner = try ctx.quotationAllocator().create(Value);
    inner.* = .{ .byte_array = out_ba };
    try ctx.stack.pushMoved(.{ .tagged = .{ .tag = a_tagged.tag, .inner = inner } });
}

fn nativePackedScalarAdd(ctx: *Context) anyerror!void {
    return packedScalarArithmeticOp(.add, ctx);
}

fn nativePackedScalarSub(ctx: *Context) anyerror!void {
    return packedScalarArithmeticOp(.sub, ctx);
}

fn nativePackedScalarMul(ctx: *Context) anyerror!void {
    return packedScalarArithmeticOp(.mul, ctx);
}

fn nativePackedScalarDiv(ctx: *Context) anyerror!void {
    return packedScalarArithmeticOp(.div, ctx);
}

// ---------------------------------------------------------------------------
// Reductions
// ---------------------------------------------------------------------------

/// packed-sum-impl ( packed-T -- number )
fn nativePackedSum(ctx: *Context) anyerror!void {
    const tagged = try popPackedTagged(ctx);
    defer container_backing.releaseValue(.{ .tagged = tagged });
    const ba = try extractByteArray(ctx, tagged);
    const elem_type = try extractElemType(ctx, tagged);

    switch (elem_type) {
        inline .f64, .f32, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |et| {
            const T = comptime etToType(et);
            try ctx.stack.push(try elementToValue(T, ctx, packed_kernels.sumPacked(T, ba.slice())));
        },
    }
}

/// packed-product-impl ( packed-T -- number )
fn nativePackedProduct(ctx: *Context) anyerror!void {
    const tagged = try popPackedTagged(ctx);
    defer container_backing.releaseValue(.{ .tagged = tagged });
    const ba = try extractByteArray(ctx, tagged);
    const elem_type = try extractElemType(ctx, tagged);

    switch (elem_type) {
        inline .f64, .f32, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |et| {
            const T = comptime etToType(et);
            try ctx.stack.push(try elementToValue(T, ctx, packed_kernels.productPacked(T, ba.slice())));
        },
    }
}

/// packed-min-impl ( packed-T -- number )
fn nativePackedMin(ctx: *Context) anyerror!void {
    const tagged = try popPackedTagged(ctx);
    defer container_backing.releaseValue(.{ .tagged = tagged });
    const ba = try extractByteArray(ctx, tagged);
    const elem_type = try extractElemType(ctx, tagged);

    switch (elem_type) {
        inline .f64, .f32, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |et| {
            const T = comptime etToType(et);
            const result = packed_kernels.minPacked(T, ba.slice()) orelse {
                helpers.setErrorContext(ctx, "packed-min: empty array", .{});
                return error.InvalidArgument;
            };
            try ctx.stack.push(try elementToValue(T, ctx, result));
        },
    }
}

/// packed-max-impl ( packed-T -- number )
fn nativePackedMax(ctx: *Context) anyerror!void {
    const tagged = try popPackedTagged(ctx);
    defer container_backing.releaseValue(.{ .tagged = tagged });
    const ba = try extractByteArray(ctx, tagged);
    const elem_type = try extractElemType(ctx, tagged);

    switch (elem_type) {
        inline .f64, .f32, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |et| {
            const T = comptime etToType(et);
            const result = packed_kernels.maxPacked(T, ba.slice()) orelse {
                helpers.setErrorContext(ctx, "packed-max: empty array", .{});
                return error.InvalidArgument;
            };
            try ctx.stack.push(try elementToValue(T, ctx, result));
        },
    }
}

/// packed-dot-impl ( packed-T packed-T -- number )
fn nativePackedDot(ctx: *Context) anyerror!void {
    const b_val = try ctx.stack.pop();
    defer container_backing.releaseValue(b_val);
    const a_val = try ctx.stack.pop();
    defer container_backing.releaseValue(a_val);

    const a_tagged = switch (a_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "packed-*", a_val);
            return error.TypeMismatch;
        },
    };
    const b_tagged = switch (b_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "packed-*", b_val);
            return error.TypeMismatch;
        },
    };

    if (a_tagged.tag != b_tagged.tag) {
        helpers.setErrorContext(ctx, "packed-dot: element type mismatch ({s} vs {s})", .{ a_tagged.tag.name, b_tagged.tag.name });
        return error.TypeMismatch;
    }

    const a_ba = try extractByteArray(ctx, a_tagged);
    const b_ba = try extractByteArray(ctx, b_tagged);
    const elem_type = try extractElemType(ctx, a_tagged);

    const a_bytes = a_ba.slice();
    const b_bytes = b_ba.slice();
    if (a_bytes.len != b_bytes.len) {
        const a_count = a_bytes.len / elem_type.elemSize();
        const b_count = b_bytes.len / elem_type.elemSize();
        helpers.setErrorContext(ctx, "packed-dot: length mismatch ({d} vs {d} elements)", .{ a_count, b_count });
        return error.TypeMismatch;
    }

    switch (elem_type) {
        inline .f64, .f32, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |et| {
            const T = comptime etToType(et);
            try ctx.stack.push(try elementToValue(T, ctx, packed_kernels.dotPacked(T, a_bytes, b_bytes)));
        },
    }
}

// ---------------------------------------------------------------------------
// Sequence protocol: packed-len, packed-nth
// ---------------------------------------------------------------------------

/// packed-len ( packed-T -- fixnum )
fn nativePackedLen(ctx: *Context) anyerror!void {
    const tagged = try popPackedTagged(ctx);
    defer container_backing.releaseValue(.{ .tagged = tagged });
    const ba = try extractByteArray(ctx, tagged);
    const elem_type = try extractElemType(ctx, tagged);
    const count = ba.slice().len / elem_type.elemSize();
    try ctx.stack.push(.{ .fixnum = @intCast(count) });
}

/// packed-nth ( packed-T fixnum -- value )
fn nativePackedNth(ctx: *Context) anyerror!void {
    const idx_val = try ctx.stack.pop();
    defer container_backing.releaseValue(idx_val);
    const a_val = try ctx.stack.pop();
    defer container_backing.releaseValue(a_val);

    const idx: i64 = switch (idx_val) {
        .fixnum => |n| n,
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum", idx_val);
            return error.TypeMismatch;
        },
    };

    const tagged = switch (a_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "packed-*", a_val);
            return error.TypeMismatch;
        },
    };

    const ba = try extractByteArray(ctx, tagged);
    const elem_type = try extractElemType(ctx, tagged);
    const bytes = ba.slice();
    const count = bytes.len / elem_type.elemSize();

    if (idx < 0 or idx >= @as(i64, @intCast(count))) {
        helpers.setErrorContext(ctx, "#nth: index {d} out of bounds for packed array of {d} elements", .{ idx, count });
        return error.IndexOutOfBounds;
    }

    const i: usize = @intCast(idx);
    switch (elem_type) {
        inline .f64, .f32, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |et| {
            const T = comptime etToType(et);
            try ctx.stack.push(try elementToValue(T, ctx, packed_kernels.readElement(T, bytes, i)));
        },
    }
}

// ---------------------------------------------------------------------------
// Shared extraction helpers
// ---------------------------------------------------------------------------

fn etToType(comptime et: PackedElementType) type {
    return switch (et) {
        .f64 => f64,
        .f32 => f32,
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
    };
}

const TaggedPayload = std.meta.TagPayload(Value, .tagged);

fn popPackedTagged(ctx: *Context) !TaggedPayload {
    const val = try ctx.stack.pop();
    return switch (val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "packed-*", val);
            container_backing.releaseValue(val);
            return error.TypeMismatch;
        },
    };
}

fn extractByteArray(ctx: *Context, tagged: TaggedPayload) !*ByteArray {
    return switch (tagged.inner.*) {
        .byte_array => |b| b,
        else => {
            helpers.setErrorContext(ctx, "packed operation: inner value is not byte-array", .{});
            return error.TypeMismatch;
        },
    };
}

fn extractElemType(ctx: *Context, tagged: TaggedPayload) !PackedElementType {
    return PackedElementType.fromTagName(tagged.tag.name) orelse {
        helpers.setErrorContext(ctx, "packed operation: not a packed type: {s}", .{tagged.tag.name});
        return error.TypeMismatch;
    };
}
