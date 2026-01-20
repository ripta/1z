const std = @import("std");
const Allocator = std.mem.Allocator;

const Stack = @import("stack.zig").Stack;
const Dictionary = @import("dictionary.zig").Dictionary;
const Instruction = @import("value.zig").Instruction;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const primitives = @import("primitives.zig");
const parser = @import("parser.zig");
const BenchmarkStats = @import("benchmark.zig").BenchmarkStats;

/// Embedded prelude source code
const prelude_source = @embedFile("prelude.1z");

pub const ExecutionError = error{
    UnknownWord,
    StackUnderflow,
    OutOfMemory,
};

/// CallFrame represents a single frame in the call stack.
pub const CallFrame = struct {
    word_name: []const u8,
    line: usize,
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
    call_stack: std.ArrayListUnmanaged(CallFrame),
    error_details: std.ArrayListUnmanaged(ErrorDetail),
    /// Tokenizer for parse-time word access (set during parsing, null otherwise)
    parse_tokenizer: ?*Tokenizer = null,
    /// Optional benchmark stats (null when benchmarking is disabled)
    benchmark: ?*BenchmarkStats = null,

    /// Initialize a new interpreter context with an empty stack and primitives.
    /// Note: This does NOT load the prelude. Call loadPrelude() separately.
    pub fn init(allocator: Allocator) Context {
        var ctx = Context{
            .stack = Stack.init(allocator),
            .dictionary = Dictionary.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .call_stack = .{},
            .error_details = .{},
            .parse_tokenizer = null,
            .benchmark = null,
        };

        primitives.registerPrimitives(&ctx.dictionary, ctx.arena.allocator()) catch |err| {
            std.debug.panic("Failed to register primitives: {any}", .{err});
        };

        return ctx;
    }

    /// Initialize context and load prelude. Convenience method for non-benchmark use.
    pub fn initWithPrelude(allocator: Allocator) Context {
        var ctx = init(allocator);
        ctx.loadPrelude() catch |err| {
            std.debug.panic("Failed to load prelude: {any}", .{err});
        };
        return ctx;
    }

    /// Load the embedded prelude source.
    pub fn loadPrelude(self: *Context) !void {
        var tokenizer = Tokenizer.init(prelude_source);
        const instrs = try parser.parseTopLevel(self.arena.allocator(), &tokenizer, self);
        try self.executeQuotation(instrs);
    }

    /// Free all resources used by the context.
    pub fn deinit(self: *Context) void {
        self.call_stack.deinit(self.allocator);
        self.error_details.deinit(self.allocator);
        self.arena.deinit();
        self.dictionary.deinit();
        self.stack.deinit();
    }

    /// Allocator for quotations and other parsed data.
    pub fn quotationAllocator(self: *Context) Allocator {
        return self.arena.allocator();
    }

    /// Clear all error details and call stack.
    pub fn clearExecutionDetails(self: *Context) void {
        self.error_details.clearRetainingCapacity();
        self.call_stack.clearRetainingCapacity();
    }

    /// Push a call frame onto the call stack.
    fn pushCallFrame(self: *Context, word_name: []const u8, line: usize) void {
        self.call_stack.append(self.allocator, .{
            .word_name = word_name,
            .line = line,
        }) catch {};
    }

    /// Pop a call frame from the call stack.
    fn popCallFrame(self: *Context) void {
        if (self.call_stack.items.len > 0) {
            _ = self.call_stack.pop();
        }
    }

    /// Capture the current call stack to error_details.
    /// Only captures if error_details is empty (first error).
    fn captureCallStackOnError(self: *Context, err: anyerror) void {
        // Only capture on first error
        if (self.error_details.items.len > 0) return;

        // Iterate call_stack in reverse (innermost first for display)
        var i = self.call_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.call_stack.items[i];
            self.error_details.append(self.allocator, .{
                .error_type = @errorName(err),
                .message = frame.word_name,
                .line = frame.line,
                .word_name = frame.word_name,
            }) catch {};
        }
    }

    /// Execute a quotation's instructions.
    pub fn executeQuotation(self: *Context, instructions: []const Instruction) anyerror!void {
        for (instructions) |instr| {
            switch (instr.op) {
                .push_literal => |val| {
                    try self.stack.push(val);
                    // Benchmark: count push_literal and update stack depth
                    if (self.benchmark) |b| {
                        b.recordPushLiteral();
                        b.updatePeakStackDepth(self.stack.depth());
                    }
                },
                .call_word => |name| {
                    // Benchmark: count call_word
                    if (self.benchmark) |b| {
                        b.recordCallWord();
                    }

                    if (self.dictionary.get(name)) |word| {
                        // Push call frame before execution
                        self.pushCallFrame(name, instr.line);
                        const result = switch (word.action) {
                            .native => |func| func(self),
                            .compound => |instrs| self.executeQuotation(instrs),
                        };

                        if (result) |_| {
                            // Success - just pop frame
                            self.popCallFrame();
                            // Benchmark: update stack depth after word execution
                            if (self.benchmark) |b| {
                                b.updatePeakStackDepth(self.stack.depth());
                            }
                        } else |err| {
                            // Error - capture call stack (before popping), then pop
                            self.captureCallStackOnError(err);
                            self.popCallFrame();
                            return err;
                        }
                    } else {
                        // Unknown word - push frame, capture, pop, return error
                        self.pushCallFrame(name, instr.line);
                        self.captureCallStackOnError(ExecutionError.UnknownWord);
                        self.popCallFrame();
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

test "call stack captured on error, calling an unknown word" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Create a word that calls an unknown word
    const alloc = ctx.quotationAllocator();
    const inner_instrs = try alloc.alloc(Instruction, 1);
    inner_instrs[0] = .{ .op = .{ .call_word = "nonexistent" }, .line = 10 };

    try ctx.dictionary.put("inner", .{
        .name = "inner",
        .action = .{ .compound = inner_instrs },
    });

    const outer_instrs = try alloc.alloc(Instruction, 1);
    outer_instrs[0] = .{ .op = .{ .call_word = "inner" }, .line = 20 };

    try ctx.dictionary.put("outer", .{
        .name = "outer",
        .action = .{ .compound = outer_instrs },
    });

    // Execute outer -> inner -> nonexistent (error)
    const top_instrs = try alloc.alloc(Instruction, 1);
    top_instrs[0] = .{ .op = .{ .call_word = "outer" }, .line = 30 };

    const result = ctx.executeQuotation(top_instrs);
    try std.testing.expectError(ExecutionError.UnknownWord, result);

    // Check error_details captured the call stack (innermost first)
    try std.testing.expectEqual(@as(usize, 3), ctx.error_details.items.len);

    // First entry: nonexistent (innermost, where error occurred)
    try std.testing.expectEqualStrings("nonexistent", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqual(@as(usize, 10), ctx.error_details.items[0].line);

    // Second entry: inner
    try std.testing.expectEqualStrings("inner", ctx.error_details.items[1].word_name.?);
    try std.testing.expectEqual(@as(usize, 20), ctx.error_details.items[1].line);

    // Third entry: outer (outermost)
    try std.testing.expectEqualStrings("outer", ctx.error_details.items[2].word_name.?);
    try std.testing.expectEqual(@as(usize, 30), ctx.error_details.items[2].line);
}

test "call stack empty after successful execution" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Execute some successful operations
    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 1 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 2 };
    instrs[2] = .{ .op = .{ .call_word = "+" }, .line = 3 };

    try ctx.executeQuotation(instrs);

    // Call stack should be empty after successful execution
    try std.testing.expectEqual(@as(usize, 0), ctx.call_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.error_details.items.len);
}

test "clearExecutionDetails clears both call stack and error details" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Manually add some data to test clearing
    ctx.call_stack.append(ctx.allocator, .{ .word_name = "test", .line = 1 }) catch {};
    ctx.error_details.append(ctx.allocator, .{
        .error_type = "TestError",
        .message = "test",
        .line = 1,
        .word_name = "test",
    }) catch {};

    try std.testing.expectEqual(@as(usize, 1), ctx.call_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);

    ctx.clearExecutionDetails();

    try std.testing.expectEqual(@as(usize, 0), ctx.call_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.error_details.items.len);
}
