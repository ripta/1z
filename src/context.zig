const std = @import("std");
const Allocator = std.mem.Allocator;

const Stack = @import("stack.zig").Stack;
const Dictionary = @import("dictionary.zig").Dictionary;
const Instruction = @import("value.zig").Instruction;
const primitives = @import("primitives.zig");

pub const ExecutionError = error{
    UnknownWord,
    StackUnderflow,
    OutOfMemory,
};

/// The Context holds all interpreter state.
pub const Context = struct {
    stack: Stack,
    dictionary: Dictionary,
    allocator: Allocator,

    /// Initialize a new interpreter context with an empty stack and primitives.
    pub fn init(allocator: Allocator) Context {
        var ctx = Context{
            .stack = Stack.init(allocator),
            .dictionary = Dictionary.init(allocator),
            .allocator = allocator,
        };

        primitives.registerPrimitives(&ctx.dictionary) catch |err| {
            std.debug.panic("Failed to register primitives: {any}", .{err});
        };

        return ctx;
    }

    /// Free all resources used by the context.
    pub fn deinit(self: *Context) void {
        self.dictionary.deinit();
        self.stack.deinit();
    }

    /// Execute a quotation's instructions.
    pub fn executeQuotation(self: *Context, instructions: []const Instruction) anyerror!void {
        for (instructions) |instr| {
            switch (instr) {
                .push_literal => |val| try self.stack.push(val),
                .call_word => |name| {
                    if (self.dictionary.get(name)) |word| {
                        switch (word.action) {
                            .native => |func| try func(self),
                            .compound => |instrs| try self.executeQuotation(instrs),
                        }
                    } else {
                        return ExecutionError.UnknownWord;
                    }
                },
            }
        }
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
