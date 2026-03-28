const std = @import("std");

pub const Op = enum { add, sub, mul, div };

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
pub fn divPacked(comptime T: type, a: []const u8, b: []const u8, out: []u8) void {
    binaryOp(T, .div, a, b, out);
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
pub fn scalarBinaryOp(comptime T: type, comptime op: Op, a: []const u8, scalar: T, out: []u8) void {
    const elem_size = @sizeOf(T);
    const n = a.len / elem_size;
    const chunk = std.simd.suggestVectorLength(T) orelse 4;
    const is_int = @typeInfo(T) == .int;
    const chunk_bytes = chunk * elem_size;

    var i: usize = 0;
    while (i + chunk <= n) : (i += chunk) {
        const byte_off = i * elem_size;
        var a_buf: [chunk_bytes]u8 align(@alignOf(@Vector(chunk, T))) = undefined;
        @memcpy(&a_buf, a[byte_off..][0..chunk_bytes]);

        const a_aligned: *align(@alignOf(@Vector(chunk, T))) const [chunk]T = @ptrCast(&a_buf);
        const va: @Vector(chunk, T) = a_aligned.*;
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

fn binaryOp(comptime T: type, comptime op: Op, a: []const u8, b: []const u8, out: []u8) void {
    const elem_size = @sizeOf(T);
    const n = a.len / elem_size;
    const chunk = std.simd.suggestVectorLength(T) orelse 4;
    const is_int = @typeInfo(T) == .int;

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
    divPacked(f64, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    try testing.expectEqual(@as(f64, 5.0), readElement(f64, &out_bytes, 0));
    try testing.expectEqual(@as(f64, 4.0), readElement(f64, &out_bytes, 1));
    try testing.expectEqual(@as(f64, 5.0), readElement(f64, &out_bytes, 2));
}

test "divPacked i32: truncating" {
    const a_vals = [_]i32{ 7, -7, 10 };
    const b_vals = [_]i32{ 2, 2, 3 };
    var out_bytes: [3 * 4]u8 = undefined;
    divPacked(i32, std.mem.sliceAsBytes(&a_vals), std.mem.sliceAsBytes(&b_vals), &out_bytes);
    try testing.expectEqual(@as(i32, 3), readElement(i32, &out_bytes, 0));
    try testing.expectEqual(@as(i32, -3), readElement(i32, &out_bytes, 1));
    try testing.expectEqual(@as(i32, 3), readElement(i32, &out_bytes, 2));
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
