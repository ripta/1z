const std = @import("std");
const Allocator = std.mem.Allocator;

const dictionary_mod = @import("dictionary.zig");
const Dictionary = dictionary_mod.Dictionary;
const WordDefinition = dictionary_mod.WordDefinition;
const LocalFrame = @import("context.zig").LocalFrame;
const dispatch_mod = @import("dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;
const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const markers = @import("primitives/markers.zig");
const Context = @import("context.zig").Context;

pub fn nativeSuppressChecksValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .boolean => |b| {
            if (b) {
                try ctx.stack.push(.{ .string = "all" });
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
            try ctx.stack.push(.{ .boolean = true });
        },
        .string => |s| {
            if (std.mem.eql(u8, s, "all") or std.mem.eql(u8, s, "warn-only") or std.mem.eql(u8, s, "none")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(.{ .string = "suppress-checks: expected t, f, or one of all, warn-only, none" });
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(.{ .string = "suppress-checks: expected t, f, or one of all, warn-only, none" });
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

pub const InferenceResult = union(enum) {
    known: i64,
    unknown,
};

pub const Severity = enum {
    err,
    warning,
};

pub const Diagnostic = struct {
    word_name: []const u8,
    source_file: ?[]const u8,
    source_line: usize,
    severity: Severity,
    message: []const u8,
};

const StackEntry = union(enum) {
    quotation: Quotation,
    other,
};

pub const InferenceEngine = struct {
    dictionary: *const Dictionary,
    dispatch_table: *const DispatchTable,
    local_frames: []const LocalFrame,
    allocator: Allocator,
    cache: std.StringHashMapUnmanaged(InferenceResult),
    in_progress: std.StringHashMapUnmanaged(void),
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    severity_override: Severity,
    suppressed: bool,

    pub fn init(
        dictionary: *const Dictionary,
        dispatch_table: *const DispatchTable,
        local_frames: []const LocalFrame,
        allocator: Allocator,
        severity_override: Severity,
        suppressed: bool,
    ) InferenceEngine {
        return .{
            .dictionary = dictionary,
            .dispatch_table = dispatch_table,
            .local_frames = local_frames,
            .allocator = allocator,
            .cache = .{},
            .in_progress = .{},
            .diagnostics = .{},
            .severity_override = severity_override,
            .suppressed = suppressed,
        };
    }

    pub fn deinit(self: *InferenceEngine) void {
        for (self.diagnostics.items) |d| {
            self.allocator.free(d.message);
        }
        self.diagnostics.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.in_progress.deinit(self.allocator);
    }

    pub fn analyzeAll(self: *InferenceEngine, checked_source: ?[]const u8) Allocator.Error!void {
        for (self.local_frames) |frame| {
            var iter = frame.iterator();
            while (iter.next()) |entry| {
                const word_def = entry.value_ptr.*;
                if (word_def.action != .compound) continue;
                if (checked_source) |src| {
                    if (word_def.source_file) |sf| {
                        if (!std.mem.eql(u8, sf, src)) continue;
                    } else continue;
                }
                _ = try self.inferWord(entry.key_ptr.*);
            }
        }
    }

    pub fn getDiagnostics(self: *const InferenceEngine) []const Diagnostic {
        return self.diagnostics.items;
    }

    pub fn hasErrors(self: *const InferenceEngine) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }

    fn lookupWord(self: *const InferenceEngine, name: []const u8) ?WordDefinition {
        var i = self.local_frames.len;
        while (i > 0) {
            i -= 1;
            if (self.local_frames[i].get(name)) |def| return def;
        }

        return self.dictionary.get(name);
    }

    fn inferWord(self: *InferenceEngine, name: []const u8) Allocator.Error!InferenceResult {
        if (self.cache.get(name)) |cached| return cached;

        if (self.in_progress.contains(name)) {
            const word_def = self.lookupWord(name) orelse return .unknown;
            if (word_def.stack_effect) |eff| {
                return computeDeclaredDelta(eff) orelse .unknown;
            }
            return .unknown;
        }

        const word_def = self.lookupWord(name) orelse return .unknown;
        switch (word_def.action) {
            .native => {
                const result = if (word_def.stack_effect) |eff|
                    computeDeclaredDelta(eff) orelse .unknown
                else
                    .unknown;
                try self.cache.put(self.allocator, name, result);
                return result;
            },
            .compound => |instructions| {
                if (word_def.stack_effect) |eff| {
                    if (stack_effect_mod.hasAnyRowVariable(eff)) {
                        try self.cache.put(self.allocator, name, .unknown);
                        return .unknown;
                    }
                }

                try self.in_progress.put(self.allocator, name, {});
                const caller_info = CallerInfo{
                    .word_name = name,
                    .source_file = word_def.source_file,
                    .source_line = word_def.source_line,
                };
                const inferred = try self.inferInstructions(instructions, caller_info);
                _ = self.in_progress.fetchRemove(name);

                if (isGeneric(&word_def)) {
                    try self.validateDispatchEntries(name, inferred, &word_def, caller_info);
                }

                if (word_def.stack_effect) |eff| {
                    if (computeDeclaredDelta(eff)) |declared| {
                        if (inferred == .known and declared.known != inferred.known) {
                            try self.emitDiagnostic(.{
                                .word_name = name,
                                .source_file = word_def.source_file,
                                .source_line = word_def.source_line,
                                .severity = .err,
                                .message = try std.fmt.allocPrint(
                                    self.allocator,
                                    "declared stack effect delta is {d}, but inferred delta is {d}",
                                    .{ declared.known, inferred.known },
                                ),
                            });
                        }
                    }
                }

                try self.cache.put(self.allocator, name, inferred);
                return inferred;
            },
        }
    }

    fn inferInstructions(self: *InferenceEngine, instructions: []const Instruction, caller: CallerInfo) Allocator.Error!InferenceResult {
        var delta: i64 = 0;
        var stack_model: std.ArrayListUnmanaged(StackEntry) = .{};
        defer stack_model.deinit(self.allocator);

        for (instructions) |instr| {
            switch (instr.op) {
                .push_literal => |val| {
                    delta += 1;
                    switch (val) {
                        .quotation => |quot| try stack_model.append(self.allocator, .{ .quotation = quot }),
                        else => try stack_model.append(self.allocator, .other),
                    }
                },
                .call_word => |name| {
                    const word_def = self.lookupWord(name);
                    if (word_def == null) {
                        return .unknown;
                    }
                    const wd = word_def.?;

                    const combinator_kind = classifyCombinator(&wd);

                    // Try row-polymorphic path for any word with row-poly effect and quotation annotations
                    if (wd.stack_effect) |eff| {
                        if (stack_effect_mod.hasAnyRowVariable(eff)) {
                            const rp_result = try self.handleRowPoly(
                                &wd,
                                combinator_kind,
                                &stack_model,
                                delta,
                                caller,
                            );
                            switch (rp_result) {
                                .applied => |applied| {
                                    delta = applied.new_delta;
                                    stack_model.shrinkRetainingCapacity(0);

                                    var i: usize = 0;
                                    while (i < applied.new_model_size) : (i += 1) {
                                        try stack_model.append(self.allocator, .other);
                                    }
                                    continue;
                                },
                                .unknown => return .unknown,
                                .fallthrough => {},
                            }
                        }
                    }

                    // Try concrete combinator path for branch/loop without row vars
                    if (combinator_kind != .none) {
                        if (wd.stack_effect) |eff| {
                            if (!stack_effect_mod.hasAnyRowVariable(eff)) {
                                const result = try self.handleCombinator(
                                    &wd,
                                    combinator_kind,
                                    &stack_model,
                                    delta,
                                    caller,
                                );
                                switch (result) {
                                    .applied => |applied| {
                                        delta = applied.new_delta;
                                        stack_model.shrinkRetainingCapacity(0);

                                        var i: usize = 0;
                                        while (i < applied.new_model_size) : (i += 1) {
                                            try stack_model.append(self.allocator, .other);
                                        }
                                        continue;
                                    },
                                    .unknown => return .unknown,
                                    .fallthrough => {},
                                }
                            }
                        }
                    }

                    const callee_result = try self.inferWord(name);
                    switch (callee_result) {
                        .known => |callee_delta| {
                            delta += callee_delta;
                            try adjustStackModel(&stack_model, callee_delta, self.allocator);
                        },
                        .unknown => return .unknown,
                    }
                },
            }
        }

        return .{ .known = delta };
    }

    const CallerInfo = struct {
        word_name: []const u8,
        source_file: ?[]const u8,
        source_line: usize,
    };

    const CombinatorKind = enum { none, branch, loop };

    fn classifyCombinator(word_def: *const WordDefinition) CombinatorKind {
        for (word_def.markers) |mk| {
            if (markers.isBranchCombinatorMarker(mk)) return .branch;
            if (markers.isLoopCombinatorMarker(mk)) return .loop;
        }
        return .none;
    }

    const CombinatorResult = union(enum) {
        applied: struct { new_delta: i64, new_model_size: usize },
        unknown,
        fallthrough,
    };

    fn handleCombinator(
        self: *InferenceEngine,
        word_def: *const WordDefinition,
        kind: CombinatorKind,
        stack_model: *std.ArrayListUnmanaged(StackEntry),
        current_delta: i64,
        caller: CallerInfo,
    ) Allocator.Error!CombinatorResult {
        const eff = word_def.stack_effect orelse return .fallthrough;
        const declared = computeDeclaredDelta(eff) orelse return .fallthrough;

        const input_count = eff.inputs.len;

        var quot_deltas: std.ArrayListUnmanaged(i64) = .{};
        defer quot_deltas.deinit(self.allocator);
        var all_literal = true;
        var found_any_quot = false;

        for (0..input_count) |param_index| {
            if (stack_model.items.len < input_count) {
                // Not enough stack model entries to analyze
                break;
            }
            const stack_pos = stack_model.items.len - input_count + param_index;

            switch (stack_model.items[stack_pos]) {
                .quotation => |quot| {
                    found_any_quot = true;
                    const qd = try self.inferInstructions(quot.instructions, caller);
                    switch (qd) {
                        .known => |d| try quot_deltas.append(self.allocator, d),
                        .unknown => {
                            all_literal = false;
                        },
                    }
                },
                .other => {},
            }
        }

        if (!all_literal or !found_any_quot or quot_deltas.items.len == 0) {
            const new_delta = current_delta + declared.known;
            const consumed = @min(stack_model.items.len, input_count);
            const new_model_size = stack_model.items.len - consumed;
            return .{ .applied = .{ .new_delta = new_delta, .new_model_size = new_model_size } };
        }

        switch (kind) {
            .branch => {
                const first = quot_deltas.items[0];
                for (quot_deltas.items[1..]) |d| {
                    if (d != first) {
                        try self.emitDiagnostic(.{
                            .word_name = caller.word_name,
                            .source_file = caller.source_file,
                            .source_line = caller.source_line,
                            .severity = .err,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "branch quotations have mismatched stack deltas",
                                .{},
                            ),
                        });
                        return .unknown;
                    }
                }

                const total_delta = current_delta + declared.known + first;
                const consumed = @min(stack_model.items.len, input_count);
                const new_model_size = stack_model.items.len - consumed;
                return .{ .applied = .{ .new_delta = total_delta, .new_model_size = new_model_size } };
            },
            .loop => {
                for (quot_deltas.items) |d| {
                    if (d != 0) {
                        try self.emitDiagnostic(.{
                            .word_name = caller.word_name,
                            .source_file = caller.source_file,
                            .source_line = caller.source_line,
                            .severity = .err,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "loop body has non-zero stack delta {d}",
                                .{d},
                            ),
                        });
                        return .unknown;
                    }
                }

                const total_delta = current_delta + declared.known;
                const consumed = @min(stack_model.items.len, input_count);
                const new_model_size = stack_model.items.len - consumed;
                return .{ .applied = .{ .new_delta = total_delta, .new_model_size = new_model_size } };
            },
            .none => return .fallthrough,
        }
    }

    fn handleRowPoly(
        self: *InferenceEngine,
        word_def: *const WordDefinition,
        kind: CombinatorKind,
        stack_model: *std.ArrayListUnmanaged(StackEntry),
        current_delta: i64,
        caller: CallerInfo,
    ) Allocator.Error!CombinatorResult {
        const eff = word_def.stack_effect orelse return .fallthrough;
        const concrete_inputs = eff.concreteInputCount();

        if (stack_model.items.len < concrete_inputs) return .fallthrough;

        var adjustments: std.ArrayListUnmanaged(i64) = .{};
        defer adjustments.deinit(self.allocator);

        var all_literal = true;
        var found_any_quot = false;
        var concrete_index: usize = 0;
        for (eff.inputs) |param| {
            if (param.is_row_variable) continue;
            defer concrete_index += 1;

            if (param.quotation_effect) |annotation| {
                found_any_quot = true;
                const stack_pos = stack_model.items.len - concrete_inputs + concrete_index;
                switch (stack_model.items[stack_pos]) {
                    .quotation => |quot| {
                        const qd = try self.inferInstructions(quot.instructions, caller);
                        switch (qd) {
                            .known => |d| {
                                const annotated_qcd = annotation.concreteDelta();
                                try adjustments.append(self.allocator, d - annotated_qcd);
                            },
                            .unknown => {
                                all_literal = false;
                            },
                        }
                    },
                    .other => {
                        all_literal = false;
                    },
                }
            }
        }

        if (!all_literal or !found_any_quot or adjustments.items.len == 0) return .fallthrough;

        const concrete_delta = eff.concreteDelta();
        const consumed = @min(stack_model.items.len, concrete_inputs);
        const new_model_size = stack_model.items.len - consumed;

        switch (kind) {
            .loop => {
                var adj_sum: i64 = 0;
                for (adjustments.items) |adj| adj_sum += adj;
                if (adj_sum != 0) {
                    try self.emitDiagnostic(.{
                        .word_name = caller.word_name,
                        .source_file = caller.source_file,
                        .source_line = caller.source_line,
                        .severity = .err,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "loop quotations have unalanced row variable adjustment (net {d})",
                            .{adj_sum},
                        ),
                    });
                    return .unknown;
                }

                return .{ .applied = .{
                    .new_delta = current_delta + concrete_delta,
                    .new_model_size = new_model_size,
                } };
            },

            .branch => {
                const first = adjustments.items[0];
                for (adjustments.items[1..]) |adj| {
                    if (adj != first) {
                        try self.emitDiagnostic(.{
                            .word_name = caller.word_name,
                            .source_file = caller.source_file,
                            .source_line = caller.source_line,
                            .severity = .err,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "branch quotations have mismatched row variable adjustments",
                                .{},
                            ),
                        });
                        return .unknown;
                    }
                }

                return .{ .applied = .{
                    .new_delta = current_delta + concrete_delta + first,
                    .new_model_size = new_model_size,
                } };
            },

            .none => {
                var adj_sum: i64 = 0;
                for (adjustments.items) |adj| adj_sum += adj;

                return .{
                    .applied = .{
                        .new_delta = current_delta + concrete_delta + adj_sum,
                        .new_model_size = new_model_size,
                    },
                };
            },
        }
    }

    fn validateDispatchEntries(self: *InferenceEngine, name: []const u8, base_result: InferenceResult, word_def: *const WordDefinition, caller: CallerInfo) Allocator.Error!void {
        const dispatch_entries = try self.dispatch_table.entriesForWord(name, self.allocator);
        defer self.allocator.free(dispatch_entries);

        for (dispatch_entries) |pair| {
            const entry_result = try self.inferInstructions(pair.entry.body, caller);
            if (base_result == .known and entry_result == .known) {
                if (base_result.known != entry_result.known) {
                    try self.emitDiagnostic(.{
                        .word_name = name,
                        .source_file = word_def.source_file,
                        .source_line = word_def.source_line,
                        .severity = .err,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "dispatch entry for ({s}, {s}) has delta {d}, but base body has delta {d}",
                            .{ pair.key.type_a, pair.key.type_b, entry_result.known, base_result.known },
                        ),
                    });
                }
            }
        }
    }

    fn emitDiagnostic(self: *InferenceEngine, diagnostic: Diagnostic) Allocator.Error!void {
        if (self.suppressed) {
            self.allocator.free(diagnostic.message);
            return;
        }
        var d = diagnostic;
        d.severity = self.severity_override;
        try self.diagnostics.append(self.allocator, d);
    }

    fn adjustStackModel(stack_model: *std.ArrayListUnmanaged(StackEntry), delta: i64, allocator: Allocator) Allocator.Error!void {
        if (delta < 0) {
            const to_remove: usize = @intCast(-delta);
            const remove_count = @min(to_remove, stack_model.items.len);
            stack_model.shrinkRetainingCapacity(stack_model.items.len - remove_count);
        } else if (delta > 0) {
            const to_add: usize = @intCast(delta);
            for (0..to_add) |_| {
                try stack_model.append(allocator, .other);
            }
        }
    }
};

fn computeDeclaredDelta(effect: StackEffect) ?InferenceResult {
    if (stack_effect_mod.hasAnyRowVariable(effect)) return null;
    const inputs: i64 = @intCast(effect.inputs.len);
    const outputs: i64 = @intCast(effect.outputs.len);
    return .{ .known = outputs - inputs };
}

fn isGeneric(word_def: *const WordDefinition) bool {
    for (word_def.markers) |mk| {
        if (markers.isGenericMarker(mk)) return true;
    }

    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn makeInstr(op: Instruction.Op) Instruction {
    return .{ .op = op, .line = 1 };
}

test "native word uses declared effect" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    try dict.put("dup", .{
        .name = "dup",
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .action = .{ .native = dummy },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("dup");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
}

test "compound word with inferrable body" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    try dict.put("dup", .{
        .name = "dup",
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .action = .{ .native = dummy },
    });

    try dict.put("drop", .{
        .name = "drop",
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const instrs: []const Instruction = &.{
        makeInstr(.{ .call_word = "dup" }),
        makeInstr(.{ .call_word = "drop" }),
    };

    try dict.put("my-word", .{
        .name = "my-word",
        .source_file = "test.1z",
        .action = .{ .compound = instrs },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("my-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
}

test "row-variable effect returns unknown" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const instrs: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };

    try dict.put("row-word", .{
        .name = "row-word",
        .source_file = "test.1z",
        .stack_effect = .{
            .inputs = &.{.{ .name = "..a", .is_row_variable = true }},
            .outputs = &.{ .{ .name = "..a", .is_row_variable = true }, .{ .name = "n" } },
        },
        .action = .{ .compound = instrs },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("row-word");
    try testing.expectEqual(InferenceResult.unknown, result);
}

test "branch combinator with agreeing quotations" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const quot_effect = StackEffect{
        .inputs = &.{},
        .outputs = &.{.{ .name = "x" }},
    };

    try dict.put("if", .{
        .name = "if",
        .markers = &.{@constCast(&markers.branch_combinator_marker)},
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "?" },
                .{ .name = "true-quot", .quotation_effect = &quot_effect },
                .{ .name = "false-quot", .quotation_effect = &quot_effect },
            },
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const true_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };
    const false_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 2 } }),
    };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .boolean = true } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }),
        makeInstr(.{ .call_word = "if" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "branch combinator with disagreeing quotations emits diagnostic" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const quot_effect = StackEffect{
        .inputs = &.{},
        .outputs = &.{.{ .name = "x" }},
    };

    try dict.put("if", .{
        .name = "if",
        .markers = &.{@constCast(&markers.branch_combinator_marker)},
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "?" },
                .{ .name = "true-quot", .quotation_effect = &quot_effect },
                .{ .name = "false-quot", .quotation_effect = &quot_effect },
            },
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const true_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };
    const false_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .fixnum = 2 } }),
    };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .boolean = true } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }),
        makeInstr(.{ .call_word = "if" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "loop combinator with zero-delta body" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const quot_effect = StackEffect{
        .inputs = &.{.{ .name = "n" }},
        .outputs = &.{.{ .name = "n" }},
    };

    try dict.put("times", .{
        .name = "times",
        .markers = &.{@constCast(&markers.loop_combinator_marker)},
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "n" },
                .{ .name = "quot", .quotation_effect = &quot_effect },
            },
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("dup", .{
        .name = "dup",
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .action = .{ .native = dummy },
    });

    try dict.put("drop", .{
        .name = "drop",
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const loop_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "dup" }),
        makeInstr(.{ .call_word = "drop" }),
    };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 5 } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = loop_body } } }),
        makeInstr(.{ .call_word = "times" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "loop combinator with non-zero-delta body emits diagnostic" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const quot_effect = StackEffect{
        .inputs = &.{.{ .name = "n" }},
        .outputs = &.{.{ .name = "n" }},
    };

    try dict.put("times", .{
        .name = "times",
        .markers = &.{@constCast(&markers.loop_combinator_marker)},
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "n" },
                .{ .name = "quot", .quotation_effect = &quot_effect },
            },
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("dup", .{
        .name = "dup",
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .action = .{ .native = dummy },
    });

    const loop_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "dup" }),
    };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 5 } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = loop_body } } }),
        makeInstr(.{ .call_word = "times" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "transitive inference" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const inner_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .fixnum = 2 } }),
    };

    try dict.put("push-two", .{
        .name = "push-two",
        .source_file = "test.1z",
        .action = .{ .compound = inner_body },
    });

    const outer_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "push-two" }),
    };

    try dict.put("outer", .{
        .name = "outer",
        .source_file = "test.1z",
        .action = .{ .compound = outer_body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("outer");
    try testing.expectEqual(InferenceResult{ .known = 2 }, result);
}

test "recursive cycle with declared effect breaks correctly" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "rec" }),
    };

    try dict.put("rec", .{
        .name = "rec",
        .source_file = "test.1z",
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{.{ .name = "b" }},
        },
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("rec");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
}

test "recursive cycle without declared effect returns unknown" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "rec-no-decl" }),
    };

    try dict.put("rec-no-decl", .{
        .name = "rec-no-decl",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("rec-no-decl");
    try testing.expectEqual(InferenceResult.unknown, result);
}

test "generic word with agreeing dispatch entries" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const base_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };

    try dict.put("my-generic", .{
        .name = "my-generic",
        .source_file = "test.1z",
        .markers = &.{@constCast(&markers.generic_marker)},
        .action = .{ .compound = base_body },
    });

    const dispatch_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 42 } }),
    };

    try dispatch.register(
        .{ .word_name = "my-generic", .type_a = "duration", .type_b = "" },
        .{ .body = dispatch_body },
        false,
    );

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("my-generic");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "generic word with disagreeing dispatch entries emits diagnostic" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const base_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };

    try dict.put("my-generic", .{
        .name = "my-generic",
        .source_file = "test.1z",
        .markers = &.{@constCast(&markers.generic_marker)},
        .action = .{ .compound = base_body },
    });

    const dispatch_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .fixnum = 2 } }),
    };

    try dispatch.register(
        .{ .word_name = "my-generic", .type_a = "duration", .type_b = "" },
        .{ .body = dispatch_body },
        false,
    );

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("my-generic");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "non-literal quotation args fall back to declared effect" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const quot_effect = StackEffect{
        .inputs = &.{},
        .outputs = &.{.{ .name = "x" }},
    };

    try dict.put("if", .{
        .name = "if",
        .markers = &.{@constCast(&markers.branch_combinator_marker)},
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "?" },
                .{ .name = "true-quot", .quotation_effect = &quot_effect },
                .{ .name = "false-quot", .quotation_effect = &quot_effect },
            },
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("get-quot", .{
        .name = "get-quot",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "q" }},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .boolean = true } }),
        makeInstr(.{ .call_word = "get-quot" }),
        makeInstr(.{ .call_word = "get-quot" }),
        makeInstr(.{ .call_word = "if" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "declared vs inferred mismatch emits diagnostic" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .fixnum = 2 } }),
    };

    try dict.put("bad-decl", .{
        .name = "bad-decl",
        .source_file = "test.1z",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "a" }},
        },
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("bad-decl");
    try testing.expectEqual(InferenceResult{ .known = 2 }, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "unknown word returns unknown" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "nonexistent" }),
    };

    try dict.put("calls-unknown", .{
        .name = "calls-unknown",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("calls-unknown");
    try testing.expectEqual(InferenceResult.unknown, result);
}

// =============================================================================
// Row-polymorphic inference tests
// =============================================================================

test "row-poly keep with literal quotation computes delta" {
    // keep: ( ..a x quot: ( ..a x -- ..b ) -- ..b x )
    // concrete_delta = concreteOutputCount(1) - concreteInputCount(2) = -1
    // quot annotation QCD = concreteOutputCount(0) - concreteInputCount(1) = -1
    // With [ drop ] (delta = -1): total = -1 + (-1 - (-1)) = -1
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const quot_annotation = StackEffect{
        .inputs = &.{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &.{
            .{ .name = "..b", .is_row_variable = true },
        },
    };

    try dict.put("keep", .{
        .name = "keep",
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "..a", .is_row_variable = true },
                .{ .name = "x" },
                .{ .name = "quot", .quotation_effect = &quot_annotation },
            },
            .outputs = &.{
                .{ .name = "..b", .is_row_variable = true },
                .{ .name = "x" },
            },
        },
        .action = .{ .native = dummy },
    });

    try dict.put("drop", .{
        .name = "drop",
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    // test-word: ( -- ) [ 1 [ drop ] keep drop ] ;
    // push 1 (+1), push [drop] (+1), call keep (-1), call drop (-1) = 0
    const drop_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "drop" }),
    };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = drop_body } } }),
        makeInstr(.{ .call_word = "keep" }),
        makeInstr(.{ .call_word = "drop" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{},
        },
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "row-poly while with balanced quotations" {
    // while: loop-combinator ( ..a pred: ( ..a -- ..b ? ) body: ( ..b -- ..a ) -- ..b )
    // concrete_delta = concreteOutputCount(0) - concreteInputCount(2) = -2
    // pred QCD = concreteOutputCount(1) - concreteInputCount(0) = 1
    // body QCD = concreteOutputCount(0) - concreteInputCount(0) = 0
    // With pred [ t ] (d=1) and body [ ] (d=0):
    //   adj_pred = 1 - 1 = 0, adj_body = 0 - 0 = 0
    //   sum = 0, so loop constraint satisfied
    //   total = -2
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const pred_annotation = StackEffect{
        .inputs = &.{
            .{ .name = "..a", .is_row_variable = true },
        },
        .outputs = &.{
            .{ .name = "..b", .is_row_variable = true },
            .{ .name = "?" },
        },
    };

    const body_annotation = StackEffect{
        .inputs = &.{
            .{ .name = "..b", .is_row_variable = true },
        },
        .outputs = &.{
            .{ .name = "..a", .is_row_variable = true },
        },
    };

    try dict.put("while", .{
        .name = "while",
        .markers = &.{@constCast(&markers.loop_combinator_marker)},
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "..a", .is_row_variable = true },
                .{ .name = "pred", .quotation_effect = &pred_annotation },
                .{ .name = "body", .quotation_effect = &body_annotation },
            },
            .outputs = &.{
                .{ .name = "..b", .is_row_variable = true },
            },
        },
        .action = .{ .native = dummy },
    });

    // pred: [ t ] => push true, delta = 1
    const pred_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .boolean = true } }),
    };

    // body: [ ] => noop, delta = 0
    const loop_body: []const Instruction = &.{};

    // test-word: ( -- ) [ [ t ] [ ] while ] ;
    // push pred (+1), push body (+1), call while (-2) = 0
    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = pred_body } } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = loop_body } } }),
        makeInstr(.{ .call_word = "while" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{},
        },
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "row-poly while with unbalanced quotations emits diagnostic" {
    // pred: [ 1 t ] => push 1, push true, delta = 2
    //   adj_pred = 2 - 1 = 1
    // body: [ ] => delta = 0
    //   adj_body = 0 - 0 = 0
    // sum = 1, loop constraint violated
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const pred_annotation = StackEffect{
        .inputs = &.{
            .{ .name = "..a", .is_row_variable = true },
        },
        .outputs = &.{
            .{ .name = "..b", .is_row_variable = true },
            .{ .name = "?" },
        },
    };

    const body_annotation = StackEffect{
        .inputs = &.{
            .{ .name = "..b", .is_row_variable = true },
        },
        .outputs = &.{
            .{ .name = "..a", .is_row_variable = true },
        },
    };

    try dict.put("while", .{
        .name = "while",
        .markers = &.{@constCast(&markers.loop_combinator_marker)},
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "..a", .is_row_variable = true },
                .{ .name = "pred", .quotation_effect = &pred_annotation },
                .{ .name = "body", .quotation_effect = &body_annotation },
            },
            .outputs = &.{
                .{ .name = "..b", .is_row_variable = true },
            },
        },
        .action = .{ .native = dummy },
    });

    // pred: [ 1 t ] => delta = 2, adj = 2 - 1 = 1
    const pred_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .boolean = true } }),
    };

    // body: [ ] => delta = 0, adj = 0
    const loop_body: []const Instruction = &.{};

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = pred_body } } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = loop_body } } }),
        makeInstr(.{ .call_word = "while" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "row-poly keep with insufficient stack falls through" {
    // When the stack model has fewer entries than concreteInputCount,
    // handleRowPoly should return .fallthrough
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const quot_annotation = StackEffect{
        .inputs = &.{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &.{
            .{ .name = "..b", .is_row_variable = true },
        },
    };

    try dict.put("keep", .{
        .name = "keep",
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "..a", .is_row_variable = true },
                .{ .name = "x" },
                .{ .name = "quot", .quotation_effect = &quot_annotation },
            },
            .outputs = &.{
                .{ .name = "..b", .is_row_variable = true },
                .{ .name = "x" },
            },
        },
        .action = .{ .native = dummy },
    });

    // Body only pushes the quotation -- x comes from outer scope.
    // Stack model has only 1 entry but keep needs 2 concrete inputs.
    const drop_body: []const Instruction = &.{};
    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = drop_body } } }),
        makeInstr(.{ .call_word = "keep" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    // Falls through to inferWord which returns unknown for row-poly keep
    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "row-poly keep with non-literal quotation falls through" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: @import("dictionary.zig").NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    const quot_annotation = StackEffect{
        .inputs = &.{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &.{
            .{ .name = "..b", .is_row_variable = true },
        },
    };

    try dict.put("keep", .{
        .name = "keep",
        .stack_effect = .{
            .inputs = &.{
                .{ .name = "..a", .is_row_variable = true },
                .{ .name = "x" },
                .{ .name = "quot", .quotation_effect = &quot_annotation },
            },
            .outputs = &.{
                .{ .name = "..b", .is_row_variable = true },
                .{ .name = "x" },
            },
        },
        .action = .{ .native = dummy },
    });

    try dict.put("get-quot", .{
        .name = "get-quot",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "q" }},
        },
        .action = .{ .native = dummy },
    });

    // Both args come from runtime -- quotation arg is .other in stack model
    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .call_word = "get-quot" }),
        makeInstr(.{ .call_word = "keep" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, .err, false);
    defer engine.deinit();

    // Falls through to inferWord which returns unknown for row-poly keep
    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}
