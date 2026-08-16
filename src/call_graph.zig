const std = @import("std");
const Allocator = std.mem.Allocator;

const dict_mod = @import("dictionary.zig");
const Dictionary = dict_mod.Dictionary;
const WordDefinition = dict_mod.WordDefinition;
const Context = @import("context.zig").Context;

const dispatch_mod = @import("dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const Marker = value_mod.Marker;

const markers = @import("primitives/markers.zig");
const stack_effect_mod = @import("stack_effect.zig");

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
        const word_def = dict_mod.loadSlot(entry.value_ptr.*);

        const graph_entry = try buildEntry(word_name, word_def, dispatch_table, allocator);
        try graph.put(allocator, word_name, graph_entry);
    }

    return graph;
}

fn buildEntry(_: []const u8, word_def: *const WordDefinition, dispatch_table: *const DispatchTable, allocator: Allocator) !CallGraphEntry {
    switch (word_def.action) {
        .native, .host_callback, .literal => return .{ .callees = &.{}, .has_opaque = false },
        .compound => |instructions| {
            var callee_set: std.StringHashMapUnmanaged(void) = .{};
            defer callee_set.deinit(allocator);
            var has_opaque = false;

            try collectCallees(instructions, &callee_set, &has_opaque, allocator);

            if (isGeneric(word_def)) {
                const dispatch_entries = try dispatch_table.entriesForDispatchId(word_def.dispatch_id, allocator);
                defer allocator.free(dispatch_entries);
                for (dispatch_entries) |pair| {
                    switch (pair.entry.body) {
                        .quotation => |q| try collectCallees(q.instructions, &callee_set, &has_opaque, allocator),
                        .native_fn, .host_callback => {},
                    }
                }
            }

            const callees = try sortedKeys(callee_set, allocator);
            return .{ .callees = callees, .has_opaque = has_opaque };
        },
    }
}

pub fn collectCalleesPublic(instructions: []const Instruction, callee_set: *std.StringHashMapUnmanaged(void), has_opaque: *bool, allocator: Allocator) !void {
    return collectCallees(instructions, callee_set, has_opaque, allocator);
}

fn collectCallees(instructions: []const Instruction, callee_set: *std.StringHashMapUnmanaged(void), has_opaque: *bool, allocator: Allocator) !void {
    for (instructions) |instr| {
        switch (instr.op) {
            .call_word, .call_word_direct, .call_word_module => {
                const name = instr.op.callTargetName().?;
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

/// Check whether any tail-position instruction is a call to `target_name`.
///
/// Tail position means:
///
/// - last instruction of the sequence; or
/// - last instruction inside a quotation argument to an `if` that is itself in tail position.
pub fn hasTailCallTo(instructions: []const Instruction, target_name: []const u8) bool {
    if (instructions.len == 0) return false;
    const last = instructions[instructions.len - 1];
    switch (last.op) {
        .call_word, .call_word_direct, .call_word_module => {
            const name = last.op.callTargetName().?;
            if (std.mem.eql(u8, name, target_name)) return true;

            // check the two quotation literals preceding `if`
            if (std.mem.eql(u8, name, "if")) {
                if (instructions.len < 3) return false;

                const true_instr = instructions[instructions.len - 3];
                const false_instr = instructions[instructions.len - 2];

                const true_body = switch (true_instr.op) {
                    .push_literal => |v| if (v == .quotation) v.quotation.instructions else return false,
                    else => return false,
                };
                const false_body = switch (false_instr.op) {
                    .push_literal => |v| if (v == .quotation) v.quotation.instructions else return false,
                    else => return false,
                };
                return hasTailCallTo(true_body, target_name) or hasTailCallTo(false_body, target_name);
            }

            return false;
        },
        .push_literal => return false,
    }
}

// =============================================================================
// Strongly-connected Components / Tarjan's Algo
// =============================================================================

const TarjanState = struct {
    graph: *const CallGraph,
    index_map: std.StringHashMapUnmanaged(u32),
    lowlink_map: std.StringHashMapUnmanaged(u32),
    on_stack: std.StringHashMapUnmanaged(void),
    stack: std.ArrayListUnmanaged([]const u8),
    current_index: u32,
    result: std.ArrayListUnmanaged([]const []const u8),
    allocator: Allocator,

    fn init(graph: *const CallGraph, allocator: Allocator) TarjanState {
        return .{
            .graph = graph,
            .index_map = .{},
            .lowlink_map = .{},
            .on_stack = .{},
            .stack = .{},
            .current_index = 0,
            .result = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *TarjanState) void {
        self.index_map.deinit(self.allocator);
        self.lowlink_map.deinit(self.allocator);
        self.on_stack.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.result.deinit(self.allocator);
    }

    fn strongconnect(self: *TarjanState, v: []const u8) !void {
        try self.index_map.put(self.allocator, v, self.current_index);
        try self.lowlink_map.put(self.allocator, v, self.current_index);
        self.current_index += 1;
        try self.stack.append(self.allocator, v);
        try self.on_stack.put(self.allocator, v, {});

        // Visit successors
        if (self.graph.get(v)) |entry| {
            for (entry.callees) |w| {
                if (!self.index_map.contains(w)) {
                    // w has not been visited; recurse
                    if (self.graph.contains(w)) {
                        try self.strongconnect(w);
                        const w_lowlink = self.lowlink_map.get(w).?;
                        const v_lowlink = self.lowlink_map.getPtr(v).?;
                        v_lowlink.* = @min(v_lowlink.*, w_lowlink);
                    }
                } else if (self.on_stack.contains(w)) {
                    // w is on the stack, hence in the current SCC
                    const w_index = self.index_map.get(w).?;
                    const v_lowlink = self.lowlink_map.getPtr(v).?;
                    v_lowlink.* = @min(v_lowlink.*, w_index);
                }
            }
        }

        // If v is a root node, pop the SCC
        const v_lowlink = self.lowlink_map.get(v).?;
        const v_index = self.index_map.get(v).?;
        if (v_lowlink == v_index) {
            var scc = std.ArrayListUnmanaged([]const u8){};
            while (true) {
                const w = self.stack.pop().?;
                _ = self.on_stack.remove(w);
                try scc.append(self.allocator, w);
                if (std.mem.eql(u8, w, v)) break;
            }

            // Only keep multi-member SCCs (self-recursion handled elsewhere)
            if (scc.items.len > 1) {
                const members = try self.allocator.dupe([]const u8, scc.items);
                std.mem.sort([]const u8, members, {}, lessThanStringSlice);
                try self.result.append(self.allocator, members);
            }
            scc.deinit(self.allocator);
        }
    }
};

/// Find all strongly connected components with more than one member.
/// Single-member SCCs (self-loops) are excluded since the existing loop
/// transform handles self-recursive tail calls.
pub fn findSCCs(graph: *const CallGraph, allocator: Allocator) ![]const []const []const u8 {
    var state = TarjanState.init(graph, allocator);
    defer state.deinit();

    // Collect and sort keys for deterministic iteration order
    const node_count = graph.count();
    var all_nodes = try allocator.alloc([]const u8, node_count);
    defer allocator.free(all_nodes);
    {
        var i: usize = 0;
        var iter = graph.iterator();
        while (iter.next()) |entry| {
            all_nodes[i] = entry.key_ptr.*;
            i += 1;
        }
    }
    std.mem.sort([]const u8, all_nodes, {}, lessThanStringSlice);

    for (all_nodes) |node| {
        if (!state.index_map.contains(node)) {
            try state.strongconnect(node);
        }
    }

    return try allocator.dupe([]const []const u8, state.result.items);
}

// =============================================================================
// Mutual TCO Group Detection
// =============================================================================

pub const MutualTcoGroups = struct {
    groups: []const []const []const u8,
    word_to_group: std.StringHashMapUnmanaged(u32),
    allocator: Allocator,

    /// Returns the group index for a word, or null if not in any mutual TCO group.
    pub fn getGroup(self: *const MutualTcoGroups, word_name: []const u8) ?u32 {
        return self.word_to_group.get(word_name);
    }

    /// Returns the members of the group with the given index.
    pub fn getMembers(self: *const MutualTcoGroups, group_id: u32) []const []const u8 {
        return self.groups[group_id];
    }

    pub fn deinit(self: *MutualTcoGroups) void {
        for (self.groups) |members| {
            self.allocator.free(members);
        }
        self.allocator.free(self.groups);
        self.word_to_group.deinit(self.allocator);
    }
};

/// A word is compilable if it is a compound word with a known stack effect and no parse-time-only markers.
///
/// Parse-time markers indicate that the word performs parsing or compilation tasks that cannot be safely
/// handled by the trampoline.
///
/// An unknown stack effect means we cannot verify the arity requirement for trampoline groups.
fn isCompilable(word_def: *const WordDefinition) bool {
    switch (word_def.action) {
        .native, .host_callback, .literal => return false,
        .compound => {},
    }
    const effect = word_def.stack_effect orelse return false;
    for (word_def.markers) |mk| {
        if (markers.isParseTimeOnlyMarker(mk)) return false;
        if (markers.isParseTimeMarker(mk)) return false;
        if (markers.isGenericMarker(mk)) return false;
    }
    if (stack_effect_mod.hasAnyRowVariable(effect.*)) return false;
    return true;
}

/// Find mutual recursion groups eligible for trampoline-based TCO.
/// A group is eligible when:
/// - Every member is a compilable compound word
/// - No member has opaque calls
/// - Every inter-member edge in the cycle is a tail call
pub fn findMutualTcoGroups(
    graph: *const CallGraph,
    dictionary: *const Dictionary,
    allocator: Allocator,
) !MutualTcoGroups {
    const sccs = try findSCCs(graph, allocator);
    defer {
        for (sccs) |members| allocator.free(members);
        allocator.free(sccs);
    }

    var groups = std.ArrayListUnmanaged([]const []const u8){};
    defer groups.deinit(allocator);
    var word_to_group = std.StringHashMapUnmanaged(u32){};

    for (sccs) |scc| {
        if (isSccEligible(scc, graph, dictionary)) {
            const group_id: u32 = @intCast(groups.items.len);
            const members = try allocator.dupe([]const u8, scc);
            try groups.append(allocator, members);
            for (members) |name| {
                try word_to_group.put(allocator, name, group_id);
            }
        }
    }

    return .{
        .groups = try allocator.dupe([]const []const u8, groups.items),
        .word_to_group = word_to_group,
        .allocator = allocator,
    };
}

/// SCC eligibility: a component is strongly-connected when every member can reach every other member.
///
/// To be eligible for mutual TCO, we require that every such path is a tail call, which ensures that
/// the trampoline can cycle through the members without consuming additional stack frames.
///
/// The eligibility criteria are checked conservatively based on the presence of tail calls in
/// the original source; we do not attempt to prove that non-tail calls are actually unreachable
/// at runtime.
fn isSccEligible(
    scc: []const []const u8,
    graph: *const CallGraph,
    dictionary: *const Dictionary,
) bool {
    // Build a set for O(1) membership checks
    var member_set: std.StringHashMapUnmanaged(void) = .{};
    defer member_set.deinit(std.heap.page_allocator);
    for (scc) |name| {
        member_set.put(std.heap.page_allocator, name, {}) catch return false;
    }

    // members must have the same stack-effect arity: trampoline reuses the same physical stack slots
    // across bounces, so mismatched arities would break the slot layout
    var ref_inputs: ?usize = null;
    var ref_outputs: ?usize = null;

    for (scc) |name| {
        // XXX(ripta): isCompilable invariant: word def being compilatble guarantees non-null stack effect
        const word_def = dictionary.get(name) orelse return false;
        if (!isCompilable(&word_def)) return false;
        const effect = word_def.stack_effect.?;
        if (ref_inputs) |ri| {
            if (effect.inputs.len != ri or effect.outputs.len != ref_outputs.?) return false;
        } else {
            ref_inputs = effect.inputs.len;
            ref_outputs = effect.outputs.len;
        }

        // No opaque calls
        const graph_entry = graph.get(name) orelse return false;
        if (graph_entry.has_opaque) return false;

        // Every inter-member callee edge must be a tail call
        const instructions = switch (word_def.action) {
            .compound => |i| i,
            .native, .host_callback, .literal => return false,
        };
        for (graph_entry.callees) |callee| {
            if (member_set.contains(callee)) {
                if (!hasTailCallTo(instructions, callee)) return false;
            }
        }
    }

    return true;
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
        .dispatch_id = 42,
    });

    const dispatch_body = &[_]Instruction{
        .{ .op = .{ .call_word = "dispatch-call" }, .line = 1 },
    };

    const duration_desc = try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, duration_desc);
    const unary_desc = try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, unary_desc);
    try dispatch.register(
        .{ .dispatch_id = 42, .type_a = duration_desc, .type_b = unary_desc },
        .{ .body = .{ .quotation = .{ .instructions = dispatch_body } } },
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

fn dummyNative(_: *Context) anyerror!void {}

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

fn deinitSCCs(sccs: []const []const []const u8, allocator: Allocator) void {
    for (sccs) |members| allocator.free(members);
    allocator.free(sccs);
}

const StackEffect = stack_effect_mod.StackEffect;

/// A minimal stack effect with one input and one output (no row variables).
const simple_effect: StackEffect = .{
    .inputs = &.{.{ .name = "a" }},
    .outputs = &.{.{ .name = "b" }},
};

// =============================================================================
// hasTailCallTo tests
// =============================================================================

test "hasTailCallTo: direct tail call detected" {
    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "foo" }, .line = 1 },
        .{ .op = .{ .call_word = "bar" }, .line = 1 },
    };
    try std.testing.expect(hasTailCallTo(instrs, "bar"));
    try std.testing.expect(!hasTailCallTo(instrs, "foo"));
}

test "hasTailCallTo: tail call inside if branches" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .call_word = "alpha" }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .call_word = "beta" }, .line = 1 },
    };
    const instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 1 },
        .{ .op = .{ .call_word = "if" }, .line = 1 },
    };
    try std.testing.expect(hasTailCallTo(instrs, "alpha"));
    try std.testing.expect(hasTailCallTo(instrs, "beta"));
    try std.testing.expect(!hasTailCallTo(instrs, "other"));
}

test "hasTailCallTo: non-tail call returns false" {
    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "target" }, .line = 1 },
        .{ .op = .{ .call_word = "other" }, .line = 1 },
    };
    try std.testing.expect(!hasTailCallTo(instrs, "target"));
}

test "hasTailCallTo: empty instructions returns false" {
    const instrs = &[_]Instruction{};
    try std.testing.expect(!hasTailCallTo(instrs, "anything"));
}

// =============================================================================
// SCC detection tests
// =============================================================================

test "findSCCs: simple two-node cycle" {
    var graph: CallGraph = .{};
    defer deinitGraph(&graph, std.testing.allocator);

    const a_callees = try std.testing.allocator.dupe([]const u8, &.{"B"});
    const b_callees = try std.testing.allocator.dupe([]const u8, &.{"A"});
    try graph.put(std.testing.allocator, "A", .{ .callees = a_callees, .has_opaque = false });
    try graph.put(std.testing.allocator, "B", .{ .callees = b_callees, .has_opaque = false });

    const sccs = try findSCCs(&graph, std.testing.allocator);
    defer deinitSCCs(sccs, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), sccs.len);
    try std.testing.expectEqual(@as(usize, 2), sccs[0].len);
    try std.testing.expectEqualStrings("A", sccs[0][0]);
    try std.testing.expectEqualStrings("B", sccs[0][1]);
}

test "findSCCs: three-node cycle" {
    var graph: CallGraph = .{};
    defer deinitGraph(&graph, std.testing.allocator);

    const a_callees = try std.testing.allocator.dupe([]const u8, &.{"B"});
    const b_callees = try std.testing.allocator.dupe([]const u8, &.{"C"});
    const c_callees = try std.testing.allocator.dupe([]const u8, &.{"A"});
    try graph.put(std.testing.allocator, "A", .{ .callees = a_callees, .has_opaque = false });
    try graph.put(std.testing.allocator, "B", .{ .callees = b_callees, .has_opaque = false });
    try graph.put(std.testing.allocator, "C", .{ .callees = c_callees, .has_opaque = false });

    const sccs = try findSCCs(&graph, std.testing.allocator);
    defer deinitSCCs(sccs, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), sccs.len);
    try std.testing.expectEqual(@as(usize, 3), sccs[0].len);
    try std.testing.expectEqualStrings("A", sccs[0][0]);
    try std.testing.expectEqualStrings("B", sccs[0][1]);
    try std.testing.expectEqualStrings("C", sccs[0][2]);
}

test "findSCCs: two disjoint cycles" {
    var graph: CallGraph = .{};
    defer deinitGraph(&graph, std.testing.allocator);

    const a_callees = try std.testing.allocator.dupe([]const u8, &.{"B"});
    const b_callees = try std.testing.allocator.dupe([]const u8, &.{"A"});
    const c_callees = try std.testing.allocator.dupe([]const u8, &.{"D"});
    const d_callees = try std.testing.allocator.dupe([]const u8, &.{"C"});
    try graph.put(std.testing.allocator, "A", .{ .callees = a_callees, .has_opaque = false });
    try graph.put(std.testing.allocator, "B", .{ .callees = b_callees, .has_opaque = false });
    try graph.put(std.testing.allocator, "C", .{ .callees = c_callees, .has_opaque = false });
    try graph.put(std.testing.allocator, "D", .{ .callees = d_callees, .has_opaque = false });

    const sccs = try findSCCs(&graph, std.testing.allocator);
    defer deinitSCCs(sccs, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), sccs.len);
}

test "findSCCs: chain with no cycle" {
    var graph: CallGraph = .{};
    defer deinitGraph(&graph, std.testing.allocator);

    const a_callees = try std.testing.allocator.dupe([]const u8, &.{"B"});
    const b_callees = try std.testing.allocator.dupe([]const u8, &.{"C"});
    try graph.put(std.testing.allocator, "A", .{ .callees = a_callees, .has_opaque = false });
    try graph.put(std.testing.allocator, "B", .{ .callees = b_callees, .has_opaque = false });
    try graph.put(std.testing.allocator, "C", .{ .callees = &.{}, .has_opaque = false });

    const sccs = try findSCCs(&graph, std.testing.allocator);
    defer deinitSCCs(sccs, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), sccs.len);
}

test "findSCCs: self-loop excluded" {
    var graph: CallGraph = .{};
    defer deinitGraph(&graph, std.testing.allocator);

    const a_callees = try std.testing.allocator.dupe([]const u8, &.{"A"});
    try graph.put(std.testing.allocator, "A", .{ .callees = a_callees, .has_opaque = false });

    const sccs = try findSCCs(&graph, std.testing.allocator);
    defer deinitSCCs(sccs, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), sccs.len);
}

// =============================================================================
// Mutual TCO group eligibility tests
// =============================================================================

test "findMutualTcoGroups: all tail-call edges produces group" {
    // A tail-calls B, B tail-calls A
    const a_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "B" }, .line = 1 },
    };
    const b_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "A" }, .line = 1 },
    };

    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    try dict.put("A", .{ .name = "A", .action = .{ .compound = a_instrs }, .stack_effect = &simple_effect });
    try dict.put("B", .{ .name = "B", .action = .{ .compound = b_instrs }, .stack_effect = &simple_effect });

    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();
    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    var groups = try findMutualTcoGroups(&graph, &dict, std.testing.allocator);
    defer groups.deinit();

    try std.testing.expectEqual(@as(usize, 1), groups.groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups.getMembers(0).len);
    try std.testing.expect(groups.getGroup("A") != null);
    try std.testing.expect(groups.getGroup("B") != null);
    try std.testing.expectEqual(groups.getGroup("A").?, groups.getGroup("B").?);
}

test "findMutualTcoGroups: one non-tail edge disqualifies" {
    // A tail-calls B, but B calls A in non-tail position
    const a_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "B" }, .line = 1 },
    };
    const b_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "A" }, .line = 1 },
        .{ .op = .{ .call_word = "other" }, .line = 1 },
    };

    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    try dict.put("A", .{ .name = "A", .action = .{ .compound = a_instrs }, .stack_effect = &simple_effect });
    try dict.put("B", .{ .name = "B", .action = .{ .compound = b_instrs }, .stack_effect = &simple_effect });

    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();
    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    var groups = try findMutualTcoGroups(&graph, &dict, std.testing.allocator);
    defer groups.deinit();

    try std.testing.expectEqual(@as(usize, 0), groups.groups.len);
}

test "findMutualTcoGroups: opaque member disqualifies" {
    const a_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "B" }, .line = 1 },
    };
    const b_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = ">quotation" }, .line = 1 },
        .{ .op = .{ .call_word = "A" }, .line = 1 },
    };

    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    try dict.put("A", .{ .name = "A", .action = .{ .compound = a_instrs }, .stack_effect = &simple_effect });
    try dict.put("B", .{ .name = "B", .action = .{ .compound = b_instrs }, .stack_effect = &simple_effect });

    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();
    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    var groups = try findMutualTcoGroups(&graph, &dict, std.testing.allocator);
    defer groups.deinit();

    try std.testing.expectEqual(@as(usize, 0), groups.groups.len);
}

test "findMutualTcoGroups: mismatched arities disqualifies" {
    // A ( a -- b ) tail-calls B, B ( a b -- c ) tail-calls A
    const a_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "B" }, .line = 1 },
    };
    const b_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "A" }, .line = 1 },
    };

    const two_in_effect: StackEffect = .{
        .inputs = &.{ .{ .name = "a" }, .{ .name = "b" } },
        .outputs = &.{.{ .name = "c" }},
    };

    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    try dict.put("A", .{ .name = "A", .action = .{ .compound = a_instrs }, .stack_effect = &simple_effect });
    try dict.put("B", .{ .name = "B", .action = .{ .compound = b_instrs }, .stack_effect = &two_in_effect });

    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();
    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    var groups = try findMutualTcoGroups(&graph, &dict, std.testing.allocator);
    defer groups.deinit();

    try std.testing.expectEqual(@as(usize, 0), groups.groups.len);
}

test "findMutualTcoGroups: native member disqualifies" {
    const a_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "B" }, .line = 1 },
    };

    var dict = Dictionary.init(std.testing.allocator);
    defer dict.deinit();
    try dict.put("A", .{ .name = "A", .action = .{ .compound = a_instrs }, .stack_effect = &simple_effect });
    try dict.put("B", .{ .name = "B", .action = .{ .native = dummyNative }, .stack_effect = &simple_effect });

    var dispatch = DispatchTable.init(std.testing.allocator);
    defer dispatch.deinit();
    var graph = try build(&dict, &dispatch, std.testing.allocator);
    defer deinitGraph(&graph, std.testing.allocator);

    var groups = try findMutualTcoGroups(&graph, &dict, std.testing.allocator);
    defer groups.deinit();

    try std.testing.expectEqual(@as(usize, 0), groups.groups.len);
}
