const std = @import("std");
const Allocator = std.mem.Allocator;

const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Instruction = @import("value.zig").Instruction;
const parser = @import("parser.zig");

/// StatementProcessor handles accumulating multi-line input and parsing.
/// Used by both REPL and batch modes to share the core logic.
pub const StatementProcessor = struct {
    stmt_buf: [65536]u8 = undefined,
    stmt_len: usize = 0,
    start_line: usize = 0, // File line number where current statement started

    pub const Result = union(enum) {
        needs_more_input,
        complete: []const Instruction,
        parse_error: anyerror,
    };

    /// Track the current file line number for error reporting.
    pub fn trackLine(self: *StatementProcessor, line_num: usize) void {
        if (self.stmt_len == 0) {
            // This is the start of a new statement
            self.start_line = line_num;
        }
    }

    // Feed a line of input. Returns the result of attempting to parse.
    pub fn feedLine(self: *StatementProcessor, allocator: Allocator, line: []const u8) Result {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) {
            return if (self.stmt_len > 0) .needs_more_input else .{ .complete = &.{} };
        }

        // Add newline separator if accumulating (preserves comment boundaries)
        if (self.stmt_len > 0 and self.stmt_len < self.stmt_buf.len) {
            self.stmt_buf[self.stmt_len] = '\n';
            self.stmt_len += 1;
        }

        // Copy trimmed line to buffer
        const copy_len = @min(trimmed.len, self.stmt_buf.len - self.stmt_len);
        @memcpy(self.stmt_buf[self.stmt_len..][0..copy_len], trimmed[0..copy_len]);
        self.stmt_len += copy_len;

        // Attempt to parse
        var tokenizer = Tokenizer.init(self.stmt_buf[0..self.stmt_len]);
        const instrs = parser.parseTopLevel(allocator, &tokenizer) catch |err| {
            if (parser.isIncompleteError(err)) {
                return .needs_more_input;
            }
            return .{ .parse_error = err };
        };

        return .{ .complete = instrs };
    }

    // Reset buffer after successful execution or fatal error.
    pub fn reset(self: *StatementProcessor) void {
        self.stmt_len = 0;
        self.start_line = 0;
    }

    // Check if currently accumulating input (for continuation prompt).
    pub fn isAccumulating(self: *const StatementProcessor) bool {
        return self.stmt_len > 0;
    }

    // Try to parse any remaining buffered content (for EOF handling).
    pub fn flush(self: *StatementProcessor, allocator: Allocator) Result {
        if (self.stmt_len == 0) {
            return .{ .complete = &.{} };
        }

        var tokenizer = Tokenizer.init(self.stmt_buf[0..self.stmt_len]);
        const instrs = parser.parseTopLevel(allocator, &tokenizer) catch |err| {
            return .{ .parse_error = err };
        };

        return .{ .complete = instrs };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "StatementProcessor complete input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};

    const result = processor.feedLine(arena.allocator(), "1 2 +");
    switch (result) {
        .complete => |instrs| {
            try std.testing.expectEqual(@as(usize, 3), instrs.len);
        },
        else => return error.UnexpectedResult,
    }
}

test "StatementProcessor multiline input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};

    // First line opens a quotation
    switch (processor.feedLine(arena.allocator(), "[")) {
        .needs_more_input => {},
        else => return error.UnexpectedResult,
    }

    try std.testing.expect(processor.isAccumulating());

    // Second line closes it
    switch (processor.feedLine(arena.allocator(), "1 2 + ]")) {
        .complete => |instrs| {
            try std.testing.expectEqual(@as(usize, 1), instrs.len);
        },
        else => return error.UnexpectedResult,
    }
}

test "StatementProcessor empty line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};

    // Empty line with no accumulation returns empty complete
    switch (processor.feedLine(arena.allocator(), "   ")) {
        .complete => |instrs| {
            try std.testing.expectEqual(@as(usize, 0), instrs.len);
        },
        else => return error.UnexpectedResult,
    }
}

test "StatementProcessor flush" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};

    // Feed incomplete input
    _ = processor.feedLine(arena.allocator(), "[");

    // Flush should return parse error for incomplete input
    switch (processor.flush(arena.allocator())) {
        .parse_error => {},
        else => return error.UnexpectedResult,
    }
}
