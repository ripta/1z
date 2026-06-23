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
const TypeValue = value_mod.TypeValue;

const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;

const helpers = @import("primitives/helpers.zig");
const markers = @import("primitives/markers.zig");
const protocols_mod = @import("primitives/protocols.zig");
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
    note,
};

pub const Diagnostic = struct {
    word_name: []const u8,
    source_file: ?[]const u8,
    source_line: usize,
    severity: Severity,
    message: []const u8,
};

/// A quotation-local definition (`name: [ body ] ;`) compiles to an instruction
/// sequence: the name symbol (deepest), optional metadata producers, the body
/// quotation, then a `;` call. Given the index of the `;` call, recover the
/// defined name by scanning backward over the body and its metadata. Returns
/// null for any shape that is not a `name: [ body ] ;` definition, so detection
/// stays conservative and only fires on the quotation-body form.
const LocalDefName = struct { name: []const u8, line: usize };
fn recoverLocalName(instructions: []const Instruction, semi_index: usize) ?LocalDefName {
    if (semi_index == 0) return null;
    var i = semi_index - 1; // the body/value item the `;` consumes from the top
    switch (instructions[i].op) {
        .push_literal => |val| if (val != .quotation) return null,
        else => return null,
    }
    while (i > 0) {
        i -= 1;
        switch (instructions[i].op) {
            .push_literal => |val| switch (val) {
                .doc_string, .stack_effect => continue,
                .symbol => |s| return .{ .name = s, .line = instructions[i].line },
                else => return null,
            },
            // A marker (or `const`) before the body is produced by a word call.
            .call_word, .call_word_direct => continue,
        }
    }
    return null;
}

/// A `case` branches array has a default arm when at least one top-level
/// element is a bare quotation; keyed arms are nested arrays `{ key [body] }`.
fn caseBranchesHaveDefault(branches: []const Value) bool {
    for (branches) |elem| if (elem == .quotation) return true;
    return false;
}

/// A quotation-local definition encountered while walking a body, together with
/// whether it has been referenced. Scoped to a single body walk, so combinator
/// arms get their own fresh set.
const LocalDef = struct { name: []const u8, line: usize, referenced: bool };

/// Mark a local as referenced when a nested quotation literal within the body
/// calls it. A reference at any nesting depth counts, since a closure over an
/// outer local is an intentional pattern. Only nested quotations are descended;
/// top-level references are handled inline during the body walk, so that path's
/// behavior is left untouched. Run after the full walk records every local, so
/// a forward reference where a quotation literal precedes the local's `;`
/// definition still counts.
fn markNestedLocalReferences(locals: []LocalDef, instructions: []const Instruction) void {
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| if (val == .quotation) {
                markLocalReferencesDeep(locals, val.quotation.instructions);
            },
            else => {},
        }
    }
}

fn markLocalReferencesDeep(locals: []LocalDef, instructions: []const Instruction) void {
    for (instructions) |instr| {
        switch (instr.op) {
            .call_word, .call_word_direct => {
                const name = instr.op.callTargetName() orelse continue;
                for (locals) |*ld| {
                    if (!ld.referenced and std.mem.eql(u8, ld.name, name)) {
                        ld.referenced = true;
                        break;
                    }
                }
            },
            .push_literal => |val| if (val == .quotation) {
                markLocalReferencesDeep(locals, val.quotation.instructions);
            },
        }
    }
}

/// Derived settings that control how `InferenceEngine` runs a static-analysis
/// pass. Produced by `readCheckPragmas` from the current pragma stack so that
/// both the CLI `--check` path and the `onez_check` C API honor pragmas
/// identically.
pub const CheckPragmaSettings = struct {
    severity_override: ?Severity,
    suppressed: bool,
    suppress_undeclared: bool,
    type_check_mode: InferenceEngine.TypeCheckMode,
    arity_check_mode: InferenceEngine.ArityCheckMode,
};

/// Read the `suppress-checks`, `suppress-undeclared`, `type-check`, and
/// `callsite-arity-mismatch` pragmas from the given context and translate
/// them into the settings consumed by `InferenceEngine.init`.
pub fn readCheckPragmas(ctx: *const Context) CheckPragmaSettings {
    var settings: CheckPragmaSettings = .{
        .severity_override = null,
        .suppressed = false,
        .suppress_undeclared = false,
        .type_check_mode = .err,
        .arity_check_mode = .err,
    };

    if (ctx.getPragma("suppress-checks")) |pragma_val| {
        switch (pragma_val) {
            .string => |s| {
                if (std.mem.eql(u8, s, "warn-only")) {
                    settings.severity_override = .warning;
                } else if (std.mem.eql(u8, s, "all")) {
                    settings.suppressed = true;
                }
            },
            else => {},
        }
    }

    if (ctx.getPragma("suppress-undeclared")) |pragma_val| {
        switch (pragma_val) {
            .boolean => |b| {
                settings.suppress_undeclared = b;
            },
            else => {},
        }
    }

    if (ctx.getPragma("type-check")) |pragma_val| {
        switch (pragma_val) {
            .string => |s| {
                if (std.mem.eql(u8, s, "off")) {
                    settings.type_check_mode = .off;
                } else if (std.mem.eql(u8, s, "warning")) {
                    settings.type_check_mode = .warning;
                }
            },
            else => {},
        }
    }

    if (ctx.getPragma("callsite-arity-mismatch")) |pragma_val| {
        switch (pragma_val) {
            .string => |s| {
                if (std.mem.eql(u8, s, "off")) {
                    settings.arity_check_mode = .off;
                } else if (std.mem.eql(u8, s, "warning")) {
                    settings.arity_check_mode = .warning;
                }
            },
            else => {},
        }
    }

    return settings;
}

const max_union_types = 8;

/// Static-analysis stack entry for a concrete typed value.
///
/// Unlike a bare `TypeValue`, this preserves the extra fallback relationships
/// that runtime type checks honor for tagged values:
///
/// - `parent_type` for enum variants satisfying their parent enum
/// - `base_type` for parameterized wrappers satisfying their base type
const TypedEntry = struct {
    tv: *const TypeValue,
    parent_type: ?*const TypeValue = null,
    base_type: ?*const TypeValue = null,

    fn matches(self: TypedEntry, expected: *const TypeValue, any_type_sentinel: ?*const TypeValue) bool {
        if (any_type_sentinel) |any_tv| {
            if (expected == any_tv) return true;
        }

        if (helpers.typeMatchesConstraint(self.tv, expected)) return true;
        if (self.parent_type) |pt| {
            if (helpers.typeMatchesConstraint(pt, expected)) return true;
        }
        if (self.base_type) |bt| {
            if (helpers.typeMatchesConstraint(bt, expected)) return true;
        }

        return false;
    }
};

const TypeUnion = struct {
    types: [max_union_types]TypedEntry = undefined,
    len: usize = 0,

    fn add(self: *TypeUnion, entry: TypedEntry) void {
        for (self.types[0..self.len]) |existing| {
            if (existing.tv == entry.tv and existing.parent_type == entry.parent_type and existing.base_type == entry.base_type) return;
        }
        if (self.len < max_union_types) {
            self.types[self.len] = entry;
            self.len += 1;
        }
    }

    fn allMatch(self: *const TypeUnion, expected: *const TypeValue, any_type_sentinel: ?*const TypeValue) bool {
        for (self.types[0..self.len]) |entry| {
            if (!entry.matches(expected, any_type_sentinel)) return false;
        }
        return true;
    }

    fn format(self: *const TypeUnion, allocator: Allocator) ![]const u8 {
        var parts: std.ArrayListUnmanaged([]const u8) = .{};
        defer parts.deinit(allocator);
        for (self.types[0..self.len]) |entry| {
            try parts.append(allocator, entry.tv.name);
        }
        return std.mem.join(allocator, " | ", parts.items);
    }
};

const StackEntry = union(enum) {
    quotation: Quotation,
    typed: TypedEntry,
    typed_union: TypeUnion,
    protocol_bounded: *const value_mod.ProtocolDescriptor,
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
    severity_override: ?Severity,
    suppressed: bool,
    suppress_undeclared: bool,
    checked_source: ?[]const u8,
    builtin_type_values: ?*const std.StringHashMapUnmanaged(*TypeValue),
    any_type_sentinel: ?*const TypeValue,
    type_check_mode: TypeCheckMode,
    arity_check_mode: ArityCheckMode,
    type_cache: std.StringHashMapUnmanaged(?[]StackEntry),
    ctx: ?*Context,

    // Set by inferInstructions when it returns .unknown
    last_unknown_callee: ?[]const u8 = null,
    last_unknown_is_polymorphic: bool = false,

    // Set by inferInstructions on every exit: true when the body it just
    // walked diverges (ends dead-code), false otherwise. Read by the
    // combinator handlers immediately after analyzing a quotation arm.
    body_terminal: bool = false,

    pub const TypeCheckMode = enum { err, warning, off };
    pub const ArityCheckMode = enum { err, warning, off };

    pub fn init(
        dictionary: *const Dictionary,
        dispatch_table: *const DispatchTable,
        local_frames: []const LocalFrame,
        allocator: Allocator,
        severity_override: ?Severity,
        suppressed: bool,
        suppress_undeclared: bool,
        builtin_type_values: ?*const std.StringHashMapUnmanaged(*TypeValue),
        any_type_sentinel: ?*const TypeValue,
        type_check_mode: TypeCheckMode,
        arity_check_mode: ArityCheckMode,
        ctx: ?*Context,
    ) InferenceEngine {
        return .{
            .dictionary = dictionary,
            .dispatch_table = dispatch_table,
            .local_frames = local_frames,
            .allocator = allocator,
            .cache = .{},
            .in_progress = .{},
            .diagnostics = .{},
            .type_cache = .{},
            .severity_override = severity_override,
            .suppressed = suppressed,
            .suppress_undeclared = suppress_undeclared,
            .checked_source = null,
            .builtin_type_values = builtin_type_values,
            .any_type_sentinel = any_type_sentinel,
            .type_check_mode = type_check_mode,
            .arity_check_mode = arity_check_mode,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *InferenceEngine) void {
        for (self.diagnostics.items) |d| {
            self.allocator.free(d.message);
        }
        self.diagnostics.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.in_progress.deinit(self.allocator);

        var tc_iter = self.type_cache.iterator();
        while (tc_iter.next()) |entry| {
            if (entry.value_ptr.*) |types| {
                self.allocator.free(types);
            }
        }
        self.type_cache.deinit(self.allocator);
    }

    pub fn analyzeAll(self: *InferenceEngine, checked_source: ?[]const u8) Allocator.Error!void {
        self.checked_source = checked_source;
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

    fn descriptorName(self: *const InferenceEngine, desc: *const value_mod.TypeDescriptor) []const u8 {
        if (desc.kind == .sentinel) return "";
        const btv = self.builtin_type_values orelse return "<descriptor>";
        var iter = btv.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.descriptor) |tv_desc| {
                if (tv_desc == desc) return entry.key_ptr.*;
            }
        }
        return "<descriptor>";
    }

    pub fn hasErrors(self: *const InferenceEngine) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }

    fn isInCheckedSource(self: *const InferenceEngine, source_file: ?[]const u8) bool {
        const checked = self.checked_source orelse return true;
        const sf = source_file orelse return false;
        return std.mem.eql(u8, sf, checked);
    }

    fn lookupWord(self: *const InferenceEngine, name: []const u8) ?WordDefinition {
        var i = self.local_frames.len;
        while (i > 0) {
            i -= 1;
            if (self.local_frames[i].get(name)) |def| return def;
        }

        return self.dictionary.get(name);
    }

    fn resolveQualifiedName(self: *const InferenceEngine, name: []const u8) ?value_mod.ModuleWord {
        const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
        const module_path = name[0..dot_index];
        const word_name = name[dot_index + 1 ..];
        if (module_path.len == 0 or word_name.len == 0) return null;

        const module_word_def = self.lookupWord(module_path) orelse return null;
        const instrs = switch (module_word_def.action) {
            .compound => |i| i,
            .native, .host_callback => return null,
        };
        if (instrs.len != 1) return null;
        const module_ptr = switch (instrs[0].op) {
            .push_literal => |val| switch (val) {
                .module => |m| m,
                else => return null,
            },
            else => return null,
        };
        return module_ptr.words.get(word_name);
    }

    fn inferWord(self: *InferenceEngine, name: []const u8) Allocator.Error!InferenceResult {
        if (self.cache.get(name)) |cached| return cached;

        if (self.in_progress.contains(name)) {
            const word_def = self.lookupWord(name) orelse return .unknown;
            if (word_def.stack_effect) |eff| {
                if (!self.type_cache.contains(name)) {
                    const out_types = try self.allocator.alloc(StackEntry, eff.outputs.len);
                    for (eff.outputs, 0..) |param, i| {
                        out_types[i] = if (param.type_annotation) |ann| switch (ann) {
                            .type => |tv| StackEntry{ .typed = .{ .tv = tv } },
                            .protocol => |desc| StackEntry{ .protocol_bounded = desc },
                            .combination => .other,
                        } else .other;
                    }
                    try self.type_cache.put(self.allocator, name, out_types);
                }
                return computeDeclaredDelta(eff) orelse .unknown;
            }
            return .unknown;
        }

        const word_def = self.lookupWord(name) orelse return .unknown;
        switch (word_def.action) {
            .native, .host_callback => {
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
                    if (isGeneric(&word_def) and instructions.len == 0) {
                        if (!self.type_cache.contains(name)) {
                            const out_types = try self.allocator.alloc(StackEntry, eff.outputs.len);
                            for (eff.outputs, 0..) |param, i| {
                                out_types[i] = if (param.type_annotation) |ann| switch (ann) {
                                    .type => |tv| StackEntry{ .typed = .{ .tv = tv } },
                                    .protocol => |desc| StackEntry{ .protocol_bounded = desc },
                                    .combination => .other,
                                } else .other;
                            }
                            try self.type_cache.put(self.allocator, name, out_types);
                        }
                        const result = computeDeclaredDelta(eff) orelse .unknown;
                        try self.cache.put(self.allocator, name, result);
                        return result;
                    }
                }

                try self.in_progress.put(self.allocator, name, {});
                const declared_inputs: ?usize = if (word_def.stack_effect) |eff| blk: {
                    if (stack_effect_mod.hasAnyRowVariable(eff)) break :blk null;
                    break :blk eff.concreteInputCount();
                } else null;
                const caller_info = CallerInfo{
                    .word_name = name,
                    .source_file = word_def.source_file,
                    .source_line = word_def.source_line,
                    .declared_input_count = declared_inputs,
                };
                var body_out_stack: std.ArrayListUnmanaged(StackEntry) = .{};
                defer body_out_stack.deinit(self.allocator);
                const inferred = try self.inferInstructions(instructions, caller_info, &body_out_stack);
                _ = self.in_progress.fetchRemove(name);

                if (inferred == .known and body_out_stack.items.len > 0) {
                    const cached_types = try self.allocator.alloc(StackEntry, body_out_stack.items.len);
                    @memcpy(cached_types, body_out_stack.items);
                    if (self.type_cache.get(name)) |existing| {
                        if (existing) |old| self.allocator.free(old);
                    }
                    try self.type_cache.put(self.allocator, name, cached_types);
                }

                const generic_uses_declared_delta = isGeneric(&word_def) and instructions.len == 0 and word_def.stack_effect != null;
                const inferred_for_delta = if (generic_uses_declared_delta)
                    computeDeclaredDelta(word_def.stack_effect.?) orelse inferred
                else
                    inferred;

                if (isGeneric(&word_def)) {
                    try self.validateDispatchEntries(name, inferred_for_delta, &word_def, caller_info);
                    if (inferred == .known) {
                        if (self.conversionTarget(name, &word_def)) |target| {
                            try self.checkConversionOutput(name, &word_def, target, &body_out_stack, null);
                        }
                    }
                }

                if (word_def.stack_effect) |eff| {
                    if (computeDeclaredDelta(eff)) |declared| {
                        switch (inferred_for_delta) {
                            .known => |inferred_delta| {
                                if (declared.known != inferred_delta) {
                                    try self.emitDiagnostic(.{
                                        .word_name = name,
                                        .source_file = word_def.source_file,
                                        .source_line = word_def.source_line,
                                        .severity = .err,
                                        .message = try std.fmt.allocPrint(
                                            self.allocator,
                                            "declared stack effect delta is {d}, but inferred delta is {d}",
                                            .{ declared.known, inferred_delta },
                                        ),
                                    });
                                }
                            },
                            .unknown => {
                                if (self.last_unknown_callee) |callee_name| {
                                    if (self.isInCheckedSource(word_def.source_file) and word_def.source_module == null) {
                                        if (self.last_unknown_is_polymorphic) {
                                            if (word_def.provenance == null) {
                                                try self.emitDiagnostic(.{
                                                    .word_name = name,
                                                    .source_file = word_def.source_file,
                                                    .source_line = word_def.source_line,
                                                    .severity = .note,
                                                    .message = try std.fmt.allocPrint(
                                                        self.allocator,
                                                        "callee {s} is polymorphic; effect trusted from declaration",
                                                        .{callee_name},
                                                    ),
                                                });
                                            }
                                        } else {
                                            try self.emitDiagnostic(.{
                                                .word_name = name,
                                                .source_file = word_def.source_file,
                                                .source_line = word_def.source_line,
                                                .severity = .warning,
                                                .message = try std.fmt.allocPrint(
                                                    self.allocator,
                                                    "cannot verify {s}: callee {s} has unknown effect",
                                                    .{ name, callee_name },
                                                ),
                                            });
                                        }
                                    }
                                }
                                try self.cache.put(self.allocator, name, declared);
                                return declared;
                            },
                        }
                    }
                } else if (!self.suppress_undeclared and self.isInCheckedSource(word_def.source_file)) {
                    try self.emitDiagnostic(.{
                        .word_name = name,
                        .source_file = word_def.source_file,
                        .source_line = word_def.source_line,
                        .severity = .warning,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "word has no declared stack effect",
                            .{},
                        ),
                    });
                }

                try self.cache.put(self.allocator, name, inferred);
                return inferred;
            },
        }
    }

    fn resolveValueType(self: *const InferenceEngine, val: Value) ?*const TypeValue {
        const btv = self.builtin_type_values orelse return null;
        const type_name = dispatch_mod.dispatchTypeName(val);
        return btv.get(type_name);
    }

    fn stackEntryForValue(self: *const InferenceEngine, val: Value) StackEntry {
        switch (val) {
            .quotation => |quot| return .{ .quotation = quot },
            .tagged => |tagged| {
                const tv = tagged.tag.type_val orelse return .other;
                return .{ .typed = .{
                    .tv = tv,
                    .parent_type = tagged.tag.parent_type,
                    .base_type = tagged.tag.base_type,
                } };
            },
            else => {
                if (self.resolveValueType(val)) |tv| {
                    return .{ .typed = .{ .tv = tv } };
                }
                return .other;
            },
        }
    }

    fn inferInstructions(
        self: *InferenceEngine,
        instructions: []const Instruction,
        caller: CallerInfo,
        out_stack: ?*std.ArrayListUnmanaged(StackEntry),
    ) Allocator.Error!InferenceResult {
        self.last_unknown_callee = null;
        self.last_unknown_is_polymorphic = false;
        var body_is_terminal = false;
        defer self.body_terminal = body_is_terminal;
        var delta: i64 = 0;
        var stack_model: std.ArrayListUnmanaged(StackEntry) = .{};
        defer stack_model.deinit(self.allocator);
        var uncertain: bool = false;
        var uncertain_source: ?[]const u8 = null;
        var uncertain_is_polymorphic: bool = false;
        var uncertain_is_dynamic: bool = false;
        var dead_code: bool = false;
        var dead_code_warned: bool = false;
        const DeadCodeCause = union(enum) { underflow, terminal_call: []const u8, terminal_branch };
        var dead_code_cause: ?DeadCodeCause = null;

        // Quotation-local definitions encountered while walking this body, with
        // whether each is referenced by a direct call in the same body or by a
        // call inside a nested quotation literal. Scoped to this invocation, so
        // combinator arms get their own fresh set.
        var locals: std.ArrayListUnmanaged(LocalDef) = .{};
        defer locals.deinit(self.allocator);

        for (instructions, 0..) |instr, idx| {
            if (dead_code) {
                if (!dead_code_warned) {
                    const message = switch (dead_code_cause orelse .underflow) {
                        .terminal_call => |terminal| try std.fmt.allocPrint(
                            self.allocator,
                            "dead code: unreachable after call to never-returns word '{s}'",
                            .{terminal},
                        ),
                        .terminal_branch => try std.fmt.allocPrint(
                            self.allocator,
                            "dead code: unreachable after branch where every arm is terminal",
                            .{},
                        ),
                        .underflow => try std.fmt.allocPrint(
                            self.allocator,
                            "dead code: unreachable after guaranteed underflow",
                            .{},
                        ),
                    };
                    try self.emitDiagnostic(.{
                        .word_name = caller.word_name,
                        .source_file = caller.source_file,
                        .source_line = instr.line,
                        .severity = .warning,
                        .message = message,
                    });
                    dead_code_warned = true;
                }
                continue;
            }
            switch (instr.op) {
                .push_literal => |val| {
                    delta += 1;
                    try stack_model.append(self.allocator, self.stackEntryForValue(val));
                },
                .call_word, .call_word_direct => {
                    const name = instr.op.callTargetName().?;

                    // A `;` call defines a quotation-local; record it (still let
                    // `;` fall through to normal handling below as a native).
                    if (std.mem.eql(u8, name, ";")) {
                        if (recoverLocalName(instructions, idx)) |def| {
                            try locals.append(self.allocator, .{ .name = def.name, .line = def.line, .referenced = false });
                        }
                    }

                    const word_def = self.lookupWord(name);
                    if (word_def == null) {
                        // A reference to one of this body's quotation-locals.
                        for (locals.items) |*ld| {
                            if (std.mem.eql(u8, ld.name, name)) {
                                ld.referenced = true;
                                break;
                            }
                        }
                        if (std.mem.indexOfScalar(u8, name, '.') != null) {
                            if (self.resolveQualifiedName(name)) |mod_word| {
                                if (mod_word.polymorphic) {
                                    if (mod_word.stack_effect) |eff| {
                                        if (computeDeclaredDelta(eff)) |result| {
                                            delta += result.known;
                                            try adjustStackModel(&stack_model, result.known, self.allocator);
                                            uncertain = true;
                                            uncertain_source = name;
                                            uncertain_is_polymorphic = true;
                                            uncertain_is_dynamic = false;
                                            continue;
                                        }
                                    }
                                    self.last_unknown_callee = name;
                                    self.last_unknown_is_polymorphic = true;
                                    return .unknown;
                                }
                                if (mod_word.stack_effect) |eff| {
                                    if (computeDeclaredDelta(eff)) |result| {
                                        delta += result.known;
                                        try adjustStackModel(&stack_model, result.known, self.allocator);
                                        continue;
                                    }
                                }
                                self.last_unknown_callee = name;
                                self.last_unknown_is_polymorphic = false;
                                return .unknown;
                            }
                        }
                        self.last_unknown_callee = name;
                        self.last_unknown_is_polymorphic = false;
                        return .unknown;
                    }
                    const wd = word_def.?;

                    const combinator_kind = classifyCombinator(&wd);

                    // A `case` whose branches array literal has no default arm
                    // can fall through to a `no-matching-branch` runtime error.
                    // The branches array is the literal pushed just before the
                    // call; a dynamically built value is not inspectable here and
                    // is left unchecked. Emit before dispatch so the warning
                    // fires regardless of the combinator path taken below.
                    if (idx > 0 and combinator_kind == .branch and std.mem.eql(u8, name, "case") and self.isInCheckedSource(caller.source_file)) {
                        switch (instructions[idx - 1].op) {
                            .push_literal => |val| if (val == .array and !caseBranchesHaveDefault(val.array)) {
                                try self.emitDiagnostic(.{
                                    .word_name = caller.word_name,
                                    .source_file = caller.source_file,
                                    .source_line = instr.line,
                                    .severity = .warning,
                                    .message = try std.fmt.allocPrint(
                                        self.allocator,
                                        "case expression has no default arm",
                                        .{},
                                    ),
                                });
                            },
                            else => {},
                        }
                    }

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

                                    if (applied.output_types) |out_types| {
                                        defer self.allocator.free(out_types);
                                        for (out_types) |entry| {
                                            try stack_model.append(self.allocator, entry);
                                        }
                                    } else {
                                        var i: usize = 0;
                                        while (i < applied.new_model_size) : (i += 1) {
                                            try stack_model.append(self.allocator, .other);
                                        }
                                    }
                                    if (applied.terminal) {
                                        dead_code = true;
                                        dead_code_cause = .terminal_branch;
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

                                        if (applied.output_types) |out_types| {
                                            defer self.allocator.free(out_types);
                                            for (out_types) |entry| {
                                                try stack_model.append(self.allocator, entry);
                                            }
                                        } else {
                                            var i: usize = 0;
                                            while (i < applied.new_model_size) : (i += 1) {
                                                try stack_model.append(self.allocator, .other);
                                            }
                                        }
                                        if (applied.terminal) {
                                            dead_code = true;
                                            dead_code_cause = .terminal_branch;
                                        }
                                        continue;
                                    },
                                    .unknown => return .unknown,
                                    .fallthrough => {},
                                }
                            }
                        }
                    }

                    if (self.type_check_mode != .off) {
                        try self.checkInputTypes(&wd, &stack_model, caller);
                    }

                    if (self.arity_check_mode != .off) {
                        const guaranteed = try self.checkCallsiteArity(&wd, name, delta, caller, instr.line, uncertain, uncertain_source);
                        if (guaranteed) {
                            dead_code = true;
                            dead_code_cause = .underflow;
                            continue;
                        }
                    }

                    for (wd.markers) |mk| {
                        if (markers.isNeverReturnsMarker(mk)) {
                            dead_code = true;
                            dead_code_cause = .{ .terminal_call = name };
                            break;
                        }
                    }
                    if (dead_code) continue;

                    if (isDynamicCall(&wd)) {
                        if (wd.stack_effect) |eff| {
                            if (computeDeclaredDelta(eff)) |result| {
                                delta += result.known;
                                try adjustStackModel(&stack_model, result.known, self.allocator);
                                uncertain = true;
                                uncertain_source = name;
                                uncertain_is_dynamic = true;
                                continue;
                            }
                        }
                    }

                    const callee_result = try self.inferWord(name);
                    switch (callee_result) {
                        .known => |callee_delta| {
                            delta += callee_delta;
                            try self.adjustStackModelTyped(&wd, &stack_model, callee_delta);
                        },
                        .unknown => {
                            if (wd.stack_effect) |eff| {
                                if (computeDeclaredDelta(eff)) |result| {
                                    delta += result.known;
                                    try adjustStackModel(&stack_model, result.known, self.allocator);
                                    uncertain = true;
                                    uncertain_source = name;
                                    uncertain_is_dynamic = false;
                                    continue;
                                }
                            }
                            return .unknown;
                        },
                    }
                },
            }
        }

        body_is_terminal = dead_code;

        if (dead_code or uncertain) {
            if (uncertain and uncertain_source != null and !uncertain_is_dynamic) {
                self.last_unknown_callee = uncertain_source;
                self.last_unknown_is_polymorphic = uncertain_is_polymorphic;
            }
            return .unknown;
        }

        // The body walked cleanly to completion, so a local with no recorded
        // reference is genuinely unused in this quotation. A reference inside a
        // nested quotation literal counts as usage, so scan those now that every
        // local is known.
        if (locals.items.len > 0) markNestedLocalReferences(locals.items, instructions);
        for (locals.items) |ld| {
            if (ld.referenced) continue;
            try self.emitDiagnostic(.{
                .word_name = caller.word_name,
                .source_file = caller.source_file,
                .source_line = ld.line,
                .severity = .warning,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "unused quotation-local definition '{s}'",
                    .{ld.name},
                ),
            });
        }

        if (out_stack) |os| {
            os.shrinkRetainingCapacity(0);
            try os.ensureTotalCapacity(self.allocator, stack_model.items.len);
            os.appendSliceAssumeCapacity(stack_model.items);
        }

        return .{ .known = delta };
    }

    const CallerInfo = struct {
        word_name: []const u8,
        source_file: ?[]const u8,
        source_line: usize,
        declared_input_count: ?usize = null,
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
        applied: struct {
            new_delta: i64,
            new_model_size: usize,
            output_types: ?[]StackEntry = null,
            terminal: bool = false,
        },
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
        var quot_arm_count: usize = 0;
        var all_arms_terminal = true;

        const max_branch_stacks = 8;
        var branch_stacks: [max_branch_stacks]std.ArrayListUnmanaged(StackEntry) = undefined;
        var branch_stack_count: usize = 0;
        defer for (branch_stacks[0..branch_stack_count]) |*bs| bs.deinit(self.allocator);

        for (0..input_count) |param_index| {
            if (stack_model.items.len < input_count) break;
            const stack_pos = stack_model.items.len - input_count + param_index;

            switch (stack_model.items[stack_pos]) {
                .quotation => |quot| {
                    found_any_quot = true;
                    quot_arm_count += 1;
                    var branch_out: std.ArrayListUnmanaged(StackEntry) = .{};
                    var quot_caller = caller;
                    quot_caller.declared_input_count = null;

                    const qd = try self.inferInstructions(quot.instructions, quot_caller, &branch_out);
                    if (!self.body_terminal) all_arms_terminal = false;
                    switch (qd) {
                        .known => |d| {
                            try quot_deltas.append(self.allocator, d);
                            if (branch_stack_count < max_branch_stacks) {
                                branch_stacks[branch_stack_count] = branch_out;
                                branch_stack_count += 1;
                            } else {
                                branch_out.deinit(self.allocator);
                            }
                        },
                        .unknown => {
                            all_literal = false;
                            branch_out.deinit(self.allocator);
                        },
                    }
                },
                .typed, .typed_union, .protocol_bounded, .other => {},
            }
        }

        if (kind == .branch and quot_arm_count >= 2 and all_arms_terminal) {
            const consumed = @min(stack_model.items.len, input_count);
            const new_model_size = stack_model.items.len - consumed;
            return .{ .applied = .{
                .new_delta = current_delta + declared.known,
                .new_model_size = new_model_size,
                .terminal = true,
            } };
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

                const merged = try self.mergeBranchTypes(branch_stacks[0..branch_stack_count]);
                return .{ .applied = .{
                    .new_delta = total_delta,
                    .new_model_size = new_model_size,
                    .output_types = merged,
                } };
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

    fn mergeBranchTypes(
        self: *InferenceEngine,
        branch_stacks: []std.ArrayListUnmanaged(StackEntry),
    ) Allocator.Error!?[]StackEntry {
        if (branch_stacks.len == 0) return null;

        const first = branch_stacks[0].items;
        if (first.len == 0) return null;

        for (branch_stacks[1..]) |bs| {
            if (bs.items.len != first.len) return null;
        }

        const result = try self.allocator.alloc(StackEntry, first.len);
        for (0..first.len) |i| {
            result[i] = first[i];
            for (branch_stacks[1..]) |bs| {
                result[i] = mergeEntry(result[i], bs.items[i]);
            }
        }
        return result;
    }

    fn mergeEntry(a: StackEntry, b: StackEntry) StackEntry {
        switch (a) {
            .other => return .other,
            .quotation => return .other,
            .typed => |tv_a| {
                switch (b) {
                    .typed => |tv_b| {
                        if (tv_a.tv == tv_b.tv and tv_a.parent_type == tv_b.parent_type and tv_a.base_type == tv_b.base_type) return a;
                        var u = TypeUnion{};
                        u.add(tv_a);
                        u.add(tv_b);
                        return .{ .typed_union = u };
                    },
                    .typed_union => |tu_b| {
                        var u = tu_b;
                        u.add(tv_a);
                        return .{ .typed_union = u };
                    },
                    else => return .other,
                }
            },
            .typed_union => |tu_a| {
                switch (b) {
                    .typed => |tv_b| {
                        var u = tu_a;
                        u.add(tv_b);
                        return .{ .typed_union = u };
                    },
                    .typed_union => |tu_b| {
                        var u = tu_a;
                        for (tu_b.types[0..tu_b.len]) |tv| u.add(tv);
                        return .{ .typed_union = u };
                    },
                    else => return .other,
                }
            },
            .protocol_bounded => |desc_a| {
                switch (b) {
                    .protocol_bounded => |desc_b| {
                        if (desc_a == desc_b) return a;
                        return .other;
                    },
                    else => return .other,
                }
            },
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

        const max_rp_stacks = 8;
        var rp_branch_stacks: [max_rp_stacks]std.ArrayListUnmanaged(StackEntry) = undefined;
        var rp_branch_count: usize = 0;
        defer for (rp_branch_stacks[0..rp_branch_count]) |*bs| bs.deinit(self.allocator);

        var all_literal = true;
        var found_any_quot = false;
        var quot_arm_count: usize = 0;
        var all_arms_terminal = true;
        var concrete_index: usize = 0;
        for (eff.inputs) |param| {
            if (param.is_row_variable) continue;
            defer concrete_index += 1;

            if (param.quotation_effect) |annotation| {
                found_any_quot = true;
                const stack_pos = stack_model.items.len - concrete_inputs + concrete_index;
                switch (stack_model.items[stack_pos]) {
                    .quotation => |quot| {
                        quot_arm_count += 1;
                        var rp_out: std.ArrayListUnmanaged(StackEntry) = .{};
                        var quot_caller = caller;
                        quot_caller.declared_input_count = null;

                        const qd = try self.inferInstructions(quot.instructions, quot_caller, &rp_out);
                        if (!self.body_terminal) all_arms_terminal = false;
                        switch (qd) {
                            .known => |d| {
                                const annotated_qcd = annotation.concreteDelta();
                                try adjustments.append(self.allocator, d - annotated_qcd);
                                if (rp_branch_count < max_rp_stacks) {
                                    rp_branch_stacks[rp_branch_count] = rp_out;
                                    rp_branch_count += 1;
                                } else {
                                    rp_out.deinit(self.allocator);
                                }
                            },
                            .unknown => {
                                all_literal = false;
                                rp_out.deinit(self.allocator);
                            },
                        }
                    },
                    .typed, .typed_union, .protocol_bounded, .other => {
                        all_literal = false;
                        all_arms_terminal = false;
                    },
                }
            }
        }

        if (kind == .branch and quot_arm_count >= 2 and all_arms_terminal) {
            const consumed = @min(stack_model.items.len, concrete_inputs);
            const new_model_size = stack_model.items.len - consumed;
            return .{ .applied = .{
                .new_delta = current_delta + eff.concreteDelta(),
                .new_model_size = new_model_size,
                .terminal = true,
            } };
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
                            "loop quotations have unbalanced row variable adjustment (net {d})",
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

                const merged = try self.mergeBranchTypes(rp_branch_stacks[0..rp_branch_count]);
                return .{ .applied = .{
                    .new_delta = current_delta + concrete_delta + first,
                    .new_model_size = new_model_size,
                    .output_types = merged,
                } };
            },

            .none => {
                var adj_sum: i64 = 0;
                for (adjustments.items) |adj| adj_sum += adj;

                const out_types = if (rp_branch_count == 1) blk: {
                    const items = rp_branch_stacks[0].items;
                    if (items.len > 0) {
                        const result = try self.allocator.alloc(StackEntry, items.len);
                        @memcpy(result, items);
                        break :blk result;
                    }
                    break :blk null;
                } else try self.mergeBranchTypes(rp_branch_stacks[0..rp_branch_count]);

                return .{
                    .applied = .{
                        .new_delta = current_delta + concrete_delta + adj_sum,
                        .new_model_size = new_model_size,
                        .output_types = out_types,
                    },
                };
            },
        }
    }

    fn validateDispatchEntries(self: *InferenceEngine, name: []const u8, base_result: InferenceResult, word_def: *const WordDefinition, caller: CallerInfo) Allocator.Error!void {
        const dispatch_entries = try self.dispatch_table.entriesForDispatchId(word_def.dispatch_id, self.allocator);
        defer self.allocator.free(dispatch_entries);

        const conv_target = self.conversionTarget(name, word_def);

        for (dispatch_entries) |pair| {
            const entry_instrs = switch (pair.entry.body) {
                .quotation => |q| q.instructions,
                .native_fn, .host_callback => continue,
            };
            var entry_out: std.ArrayListUnmanaged(StackEntry) = .{};
            defer entry_out.deinit(self.allocator);
            const entry_result = try self.inferInstructions(entry_instrs, caller, &entry_out);
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
                            .{ self.descriptorName(pair.key.type_a), self.descriptorName(pair.key.type_b), entry_result.known, base_result.known },
                        ),
                    });
                }
            }
            if (conv_target) |target| {
                if (entry_result == .known) {
                    try self.checkConversionOutput(name, word_def, target, &entry_out, self.descriptorName(pair.key.type_a));
                }
            }
        }
    }

    /// Convention-derived output type for a `>name` conversion word, or null
    /// when the word is not subject to the check. A `>name` word is expected to
    /// return a value of type `name`. The check is skipped unless the suffix
    /// names a known builtin type and the word declares no explicit typed top
    /// output, since an explicit annotation is the user's deliberate override.
    fn conversionTarget(self: *const InferenceEngine, name: []const u8, word_def: *const WordDefinition) ?*const TypeValue {
        if (self.type_check_mode == .off) return null;
        if (name.len < 2 or name[0] != '>') return null;
        if (!self.isInCheckedSource(word_def.source_file)) return null;

        if (word_def.stack_effect) |eff| {
            if (eff.outputs.len > 0) {
                if (eff.outputs[eff.outputs.len - 1].type_annotation != null) return null;
            }
        }

        const btv = self.builtin_type_values orelse return null;
        return btv.get(name[1..]);
    }

    /// Compare the inferred top-of-stack output of a `>name` conversion body
    /// against the convention-derived target type and emit a diagnostic on
    /// mismatch. `method_type` is the dispatching type name for a method entry,
    /// or null for the base body.
    fn checkConversionOutput(
        self: *InferenceEngine,
        name: []const u8,
        word_def: *const WordDefinition,
        target: *const TypeValue,
        out_stack: *const std.ArrayListUnmanaged(StackEntry),
        method_type: ?[]const u8,
    ) Allocator.Error!void {
        if (out_stack.items.len == 0) return;
        const top = out_stack.items[out_stack.items.len - 1];

        const mismatch_actual: ?[]const u8 = switch (top) {
            .typed => |typed| if (!typed.matches(target, self.any_type_sentinel)) typed.tv.name else null,
            .typed_union => |tu| if (!tu.allMatch(target, self.any_type_sentinel)) blk: {
                break :blk tu.format(self.allocator) catch null;
            } else null,
            .quotation, .protocol_bounded, .other => null,
        };

        const actual_name = mismatch_actual orelse return;

        const severity: Severity = if (self.type_check_mode == .warning) .warning else .err;
        const message = if (method_type) |mt|
            try std.fmt.allocPrint(
                self.allocator,
                "{s} is declared to return {s}, but method{{ {s} }} returns {s} instead",
                .{ name, target.name, mt, actual_name },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{s} is declared to return {s}, but its body returns {s} instead",
                .{ name, target.name, actual_name },
            );
        try self.emitDiagnostic(.{
            .word_name = name,
            .source_file = word_def.source_file,
            .source_line = word_def.source_line,
            .severity = severity,
            .message = message,
        });
    }

    fn checkInputTypes(
        self: *InferenceEngine,
        word_def: *const WordDefinition,
        stack_model: *const std.ArrayListUnmanaged(StackEntry),
        caller: CallerInfo,
    ) Allocator.Error!void {
        const eff = word_def.stack_effect orelse return;
        const concrete_count = eff.concreteInputCount();
        if (concrete_count == 0 or stack_model.items.len < concrete_count) return;

        var concrete_index: usize = 0;
        for (eff.inputs) |param| {
            if (param.is_row_variable) continue;
            defer concrete_index += 1;

            const ann = param.type_annotation orelse continue;
            const stack_pos = stack_model.items.len - concrete_count + concrete_index;
            const entry = stack_model.items[stack_pos];

            switch (ann) {
                .type => |expected_tv| {
                    const mismatch_actual: ?[]const u8 = switch (entry) {
                        .typed => |typed| if (!typed.matches(expected_tv, self.any_type_sentinel)) typed.tv.name else null,
                        .typed_union => |tu| if (!tu.allMatch(expected_tv, self.any_type_sentinel)) blk: {
                            break :blk tu.format(self.allocator) catch null;
                        } else null,
                        .quotation => blk: {
                            const qtv = self.resolveValueType(.{ .quotation = .{ .instructions = &.{} } });
                            if (qtv) |qtype| {
                                if (qtype != expected_tv) break :blk qtype.name;
                            }
                            break :blk null;
                        },
                        .protocol_bounded, .other => null,
                    };

                    if (mismatch_actual) |actual_name| {
                        const severity: Severity = if (self.type_check_mode == .warning) .warning else .err;
                        try self.emitDiagnostic(.{
                            .word_name = caller.word_name,
                            .source_file = caller.source_file,
                            .source_line = caller.source_line,
                            .severity = severity,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "type mismatch: {s} expects {s} for parameter '{s}', but got {s}",
                                .{ word_def.name, expected_tv.name, param.name, actual_name },
                            ),
                        });
                    }
                },
                .protocol => |descriptor| {
                    const ctx = self.ctx orelse continue;
                    const mismatch_actual: ?[]const u8 = switch (entry) {
                        .typed => |typed| blk: {
                            const satisfies = protocols_mod.satisfiesByDescriptorSameTypeOnly(ctx, typed.tv, descriptor) catch break :blk null;
                            if (satisfies) break :blk null;
                            break :blk typed.tv.name;
                        },
                        .typed_union => |tu| blk: {
                            for (tu.types[0..tu.len]) |member| {
                                const satisfies = protocols_mod.satisfiesByDescriptorSameTypeOnly(ctx, member.tv, descriptor) catch break :blk null;
                                if (!satisfies) {
                                    break :blk tu.format(self.allocator) catch null;
                                }
                            }
                            break :blk null;
                        },
                        .protocol_bounded => |actual_desc| if (actual_desc == descriptor) null else null,
                        .quotation, .other => null,
                    };

                    if (mismatch_actual) |actual_name| {
                        const severity: Severity = if (self.type_check_mode == .warning) .warning else .err;
                        try self.emitDiagnostic(.{
                            .word_name = caller.word_name,
                            .source_file = caller.source_file,
                            .source_line = caller.source_line,
                            .severity = severity,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "{s}: type '{s}' does not satisfy protocol '{s}' for parameter '{s}'",
                                .{ word_def.name, actual_name, descriptor.name, param.name },
                            ),
                        });
                    }
                },
                // Combinator output checking is not yet implemented; treat a
                // combinator-annotated output as unconstrained for now.
                .combination => {},
            }
        }
    }

    fn checkCallsiteArity(
        self: *InferenceEngine,
        word_def: *const WordDefinition,
        callee_name: []const u8,
        delta: i64,
        caller: CallerInfo,
        call_line: usize,
        is_uncertain: bool,
        uncertain_src: ?[]const u8,
    ) Allocator.Error!bool {
        const caller_inputs = caller.declared_input_count orelse return false;
        const callee_eff = word_def.stack_effect orelse return false;
        if (stack_effect_mod.hasAnyRowVariable(callee_eff)) return false;
        const required = callee_eff.concreteInputCount();
        if (required == 0) return false;
        const available = @as(i64, @intCast(caller_inputs)) + delta;
        if (available < @as(i64, @intCast(required))) {
            if (is_uncertain) {
                try self.emitDiagnostic(.{
                    .word_name = caller.word_name,
                    .source_file = caller.source_file,
                    .source_line = call_line,
                    .severity = .warning,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "potential underflow: call to '{s}' requires {d} value(s) but only {d} available (depth uncertain due to '{s}')",
                        .{ callee_name, required, available, uncertain_src orelse "unknown" },
                    ),
                });
                return false;
            }
            const severity: Severity = if (self.arity_check_mode == .warning) .warning else .err;
            try self.emitDiagnostic(.{
                .word_name = caller.word_name,
                .source_file = caller.source_file,
                .source_line = call_line,
                .severity = severity,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "call to '{s}' requires {d} value(s) but only {d} available",
                    .{ callee_name, required, available },
                ),
            });
            return severity == .err;
        }
        return false;
    }

    fn adjustStackModelTyped(
        self: *InferenceEngine,
        word_def: *const WordDefinition,
        stack_model: *std.ArrayListUnmanaged(StackEntry),
        callee_delta: i64,
    ) Allocator.Error!void {
        const eff = word_def.stack_effect orelse {
            try adjustStackModel(stack_model, callee_delta, self.allocator);
            return;
        };

        if (stack_effect_mod.hasAnyRowVariable(eff)) {
            try adjustStackModel(stack_model, callee_delta, self.allocator);
            return;
        }

        var has_typed_outputs = false;
        for (eff.outputs) |param| {
            if (param.type_annotation != null) {
                has_typed_outputs = true;
                break;
            }
        }

        if (!has_typed_outputs) {
            if (self.type_cache.get(word_def.name)) |cached_opt| {
                if (cached_opt) |cached_types| {
                    const input_count = eff.inputs.len;
                    const remove_count = @min(input_count, stack_model.items.len);
                    stack_model.shrinkRetainingCapacity(stack_model.items.len - remove_count);
                    for (cached_types) |entry| {
                        try stack_model.append(self.allocator, entry);
                    }
                    return;
                }
            }
            try adjustStackModel(stack_model, callee_delta, self.allocator);
            return;
        }

        const input_count = eff.inputs.len;
        const remove_count = @min(input_count, stack_model.items.len);
        stack_model.shrinkRetainingCapacity(stack_model.items.len - remove_count);

        for (eff.outputs) |param| {
            if (param.type_annotation) |ann| {
                switch (ann) {
                    .type => |tv| try stack_model.append(self.allocator, .{ .typed = .{ .tv = tv } }),
                    .protocol => |desc| try stack_model.append(self.allocator, .{ .protocol_bounded = desc }),
                    .combination => try stack_model.append(self.allocator, .other),
                }
            } else {
                try stack_model.append(self.allocator, .other);
            }
        }
    }

    fn emitDiagnostic(self: *InferenceEngine, diagnostic: Diagnostic) Allocator.Error!void {
        if (self.suppressed) {
            self.allocator.free(diagnostic.message);
            return;
        }
        var d = diagnostic;
        if (self.severity_override) |override| {
            d.severity = override;
        }
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

fn isDynamicCall(word_def: *const WordDefinition) bool {
    for (word_def.markers) |mk| {
        if (markers.isDynamicEvalMarker(mk)) return true;
    }
    return false;
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

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("dup", .{
        .name = "dup",
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .action = .{ .native = dummy },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("dup");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
}

test "compound word with inferrable body" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("row-word");
    try testing.expectEqual(InferenceResult.unknown, result);
}

test "branch combinator with agreeing quotations" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

fn putCaseWord(dict: *Dictionary) !void {
    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    try dict.put("case", .{
        .name = "case",
        .markers = &.{@constCast(&markers.branch_combinator_marker)},
        .stack_effect = .{
            .inputs = &.{ .{ .name = "val" }, .{ .name = "branches" } },
            .outputs = &.{.{ .name = "x" }},
        },
        .action = .{ .native = dummy },
    });
}

test "case without default arm warns" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    try putCaseWord(&dict);

    const arm_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 0 } })};
    // { { 1 [ 0 ] } } -- a single keyed arm, no bare-quotation default.
    const pair: []const Value = &.{ .{ .fixnum = 1 }, .{ .quotation = .{ .instructions = arm_body } } };
    const branches: []const Value = &.{.{ .array = pair }};

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .array = branches } }),
        makeInstr(.{ .call_word = "case" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.warning, engine.diagnostics.items[0].severity);
    try testing.expectEqualStrings("case expression has no default arm", engine.diagnostics.items[0].message);
}

test "case with default arm does not warn" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    try putCaseWord(&dict);

    const arm_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 0 } })};
    const default_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 9 } })};
    const pair: []const Value = &.{ .{ .fixnum = 1 }, .{ .quotation = .{ .instructions = arm_body } } };
    // { { 1 [ 0 ] } [ 9 ] } -- a keyed arm plus a bare-quotation default.
    const branches: []const Value = &.{
        .{ .array = pair },
        .{ .quotation = .{ .instructions = default_body } },
    };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .array = branches } }),
        makeInstr(.{ .call_word = "case" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "user word carrying dynamic-eval is treated as a dynamic call" {
    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    const eval_effect: StackEffect = .{
        .inputs = &.{.{ .name = "s" }},
        .outputs = &.{.{ .name = "x" }},
    };
    const caller_body: []const Instruction = &.{makeInstr(.{ .call_word = "my-eval" })};

    // With the dynamic-eval marker, the call is treated as a dynamic call even
    // though my-eval has a fully concrete declared effect, so the caller's
    // inference is forced uncertain and returns .unknown -- with no diagnostic,
    // since the dynamic source is excluded from the cannot-verify reporting.
    {
        var dict = Dictionary.init(testing.allocator);
        defer dict.deinit();
        var dispatch = DispatchTable.init(testing.allocator);
        defer dispatch.deinit();

        try dict.put("my-eval", .{
            .name = "my-eval",
            .markers = &.{@constCast(&markers.dynamic_eval_marker)},
            .stack_effect = eval_effect,
            .action = .{ .native = dummy },
        });
        try dict.put("caller", .{
            .name = "caller",
            .source_file = "test.1z",
            .action = .{ .compound = caller_body },
        });

        var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
        defer engine.deinit();

        const result = try engine.inferWord("caller");
        try testing.expect(result == .unknown);
        try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
    }

    // The identical word without the marker is an ordinary concrete-effect
    // callee, so the caller infers cleanly to a known delta of 0.
    {
        var dict = Dictionary.init(testing.allocator);
        defer dict.deinit();
        var dispatch = DispatchTable.init(testing.allocator);
        defer dispatch.deinit();

        try dict.put("my-eval", .{
            .name = "my-eval",
            .stack_effect = eval_effect,
            .action = .{ .native = dummy },
        });
        try dict.put("caller", .{
            .name = "caller",
            .source_file = "test.1z",
            .action = .{ .compound = caller_body },
        });

        var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
        defer engine.deinit();

        const result = try engine.inferWord("caller");
        try testing.expect(result == .known and result.known == 0);
        try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
    }
}

test "loop combinator with zero-delta body" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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
        .dispatch_id = 1,
        .markers = &.{@constCast(&markers.generic_marker)},
        .action = .{ .compound = base_body },
    });

    const dispatch_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 42 } }),
    };
    const duration_desc = try value_mod.createBuiltinTypeDescriptor(testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(testing.allocator, duration_desc);
    const unary_desc = try value_mod.createBuiltinTypeDescriptor(testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(testing.allocator, unary_desc);

    try dispatch.register(
        .{
            .dispatch_id = 1,
            .type_a = duration_desc,
            .type_b = unary_desc,
        },
        .{ .body = .{ .quotation = .{ .instructions = dispatch_body } } },
        false,
    );

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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
        .dispatch_id = 1,
        .markers = &.{@constCast(&markers.generic_marker)},
        .action = .{ .compound = base_body },
    });

    const dispatch_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .fixnum = 2 } }),
    };
    const duration_desc2 = try value_mod.createBuiltinTypeDescriptor(testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(testing.allocator, duration_desc2);
    const unary_desc2 = try value_mod.createBuiltinTypeDescriptor(testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(testing.allocator, unary_desc2);

    try dispatch.register(
        .{
            .dispatch_id = 1,
            .type_a = duration_desc2,
            .type_b = unary_desc2,
        },
        .{ .body = .{ .quotation = .{ .instructions = dispatch_body } } },
        false,
    );

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
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

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
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

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    defer engine.deinit();

    // Falls through to inferWord which returns unknown for row-poly keep
    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

// =============================================================================
// Qualified name resolution and declared-delta fallback tests
// =============================================================================

fn makeTestModule(allocator: Allocator) !*value_mod.Module {
    const mod = try allocator.create(value_mod.Module);
    mod.* = .{
        .name = "testmod",
        .words = .{},
    };
    return mod;
}

test "qualified name resolves to known delta" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const mod = try makeTestModule(testing.allocator);
    defer testing.allocator.destroy(mod);
    defer mod.words.deinit(testing.allocator);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try mod.words.put(testing.allocator, "double", .{
        .stack_effect = .{
            .inputs = &.{.{ .name = "n" }},
            .outputs = &.{.{ .name = "n" }},
        },
        .action = .{ .native = dummy },
    });

    const mod_instrs: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .module = mod } }),
    };

    try dict.put("math", .{
        .name = "math",
        .action = .{ .compound = mod_instrs },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 5 } }),
        makeInstr(.{ .call_word = "math.double" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "n" }},
        },
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "polymorphic qualified name falls back to declared delta with note" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const mod = try makeTestModule(testing.allocator);
    defer testing.allocator.destroy(mod);
    defer mod.words.deinit(testing.allocator);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try mod.words.put(testing.allocator, "poly-word", .{
        .polymorphic = true,
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{.{ .name = "b" }},
        },
        .action = .{ .native = dummy },
    });

    const mod_instrs: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .module = mod } }),
    };

    try dict.put("mymod", .{
        .name = "mymod",
        .action = .{ .compound = mod_instrs },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .call_word = "mymod.poly-word" }),
    };

    try dict.put("caller", .{
        .name = "caller",
        .source_file = "test.1z",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "x" }},
        },
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    engine.checked_source = "test.1z";
    defer engine.deinit();

    const result = try engine.inferWord("caller");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.note, engine.diagnostics.items[0].severity);
}

test "declared-delta fallback prevents cascade" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    // Word A calls an unknown callee, but has a declared effect
    const body_a: []const Instruction = &.{
        makeInstr(.{ .call_word = "nonexistent" }),
    };

    try dict.put("word-a", .{
        .name = "word-a",
        .source_file = "test.1z",
        .stack_effect = .{
            .inputs = &.{.{ .name = "x" }},
            .outputs = &.{.{ .name = "y" }},
        },
        .action = .{ .compound = body_a },
    });

    // Word B calls word-a
    const body_b: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .call_word = "word-a" }),
    };

    try dict.put("word-b", .{
        .name = "word-b",
        .source_file = "test.1z",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "r" }},
        },
        .action = .{ .compound = body_b },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    engine.checked_source = "test.1z";
    defer engine.deinit();

    const result_b = try engine.inferWord("word-b");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result_b);

    // Only word-a should emit a warning; word-b sees word-a's declared delta
    var warning_count: usize = 0;
    for (engine.diagnostics.items) |d| {
        if (d.severity == .warning) warning_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), warning_count);
}

test "generated word calling polymorphic callee is silent" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const mod = try makeTestModule(testing.allocator);
    defer testing.allocator.destroy(mod);
    defer mod.words.deinit(testing.allocator);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try mod.words.put(testing.allocator, "poly-word", .{
        .polymorphic = true,
        .stack_effect = .{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{.{ .name = "b" }},
        },
        .action = .{ .native = dummy },
    });

    const mod_instrs: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .module = mod } }),
    };

    try dict.put("mymod", .{
        .name = "mymod",
        .action = .{ .compound = mod_instrs },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .call_word = "mymod.poly-word" }),
    };

    const provenance = dictionary_mod.WordProvenance{
        .generator = "struct{",
        .parent = "test-type",
        .role = "accessor",
    };

    try dict.put("generated-caller", .{
        .name = "generated-caller",
        .source_file = "test.1z",
        .provenance = provenance,
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "x" }},
        },
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .off, .off, null);
    engine.checked_source = "test.1z";
    defer engine.deinit();

    const result = try engine.inferWord("generated-caller");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

// =============================================================================
// Type checking tests
// =============================================================================

test "typed literal produces typed stack entry" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);
    try btv.put(testing.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = .{
            .inputs = &.{.{ .name = "n", .type_annotation = .{ .type = &fixnum_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 42 } }),
        makeInstr(.{ .call_word = "consume-fixnum" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, null, .err, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "type mismatch emits diagnostic" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);
    try btv.put(testing.allocator, "fixnum", &fixnum_tv);
    try btv.put(testing.allocator, "string", &string_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = .{
            .inputs = &.{.{ .name = "n", .type_annotation = .{ .type = &fixnum_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .string = "hello" } }),
        makeInstr(.{ .call_word = "consume-fixnum" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, null, .err, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "declared union input accepts matching typed value" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };
    var union_members = [_]*const TypeValue{ &fixnum_tv, &string_tv };
    var union_tv = TypeValue{ .name = "fixnum|string", .descriptor = null, .member_types = union_members[0..] };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);
    try btv.put(testing.allocator, "fixnum", &fixnum_tv);
    try btv.put(testing.allocator, "string", &string_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-union", .{
        .name = "consume-union",
        .stack_effect = .{
            .inputs = &.{.{ .name = "x", .type_annotation = .{ .type = &union_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 42 } }),
        makeInstr(.{ .call_word = "consume-union" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, null, .err, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "declared any input accepts concrete typed value" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var any_tv = TypeValue{ .name = "any", .descriptor = null };
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);
    try btv.put(testing.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-any", .{
        .name = "consume-any",
        .stack_effect = .{
            .inputs = &.{.{ .name = "x", .type_annotation = .{ .type = &any_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 42 } }),
        makeInstr(.{ .call_word = "consume-any" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, &any_tv, .err, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "declared parent enum input accepts tagged variant value" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var color_tv = TypeValue{ .name = "color", .descriptor = null };
    var color_red_tv = TypeValue{ .name = "color:red", .descriptor = null };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);

    var tagged_type = value_mod.VirtualType{
        .name = "color:red",
        .inner_type = "symbol",
        .parent_type = &color_tv,
        .type_val = &color_red_tv,
    };
    var inner = Value{ .symbol = "red" };
    const tagged = Value{ .tagged = .{ .tag = &tagged_type, .inner = &inner } };

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-color", .{
        .name = "consume-color",
        .stack_effect = .{
            .inputs = &.{.{ .name = "c", .type_annotation = .{ .type = &color_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = tagged }),
        makeInstr(.{ .call_word = "consume-color" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, null, .err, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "declared base input accepts parameterized tagged value" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var array_tv = TypeValue{ .name = "array", .descriptor = null };
    var array_fixnum_tv = TypeValue{ .name = "array(fixnum)", .descriptor = null };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);

    var tagged_type = value_mod.VirtualType{
        .name = "array(fixnum)",
        .inner_type = "array",
        .base_type = &array_tv,
        .type_val = &array_fixnum_tv,
    };
    var elems = [_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } };
    var inner = Value{ .array = elems[0..] };
    const tagged = Value{ .tagged = .{ .tag = &tagged_type, .inner = &inner } };

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-array", .{
        .name = "consume-array",
        .stack_effect = .{
            .inputs = &.{.{ .name = "xs", .type_annotation = .{ .type = &array_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = tagged }),
        makeInstr(.{ .call_word = "consume-array" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, null, .err, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "type union allMatch accepts members via parent fallback" {
    var color_tv = TypeValue{ .name = "color", .descriptor = null };
    var red_tv = TypeValue{ .name = "color:red", .descriptor = null };
    var blue_tv = TypeValue{ .name = "color:blue", .descriptor = null };

    var type_union = TypeUnion{};
    type_union.add(.{ .tv = &red_tv, .parent_type = &color_tv });
    type_union.add(.{ .tv = &blue_tv, .parent_type = &color_tv });

    try testing.expect(type_union.allMatch(&color_tv, null));
}

test "unknown type skips check" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);
    try btv.put(testing.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("unknown-producer", .{
        .name = "unknown-producer",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "x" }},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = .{
            .inputs = &.{.{ .name = "n", .type_annotation = .{ .type = &fixnum_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "unknown-producer" }),
        makeInstr(.{ .call_word = "consume-fixnum" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, null, .err, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "type check mode off skips all checks" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);
    try btv.put(testing.allocator, "fixnum", &fixnum_tv);
    try btv.put(testing.allocator, "string", &string_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = .{
            .inputs = &.{.{ .name = "n", .type_annotation = .{ .type = &fixnum_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .string = "hello" } }),
        makeInstr(.{ .call_word = "consume-fixnum" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, null, .off, .off, null);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

// =============================================================================
// Protocol-bound annotation tests
// =============================================================================

test "protocol-bounded output flowing into same-protocol input emits no diagnostic" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var p_desc = value_mod.ProtocolDescriptor{ .name = "P", .methods = &.{}, .protocol_id = 1 };

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("produce-p", .{
        .name = "produce-p",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "y", .type_annotation = .{ .protocol = &p_desc } }},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("consume-p", .{
        .name = "consume-p",
        .stack_effect = .{
            .inputs = &.{.{ .name = "x", .type_annotation = .{ .protocol = &p_desc } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "produce-p" }),
        makeInstr(.{ .call_word = "consume-p" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .err, .off, null);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "protocol-bounded output flowing into different-protocol input defers silently" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var p_desc = value_mod.ProtocolDescriptor{ .name = "P", .methods = &.{}, .protocol_id = 1 };
    var q_desc = value_mod.ProtocolDescriptor{ .name = "Q", .methods = &.{}, .protocol_id = 2 };

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("produce-p", .{
        .name = "produce-p",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "y", .type_annotation = .{ .protocol = &p_desc } }},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("consume-q", .{
        .name = "consume-q",
        .stack_effect = .{
            .inputs = &.{.{ .name = "x", .type_annotation = .{ .protocol = &q_desc } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "produce-p" }),
        makeInstr(.{ .call_word = "consume-q" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, null, null, .err, .off, null);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "protocol-bounded output flowing into concrete input defers silently" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var p_desc = value_mod.ProtocolDescriptor{ .name = "P", .methods = &.{}, .protocol_id = 1 };
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);
    try btv.put(testing.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("produce-p", .{
        .name = "produce-p",
        .stack_effect = .{
            .inputs = &.{},
            .outputs = &.{.{ .name = "y", .type_annotation = .{ .protocol = &p_desc } }},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = .{
            .inputs = &.{.{ .name = "n", .type_annotation = .{ .type = &fixnum_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "produce-p" }),
        makeInstr(.{ .call_word = "consume-fixnum" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, null, .err, .off, null);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "concrete typed entry flowing into protocol input without ctx is silently skipped" {
    var dict = Dictionary.init(testing.allocator);
    defer dict.deinit();
    var dispatch = DispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    var p_desc = value_mod.ProtocolDescriptor{ .name = "P", .methods = &.{}, .protocol_id = 1 };
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var btv: std.StringHashMapUnmanaged(*TypeValue) = .{};
    defer btv.deinit(testing.allocator);
    try btv.put(testing.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-p", .{
        .name = "consume-p",
        .stack_effect = .{
            .inputs = &.{.{ .name = "x", .type_annotation = .{ .protocol = &p_desc } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 42 } }),
        makeInstr(.{ .call_word = "consume-p" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = InferenceEngine.init(&dict, &dispatch, &.{}, testing.allocator, null, false, true, &btv, null, .err, .off, null);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}
