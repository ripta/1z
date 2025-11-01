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
    UnmatchedOpenParen,
    UnmatchedCloseParen,
    OutOfMemory,
};

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const args = std.process.argsAlloc(allocator) catch return 1;
    defer std.process.argsFree(allocator, args);

    // If a file path is provided, run in batch mode, which executes the file
    // and exits. Errors print to stderr, and cause a non-zero exit code.
    // Otherwise, interactive REPL starts.
    if (args.len > 1) {
        return batch(&ctx, args[1]);
    } else {
        repl(&ctx);
        return 0;
    }
}

fn repl(ctx: *Context) void {
    const stdin_file: File = .stdin();
    const stdout_file: File = .stdout();

    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin = stdin_file.reader(&stdin_buf);
    var stdout = stdout_file.writer(&stdout_buf);

    const writer = &stdout.interface;
    const reader = &stdin.interface;

    // Buffer for accumulating multiline statements
    var stmt_buf: [65536]u8 = undefined;
    var stmt_len: usize = 0;

    writer.print("1z interpreter v{s}\n", .{version}) catch return;
    writer.writeAll("Type '.q' to quit\n\n") catch return;
    writer.flush() catch return;

    // TODO(ripta): Refactor this loop and batch mode to share more code,
    // potentially into an evaluator.
    while (true) {
        // Show continuation prompt if accumulating, otherwise primary prompt
        if (stmt_len > 0) {
            writer.writeAll("+ ") catch return;
        } else {
            writer.writeAll("> ") catch return;
        }
        writer.flush() catch return;

        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                writer.writeAll("\nGoodbye!\n") catch {};
                writer.flush() catch {};
                return;
            },
            else => {
                writer.print("\nError reading input: {any}\n", .{err}) catch {};
                writer.flush() catch {};
                continue;
            },
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.eql(u8, trimmed, ".q")) {
            writer.writeAll("Goodbye!\n") catch {};
            writer.flush() catch {};
            break;
        }

        if (trimmed.len == 0) {
            continue;
        }

        // Accumulate multiple lines into the statement buffer
        if (stmt_len > 0) {
            if (stmt_len < stmt_buf.len) {
                stmt_buf[stmt_len] = ' ';
                stmt_len += 1;
            }
        }
        const copy_len = @min(trimmed.len, stmt_buf.len - stmt_len);
        @memcpy(stmt_buf[stmt_len..][0..copy_len], trimmed[0..copy_len]);
        stmt_len += copy_len;

        // Attempt to parse the accumulated statement. If incomplete, continue
        // accumulating more input. If an error occurs, report it and reset the buffer.
        // If parsing succeeds, execute the quotation.
        var tokenizer = Tokenizer.init(stmt_buf[0..stmt_len]);
        const instrs = parseTopLevel(ctx.quotationAllocator(), &tokenizer) catch |err| {
            if (isIncompleteError(err)) {
                continue;
            }

            writer.print("Error: {any}\n", .{err}) catch {};
            writer.flush() catch return;
            stmt_len = 0;
            continue;
        };

        var had_error = false;
        ctx.executeQuotation(instrs) catch |err| {
            writer.print("Error: {any}\n", .{err}) catch {};
            had_error = true;
        };

        // On success, print the current stack state.
        // TODO(ripta): Consider printing stack on error as well. We need to be
        // careful about partial state and large stacks.
        if (!had_error) {
            writer.writeAll("Stack: ") catch return;
            ctx.stack.dump(writer) catch return;
            writer.writeAll("\n") catch return;
        }

        writer.flush() catch return;
        stmt_len = 0;
    }
}

fn batch(ctx: *Context, file_path: []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writer(&stderr_buf);
    const err_writer = &stderr.interface;

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        err_writer.print("Error opening file '{s}': {any}\n", .{ file_path, err }) catch {};
        err_writer.flush() catch {};
        return 1;
    };
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    // Buffer for accumulating multiline statements
    var stmt_buf: [65536]u8 = undefined;
    var stmt_len: usize = 0;

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Try to execute any remaining buffered content
                if (stmt_len > 0) {
                    var tokenizer = Tokenizer.init(stmt_buf[0..stmt_len]);
                    const instrs = parseTopLevel(ctx.quotationAllocator(), &tokenizer) catch |err2| {
                        err_writer.print("Error: {any}\n", .{err2}) catch {};
                        err_writer.flush() catch {};
                        return 1;
                    };
                    ctx.executeQuotation(instrs) catch |err2| {
                        err_writer.print("Error: {any}\n", .{err2}) catch {};
                        err_writer.flush() catch {};
                        return 1;
                    };
                }
                break;
            },
            else => {
                err_writer.print("Error reading file: {any}\n", .{err}) catch {};
                err_writer.flush() catch {};
                return 1;
            },
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ".q")) break;

        // Accumulate multiple lines into the statement buffer
        if (stmt_len > 0) {
            if (stmt_len < stmt_buf.len) {
                stmt_buf[stmt_len] = ' ';
                stmt_len += 1;
            }
        }
        const copy_len = @min(trimmed.len, stmt_buf.len - stmt_len);
        @memcpy(stmt_buf[stmt_len..][0..copy_len], trimmed[0..copy_len]);
        stmt_len += copy_len;

        // Attempt to parse the accumulated statement. If incomplete, continue
        // accumulating more input. If an error occurs, report it and reset the buffer.
        // If parsing succeeds, execute the quotation.
        var tokenizer = Tokenizer.init(stmt_buf[0..stmt_len]);
        const instrs = parseTopLevel(ctx.quotationAllocator(), &tokenizer) catch |err| {
            if (isIncompleteError(err)) {
                continue; // Accumulate more input
            }
            err_writer.print("Error: {any}\n", .{err}) catch {};
            err_writer.flush() catch {};
            return 1;
        };

        ctx.executeQuotation(instrs) catch |err| {
            err_writer.print("Error: {any}\n", .{err}) catch {};
            err_writer.flush() catch {};
            return 1;
        };
        stmt_len = 0;
    }

    return 0;
}

/// Returns true if the parse error indicates incomplete input.
fn isIncompleteError(err: anyerror) bool {
    return err == error.UnmatchedOpenBracket or err == error.UnmatchedOpenBrace;
}

fn parseTopLevel(allocator: Allocator, tokenizer: *Tokenizer) ParseError![]const Instruction {
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

fn interpretTokens(ctx: *Context, tokenizer: *Tokenizer, _: anytype) !void {
    const instrs = try parseTopLevel(ctx.quotationAllocator(), tokenizer);
    try ctx.executeQuotation(instrs);
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
        } else if (std.mem.eql(u8, token, "(")) {
            const effect = try parseStackEffect(allocator, tokenizer);
            instructions.append(allocator, .{ .push_literal = .{ .stack_effect = effect } }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, ")")) {
            return ParseError.UnmatchedCloseParen;
        } else if (parseInteger(token)) |n| {
            instructions.append(allocator, .{ .push_literal = .{ .integer = n } }) catch return ParseError.OutOfMemory;
        } else if (parseString(token)) |s| {
            // Copy string to arena so it persists after input buffer is reused
            const s_copy = allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .push_literal = .{ .string = s_copy } }) catch return ParseError.OutOfMemory;
        } else if (token.len > 1 and token[token.len - 1] == ':') {
            // Copy symbol to arena so it persists after input buffer is reused
            const sym_copy = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .push_literal = .{ .symbol = sym_copy } }) catch return ParseError.OutOfMemory;
        } else {
            // Copy word name to arena so it persists after input buffer is reused
            const name_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .call_word = name_copy }) catch return ParseError.OutOfMemory;
        }
    }

    return ParseError.UnmatchedOpenBracket;
}

fn parseStackEffect(allocator: Allocator, tokenizer: *Tokenizer) ParseError![]const u8 {
    var tokens: std.ArrayListUnmanaged([]const u8) = .{};
    defer tokens.deinit(allocator);

    while (tokenizer.next()) |token| {
        if (std.mem.eql(u8, token, ")")) {
            // Join tokens with spaces to form the stack effect string
            const result = std.mem.join(allocator, " ", tokens.items) catch return ParseError.OutOfMemory;
            return result;
        }
        const token_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
        tokens.append(allocator, token_copy) catch return ParseError.OutOfMemory;
    }

    return ParseError.UnmatchedOpenParen;
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
