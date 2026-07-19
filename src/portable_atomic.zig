const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

/// Drop-in replacement for `std.atomic.Value(T)` for counters wider than 32 bits (u64, i128).
/// wasm32 baseline has no atomic load/store/RMW for operand sizes above 32 bits without the
/// atomics feature, which the wasm build deliberately does not enable (single-worker,
/// cooperative scheduling has no concurrent caller to race against). Hosted targets keep the
/// real atomic ops, since they have genuine multi-worker concurrent callers.
///
/// Exposes the same method surface (`init`, `load`, `store`, `fetchAdd`, `fetchSub`,
/// `cmpxchgStrong`) as `std.atomic.Value(T)` so call sites are unchanged; only the field's
/// declared type and `.init(...)` call site switch over.
pub fn WideCounter(comptime T: type) type {
    return struct {
        inner: std.atomic.Value(T),

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .inner = std.atomic.Value(T).init(value) };
        }

        pub fn load(self: *const Self, comptime order: std.builtin.AtomicOrder) T {
            if (comptime is_freestanding) return self.inner.raw;
            return self.inner.load(order);
        }

        pub fn store(self: *Self, value: T, comptime order: std.builtin.AtomicOrder) void {
            if (comptime is_freestanding) {
                self.inner.raw = value;
                return;
            }
            self.inner.store(value, order);
        }

        pub fn fetchAdd(self: *Self, operand: T, comptime order: std.builtin.AtomicOrder) T {
            if (comptime is_freestanding) {
                const old = self.inner.raw;
                self.inner.raw = old +% operand;
                return old;
            }
            return self.inner.fetchAdd(operand, order);
        }

        pub fn fetchSub(self: *Self, operand: T, comptime order: std.builtin.AtomicOrder) T {
            if (comptime is_freestanding) {
                const old = self.inner.raw;
                self.inner.raw = old -% operand;
                return old;
            }
            return self.inner.fetchSub(operand, order);
        }

        pub fn cmpxchgStrong(self: *Self, expected: T, new: T, comptime success_order: std.builtin.AtomicOrder, comptime fail_order: std.builtin.AtomicOrder) ?T {
            if (comptime is_freestanding) {
                if (self.inner.raw == expected) {
                    self.inner.raw = new;
                    return null;
                }
                return self.inner.raw;
            }
            return self.inner.cmpxchgStrong(expected, new, success_order, fail_order);
        }
    };
}

test "WideCounter load/store/fetchAdd/fetchSub round-trip" {
    var c = WideCounter(u64).init(5);
    try std.testing.expectEqual(@as(u64, 5), c.load(.acquire));
    c.store(10, .release);
    try std.testing.expectEqual(@as(u64, 10), c.load(.acquire));
    try std.testing.expectEqual(@as(u64, 10), c.fetchAdd(1, .acq_rel));
    try std.testing.expectEqual(@as(u64, 11), c.load(.acquire));
    try std.testing.expectEqual(@as(u64, 11), c.fetchSub(1, .acq_rel));
    try std.testing.expectEqual(@as(u64, 10), c.load(.acquire));
}

test "WideCounter cmpxchgStrong success and failure" {
    var c = WideCounter(i128).init(100);
    try std.testing.expectEqual(@as(?i128, null), c.cmpxchgStrong(100, 200, .acq_rel, .acquire));
    try std.testing.expectEqual(@as(i128, 200), c.load(.acquire));
    try std.testing.expectEqual(@as(?i128, 200), c.cmpxchgStrong(100, 300, .acq_rel, .acquire));
    try std.testing.expectEqual(@as(i128, 200), c.load(.acquire));
}
