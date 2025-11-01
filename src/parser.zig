const std = @import("std");
const Allocator = std.mem.Allocator;

const Tokenizer = @import("tokenizer.zig").Tokenizer;
const parseInteger = @import("tokenizer.zig").parseInteger;
const parseString = @import("tokenizer.zig").parseString;
const Value = @import("value.zig").Value;
const Instruction = @import("value.zig").Instruction;

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

pub fn parseStackEffect(allocator: Allocator, tokenizer: *Tokenizer) ParseError![]const u8 {
    var tokens: std.ArrayListUnmanaged([]const u8) = .{};
    defer tokens.deinit(allocator);

    while (tokenizer.next()) |token| {
        if (std.mem.eql(u8, token, ")")) {
            const result = std.mem.join(allocator, " ", tokens.items) catch return ParseError.OutOfMemory;
            return result;
        }
        const token_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
        tokens.append(allocator, token_copy) catch return ParseError.OutOfMemory;
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
    try std.testing.expectEqualStrings("n -- n", effect);
}

test "parse multi-arg stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("a b c -- sum )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer);
    try std.testing.expectEqualStrings("a b c -- sum", effect);
}

test "parse empty stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init(")");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer);
    try std.testing.expectEqualStrings("", effect);
}

test "unmatched open paren" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("n -- n");
    const result = parseStackEffect(arena.allocator(), &tokenizer);
    try std.testing.expectError(ParseError.UnmatchedOpenParen, result);
}

test "parse top level with stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("foo: ( n -- n ) [ 1 ]");
    const instrs = try parseTopLevel(arena.allocator(), &tokenizer);

    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqualStrings("foo", instrs[0].push_literal.symbol);
    try std.testing.expectEqualStrings("n -- n", instrs[1].push_literal.stack_effect);
    try std.testing.expectEqual(@as(usize, 1), instrs[2].push_literal.quotation.len);
}
