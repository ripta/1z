//! A copy of the top of a value stack, held so a failed attempt can be undone.

const std = @import("std");
const Value = @import("value.zig").Value;
const Stack = @import("stack.zig").Stack;
const container_backing = @import("container_backing.zig");

/// The top slots of a value stack, each held with a reference of its own so it can be put back.
///
/// An attempt that runs on the stack may consume, overwrite, or release the values it started
/// from, so a depth alone cannot undo it. The snapshot keeps the values alive across the attempt.
/// Restoring hands the snapshot's references to the stack; releasing drops them once the attempt
/// is kept.
pub const StackSnapshot = struct {
    inline_values: [inline_capacity]Value = undefined,
    heap_values: ?[]Value = null,
    count: usize = 0,

    const inline_capacity = 8;

    fn values(self: *StackSnapshot) []Value {
        return if (self.heap_values) |h| h else self.inline_values[0..self.count];
    }

    /// Hold the top `wanted` slots of `stack`, or all of it when it is shallower. False when a
    /// heap buffer cannot be had, and then nothing is held.
    pub fn take(self: *StackSnapshot, stack: *Stack, wanted: usize) bool {
        const len = stack.items.items.len;
        const n = @min(wanted, len);
        if (n > inline_capacity) {
            self.heap_values = stack.allocator.alloc(Value, n) catch return false;
        }

        self.count = n;
        const held = self.values();
        @memcpy(held, stack.items.items[len - n .. len]);
        for (held) |v| container_backing.retainValue(v);
        return true;
    }

    /// Drop the held references once the attempt is kept.
    pub fn release(self: *StackSnapshot, stack: *Stack) void {
        for (self.values()) |v| container_backing.releaseValue(v);
        self.free(stack);
    }

    /// Put the held values back as the slots just under `entry_sp`, and make `entry_sp` the depth.
    ///
    /// The slots are overwritten without being released. The caller settles whatever they held.
    pub fn restore(self: *StackSnapshot, stack: *Stack, entry_sp: usize) void {
        const held = self.values();
        const base = entry_sp - held.len;

        // The attempt may have left a depth below its entry. The slots up to the entry depth were
        // live when it began, so the capacity already covers them.
        stack.items.items.len = entry_sp;
        @memcpy(stack.items.items[base..entry_sp], held);
        self.free(stack);
    }

    fn free(self: *StackSnapshot, stack: *Stack) void {
        if (self.heap_values) |h| stack.allocator.free(h);
        self.heap_values = null;
        self.count = 0;
    }
};

test "restore puts back values the attempt overwrote and dropped" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .fixnum = 2 });

    var snapshot: StackSnapshot = .{};
    try std.testing.expect(snapshot.take(&stack, 2));

    stack.items.items[0] = .{ .fixnum = 99 };
    stack.items.items.len = 1;

    snapshot.restore(&stack, 2);
    try std.testing.expectEqual(@as(usize, 2), stack.depth());
    try std.testing.expectEqual(@as(i64, 1), stack.items.items[0].fixnum);
    try std.testing.expectEqual(@as(i64, 2), stack.items.items[1].fixnum);
}

test "a snapshot wider than the inline buffer uses the heap and frees it" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    for (0..12) |i| try stack.push(.{ .fixnum = @intCast(i) });

    var snapshot: StackSnapshot = .{};
    try std.testing.expect(snapshot.take(&stack, 12));
    try std.testing.expect(snapshot.heap_values != null);
    snapshot.release(&stack);
    try std.testing.expectEqual(@as(?[]Value, null), snapshot.heap_values);
}
