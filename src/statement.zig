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

/// The most bytes one statement may hold, newlines between its lines included.
pub const max_statement_len = 65536;

/// StatementProcessor handles accumulating multi-line input and parsing.
/// Used by both REPL and batch modes to share the core logic.
pub const StatementProcessor = struct {
    // Buffer for accumulating statement lines. Size is arbitrary but large enough for typical(?) use.
    // A statement past it raises a parse error instead of being clipped.
    stmt_buf: [max_statement_len]u8 = undefined,
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

    /// Whether the buffered statement begins at the source's very first byte.
    ///
    /// Each statement is tokenized as its own input, so the tokenizer cannot tell the file's first
    /// byte from a later statement's on its own. A caller that never calls `trackLine` leaves
    /// `start_line` at zero, and is feeding a fragment rather than a file.
    fn atSourceStart(self: *const StatementProcessor) bool {
        return self.start_line == 1;
    }

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

        // A newline separates accumulated lines, which preserves comment boundaries.
        const separator: usize = if (self.stmt_len > 0) 1 else 0;
        if (self.stmt_len + separator + body.len > self.stmt_buf.len) {
            return self.statementTooLong(allocator, ctx, body.len);
        }

        if (separator == 1) {
            self.stmt_buf[self.stmt_len] = '\n';
            self.stmt_len += 1;
        }

        @memcpy(self.stmt_buf[self.stmt_len..][0..body.len], body);
        self.stmt_len += body.len;

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
                .at_source_start = self.atSourceStart(),
            };
            pc_mod.pending_entry_coroutine = &self.coroutine.?;
            pc_mod.initCoroutineContext(&self.coroutine.?);
            self.resumeCoroutine(ctx);
        }

        return self.handleCoroutineReturn();
    }

    /// Refuse a line that would push the buffered statement past the buffer.
    ///
    /// The buffer is left as it was. A caller that keeps feeding after the error resets it.
    ///
    /// A parse suspended on the buffered lines is resumed to its end first. Its frames restore
    /// fields of the context on the way out, and abandoning it would leave those fields stale.
    fn statementTooLong(self: *StatementProcessor, allocator: Allocator, ctx: ?*Context, line_len: usize) Result {
        if (self.coroutine != null) {
            self.resumeCoroutine(ctx);
            self.coroutine = null;
        }

        const c = ctx orelse return .{ .parse_error = parser.ParseError.StatementTooLong };

        const buffered_lines = if (self.stmt_len > 0) std.mem.count(u8, self.getStatement(), "\n") + 1 else 0;
        const message: []const u8 = blk: {
            if (self.start_line == 0) {
                break :blk std.fmt.allocPrint(
                    allocator,
                    "a statement may not exceed {d} bytes, and a line of {d} bytes does not fit",
                    .{ max_statement_len, line_len },
                ) catch "a statement may not exceed its byte limit";
            }
            break :blk std.fmt.allocPrint(
                allocator,
                "a statement may not exceed {d} bytes, and this one passes that at line {d}",
                .{ max_statement_len, self.start_line + buffered_lines },
            ) catch "a statement may not exceed its byte limit";
        };

        c.parse_diagnostics = .{
            .error_type = "StatementTooLong",
            .message = message,
        };

        return .{ .parse_error = parser.ParseError.StatementTooLong };
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
        const saved_floor = c.stack_floor;
        const saved_low = c.stack_low;
        const saved_growth = c.stack_growth;
        const saved_grown = c.stack_grown;
        defer {
            c.stack_high = saved_high;
            c.stack_limit = saved_limit;
            c.stack_floor = saved_floor;
            c.stack_low = saved_low;
            c.stack_growth = saved_growth;
            c.stack_grown = saved_grown;
        }

        // The parser's stack cannot grow. Left in place, a task's growth would commit the task's
        // region and arm the guard at an address on a stack the parse is not running on. A growth
        // already taken describes the task's stack too.
        c.stack_growth = null;
        c.stack_grown = null;

        // allocateTaskStack lays the region out as [guard page][usable], and the coroutine's
        // entry sp skips the guard page, so the usable span starts one page in.
        const usable_low = @intFromPtr(co.stack_mem.ptr) + std.heap.page_size_min;
        c.stack_high = @intFromPtr(co.stack_mem.ptr) + co.stack_mem.len;
        c.stack_limit = usable_low + coroutine_stack_reserve;
        c.stack_floor = c.stack_limit;
        c.stack_low = usable_low;

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
        tokenizer.at_source_start = self.atSourceStart();
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

    /// Whether the buffered text is only doc comments, which wait for the definition they document.
    pub fn holdsOnlyDocComments(self: *const StatementProcessor) bool {
        return self.stmt_len > 0 and bufferOnlyHasDocComments(self.stmt_buf[0..self.stmt_len]);
    }

    /// Whether `line` can begin a new top-level statement while another is still accumulating.
    ///
    /// A body line is indented, so a line at column zero begins a statement. A closer or a plain
    /// comment continues the statement above it. A doc comment begins one, so its doc attaches to
    /// the definition after it.
    pub fn startsNewStatement(line: []const u8) bool {
        const body = std.mem.trimRight(u8, line, "\r\n");
        if (body.len == 0) return false;

        switch (body[0]) {
            ' ', '\t', ']', '}', ')', ';' => return false,
            '\\' => {
                if (body.len >= 2 and body[1] == '\\' and (body.len == 2 or isBlank(body[2]))) return true;
                if (body.len == 1 or isBlank(body[1])) return false;
                return true;
            },
            else => return true,
        }
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
        tokenizer.at_source_start = self.atSourceStart();
        const instrs = parser.parseTopLevel(allocator, &tokenizer, ctx) catch |err| {
            return .{ .parse_error = err };
        };
        adjustInstructionLines(instrs, self.start_line);

        return .{ .complete = instrs };
    }
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Tracks whether the text fed so far ends inside an open string, the way the tokenizer reads it.
///
/// A split must never fire inside a string, since a line at column zero there is string content.
/// The scan keeps its state from line to line, so a long statement is read once and not again on
/// every line. A quote opens a string only at the start of a token, and a comment hides quotes.
pub const SplitScan = struct {
    in_string: bool = false,
    /// The file line the open string began on. Meaningful only while `in_string`.
    open_line: usize = 0,

    pub fn reset(self: *SplitScan) void {
        self.* = .{};
    }

    pub fn feed(self: *SplitScan, line: []const u8, file_line: usize) void {
        const body = std.mem.trimRight(u8, line, "\r\n");
        if (file_line == 1 and std.mem.startsWith(u8, body, "#!")) return;

        var i: usize = 0;
        while (i < body.len) {
            if (self.in_string) {
                // A trailing backslash pairs with the newline that joins the buffered lines, so it
                // escapes nothing on the next line.
                switch (body[i]) {
                    '\\' => i += 2,
                    '"' => {
                        self.in_string = false;
                        i += 1;
                    },
                    else => i += 1,
                }
                continue;
            }

            const c = body[i];
            if (isBlank(c)) {
                i += 1;
                continue;
            }

            if (c == '\\') {
                const rest = body[i + 1 ..];
                const plain = rest.len == 0 or isBlank(rest[0]);
                const doc = rest.len >= 1 and rest[0] == '\\' and (rest.len == 1 or isBlank(rest[1]));
                if (plain or doc) return;
            }

            if (c == '"') {
                self.in_string = true;
                self.open_line = file_line;
                i += 1;
                continue;
            }

            while (i < body.len and !isBlank(body[i])) i += 1;
        }
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

/// Callers reach this only when the buffer parsed to no instructions, so the tokenizer's default
/// `at_source_start` cannot diverge from the statement's: a buffer whose leading `#!` was read as a
/// word would have produced one.
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

test "startsNewStatement follows the column-zero rules" {
    const starts = StatementProcessor.startsNewStatement;

    try std.testing.expect(starts("word: ( -- ) [ ] ;"));
    try std.testing.expect(starts("use \"testing\" ;"));
    try std.testing.expect(starts("\\\\ doc line"));
    try std.testing.expect(starts("\\\\"));
    try std.testing.expect(starts("\\word"));

    try std.testing.expect(!starts(""));
    try std.testing.expect(!starts("   "));
    try std.testing.expect(!starts("  indented"));
    try std.testing.expect(!starts("\tindented"));
    try std.testing.expect(!starts("] closer"));
    try std.testing.expect(!starts("}"));
    try std.testing.expect(!starts(")"));
    try std.testing.expect(!starts(";"));
    try std.testing.expect(!starts("\\ comment"));
    try std.testing.expect(!starts("\\"));
}

test "SplitScan tracks an open string across lines" {
    var scan: SplitScan = .{};

    scan.feed("a: [ \"open", 3);
    try std.testing.expect(scan.in_string);
    try std.testing.expectEqual(@as(usize, 3), scan.open_line);

    scan.feed("still inside \\\" the string", 4);
    try std.testing.expect(scan.in_string);

    scan.feed("closed\" drop", 5);
    try std.testing.expect(!scan.in_string);
}

test "SplitScan ignores quotes in comments and inside words" {
    var scan: SplitScan = .{};

    scan.feed("word \\ a comment with \"a quote", 1);
    try std.testing.expect(!scan.in_string);

    scan.feed("\\\\ a doc with \"a quote", 2);
    try std.testing.expect(!scan.in_string);

    scan.feed("it\"s a word", 3);
    try std.testing.expect(!scan.in_string);

    scan.feed("\"closed\" and \"open", 4);
    try std.testing.expect(scan.in_string);
}

test "SplitScan reads a trailing backslash as escaping only the line break" {
    var scan: SplitScan = .{};

    scan.feed("\"ends with a backslash\\", 1);
    try std.testing.expect(scan.in_string);

    scan.feed("\" closes the string", 2);
    try std.testing.expect(!scan.in_string);

    scan.feed("\"again\\", 3);
    scan.feed("", 4);
    try std.testing.expect(scan.in_string);

    scan.feed("\"", 5);
    try std.testing.expect(!scan.in_string);
}

test "StatementProcessor raises a parse error past the statement buffer and leaves the buffer intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    processor.trackLine(10);
    switch (processor.feedLine(arena.allocator(), "[", null)) {
        .needs_more_input => {},
        else => return error.UnexpectedResult,
    }

    const too_long = try arena.allocator().alloc(u8, max_statement_len);
    @memset(too_long, 'x');

    switch (processor.feedLine(arena.allocator(), too_long, null)) {
        .parse_error => |err| try std.testing.expectEqual(parser.ParseError.StatementTooLong, err),
        else => return error.UnexpectedResult,
    }

    try std.testing.expectEqualStrings("[", processor.getStatement());
}

test "StatementProcessor unwinds a suspended parse when a line overflows the buffer" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    processor.trackLine(1);
    switch (processor.feedLine(arena.allocator(), "foo: ( -- x ) [", &ctx)) {
        .needs_more_input => {},
        else => return error.UnexpectedResult,
    }
    try std.testing.expect(ctx.parse_body_effect != null);

    const too_long = try arena.allocator().alloc(u8, max_statement_len);
    @memset(too_long, 'x');

    switch (processor.feedLine(arena.allocator(), too_long, &ctx)) {
        .parse_error => |err| try std.testing.expectEqual(parser.ParseError.StatementTooLong, err),
        else => return error.UnexpectedResult,
    }

    try std.testing.expect(processor.coroutine == null);
    try std.testing.expect(ctx.parse_body_effect == null);
    try std.testing.expect(!ctx.parse_body_start);
    try std.testing.expectEqualStrings("StatementTooLong", ctx.parse_diagnostics.?.error_type.?);
}

test "StatementProcessor accepts a statement that exactly fills the buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    const fills = try arena.allocator().alloc(u8, max_statement_len - 2);
    @memset(fills, ' ');

    switch (processor.feedLine(arena.allocator(), "[", null)) {
        .needs_more_input => {},
        else => return error.UnexpectedResult,
    }
    switch (processor.feedLine(arena.allocator(), fills, null)) {
        .needs_more_input => {},
        else => return error.UnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, max_statement_len), processor.stmt_len);
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
