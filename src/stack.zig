const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const container_backing = @import("container_backing.zig");
const ShadowTable = @import("analysis_shadow.zig").ShadowTable;

pub const StackError = error{
    StackUnderflow,
};

/// Stack is the primary mechanism for passing data between words, and is LIFO.
///
/// Lifecycle policy: a stack slot is an owning reference to its value's
/// backing. `push` retains; `pop` transfers slot ownership to the
/// caller's C local; `clear` releases every residual slot; `peek` only
/// borrows. See spec/language/15-value-lifecycle.md.
pub const Stack = struct {
    items: std.ArrayListUnmanaged(Value),

    /// The copies an analysis load owner keeps of its ancestors' containers. Null for a stack
    /// outside analysis, so a pop pays one test. It is the choke point of the shadow redirect: a
    /// container with a copy is swapped for the copy at `pop`, `peek`, and `peekN`.
    shadows: ?*ShadowTable = null,

    allocator: Allocator,

    /// Initialize a new empty stack.
    pub fn init(allocator: Allocator) Stack {
        return Stack{
            .items = .{},
            .allocator = allocator,
        };
    }

    /// Free the stack's slice storage. Callers must call `clear` first
    /// if any residual slots still hold owning references; otherwise
    /// those references leak.
    pub fn deinit(self: *Stack) void {
        self.items.deinit(self.allocator);
    }

    /// Push a value onto the top of the stack. The slot becomes a new
    /// owning reference; the helper invokes `retainValue` so the
    /// backing's refcount tracks the new owner. If `append` fails the
    /// retain is undone so the contract stays atomic.
    pub fn push(self: *Stack, value: Value) !void {
        container_backing.retainValue(value);
        errdefer container_backing.releaseValue(value);
        try self.items.append(self.allocator, value);
    }

    /// Push a value whose ownership the caller already holds, without
    /// retaining. Use this only when transferring an owning reference
    /// the caller already accounts for, e.g., moving a value out of a
    /// temp buffer into a stack slot. Misuse leaks or under-counts.
    pub fn pushMoved(self: *Stack, value: Value) !void {
        try self.items.append(self.allocator, value);
    }

    /// Pop and return the top value from the stack. Pure transfer:
    /// the slot loses ownership and the caller's C local inherits it.
    /// No atomic refcount change. The caller MUST either re-store the
    /// value (via push, container insert, etc.) or release it via
    /// `container_backing.releaseValue`.
    ///
    /// A stack under analysis swaps a container for its copy here, and the caller owns the copy.
    pub fn pop(self: *Stack) StackError!Value {
        const v = self.items.pop() orelse return error.StackUnderflow;
        if (self.shadows) |table| {
            @branchHint(.unlikely);
            return table.redirectPopped(v);
        }
        return v;
    }

    /// Pop for a caller that accepts only kinds a write can never mutate in place, such as a
    /// fixnum, a boolean, or a quotation. Such a value is never redirected, so this skips the test.
    pub fn popPlain(self: *Stack) StackError!Value {
        return self.items.pop() orelse error.StackUnderflow;
    }

    /// Pop and release the top value in one step, for the common
    /// discard pattern (`_ = try stack.pop()` and `nativeDrop`). The value is
    /// dropped, so it is never redirected.
    pub fn popAndRelease(self: *Stack) StackError!void {
        const v = self.items.pop() orelse return error.StackUnderflow;
        container_backing.releaseValue(v);
    }

    /// Return the top value without removing it. Borrow only; the
    /// caller does not become an owner and must not release.
    /// Returns StackUnderflow if the stack is empty.
    pub fn peek(self: *const Stack) StackError!Value {
        if (self.items.items.len == 0) {
            return error.StackUnderflow;
        }
        return self.redirected(self.items.items[self.items.items.len - 1]);
    }

    /// Return the value at depth n from top (0 = top, 1 = second from top, etc.)
    /// Borrow only; see `peek`.
    /// Returns StackUnderflow if n >= stack depth.
    pub fn peekN(self: *const Stack, n: usize) StackError!Value {
        if (n >= self.items.items.len) {
            return error.StackUnderflow;
        }
        return self.redirected(self.items.items[self.items.items.len - 1 - n]);
    }

    /// `peek` for a caller that reads only the value's type, which a copy shares with its original.
    pub fn peekPlain(self: *const Stack) StackError!Value {
        if (self.items.items.len == 0) {
            return error.StackUnderflow;
        }
        return self.items.items[self.items.items.len - 1];
    }

    /// `peekN` for a caller that reads only the value's type. See `peekPlain`.
    pub fn peekPlainN(self: *const Stack, n: usize) StackError!Value {
        if (n >= self.items.items.len) {
            return error.StackUnderflow;
        }
        return self.items.items[self.items.items.len - 1 - n];
    }

    /// A borrowed value, with a container swapped for its copy under analysis.
    inline fn redirected(self: *const Stack, v: Value) Value {
        if (self.shadows) |table| {
            @branchHint(.unlikely);
            return table.lookup(v) orelse v;
        }
        return v;
    }

    /// Return the number of items on the stack.
    pub fn depth(self: *const Stack) usize {
        return self.items.items.len;
    }

    /// Release a contiguous slice of slots in the [start, end) range
    /// without shrinking the array. Callers pair this with
    /// `shrinkRetainingCapacity` (or equivalent) to drop slots that
    /// no longer correspond to owning references.
    pub fn releaseRange(self: *Stack, start: usize, end: usize) void {
        std.debug.assert(start <= end);
        std.debug.assert(end <= self.items.items.len);
        var i: usize = start;
        while (i < end) : (i += 1) {
            container_backing.releaseValue(self.items.items[i]);
        }
    }

    /// Remove all items from the stack, releasing each slot's owning
    /// reference. Required before `deinit` so residual values do not
    /// leak.
    pub fn clear(self: *Stack) void {
        for (self.items.items) |v| {
            container_backing.releaseValue(v);
        }
        self.items.clearRetainingCapacity();
    }

    /// Print the stack contents for debugging/REPL display.
    /// Format: [bottom ... ... ... top]
    pub fn dump(self: *const Stack, writer: anytype) !void {
        try writer.writeAll("[ ");
        for (self.items.items) |item| {
            try item.write(writer);
            try writer.writeAll(" ");
        }
        try writer.writeAll("]");
    }
};

// =============================================================================
// Tests
// =============================================================================

test "init and deinit" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    try std.testing.expectEqual(@as(usize, 0), stack.depth());
}

test "push and pop" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .fixnum = 42 });
    try std.testing.expectEqual(@as(usize, 1), stack.depth());

    const val = try stack.pop();
    try std.testing.expectEqual(@as(i64, 42), val.fixnum);
    try std.testing.expectEqual(@as(usize, 0), stack.depth());
}

test "push multiple and pop in LIFO order" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .fixnum = 2 });
    try stack.push(.{ .fixnum = 3 });
    try std.testing.expectEqual(@as(usize, 3), stack.depth());

    try std.testing.expectEqual(@as(i64, 3), (try stack.pop()).fixnum);
    try std.testing.expectEqual(@as(i64, 2), (try stack.pop()).fixnum);
    try std.testing.expectEqual(@as(i64, 1), (try stack.pop()).fixnum);
}

test "pop empty stack returns StackUnderflow" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expectError(error.StackUnderflow, stack.pop());
}

test "peek returns top without removing" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .fixnum = 42 });
    try stack.push(.{ .fixnum = 99 });

    const val = try stack.peek();
    try std.testing.expectEqual(@as(i64, 99), val.fixnum);
    try std.testing.expectEqual(@as(usize, 2), stack.depth());
}

test "peek empty stack returns StackUnderflow" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expectError(error.StackUnderflow, stack.peek());
}

test "peekN returns value at depth n" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .fixnum = 2 });
    try stack.push(.{ .fixnum = 3 });

    // n=0 is top (3), n=1 is second (2), n=2 is bottom (1)
    try std.testing.expectEqual(@as(i64, 3), (try stack.peekN(0)).fixnum);
    try std.testing.expectEqual(@as(i64, 2), (try stack.peekN(1)).fixnum);
    try std.testing.expectEqual(@as(i64, 1), (try stack.peekN(2)).fixnum);

    // Doesn't remove values
    try std.testing.expectEqual(@as(usize, 3), stack.depth());
}

test "peekN returns StackUnderflow for n >= depth" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .fixnum = 2 });

    try std.testing.expectError(error.StackUnderflow, stack.peekN(2));
    try std.testing.expectError(error.StackUnderflow, stack.peekN(10));
}

test "peekN on empty stack returns StackUnderflow" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expectError(error.StackUnderflow, stack.peekN(0));
}

test "dump empty stack" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try stack.dump(fbs.writer());

    try std.testing.expectEqualStrings("[ ]", fbs.getWritten());
}

test "dump stack with values" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .fixnum = 2 });
    try stack.push(.{ .fixnum = 3 });

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try stack.dump(fbs.writer());

    try std.testing.expectEqualStrings("[ 1 2 3 ]", fbs.getWritten());
}
