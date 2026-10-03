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
    /// Every slot from the snapshot's base up to the attempt's depth is released first, so the
    /// attempt must have left each of those slots owned. The attempt cannot reach below the base,
    /// which is the depth the snapshot was taken over.
    ///
    /// An empty snapshot holds nothing to put back. Its attempt may have consumed values under
    /// `entry_sp` that no one recorded, so what it left there stays, and only what it pushed above
    /// the entry is released.
    pub fn restore(self: *StackSnapshot, stack: *Stack, entry_sp: usize) void {
        const held = self.values();
        if (held.len == 0) {
            releaseAbove(stack, @min(entry_sp, stack.items.items.len));
            self.free(stack);
            return;
        }

        // Compiled code never writes below its base. The clamp keeps a breach from slicing
        // backwards in a release build.
        const base = entry_sp - held.len;
        std.debug.assert(stack.items.items.len >= base);
        releaseAbove(stack, @min(base, stack.items.items.len));

        // The attempt may have left a depth below its entry. The slots up to the entry depth were
        // live when it began, so the capacity already covers them.
        stack.items.items.len = entry_sp;
        @memcpy(stack.items.items[base..entry_sp], held);
        self.free(stack);
    }

    /// Release every slot from `floor` up to the stack's depth, and make `floor` the depth.
    pub fn releaseAbove(stack: *Stack, floor: usize) void {
        const len = stack.items.items.len;
        std.debug.assert(len >= floor);

        for (stack.items.items[floor..len]) |v| container_backing.releaseValue(v);
        stack.items.items.len = floor;
    }

    fn free(self: *StackSnapshot, stack: *Stack) void {
        if (self.heap_values) |h| stack.allocator.free(h);
        self.heap_values = null;
        self.count = 0;
    }
};

/// Whole-stack snapshots for the catch sites running on one context, as segments of one buffer.
///
/// Catch sites nest strictly, so the segments form a LIFO. A site pushes its segment before the
/// protected code runs, and pops it by discarding or restoring when that code returns. The buffer
/// keeps its capacity across calls, so a warm context takes a snapshot without allocating.
///
/// The reservation happens before anything is retained. A site whose reservation fails must not
/// start the code it would protect.
pub const CatchSnapshots = struct {
    values: std.ArrayListUnmanaged(Value) = .{},

    /// Where a segment sits in the buffer.
    pub const Segment = struct {
        mark: usize,
        len: usize,
    };

    /// Hold every slot of `stack` as a new topmost segment.
    pub fn push(self: *CatchSnapshots, allocator: std.mem.Allocator, stack: *Stack) error{OutOfMemory}!Segment {
        const live = stack.items.items;
        try self.values.ensureUnusedCapacity(allocator, live.len);

        const seg: Segment = .{ .mark = self.values.items.len, .len = live.len };
        self.values.appendSliceAssumeCapacity(live);
        for (live) |v| container_backing.retainValue(v);
        return seg;
    }

    /// Drop the segment once the protected code is kept.
    pub fn discard(self: *CatchSnapshots, seg: Segment) void {
        for (self.held(seg)) |v| container_backing.releaseValue(v);
        self.values.items.len = seg.mark;
    }

    /// Replace the whole stack with the segment, handing the segment's references to it.
    ///
    /// Every slot the protected code left is released, so each must be owned. A compiled raise
    /// settles its stack before returning, which is what makes that hold in every tier.
    pub fn restore(self: *CatchSnapshots, seg: Segment, stack: *Stack) void {
        const values = self.held(seg);
        StackSnapshot.releaseAbove(stack, 0);

        // The segment was the whole stack when it was taken. A stack never gives back capacity,
        // so it still covers the segment.
        stack.items.items.len = values.len;
        @memcpy(stack.items.items, values);
        self.values.items.len = seg.mark;
    }

    /// Whether `stack` still holds exactly the segment, slot for slot.
    ///
    /// A handler that returns normally may still have consumed a value below its arguments and
    /// pushed one back, so depth alone cannot tell. Slots compare by identity, not structure: a
    /// handler that put back an equal but different value has still changed the stack.
    pub fn unchanged(self: *CatchSnapshots, seg: Segment, stack: *const Stack) bool {
        const values = self.held(seg);
        const live = stack.items.items;
        if (live.len != values.len) return false;

        for (live, values) |a, b| {
            if (!sameValue(a, b)) return false;
        }
        return true;
    }

    /// The values of `seg`, which must be the topmost segment.
    ///
    /// A segment above it would mean a catch site returned without popping its own, or two
    /// executions interleaved on one context. Either breaks the nesting every site relies on.
    fn held(self: *CatchSnapshots, seg: Segment) []Value {
        std.debug.assert(seg.mark + seg.len == self.values.items.len);
        return self.values.items[seg.mark..][0..seg.len];
    }

    pub fn deinit(self: *CatchSnapshots, allocator: std.mem.Allocator) void {
        for (self.values.items) |v| container_backing.releaseValue(v);
        self.values.deinit(allocator);
    }
};

/// Same tag and same payload, with heap payloads compared by address. A float compares by its
/// bits, so a NaN is the same value as itself.
fn sameValue(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    if (a == .float) return @as(u64, @bitCast(a.float)) == @as(u64, @bitCast(b.float));
    return std.meta.eql(a, b);
}

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

test "restore releases what the attempt left and hands back the snapshot's references" {
    const Vector = @import("value.zig").Vector;

    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    defer stack.clear();

    // A push retains, so each creator's own reference is dropped once the stack holds one.
    const operand = try Vector.create(std.testing.allocator);
    try stack.push(.{ .vector = operand });
    operand.header.release();
    try stack.push(.{ .fixnum = 2 });

    var snapshot: StackSnapshot = .{};
    try std.testing.expect(snapshot.take(&stack, 2));
    try std.testing.expectEqual(@as(u32, 2), operand.header.refcountValue());

    // The attempt left the operand unconsumed and pushed a value of its own.
    const pushed = try Vector.create(std.testing.allocator);
    try stack.push(.{ .vector = pushed });
    pushed.header.release();

    snapshot.restore(&stack, 2);
    try std.testing.expectEqual(@as(usize, 2), stack.depth());
    try std.testing.expectEqual(@as(u32, 1), operand.header.refcountValue());
    try std.testing.expectEqual(@as(i64, 2), stack.items.items[1].fixnum);
}

test "an empty snapshot releases only what the attempt pushed above the entry" {
    const Vector = @import("value.zig").Vector;

    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .fixnum = 1 });

    var snapshot: StackSnapshot = .{};
    try std.testing.expect(snapshot.take(&stack, 0));

    const pushed = try Vector.create(std.testing.allocator);
    try stack.push(.{ .vector = pushed });
    pushed.header.release();

    snapshot.restore(&stack, 1);
    try std.testing.expectEqual(@as(usize, 1), stack.depth());
    try std.testing.expectEqual(@as(i64, 1), stack.items.items[0].fixnum);
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

test "a catch segment restores the whole stack the protected code consumed" {
    const Vector = @import("value.zig").Vector;

    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    defer stack.clear();

    var snapshots: CatchSnapshots = .{};
    defer snapshots.deinit(std.testing.allocator);

    const below = try Vector.create(std.testing.allocator);
    try stack.push(.{ .vector = below });
    below.header.release();
    try stack.push(.{ .fixnum = 2 });

    const seg = try snapshots.push(std.testing.allocator, &stack);
    try std.testing.expectEqual(@as(u32, 2), below.header.refcountValue());

    // The protected code consumed both values and left partial state of its own.
    StackSnapshot.releaseAbove(&stack, 0);
    const partial = try Vector.create(std.testing.allocator);
    try stack.push(.{ .vector = partial });
    partial.header.release();

    snapshots.restore(seg, &stack);
    try std.testing.expectEqual(@as(usize, 2), stack.depth());
    try std.testing.expectEqual(@as(u32, 1), below.header.refcountValue());
    try std.testing.expectEqual(@as(i64, 2), stack.items.items[1].fixnum);
    try std.testing.expectEqual(@as(usize, 0), snapshots.values.items.len);
}

test "nested catch segments pop in order" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    var snapshots: CatchSnapshots = .{};
    defer snapshots.deinit(std.testing.allocator);

    try stack.push(.{ .fixnum = 1 });
    const outer = try snapshots.push(std.testing.allocator, &stack);
    try stack.push(.{ .fixnum = 2 });
    const inner = try snapshots.push(std.testing.allocator, &stack);
    try std.testing.expectEqual(@as(usize, 3), snapshots.values.items.len);

    snapshots.discard(inner);
    snapshots.restore(outer, &stack);
    try std.testing.expectEqual(@as(usize, 1), stack.depth());
    try std.testing.expectEqual(@as(i64, 1), stack.items.items[0].fixnum);
    try std.testing.expectEqual(@as(usize, 0), snapshots.values.items.len);
}

test "a catch segment that cannot be reserved retains nothing" {
    const Vector = @import("value.zig").Vector;

    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    defer stack.clear();

    const operand = try Vector.create(std.testing.allocator);
    try stack.push(.{ .vector = operand });
    operand.header.release();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var snapshots: CatchSnapshots = .{};
    defer snapshots.deinit(failing.allocator());

    try std.testing.expectError(error.OutOfMemory, snapshots.push(failing.allocator(), &stack));
    try std.testing.expectEqual(@as(u32, 1), operand.header.refcountValue());
    try std.testing.expectEqual(@as(usize, 0), snapshots.values.items.len);
}

test "a stack the handler left alone reads as unchanged, NaN included" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    var snapshots: CatchSnapshots = .{};
    defer snapshots.deinit(std.testing.allocator);

    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .float = std.math.nan(f64) });
    const seg = try snapshots.push(std.testing.allocator, &stack);

    // A handler that took an argument and consumed it.
    try stack.push(.{ .fixnum = 30 });
    _ = try stack.pop();

    try std.testing.expect(snapshots.unchanged(seg, &stack));
    snapshots.discard(seg);
}

test "a stack with an extra value reads as changed" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    var snapshots: CatchSnapshots = .{};
    defer snapshots.deinit(std.testing.allocator);

    try stack.push(.{ .fixnum = 1 });
    const seg = try snapshots.push(std.testing.allocator, &stack);
    try stack.push(.{ .fixnum = 777 });

    try std.testing.expect(!snapshots.unchanged(seg, &stack));
    snapshots.restore(seg, &stack);
    try std.testing.expectEqual(@as(usize, 1), stack.depth());
}

test "a value swapped below the handler's arguments reads as changed" {
    const Vector = @import("value.zig").Vector;

    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    defer stack.clear();

    var snapshots: CatchSnapshots = .{};
    defer snapshots.deinit(std.testing.allocator);

    const original = try Vector.create(std.testing.allocator);
    try stack.push(.{ .vector = original });
    original.header.release();
    const seg = try snapshots.push(std.testing.allocator, &stack);

    // An equal but different value in the same slot.
    StackSnapshot.releaseAbove(&stack, 0);
    const replacement = try Vector.create(std.testing.allocator);
    try stack.push(.{ .vector = replacement });
    replacement.header.release();

    try std.testing.expect(!snapshots.unchanged(seg, &stack));
    snapshots.restore(seg, &stack);
    try std.testing.expectEqual(original, stack.items.items[0].vector);
}
