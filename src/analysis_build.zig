//! The build setup for an analysis child.
//!
//! `1z check`, `onez_check`, and the language server's per-document analysis build their child this
//! way.
//!
//! An analysis child is built once, analyzed, and torn down whole. Nothing here restores state,
//! because there is nothing to restore it to.

const std = @import("std");
const Context = @import("context.zig").Context;
const statement = @import("statement.zig");
const StatementProcessor = statement.StatementProcessor;
const SplitScan = statement.SplitScan;

/// Point a freshly built analysis child at the document it analyzes.
///
/// One local frame serves as the document frame, the import frame, and the durable floor. One
/// pragma frame holds the document's pragmas. The child enters check mode and stays in it. The
/// check dispatch log is not opened: an arm the document registers lands in the child's own
/// dispatch table, which dies with the child.
///
/// `source` and `source_dir` are copied onto the child's arena. A definition whose body carries
/// no source stamp takes `current_source` as its file, so the child must own what it names.
///
/// A failure leaves the child torn down by its own `deinit`.
pub fn begin(ctx: *Context, source: []const u8, source_dir: ?[]const u8) !void {
    std.debug.assert(ctx.in_analysis and ctx.owns_loads);

    const arena = ctx.arena.allocator();
    const owned_source = try arena.dupe(u8, source);
    const owned_dir: ?[]const u8 = if (source_dir) |dir| try arena.dupe(u8, dir) else null;

    try ctx.pushLocalFrame();
    try ctx.pushPragmaFrame();

    ctx.enterCheckMode();
    ctx.current_source = owned_source;
    ctx.current_source_dir = owned_dir;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    ctx.durable_frame_floor = ctx.import_frame_index;
}

/// One parse error, with the parser's own words for it.
///
/// The strings live on the child's arena, so they last as long as the child does.
pub const ParseFailure = struct {
    /// The parser's error name, such as `UnmatchedOpenBracket`.
    error_type: []const u8,
    message: ?[]const u8,
    /// The 1-based file line of the opening bracket or quote when the parser names one, and the
    /// line the error was raised on otherwise.
    line: usize,
};

/// The second and third passes of a build over text that failed to parse.
pub const Recovery = struct {
    /// Statement splits are enabled from this 1-based line onward.
    split_from: usize,
    /// From this line onward a split may fire inside what looks like an open string.
    guard_off_from: ?usize = null,
};

/// What one pass of `runCheckStatements` found. The server reads it to decide whether another
/// pass is needed and which one.
pub const Outcome = struct {
    /// Every parse error the pass met. A pass without recovery stops at the first.
    failures: []const ParseFailure = &.{},
    /// The line the first failed statement started on. Set only by a pass without recovery.
    failed_start_line: ?usize = null,
    /// The line an open string at the end of the text began on. Set only by a pass with recovery.
    open_string_line: ?usize = null,
};

/// Run a document's check statements on `ctx`: its definitions and its `"name" load reexport`
/// lines.
///
/// The text goes through `StatementProcessor` a line at a time, the way `1z check` and a module
/// load feed theirs, so each statement is parsed and tested on its own. Parsing the whole document
/// as one statement would let any top-level code beside a definition hide the definition.
///
/// Without `recovery` the pass stops at the first parse error, the way `1z check` does. With it,
/// a pass reads on past each parse error. A statement still accumulating is split off when the next
/// line starts at column zero, and the error of each broken statement is kept. After an error that
/// no further line can complete, the pass skips to the next line that could start a statement.
///
/// A statement's own error is dropped. Running out of memory is not, because the child would then
/// be missing definitions that its text declares, and nothing would say so.
pub fn runCheckStatements(ctx: *Context, text: []const u8, recovery: ?Recovery) error{OutOfMemory}!Outcome {
    const saved_line_offset = ctx.parse_line_offset;
    defer ctx.parse_line_offset = saved_line_offset;

    var run: Run = .{ .ctx = ctx, .recovering = recovery != null };
    defer run.processor.deinit();

    var scan: SplitScan = .{};
    var skipping = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var file_line: usize = 0;
    while (true) {
        const next_line = lines.next() orelse {
            _ = try run.flushBuffered(file_line, .end_of_text);
            return run.outcome(if (recovery != null and scan.in_string) scan.open_line else null);
        };
        file_line += 1;

        if (recovery) |r| {
            const enabled = file_line >= r.split_from;
            if (enabled) {
                const guard_off = if (r.guard_off_from) |from| file_line >= from else false;
                const open = run.processor.isAccumulating() or skipping;
                const splits = open and (guard_off or !scan.in_string) and
                    StatementProcessor.startsNewStatement(next_line) and
                    !run.processor.holdsOnlyDocComments();

                if (splits) {
                    if (run.processor.isAccumulating()) _ = try run.flushBuffered(file_line, .split);
                    run.processor.reset();
                    skipping = false;
                    scan.reset();
                } else if (skipping) {
                    scan.feed(next_line, file_line);
                    continue;
                } else if (!run.processor.isAccumulating()) {
                    scan.reset();
                }

                scan.feed(next_line, file_line);
            }
        }

        // Re-analysis drops whatever a statement raises, and the drop must be complete: the
        // residue would otherwise reach the next statement and every later one. The bracket
        // covers the parse as well as the execution, since a parse-time word's failure clears to
        // zero rather than to an enclosing shield's mark.
        const saved_error_state = ctx.saveErrorState();
        defer ctx.restoreErrorState(saved_error_state);

        ctx.parse_diagnostics = null;
        run.processor.trackLine(file_line);
        if (run.processor.start_line > 0) ctx.parse_line_offset = run.processor.start_line - 1;

        const result = run.processor.feedLine(ctx.quotationAllocator(), next_line, ctx);
        switch (try run.settle(result, file_line, .line)) {
            .go_on => {},
            .stop => return run.outcome(null),
            .skip => skipping = true,
        }
    }
}

/// The state one pass of `runCheckStatements` carries from line to line.
const Run = struct {
    ctx: *Context,
    recovering: bool,
    processor: StatementProcessor = .{},
    failures: std.ArrayListUnmanaged(ParseFailure) = .{},
    failed_start_line: ?usize = null,

    const Source = enum { line, split, end_of_text };
    const Next = enum { go_on, stop, skip };

    fn outcome(self: *const Run, open_string_line: ?usize) Outcome {
        return .{
            .failures = self.failures.items,
            .failed_start_line = self.failed_start_line,
            .open_string_line = open_string_line,
        };
    }

    /// Flush the incomplete statement to capture its error. Its own bracket keeps the error's
    /// residue from reaching the line that follows.
    fn flushBuffered(self: *Run, file_line: usize, source: Source) error{OutOfMemory}!Next {
        const saved_error_state = self.ctx.saveErrorState();
        defer self.ctx.restoreErrorState(saved_error_state);

        self.ctx.parse_diagnostics = null;
        const result = self.processor.flush(self.ctx.quotationAllocator(), self.ctx);

        return self.settle(result, file_line, source);
    }

    fn settle(self: *Run, result: StatementProcessor.Result, file_line: usize, source: Source) error{OutOfMemory}!Next {
        switch (result) {
            .needs_more_input => return .go_on,
            .parse_error => |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;

                try self.record(err, file_line, source);
                if (self.failed_start_line == null) self.failed_start_line = self.processor.start_line;

                if (!self.recovering) return .stop;

                self.processor.reset();
                return if (source == .line) .skip else .go_on;
            },
            .complete => |instrs| {
                if (instrs.len > 0 and Context.isCheckStatement(instrs)) {
                    self.ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                    };
                }
                self.processor.reset();
                return .go_on;
            },
        }
    }

    /// Keep the parser's diagnostic before the statement's error-state bracket discards it.
    fn record(self: *Run, err: anyerror, file_line: usize, source: Source) error{OutOfMemory}!void {
        const arena = self.ctx.arena.allocator();
        const start = self.processor.start_line;

        const diag = self.ctx.parse_diagnostics;
        self.ctx.parse_diagnostics = null;

        const error_type = if (diag) |d| d.error_type else null;
        const message = if (diag) |d| d.message else null;
        const opening = if (diag) |d| d.opening_line else null;

        const line = if (opening) |ol|
            (if (start > 0) ol + start - 1 else ol)
        else if (source == .line) file_line else start;

        try self.failures.append(arena, .{
            .error_type = if (error_type) |t| try arena.dupe(u8, t) else @errorName(err),
            .message = if (message) |m| try arena.dupe(u8, m) else null,
            .line = line,
        });
    }
};

fn writeModule(tmp: *std.testing.TmpDir, name: []const u8, source: []const u8) ![]u8 {
    try tmp.dir.writeFile(.{ .sub_path = name, .data = source });
    return tmp.dir.realpathAlloc(std.testing.allocator, name);
}

test "begin: one frame is the document, import, and floor frame, and the child owns its source" {
    var root = Context.init(std.testing.allocator);
    defer root.deinit();

    var child = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer child.deinit();

    var uri_buf = "file:///work/doc.1z".*;
    var dir_buf = "/work".*;

    try begin(&child, &uri_buf, &dir_buf);

    try std.testing.expectEqual(@as(usize, 1), child.local_frames.items.len);
    try std.testing.expectEqual(@as(?usize, 0), child.import_frame_index);
    try std.testing.expectEqual(@as(?usize, 0), child.durable_frame_floor);
    try std.testing.expect(child.check_mode);

    uri_buf[0] = 'X';
    dir_buf[0] = 'X';
    try std.testing.expectEqualStrings("file:///work/doc.1z", child.current_source);
    try std.testing.expectEqualStrings("/work", child.current_source_dir.?);
}

test "analysis children leave no key of their arena in the root's stores" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dep = try writeModule(&tmp, "dep.1z", "dep-point: struct{ x y } ;\ndep-double: ( n -- n ) [ 2 * ] ;\n");
    defer std.testing.allocator.free(dep);

    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    const text = try std.fmt.allocPrint(
        std.testing.allocator,
        "use \"{s}\" ;\nlocal-add: ( n -- n ) [ dep-double 1 + ] ;\nlocal-each: ( -- ) [ [ 1 ] call drop ] ;\n",
        .{dep},
    );
    defer std.testing.allocator.free(text);

    var round: usize = 0;
    while (round < 6) : (round += 1) {
        // The child stays alive through the checks. A key left on its arena would dangle only after
        // `deinit`, and by then the address could be reused and the stale entry go unseen.
        var child = try Context.initChild(std.testing.allocator, &root, .analysis);
        defer child.deinit();

        try begin(&child, "doc.1z", dir);
        try std.testing.expectEqual(@as(usize, 0), (try runCheckStatements(&child, text, null)).failures.len);

        try std.testing.expect(child.body_stores.anyKeyOnArena(child.arena));
        try std.testing.expect(!root.body_stores.anyKeyOnArena(child.arena));

        try std.testing.expectEqual(@as(u32, 1), child.module_cache_value.map.count());
        try std.testing.expectEqual(@as(u32, 0), root.module_cache_value.map.count());
    }
}

test "a redefined prelude const is accepted on a child as the root accepts it" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var child = try Context.initChild(std.testing.allocator, &root, .analysis_reusing);
    defer child.deinit();

    try begin(&child, "doc.1z", null);
    const outcome = try runCheckStatements(&child, "fixnum: ( -- x ) [ 0 ] ;\nafter-fixnum: ( -- x ) [ 1 ] ;\n", null);
    try std.testing.expectEqual(@as(usize, 0), outcome.failures.len);

    try std.testing.expect(child.local_frames.items[0].contains("fixnum"));
    try std.testing.expect(child.local_frames.items[0].contains("after-fixnum"));
}

/// A prelude root, and a fresh analysis child that has run `text` under `recovery`.
const Recovered = struct {
    root: Context,
    child: Context,
    outcome: Outcome,

    fn start(self: *Recovered, text: []const u8, recovery: ?Recovery) !void {
        self.root = Context.initWithPrelude(std.testing.allocator);
        errdefer self.root.deinit();

        self.child = try Context.initChild(std.testing.allocator, &self.root, .analysis);
        errdefer self.child.deinit();

        try begin(&self.child, "doc.1z", null);
        self.outcome = try runCheckStatements(&self.child, text, recovery);
    }

    fn stop(self: *Recovered) void {
        self.child.deinit();
        self.root.deinit();
    }

    fn defines(self: *Recovered, name: []const u8) bool {
        return self.child.local_frames.items[0].contains(name);
    }
};

test "a pass without recovery stops at the first parse error and reports where its statement began" {
    var run: Recovered = undefined;
    try run.start("first: ( -- x ) [ 1 ] ;\n[ open\nlater: ( -- x ) [ 1 ] ;\n", null);
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures.len);
    try std.testing.expectEqual(@as(?usize, 2), run.outcome.failed_start_line);
    try std.testing.expectEqualStrings("UnmatchedOpenBracket", run.outcome.failures[0].error_type);
    try std.testing.expectEqual(@as(usize, 2), run.outcome.failures[0].line);
    try std.testing.expect(run.defines("first"));
    try std.testing.expect(!run.defines("later"));
}

test "a split at a column-zero line keeps the definition below an unclosed bracket" {
    var run: Recovered = undefined;
    try run.start("first: ( -- x ) [ 1 ] ;\n[ open\nlater: ( -- x ) [ 1 ] ;\n", .{ .split_from = 2 });
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures.len);
    try std.testing.expectEqualStrings("UnmatchedOpenBracket", run.outcome.failures[0].error_type);
    try std.testing.expectEqual(@as(usize, 2), run.outcome.failures[0].line);
    try std.testing.expect(run.defines("first"));
    try std.testing.expect(run.defines("later"));
}

test "the failure sits at the opening bracket, not at the statement start or the split line" {
    var run: Recovered = undefined;
    try run.start("broken: ( -- x ) [\n  1\n  [ 2\nlater: ( -- x ) [ 1 ] ;\n", .{ .split_from = 1 });
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures.len);
    try std.testing.expectEqual(@as(usize, 3), run.outcome.failures[0].line);
    try std.testing.expect(run.defines("later"));
}

test "a closer at column zero does not split" {
    var run: Recovered = undefined;
    try run.start("foo: ( -- x ) [\n  1\n] ;\n", .{ .split_from = 1 });
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 0), run.outcome.failures.len);
    try std.testing.expect(run.defines("foo"));
}

test "a comment and a bare backslash at column zero do not split" {
    var run: Recovered = undefined;
    try run.start("foo: ( -- x ) [\n  1\n\\ a note\n\\\n] ;\n", .{ .split_from = 1 });
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 0), run.outcome.failures.len);
    try std.testing.expect(run.defines("foo"));
}

test "a doc comment at column zero splits, and its doc attaches to the next definition" {
    var run: Recovered = undefined;
    try run.start("[ open\n\\\\ Documents later.\nlater: ( -- x ) [ 1 ] ;\n", .{ .split_from = 1 });
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures.len);
    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures[0].line);

    const def = run.child.lookupWord("later") orelse return error.TestUnexpectedResult;
    try std.testing.expect(def.doc != null);
    try std.testing.expect(std.mem.indexOf(u8, def.doc.?, "Documents later.") != null);
}

test "a doc comment waiting for its definition is not split from it" {
    var run: Recovered = undefined;
    try run.start("\\\\ Documents later.\nlater: ( -- x ) [ 1 ] ;\n", .{ .split_from = 1 });
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 0), run.outcome.failures.len);
    try std.testing.expect(run.defines("later"));
}

test "a column-zero line inside an open string does not split" {
    var run: Recovered = undefined;
    try run.start(
        "[ open\nlater: ( -- s ) [ \"first\nsecond: ( -- x ) [ 1 ] ;\nthird\" ] ;\n",
        .{ .split_from = 1 },
    );
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures.len);
    try std.testing.expectEqual(@as(?usize, null), run.outcome.open_string_line);
    try std.testing.expect(run.defines("later"));
    try std.testing.expect(!run.defines("second"));
}

test "after a hard error the pass skips to the next line that could start a statement" {
    var run: Recovered = undefined;
    try run.start("] stray\n  ]\n  ]\nlater: ( -- x ) [ 1 ] ;\n", .{ .split_from = 1 });
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures.len);
    try std.testing.expectEqualStrings("UnmatchedCloseBracket", run.outcome.failures[0].error_type);
    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures[0].line);
    try std.testing.expect(run.defines("later"));
}

test "an unclosed quote ends the second pass inside a string, and the third pass splits past it" {
    const text = "a: ( -- x ) [ 1 ] ;\nb: ( -- s ) [ \"oops ] ;\nc: ( -- x ) [ 2 ] ;\n";

    var first: Recovered = undefined;
    try first.start(text, null);
    defer first.stop();
    try std.testing.expectEqual(@as(?usize, 2), first.outcome.failed_start_line);

    var second: Recovered = undefined;
    try second.start(text, .{ .split_from = 2 });
    defer second.stop();
    try std.testing.expectEqual(@as(?usize, 2), second.outcome.open_string_line);
    try std.testing.expect(!second.defines("c"));

    var third: Recovered = undefined;
    try third.start(text, .{ .split_from = 2, .guard_off_from = 2 });
    defer third.stop();
    try std.testing.expectEqual(@as(usize, 1), third.outcome.failures.len);
    try std.testing.expectEqualStrings("UnmatchedOpenQuote", third.outcome.failures[0].error_type);
    try std.testing.expectEqual(@as(usize, 2), third.outcome.failures[0].line);
    try std.testing.expect(third.defines("a"));
    try std.testing.expect(third.defines("c"));
}

test "a statement past the buffer is a parse error naming the limit and the line" {
    const long_body = try std.testing.allocator.alloc(u8, statement.max_statement_len);
    defer std.testing.allocator.free(long_body);
    @memset(long_body, ' ');

    const text = try std.fmt.allocPrint(std.testing.allocator, "[\n{s}\n", .{long_body});
    defer std.testing.allocator.free(text);

    var run: Recovered = undefined;
    try run.start(text, null);
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures.len);
    try std.testing.expectEqualStrings("StatementTooLong", run.outcome.failures[0].error_type);

    const message = run.outcome.failures[0].message orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, message, "65536") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "line 2") != null);
}

test "a statement past the buffer inside a body is skipped, and the pass leaves no parse state behind" {
    const blank_lines = try std.testing.allocator.alloc(u8, 17 * 4001);
    defer std.testing.allocator.free(blank_lines);

    var at: usize = 0;
    while (at < blank_lines.len) : (at += 4001) {
        @memset(blank_lines[at..][0..4000], ' ');
        blank_lines[at + 4000] = '\n';
    }

    const text = try std.fmt.allocPrint(
        std.testing.allocator,
        "foo: ( -- x ) [\n{s}later: ( -- x ) [ 1 ] ;\n",
        .{blank_lines},
    );
    defer std.testing.allocator.free(text);

    var run: Recovered = undefined;
    try run.start(text, .{ .split_from = 1 });
    defer run.stop();

    try std.testing.expectEqual(@as(usize, 1), run.outcome.failures.len);
    try std.testing.expectEqualStrings("StatementTooLong", run.outcome.failures[0].error_type);
    try std.testing.expect(run.defines("later"));
    try std.testing.expect(run.child.parse_body_effect == null);
    try std.testing.expect(!run.child.parse_body_start);
}

test "a stray brace or parenthesis skips to the next line that could start a statement" {
    var brace: Recovered = undefined;
    try brace.start("} stray\n  ]\n  )\nlater: ( -- x ) [ 1 ] ;\n", .{ .split_from = 1 });
    defer brace.stop();

    try std.testing.expectEqual(@as(usize, 1), brace.outcome.failures.len);
    try std.testing.expectEqualStrings("UnmatchedCloseBrace", brace.outcome.failures[0].error_type);
    try std.testing.expect(brace.defines("later"));

    var paren: Recovered = undefined;
    try paren.start(") stray\n  }\n  ]\nlater: ( -- x ) [ 1 ] ;\n", .{ .split_from = 1 });
    defer paren.stop();

    try std.testing.expectEqual(@as(usize, 1), paren.outcome.failures.len);
    try std.testing.expectEqualStrings("UnmatchedCloseParen", paren.outcome.failures[0].error_type);
    try std.testing.expect(paren.defines("later"));
}

test "a trailing backslash inside a string does not hide the quote that closes it" {
    var run: Recovered = undefined;
    try run.start(
        "[ open\nb: ( -- s ) [ \"abc\\\n\" ] ;\n[ open again\nlater: ( -- x ) [ 1 ] ;\n",
        .{ .split_from = 1 },
    );
    defer run.stop();

    try std.testing.expectEqual(@as(?usize, null), run.outcome.open_string_line);
    try std.testing.expectEqual(@as(usize, 2), run.outcome.failures.len);
    try std.testing.expect(run.defines("later"));
}
