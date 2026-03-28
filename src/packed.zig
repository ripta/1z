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
