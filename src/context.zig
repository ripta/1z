const std = @import("std");
const Allocator = std.mem.Allocator;
const Stack = @import("stack.zig").Stack;

/// The Context holds all interpreter state.
pub const Context = struct {
    stack: Stack,
    allocator: Allocator,

    /// Initialize a new interpreter context with an empty stack.
    pub fn init(allocator: Allocator) Context {
        return Context{
            .stack = Stack.init(allocator),
            .allocator = allocator,
        };
    }

    /// Free all resources used by the context.
    pub fn deinit(self: *Context) void {
        self.stack.deinit();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "init and deinit" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}

test "stack operations through context" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const Value = @import("value.zig").Value;
    try ctx.stack.push(Value{ .integer = 42 });
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());

    const val = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 42), val.integer);
}
