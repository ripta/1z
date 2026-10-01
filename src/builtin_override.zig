const std = @import("std");
const builtin = @import("builtin");

/// The numeric operators whose builtin operand pairs compiled code computes inline.
pub const Op = enum(u3) {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    lt,
    gt,
};

/// An inlined operand pair, ordered so the index reads as `(a is float) * 2 + (b is float)`.
pub const Pair = enum(u2) {
    fixnum_fixnum,
    fixnum_float,
    float_fixnum,
    float_float,

    pub fn of(a_is_float: bool, b_is_float: bool) Pair {
        return @enumFromInt(@as(u2, @intFromBool(a_is_float)) * 2 + @intFromBool(b_is_float));
    }
};

/// The first `abs` bit. `abs` on a fixnum is this bit and `abs` on a float the one after it.
pub const abs_base: u6 = 32;

/// One bit per operator and inlined operand pair, set when a method arm replaces that pair's
/// builtin dispatch entry.
///
/// Compiled code tests a site's bit before computing inline, and takes the native call when it is
/// set, so an arm registered after a word compiled still runs. The mask is process-global rather
/// than per `Context`: a registration lands on one context, while a task on another sees the arm
/// through its ancestor walk and runs compiled code against its own.
///
/// Nothing clears a bit. A stale bit sends its sites to the native, which still dispatches to the
/// right answer, so it costs speed and never correctness.
var mask: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn binaryBit(op: Op, pair: Pair) u6 {
    return @as(u6, @intFromEnum(op)) * 4 + @intFromEnum(pair);
}

pub fn absBit(is_float: bool) u6 {
    return abs_base + @intFromBool(is_float);
}

pub fn set(bits: u64) void {
    if (bits == 0) return;

    // wasm32 has no 64-bit atomics, and a single-threaded build has no racing access.
    if (builtin.single_threaded) {
        mask.raw |= bits;
    } else {
        _ = mask.fetchOr(bits, .release);
    }
}

pub fn load() u64 {
    if (builtin.single_threaded) return mask.raw;
    return mask.load(.acquire);
}

pub fn isSet(bit: u6) bool {
    return load() & (@as(u64, 1) << bit) != 0;
}

/// The address JIT code loads the mask from on every guarded execution.
pub fn maskAddress() usize {
    return @intFromPtr(&mask.raw);
}

/// Clear the mask. Unit tests share one process, so a test that registers an arm on one of these
/// operators must clear what it set or every later compiled test takes the native call.
pub fn resetForTest() void {
    if (!builtin.is_test) @compileError("resetForTest is test-only");
    mask.raw = 0;
}

test "Pair.of orders the float flags as a two-bit index" {
    try std.testing.expectEqual(Pair.fixnum_fixnum, Pair.of(false, false));
    try std.testing.expectEqual(Pair.fixnum_float, Pair.of(false, true));
    try std.testing.expectEqual(Pair.float_fixnum, Pair.of(true, false));
    try std.testing.expectEqual(Pair.float_float, Pair.of(true, true));
}

test "binary and abs bits do not overlap" {
    try std.testing.expectEqual(@as(u6, 0), binaryBit(.add, .fixnum_fixnum));
    try std.testing.expectEqual(@as(u6, 31), binaryBit(.gt, .float_float));
    try std.testing.expectEqual(@as(u6, 32), absBit(false));
    try std.testing.expectEqual(@as(u6, 33), absBit(true));
}
