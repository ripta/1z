const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const ByteArray = value_mod.ByteArray;
const VirtualType = value_mod.VirtualType;
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;
const simd_kernels = @import("../simd_vector.zig");

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "simd-from-stack", .func = nativeSimdFromStack, .stack_effect = "v0..vN-1 type-str -- byte-array" },
    .{ .name = "simd-splat-impl", .func = nativeSimdSplat, .stack_effect = "value type-str -- byte-array" },
    .{ .name = "simd-to-array", .func = nativeSimdToArray, .stack_effect = "simd-NxT -- array" },
    .{ .name = "simd-lane-get", .func = nativeSimdLaneGet, .stack_effect = "simd-NxT fixnum -- value" },
    .{ .name = "simd-lane-set", .func = nativeSimdLaneSet, .stack_effect = "simd-NxT value fixnum -- simd-NxT" },
    .{ .name = "simd-add", .func = nativeSimdAdd, .stack_effect = "simd-NxT simd-NxT -- simd-NxT" },
    .{ .name = "simd-sub", .func = nativeSimdSub, .stack_effect = "simd-NxT simd-NxT -- simd-NxT" },
    .{ .name = "simd-mul", .func = nativeSimdMul, .stack_effect = "simd-NxT simd-NxT -- simd-NxT" },
    .{ .name = "simd-div", .func = nativeSimdDiv, .stack_effect = "simd-NxT simd-NxT -- simd-NxT" },
    .{ .name = "simd-shuffle-impl", .func = nativeSimdShuffle, .stack_effect = "simd-NxT array -- simd-NxT" },
    .{ .name = "simd-select-impl", .func = nativeSimdSelect, .stack_effect = "simd-NxT simd-NxT simd-NxT -- simd-NxT" },
    .{ .name = "simd-blend-impl", .func = nativeSimdBlend, .stack_effect = "simd-NxT simd-NxT fixnum -- simd-NxT" },
};

const SimdVectorType = enum {
    @"2xf64",
    @"4xf32",
    @"2xi64",
    @"4xi32",
    @"8xi16",
    @"16xi8",
    @"2xu64",
    @"4xu32",
    @"8xu16",
    @"16xu8",

    fn fromString(s: []const u8) ?SimdVectorType {
        const map = std.StaticStringMap(SimdVectorType).initComptime(.{
            .{ "2xf64", .@"2xf64" },
            .{ "4xf32", .@"4xf32" },
            .{ "2xi64", .@"2xi64" },
            .{ "4xi32", .@"4xi32" },
            .{ "8xi16", .@"8xi16" },
            .{ "16xi8", .@"16xi8" },
            .{ "2xu64", .@"2xu64" },
            .{ "4xu32", .@"4xu32" },
            .{ "8xu16", .@"8xu16" },
            .{ "16xu8", .@"16xu8" },
        });
        return map.get(s);
    }

    fn fromTagName(name: []const u8) ?SimdVectorType {
        if (std.mem.startsWith(u8, name, "simd-")) {
            return fromString(name["simd-".len..]);
        }
        return null;
    }

    fn laneCount(self: SimdVectorType) usize {
        return switch (self) {
            .@"2xf64", .@"2xi64", .@"2xu64" => 2,
            .@"4xf32", .@"4xi32", .@"4xu32" => 4,
            .@"8xi16", .@"8xu16" => 8,
            .@"16xi8", .@"16xu8" => 16,
        };
    }

    fn elemSize(self: SimdVectorType) usize {
        return switch (self) {
            .@"16xi8", .@"16xu8" => 1,
            .@"8xi16", .@"8xu16" => 2,
            .@"4xf32", .@"4xi32", .@"4xu32" => 4,
            .@"2xf64", .@"2xi64", .@"2xu64" => 8,
        };
    }

    fn typeName(self: SimdVectorType) []const u8 {
        return switch (self) {
            .@"2xf64" => "2xf64",
            .@"4xf32" => "4xf32",
            .@"2xi64" => "2xi64",
            .@"4xi32" => "4xi32",
            .@"8xi16" => "8xi16",
            .@"16xi8" => "16xi8",
            .@"2xu64" => "2xu64",
            .@"4xu32" => "4xu32",
            .@"8xu16" => "8xu16",
            .@"16xu8" => "16xu8",
        };
    }
};

// ---------------------------------------------------------------------------
// Value conversion helpers (mirrored from packed.zig since they are private)
// ---------------------------------------------------------------------------

fn valueToElement(comptime T: type, ctx: *Context, arena: Allocator, val: Value) !T {
    const info = @typeInfo(T);
    if (info == .float) {
        return switch (val) {
            .float => |f| @floatCast(f),
            .fixnum => |n| @floatFromInt(n),
            .bignum => |b| blk: {
                const str = b.toConst().toStringAlloc(arena, 10, .lower) catch {
                    helpers.setErrorContext(ctx, "simd: bignum too large for {s}", .{@typeName(T)});
                    return error.TypeMismatch;
                };
                break :blk std.fmt.parseFloat(T, str) catch {
                    helpers.setErrorContext(ctx, "simd: cannot convert bignum to {s}", .{@typeName(T)});
                    return error.TypeMismatch;
                };
            },
            else => {
                helpers.setErrorContext(ctx, "simd: expected number, got {s}", .{helpers.valueTypeName(val)});
                return error.TypeMismatch;
            },
        };
    } else if (info == .int) {
        const n: i64 = switch (val) {
            .fixnum => |f| f,
            .float => |f| blk: {
                if (f != @trunc(f)) {
                    helpers.setErrorContext(ctx, "simd: float {d} is not an integer", .{f});
                    return error.TypeMismatch;
                }
                break :blk @intFromFloat(f);
            },
            else => {
                helpers.setErrorContext(ctx, "simd: expected number, got {s}", .{helpers.valueTypeName(val)});
                return error.TypeMismatch;
            },
        };
        return std.math.cast(T, n) orelse {
            helpers.setErrorContext(ctx, "simd: value {d} out of range for {s}", .{ n, @typeName(T) });
            return error.TypeMismatch;
        };
    } else {
        unreachable;
    }
}

fn elementToValue(comptime T: type, elem: T) Value {
    const info = @typeInfo(T);
    if (info == .float) {
        return .{ .float = @floatCast(elem) };
    } else if (info == .int) {
        if (info.int.signedness == .unsigned) {
            if (@sizeOf(T) <= 4) {
                return .{ .fixnum = @intCast(elem) };
            } else {
                if (elem <= std.math.maxInt(i64)) {
                    return .{ .fixnum = @intCast(elem) };
                } else {
                    return .{ .fixnum = @bitCast(@as(u64, elem)) };
                }
            }
        } else {
            return .{ .fixnum = @intCast(elem) };
        }
    } else {
        unreachable;
    }
}

fn etToType(comptime et: SimdVectorType) type {
    return switch (et) {
        .@"2xf64" => f64,
        .@"4xf32" => f32,
        .@"2xi64" => i64,
        .@"4xi32" => i32,
        .@"8xi16" => i16,
        .@"16xi8" => i8,
        .@"2xu64" => u64,
        .@"4xu32" => u32,
        .@"8xu16" => u16,
        .@"16xu8" => u8,
    };
}

fn etToLaneCount(comptime et: SimdVectorType) comptime_int {
    return switch (et) {
        .@"2xf64", .@"2xi64", .@"2xu64" => 2,
        .@"4xf32", .@"4xi32", .@"4xu32" => 4,
        .@"8xi16", .@"8xu16" => 8,
        .@"16xi8", .@"16xu8" => 16,
    };
}

// ---------------------------------------------------------------------------
// Tagged value extraction helpers
// ---------------------------------------------------------------------------

const TaggedPayload = std.meta.TagPayload(Value, .tagged);

fn popSimdTagged(ctx: *Context) !TaggedPayload {
    const val = try ctx.stack.pop();
    return switch (val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "simd-*", val);
            return error.TypeMismatch;
        },
    };
}

fn extractByteArray(ctx: *Context, tagged: TaggedPayload) !*ByteArray {
    return switch (tagged.inner.*) {
        .byte_array => |b| b,
        else => {
            helpers.setErrorContext(ctx, "simd operation: inner value is not byte-array", .{});
            return error.TypeMismatch;
        },
    };
}

fn extractSimdType(ctx: *Context, tagged: TaggedPayload) !SimdVectorType {
    return SimdVectorType.fromTagName(tagged.tag.name) orelse {
        helpers.setErrorContext(ctx, "simd operation: not a SIMD type: {s}", .{tagged.tag.name});
        return error.TypeMismatch;
    };
}

fn validateSimdSize(ctx: *Context, ba: *ByteArray) !*[simd_kernels.SIMD_BYTES]u8 {
    const bytes = ba.slice();
    if (bytes.len != simd_kernels.SIMD_BYTES) {
        helpers.setErrorContext(ctx, "simd operation: expected {d} bytes, got {d}", .{ simd_kernels.SIMD_BYTES, bytes.len });
        return error.TypeMismatch;
    }
    return bytes[0..simd_kernels.SIMD_BYTES];
}

fn allocSimdByteArray(alloc: Allocator) !*ByteArray {
    const ba = try ByteArray.create(alloc);
    try ba.ensureTotalCapacity(alloc, simd_kernels.SIMD_BYTES);
    ba.items.len = simd_kernels.SIMD_BYTES;
    return ba;
}

fn wrapSimdResult(ctx: *Context, alloc: Allocator, tag: *const VirtualType, out_bytes: [simd_kernels.SIMD_BYTES]u8) !void {
    const out_ba = try allocSimdByteArray(alloc);
    out_ba.items[0..simd_kernels.SIMD_BYTES].* = out_bytes;
    const inner = try alloc.create(Value);
    inner.* = .{ .byte_array = out_ba };
    try ctx.stack.push(.{ .tagged = .{ .tag = tag, .inner = inner } });
}

// ---------------------------------------------------------------------------
// Construction: simd-from-stack ( v0..vN-1 type-str -- byte-array )
// ---------------------------------------------------------------------------

fn nativeSimdFromStack(ctx: *Context) anyerror!void {
    const alloc = ctx.containerAllocator();
    const arena = ctx.arena.allocator();

    const type_str_val = try ctx.stack.pop();
    const type_str = switch (type_str_val) {
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string", type_str_val);
            return error.TypeMismatch;
        },
    };

    const simd_type = SimdVectorType.fromString(type_str) orelse {
        helpers.setErrorContext(ctx, "simd-from-stack: unknown SIMD type \"{s}\"", .{type_str});
        return error.TypeMismatch;
    };

    const n = simd_type.laneCount();

    // pop N values from stack; lane 0 is deepest / first pushed.
    var vals: [16]Value = undefined;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        vals[i] = try ctx.stack.pop();
    }

    const ba = try allocSimdByteArray(alloc);

    switch (simd_type) {
        inline .@"2xf64", .@"4xf32", .@"2xi64", .@"4xi32", .@"8xi16", .@"16xi8", .@"2xu64", .@"4xu32", .@"8xu16", .@"16xu8" => |et| {
            const T = comptime etToType(et);
            const N = comptime etToLaneCount(et);
            for (0..N) |j| {
                const elem = try valueToElement(T, ctx, arena, vals[j]);
                const elem_size = @sizeOf(T);
                const offset = j * elem_size;
                ba.slice()[offset..][0..elem_size].* = std.mem.toBytes(elem);
            }
        },
    }

    try ctx.stack.push(.{ .byte_array = ba });
}

// ---------------------------------------------------------------------------
// Construction: simd-splat-impl ( value type-str -- byte-array )
// ---------------------------------------------------------------------------

fn nativeSimdSplat(ctx: *Context) anyerror!void {
    const alloc = ctx.containerAllocator();
    const arena = ctx.arena.allocator();

    const type_str_val = try ctx.stack.pop();
    const value_val = try ctx.stack.pop();

    const type_str = switch (type_str_val) {
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string", type_str_val);
            return error.TypeMismatch;
        },
    };

    const simd_type = SimdVectorType.fromString(type_str) orelse {
        helpers.setErrorContext(ctx, "simd-splat: unknown SIMD type \"{s}\"", .{type_str});
        return error.TypeMismatch;
    };

    const ba = try allocSimdByteArray(alloc);

    switch (simd_type) {
        inline .@"2xf64", .@"4xf32", .@"2xi64", .@"4xi32", .@"8xi16", .@"16xi8", .@"2xu64", .@"4xu32", .@"8xu16", .@"16xu8" => |et| {
            const T = comptime etToType(et);
            const N = comptime etToLaneCount(et);
            const scalar = try valueToElement(T, ctx, arena, value_val);
            simd_kernels.simdSplat(N, T, scalar, ba.slice()[0..simd_kernels.SIMD_BYTES]);
        },
    }

    try ctx.stack.push(.{ .byte_array = ba });
}

// ---------------------------------------------------------------------------
// Conversion: simd-to-array ( simd-NxT -- array )
// ---------------------------------------------------------------------------

fn nativeSimdToArray(ctx: *Context) anyerror!void {
    const alloc = ctx.containerAllocator();

    const tagged = try popSimdTagged(ctx);
    const ba = try extractByteArray(ctx, tagged);
    const simd_type = try extractSimdType(ctx, tagged);
    const bytes = try validateSimdSize(ctx, ba);

    const n = simd_type.laneCount();
    const result = try alloc.alloc(Value, n);

    switch (simd_type) {
        inline .@"2xf64", .@"4xf32", .@"2xi64", .@"4xi32", .@"8xi16", .@"16xi8", .@"2xu64", .@"4xu32", .@"8xu16", .@"16xu8" => |et| {
            const T = comptime etToType(et);
            const N = comptime etToLaneCount(et);
            for (0..N) |i| {
                result[i] = elementToValue(T, simd_kernels.simdGetLane(N, T, bytes, i));
            }
        },
    }

    try ctx.stack.push(.{ .array = result });
}

// ---------------------------------------------------------------------------
// Lane access: simd-lane-get ( simd-NxT fixnum -- value )
// ---------------------------------------------------------------------------

fn nativeSimdLaneGet(ctx: *Context) anyerror!void {
    const idx_val = try ctx.stack.pop();
    const tagged = try popSimdTagged(ctx);
    const ba = try extractByteArray(ctx, tagged);
    const simd_type = try extractSimdType(ctx, tagged);
    const bytes = try validateSimdSize(ctx, ba);

    const idx: i64 = switch (idx_val) {
        .fixnum => |n| n,
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum", idx_val);
            return error.TypeMismatch;
        },
    };

    const n = simd_type.laneCount();
    if (idx < 0 or idx >= @as(i64, @intCast(n))) {
        helpers.setErrorContext(ctx, "simd-lane: index {d} out of bounds for {d}-lane vector", .{ idx, n });
        return error.IndexOutOfBounds;
    }

    const lane: usize = @intCast(idx);
    switch (simd_type) {
        inline .@"2xf64", .@"4xf32", .@"2xi64", .@"4xi32", .@"8xi16", .@"16xi8", .@"2xu64", .@"4xu32", .@"8xu16", .@"16xu8" => |et| {
            const T = comptime etToType(et);
            const N = comptime etToLaneCount(et);
            try ctx.stack.push(elementToValue(T, simd_kernels.simdGetLane(N, T, bytes, lane)));
        },
    }
}

// ---------------------------------------------------------------------------
// Lane mutation: simd-lane-set ( simd-NxT value fixnum -- simd-NxT )
// ---------------------------------------------------------------------------

fn nativeSimdLaneSet(ctx: *Context) anyerror!void {
    const alloc = ctx.containerAllocator();
    const arena = ctx.arena.allocator();

    const idx_val = try ctx.stack.pop();
    const value_val = try ctx.stack.pop();
    const tagged = try popSimdTagged(ctx);
    const ba = try extractByteArray(ctx, tagged);
    const simd_type = try extractSimdType(ctx, tagged);
    const bytes = try validateSimdSize(ctx, ba);

    const idx: i64 = switch (idx_val) {
        .fixnum => |n| n,
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum", idx_val);
            return error.TypeMismatch;
        },
    };

    const n = simd_type.laneCount();
    if (idx < 0 or idx >= @as(i64, @intCast(n))) {
        helpers.setErrorContext(ctx, "simd-set-lane: index {d} out of bounds for {d}-lane vector", .{ idx, n });
        return error.IndexOutOfBounds;
    }

    const lane: usize = @intCast(idx);
    switch (simd_type) {
        inline .@"2xf64", .@"4xf32", .@"2xi64", .@"4xi32", .@"8xi16", .@"16xi8", .@"2xu64", .@"4xu32", .@"8xu16", .@"16xu8" => |et| {
            const T = comptime etToType(et);
            const N = comptime etToLaneCount(et);
            const value = try valueToElement(T, ctx, arena, value_val);
            var out_bytes: [simd_kernels.SIMD_BYTES]u8 = undefined;
            simd_kernels.simdSetLane(N, T, bytes, lane, value, &out_bytes);
            try wrapSimdResult(ctx, alloc, tagged.tag, out_bytes);
        },
    }
}

// ---------------------------------------------------------------------------
// Element-wise arithmetic
// ---------------------------------------------------------------------------

fn simdArithmeticOp(comptime op: simd_kernels.Op, ctx: *Context) anyerror!void {
    const alloc = ctx.containerAllocator();

    const b_val = try ctx.stack.pop();
    const a_val = try ctx.stack.pop();

    const a_tagged = switch (a_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "simd-*", a_val);
            return error.TypeMismatch;
        },
    };
    const b_tagged = switch (b_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "simd-*", b_val);
            return error.TypeMismatch;
        },
    };

    if (a_tagged.tag != b_tagged.tag) {
        const op_name = switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
        };
        helpers.setErrorContext(ctx, "{s} {s} {s}: type mismatch", .{ a_tagged.tag.name, op_name, b_tagged.tag.name });
        return error.TypeMismatch;
    }

    const a_ba = try extractByteArray(ctx, a_tagged);
    const b_ba = try extractByteArray(ctx, b_tagged);
    const simd_type = try extractSimdType(ctx, a_tagged);
    const a_bytes = try validateSimdSize(ctx, a_ba);
    const b_bytes = try validateSimdSize(ctx, b_ba);

    switch (simd_type) {
        inline .@"2xf64", .@"4xf32", .@"2xi64", .@"4xi32", .@"8xi16", .@"16xi8", .@"2xu64", .@"4xu32", .@"8xu16", .@"16xu8" => |et| {
            const T = comptime etToType(et);
            const N = comptime etToLaneCount(et);
            var out_bytes: [simd_kernels.SIMD_BYTES]u8 = undefined;
            simd_kernels.simdBinaryOp(N, T, op, a_bytes, b_bytes, &out_bytes);
            try wrapSimdResult(ctx, alloc, a_tagged.tag, out_bytes);
        },
    }
}

fn nativeSimdAdd(ctx: *Context) anyerror!void {
    return simdArithmeticOp(.add, ctx);
}

fn nativeSimdSub(ctx: *Context) anyerror!void {
    return simdArithmeticOp(.sub, ctx);
}

fn nativeSimdMul(ctx: *Context) anyerror!void {
    return simdArithmeticOp(.mul, ctx);
}

fn nativeSimdDiv(ctx: *Context) anyerror!void {
    return simdArithmeticOp(.div, ctx);
}

// ---------------------------------------------------------------------------
// Shuffle: simd-shuffle-impl ( simd-NxT array -- simd-NxT )
// ---------------------------------------------------------------------------

fn nativeSimdShuffle(ctx: *Context) anyerror!void {
    const alloc = ctx.containerAllocator();

    const indices_val = try ctx.stack.pop();
    const tagged = try popSimdTagged(ctx);
    const ba = try extractByteArray(ctx, tagged);
    const simd_type = try extractSimdType(ctx, tagged);
    const bytes = try validateSimdSize(ctx, ba);

    const indices_arr = switch (indices_val) {
        .array => |a| a,
        else => {
            helpers.setTypeMismatchError(ctx, "array", indices_val);
            return error.TypeMismatch;
        },
    };

    const n = simd_type.laneCount();
    if (indices_arr.len != n) {
        helpers.setErrorContext(ctx, "simd-shuffle: expected {d} indices, got {d}", .{ n, indices_arr.len });
        return error.TypeMismatch;
    }

    switch (simd_type) {
        inline .@"2xf64", .@"4xf32", .@"2xi64", .@"4xi32", .@"8xi16", .@"16xi8", .@"2xu64", .@"4xu32", .@"8xu16", .@"16xu8" => |et| {
            const T = comptime etToType(et);
            const N = comptime etToLaneCount(et);
            var indices: [N]usize = undefined;
            for (0..N) |i| {
                const idx: i64 = switch (indices_arr[i]) {
                    .fixnum => |f| f,
                    else => {
                        helpers.setErrorContext(ctx, "simd-shuffle: index {d} is not a fixnum", .{i});
                        return error.TypeMismatch;
                    },
                };
                if (idx < 0 or idx >= @as(i64, @intCast(N))) {
                    helpers.setErrorContext(ctx, "simd-shuffle: index {d} out of bounds (0..{d})", .{ idx, N });
                    return error.IndexOutOfBounds;
                }
                indices[i] = @intCast(idx);
            }
            var out_bytes: [simd_kernels.SIMD_BYTES]u8 = undefined;
            simd_kernels.simdPermute(N, T, bytes, indices, &out_bytes);
            try wrapSimdResult(ctx, alloc, tagged.tag, out_bytes);
        },
    }
}

// ---------------------------------------------------------------------------
// Select: simd-select-impl ( mask a b -- simd-NxT )
// ---------------------------------------------------------------------------

fn nativeSimdSelect(ctx: *Context) anyerror!void {
    const alloc = ctx.containerAllocator();

    const b_val = try ctx.stack.pop();
    const a_val = try ctx.stack.pop();
    const mask_val = try ctx.stack.pop();

    const mask_tagged = switch (mask_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "simd-*", mask_val);
            return error.TypeMismatch;
        },
    };
    const a_tagged = switch (a_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "simd-*", a_val);
            return error.TypeMismatch;
        },
    };
    const b_tagged = switch (b_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "simd-*", b_val);
            return error.TypeMismatch;
        },
    };

    if (mask_tagged.tag != a_tagged.tag or a_tagged.tag != b_tagged.tag) {
        helpers.setErrorContext(ctx, "simd-select: all three vectors must be the same SIMD type", .{});
        return error.TypeMismatch;
    }

    const mask_ba = try extractByteArray(ctx, mask_tagged);
    const a_ba = try extractByteArray(ctx, a_tagged);
    const b_ba = try extractByteArray(ctx, b_tagged);
    const simd_type = try extractSimdType(ctx, a_tagged);
    const mask_bytes = try validateSimdSize(ctx, mask_ba);
    const a_bytes = try validateSimdSize(ctx, a_ba);
    const b_bytes = try validateSimdSize(ctx, b_ba);

    switch (simd_type) {
        inline .@"2xf64", .@"4xf32", .@"2xi64", .@"4xi32", .@"8xi16", .@"16xi8", .@"2xu64", .@"4xu32", .@"8xu16", .@"16xu8" => |et| {
            const T = comptime etToType(et);
            const N = comptime etToLaneCount(et);
            var out_bytes: [simd_kernels.SIMD_BYTES]u8 = undefined;
            simd_kernels.simdSelect(N, T, mask_bytes, a_bytes, b_bytes, &out_bytes);
            try wrapSimdResult(ctx, alloc, a_tagged.tag, out_bytes);
        },
    }
}

// ---------------------------------------------------------------------------
// Blend: simd-blend-impl ( a b fixnum -- simd-NxT )
// ---------------------------------------------------------------------------

fn nativeSimdBlend(ctx: *Context) anyerror!void {
    const alloc = ctx.containerAllocator();

    const bitmask_val = try ctx.stack.pop();
    const b_val = try ctx.stack.pop();
    const a_val = try ctx.stack.pop();

    const a_tagged = switch (a_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "simd-*", a_val);
            return error.TypeMismatch;
        },
    };
    const b_tagged = switch (b_val) {
        .tagged => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "simd-*", b_val);
            return error.TypeMismatch;
        },
    };

    if (a_tagged.tag != b_tagged.tag) {
        helpers.setErrorContext(ctx, "simd-blend: both vectors must be the same SIMD type", .{});
        return error.TypeMismatch;
    }

    const bitmask: i64 = switch (bitmask_val) {
        .fixnum => |n| n,
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum", bitmask_val);
            return error.TypeMismatch;
        },
    };

    if (bitmask < 0) {
        helpers.setErrorContext(ctx, "simd-blend: bitmask must be non-negative, got {d}", .{bitmask});
        return error.TypeMismatch;
    }

    const a_ba = try extractByteArray(ctx, a_tagged);
    const b_ba = try extractByteArray(ctx, b_tagged);
    const simd_type = try extractSimdType(ctx, a_tagged);
    const a_bytes = try validateSimdSize(ctx, a_ba);
    const b_bytes = try validateSimdSize(ctx, b_ba);

    switch (simd_type) {
        inline .@"2xf64", .@"4xf32", .@"2xi64", .@"4xi32", .@"8xi16", .@"16xi8", .@"2xu64", .@"4xu32", .@"8xu16", .@"16xu8" => |et| {
            const T = comptime etToType(et);
            const N = comptime etToLaneCount(et);
            var out_bytes: [simd_kernels.SIMD_BYTES]u8 = undefined;
            simd_kernels.simdBlend(N, T, a_bytes, b_bytes, @intCast(bitmask), &out_bytes);
            try wrapSimdResult(ctx, alloc, a_tagged.tag, out_bytes);
        },
    }
}
