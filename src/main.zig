const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const Context = @import("context.zig").Context;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const parseInteger = @import("tokenizer.zig").parseInteger;
const parseString = @import("tokenizer.zig").parseString;
const Value = @import("value.zig").Value;
const Instruction = @import("value.zig").Instruction;

const build_options = @import("build_options");
pub const version = build_options.version;

const ParseError = error{
    UnmatchedOpenBracket,
    UnmatchedCloseBracket,
    UnmatchedOpenBrace,
    UnmatchedCloseBrace,
    OutOfMemory,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try repl(&ctx);
}

fn repl(ctx: *Context) !void {
    const stdin_file: File = .stdin();
    const stdout_file: File = .stdout();

    // Buffers for buffered I/O
    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin = stdin_file.reader(&stdin_buf);
    var stdout = stdout_file.writer(&stdout_buf);

    const writer = &stdout.interface;
    const reader = &stdin.interface;

    try writer.print("1z interpreter v{s}\n", .{version});
    try writer.writeAll("Type '.q' to quit\n\n");
    try writer.flush();

    while (true) {
        // Prompt
        try writer.writeAll("> ");
        try writer.flush();

        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                try writer.writeAll("\nGoodbye!\n");
                try writer.flush();
                return;
            },
            else => {
                try writer.print("\nError reading input: {any}\n", .{err});
                try writer.flush();
                continue;
            },
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (std.mem.eql(u8, trimmed, ".q") or std.mem.eql(u8, trimmed, "quit")) {
            try writer.writeAll("Goodbye!\n");
            try writer.flush();
            break;
        }

        if (trimmed.len == 0) {
            continue;
        }

        var tokenizer = Tokenizer.init(trimmed);
        const result = interpretTokens(ctx, &tokenizer, writer);
        const had_error = if (result) |_| false else |_| true;
        result catch |err| {
            try writer.print("Error: {any}\n", .{err});
        };

        if (!had_error) {
            try writer.writeAll("Stack: ");
            try ctx.stack.dump(writer);
            try writer.writeAll("\n");
        }
        try writer.flush();
    }
}

fn interpretTokens(ctx: *Context, tokenizer: *Tokenizer, writer: anytype) !void {
    while (tokenizer.next()) |token| {
        if (std.mem.eql(u8, token, "[")) {
            const quotation = try parseQuotation(ctx.quotationAllocator(), tokenizer);
            try ctx.stack.push(.{ .quotation = quotation });
        } else if (std.mem.eql(u8, token, "]")) {
            return ParseError.UnmatchedCloseBracket;
        } else if (std.mem.eql(u8, token, "{")) {
            const arr = try parseArray(ctx.quotationAllocator(), tokenizer);
            try ctx.stack.push(.{ .array = arr });
        } else if (std.mem.eql(u8, token, "}")) {
            return ParseError.UnmatchedCloseBrace;
        } else if (parseInteger(token)) |n| {
            try ctx.stack.push(.{ .integer = n });
        } else if (parseString(token)) |s| {
            try ctx.stack.push(.{ .string = s });
        } else if (token.len > 1 and token[token.len - 1] == ':') {
            try ctx.stack.push(.{ .symbol = token[0 .. token.len - 1] });
        } else if (ctx.dictionary.get(token)) |word| {
            switch (word.action) {
                .native => |func| try func(ctx),
                .compound => |instrs| try ctx.executeQuotation(instrs),
            }
        } else {
            writer.print("Error: unknown word '{s}'\n", .{token}) catch {};
            return error.UnknownWord;
        }
    }
}

fn parseQuotation(allocator: Allocator, tokenizer: *Tokenizer) ParseError![]const Instruction {
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
        } else if (parseInteger(token)) |n| {
            instructions.append(allocator, .{ .push_literal = .{ .integer = n } }) catch return ParseError.OutOfMemory;
        } else if (parseString(token)) |s| {
            instructions.append(allocator, .{ .push_literal = .{ .string = s } }) catch return ParseError.OutOfMemory;
        } else if (token.len > 1 and token[token.len - 1] == ':') {
            instructions.append(allocator, .{ .push_literal = .{ .symbol = token[0 .. token.len - 1] } }) catch return ParseError.OutOfMemory;
        } else {
            instructions.append(allocator, .{ .call_word = token }) catch return ParseError.OutOfMemory;
        }
    }

    return ParseError.UnmatchedOpenBracket;
}

fn parseArray(allocator: Allocator, tokenizer: *Tokenizer) ParseError![]const Value {
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
            // Unknown token in array - treat as error for now
            return ParseError.OutOfMemory;
        }
    }

    return ParseError.UnmatchedOpenBrace;
}

// =============================================================================
// Tests - import other modules to run their tests
// =============================================================================

test {
    _ = @import("value.zig");
    _ = @import("stack.zig");
    _ = @import("context.zig");
    _ = @import("tokenizer.zig");
    _ = @import("dictionary.zig");
    _ = @import("primitives.zig");
}

test "parse simple quotation" {
    var tokenizer = Tokenizer.init("1 2 + ]");
    const instrs = try parseQuotation(std.testing.allocator, &tokenizer);
    defer std.testing.allocator.free(instrs);

    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqual(@as(i64, 1), instrs[0].push_literal.integer);
    try std.testing.expectEqual(@as(i64, 2), instrs[1].push_literal.integer);
    try std.testing.expectEqualStrings("+", instrs[2].call_word);
}

test "parse nested quotation" {
    var tokenizer = Tokenizer.init("[ 1 ] ]");
    const instrs = try parseQuotation(std.testing.allocator, &tokenizer);
    defer std.testing.allocator.free(instrs);

    try std.testing.expectEqual(@as(usize, 1), instrs.len);
    const nested = instrs[0].push_literal.quotation;
    defer std.testing.allocator.free(nested);
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
