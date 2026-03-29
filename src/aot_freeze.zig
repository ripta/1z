const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const StatementProcessor = @import("statement.zig").StatementProcessor;
const ir_codegen = @import("ir_codegen.zig");
const AotWordDesc = ir_codegen.AotWordDesc;
const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const dictionary_mod = @import("dictionary.zig");
const WordDefinition = dictionary_mod.WordDefinition;

pub const FreezeResult = struct {
    words: []AotWordDesc,
    entry_word_id: u32,
    max_word_id: u32,
    skipped_words: []const []const u8,

    pub fn deinit(self: *FreezeResult, allocator: Allocator) void {
        allocator.free(self.words);
        allocator.free(self.skipped_words);
    }
};

pub const FreezeError = error{
    FileNotFound,
    FileReadFailed,
    ExecutionFailed,
    OutOfMemory,
};

/// Walk the module dependency graph from an entry file, collecting all
/// reachable compound words into an AotWordDesc array suitable for
/// emitProgramC.
///
/// The entry file is executed through the interpreter to populate the
/// module cache and define all words. Non-definition top-level statements
/// are collected as the entry point.
pub fn freezeModuleGraph(
    ctx: *Context,
    entry_file: []const u8,
    allocator: Allocator,
) (FreezeError || Allocator.Error)!FreezeResult {
    // Phase A: Execute entry file, collect non-definition instructions.
    // The local frame and pragma frame are kept alive so that lookupWord
    // can find words defined in the entry file during discovery.
    const entry_instrs = executeAndCollectEntry(ctx, entry_file, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.FileNotFound,
        error.FileReadFailed => return error.FileReadFailed,
        else => return error.ExecutionFailed,
    };

    // Phase B: Discover all reachable compound words via BFS.
    // The entry file's local frame is still on the stack, so lookupWord
    // finds entry-file definitions and their imports.
    var discovered = discoverReachableWords(ctx, entry_instrs, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer discovered.names.deinit(allocator);
    defer discovered.defs.deinit(allocator);

    // Now safe to pop the frames
    ctx.popPragmaFrame();
    ctx.popLocalFrame();

    // Phase C: Build AotWordDesc array
    return buildAotDescs(entry_instrs, &discovered, allocator);
}

/// Accumulated non-definition instructions from the entry file and
/// the set of word names defined in the entry file's local frame.
const EntryInstructions = []const Instruction;

/// Execute the entry file through the interpreter, collecting
/// non-definition top-level instructions as the entry point body.
fn executeAndCollectEntry(
    ctx: *Context,
    entry_file: []const u8,
    allocator: Allocator,
) anyerror!EntryInstructions {
    const file = std.fs.cwd().openFile(entry_file, .{}) catch {
        return error.FileNotFound;
    };
    defer file.close();

    // Set source filename for error reporting
    ctx.current_source = entry_file;

    // Set current_source_dir for relative path resolution in load/use
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.cwd().realpath(entry_file, &abs_buf)) |abs_path| {
        if (std.fs.path.dirname(abs_path)) |dir| {
            ctx.current_source_dir = ctx.quotationAllocator().dupe(u8, dir) catch null;
        }
    } else |_| {
        if (std.fs.path.dirname(entry_file)) |dir| {
            ctx.current_source_dir = dir;
        }
    }

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    try ctx.pushLocalFrame();
    errdefer ctx.popLocalFrame();

    try ctx.pushPragmaFrame();
    errdefer ctx.popPragmaFrame();

    const old_import_frame = ctx.import_frame_index;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    defer ctx.import_frame_index = old_import_frame;

    // Accumulate non-definition instructions for the entry word
    var entry_instrs: std.ArrayListUnmanaged(Instruction) = .{};

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                switch (processor.flush(ctx.quotationAllocator(), ctx)) {
                    .needs_more_input => {},
                    .parse_error => |e| return e,
                    .complete => |instrs| {
                        if (instrs.len > 0) {
                            const is_def = Context.isDefinitionStatement(instrs);
                            if (is_def) {
                                try ctx.executeQuotation(.{ .instructions = instrs });
                            } else {
                                try entry_instrs.appendSlice(allocator, instrs);
                            }
                        }
                    },
                }
                break;
            },
            else => return error.FileReadFailed,
        };

        switch (processor.feedLine(ctx.quotationAllocator(), line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| return err,
            .complete => |instrs| {
                if (instrs.len > 0) {
                    const is_def = Context.isDefinitionStatement(instrs);
                    if (is_def) {
                        try ctx.executeQuotation(.{ .instructions = instrs });
                    } else {
                        try entry_instrs.appendSlice(allocator, instrs);
                    }
                }
                processor.reset();
            },
        }
    }

    // Do NOT pop the local frame or pragma frame here. The caller
    // (freezeModuleGraph) keeps them alive for word discovery, then pops.

    return entry_instrs.toOwnedSlice(allocator);
}

const DiscoveredWords = struct {
    names: std.ArrayListUnmanaged([]const u8),
    defs: std.ArrayListUnmanaged(WordDefinition),
};

/// BFS over call_word references starting from entry instructions,
/// collecting all reachable compound words.
fn discoverReachableWords(
    ctx: *Context,
    entry_instrs: []const Instruction,
    allocator: Allocator,
) Allocator.Error!DiscoveredWords {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);

    var result = DiscoveredWords{
        .names = .{},
        .defs = .{},
    };

    // Seed worklist from entry instructions
    try collectCallWords(entry_instrs, &worklist, &seen, allocator);

    // BFS
    while (worklist.pop()) |name| {
        const word = ctx.lookupWord(name) orelse continue;

        // Skip parse-time-only words
        if (word.parse_time_only) continue;

        // Skip native words (they're in lib1z.a)
        const instrs = switch (word.action) {
            .compound => |c| c,
            .native => continue,
        };

        try result.names.append(allocator, name);
        try result.defs.append(allocator, word);

        // Discover callees
        try collectCallWords(instrs, &worklist, &seen, allocator);
    }

    return result;
}

/// Extract call_word names from instructions and add unseen ones to the worklist.
fn collectCallWords(
    instrs: []const Instruction,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    allocator: Allocator,
) Allocator.Error!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .call_word => |name| {
                const gop = try seen.getOrPut(allocator, name);
                if (!gop.found_existing) {
                    try worklist.append(allocator, name);
                }
            },
            .push_literal => |val| {
                // Recurse into nested quotations
                switch (val) {
                    .quotation => |q| try collectCallWords(q.instructions, worklist, seen, allocator),
                    else => {},
                }
            },
        }
    }
}

/// Assign word IDs and build the AotWordDesc array.
fn buildAotDescs(
    entry_instrs: []const Instruction,
    discovered: *const DiscoveredWords,
    allocator: Allocator,
) Allocator.Error!FreezeResult {
    var words = std.ArrayListUnmanaged(AotWordDesc){};
    var skipped = std.ArrayListUnmanaged([]const u8){};
    var next_id: u32 = 0;

    // Entry word gets ID 0
    const entry_word_id = next_id;
    next_id += 1;
    try words.append(allocator, .{
        .name = "__entry__",
        .instructions = entry_instrs,
        .input_count = 0,
        .output_count = 0,
        .word_id = entry_word_id,
    });

    // Assign IDs to discovered words
    for (discovered.names.items, discovered.defs.items) |name, def| {
        const effect = def.stack_effect orelse {
            try skipped.append(allocator, name);
            continue;
        };
        const id = next_id;
        next_id += 1;
        try words.append(allocator, .{
            .name = name,
            .instructions = def.action.compound,
            .input_count = @intCast(effect.inputs.len),
            .output_count = @intCast(effect.outputs.len),
            .word_id = id,
        });
    }

    const max_word_id = if (next_id > 0) next_id - 1 else 0;

    return FreezeResult{
        .words = try words.toOwnedSlice(allocator),
        .entry_word_id = entry_word_id,
        .max_word_id = max_word_id,
        .skipped_words = try skipped.toOwnedSlice(allocator),
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "collectCallWords extracts call_word names from instructions" {
    const allocator = testing.allocator;
    const instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .call_word = "double" }, .line = 1 },
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);

    try collectCallWords(instrs, &worklist, &seen, allocator);

    try testing.expectEqual(@as(usize, 2), worklist.items.len);
    try testing.expect(seen.contains("double"));
    try testing.expect(seen.contains("drop"));
}

test "buildAotDescs assigns sequential IDs and skips effectless words" {
    const allocator = testing.allocator;
    const entry_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    };

    const effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
    };
    defer discovered.names.deinit(allocator);
    defer discovered.defs.deinit(allocator);

    // Word with effect
    try discovered.names.append(allocator, "foo");
    try discovered.defs.append(allocator, .{
        .name = "foo",
        .action = .{ .compound = &.{} },
        .stack_effect = effect,
    });

    // Word without effect (should be skipped)
    try discovered.names.append(allocator, "bar");
    try discovered.defs.append(allocator, .{
        .name = "bar",
        .action = .{ .compound = &.{} },
    });

    var result = try buildAotDescs(entry_instrs, &discovered, allocator);
    defer result.deinit(allocator);

    // Entry word (id 0) + foo (id 1) = 2 words; bar skipped
    try testing.expectEqual(@as(usize, 2), result.words.len);
    try testing.expectEqual(@as(u32, 0), result.entry_word_id);
    try testing.expectEqual(@as(u32, 1), result.max_word_id);
    try testing.expectEqual(@as(usize, 1), result.skipped_words.len);
    try testing.expect(std.mem.eql(u8, result.skipped_words[0], "bar"));
}
