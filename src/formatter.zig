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
        if (tok.kind == .comment or tok.kind == .doc_comment) {
            return .{ .kind = .comment, .text = tok.text };
        }
        if (tok.kind == .newline) {
            return .{ .kind = .newline, .text = tok.text };
        }

        const text = tok.text;
        if (std.mem.eql(u8, text, "[")) return .{ .kind = .open_bracket, .text = text };
        if (std.mem.eql(u8, text, "]")) return .{ .kind = .close_bracket, .text = text };
        if (std.mem.eql(u8, text, "{")) return .{ .kind = .open_brace, .text = text };
        if (text.len > 1 and text[text.len - 1] == '{') return .{ .kind = .open_brace, .text = text };
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
        var pending_comments: std.ArrayListUnmanaged([]const u8) = .{};
        defer pending_comments.deinit(self.allocator);
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
                        }

                        // After a comment: allow up to 1 blank line (preserve intentional separation)
                        if (after_comment) break :blk @min(newline_count, 2);

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

                        // If there are pending comments, preserve the newline so they stay on their line
                        // In multi-line blocks, also preserve blank lines
                        if (pending_comments.items.len > 0) {
                            if (indent_level > 0 and self.isInMultiLineBlock(i)) {
                                break :blk @min(newline_count, 2);
                            }
                            break :blk 1;
                        }

                        // Inside a multi-line block, preserve newlines between statements
                        // Allow up to 1 blank line to respect intentional separation
                        if (indent_level > 0 and self.isInMultiLineBlock(i)) break :blk @min(newline_count, 2);

                        // Default: preserve user's line breaks, compress multiple blank lines to one
                        break :blk @min(newline_count, 2);
                    };

                    // Calculate how many more newlines to write (accounting for already written)
                    const desired = @min(max_newlines, newline_count);
                    const to_write = if (desired > newlines_written) desired - newlines_written else 0;

                    if (to_write > 0) {
                        // Write pending comment first
                        for (pending_comments.items) |comment| {
                            try writer.writeAll("  ");
                            try writer.writeAll(comment);
                        }
                        pending_comments.clearRetainingCapacity();

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
                        try pending_comments.append(self.allocator, tok.text);
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
                    if (line_start) {
                        try self.writeIndent(writer, indent_level);
                    } else {
                        try writer.writeAll(" ");
                    }
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
                    if (needs_newline) {
                        if (!line_start) {
                            // Write pending comments before newline
                            for (pending_comments.items) |comment| {
                                try writer.writeAll("  ");
                                try writer.writeAll(comment);
                            }
                            pending_comments.clearRetainingCapacity();
                            try writer.writeAll("\n");
                        }
                        try self.writeIndent(writer, indent_level);
                        line_start = true;
                    } else if (!line_start) {
                        // Always write space before closing bracket in single-line mode
                        // This ensures `[ ]` stays as `[ ]` not `[]`
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

                    // A `;` terminates a definition statement only at the top level or inside a multi-line block.
                    // In either case the next statement belongs on its own line.
                    // Inside a single-line block (a quotation or brace form the user kept on one line), the `;`
                    // is part of that line and must not force a break, or the closing bracket gets orphaned.
                    // The block counts as multi-line when a newline appears anywhere within it, even if its
                    // first content shares the opening line (as in `matrix{ 1 ;` ... `}`).
                    const ends_statement = indent_level == 0 or self.enclosingBlockIsMultiLine(i);
                    if (ends_statement) {
                        // After semicolon, write pending comments and newline
                        for (pending_comments.items) |comment| {
                            try writer.writeAll("  ");
                            try writer.writeAll(comment);
                        }

                        pending_comments.clearRetainingCapacity();
                        try writer.writeAll("\n");
                        line_start = true;
                        after_opening = false;
                        newlines_written = 1;
                    } else {
                        line_start = false;
                        after_opening = false;
                        newlines_written = 0;
                    }
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

        // Write any remaining pending comments
        for (pending_comments.items) |comment| {
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

    /// Determine if we are currently inside a multi-line block.
    /// This looks for the enclosing opening bracket and checks if there's a newline after it.
    fn isInMultiLineBlock(self: *Formatter, pos: usize) bool {
        // Look backwards to find the most recent unclosed opening bracket
        var depth: i32 = 0;
        var j: usize = pos;

        while (j > 0) {
            j -= 1;
            const t = self.tokens.items[j];

            if (t.isClosing()) {
                depth += 1;
            } else if (t.isOpening()) {
                if (depth == 0) {
                    // Found the enclosing opening bracket
                    // Check if there's a newline immediately after it
                    var k = j + 1;
                    while (k < pos) {
                        if (self.tokens.items[k].kind == .newline) {
                            return true;
                        }
                        // Stop at first non-newline, non-comment token
                        if (self.tokens.items[k].kind != .comment) {
                            break;
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

    /// Determine whether the block enclosing pos spans multiple lines, scanning the whole
    /// block rather than only the gap after its opening bracket. A `matrix{ 1 ;` ... `}` form
    /// keeps its first content on the opening line yet is still multi-line, so the row-separating
    /// `;` tokens must break.
    fn enclosingBlockIsMultiLine(self: *Formatter, pos: usize) bool {
        // Find the enclosing opening bracket by walking backwards with depth tracking.
        var depth: i32 = 0;
        var j: usize = pos;
        while (j > 0) {
            j -= 1;
            const t = self.tokens.items[j];
            if (t.isClosing()) {
                depth += 1;
            } else if (t.isOpening()) {
                if (depth == 0) {
                    // Scan forward from the opening bracket to its matching close for any newline.
                    var inner_depth: i32 = 0;
                    var k = j + 1;
                    while (k < self.tokens.items.len) : (k += 1) {
                        const u = self.tokens.items[k];
                        if (u.kind == .newline) return true;
                        if (u.isOpening()) {
                            inner_depth += 1;
                        } else if (u.isClosing()) {
                            if (inner_depth == 0) return false;
                            inner_depth -= 1;
                        }
                    }
                    return false;
                }
                depth -= 1;
            }
        }
        return false;
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

    const formatted = try output.toOwnedSlice(allocator);
    defer allocator.free(formatted);

    // Post-process to align consecutive inline comments and single-line definitions
    const with_comments = try alignComments(allocator, formatted);
    defer allocator.free(with_comments);
    return alignSymbolLines(allocator, with_comments);
}

/// Align consecutive inline comments to the same column.
/// Groups of consecutive lines with inline comments are aligned together.
///
/// XXX(ripta): Not a fan of reparsing lines here. Find better ways in the future.
fn alignComments(allocator: Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var lines = try splitIntoLines(allocator, input);
    defer lines.deinit(allocator);

    // Process lines in groups
    var i: usize = 0;
    while (i < lines.items.len) {
        // Find the end of a group of consecutive lines with inline comments
        const group_start = i;
        var group_end = i;
        var max_code_len: usize = 0;

        while (group_end < lines.items.len) {
            const line = lines.items[group_end];
            if (findInlineComment(line)) |comment_pos| {
                // This line has an inline comment
                // Code length is everything before "  \"
                const code_len = if (comment_pos >= 2) comment_pos - 2 else 0;
                max_code_len = @max(max_code_len, code_len);
                group_end += 1;
            } else {
                // No inline comment - end of group
                break;
            }
        }

        if (group_end > group_start and max_code_len > 0) {
            // We have a group of lines with inline comments - align them
            for (lines.items[group_start..group_end]) |line| {
                if (findInlineComment(line)) |comment_pos| {
                    const code_end = if (comment_pos >= 2) comment_pos - 2 else 0;
                    const code_part = std.mem.trimRight(u8, line[0..code_end], " ");
                    const comment_part = line[comment_pos..];

                    try result.appendSlice(allocator, code_part);
                    // Pad to align comments
                    const padding = if (max_code_len > code_part.len) max_code_len - code_part.len else 0;
                    for (0..padding + 2) |_| {
                        try result.append(allocator, ' ');
                    }
                    try result.appendSlice(allocator, comment_part);
                    try result.append(allocator, '\n');
                }
            }
            i = group_end;
        } else {
            try emitRawLines(allocator, &result, lines.items[i .. i + 1]);
            i += 1;
        }
    }

    // Remove trailing newline if input didn't have one
    if (result.items.len > 0 and input.len > 0 and input[input.len - 1] != '\n') {
        _ = result.pop();
    }

    return result.toOwnedSlice(allocator);
}

/// Find the position of an inline comment in a line.
/// Returns null if no inline comment (standalone comments or no comment).
fn findInlineComment(line: []const u8) ?usize {
    // An inline comment is "  \" preceded by non-whitespace content
    // Standalone comments start with optional whitespace then "\"

    // First, check if line has a comment at all
    const comment_marker = std.mem.indexOf(u8, line, "\\");
    if (comment_marker == null) return null;

    const pos = comment_marker.?;

    // Check if this is an inline comment (has code before it)
    // Inline comments have "  \" pattern - two spaces before backslash
    if (pos >= 2 and line[pos - 1] == ' ' and line[pos - 2] == ' ') {
        // Check if there's actual code before the spaces
        const before_spaces = std.mem.trimRight(u8, line[0 .. pos - 2], " ");
        if (before_spaces.len > 0 and before_spaces[0] != '\\') {
            return pos;
        }
    }

    return null;
}

/// Split input into lines, separated by newline characters.
fn splitIntoLines(allocator: Allocator, input: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var lines: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer lines.deinit(allocator);

    var line_start: usize = 0;
    for (input, 0..) |c, idx| {
        if (c == '\n') {
            try lines.append(allocator, input[line_start..idx]);
            line_start = idx + 1;
        }
    }
    if (line_start < input.len) {
        try lines.append(allocator, input[line_start..]);
    }

    return lines;
}

/// Emit lines as-is into the result buffer, each followed by a newline.
fn emitRawLines(allocator: Allocator, result: *std.ArrayListUnmanaged(u8), lines: []const []const u8) !void {
    for (lines) |line| {
        try result.appendSlice(allocator, line);
        try result.append(allocator, '\n');
    }
}

/// Find the end index of a divergence-limited subgroup starting at `start`.
/// Lines in the subgroup have name lengths whose padding does not exceed
/// min(shortest_name_len, 15).
fn findSubgroupEnd(parsed: []const ?AlignableLine, start: usize) usize {
    var subgroup_end = start + 1;
    var max_name_len = parsed[start].?.name.len;
    var min_name_len = parsed[start].?.name.len;

    while (subgroup_end < parsed.len) {
        const candidate_len = parsed[subgroup_end].?.name.len;
        const new_max = @max(max_name_len, candidate_len);
        const new_min = @min(min_name_len, candidate_len);

        const padding_needed = new_max - new_min;
        const limit = @min(new_min, 15);
        if (padding_needed > limit) break;

        max_name_len = new_max;
        min_name_len = new_min;
        subgroup_end += 1;
    }

    return subgroup_end;
}

/// Parsed representation of an alignable symbol line (definition or block entry).
const AlignableLine = struct {
    indent: []const u8,
    name: []const u8,
    has_stack_effect: bool,
    stack_effect: []const u8,
    body: []const u8,
    suffix: []const u8,
    trailing_comment: ?[]const u8,
};

/// Parse a line as an alignable symbol line.
/// Returns null if the line is not alignable.
///
/// Unindented lines must end with " ;" and may have a stack effect after the
/// name. Indented lines have no stack effect parsing; body includes everything
/// after the name (including " ;" if present), and suffix is empty.
///
/// XXX(ripta): Not a fan of reparsing lines here. Find better ways in the future.
fn parseAlignableLine(line: []const u8) ?AlignableLine {
    const trimmed_right = std.mem.trimRight(u8, line, " \t");
    const stripped = std.mem.trimLeft(u8, line, " ");
    const indent_len = line.len - stripped.len;
    const indent = line[0..indent_len];

    const first_space = std.mem.indexOf(u8, stripped, " ") orelse return null;
    const first_word = stripped[0..first_space];
    if (first_word.len < 2 or first_word[first_word.len - 1] != ':') return null;

    const after_name = std.mem.trimLeft(u8, stripped[first_space..], " ");
    if (after_name.len == 0) return null;

    if (indent_len == 0) {
        var trailing_comment: ?[]const u8 = null;
        var def_end: usize = undefined;

        if (findInlineComment(trimmed_right)) |comment_pos| {
            const before_comment = std.mem.trimRight(u8, trimmed_right[0 .. comment_pos - 2], " ");
            if (before_comment.len < 2 or !std.mem.endsWith(u8, before_comment, " ;")) return null;
            def_end = before_comment.len - 2;
            trailing_comment = trimmed_right[comment_pos..];
        } else {
            if (!std.mem.endsWith(u8, trimmed_right, " ;")) return null;
            def_end = trimmed_right.len - 2;
        }

        if (def_end == 0) return null;
        const content = std.mem.trimRight(u8, line[0..def_end], " ");

        const content_first_space = std.mem.indexOf(u8, content, " ") orelse return null;
        const content_after_name = std.mem.trimLeft(u8, content[content_first_space..], " ");
        if (content_after_name.len == 0) return null;

        if (content_after_name[0] == '(') {
            const close_paren = std.mem.indexOf(u8, content_after_name, " )") orelse return null;
            const stack_effect = content_after_name[0 .. close_paren + 2];
            const body = std.mem.trimLeft(u8, content_after_name[close_paren + 2 ..], " ");
            if (body.len == 0) return null;

            return .{
                .indent = indent,
                .name = first_word,
                .has_stack_effect = true,
                .stack_effect = stack_effect,
                .body = body,
                .suffix = " ;",
                .trailing_comment = trailing_comment,
            };
        }

        return .{
            .indent = indent,
            .name = first_word,
            .has_stack_effect = false,
            .stack_effect = "",
            .body = content_after_name,
            .suffix = " ;",
            .trailing_comment = trailing_comment,
        };
    }

    // Indented: block entry, no stack effect, body is everything after name
    var trailing_comment: ?[]const u8 = null;
    var value: []const u8 = undefined;

    if (findInlineComment(trimmed_right)) |comment_pos| {
        const before_comment = std.mem.trimRight(u8, trimmed_right[0 .. comment_pos - 2], " ");
        value = std.mem.trimLeft(u8, before_comment[indent_len + first_word.len ..], " ");
        trailing_comment = trimmed_right[comment_pos..];
    } else {
        value = std.mem.trimRight(u8, after_name, " \t");
    }

    if (value.len == 0) return null;

    return .{
        .indent = indent,
        .name = first_word,
        .has_stack_effect = false,
        .stack_effect = "",
        .body = value,
        .suffix = "",
        .trailing_comment = trailing_comment,
    };
}

/// Align consecutive symbol lines (definitions and block entries) so their
/// bodies line up vertically. Groups of 3 or more like-structured lines at
/// the same indent level are aligned together. Stack effect alignment is
/// reserved for unindented (top-level) definitions.
///
/// XXX(ripta): Not a fan of reparsing lines here. Find better ways in the future.
fn alignSymbolLines(allocator: Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var lines = try splitIntoLines(allocator, input);
    defer lines.deinit(allocator);

    var parsed = try std.ArrayListUnmanaged(?AlignableLine).initCapacity(allocator, lines.items.len);
    defer parsed.deinit(allocator);
    for (lines.items) |line| {
        parsed.appendAssumeCapacity(parseAlignableLine(line));
    }

    var i: usize = 0;
    while (i < lines.items.len) {
        if (parsed.items[i] == null) {
            try emitRawLines(allocator, &result, lines.items[i .. i + 1]);
            i += 1;
            continue;
        }

        // Find end of consecutive parsed lines at the same indent level
        const group_start = i;
        const group_indent = parsed.items[i].?.indent;
        var group_end = i;
        while (group_end < lines.items.len) {
            const p = parsed.items[group_end] orelse break;
            if (!std.mem.eql(u8, p.indent, group_indent)) break;
            group_end += 1;
        }

        // Split group into sub-runs by has_stack_effect
        var run_start = group_start;
        while (run_start < group_end) {
            const run_has_effect = parsed.items[run_start].?.has_stack_effect;
            var run_end = run_start + 1;
            while (run_end < group_end and parsed.items[run_end].?.has_stack_effect == run_has_effect) {
                run_end += 1;
            }

            const run_len = run_end - run_start;
            if (run_len >= 3) {
                var subgroup_start = run_start;
                while (subgroup_start < run_end) {
                    const subgroup_end = findSubgroupEnd(parsed.items[subgroup_start..run_end], 0) + subgroup_start;
                    const subgroup_len = subgroup_end - subgroup_start;
                    if (subgroup_len >= 3) {
                        try emitAlignedLines(allocator, &result, parsed.items[subgroup_start..subgroup_end]);
                    } else {
                        try emitRawLines(allocator, &result, lines.items[subgroup_start..subgroup_end]);
                    }
                    subgroup_start = subgroup_end;
                }
            } else {
                try emitRawLines(allocator, &result, lines.items[run_start..run_end]);
            }

            run_start = run_end;
        }

        i = group_end;
    }

    if (result.items.len > 0 and input.len > 0 and input[input.len - 1] != '\n') {
        _ = result.pop();
    }

    return result.toOwnedSlice(allocator);
}

/// Emit a subgroup of alignable lines with aligned columns.
fn emitAlignedLines(
    allocator: Allocator,
    result: *std.ArrayListUnmanaged(u8),
    lines: []const ?AlignableLine,
) !void {
    var max_name_len: usize = 0;
    for (lines) |maybe_line| {
        max_name_len = @max(max_name_len, maybe_line.?.name.len);
    }

    const has_stack_effect = lines[0].?.has_stack_effect;
    var max_effect_len: usize = 0;
    if (has_stack_effect) {
        for (lines) |maybe_line| {
            max_effect_len = @max(max_effect_len, maybe_line.?.stack_effect.len);
        }
    }

    for (lines) |maybe_line| {
        const line = maybe_line.?;

        try result.appendSlice(allocator, line.indent);
        try result.appendSlice(allocator, line.name);

        const name_padding = max_name_len - line.name.len;
        for (0..name_padding) |_| {
            try result.append(allocator, ' ');
        }

        if (has_stack_effect) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, line.stack_effect);

            const effect_padding = max_effect_len - line.stack_effect.len;
            for (0..effect_padding) |_| {
                try result.append(allocator, ' ');
            }
        }

        try result.append(allocator, ' ');
        try result.appendSlice(allocator, line.body);
        try result.appendSlice(allocator, line.suffix);

        if (line.trailing_comment) |comment| {
            try result.appendSlice(allocator, "  ");
            try result.appendSlice(allocator, comment);
        }

        try result.append(allocator, '\n');
    }
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
// Most formatter tests are in tests/formatting/ as golden file tests.
// Run with: zig build fmt-test

test "format empty input" {
    const input = "";
    const result = try formatString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}
