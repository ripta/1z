//! The build setup for an analysis child.
//!
//! `1z check` and the language server's per-document analysis build their child this way.
//! `onez_check` still runs on its root context and will move here.
//!
//! An analysis child is built once, analyzed, and torn down whole. Nothing here restores state,
//! because there is nothing to restore it to.

const std = @import("std");
const Context = @import("context.zig").Context;
const StatementProcessor = @import("statement.zig").StatementProcessor;

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

/// Run a document's check statements on `ctx`: its definitions and its `"name" load reexport`
/// lines. Returns the 1-based line a parse error stopped on, or null when the whole document parsed.
///
/// The text goes through `StatementProcessor` a line at a time, the way `1z check` and a module
/// load feed theirs, so each statement is parsed and tested on its own. Parsing the whole document
/// as one statement would let any top-level code beside a definition hide the definition.
///
/// A statement's own error is dropped. Running out of memory is not, because the child would then
/// be missing definitions that its text declares, and nothing would say so.
pub fn runCheckStatements(ctx: *Context, text: []const u8) error{OutOfMemory}!?usize {
    const saved_line_offset = ctx.parse_line_offset;
    defer ctx.parse_line_offset = saved_line_offset;

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    var file_line: usize = 0;
    while (true) {
        // Re-analysis drops whatever a statement raises, and the drop must be complete: the
        // residue would otherwise reach the next statement and every later one. The bracket
        // covers the parse as well as the execution, since a parse-time word's failure clears to
        // zero rather than to an enclosing shield's mark.
        const saved_error_state = ctx.saveErrorState();
        defer ctx.restoreErrorState(saved_error_state);

        const next_line = lines.next();
        const result = if (next_line) |line| blk: {
            file_line += 1;
            processor.trackLine(file_line);
            if (processor.start_line > 0) ctx.parse_line_offset = processor.start_line - 1;
            break :blk processor.feedLine(ctx.quotationAllocator(), line, ctx);
        } else processor.flush(ctx.quotationAllocator(), ctx);

        switch (result) {
            .needs_more_input => {},
            .parse_error => |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return if (next_line != null) file_line else processor.start_line;
            },
            .complete => |instrs| {
                if (instrs.len > 0 and Context.isCheckStatement(instrs)) {
                    ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                    };
                }
                processor.reset();
            },
        }

        if (next_line == null) return null;
    }
}

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
        try std.testing.expectEqual(@as(?usize, null), try runCheckStatements(&child, text));

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
    try std.testing.expectEqual(
        @as(?usize, null),
        try runCheckStatements(&child, "fixnum: ( -- x ) [ 0 ] ;\nafter-fixnum: ( -- x ) [ 1 ] ;\n"),
    );

    try std.testing.expect(child.local_frames.items[0].contains("fixnum"));
    try std.testing.expect(child.local_frames.items[0].contains("after-fixnum"));
}
