const std = @import("std");
const Allocator = std.mem.Allocator;

const Stack = @import("stack.zig").Stack;
const Dictionary = @import("dictionary.zig").Dictionary;
const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Quotation = value_mod.Quotation;
const Value = value_mod.Value;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const primitives = @import("primitives.zig");
const parser = @import("parser.zig");
const BenchmarkStats = @import("benchmark.zig").BenchmarkStats;
const StackEffect = @import("stack_effect.zig").StackEffect;
const StackEffectParam = @import("stack_effect.zig").StackEffectParam;

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

/// ParameterFrame holds parameter bindings for dynamic scoping.
/// Each frame is a mapping from parameter name to its bound value.
pub const ParameterFrame = std.StringHashMapUnmanaged(Value);

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
    /// Parameter environment frames for dynamic scoping
    parameter_env: std.ArrayListUnmanaged(ParameterFrame),
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
            .parameter_env = .{},
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
    /// Processes definitions incrementally so that parse-time words defined
    /// earlier in the prelude are available when parsing later definitions.
    pub fn loadPrelude(self: *Context) !void {
        const StatementProcessor = @import("statement.zig").StatementProcessor;
        var processor: StatementProcessor = .{};

        // Split prelude into lines and process incrementally
        var lines = std.mem.splitScalar(u8, prelude_source, '\n');
        while (lines.next()) |line| {
            const result = processor.feedLine(self.arena.allocator(), line, self);
            switch (result) {
                .needs_more_input => continue,
                .complete => |instrs| {
                    if (instrs.len > 0) {
                        try self.executeQuotation(.{ .instructions = instrs });
                    }
                    processor.reset();
                },
                .parse_error => |err| return err,
            }
        }

        // Flush any remaining buffered content
        switch (processor.flush(self.arena.allocator(), self)) {
            .complete => |instrs| {
                if (instrs.len > 0) {
                    try self.executeQuotation(.{ .instructions = instrs });
                }
            },
            .parse_error => |err| return err,
            .needs_more_input => {},
        }
    }

    /// Free all resources used by the context.
    pub fn deinit(self: *Context) void {
        for (self.parameter_env.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.parameter_env.deinit(self.allocator);
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

    /// Get the current binding for a parameter by name.
    /// Searches frames from top (innermost) to bottom (outermost).
    /// Returns null if the parameter is not bound in any frame.
    pub fn getParameterBinding(self: *Context, name: []const u8) ?Value {
        // Search from top (innermost) to bottom (outermost)
        var i = self.parameter_env.items.len;
        while (i > 0) {
            i -= 1;
            if (self.parameter_env.items[i].get(name)) |value| {
                return value;
            }
        }
        return null;
    }

    /// Push a new empty parameter frame onto the environment stack.
    pub fn pushParameterFrame(self: *Context) !void {
        try self.parameter_env.append(self.allocator, ParameterFrame{});
    }

    /// Pop the top parameter frame from the environment stack.
    pub fn popParameterFrame(self: *Context) void {
        if (self.parameter_env.items.len > 0) {
            const last_idx = self.parameter_env.items.len - 1;
            self.parameter_env.items[last_idx].deinit(self.allocator);
            self.parameter_env.items.len -= 1;
        }
    }

    /// Bind a parameter name to a value in the top frame.
    /// Assumes there is at least one frame on the stack.
    pub fn setParameterInTopFrame(self: *Context, name: []const u8, value: Value) !void {
        if (self.parameter_env.items.len == 0) {
            return error.OutOfMemory; // Should never happen if pushParameterFrame was called
        }
        const top_index = self.parameter_env.items.len - 1;
        try self.parameter_env.items[top_index].put(self.allocator, name, value);
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

    /// Infer a quotation's stack delta by statically analyzing its instructions.
    /// Returns null if the delta cannot be determined (e.g., unknown words, control flow).
    fn inferQuotationDelta(self: *Context, quot: Quotation) ?i64 {
        var delta: i64 = 0;

        for (quot.instructions) |instr| {
            switch (instr.op) {
                .push_literal => |val| {
                    // Pushing a value increases stack by 1
                    delta += 1;

                    // If it's a quotation, we can't know its effect without calling it
                    // But we're just counting the push, not its execution
                    _ = val;
                },
                .call_word => |name| {
                    if (self.dictionary.get(name)) |word| {
                        if (word.stack_effect) |word_effect| {
                            // Count only concrete parameters (skip row variables)
                            var concrete_inputs: i64 = 0;
                            var concrete_outputs: i64 = 0;

                            for (word_effect.inputs) |param| {
                                if (!isRowVariable(param.name)) {
                                    concrete_inputs += 1;
                                }
                            }
                            for (word_effect.outputs) |param| {
                                if (!isRowVariable(param.name)) {
                                    concrete_outputs += 1;
                                }
                            }

                            delta = delta - concrete_inputs + concrete_outputs;
                        } else {
                            // Word has no declared effect, can't infer
                            return null;
                        }
                    } else {
                        // Unknown word
                        return null;
                    }
                },
            }
        }

        return delta;
    }

    /// Validate a quotation against an expected effect by inferring its delta.
    /// Returns an error if the quotation doesn't match the expected effect.
    fn validateQuotationEffect(self: *Context, quot: Quotation, expected_effect: *const StackEffect, param_name: []const u8) !void {
        // If the effect has unbalanced row variables (row vars that appear only in
        // inputs or only in outputs), we can't determine a fixed expected delta.
        // Skip validation in this case since the effect is polymorphic.
        if (hasUnbalancedRowVariables(expected_effect)) {
            return;
        }

        // Compute expected delta from effect
        var expected_concrete_inputs: i64 = 0;
        var expected_concrete_outputs: i64 = 0;

        for (expected_effect.inputs) |param| {
            if (!isRowVariable(param.name)) {
                expected_concrete_inputs += 1;
            }
        }
        for (expected_effect.outputs) |param| {
            if (!isRowVariable(param.name)) {
                expected_concrete_outputs += 1;
            }
        }

        const expected_delta = expected_concrete_outputs - expected_concrete_inputs;

        // Infer actual delta from quotation instructions
        const inferred_delta = self.inferQuotationDelta(quot);

        if (inferred_delta) |actual_delta| {
            if (actual_delta != expected_delta) {
                // Capture error details
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "parameter '{s}' has effect ({d} -- {d}) but quotation produces delta {d}", .{
                    param_name,
                    expected_concrete_inputs,
                    expected_concrete_outputs,
                    actual_delta,
                }) catch "stack effect mismatch";

                const msg_copy = self.arena.allocator().dupe(u8, msg) catch return primitives.InterpreterError.StackEffectMismatch;

                self.error_details.append(self.allocator, .{
                    .error_type = "StackEffectMismatch",
                    .message = msg_copy,
                    .line = 0,
                    .word_name = param_name,
                }) catch {};

                return primitives.InterpreterError.StackEffectMismatch;
            }
        }
        // If we can't infer the delta, don't error - allow dynamic validation
    }

    /// Check if an effect has row variables that appear only in inputs or only in outputs.
    /// Such effects are polymorphic and their delta cannot be determined statically.
    fn hasUnbalancedRowVariables(effect: *const StackEffect) bool {
        // Collect row variables from inputs
        var input_row_vars: [8][]const u8 = undefined;
        var input_count: usize = 0;
        for (effect.inputs) |param| {
            if (isRowVariable(param.name) and input_count < 8) {
                input_row_vars[input_count] = param.name;
                input_count += 1;
            }
        }

        // Collect row variables from outputs
        var output_row_vars: [8][]const u8 = undefined;
        var output_count: usize = 0;
        for (effect.outputs) |param| {
            if (isRowVariable(param.name) and output_count < 8) {
                output_row_vars[output_count] = param.name;
                output_count += 1;
            }
        }

        // Check if any input row var is missing from outputs
        for (input_row_vars[0..input_count]) |input_var| {
            var found = false;
            for (output_row_vars[0..output_count]) |output_var| {
                if (std.mem.eql(u8, input_var, output_var)) {
                    found = true;
                    break;
                }
            }
            if (!found) return true;
        }

        // Check if any output row var is missing from inputs
        for (output_row_vars[0..output_count]) |output_var| {
            var found = false;
            for (input_row_vars[0..input_count]) |input_var| {
                if (std.mem.eql(u8, output_var, input_var)) {
                    found = true;
                    break;
                }
            }
            if (!found) return true;
        }

        return false;
    }

    /// Check if a name is a row variable (starts with "..")
    fn isRowVariable(name: []const u8) bool {
        return name.len >= 2 and name[0] == '.' and name[1] == '.';
    }

    /// Check if a row variable name is defined in a word's effect (inputs or outputs).
    fn isRowVariableDefined(row_var: []const u8, word_effect: *const StackEffect) bool {
        for (word_effect.inputs) |param| {
            if (std.mem.eql(u8, param.name, row_var)) return true;
        }
        for (word_effect.outputs) |param| {
            if (std.mem.eql(u8, param.name, row_var)) return true;
        }
        return false;
    }

    /// Validate that all row variables in a quotation effect are defined in the word's effect.
    fn validateRowVariables(self: *Context, quot_effect: *const StackEffect, word_effect: *const StackEffect, param_name: []const u8) !void {
        // Check all row variables in quotation effect inputs
        for (quot_effect.inputs) |param| {
            if (isRowVariable(param.name) and !isRowVariableDefined(param.name, word_effect)) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "parameter '{s}' uses undefined row variable '{s}'", .{
                    param_name,
                    param.name,
                }) catch "undefined row variable";

                const msg_copy = self.arena.allocator().dupe(u8, msg) catch return primitives.InterpreterError.StackEffectMismatch;

                self.error_details.append(self.allocator, .{
                    .error_type = "StackEffectMismatch",
                    .message = msg_copy,
                    .line = 0,
                    .word_name = param_name,
                }) catch {};

                return primitives.InterpreterError.StackEffectMismatch;
            }
        }

        // Check all row variables in quotation effect outputs
        for (quot_effect.outputs) |param| {
            if (isRowVariable(param.name) and !isRowVariableDefined(param.name, word_effect)) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "parameter '{s}' uses undefined row variable '{s}'", .{
                    param_name,
                    param.name,
                }) catch "undefined row variable";

                const msg_copy = self.arena.allocator().dupe(u8, msg) catch return primitives.InterpreterError.StackEffectMismatch;

                self.error_details.append(self.allocator, .{
                    .error_type = "StackEffectMismatch",
                    .message = msg_copy,
                    .line = 0,
                    .word_name = param_name,
                }) catch {};

                return primitives.InterpreterError.StackEffectMismatch;
            }
        }
    }

    /// Validate quotation parameters against their declared effects.
    /// Uses static analysis to infer the quotation's stack delta and compares
    /// against the expected effect from the parameter annotation.
    /// Also validates that row variables in quotation effects are defined in the word's effect.
    fn validateParameterEffects(self: *Context, effect: *const StackEffect) !void {
        // First, validate that all row variables in quotation effects are defined
        for (effect.inputs) |param| {
            if (param.quotation_effect) |quot_effect| {
                try self.validateRowVariables(quot_effect, effect, param.name);
            }
        }

        // Count concrete parameters (skip row variables starting with "..")
        var concrete_params: usize = 0;
        for (effect.inputs) |param| {
            if (!isRowVariable(param.name)) {
                concrete_params += 1;
            }
        }

        if (concrete_params == 0 or self.stack.depth() < concrete_params) return;

        // Validate quotation effects on stack
        // The top concrete_params items on the stack are the parameters
        // Stack layout: [...other values] [param_0] [param_1] ... [param_n-1]
        // param_n-1 is on top (offset 0 from top), param_0 is at offset n-1 from top
        var concrete_index: usize = 0;
        for (effect.inputs) |param| {
            // Skip row variables
            if (isRowVariable(param.name)) {
                continue;
            }

            // If this parameter has a quotation effect annotation
            if (param.quotation_effect) |expected_effect| {
                // Calculate offset from top of stack: rightmost concrete param is on top
                const offset_from_top = concrete_params - 1 - concrete_index;

                // Get the stack value at this offset and validate if it's a quotation
                const stack_index = self.stack.depth() - 1 - offset_from_top;
                if (self.stack.items.items[stack_index] == .quotation) {
                    const quot = self.stack.items.items[stack_index].quotation;
                    try self.validateQuotationEffect(quot, expected_effect, param.name);
                }
            }

            concrete_index += 1;
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

    /// Capture stack effect mismatch details for error reporting.
    fn captureStackEffectMismatch(
        self: *Context,
        word_name: []const u8,
        effect: StackEffect,
        actual_depth: usize,
    ) void {
        // Only capture on first error
        if (self.error_details.items.len > 0) return;

        // Format the declared effect and explanation
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        // Write declared effect
        writer.writeAll("declared ") catch {};
        effect.write(writer) catch {};

        // Write explanation
        writer.print(", requires {d} output(s) but stack has {d}", .{
            effect.outputs.len,
            actual_depth,
        }) catch {};

        // Store the message (copy to arena so it outlives the buffer)
        const msg_copy = self.arena.allocator().dupe(u8, fbs.getWritten()) catch return;

        const line = if (self.call_stack.items.len > 0)
            self.call_stack.items[self.call_stack.items.len - 1].line
        else
            0;

        self.error_details.append(self.allocator, .{
            .error_type = "StackEffectMismatch",
            .message = msg_copy,
            .line = line,
            .word_name = word_name,
        }) catch {};
    }

    /// Execute a quotation's instructions with optional effect validation.
    pub fn executeQuotation(self: *Context, quotation: Quotation) anyerror!void {
        // Record depth before execution for validation
        const depth_before = self.stack.depth();

        // Execute instructions
        try self.executeInstructions(quotation.instructions);

        // Validate quotation's stack effect if declared
        if (quotation.effect) |effect| {
            const depth_after = self.stack.depth();
            const expected_delta: i64 = @as(i64, @intCast(effect.outputs.len)) - @as(i64, @intCast(effect.inputs.len));
            const actual_delta: i64 = @as(i64, @intCast(depth_after)) - @as(i64, @intCast(depth_before));

            if (expected_delta != actual_delta) {
                self.captureQuotationEffectMismatch(effect.*, expected_delta, actual_delta);
                return primitives.InterpreterError.StackEffectMismatch;
            }
        }
    }

    /// Execute raw instructions (internal helper, no effect validation).
    fn executeInstructions(self: *Context, instructions: []const Instruction) anyerror!void {
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

                        // Validate quotation parameters against declared effects
                        if (word.stack_effect) |effect| {
                            self.validateParameterEffects(&effect) catch |err| {
                                self.captureCallStackOnError(err);
                                self.popCallFrame();
                                return err;
                            };
                        }

                        const result = switch (word.action) {
                            .native => |func| func(self),
                            .compound => |instrs| self.executeInstructions(instrs),
                        };

                        if (result) |_| {
                            // Validate stack effect if declared
                            if (word.stack_effect) |effect| {
                                const depth_after = self.stack.depth();

                                // Validate: word must produce at least declared outputs
                                // We allow consuming more than declared (for variable consumption)
                                // and producing more than declared (for combinators calling quotations)
                                // But the word must leave at least outputs_len items
                                if (depth_after < effect.outputs.len) {
                                    self.captureStackEffectMismatch(name, effect, depth_after);
                                    self.popCallFrame();
                                    return primitives.InterpreterError.StackEffectMismatch;
                                }
                            }

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

    /// Capture quotation effect mismatch details for error reporting.
    fn captureQuotationEffectMismatch(
        self: *Context,
        effect: StackEffect,
        expected_delta: i64,
        actual_delta: i64,
    ) void {
        // Only capture on first error
        if (self.error_details.items.len > 0) return;

        // Format the declared effect and explanation
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        // Write declared effect
        writer.writeAll("quotation declared ") catch {};
        effect.write(writer) catch {};

        // Write explanation
        writer.print(", expected delta {d} but got {d}", .{
            expected_delta,
            actual_delta,
        }) catch {};

        // Store the message (copy to arena so it outlives the buffer)
        const msg_copy = self.arena.allocator().dupe(u8, fbs.getWritten()) catch return;

        const line = if (self.call_stack.items.len > 0)
            self.call_stack.items[self.call_stack.items.len - 1].line
        else
            0;

        self.error_details.append(self.allocator, .{
            .error_type = "StackEffectMismatch",
            .message = msg_copy,
            .line = line,
            .word_name = "<quotation>",
        }) catch {};
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

    const result = ctx.executeQuotation(.{ .instructions = top_instrs });
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

    try ctx.executeQuotation(.{ .instructions = instrs });

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

test "stack effect validation passes for correct effect" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // dup has effect ( a -- a a ), which is correct
    // Push 1, call dup, should have 2 items
    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = 5 } }, .line = 1 };
    instrs[1] = .{ .op = .{ .call_word = "dup" }, .line = 2 };

    try ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
}

test "stack effect validation fails when word produces fewer outputs than declared" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();

    // Create a word that claims to produce 2 outputs but actually produces 0
    // Effect: ( -- a b ) but body is empty
    const empty_instrs = try alloc.alloc(Instruction, 0);
    const outputs = try alloc.alloc(StackEffectParam, 2);
    outputs[0] = .{ .name = "a" };
    outputs[1] = .{ .name = "b" };

    try ctx.dictionary.put("bad-word", .{
        .name = "bad-word",
        .stack_effect = .{
            .inputs = &[_]StackEffectParam{},
            .outputs = outputs,
        },
        .action = .{ .compound = empty_instrs },
    });

    // Call bad-word - should fail because it claims 2 outputs but produces 0
    const call_instrs = try alloc.alloc(Instruction, 1);
    call_instrs[0] = .{ .op = .{ .call_word = "bad-word" }, .line = 1 };

    const result = ctx.executeQuotation(.{ .instructions = call_instrs });
    try std.testing.expectError(primitives.InterpreterError.StackEffectMismatch, result);
}

test "stack effect validation passes for combinator calling quotation" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // if ( ? true-quot false-quot -- ) calls a quotation
    // The quotation can produce outputs, which is allowed
    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 4);
    instrs[0] = .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 },
    } } } }, .line = 2 };
    instrs[2] = .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &[_]Instruction{} } } }, .line = 3 };
    instrs[3] = .{ .op = .{ .call_word = "if" }, .line = 4 };

    try ctx.executeQuotation(.{ .instructions = instrs });
    // if consumed 3, quotation produced 1, so stack has 1
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
}

test "quotation with correct declared effect passes" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Create a quotation with effect ( n -- n ) that actually preserves stack depth
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    };

    // [ ( n -- n ) dup drop ] - takes 1, produces 1 (correct)
    const alloc = ctx.quotationAllocator();
    const dup_drop_instrs = try alloc.alloc(Instruction, 2);
    dup_drop_instrs[0] = .{ .op = .{ .call_word = "dup" }, .line = 1 };
    dup_drop_instrs[1] = .{ .op = .{ .call_word = "drop" }, .line = 1 };

    const quot = Quotation{
        .instructions = dup_drop_instrs,
        .effect = &effect,
    };

    // Push initial value and execute
    try ctx.stack.push(.{ .integer = 42 });
    try ctx.executeQuotation(quot);

    // Should have 1 value on stack
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
}

test "quotation with incorrect declared effect fails" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Create a quotation with effect ( n -- n ) but actually does dup (adds 1)
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    };

    // [ ( n -- n ) dup ] - claims (1 in, 1 out) but actually (1 in, 2 out)
    const alloc = ctx.quotationAllocator();
    const dup_instrs = try alloc.alloc(Instruction, 1);
    dup_instrs[0] = .{ .op = .{ .call_word = "dup" }, .line = 1 };

    const quot = Quotation{
        .instructions = dup_instrs,
        .effect = &effect,
    };

    // Push initial value and execute
    try ctx.stack.push(.{ .integer = 42 });
    const result = ctx.executeQuotation(quot);

    // Should fail with StackEffectMismatch
    try std.testing.expectError(primitives.InterpreterError.StackEffectMismatch, result);
}
