const std = @import("std");
const Allocator = std.mem.Allocator;
const tokenizer_mod = @import("tokenizer.zig");
const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;

/// FormatterToken extends Token with classification for formatting purposes.
pub const FormatterToken = struct {
    kind: Kind,
    text: []const u8,

    pub const Kind = enum {
        open_bracket, // [
        close_bracket, // ]
        open_brace, // {
        close_brace, // }
        open_paren, // (
        close_paren, // )
        arrow, // --
        semicolon, // ;
        symbol, // word:
        string, // "..."
        word, // other tokens
        comment, // \ ... to EOL
        newline, // preserved newline
    };

    fn classify(tok: Token) FormatterToken {
        if (tok.kind == .comment) {
            return .{ .kind = .comment, .text = tok.text };
        }
        if (tok.kind == .newline) {
            return .{ .kind = .newline, .text = tok.text };
        }

        const text = tok.text;
        if (std.mem.eql(u8, text, "[")) return .{ .kind = .open_bracket, .text = text };
        if (std.mem.eql(u8, text, "]")) return .{ .kind = .close_bracket, .text = text };
        if (std.mem.eql(u8, text, "{")) return .{ .kind = .open_brace, .text = text };
        if (std.mem.eql(u8, text, "}")) return .{ .kind = .close_brace, .text = text };
        if (std.mem.eql(u8, text, "(")) return .{ .kind = .open_paren, .text = text };
        if (std.mem.eql(u8, text, ")")) return .{ .kind = .close_paren, .text = text };
        if (std.mem.eql(u8, text, "--")) return .{ .kind = .arrow, .text = text };
        if (std.mem.eql(u8, text, ";")) return .{ .kind = .semicolon, .text = text };
        if (text.len > 0 and text[0] == '"') return .{ .kind = .string, .text = text };
        if (text.len > 1 and text[text.len - 1] == ':') return .{ .kind = .symbol, .text = text };
        return .{ .kind = .word, .text = text };
    }

    fn isOpening(self: FormatterToken) bool {
        return self.kind == .open_bracket or self.kind == .open_brace or self.kind == .open_paren;
    }

    fn isClosing(self: FormatterToken) bool {
        return self.kind == .close_bracket or self.kind == .close_brace or self.kind == .close_paren;
    }
};

/// Format 1z source code according to the language specification.
pub const Formatter = struct {
    allocator: Allocator,
    tokens: std.ArrayListUnmanaged(FormatterToken),
    indent_size: usize = 2,

    pub fn init(allocator: Allocator) Formatter {
        return .{
            .allocator = allocator,
            .tokens = .{},
        };
    }

    pub fn deinit(self: *Formatter) void {
        self.tokens.deinit(self.allocator);
    }

    /// Parse input into formatter tokens.
    pub fn parse(self: *Formatter, input: []const u8) !void {
        var tokenizer = Tokenizer.initForFormatting(input);
        while (tokenizer.next()) |tok| {
            try self.tokens.append(self.allocator, FormatterToken.classify(tok));
        }
    }

    /// Format and write output to writer.
    pub fn format(self: *Formatter, writer: anytype) !void {
        if (self.tokens.items.len == 0) return;

        var i: usize = 0;
        var indent_level: usize = 0;
        var in_stack_effect = false;
        var line_start = true;
        // Track if we just wrote an opening bracket
        var after_opening = false;
        var pending_comment: ?[]const u8 = null;
        // Track if last content was a comment (no blank lines after)
        var after_comment = false;
        // Track if we're at the start of the file
        var at_file_start = true;
        // Track consecutive newlines written
        var newlines_written: usize = 0;

        while (i < self.tokens.items.len) {
            const tok = self.tokens.items[i];

            switch (tok.kind) {
                .newline => {
                    // Count consecutive newlines
                    var newline_count: usize = 0;
                    var j = i;
                    while (j < self.tokens.items.len and self.tokens.items[j].kind == .newline) {
                        newline_count += 1;
                        j += 1;
                    }

                    // Check if these newlines are at end of file (no more content)
                    const is_trailing = self.peekNextNonNewline(j) == null;

                    // Determine how many total newlines to allow based on context
                    const max_newlines: usize = blk: {
                        // Inside stack effects: no newlines
                        if (in_stack_effect) break :blk 0;

                        // Trailing newlines at end of file: none (file will end with 1 from last content)
                        if (is_trailing) break :blk 0;

                        const prev = if (i > 0) self.tokens.items[i - 1] else null;
                        const next_content = self.peekNextNonNewline(j);

                        // Check for places where newlines should be removed (normalization)
                        if (next_content) |n| {
                            // Before opening bracket (except in multi-line blocks) - normalize
                            if (n.isOpening()) {
                                if (prev) |p| {
                                    // After stack effect or symbol, before bracket - remove newline
                                    if (p.kind == .close_paren or p.kind == .symbol) break :blk 0;
                                }
                            }

                            // Before semicolon - remove newline
                            if (n.kind == .semicolon) break :blk 0;

                            // Before closing bracket in single-line block - remove newline
                            if (n.isClosing() and !self.isMultiLineBlock(i)) break :blk 0;
                        }

                        // After a comment: no blank lines allowed (max 1 newline total)
                        if (after_comment) break :blk 1;

                        // At file start: allow up to 1 blank line (2 newlines)
                        if (at_file_start) break :blk 2;

                        // After opening bracket with content - multi-line block structure
                        if (prev) |p| {
                            if (p.isOpening()) {
                                if (next_content) |n| {
                                    if (!n.isClosing()) break :blk @min(newline_count, 2);
                                }
                            }
                        }

                        // Before closing bracket in multi-line block
                        if (next_content) |n| {
                            if (n.isClosing() and self.isMultiLineBlock(i)) {
                                break :blk @min(newline_count, 2);
                            }
                        }

                        // After semicolon (between statements) - allow up to 1 blank line
                        if (prev) |p| {
                            if (p.kind == .semicolon) break :blk 2;
                        }

                        // Default: remove newlines (normalize)
                        break :blk 0;
                    };

                    // Calculate how many more newlines to write (accounting for already written)
                    const desired = @min(max_newlines, newline_count);
                    const to_write = if (desired > newlines_written) desired - newlines_written else 0;

                    if (to_write > 0) {
                        // Write pending comment first
                        if (pending_comment) |comment| {
                            try writer.writeAll("  ");
                            try writer.writeAll(comment);
                            pending_comment = null;
                        }

                        // Write the additional newlines
                        for (0..to_write) |_| {
                            try writer.writeAll("\n");
                        }
                        newlines_written += to_write;
                        line_start = true;
                        after_opening = false;
                    }

                    // Skip all consecutive newlines
                    i = j;
                    continue;
                },

                .comment => {
                    at_file_start = false;
                    // Store comment to write at end of line or on its own line
                    if (line_start) {
                        try self.writeIndent(writer, indent_level);
                        try writer.writeAll(tok.text);
                        line_start = false;
                        after_comment = true;
                    } else {
                        pending_comment = tok.text;
                    }
                    newlines_written = 0;
                    i += 1;
                    continue;
                },

                .open_paren => {
                    at_file_start = false;
                    after_comment = false;
                    in_stack_effect = true;
                    if (!line_start) try writer.writeAll(" ");
                    try writer.writeAll("(");
                    line_start = false;
                    after_opening = true;
                    newlines_written = 0;
                },

                .close_paren => {
                    at_file_start = false;
                    after_comment = false;
                    in_stack_effect = false;
                    try writer.writeAll(" )");
                    line_start = false;
                    after_opening = false;
                    newlines_written = 0;
                },

                .arrow => {
                    at_file_start = false;
                    after_comment = false;
                    try writer.writeAll(" --");
                    line_start = false;
                    after_opening = false;
                    newlines_written = 0;
                },

                .open_bracket, .open_brace => {
                    at_file_start = false;
                    after_comment = false;
                    if (!line_start) try writer.writeAll(" ");
                    try writer.writeAll(tok.text);
                    indent_level += 1;
                    line_start = false;
                    after_opening = true;
                    newlines_written = 0;
                },

                .close_bracket, .close_brace => {
                    at_file_start = false;
                    after_comment = false;
                    indent_level -|= 1;

                    // Check if we need to be on a new line
                    const needs_newline = self.isMultiLineBlock(i);
                    if (needs_newline and !line_start) {
                        // Write pending comment
                        if (pending_comment) |comment| {
                            try writer.writeAll("  ");
                            try writer.writeAll(comment);
                            pending_comment = null;
                        }
                        try writer.writeAll("\n");
                        try self.writeIndent(writer, indent_level);
                        line_start = true;
                    } else if (!line_start and !after_opening) {
                        try writer.writeAll(" ");
                    }
                    try writer.writeAll(tok.text);
                    line_start = false;
                    after_opening = false;
                    newlines_written = 0;
                },

                .semicolon => {
                    at_file_start = false;
                    after_comment = false;
                    try writer.writeAll(" ;");
                    // After semicolon, write pending comment and newline
                    if (pending_comment) |comment| {
                        try writer.writeAll("  ");
                        try writer.writeAll(comment);
                        pending_comment = null;
                    }
                    try writer.writeAll("\n");
                    line_start = true;
                    after_opening = false;
                    newlines_written = 1;
                },

                .symbol => {
                    at_file_start = false;
                    after_comment = false;
                    if (line_start) {
                        try self.writeIndent(writer, indent_level);
                    } else {
                        try writer.writeAll(" ");
                    }
                    try writer.writeAll(tok.text);
                    line_start = false;
                    after_opening = false;
                    newlines_written = 0;
                },

                else => {
                    at_file_start = false;
                    after_comment = false;
                    if (line_start) {
                        try self.writeIndent(writer, indent_level);
                    } else {
                        try writer.writeAll(" ");
                    }
                    try writer.writeAll(tok.text);
                    line_start = false;
                    after_opening = false;
                    newlines_written = 0;
                },
            }

            i += 1;
        }

        // Write any remaining pending comment
        if (pending_comment) |comment| {
            try writer.writeAll("  ");
            try writer.writeAll(comment);
            line_start = false;
        }

        // Ensure file ends with exactly one newline (no trailing blank lines)
        if (!line_start) {
            try writer.writeAll("\n");
        }
    }

    /// Peek at next token that's not a newline.
    fn peekNextNonNewline(self: *Formatter, start: usize) ?FormatterToken {
        var j = start;
        while (j < self.tokens.items.len) {
            const t = self.tokens.items[j];
            if (t.kind != .newline) return t;
            j += 1;
        }
        return null;
    }

    fn writeIndent(self: *Formatter, writer: anytype, level: usize) !void {
        for (0..level * self.indent_size) |_| {
            try writer.writeAll(" ");
        }
    }

    /// Determine if the block containing position i is multi-line.
    fn isMultiLineBlock(self: *Formatter, pos: usize) bool {
        // Look backwards from pos to find the matching opening bracket
        var depth: i32 = 0;
        var j: usize = pos;

        while (j > 0) {
            j -= 1;
            const t = self.tokens.items[j];

            if (t.isClosing()) {
                depth += 1;
            } else if (t.isOpening()) {
                if (depth == 0) {
                    // Found matching opening bracket, now check if there's a newline between
                    var k = j + 1;
                    while (k < pos) {
                        if (self.tokens.items[k].kind == .newline) {
                            return true;
                        }
                        k += 1;
                    }
                    return false;
                }
                depth -= 1;
            }
        }
        return false;
    }
};

/// Format a string and return the formatted result.
pub fn formatString(allocator: Allocator, input: []const u8) ![]u8 {
    var formatter = Formatter.init(allocator);
    defer formatter.deinit();

    try formatter.parse(input);

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    try formatter.format(output.writer(allocator));

    return output.toOwnedSlice(allocator);
}

/// Format a file in-place.
pub fn formatFile(allocator: Allocator, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // 10MB max
    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 10);
    defer allocator.free(content);

    const formatted = try formatString(allocator, content);
    defer allocator.free(formatted);

    // Write back to file
    const write_file = try std.fs.cwd().createFile(path, .{});
    defer write_file.close();

    try write_file.writeAll(formatted);
}

/// Check if a file is properly formatted. Returns true if already formatted.
pub fn checkFile(allocator: Allocator, path: []const u8) !bool {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 10);
    defer allocator.free(content);

    const formatted = try formatString(allocator, content);
    defer allocator.free(formatted);

    return std.mem.eql(u8, content, formatted);
}

// =============================================================================
// Tests
// =============================================================================

test "format simple definition" {
    const input = "double: ( n -- n ) [ 2 * ] ;";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("double: ( n -- n ) [ 2 * ] ;\n", result);
}

test "format compress extra spaces" {
    const input = "double:   (  n  --  n  )   [  2   *  ]   ;";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("double: ( n -- n ) [ 2 * ] ;\n", result);
}

test "format preserves comments" {
    const input = "\\ This is a comment\n1 2 +";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("\\ This is a comment\n1 2 +\n", result);
}

test "format preserves multi-line structure" {
    const input = "factorial: ( n -- n! ) [\n  dup 1 >\n  [ dup 1 - factorial * ]\n  [ drop 1 ]\n  if\n] ;";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "] ;") != null);
}

test "format opening bracket on same line" {
    const input = "square: ( n -- n )\n[ dup * ]\n;";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("square: ( n -- n ) [ dup * ] ;\n", result);
}

test "format array" {
    const input = "{ 1 2 3 }";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("{ 1 2 3 }\n", result);
}

test "format empty input" {
    const input = "";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "format inline comment" {
    const input = "1 2 + \\ add numbers";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("1 2 +  \\ add numbers\n", result);
}

test "format preserves single blank line between statements" {
    const input = "double: [ 2 * ] ;\n\ntriple: [ 3 * ] ;";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("double: [ 2 * ] ;\n\ntriple: [ 3 * ] ;\n", result);
}

test "format compresses multiple blank lines to one" {
    const input = "double: [ 2 * ] ;\n\n\n\ntriple: [ 3 * ] ;";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("double: [ 2 * ] ;\n\ntriple: [ 3 * ] ;\n", result);
}

test "format no blank line after comment" {
    const input = "\\ a comment\n\ndouble: [ 2 * ] ;";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("\\ a comment\ndouble: [ 2 * ] ;\n", result);
}

test "format blank line before comment is ok" {
    const input = "double: [ 2 * ] ;\n\n\\ a comment\ntriple: [ 3 * ] ;";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("double: [ 2 * ] ;\n\n\\ a comment\ntriple: [ 3 * ] ;\n", result);
}

test "format no trailing blank lines" {
    const input = "double: [ 2 * ] ;\n\n\n";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("double: [ 2 * ] ;\n", result);
}
