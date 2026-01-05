const std = @import("std");
const Allocator = std.mem.Allocator;

const Tokenizer = @import("tokenizer.zig").Tokenizer;
const parseInteger = @import("tokenizer.zig").parseInteger;
const parseString = @import("tokenizer.zig").parseString;
const Value = @import("value.zig").Value;
const Instruction = @import("value.zig").Instruction;
const StackEffect = @import("stack_effect.zig").StackEffect;
const StackEffectParam = @import("stack_effect.zig").StackEffectParam;

/// All the different errors that can occur during parsing.
pub const ParseError = error{
    UnmatchedOpenBracket,
    UnmatchedCloseBracket,
    UnmatchedOpenBrace,
    UnmatchedCloseBrace,
    UnmatchedOpenParen,
    UnmatchedCloseParen,
    OutOfMemory,
};

/// Returns true if the parse error indicates incomplete input.
pub fn isIncompleteError(err: anyerror) bool {
    return err == error.UnmatchedOpenBracket or err == error.UnmatchedOpenBrace;
}

/// Parse a top-level sequence of instructions. This is the entry point for
/// parsing, and handles continuation lines (multiline statements).
pub fn parseTopLevel(allocator: Allocator, tokenizer: *Tokenizer) ParseError![]const Instruction {
    var instructions: std.ArrayListUnmanaged(Instruction) = .{};
    errdefer instructions.deinit(allocator);

    while (tokenizer.next()) |token| {
        if (std.mem.eql(u8, token, "[")) {
            const quotation = try parseQuotation(allocator, tokenizer);
            instructions.append(allocator, .{ .push_literal = .{ .quotation = quotation } }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "]")) {
            return ParseError.UnmatchedCloseBracket;
        } else if (std.mem.eql(u8, token, "{")) {
            const arr = try parseArray(allocator, tokenizer);
            instructions.append(allocator, .{ .push_literal = .{ .array = arr } }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "}")) {
            return ParseError.UnmatchedCloseBrace;
        } else if (std.mem.eql(u8, token, "(")) {
            const effect = try parseStackEffect(allocator, tokenizer);
            instructions.append(allocator, .{ .push_literal = .{ .stack_effect = effect } }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, ")")) {
            return ParseError.UnmatchedCloseParen;
        } else if (parseInteger(token)) |n| {
            instructions.append(allocator, .{ .push_literal = .{ .integer = n } }) catch return ParseError.OutOfMemory;
        } else if (parseString(token)) |s| {
            const s_copy = allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .push_literal = .{ .string = s_copy } }) catch return ParseError.OutOfMemory;
        } else if (token.len > 1 and token[token.len - 1] == ':') {
            const sym_copy = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .push_literal = .{ .symbol = sym_copy } }) catch return ParseError.OutOfMemory;
        } else {
            const name_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .call_word = name_copy }) catch return ParseError.OutOfMemory;
        }
    }

    return instructions.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
}

pub fn parseQuotation(allocator: Allocator, tokenizer: *Tokenizer) ParseError![]const Instruction {
    var instructions: std.ArrayListUnmanaged(Instruction) = .{};
    errdefer instructions.deinit(allocator);

    while (tokenizer.next()) |token| {
        if (std.mem.eql(u8, token, "[")) {
            const nested = try parseQuotation(allocator, tokenizer);
            instructions.append(allocator, .{ .push_literal = .{ .quotation = nested } }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "]")) {
            return instructions.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "{")) {
            const arr = try parseArray(allocator, tokenizer);
            instructions.append(allocator, .{ .push_literal = .{ .array = arr } }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "(")) {
            const effect = try parseStackEffect(allocator, tokenizer);
            instructions.append(allocator, .{ .push_literal = .{ .stack_effect = effect } }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, ")")) {
            return ParseError.UnmatchedCloseParen;
        } else if (parseInteger(token)) |n| {
            instructions.append(allocator, .{ .push_literal = .{ .integer = n } }) catch return ParseError.OutOfMemory;
        } else if (parseString(token)) |s| {
            const s_copy = allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .push_literal = .{ .string = s_copy } }) catch return ParseError.OutOfMemory;
        } else if (token.len > 1 and token[token.len - 1] == ':') {
            const sym_copy = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .push_literal = .{ .symbol = sym_copy } }) catch return ParseError.OutOfMemory;
        } else {
            const name_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .call_word = name_copy }) catch return ParseError.OutOfMemory;
        }
    }

    return ParseError.UnmatchedOpenBracket;
}

/// Parse a stack effect with support for quotation annotations.
/// Handles nested parentheses for syntax like:
///   ( try-quot recover-quot: ( error -- ) -- )
///   ( seq quot: ( elem -- elem' ) -- seq' )
pub fn parseStackEffect(allocator: Allocator, tokenizer: *Tokenizer) ParseError!StackEffect {
    var inputs: std.ArrayListUnmanaged(StackEffectParam) = .{};
    errdefer inputs.deinit(allocator);

    var outputs: std.ArrayListUnmanaged(StackEffectParam) = .{};
    errdefer outputs.deinit(allocator);

    var current_list = &inputs;
    var pending_param_name: ?[]const u8 = null;

    while (tokenizer.next()) |token| {
        if (std.mem.eql(u8, token, "(")) {
            // This should be a nested effect for the pending parameter
            if (pending_param_name) |name| {
                const nested = try parseStackEffect(allocator, tokenizer);
                const nested_ptr = allocator.create(StackEffect) catch return ParseError.OutOfMemory;
                nested_ptr.* = nested;

                const param = StackEffectParam{
                    .name = name,
                    .quotation_effect = nested_ptr,
                };
                current_list.append(allocator, param) catch return ParseError.OutOfMemory;
                pending_param_name = null;
            } else {
                // Unexpected ( without a parameter name
                return ParseError.OutOfMemory;
            }
        } else if (std.mem.eql(u8, token, ")")) {
            // Flush any pending parameter
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name }) catch return ParseError.OutOfMemory;
            }

            return StackEffect{
                .inputs = inputs.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
                .outputs = outputs.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
            };
        } else if (std.mem.eql(u8, token, "--")) {
            // Flush pending parameter before switching
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name }) catch return ParseError.OutOfMemory;
                pending_param_name = null;
            }
            current_list = &outputs;
        } else if (token.len > 0 and token[token.len - 1] == ':') {
            // Flush previous pending parameter (if any)
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name }) catch return ParseError.OutOfMemory;
            }
            // This is a parameter name with annotation (strip the colon)
            pending_param_name = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
        } else {
            // Flush previous pending parameter (if any)
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name }) catch return ParseError.OutOfMemory;
            }
            // Regular parameter name
            pending_param_name = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
        }
    }

    return ParseError.UnmatchedOpenParen;
}

pub fn parseArray(allocator: Allocator, tokenizer: *Tokenizer) ParseError![]const Value {
    var values: std.ArrayListUnmanaged(Value) = .{};
    errdefer values.deinit(allocator);

    while (tokenizer.next()) |token| {
        if (std.mem.eql(u8, token, "{")) {
            const nested = try parseArray(allocator, tokenizer);
            values.append(allocator, .{ .array = nested }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "}")) {
            return values.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "[")) {
            const quot = try parseQuotation(allocator, tokenizer);
            values.append(allocator, .{ .quotation = quot }) catch return ParseError.OutOfMemory;
        } else if (parseInteger(token)) |n| {
            values.append(allocator, .{ .integer = n }) catch return ParseError.OutOfMemory;
        } else if (parseString(token)) |s| {
            values.append(allocator, .{ .string = s }) catch return ParseError.OutOfMemory;
        } else if (token.len > 1 and token[token.len - 1] == ':') {
            values.append(allocator, .{ .symbol = token[0 .. token.len - 1] }) catch return ParseError.OutOfMemory;
        } else {
            return ParseError.OutOfMemory;
        }
    }

    return ParseError.UnmatchedOpenBrace;
}

// =============================================================================
// Tests
// =============================================================================

test "parse simple quotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("1 2 + ]");
    const instrs = try parseQuotation(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqual(@as(i64, 1), instrs[0].push_literal.integer);
    try std.testing.expectEqual(@as(i64, 2), instrs[1].push_literal.integer);
    try std.testing.expectEqualStrings("+", instrs[2].call_word);
}

test "parse nested quotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("[ 1 ] ]");
    const instrs = try parseQuotation(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 1), instrs.len);
    const nested = instrs[0].push_literal.quotation;
    try std.testing.expectEqual(@as(usize, 1), nested.len);
    try std.testing.expectEqual(@as(i64, 1), nested[0].push_literal.integer);
}

test "unmatched open bracket" {
    var tokenizer = Tokenizer.init("1 2");
    const result = parseQuotation(std.testing.allocator, &tokenizer);
    try std.testing.expectError(ParseError.UnmatchedOpenBracket, result);
}

test "parse simple array" {
    var tokenizer = Tokenizer.init("1 2 3 }");
    const arr = try parseArray(std.testing.allocator, &tokenizer);
    defer std.testing.allocator.free(arr);

    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].integer);
    try std.testing.expectEqual(@as(i64, 2), arr[1].integer);
    try std.testing.expectEqual(@as(i64, 3), arr[2].integer);
}

test "parse nested array" {
    var tokenizer = Tokenizer.init("{ 1 2 } }");
    const arr = try parseArray(std.testing.allocator, &tokenizer);
    defer std.testing.allocator.free(arr);

    try std.testing.expectEqual(@as(usize, 1), arr.len);
    const nested = arr[0].array;
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqual(@as(usize, 2), nested.len);
    try std.testing.expectEqual(@as(i64, 1), nested[0].integer);
    try std.testing.expectEqual(@as(i64, 2), nested[1].integer);
}

test "parse array with string" {
    var tokenizer = Tokenizer.init("\"hello\" 42 }");
    const arr = try parseArray(std.testing.allocator, &tokenizer);
    defer std.testing.allocator.free(arr);

    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("hello", arr[0].string);
    try std.testing.expectEqual(@as(i64, 42), arr[1].integer);
}

test "unmatched open brace" {
    var tokenizer = Tokenizer.init("1 2");
    const result = parseArray(std.testing.allocator, &tokenizer);
    try std.testing.expectError(ParseError.UnmatchedOpenBrace, result);
}

test "parse simple stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("n -- n )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 1), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);
    try std.testing.expectEqualStrings("n", effect.inputs[0].name);
    try std.testing.expectEqualStrings("n", effect.outputs[0].name);
}

test "parse multi-arg stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("a b c -- sum )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 3), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);
    try std.testing.expectEqualStrings("a", effect.inputs[0].name);
    try std.testing.expectEqualStrings("b", effect.inputs[1].name);
    try std.testing.expectEqualStrings("c", effect.inputs[2].name);
    try std.testing.expectEqualStrings("sum", effect.outputs[0].name);
}

test "parse empty stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("-- )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 0), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), effect.outputs.len);
}

test "unmatched open paren" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("n -- n");
    const result = parseStackEffect(arena.allocator(), &tokenizer);
    try std.testing.expectError(ParseError.UnmatchedOpenParen, result);
}

test "parse stack effect with quotation annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("seq quot: ( elem -- elem' ) -- seq' )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 2), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);

    // First input: seq (no annotation)
    try std.testing.expectEqualStrings("seq", effect.inputs[0].name);
    try std.testing.expect(effect.inputs[0].quotation_effect == null);

    // Second input: quot with annotation
    try std.testing.expectEqualStrings("quot", effect.inputs[1].name);
    try std.testing.expect(effect.inputs[1].quotation_effect != null);

    const nested = effect.inputs[1].quotation_effect.?;
    try std.testing.expectEqual(@as(usize, 1), nested.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), nested.outputs.len);
    try std.testing.expectEqualStrings("elem", nested.inputs[0].name);
    try std.testing.expectEqualStrings("elem'", nested.outputs[0].name);
}

test "parse recover stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("try-quot recover-quot: ( error -- ) -- )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 2), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), effect.outputs.len);

    try std.testing.expectEqualStrings("try-quot", effect.inputs[0].name);
    try std.testing.expect(effect.inputs[0].quotation_effect == null);

    try std.testing.expectEqualStrings("recover-quot", effect.inputs[1].name);
    try std.testing.expect(effect.inputs[1].quotation_effect != null);

    const nested = effect.inputs[1].quotation_effect.?;
    try std.testing.expectEqual(@as(usize, 1), nested.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), nested.outputs.len);
    try std.testing.expectEqualStrings("error", nested.inputs[0].name);
}

test "parse bi stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("x p: ( x -- a ) q: ( x -- b ) -- a b )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 3), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), effect.outputs.len);

    // x has no annotation
    try std.testing.expectEqualStrings("x", effect.inputs[0].name);
    try std.testing.expect(effect.inputs[0].quotation_effect == null);

    // p and q have annotations
    try std.testing.expectEqualStrings("p", effect.inputs[1].name);
    try std.testing.expect(effect.inputs[1].quotation_effect != null);
    try std.testing.expectEqualStrings("q", effect.inputs[2].name);
    try std.testing.expect(effect.inputs[2].quotation_effect != null);
}

test "parse top level with stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("foo: ( n -- n ) [ 1 ]");
    const instrs = try parseTopLevel(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqualStrings("foo", instrs[0].push_literal.symbol);

    const effect = instrs[1].push_literal.stack_effect;
    try std.testing.expectEqual(@as(usize, 1), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);
    try std.testing.expectEqualStrings("n", effect.inputs[0].name);

    try std.testing.expectEqual(@as(usize, 1), instrs[2].push_literal.quotation.len);
}
