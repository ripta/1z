const std = @import("std");

pub const Op = enum { add, sub, mul, div };

/// Integer division failures. Float division never raises: zero divisors follow IEEE and
/// produce inf/nan. FixnumOverflow covers minInt(T) / -1, whose quotient does not fit T;
/// the scalar tower promotes that case to bignum, which a fixed-width packed array cannot hold.
pub const DivideError = error{ DivisionByZero, FixnumOverflow };

fn OpResult(comptime op: Op) type {
    return if (op == .div) DivideError!void else void;
}

/// The ten packed element types. Names match the `"i8"`..`"f64"` strings the packed
/// natives take and the `packed-<name>` virtual type names.
pub const ElementType = enum {
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

    pub fn fromString(s: []const u8) ?ElementType {
        const map = std.StaticStringMap(ElementType).initComptime(.{
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

    pub fn fromTagName(name: []const u8) ?ElementType {
        if (std.mem.startsWith(u8, name, "packed-")) {
            return fromString(name["packed-".len..]);
        }
        return null;
    }

    pub fn elemSize(self: ElementType) usize {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .i64, .u64, .f64 => 8,
        };
    }

    pub fn typeName(self: ElementType) []const u8 {
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

    pub fn toType(comptime self: ElementType) type {
        return switch (self) {
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
};

/// Element-wise addition on packed byte slices interpreted as type T.
pub fn addPacked(comptime T: type, a: []const u8, b: []const u8, out: []u8) void {
    binaryOp(T, .add, a, b, out);
}

/// Element-wise subtraction on packed byte slices interpreted as type T.
pub fn subPacked(comptime T: type, a: []const u8, b: []const u8, out: []u8) void {
    binaryOp(T, .sub, a, b, out);
}

/// Element-wise multiplication on packed byte slices interpreted as type T.
pub fn mulPacked(comptime T: type, a: []const u8, b: []const u8, out: []u8) void {
    binaryOp(T, .mul, a, b, out);
}

/// Element-wise division on packed byte slices interpreted as type T.
/// Integer types use truncating division; float types use standard division.
pub fn divPacked(comptime T: type, a: []const u8, b: []const u8, out: []u8) DivideError!void {
    return binaryOp(T, .div, a, b, out);
}

/// Fill a packed byte slice with copies of a single value.
pub fn fillPacked(comptime T: type, out: []u8, value: T) void {
    const n = elementCount(T, out);
    for (0..n) |i| {
        writeElement(T, out, i, value);
    }
}

/// Read a single element from a byte slice at element index i (unaligned-safe).
pub fn readElement(comptime T: type, bytes: []const u8, i: usize) T {
    const elem_size = @sizeOf(T);
    const offset = i * elem_size;
    return std.mem.bytesToValue(T, bytes[offset..][0..elem_size]);
}

/// Write a single element to a byte slice at element index i (unaligned-safe).
pub fn writeElement(comptime T: type, bytes: []u8, i: usize, value: T) void {
    const elem_size = @sizeOf(T);
    const offset = i * elem_size;
    bytes[offset..][0..elem_size].* = std.mem.toBytes(value);
}

/// Return the number of elements of type T that fit in the byte slice.
pub fn elementCount(comptime T: type, bytes: []const u8) usize {
    return bytes.len / @sizeOf(T);
}

// ---------------------------------------------------------------------------
// Reductions
// ---------------------------------------------------------------------------

/// Sum all elements. Returns 0 for empty arrays.
pub fn sumPacked(comptime T: type, bytes: []const u8) T {
    const n = elementCount(T, bytes);
    if (n == 0) return zeroval(T);

    const chunk = std.simd.suggestVectorLength(T) orelse 4;
    const is_int = @typeInfo(T) == .int;
    const elem_size = @sizeOf(T);
    const chunk_bytes = chunk * elem_size;

    var acc: T = zeroval(T);
    var i: usize = 0;
    while (i + chunk <= n) : (i += chunk) {
        const byte_off = i * elem_size;
        var buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        @memcpy(&buf, bytes[byte_off..][0..chunk_bytes]);
        const aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&buf);
        const v: @Vector(chunk, T) = aligned.*;
        const chunk_sum: T = if (is_int) @reduce(.Add, v) else @reduce(.Add, v);
        acc = if (is_int) acc +% chunk_sum else acc + chunk_sum;
    }
    while (i < n) : (i += 1) {
        const e = readElement(T, bytes, i);
        acc = if (is_int) acc +% e else acc + e;
    }
    return acc;
}

/// Product of all elements. Returns 1 for empty arrays.
pub fn productPacked(comptime T: type, bytes: []const u8) T {
    const n = elementCount(T, bytes);
    if (n == 0) return oneval(T);

    var acc: T = oneval(T);
    const is_int = @typeInfo(T) == .int;
    for (0..n) |i| {
        const e = readElement(T, bytes, i);
        acc = if (is_int) acc *% e else acc * e;
    }
    return acc;
}

/// Minimum element. Returns null for empty arrays.
pub fn minPacked(comptime T: type, bytes: []const u8) ?T {
    const n = elementCount(T, bytes);
    if (n == 0) return null;

    const chunk = std.simd.suggestVectorLength(T) orelse 4;
    const elem_size = @sizeOf(T);
    const chunk_bytes = chunk * elem_size;

    var acc: T = readElement(T, bytes, 0);
    var i: usize = 0;
    while (i + chunk <= n) : (i += chunk) {
        const byte_off = i * elem_size;
        var buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        @memcpy(&buf, bytes[byte_off..][0..chunk_bytes]);
        const aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&buf);
        const v: @Vector(chunk, T) = aligned.*;
        const chunk_min: T = @reduce(.Min, v);
        acc = if (minCmp(T, chunk_min, acc)) chunk_min else acc;
    }
    while (i < n) : (i += 1) {
        const e = readElement(T, bytes, i);
        if (minCmp(T, e, acc)) acc = e;
    }
    return acc;
}

/// Maximum element. Returns null for empty arrays.
pub fn maxPacked(comptime T: type, bytes: []const u8) ?T {
    const n = elementCount(T, bytes);
    if (n == 0) return null;

    const chunk = std.simd.suggestVectorLength(T) orelse 4;
    const elem_size = @sizeOf(T);
    const chunk_bytes = chunk * elem_size;

    var acc: T = readElement(T, bytes, 0);
    var i: usize = 0;
    while (i + chunk <= n) : (i += chunk) {
        const byte_off = i * elem_size;
        var buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        @memcpy(&buf, bytes[byte_off..][0..chunk_bytes]);
        const aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&buf);
        const v: @Vector(chunk, T) = aligned.*;
        const chunk_max: T = @reduce(.Max, v);
        acc = if (minCmp(T, acc, chunk_max)) chunk_max else acc;
    }
    while (i < n) : (i += 1) {
        const e = readElement(T, bytes, i);
        if (minCmp(T, acc, e)) acc = e;
    }
    return acc;
}

/// Dot product: element-wise multiply then sum. Returns 0 for empty arrays.
pub fn dotPacked(comptime T: type, a: []const u8, b: []const u8) T {
    const elem_size = @sizeOf(T);
    const n = a.len / elem_size;
    if (n == 0) return zeroval(T);

    const chunk = std.simd.suggestVectorLength(T) orelse 4;
    const is_int = @typeInfo(T) == .int;
    const chunk_bytes = chunk * elem_size;

    var acc: T = zeroval(T);
    var i: usize = 0;
    while (i + chunk <= n) : (i += chunk) {
        const byte_off = i * elem_size;
        var a_buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        var b_buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        @memcpy(&a_buf, a[byte_off..][0..chunk_bytes]);
        @memcpy(&b_buf, b[byte_off..][0..chunk_bytes]);

        const a_aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&a_buf);
        const b_aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&b_buf);

        const va: @Vector(chunk, T) = a_aligned.*;
        const vb: @Vector(chunk, T) = b_aligned.*;
        const prod: @Vector(chunk, T) = if (is_int) va *% vb else va * vb;
        const chunk_sum: T = @reduce(.Add, prod);
        acc = if (is_int) acc +% chunk_sum else acc + chunk_sum;
    }
    while (i < n) : (i += 1) {
        const ae = readElement(T, a, i);
        const be = readElement(T, b, i);
        const p: T = if (is_int) ae *% be else ae * be;
        acc = if (is_int) acc +% p else acc + p;
    }
    return acc;
}

// ---------------------------------------------------------------------------
// Scalar broadcast operation
// ---------------------------------------------------------------------------

/// Element-wise operation with a scalar broadcast to the second operand.
pub fn scalarBinaryOp(comptime T: type, comptime op: Op, a: []const u8, scalar: T, out: []u8) OpResult(op) {
    const elem_size = @sizeOf(T);
    const n = a.len / elem_size;
    const chunk = std.simd.suggestVectorLength(T) orelse 4;
    const is_int = @typeInfo(T) == .int;
    const chunk_bytes = chunk * elem_size;

    const guard_div = comptime (op == .div and is_int);
    const guard_overflow = comptime (guard_div and @typeInfo(T).int.signedness == .signed);

    // The divisor is loop-invariant, so the zero test hoists to entry. The minInt / -1
    // overflow depends on each dividend element, so only the divisor half hoists.
    if (comptime guard_div) {
        if (scalar == 0) return error.DivisionByZero;
    }
    const check_min = if (comptime guard_overflow) scalar == -1 else false;

    var i: usize = 0;
    while (i + chunk <= n) : (i += chunk) {
        const byte_off = i * elem_size;
        var a_buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        @memcpy(&a_buf, a[byte_off..][0..chunk_bytes]);

        const a_aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&a_buf);
        const va: @Vector(chunk, T) = a_aligned.*;
        if (comptime guard_overflow) {
            if (check_min) {
                const min_splat: @Vector(chunk, T) = @splat(std.math.minInt(T));
                if (@reduce(.Or, va == min_splat)) return error.FixnumOverflow;
            }
        }
        const vb: @Vector(chunk, T) = @splat(scalar);
        const vr: @Vector(chunk, T) = switch (op) {
            .add => if (is_int) va +% vb else va + vb,
            .sub => if (is_int) va -% vb else va - vb,
            .mul => if (is_int) va *% vb else va * vb,
            .div => if (is_int) @divTrunc(va, vb) else va / vb,
        };

        const r_aligned: *const [chunk_bytes]u8 = @ptrCast(&vr);
        @memcpy(out[byte_off..][0..chunk_bytes], r_aligned);
    }

    while (i < n) : (i += 1) {
        const ae = readElement(T, a, i);
        if (comptime guard_overflow) {
            if (check_min and ae == std.math.minInt(T)) return error.FixnumOverflow;
        }
        const re: T = switch (op) {
            .add => if (is_int) ae +% scalar else ae + scalar,
            .sub => if (is_int) ae -% scalar else ae - scalar,
            .mul => if (is_int) ae *% scalar else ae * scalar,
            .div => if (is_int) @divTrunc(ae, scalar) else ae / scalar,
        };
        writeElement(T, out, i, re);
    }
}

// ---------------------------------------------------------------------------
// Chained scalar operations
// ---------------------------------------------------------------------------

/// One step of a recognized arithmetic chain: the element is the left operand,
/// the scalar the right.
///
/// Scalars are stored as f64 and cast to the element type when the chain is applied.
/// The cast is exact because the builder converts each literal to the element type
/// before widening it for storage.
pub const ChainOp = struct {
    op: Op,
    scalar: f64,
};

/// The SIMD chunk width `applyChainChunk` produces for element type T. The chunk
/// buffer a caller passes as `out` must be sized from this same function, so the
/// fallback width and the real width can never disagree.
pub fn chainChunkLen(comptime T: type) comptime_int {
    return std.simd.suggestVectorLength(T) orelse 4;
}

/// Apply an operation chain to up to one SIMD chunk of float elements starting at
/// element index `start`, widening results to f64 into `out`. Returns the number of
/// elements produced, zero at the end of the array. The chunk stays in registers
/// across the chain, so each additional operation costs one instruction per chunk.
///
/// Float-only: integer element types diverge from the scalar tower on overflow and
/// are never recognized, so no wrapping or division guards are needed here.
pub fn applyChainChunk(comptime T: type, bytes: []const u8, start: usize, chain: []const ChainOp, out: []f64) usize {
    comptime std.debug.assert(@typeInfo(T) == .float);
    const elem_size = @sizeOf(T);
    const n = bytes.len / elem_size;
    if (start >= n) return 0;

    const chunk = chainChunkLen(T);
    const remaining = n - start;

    if (remaining >= chunk) {
        const chunk_bytes = chunk * elem_size;
        const byte_off = start * elem_size;
        var a_buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        @memcpy(&a_buf, bytes[byte_off..][0..chunk_bytes]);

        const a_aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&a_buf);
        var va: @Vector(chunk, T) = a_aligned.*;
        for (chain) |step| {
            const vb: @Vector(chunk, T) = @splat(@floatCast(step.scalar));
            va = switch (step.op) {
                .add => va + vb,
                .sub => va - vb,
                .mul => va * vb,
                .div => va / vb,
            };
        }

        for (0..chunk) |lane| {
            out[lane] = @floatCast(va[lane]);
        }
        return chunk;
    }

    for (0..remaining) |i| {
        var e = readElement(T, bytes, start + i);
        for (chain) |step| {
            const s: T = @floatCast(step.scalar);
            e = switch (step.op) {
                .add => e + s,
                .sub => e - s,
                .mul => e * s,
                .div => e / s,
            };
        }
        out[i] = @floatCast(e);
    }
    return remaining;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn zeroval(comptime T: type) T {
    return if (@typeInfo(T) == .float) @as(T, 0.0) else @as(T, 0);
}

fn oneval(comptime T: type) T {
    return if (@typeInfo(T) == .float) @as(T, 1.0) else @as(T, 1);
}

fn minCmp(comptime T: type, a: T, b: T) bool {
    return if (@typeInfo(T) == .float) a < b else a < b;
}

// ---------------------------------------------------------------------------
// Internal: SIMD binary operation kernel
// ---------------------------------------------------------------------------

fn binaryOp(comptime T: type, comptime op: Op, a: []const u8, b: []const u8, out: []u8) OpResult(op) {
    const elem_size = @sizeOf(T);
    const n = a.len / elem_size;
    const chunk = std.simd.suggestVectorLength(T) orelse 4;
    const is_int = @typeInfo(T) == .int;

    const guard_div = comptime (op == .div and is_int);
    const guard_overflow = comptime (guard_div and @typeInfo(T).int.signedness == .signed);

    // SIMD track: load chunks into aligned local buffers, process, write back.
    // Each chunk covers `chunk` elements, which is `chunk * elem_size` bytes wide.
    const chunk_bytes = chunk * elem_size;
    var i: usize = 0;
    while (i + chunk <= n) : (i += chunk) {
        const byte_off = i * elem_size;
        var a_buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        var b_buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        @memcpy(&a_buf, a[byte_off..][0..chunk_bytes]);
        @memcpy(&b_buf, b[byte_off..][0..chunk_bytes]);

        const a_aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&a_buf);
        const b_aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&b_buf);

        const va: @Vector(chunk, T) = a_aligned.*;
        const vb: @Vector(chunk, T) = b_aligned.*;
        if (comptime guard_div) {
            const zero_splat: @Vector(chunk, T) = @splat(0);
            if (@reduce(.Or, vb == zero_splat)) return error.DivisionByZero;
        }
        if (comptime guard_overflow) {
            const min_splat: @Vector(chunk, T) = @splat(std.math.minInt(T));
            const neg_one_splat: @Vector(chunk, T) = @splat(-1);
            const false_splat: @Vector(chunk, bool) = @splat(false);
            const overflow_lanes = @select(bool, va == min_splat, vb == neg_one_splat, false_splat);
            if (@reduce(.Or, overflow_lanes)) return error.FixnumOverflow;
        }
        const vr: @Vector(chunk, T) = switch (op) {
            .add => if (is_int) va +% vb else va + vb,
            .sub => if (is_int) va -% vb else va - vb,
            .mul => if (is_int) va *% vb else va * vb,
            .div => if (is_int) @divTrunc(va, vb) else va / vb,
        };

        const r_aligned: *const [chunk_bytes]u8 = @ptrCast(&vr);
        @memcpy(out[byte_off..][0..chunk_bytes], r_aligned);
    }

    // Scalar tail: process remaining elements one by one.
    while (i < n) : (i += 1) {
        const ae = readElement(T, a, i);
        const be = readElement(T, b, i);
        if (comptime guard_div) {
            if (be == 0) return error.DivisionByZero;
        }
        if (comptime guard_overflow) {
            if (ae == std.math.minInt(T) and be == -1) return error.FixnumOverflow;
        }
        const re: T = switch (op) {
            .add => if (is_int) ae +% be else ae + be,
            .sub => if (is_int) ae -% be else ae - be,
            .mul => if (is_int) ae *% be else ae * be,
            .div => if (is_int) @divTrunc(ae, be) else ae / be,
        };
        writeElement(T, out, i, re);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "addPacked f64: empty" {
    var out = [_]u8{};
    addPacked(f64, &.{}, &.{}, &out);
}

test "addPacked f64: single element" {
    const a = std.mem.toBytes(@as(f64, 1.5));
    const b = std.mem.toBytes(@as(f64, 2.5));
    var out: [8]u8 = undefined;
    addPacked(f64, &a, &b, &out);
    try testing.expectEqual(@as(f64, 4.0), readElement(f64, &out, 0));
}

test "addPacked f64: multiple elements" {
    const a_vals = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const b_vals = [_]f64{ 10.0, 20.0, 30.0, 40.0, 50.0 };
    const a = std.mem.sliceAsBytes(&a_vals);
    const b = std.mem.sliceAsBytes(&b_vals);
    var out_bytes: [5 * 8]u8 = undefined;
    addPacked(f64, a, b, &out_bytes);
    try testing.expectEqual(@as(f64, 11.0), readElement(f64, &out_bytes, 0));
    try testing.expectEqual(@as(f64, 22.0), readElement(f64, &out_bytes, 1));
    try testing.expectEqual(@as(f64, 33.0), readElement(f64, &out_bytes, 2));
    try testing.expectEqual(@as(f64, 44.0), readElement(f64, &out_bytes, 3));
    try testing.expectEqual(@as(f64, 55.0), readElement(f64, &out_bytes, 4));
}

test "subPacked i32: wrapping" {
    const min_i32 = std.math.minInt(i32);
    const a_vals = [_]i32{min_i32};
    const b_vals = [_]i32{1};
    var out_bytes: [4]u8 = undefined;
    subPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    try testing.expectEqual(std.math.maxInt(i32), readElement(i32, &out_bytes, 0));
}

test "mulPacked i32: basic" {
    const a_vals = [_]i32{ 2, 3, 4 };
    const b_vals = [_]i32{ 5, 6, 7 };
    var out_bytes: [3 * 4]u8 = undefined;
    mulPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    try testing.expectEqual(@as(i32, 10), readElement(i32, &out_bytes, 0));
    try testing.expectEqual(@as(i32, 18), readElement(i32, &out_bytes, 1));
    try testing.expectEqual(@as(i32, 28), readElement(i32, &out_bytes, 2));
}

test "divPacked f64: basic" {
    const a_vals = [_]f64{ 10.0, 20.0, 30.0 };
    const b_vals = [_]f64{ 2.0, 5.0, 6.0 };
    var out_bytes: [3 * 8]u8 = undefined;
    try divPacked(f64, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    try testing.expectEqual(@as(f64, 5.0), readElement(f64, &out_bytes, 0));
    try testing.expectEqual(@as(f64, 4.0), readElement(f64, &out_bytes, 1));
    try testing.expectEqual(@as(f64, 5.0), readElement(f64, &out_bytes, 2));
}

test "divPacked i32: truncating" {
    const a_vals = [_]i32{ 7, -7, 10 };
    const b_vals = [_]i32{ 2, 2, 3 };
    var out_bytes: [3 * 4]u8 = undefined;
    try divPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    try testing.expectEqual(@as(i32, 3), readElement(i32, &out_bytes, 0));
    try testing.expectEqual(@as(i32, -3), readElement(i32, &out_bytes, 1));
    try testing.expectEqual(@as(i32, 3), readElement(i32, &out_bytes, 2));
}

test "divPacked i32: zero divisor in scalar tail" {
    const a_vals = [_]i32{6};
    const b_vals = [_]i32{0};
    var out_bytes: [4]u8 = undefined;
    try testing.expectError(error.DivisionByZero, divPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes));
}

test "divPacked i32: zero divisor in vector path" {
    const n = 16;
    var a_vals: [n]i32 = undefined;
    var b_vals: [n]i32 = undefined;
    for (0..n) |i| {
        a_vals[i] = @intCast(i + 1);
        b_vals[i] = 1;
    }
    b_vals[0] = 0;
    var out_bytes: [n * 4]u8 = undefined;
    try testing.expectError(error.DivisionByZero, divPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes));
}

test "divPacked u16: zero divisor" {
    const a_vals = [_]u16{6};
    const b_vals = [_]u16{0};
    var out_bytes: [2]u8 = undefined;
    try testing.expectError(error.DivisionByZero, divPacked(u16, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes));
}

test "divPacked i32: minInt / -1 in scalar tail" {
    const a_vals = [_]i32{std.math.minInt(i32)};
    const b_vals = [_]i32{-1};
    var out_bytes: [4]u8 = undefined;
    try testing.expectError(error.FixnumOverflow, divPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes));
}

test "divPacked i32: minInt / -1 in vector path" {
    const n = 16;
    var a_vals: [n]i32 = undefined;
    var b_vals: [n]i32 = undefined;
    for (0..n) |i| {
        a_vals[i] = @intCast(i + 1);
        b_vals[i] = -1;
    }
    a_vals[3] = std.math.minInt(i32);
    var out_bytes: [n * 4]u8 = undefined;
    try testing.expectError(error.FixnumOverflow, divPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes));
}

test "divPacked i32: minInt lane with nonzero non-negative-one divisor is fine" {
    const n = 16;
    var a_vals: [n]i32 = undefined;
    var b_vals: [n]i32 = undefined;
    for (0..n) |i| {
        a_vals[i] = @intCast(i + 1);
        b_vals[i] = 2;
    }
    a_vals[0] = std.math.minInt(i32);
    b_vals[5] = -1;
    var out_bytes: [n * 4]u8 = undefined;
    try divPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    try testing.expectEqual(@as(i32, -1073741824), readElement(i32, &out_bytes, 0));
    try testing.expectEqual(@as(i32, -6), readElement(i32, &out_bytes, 5));
}

test "divPacked f64: zero divisor follows IEEE" {
    const a_vals = [_]f64{6.0};
    const b_vals = [_]f64{0.0};
    var out_bytes: [8]u8 = undefined;
    try divPacked(f64, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    try testing.expect(std.math.isInf(readElement(f64, &out_bytes, 0)));
}

test "addPacked i8: wrapping overflow" {
    const a_vals = [_]i8{ 127, -128, 50 };
    const b_vals = [_]i8{ 1, -1, 100 };
    var out_bytes: [3]u8 = undefined;
    addPacked(i8, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    try testing.expectEqual(@as(i8, -128), readElement(i8, &out_bytes, 0));
    try testing.expectEqual(@as(i8, 127), readElement(i8, &out_bytes, 1));
    try testing.expectEqual(@as(i8, -106), readElement(i8, &out_bytes, 2));
}

test "fillPacked f64: basic" {
    var out_bytes: [3 * 8]u8 = undefined;
    fillPacked(f64, &out_bytes, 42.0);
    try testing.expectEqual(@as(f64, 42.0), readElement(f64, &out_bytes, 0));
    try testing.expectEqual(@as(f64, 42.0), readElement(f64, &out_bytes, 1));
    try testing.expectEqual(@as(f64, 42.0), readElement(f64, &out_bytes, 2));
}

test "fillPacked i32: basic" {
    var out_bytes: [4 * 4]u8 = undefined;
    fillPacked(i32, &out_bytes, -7);
    for (0..4) |i| {
        try testing.expectEqual(@as(i32, -7), readElement(i32, &out_bytes, i));
    }
}

// ---------------------------------------------------------------------------
// Reduction tests
// ---------------------------------------------------------------------------

test "sumPacked f64: empty" {
    try testing.expectEqual(@as(f64, 0.0), sumPacked(f64, &.{}));
}

test "sumPacked f64: single" {
    const vals = [_]f64{3.5};
    try testing.expectEqual(@as(f64, 3.5), sumPacked(f64, std.mem.sliceAsBytes(&vals)));
}

test "sumPacked f64: multiple" {
    const vals = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    try testing.expectEqual(@as(f64, 15.0), sumPacked(f64, std.mem.sliceAsBytes(&vals)));
}

test "sumPacked i32: wrapping" {
    const vals = [_]i32{ std.math.maxInt(i32), 1 };
    try testing.expectEqual(std.math.minInt(i32), sumPacked(i32, std.mem.sliceAsBytes(&vals)));
}

test "productPacked f64: empty" {
    try testing.expectEqual(@as(f64, 1.0), productPacked(f64, &.{}));
}

test "productPacked f64: multiple" {
    const vals = [_]f64{ 2.0, 3.0, 4.0 };
    try testing.expectEqual(@as(f64, 24.0), productPacked(f64, std.mem.sliceAsBytes(&vals)));
}

test "productPacked i32: basic" {
    const vals = [_]i32{ 2, 3, 4 };
    try testing.expectEqual(@as(i32, 24), productPacked(i32, std.mem.sliceAsBytes(&vals)));
}

test "minPacked f64: empty" {
    try testing.expect(minPacked(f64, &.{}) == null);
}

test "minPacked f64: multiple" {
    const vals = [_]f64{ 3.0, 1.0, 4.0, 1.5 };
    try testing.expectEqual(@as(f64, 1.0), minPacked(f64, std.mem.sliceAsBytes(&vals)).?);
}

test "minPacked i32: negative" {
    const vals = [_]i32{ 5, -3, 2, 0 };
    try testing.expectEqual(@as(i32, -3), minPacked(i32, std.mem.sliceAsBytes(&vals)).?);
}

test "maxPacked f64: multiple" {
    const vals = [_]f64{ 3.0, 1.0, 4.0, 1.5 };
    try testing.expectEqual(@as(f64, 4.0), maxPacked(f64, std.mem.sliceAsBytes(&vals)).?);
}

test "maxPacked i32: negative" {
    const vals = [_]i32{ -5, -3, -2, -10 };
    try testing.expectEqual(@as(i32, -2), maxPacked(i32, std.mem.sliceAsBytes(&vals)).?);
}

test "dotPacked f64: empty" {
    try testing.expectEqual(@as(f64, 0.0), dotPacked(f64, &.{}, &.{}));
}

test "dotPacked f64: basic" {
    const a_vals = [_]f64{ 1.0, 2.0, 3.0 };
    const b_vals = [_]f64{ 4.0, 5.0, 6.0 };
    try testing.expectEqual(@as(f64, 32.0), dotPacked(f64, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals)));
}

test "dotPacked i32: basic" {
    const a_vals = [_]i32{ 1, 2, 3 };
    const b_vals = [_]i32{ 4, 5, 6 };
    try testing.expectEqual(@as(i32, 32), dotPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals)));
}

test "sumPacked f64: large array exercises multi-chunk path" {
    const n = 64;
    var vals: [n]f64 = undefined;
    for (0..n) |i| vals[i] = 1.0;
    try testing.expectEqual(@as(f64, 64.0), sumPacked(f64, std.mem.sliceAsBytes(&vals)));
}

// ---------------------------------------------------------------------------
// Scalar broadcast tests
// ---------------------------------------------------------------------------

test "scalarBinaryOp f64 add: basic" {
    const a_vals = [_]f64{ 1.0, 2.0, 3.0 };
    var out_bytes: [3 * 8]u8 = undefined;
    scalarBinaryOp(f64, .add, std.mem.sliceAsBytes(&a_vals), 10.0, &out_bytes);
    try testing.expectEqual(@as(f64, 11.0), readElement(f64, &out_bytes, 0));
    try testing.expectEqual(@as(f64, 12.0), readElement(f64, &out_bytes, 1));
    try testing.expectEqual(@as(f64, 13.0), readElement(f64, &out_bytes, 2));
}

test "scalarBinaryOp i32 mul: basic" {
    const a_vals = [_]i32{ 2, 3, 4 };
    var out_bytes: [3 * 4]u8 = undefined;
    scalarBinaryOp(i32, .mul, std.mem.sliceAsBytes(&a_vals), 10, &out_bytes);
    try testing.expectEqual(@as(i32, 20), readElement(i32, &out_bytes, 0));
    try testing.expectEqual(@as(i32, 30), readElement(i32, &out_bytes, 1));
    try testing.expectEqual(@as(i32, 40), readElement(i32, &out_bytes, 2));
}

test "scalarBinaryOp f64: empty" {
    var out = [_]u8{};
    scalarBinaryOp(f64, .add, &.{}, 5.0, &out);
}

test "scalarBinaryOp i32 div: zero divisor" {
    const a_vals = [_]i32{ 6, 8 };
    var out_bytes: [2 * 4]u8 = undefined;
    try testing.expectError(error.DivisionByZero, scalarBinaryOp(i32, .div, std.mem.sliceAsBytes(&a_vals), 0, &out_bytes));
}

test "scalarBinaryOp u16 div: zero divisor" {
    const a_vals = [_]u16{6};
    var out_bytes: [2]u8 = undefined;
    try testing.expectError(error.DivisionByZero, scalarBinaryOp(u16, .div, std.mem.sliceAsBytes(&a_vals), 0, &out_bytes));
}

test "scalarBinaryOp i32 div: minInt / -1 in scalar tail" {
    const a_vals = [_]i32{std.math.minInt(i32)};
    var out_bytes: [4]u8 = undefined;
    try testing.expectError(error.FixnumOverflow, scalarBinaryOp(i32, .div, std.mem.sliceAsBytes(&a_vals), -1, &out_bytes));
}

test "scalarBinaryOp i32 div: minInt / -1 in vector path" {
    const n = 16;
    var a_vals: [n]i32 = undefined;
    for (0..n) |i| a_vals[i] = @intCast(i + 1);
    a_vals[2] = std.math.minInt(i32);
    var out_bytes: [n * 4]u8 = undefined;
    try testing.expectError(error.FixnumOverflow, scalarBinaryOp(i32, .div, std.mem.sliceAsBytes(&a_vals), -1, &out_bytes));
}

test "scalarBinaryOp i32 div: -1 divisor without minInt dividend is fine" {
    const a_vals = [_]i32{ 6, -8 };
    var out_bytes: [2 * 4]u8 = undefined;
    try scalarBinaryOp(i32, .div, std.mem.sliceAsBytes(&a_vals), -1, &out_bytes);
    try testing.expectEqual(@as(i32, -6), readElement(i32, &out_bytes, 0));
    try testing.expectEqual(@as(i32, 8), readElement(i32, &out_bytes, 1));
}

test "scalarBinaryOp f32 div: zero divisor follows IEEE" {
    const a_vals = [_]f32{6.0};
    var out_bytes: [4]u8 = undefined;
    try scalarBinaryOp(f32, .div, std.mem.sliceAsBytes(&a_vals), 0.0, &out_bytes);
    try testing.expect(std.math.isInf(readElement(f32, &out_bytes, 0)));
}

// ---------------------------------------------------------------------------
// Chain kernel tests
// ---------------------------------------------------------------------------

test "applyChainChunk f64: single op over a full chunk" {
    const chunk = chainChunkLen(f64);
    var vals: [chunk]f64 = undefined;
    for (0..chunk) |i| vals[i] = @floatFromInt(i + 1);
    const chain = [_]ChainOp{.{ .op = .mul, .scalar = 2.0 }};
    var out: [chunk]f64 = undefined;
    const produced = applyChainChunk(f64, std.mem.sliceAsBytes(&vals), 0, &chain, &out);
    try testing.expectEqual(chunk, produced);
    for (0..chunk) |i| {
        try testing.expectEqual(@as(f64, @floatFromInt((i + 1) * 2)), out[i]);
    }
}

test "applyChainChunk f64: chained ops stay left-to-right" {
    const vals = [_]f64{ 1.0, 2.0, 3.0 };
    const chain = [_]ChainOp{
        .{ .op = .mul, .scalar = 2.0 },
        .{ .op = .add, .scalar = 1.0 },
    };
    var results: [3]f64 = undefined;
    var out: [3]f64 = undefined;
    var start: usize = 0;
    while (start < vals.len) {
        const produced = applyChainChunk(f64, std.mem.sliceAsBytes(&vals), start, &chain, &out);
        try testing.expect(produced > 0);
        @memcpy(results[start..][0..produced], out[0..produced]);
        start += produced;
    }
    try testing.expectEqual(@as(f64, 3.0), results[0]);
    try testing.expectEqual(@as(f64, 5.0), results[1]);
    try testing.expectEqual(@as(f64, 7.0), results[2]);
}

test "applyChainChunk f64: sub and div broadcast to the right operand" {
    const vals = [_]f64{ 10.0, 20.0 };
    const chain = [_]ChainOp{
        .{ .op = .sub, .scalar = 2.0 },
        .{ .op = .div, .scalar = 4.0 },
    };
    var out: [2]f64 = undefined;
    _ = applyChainChunk(f64, std.mem.sliceAsBytes(&vals), 0, &chain, &out);
    try testing.expectEqual(@as(f64, 2.0), out[0]);
    try testing.expectEqual(@as(f64, 4.5), out[1]);
}

test "applyChainChunk f64: partial tail and exhaustion" {
    const chunk = chainChunkLen(f64);
    const n = chunk + 1;
    var vals: [n]f64 = undefined;
    for (0..n) |i| vals[i] = @floatFromInt(i);
    const chain = [_]ChainOp{.{ .op = .add, .scalar = 0.5 }};
    var out: [chunk]f64 = undefined;

    const first = applyChainChunk(f64, std.mem.sliceAsBytes(&vals), 0, &chain, &out);
    try testing.expectEqual(chunk, first);

    const tail = applyChainChunk(f64, std.mem.sliceAsBytes(&vals), first, &chain, &out);
    try testing.expectEqual(@as(usize, 1), tail);
    try testing.expectEqual(@as(f64, @floatFromInt(chunk)) + 0.5, out[0]);

    const done = applyChainChunk(f64, std.mem.sliceAsBytes(&vals), n, &chain, &out);
    try testing.expectEqual(@as(usize, 0), done);
}

test "applyChainChunk f32: computes in f32, matching the broadcast kernel" {
    const vals = [_]f32{1.1};
    const chain = [_]ChainOp{.{ .op = .mul, .scalar = 3.0 }};
    var out: [1]f64 = undefined;
    _ = applyChainChunk(f32, std.mem.sliceAsBytes(&vals), 0, &chain, &out);
    const expected: f32 = @as(f32, 1.1) * 3.0;
    try testing.expectEqual(@as(f64, @floatCast(expected)), out[0]);
}

test "applyChainChunk f32: full chunk agrees with scalarBinaryOp" {
    const chunk = chainChunkLen(f32);
    var vals: [chunk]f32 = undefined;
    for (0..chunk) |i| vals[i] = @as(f32, @floatFromInt(i)) + 0.25;
    const chain = [_]ChainOp{.{ .op = .mul, .scalar = 3.0 }};
    var out: [chunk]f64 = undefined;
    _ = applyChainChunk(f32, std.mem.sliceAsBytes(&vals), 0, &chain, &out);

    var broadcast_bytes: [chunk * 4]u8 = undefined;
    scalarBinaryOp(f32, .mul, std.mem.sliceAsBytes(&vals), 3.0, &broadcast_bytes);
    for (0..chunk) |i| {
        try testing.expectEqual(@as(f64, @floatCast(readElement(f32, &broadcast_bytes, i))), out[i]);
    }
}

// ---------------------------------------------------------------------------
// Existing binary operation tests
// ---------------------------------------------------------------------------

test "addPacked u16: large array exercises multi-chunk path" {
    const n = 64;
    var a_vals: [n]u16 = undefined;
    var b_vals: [n]u16 = undefined;
    for (0..n) |i| {
        a_vals[i] = @intCast(i);
        b_vals[i] = @intCast(n - i);
    }
    var out_bytes: [n * 2]u8 = undefined;
    addPacked(u16, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    for (0..n) |i| {
        try testing.expectEqual(@as(u16, n), readElement(u16, &out_bytes, i));
    }
}
