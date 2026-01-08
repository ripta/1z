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

/// ErrorDetail captures information about an error for debugging purposes.
pub const ErrorDetail = struct {
    error_type: []const u8,
    message: []const u8,
    line: usize,
    word_name: ?[]const u8,
};

/// The Context holds all interpreter state.
pub const Context = struct {
    stack: Stack,
    dictionary: Dictionary,
    arena: std.heap.ArenaAllocator,
    allocator: Allocator,
    error_details: std.ArrayListUnmanaged(ErrorDetail),

    /// Initialize a new interpreter context with an empty stack and primitives.
    pub fn init(allocator: Allocator) Context {
        var ctx = Context{
            .stack = Stack.init(allocator),
            .dictionary = Dictionary.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .error_details = .{},
        };

        primitives.registerPrimitives(&ctx.dictionary, ctx.arena.allocator()) catch |err| {
            std.debug.panic("Failed to register primitives: {any}", .{err});
        };

        return ctx;
    }

    /// Free all resources used by the context.
    pub fn deinit(self: *Context) void {
        self.error_details.deinit(self.allocator);
        self.arena.deinit();
        self.dictionary.deinit();
        self.stack.deinit();
    }

    /// Allocator for quotations and other parsed data.
    pub fn quotationAllocator(self: *Context) Allocator {
        return self.arena.allocator();
    }

    /// Clear all error details.
    pub fn clearErrorDetails(self: *Context) void {
        self.error_details.clearRetainingCapacity();
    }

    /// Push an error detail onto the error stack.
    pub fn pushErrorDetail(self: *Context, detail: ErrorDetail) void {
        self.error_details.append(self.allocator, detail) catch {};
    }

    /// Execute a quotation's instructions.
    pub fn executeQuotation(self: *Context, instructions: []const Instruction) anyerror!void {
        for (instructions) |instr| {
            switch (instr.op) {
                .push_literal => |val| try self.stack.push(val),
                .call_word => |name| {
                    if (self.dictionary.get(name)) |word| {
                        switch (word.action) {
                            .native => |func| func(self) catch |err| {
                                self.pushErrorDetail(.{
                                    .error_type = @errorName(err),
                                    .message = name,
                                    .line = instr.line,
                                    .word_name = name,
                                });
                                return err;
                            },
                            .compound => |instrs| self.executeQuotation(instrs) catch |err| {
                                self.pushErrorDetail(.{
                                    .error_type = @errorName(err),
                                    .message = name,
                                    .line = instr.line,
                                    .word_name = name,
                                });
                                return err;
                            },
                        }
                    } else {
                        self.pushErrorDetail(.{
                            .error_type = "UnknownWord",
                            .message = name,
                            .line = instr.line,
                            .word_name = name,
                        });
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

test "quotation allocator frees on deinit" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "+" }, .line = 0 };

    try ctx.dictionary.put("test-word", .{
        .name = "test-word",
        .action = .{ .compound = instrs },
    });
}
