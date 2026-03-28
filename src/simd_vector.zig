const std = @import("std");

pub const SIMD_BYTES = 16;
pub const Op = enum { add, sub, mul, div };

/// Load 16 raw bytes into an aligned @Vector(N, T).
pub fn bytesToVector(comptime N: comptime_int, comptime T: type, bytes: *const [SIMD_BYTES]u8) @Vector(N, T) {
    var buf: [SIMD_BYTES]u8 align(@alignOf(@Vector(N, T))) = undefined;
    @memcpy(&buf, bytes);
    const aligned: *align(@alignOf(@Vector(N, T))) const [N]T = @ptrCast(&buf);
    return aligned.*;
}

/// Store a @Vector(N, T) as 16 raw bytes.
pub fn vectorToBytes(comptime N: comptime_int, comptime T: type, v: @Vector(N, T)) [SIMD_BYTES]u8 {
    const ptr: *const [SIMD_BYTES]u8 = @ptrCast(&v);
    return ptr.*;
}

/// Element-wise binary operation on two 128-bit SIMD vectors.
pub fn simdBinaryOp(comptime N: comptime_int, comptime T: type, comptime op: Op, a: *const [SIMD_BYTES]u8, b: *const [SIMD_BYTES]u8, out: *[SIMD_BYTES]u8) void {
    const va = bytesToVector(N, T, a);
    const vb = bytesToVector(N, T, b);
    const is_int = @typeInfo(T) == .int;
    const vr: @Vector(N, T) = switch (op) {
        .add => if (is_int) va +% vb else va + vb,
        .sub => if (is_int) va -% vb else va - vb,
        .mul => if (is_int) va *% vb else va * vb,
        .div => if (is_int) @divTrunc(va, vb) else va / vb,
    };
    out.* = vectorToBytes(N, T, vr);
}

/// Broadcast a single scalar to all N lanes.
pub fn simdSplat(comptime N: comptime_int, comptime T: type, value: T, out: *[SIMD_BYTES]u8) void {
    const v: @Vector(N, T) = @splat(value);
    out.* = vectorToBytes(N, T, v);
}

/// Extract a single lane value.
pub fn simdGetLane(comptime N: comptime_int, comptime T: type, bytes: *const [SIMD_BYTES]u8, lane: usize) T {
    const v = bytesToVector(N, T, bytes);
    return v[lane];
}

/// Return a new vector with one lane replaced.
pub fn simdSetLane(comptime N: comptime_int, comptime T: type, src: *const [SIMD_BYTES]u8, lane: usize, value: T, out: *[SIMD_BYTES]u8) void {
    var v = bytesToVector(N, T, src);
    v[lane] = value;
    out.* = vectorToBytes(N, T, v);
}

/// Runtime lane permutation: out[i] = src[indices[i]].
pub fn simdPermute(comptime N: comptime_int, comptime T: type, src: *const [SIMD_BYTES]u8, indices: [N]usize, out: *[SIMD_BYTES]u8) void {
    const v = bytesToVector(N, T, src);
    var result: [N]T = undefined;
    for (0..N) |i| {
        result[i] = v[indices[i]];
    }
    const rv: @Vector(N, T) = result;
    out.* = vectorToBytes(N, T, rv);
}

/// Per-lane select: non-zero mask lanes pick from a, zero lanes pick from b.
pub fn simdSelect(comptime N: comptime_int, comptime T: type, mask: *const [SIMD_BYTES]u8, a: *const [SIMD_BYTES]u8, b: *const [SIMD_BYTES]u8, out: *[SIMD_BYTES]u8) void {
    const vm = bytesToVector(N, T, mask);
    const va = bytesToVector(N, T, a);
    const vb = bytesToVector(N, T, b);
    const zero: @Vector(N, T) = @splat(zeroval(T));
    const pred: @Vector(N, bool) = vm != zero;
    const vr = @select(T, pred, va, vb);
    out.* = vectorToBytes(N, T, vr);
}

/// Bitmask blend: bit i=1 picks lane i from b, bit=0 keeps a.
pub fn simdBlend(comptime N: comptime_int, comptime T: type, a: *const [SIMD_BYTES]u8, b: *const [SIMD_BYTES]u8, bitmask: u16, out: *[SIMD_BYTES]u8) void {
    const va = bytesToVector(N, T, a);
    const vb = bytesToVector(N, T, b);
    var pred: @Vector(N, bool) = undefined;
    for (0..N) |i| {
        pred[i] = (bitmask >> @intCast(i)) & 1 == 1;
    }
    const vr = @select(T, pred, vb, va);
    out.* = vectorToBytes(N, T, vr);
}

fn zeroval(comptime T: type) T {
    return if (@typeInfo(T) == .float) @as(T, 0.0) else @as(T, 0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "simdBinaryOp f64 add" {
    const a_vals = [2]f64{ 1.5, 2.5 };
    const b_vals = [2]f64{ 10.0, 20.0 };
    const a: *const [16]u8 = @ptrCast(&a_vals);
    const b: *const [16]u8 = @ptrCast(&b_vals);
    var out: [16]u8 = undefined;
    simdBinaryOp(2, f64, .add, a, b, &out);
    const result: *const [2]f64 = @ptrCast(@alignCast(&out));
    try testing.expectEqual(@as(f64, 11.5), result[0]);
    try testing.expectEqual(@as(f64, 22.5), result[1]);
}

test "simdBinaryOp i32 mul wrapping" {
    const a_vals = [4]i32{ 2, 3, std.math.maxInt(i32), -1 };
    const b_vals = [4]i32{ 5, 6, 2, 7 };
    const a: *const [16]u8 = @ptrCast(&a_vals);
    const b: *const [16]u8 = @ptrCast(&b_vals);
    var out: [16]u8 = undefined;
    simdBinaryOp(4, i32, .mul, a, b, &out);
    const result: *const [4]i32 = @ptrCast(@alignCast(&out));
    try testing.expectEqual(@as(i32, 10), result[0]);
    try testing.expectEqual(@as(i32, 18), result[1]);
    try testing.expectEqual(@as(i32, -2), result[2]); // wrapping
    try testing.expectEqual(@as(i32, -7), result[3]);
}

test "simdSplat f32" {
    var out: [16]u8 = undefined;
    simdSplat(4, f32, 3.14, &out);
    const result: *const [4]f32 = @ptrCast(@alignCast(&out));
    for (0..4) |i| {
        try testing.expectEqual(@as(f32, 3.14), result[i]);
    }
}

test "simdGetLane and simdSetLane" {
    const vals = [4]i32{ 10, 20, 30, 40 };
    const bytes: *const [16]u8 = @ptrCast(&vals);
    try testing.expectEqual(@as(i32, 20), simdGetLane(4, i32, bytes, 1));

    var out: [16]u8 = undefined;
    simdSetLane(4, i32, bytes, 2, 99, &out);
    const result: *const [4]i32 = @ptrCast(@alignCast(&out));
    try testing.expectEqual(@as(i32, 10), result[0]);
    try testing.expectEqual(@as(i32, 20), result[1]);
    try testing.expectEqual(@as(i32, 99), result[2]);
    try testing.expectEqual(@as(i32, 40), result[3]);
}

test "simdPermute reverses lanes" {
    const vals = [4]f32{ 1.0, 2.0, 3.0, 4.0 };
    const bytes: *const [16]u8 = @ptrCast(&vals);
    var out: [16]u8 = undefined;
    simdPermute(4, f32, bytes, .{ 3, 2, 1, 0 }, &out);
    const result: *const [4]f32 = @ptrCast(@alignCast(&out));
    try testing.expectEqual(@as(f32, 4.0), result[0]);
    try testing.expectEqual(@as(f32, 3.0), result[1]);
    try testing.expectEqual(@as(f32, 2.0), result[2]);
    try testing.expectEqual(@as(f32, 1.0), result[3]);
}

test "simdSelect picks by non-zero mask" {
    const mask_vals = [4]i32{ 0, 1, 0, -1 };
    const a_vals = [4]i32{ 10, 20, 30, 40 };
    const b_vals = [4]i32{ 100, 200, 300, 400 };
    const mask: *const [16]u8 = @ptrCast(&mask_vals);
    const a: *const [16]u8 = @ptrCast(&a_vals);
    const b: *const [16]u8 = @ptrCast(&b_vals);
    var out: [16]u8 = undefined;
    simdSelect(4, i32, mask, a, b, &out);
    const result: *const [4]i32 = @ptrCast(@alignCast(&out));
    try testing.expectEqual(@as(i32, 100), result[0]); // mask=0 -> b
    try testing.expectEqual(@as(i32, 20), result[1]); // mask!=0 -> a
    try testing.expectEqual(@as(i32, 300), result[2]); // mask=0 -> b
    try testing.expectEqual(@as(i32, 40), result[3]); // mask!=0 -> a
}

test "simdBlend with bitmask" {
    const a_vals = [4]i32{ 10, 20, 30, 40 };
    const b_vals = [4]i32{ 100, 200, 300, 400 };
    const a: *const [16]u8 = @ptrCast(&a_vals);
    const b: *const [16]u8 = @ptrCast(&b_vals);
    var out: [16]u8 = undefined;
    simdBlend(4, i32, a, b, 0b0101, &out); // bits 0,2 set -> pick b for lanes 0,2
    const result: *const [4]i32 = @ptrCast(@alignCast(&out));
    try testing.expectEqual(@as(i32, 100), result[0]); // bit=1 -> b
    try testing.expectEqual(@as(i32, 20), result[1]); // bit=0 -> a
    try testing.expectEqual(@as(i32, 300), result[2]); // bit=1 -> b
    try testing.expectEqual(@as(i32, 40), result[3]); // bit=0 -> a
}

test "simdBinaryOp u8 add wrapping" {
    const a_vals = [16]u8{ 255, 1, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const b_vals = [16]u8{ 1, 254, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var out: [16]u8 = undefined;
    simdBinaryOp(16, u8, .add, &a_vals, &b_vals, &out);
    try testing.expectEqual(@as(u8, 0), out[0]); // 255+1 wraps
    try testing.expectEqual(@as(u8, 255), out[1]);
    try testing.expectEqual(@as(u8, 0), out[2]);
    try testing.expectEqual(@as(u8, 0), out[3]); // 128+128 wraps
}

test "simdBinaryOp f64 div" {
    const a_vals = [2]f64{ 10.0, 20.0 };
    const b_vals = [2]f64{ 4.0, 5.0 };
    const a: *const [16]u8 = @ptrCast(&a_vals);
    const b: *const [16]u8 = @ptrCast(&b_vals);
    var out: [16]u8 = undefined;
    simdBinaryOp(2, f64, .div, a, b, &out);
    const result: *const [2]f64 = @ptrCast(@alignCast(&out));
    try testing.expectEqual(@as(f64, 2.5), result[0]);
    try testing.expectEqual(@as(f64, 4.0), result[1]);
}
