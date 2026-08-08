const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Instruction = @import("value.zig").Instruction;
const parser = @import("parser.zig");
const Context = @import("context.zig").Context;
const pc_mod = @import("parser_coroutine.zig");
const ParserCoroutine = pc_mod.ParserCoroutine;
const task_mod = @import("task.zig");

// Freestanding targets have no libc ucontext, so the coroutine-based incremental parse below is
// unusable there (see parser_coroutine.zig). feedLine takes a coroutine-free fallback instead:
// reparse the accumulated buffer from scratch via the same direct parser.parseTopLevel path
// flush() already uses for its own non-coroutine case, detecting incompleteness through
// parser.isIncompleteError rather than a suspended parse. This never touches self.coroutine or
// self.coroutine_stack on that target, so no coroutine is ever constructed or resumed there.
const is_freestanding = builtin.os.tag == .freestanding;

/// StatementProcessor handles accumulating multi-line input and parsing.
/// Used by both REPL and batch modes to share the core logic.
pub const StatementProcessor = struct {
    // Buffer for accumulating statement lines. Size is arbitrary but large enough for typical(?) use.
    stmt_buf: [65536]u8 = undefined,
    // Cur rent length of valid data in stmt_buf
    stmt_len: usize = 0,
    // File line number where current statement started
    start_line: usize = 0,
    // Active parser coroutine, if any
    coroutine: ?ParserCoroutine = null,
    // Stack for parser coroutine; allocated on demand to avoid reserving for simple statements.
    coroutine_stack: ?[]align(std.heap.page_size_min) u8 = null,

    // Size for parser coroutine stack, which should be enough for typical parsing depth.
    const coroutine_stack_size = 1024 * 1024;

    // Headroom the overflow guard keeps below the parser coroutine's usable stack, matching the
    // one-eighth proportion tasks reserve on their own stacks.
    const coroutine_stack_reserve = coroutine_stack_size / 8;

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

    pub fn deinit(self: *StatementProcessor) void {
        if (self.coroutine_stack) |stack| {
            task_mod.freeTaskStack(stack);
            self.coroutine_stack = null;
        }
    }

    // Feed a line of input. Returns the result of attempting to parse.
    // If ctx is provided, parse-time words will be executed during parsing.
    pub fn feedLine(self: *StatementProcessor, allocator: Allocator, line: []const u8, ctx: ?*Context) Result {
        // Strip only the line terminator. The rest of the line is copied verbatim so the
        // tokenizer's column counter matches the source file; the tokenizer skips inter-token
        // whitespace itself, and multiline string literals keep their source bytes.
        const body = std.mem.trimRight(u8, line, "\r\n");
        const blank = std.mem.trim(u8, body, " \t").len == 0;

        if (blank and self.stmt_len == 0) {
            return .{ .complete = &.{} };
        }

        // Add newline separator if accumulating (preserves comment boundaries)
        if (self.stmt_len > 0 and self.stmt_len < self.stmt_buf.len) {
            self.stmt_buf[self.stmt_len] = '\n';
            self.stmt_len += 1;
        }

        const copy_len = @min(body.len, self.stmt_buf.len - self.stmt_len);
        @memcpy(self.stmt_buf[self.stmt_len..][0..copy_len], body[0..copy_len]);
        self.stmt_len += copy_len;

        // A blank line cannot complete a statement, so don't resume the parser; resuming
        // without a new token would make it treat the input as finished.
        if (blank) {
            return .needs_more_input;
        }

        if (comptime is_freestanding) {
            return self.tryParseDirect(allocator, ctx);
        }

        // Attempt to parse
        if (self.coroutine != null) {
            self.coroutine.?.tokenizer.?.input = self.stmt_buf[0..self.stmt_len];
            self.resumeCoroutine(ctx);
        } else {
            if (self.coroutine_stack == null) {
                self.coroutine_stack = task_mod.allocateTaskStack(coroutine_stack_size) catch return .{ .parse_error = error.OutOfMemory };
            }
            self.coroutine = .{
                .stack_mem = self.coroutine_stack.?,
                .allocator = allocator,
                .ctx = ctx,
                .initial_input = self.stmt_buf[0..self.stmt_len],
            };
            pc_mod.pending_entry_coroutine = &self.coroutine.?;
            pc_mod.initCoroutineContext(&self.coroutine.?);
            self.resumeCoroutine(ctx);
        }

        return self.handleCoroutineReturn();
    }

    /// Resume the parser coroutine with the context's native-stack bounds describing that
    /// coroutine's stack instead of whichever stack the caller is on.
    ///
    /// A compound parse-time word runs inside this resume, and the overflow guard in
    /// `executeResolvedWord` compares `@frameAddress()` against these bounds. A task's bounds
    /// describe a stack the parse-time word never runs on, so leaving them in place reads as
    /// instant exhaustion. The save and restore nest, which an `eval-string` driving a second
    /// processor on the same context relies on.
    fn resumeCoroutine(self: *StatementProcessor, ctx: ?*Context) void {
        const co = &self.coroutine.?;
        const c = ctx orelse {
            co.@"resume"();
            return;
        };

        const saved_high = c.stack_high;
        const saved_limit = c.stack_limit;
        defer {
            c.stack_high = saved_high;
            c.stack_limit = saved_limit;
        }

        // allocateTaskStack lays the region out as [guard page][usable], and the coroutine's
        // entry sp skips the guard page, so the usable span starts one page in.
        const usable_low = @intFromPtr(co.stack_mem.ptr) + std.heap.page_size_min;
        c.stack_high = @intFromPtr(co.stack_mem.ptr) + co.stack_mem.len;
        c.stack_limit = usable_low + coroutine_stack_reserve;

        co.@"resume"();
    }

    /// Handle the result of a coroutine resume, checking for completion or need for more input.
    fn handleCoroutineReturn(self: *StatementProcessor) Result {
        const status = self.coroutine.?.status;
        switch (status) {
            .yielded => return .needs_more_input,
            .completed => {
                const result = self.coroutine.?.result.?;
                self.coroutine = null;
                switch (result) {
                    .success => |instrs| {
                        if (instrs.len == 0 and self.stmt_len > 0 and bufferOnlyHasDocComments(self.stmt_buf[0..self.stmt_len])) {
                            return .needs_more_input;
                        }
                        adjustInstructionLines(instrs, self.start_line);
                        return .{ .complete = instrs };
                    },
                    .parse_error => |err| {
                        if (parser.isIncompleteError(err)) {
                            return .needs_more_input;
                        }
                        return .{ .parse_error = err };
                    },
                }
            },
            .running => unreachable,
        }
    }

    /// Freestanding-only sibling of handleCoroutineReturn: parses the accumulated buffer
    /// directly instead of resuming a suspended coroutine, producing the same three-way Result.
    ///
    /// Restores the stack to its pre-attempt depth on needs-more-input: a still-incomplete
    /// parse-time word (e.g., `method{ ... } [`) can push before hitting incompleteness, and the
    /// next feedLine call reparses from scratch, so an abandoned attempt's pushes must not persist.
    /// Only rolls back when the attempt netted a growth: a parse-time word with full stack access
    /// (e.g. `bind-until`) can also pop pre-existing values, and shrinking to a depth larger than
    /// what's actually left would grow the stack's length past its populated slots.
    fn tryParseDirect(self: *StatementProcessor, allocator: Allocator, ctx: ?*Context) Result {
        const stack_depth_before: ?usize = if (ctx) |c| c.stack.depth() else null;
        var tokenizer = Tokenizer.init(self.stmt_buf[0..self.stmt_len]);
        const instrs = parser.parseTopLevel(allocator, &tokenizer, ctx) catch |err| {
            if (parser.isIncompleteError(err)) {
                if (ctx) |c| if (stack_depth_before) |before| {
                    const after = c.stack.depth();
                    if (after > before) {
                        c.stack.releaseRange(before, after);
                        c.stack.items.shrinkRetainingCapacity(before);
                    }
                };
                return .needs_more_input;
            }
            return .{ .parse_error = err };
        };
        if (instrs.len == 0 and self.stmt_len > 0 and bufferOnlyHasDocComments(self.stmt_buf[0..self.stmt_len])) {
            return .needs_more_input;
        }
        adjustInstructionLines(instrs, self.start_line);
        return .{ .complete = instrs };
    }

    /// Reset buffer after successful execution or fatal error.
    pub fn reset(self: *StatementProcessor) void {
        self.coroutine = null;
        self.stmt_len = 0;
        self.start_line = 0;
    }

    /// Check if currently accumulating input (for continuation prompt).
    pub fn isAccumulating(self: *const StatementProcessor) bool {
        return self.stmt_len > 0;
    }

    /// Return the current accumulated statement text.
    pub fn getStatement(self: *const StatementProcessor) []const u8 {
        return self.stmt_buf[0..self.stmt_len];
    }

    /// Try to parse any remaining buffered content (for EOF handling).
    /// If ctx is provided, parse-time words will be executed during parsing.
    pub fn flush(self: *StatementProcessor, allocator: Allocator, ctx: ?*Context) Result {
        if (self.coroutine != null) {
            // resume without extending input; nextOrYield will see no growth and return null, causing
            // the parser to complete 😩
            self.resumeCoroutine(ctx);
            const result = self.coroutine.?.result.?;
            self.coroutine = null;
            return switch (result) {
                .success => |instrs| .{ .complete = instrs },
                .parse_error => |err| .{ .parse_error = err },
            };
        }

        if (self.stmt_len == 0) {
            return .{ .complete = &.{} };
        }

        // bo active coroutine but buffered content, e.g., doc-comment accumulation followed by EOF(?)
        var tokenizer = Tokenizer.init(self.stmt_buf[0..self.stmt_len]);
        const instrs = parser.parseTopLevel(allocator, &tokenizer, ctx) catch |err| {
            return .{ .parse_error = err };
        };
        adjustInstructionLines(instrs, self.start_line);

        return .{ .complete = instrs };
    }
};

fn adjustInstructionLines(instrs: []const Instruction, line_offset: usize) void {
    if (line_offset == 0) return;
    for (instrs) |*instr| {
        const ptr = @constCast(instr);
        ptr.line += line_offset - 1; // tokenizer starts each statement at line 1
        switch (instr.op) {
            .push_literal => |val| switch (val) {
                .quotation => |nested| adjustInstructionLines(nested.instructions, line_offset),
                else => {},
            },
            else => {},
        }
    }
}

fn bufferOnlyHasDocComments(buf: []const u8) bool {
    var tokenizer = Tokenizer.init(buf);
    var saw_doc_comment = false;
    while (tokenizer.next()) |tok| {
        switch (tok.kind) {
            .doc_comment => saw_doc_comment = true,
            .comment, .newline => {},
            else => return false,
        }
    }
    return saw_doc_comment;
}

// =============================================================================
// Tests
// =============================================================================

test "StatementProcessor complete input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    const result = processor.feedLine(arena.allocator(), "1 2 +", null);
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
    defer processor.deinit();

    // First line opens a quotation
    processor.trackLine(2);
    switch (processor.feedLine(arena.allocator(), "[", null)) {
        .needs_more_input => {},
        else => return error.UnexpectedResult,
    }

    try std.testing.expect(processor.isAccumulating());

    // Second line closes it
    processor.trackLine(3);
    switch (processor.feedLine(arena.allocator(), "1 2 + ]", null)) {
        .complete => |instrs| {
            try std.testing.expectEqual(@as(usize, 1), instrs.len);
            try std.testing.expectEqual(@as(usize, 2), instrs[0].line);
        },
        else => return error.UnexpectedResult,
    }
}

test "StatementProcessor preserves continuation-line columns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    processor.trackLine(1);
    switch (processor.feedLine(arena.allocator(), "[", null)) {
        .needs_more_input => {},
        else => return error.UnexpectedResult,
    }

    // The `1` sits at source column 3; the pre-fix trim reported column 1.
    processor.trackLine(2);
    switch (processor.feedLine(arena.allocator(), "  1 ]", null)) {
        .complete => |instrs| {
            try std.testing.expectEqual(@as(usize, 1), instrs.len);
            const nested = instrs[0].op.push_literal.quotation.instructions;
            try std.testing.expectEqual(@as(usize, 1), nested.len);
            try std.testing.expectEqual(@as(usize, 3), nested[0].column);
        },
        else => return error.UnexpectedResult,
    }
}

test "StatementProcessor empty line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    // Empty line with no accumulation returns empty complete
    switch (processor.feedLine(arena.allocator(), "   ", null)) {
        .complete => |instrs| {
            try std.testing.expectEqual(@as(usize, 0), instrs.len);
        },
        else => return error.UnexpectedResult,
    }
}

test "StatementProcessor only accumulates doc-comment-only buffer" {
    try std.testing.expect(bufferOnlyHasDocComments("\\\\ doc"));
    try std.testing.expect(bufferOnlyHasDocComments("\\\\ doc\n\\ ordinary comment"));
    try std.testing.expect(!bufferOnlyHasDocComments("\\\\ doc\nuse \"testing\" ;"));
    try std.testing.expect(!bufferOnlyHasDocComments("\\ ordinary comment"));
}

test "StatementProcessor flush" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    // Feed incomplete input
    _ = processor.feedLine(arena.allocator(), "[", null);

    // Flush should return parse error for incomplete input
    switch (processor.flush(arena.allocator(), null)) {
        .parse_error => {},
        else => return error.UnexpectedResult,
    }
}

test "StatementProcessor adjusts lines after trackLine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    processor.trackLine(8);
    const result = processor.feedLine(arena.allocator(), "foo: ( -- ) [ 1 ] ;", null);
    switch (result) {
        .complete => |instrs| {
            try std.testing.expect(instrs.len > 0);
            try std.testing.expectEqual(@as(usize, 8), instrs[0].line);
        },
        else => return error.UnexpectedResult,
    }
}
