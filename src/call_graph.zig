const std = @import("std");
const Allocator = std.mem.Allocator;
const Dictionary = @import("dictionary.zig").Dictionary;
const WordDefinition = @import("dictionary.zig").WordDefinition;
const DispatchTable = @import("dispatch.zig").DispatchTable;
const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const Marker = value_mod.Marker;
const markers = @import("primitives/markers.zig");

pub const CallGraphEntry = struct {
    callees: []const []const u8,
    has_opaque: bool,
};

pub const CallGraph = std.StringHashMapUnmanaged(CallGraphEntry);

/// Build a complete call graph from the dictionary and dispatch table.
/// Every word in the dictionary gets an entry. Native words are leaf nodes
/// with empty callees. Compound words have their instruction bodies scanned
/// for call_word references. Generic words additionally include callees from
/// all dispatch table entries for that word.
pub fn build(dictionary: *const Dictionary, dispatch_table: *const DispatchTable, allocator: Allocator) !CallGraph {
    var graph: CallGraph = .{};

    var iter = dictionary.entries.iterator();
    while (iter.next()) |entry| {
        const word_name = entry.key_ptr.*;
        const word_def = entry.value_ptr.*;

        const graph_entry = try buildEntry(word_name, &word_def, dispatch_table, allocator);
        try graph.put(allocator, word_name, graph_entry);
    }

    return graph;
}

fn buildEntry(word_name: []const u8, word_def: *const WordDefinition, dispatch_table: *const DispatchTable, allocator: Allocator) !CallGraphEntry {
    switch (word_def.action) {
        .native => return .{ .callees = &.{}, .has_opaque = false },
        .compound => |instructions| {
            var callee_set: std.StringHashMapUnmanaged(void) = .{};
            defer callee_set.deinit(allocator);
            var has_opaque = false;

            try collectCallees(instructions, &callee_set, &has_opaque, allocator);

            if (isGeneric(word_def)) {
                const dispatch_entries = try dispatch_table.entriesForWord(word_name, allocator);
                defer allocator.free(dispatch_entries);
                for (dispatch_entries) |pair| {
                    try collectCallees(pair.entry.body, &callee_set, &has_opaque, allocator);
                }
            }

            const callees = try sortedKeys(callee_set, allocator);
            return .{ .callees = callees, .has_opaque = has_opaque };
        },
    }
}

fn collectCallees(instructions: []const Instruction, callee_set: *std.StringHashMapUnmanaged(void), has_opaque: *bool, allocator: Allocator) !void {
    for (instructions) |instr| {
        switch (instr.op) {
            .call_word => |name| {
                if (std.mem.eql(u8, name, ">quotation")) {
                    has_opaque.* = true;
                }
                try callee_set.put(allocator, name, {});
            },
            .push_literal => |val| {
                switch (val) {
                    .quotation => |quot| try collectCallees(quot.instructions, callee_set, has_opaque, allocator),
                    else => {},
                }
            },
        }
    }
}

fn isGeneric(word_def: *const WordDefinition) bool {
    for (word_def.markers) |mk| {
        if (markers.isGenericMarker(mk)) return true;
    }
    return false;
}

fn sortedKeys(set: std.StringHashMapUnmanaged(void), allocator: Allocator) ![]const []const u8 {
    const count = set.count();
    if (count == 0) return &.{};

    const result = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    var iter = set.iterator();
    while (iter.next()) |entry| {
        result[i] = entry.key_ptr.*;
        i += 1;
    }
    std.mem.sort([]const u8, result, {}, lessThanStringSlice);
    return result;
}

fn lessThanStringSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// =============================================================================
// Tests
// =============================================================================

test "native word produces empty leaf entry" {
    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();

    try dict.put("native-word", .{
        .name = "native-word",
        .action = .{ .native = dummyNative },
    });

    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer graph.deinit(std.testing.allocator);

    const entry = graph.get("native-word").?;
    try std.testing.expectEqual(@as(usize, 0), entry.callees.len);
    try std.testing.expect(!entry.has_opaque);
}

test "compound word with direct callees" {
    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "foo" }, .line = 1 },
        .{ .op = .{ .call_word = "bar" }, .line = 1 },
    };

    try dict.put("my-word", .{
        .name = "my-word",
        .action = .{ .compound = instrs },
    });

    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    const entry = graph.get("my-word").?;
    try std.testing.expectEqual(@as(usize, 2), entry.callees.len);
    try std.testing.expectEqualStrings("bar", entry.callees[0]);
    try std.testing.expectEqualStrings("foo", entry.callees[1]);
    try std.testing.expect(!entry.has_opaque);
}

test "nested quotation descent finds callees inside quotation literals" {
    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();

    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "inner-call" }, .line = 1 },
    };
    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "outer-call" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_instrs } } }, .line = 1 },
    };

    try dict.put("nested-word", .{
        .name = "nested-word",
        .action = .{ .compound = instrs },
    });

    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    const entry = graph.get("nested-word").?;
    try std.testing.expectEqual(@as(usize, 2), entry.callees.len);
    try std.testing.expectEqualStrings("inner-call", entry.callees[0]);
    try std.testing.expectEqualStrings("outer-call", entry.callees[1]);
}

test ">quotation triggers has_opaque" {
    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "foo" }, .line = 1 },
        .{ .op = .{ .call_word = ">quotation" }, .line = 1 },
    };

    try dict.put("opaque-word", .{
        .name = "opaque-word",
        .action = .{ .compound = instrs },
    });

    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    const entry = graph.get("opaque-word").?;
    try std.testing.expect(entry.has_opaque);
    try std.testing.expectEqual(@as(usize, 2), entry.callees.len);
}

test "callee deduplication: same name called twice produces one entry" {
    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    };

    try dict.put("dedup-word", .{
        .name = "dedup-word",
        .action = .{ .compound = instrs },
    });

    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    const entry = graph.get("dedup-word").?;
    try std.testing.expectEqual(@as(usize, 2), entry.callees.len);
    try std.testing.expectEqualStrings("drop", entry.callees[0]);
    try std.testing.expectEqualStrings("dup", entry.callees[1]);
}

test "generic word includes dispatch entry callees" {
    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();

    const body_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "base-call" }, .line = 1 },
    };

    try dict.put("my-generic", .{
        .name = "my-generic",
        .action = .{ .compound = body_instrs },
        .markers = &.{@constCast(&markers.generic_marker)},
    });

    const dispatch_body = &[_]Instruction{
        .{ .op = .{ .call_word = "dispatch-call" }, .line = 1 },
    };
    try dispatch.register(
        .{ .word_name = "my-generic", .type_a = "duration", .type_b = "" },
        .{ .body = dispatch_body },
        false,
    );

    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    const entry = graph.get("my-generic").?;
    try std.testing.expectEqual(@as(usize, 2), entry.callees.len);
    try std.testing.expectEqualStrings("base-call", entry.callees[0]);
    try std.testing.expectEqualStrings("dispatch-call", entry.callees[1]);
    try std.testing.expect(!entry.has_opaque);
}

fn dummyNative(_: *@import("context.zig").Context) anyerror!void {}

fn deinitGraph(graph: *CallGraph, allocator: Allocator) void {
    var iter = graph.iterator();
    while (iter.next()) |entry| {
        const callees = entry.value_ptr.callees;
        if (callees.len > 0) {
            allocator.free(callees);
        }
    }
    graph.deinit(allocator);
}
