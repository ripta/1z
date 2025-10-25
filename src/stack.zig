const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

pub const StackError = error{
    StackUnderflow,
};

/// Stack is the primary mechanism for passing data between words, and is LIFO.
pub const Stack = struct {
    items: std.ArrayListUnmanaged(Value),
    allocator: Allocator,

    /// Initialize a new empty stack.
    pub fn init(allocator: Allocator) Stack {
        return Stack{
            .items = .{},
            .allocator = allocator,
        };
    }

    /// Free all memory used by the stack.
    pub fn deinit(self: *Stack) void {
        self.items.deinit(self.allocator);
    }

    /// Push a value onto the top of the stack.
    pub fn push(self: *Stack, value: Value) !void {
        try self.items.append(self.allocator, value);
    }

    /// Pop and return the top value from the stack.
    /// Returns StackUnderflow if the stack is empty.
    pub fn pop(self: *Stack) StackError!Value {
        return self.items.pop() orelse error.StackUnderflow;
    }

    /// Return the top value without removing it.
    /// Returns StackUnderflow if the stack is empty.
    pub fn peek(self: *const Stack) StackError!Value {
        if (self.items.items.len == 0) {
            return error.StackUnderflow;
        }
        return self.items.items[self.items.items.len - 1];
    }

    /// Return the number of items on the stack.
    pub fn depth(self: *const Stack) usize {
        return self.items.items.len;
    }

    /// Print the stack contents for debugging/REPL display.
    /// Format: [bottom ... ... ... top]
    pub fn dump(self: *const Stack, writer: anytype) !void {
        try writer.writeAll("[ ");
        for (self.items.items) |item| {
            try writer.print("{f} ", .{item});
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

    try stack.push(.{ .integer = 42 });
    try std.testing.expectEqual(@as(usize, 1), stack.depth());

    const val = try stack.pop();
    try std.testing.expectEqual(@as(i64, 42), val.integer);
    try std.testing.expectEqual(@as(usize, 0), stack.depth());
}

test "push multiple and pop in LIFO order" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .integer = 1 });
    try stack.push(.{ .integer = 2 });
    try stack.push(.{ .integer = 3 });
    try std.testing.expectEqual(@as(usize, 3), stack.depth());

    try std.testing.expectEqual(@as(i64, 3), (try stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 2), (try stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 1), (try stack.pop()).integer);
}

test "pop empty stack returns StackUnderflow" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expectError(error.StackUnderflow, stack.pop());
}

test "peek returns top without removing" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(.{ .integer = 42 });
    try stack.push(.{ .integer = 99 });

    const val = try stack.peek();
    try std.testing.expectEqual(@as(i64, 99), val.integer);
    try std.testing.expectEqual(@as(usize, 2), stack.depth());
}

test "peek empty stack returns StackUnderflow" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expectError(error.StackUnderflow, stack.peek());
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

    try stack.push(.{ .integer = 1 });
    try stack.push(.{ .integer = 2 });
    try stack.push(.{ .integer = 3 });

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try stack.dump(fbs.writer());

    try std.testing.expectEqualStrings("[ 1 2 3 ]", fbs.getWritten());
}
