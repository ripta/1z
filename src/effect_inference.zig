const std = @import("std");
const Allocator = std.mem.Allocator;

const dictionary_mod = @import("dictionary.zig");
const Dictionary = dictionary_mod.Dictionary;
const WordDefinition = dictionary_mod.WordDefinition;

const dispatch_mod = @import("dispatch.zig");

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const TypeValue = value_mod.TypeValue;

const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;

const container_backing = @import("container_backing.zig");
const helpers = @import("primitives/helpers.zig");
const markers = @import("primitives/markers.zig");
const protocols_mod = @import("primitives/protocols.zig");
const Context = @import("context.zig").Context;

pub fn nativeSuppressChecksValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .boolean => |b| {
            if (b) {
                try ctx.stack.push(value_mod.stringValue("all"));
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
            try ctx.stack.push(.{ .boolean = true });
        },
        .string => |s| {
            if (std.mem.eql(u8, s.bytes, "all") or std.mem.eql(u8, s.bytes, "warn-only") or std.mem.eql(u8, s.bytes, "none")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(value_mod.stringValue("suppress-checks: expected t, f, or one of all, warn-only, none"));
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(value_mod.stringValue("suppress-checks: expected t, f, or one of all, warn-only, none"));
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

pub const InferenceResult = union(enum) {
    known: i64,
    unknown,

    /// A body whose last step is a branch with arms of different arity, or a declaration with
    /// `|` alternative outputs. Each member is one arity the word may leave.
    alternatives: stack_effect_mod.DeltaSet,
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
                .symbol => |s| return .{ .name = s.bytes, .line = instructions[i].line },
                else => return null,
            },
            // A marker (or `const`) before the body is produced by a word call.
            .call_word, .call_word_direct, .call_word_module => continue,
        }
    }
    return null;
}

/// A `case`/`cond` branches array has a default arm when at least one top-level
/// element is a bare quotation; keyed arms are nested arrays `{ key [body] }`.
fn branchesHaveDefault(branches: []const Value) bool {
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
            .call_word, .call_word_direct, .call_word_module => {
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
    default_arm_mode: InferenceEngine.DefaultArmMode,
    never_returns_mode: InferenceEngine.NeverReturnsMode,
};

/// Read the `suppress-checks`, `suppress-undeclared`, `type-check`,
/// `callsite-arity-mismatch`, `missing-default-arm`, and
/// `never-returns-consistency` pragmas from the given context and translate them
/// into the settings consumed by `InferenceEngine.init`.
pub fn readCheckPragmas(ctx: *const Context) CheckPragmaSettings {
    var settings: CheckPragmaSettings = .{
        .severity_override = null,
        .suppressed = false,
        .suppress_undeclared = false,
        .type_check_mode = .err,
        .arity_check_mode = .err,
        .default_arm_mode = .err,
        .never_returns_mode = .warning,
    };

    if (ctx.getPragma("suppress-checks")) |pragma_val| {
        switch (pragma_val) {
            .string => |s| {
                if (std.mem.eql(u8, s.bytes, "warn-only")) {
                    settings.severity_override = .warning;
                } else if (std.mem.eql(u8, s.bytes, "all")) {
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
                if (std.mem.eql(u8, s.bytes, "off")) {
                    settings.type_check_mode = .off;
                } else if (std.mem.eql(u8, s.bytes, "warning")) {
                    settings.type_check_mode = .warning;
                }
            },
            else => {},
        }
    }

    if (ctx.getPragma("callsite-arity-mismatch")) |pragma_val| {
        switch (pragma_val) {
            .string => |s| {
                if (std.mem.eql(u8, s.bytes, "off")) {
                    settings.arity_check_mode = .off;
                } else if (std.mem.eql(u8, s.bytes, "warning")) {
                    settings.arity_check_mode = .warning;
                }
            },
            else => {},
        }
    }

    if (ctx.getPragma("missing-default-arm")) |pragma_val| {
        switch (pragma_val) {
            .string => |s| {
                if (std.mem.eql(u8, s.bytes, "off")) {
                    settings.default_arm_mode = .off;
                } else if (std.mem.eql(u8, s.bytes, "warning")) {
                    settings.default_arm_mode = .warning;
                }
            },
            else => {},
        }
    }

    // Defaults to warning, so the "error" value is read explicitly here.
    if (ctx.getPragma("never-returns-consistency")) |pragma_val| {
        switch (pragma_val) {
            .string => |s| {
                if (std.mem.eql(u8, s.bytes, "off")) {
                    settings.never_returns_mode = .off;
                } else if (std.mem.eql(u8, s.bytes, "error")) {
                    settings.never_returns_mode = .err;
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
    /// A struct instance pushed as a literal, kept so a check that depends on a literal argument
    /// can read it. It carries no type, so every other consumer treats it as `.other`.
    struct_literal: Value,
};

pub const InferenceEngine = struct {
    ctx: *Context,
    allocator: Allocator,
    cache: std.StringHashMapUnmanaged(InferenceResult),
    in_progress: std.StringHashMapUnmanaged(void),
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    severity_override: ?Severity,
    suppressed: bool,
    suppress_undeclared: bool,
    checked_source: ?[]const u8,
    any_type_sentinel: ?*const TypeValue,
    type_check_mode: TypeCheckMode,
    arity_check_mode: ArityCheckMode,
    default_arm_mode: DefaultArmMode,
    never_returns_mode: NeverReturnsMode,
    type_cache: std.StringHashMapUnmanaged(?[]StackEntry),

    // Set by inferInstructions when it returns .unknown
    last_unknown_callee: ?[]const u8 = null,
    last_unknown_is_polymorphic: bool = false,

    // Set by inferInstructions on every exit: true when the body it just
    // walked diverges (ends dead-code), false otherwise. Read by the
    // combinator handlers immediately after analyzing a quotation arm.
    body_terminal: bool = false,

    // Set by inferInstructions on every exit: true when the stack model it left holds every
    // entry above the lowest point the body reached, false when some step could only keep a
    // correct top portion. Read the same way as `body_terminal`.
    //
    // An exact window of length L from a body with delta d consumed L - d entries from beneath
    // its start. That is what lets a caller replay the body as a pop and a push.
    body_window_exact: bool = true,

    /// Words whose inferred body leaves an exact window, so a caller can replay them.
    ///
    /// An exact word with an empty window has no `type_cache` entry.
    exact_windows: std.StringHashMapUnmanaged(void) = .{},

    pub const TypeCheckMode = enum { err, warning, off };
    pub const ArityCheckMode = enum { err, warning, off };
    pub const DefaultArmMode = enum { err, warning, off };
    pub const NeverReturnsMode = enum { err, warning, off };

    pub fn init(
        ctx: *Context,
        allocator: Allocator,
        severity_override: ?Severity,
        suppressed: bool,
        suppress_undeclared: bool,
        any_type_sentinel: ?*const TypeValue,
        type_check_mode: TypeCheckMode,
        arity_check_mode: ArityCheckMode,
        default_arm_mode: DefaultArmMode,
        never_returns_mode: NeverReturnsMode,
    ) InferenceEngine {
        return .{
            .ctx = ctx,
            .allocator = allocator,
            .cache = .{},
            .in_progress = .{},
            .diagnostics = .{},
            .type_cache = .{},
            .severity_override = severity_override,
            .suppressed = suppressed,
            .suppress_undeclared = suppress_undeclared,
            .checked_source = null,
            .any_type_sentinel = any_type_sentinel,
            .type_check_mode = type_check_mode,
            .arity_check_mode = arity_check_mode,
            .default_arm_mode = default_arm_mode,
            .never_returns_mode = never_returns_mode,
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
        self.exact_windows.deinit(self.allocator);
    }

    pub fn analyzeAll(self: *InferenceEngine, checked_source: ?[]const u8) Allocator.Error!void {
        self.checked_source = checked_source;
        for (self.ctx.local_frames.items) |frame| {
            var iter = frame.iterator();
            while (iter.next()) |entry| {
                const word_def = entry.value_ptr.*;
                if (word_def.action != .compound and word_def.action != .literal) continue;
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
        return self.ctx.lookupTypeNameByDescriptor(desc) orelse "<descriptor>";
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
        return self.ctx.lookupWord(name);
    }

    fn resolveQualifiedName(self: *const InferenceEngine, name: []const u8) ?value_mod.ModuleWord {
        const qn = Context.splitQualifiedName(name) orelse return null;
        const binding = self.lookupWord(qn.module_path) orelse return null;
        const module = Context.moduleLiteralFromWordDef(binding) orelse return null;
        return module.words.get(qn.word_name);
    }

    /// Emit a diagnostic when a word declares the bottom output `-- *` without the
    /// `never-returns` marker, or carries the marker without the `-- *` shape.
    ///
    /// The biconditional keeps the two signals from drifting apart.
    fn checkNeverReturnsConsistency(self: *InferenceEngine, name: []const u8, word_def: *const WordDefinition) Allocator.Error!void {
        const has_star = if (word_def.stack_effect) |eff| eff.isBottomOutput() else false;

        var has_marker = false;
        for (word_def.markers) |mk| {
            if (markers.isNeverReturnsMarker(mk)) {
                has_marker = true;
                break;
            }
        }

        if (has_star == has_marker) return;

        const severity: Severity = if (self.never_returns_mode == .warning) .warning else .err;
        const detail = if (has_star)
            "declares a `-- *` output but is not marked never-returns"
        else
            "carries the never-returns marker but does not declare a `-- *` output";

        try self.emitDiagnostic(.{
            .word_name = name,
            .source_file = word_def.source_file,
            .source_line = word_def.source_line,
            .severity = severity,
            .message = try std.fmt.allocPrint(self.allocator, "{s}", .{detail}),
        });
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
                return computeDeclaredDelta(eff.*) orelse .unknown;
            }
            return .unknown;
        }

        const word_def = self.lookupWord(name) orelse return .unknown;

        // A .literal value has no instruction body of its own; synthesize
        // the equivalent single push_literal instruction so inference,
        // caching, and diagnostics below run exactly as they did before
        // this variant existed for what was always a one-instruction
        // compound body.
        const instructions: []const Instruction = switch (word_def.action) {
            .compound => |i| i,
            .literal => |v| blk: {
                const synthesized = try self.allocator.alloc(Instruction, 1);
                synthesized[0] = .{ .op = .{ .push_literal = v }, .line = 0 };
                break :blk synthesized;
            },
            .native, .host_callback => {
                const result = if (word_def.stack_effect) |eff|
                    computeDeclaredDelta(eff.*) orelse .unknown
                else
                    .unknown;
                try self.cache.put(self.allocator, name, result);
                return result;
            },
        };

        if (self.never_returns_mode != .off and self.isInCheckedSource(word_def.source_file)) {
            try self.checkNeverReturnsConsistency(name, &word_def);
        }

        if (word_def.stack_effect) |eff| {
            if (stack_effect_mod.hasAnyRowVariable(eff.*)) {
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
                const result = computeDeclaredDelta(eff.*) orelse .unknown;
                try self.cache.put(self.allocator, name, result);

                // The entries are validated against the declaration, but their windows are not
                // merged into the cache: an empty base body is no evidence about the outputs, so
                // call sites keep the annotation-derived types above.
                var entry_windows: std.ArrayListUnmanaged(std.ArrayListUnmanaged(StackEntry)) = .{};
                defer {
                    for (entry_windows.items) |*w| w.deinit(self.allocator);
                    entry_windows.deinit(self.allocator);
                }

                const caller_info = CallerInfo{
                    .word_name = name,
                    .source_file = word_def.source_file,
                    .source_line = word_def.source_line,
                    .declared_input_count = eff.concreteInputCount(),
                    .alternatives_ok = result == .alternatives,
                };
                const conv_target = try self.conversionBodyTarget(name, &word_def);
                _ = try self.validateDispatchEntries(name, result, &word_def, caller_info, conv_target, &entry_windows);
                return result;
            }
        }

        try self.in_progress.put(self.allocator, name, {});
        defer _ = self.in_progress.fetchRemove(name);
        const declared_inputs: ?usize = if (word_def.stack_effect) |eff| blk: {
            if (stack_effect_mod.hasAnyRowVariable(eff.*)) break :blk null;
            break :blk eff.concreteInputCount();
        } else null;
        const declares_alternatives = if (word_def.stack_effect) |eff|
            (computeDeclaredDelta(eff.*) orelse InferenceResult.unknown) == .alternatives
        else
            false;
        const caller_info = CallerInfo{
            .word_name = name,
            .source_file = word_def.source_file,
            .source_line = word_def.source_line,
            .declared_input_count = declared_inputs,
            .alternatives_ok = declares_alternatives,
        };
        var body_out_stack: std.ArrayListUnmanaged(StackEntry) = .{};
        defer body_out_stack.deinit(self.allocator);
        const inferred = try self.inferInstructions(instructions, caller_info, &body_out_stack);
        if (inferred == .known and self.body_window_exact) {
            try self.exact_windows.put(self.allocator, name, {});
        }

        if (inferred == .known and body_out_stack.items.len > 0) {
            const cached_types = try self.allocator.alloc(StackEntry, body_out_stack.items.len);
            @memcpy(cached_types, body_out_stack.items);
            if (self.type_cache.get(name)) |existing| {
                if (existing) |old| self.allocator.free(old);
            }
            try self.type_cache.put(self.allocator, name, cached_types);
        }

        if (inferred == .known and self.type_check_mode != .off and self.isInCheckedSource(word_def.source_file)) {
            if (word_def.stack_effect) |eff| {
                if (!stack_effect_mod.hasAnyRowVariable(eff.*)) {
                    try self.checkDeclaredOutputs(name, &word_def, inferred.known, body_out_stack.items, null);
                }
            }
        }

        if (isGeneric(&word_def)) {
            var entry_windows: std.ArrayListUnmanaged(std.ArrayListUnmanaged(StackEntry)) = .{};
            defer {
                for (entry_windows.items) |*w| w.deinit(self.allocator);
                entry_windows.deinit(self.allocator);
            }

            const conv_target = try self.conversionBodyTarget(name, &word_def);
            const entries_mergeable = try self.validateDispatchEntries(name, inferred, &word_def, caller_info, conv_target, &entry_windows);
            if (inferred == .known) {
                try self.mergeDispatchWindows(name, body_out_stack.items, entry_windows.items, entries_mergeable);
            }

            if (inferred == .known) {
                if (conv_target) |target| {
                    try self.checkConversionOutput(name, &word_def, target, &body_out_stack, null);
                }
            }
        }

        if (word_def.stack_effect) |eff| {
            if (computeDeclaredDelta(eff.*)) |declared| {
                switch (inferred) {
                    .known, .alternatives => {
                        const admitted = switch (inferred) {
                            .known => |d| declaredAdmits(declared, d),
                            .alternatives => |set| blk: {
                                for (set.slice()) |d| {
                                    if (!declaredAdmits(declared, d)) break :blk false;
                                }
                                break :blk true;
                            },
                            .unknown => unreachable,
                        };

                        if (!admitted) {
                            const declared_text = try formatDeltas(self.allocator, declared);
                            defer self.allocator.free(declared_text);
                            const inferred_text = try formatDeltas(self.allocator, inferred);
                            defer self.allocator.free(inferred_text);

                            try self.emitDiagnostic(.{
                                .word_name = name,
                                .source_file = word_def.source_file,
                                .source_line = word_def.source_line,
                                .severity = .err,
                                .message = try std.fmt.allocPrint(
                                    self.allocator,
                                    "declared stack effect delta is {s}, but inferred delta is {s}",
                                    .{ declared_text, inferred_text },
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
    }

    fn resolveValueType(self: *const InferenceEngine, val: Value) ?*const TypeValue {
        const type_name = dispatch_mod.dispatchTypeName(val);
        return self.ctx.lookupBuiltinTypeValue(type_name);
    }

    fn stackEntryForValue(self: *const InferenceEngine, val: Value) StackEntry {
        switch (val) {
            .quotation => |quot| return .{ .quotation = quot },
            .struct_instance => return .{ .struct_literal = val },
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
        var window_exact = true;
        defer self.body_window_exact = window_exact;
        var delta: i64 = 0;
        var stack_model: std.ArrayListUnmanaged(StackEntry) = .{};
        defer stack_model.deinit(self.allocator);
        var uncertain: bool = false;
        var uncertain_source: ?[]const u8 = null;
        var uncertain_is_polymorphic: bool = false;
        var uncertain_is_dynamic: bool = false;
        var dead_code: bool = false;
        var dead_code_warned: bool = false;
        const DeadCodeCause = union(enum) { underflow, terminal_call: []const u8, terminal_branch, terminal_recovery };
        var dead_code_cause: ?DeadCodeCause = null;
        var alternatives_result: ?stack_effect_mod.DeltaSet = null;

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
                        .terminal_recovery => try std.fmt.allocPrint(
                            self.allocator,
                            "dead code: unreachable after recovery where both arms are terminal",
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
                .call_word, .call_word_direct, .call_word_module => {
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
                                        if (declaredKnownDelta(eff.*)) |declared_delta| {
                                            delta += declared_delta;
                                            try self.applyEffectToModel(&stack_model, eff, null);
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
                                    if (declaredKnownDelta(eff.*)) |declared_delta| {
                                        delta += declared_delta;
                                        try self.applyEffectToModel(&stack_model, eff, null);
                                        continue;
                                    }
                                }

                                // An alternative-arity callee leaves an uncountable stack.
                                self.last_unknown_callee = name;
                                self.last_unknown_is_polymorphic = if (mod_word.stack_effect) |eff| eff.hasAlternativeOutput() else false;
                                return .unknown;
                            }
                        }
                        self.last_unknown_callee = name;
                        self.last_unknown_is_polymorphic = false;
                        return .unknown;
                    }
                    const wd = word_def.?;

                    const combinator_kind = classifyCombinator(&wd);

                    // A `partial-dispatch` word (`case`, `cond`) whose branches
                    // array literal has no default arm can fall through to a
                    // `no-matching-branch` runtime error. The branches array is
                    // the literal pushed just before the call; a dynamically
                    // built value is not inspectable here and is left unchecked.
                    // Emit before dispatch so the warning fires regardless of the
                    // combinator path taken below.
                    if (idx > 0 and self.default_arm_mode != .off and isPartialDispatch(&wd) and self.isInCheckedSource(caller.source_file)) {
                        switch (instructions[idx - 1].op) {
                            .push_literal => |val| if (val == .array and !branchesHaveDefault(val.array.items)) {
                                const severity: Severity = if (self.default_arm_mode == .warning) .warning else .err;
                                try self.emitDiagnostic(.{
                                    .word_name = caller.word_name,
                                    .source_file = caller.source_file,
                                    .source_line = instr.line,
                                    .severity = severity,
                                    .message = try std.fmt.allocPrint(
                                        self.allocator,
                                        "{s} expression has no default arm",
                                        .{name},
                                    ),
                                });
                            },
                            else => {},
                        }
                    }

                    // A combinator's arms are compared against each other on its own path.
                    if (combinator_kind == .none and self.isInCheckedSource(caller.source_file)) {
                        try self.checkLiteralQuotationArgs(&wd, stack_model.items, instructions, idx, caller, instr.line);
                    }

                    // Try row-polymorphic path for any word with row-poly effect and quotation annotations
                    if (wd.stack_effect) |eff| {
                        if (stack_effect_mod.hasAnyRowVariable(eff.*)) {
                            const rp_result = try self.handleRowPoly(
                                &wd,
                                combinator_kind,
                                &stack_model,
                                delta,
                                caller,
                                instr.line,
                                idx + 1 == instructions.len,
                            );
                            switch (rp_result) {
                                .applied => |applied| {
                                    delta = applied.new_delta;
                                    stack_model.shrinkRetainingCapacity(0);
                                    if (!applied.exact) window_exact = false;

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
                                        dead_code_cause = if (combinator_kind == .recovery) .terminal_recovery else .terminal_branch;
                                    }
                                    continue;
                                },
                                .unknown => return .unknown,
                                .fallthrough => {},
                                .alternatives => |set| {
                                    alternatives_result = set;
                                    window_exact = false;
                                    stack_model.clearRetainingCapacity();
                                    continue;
                                },
                            }
                        }
                    }

                    // Try concrete combinator path for branch/loop without row vars
                    if (combinator_kind != .none) {
                        if (wd.stack_effect) |eff| {
                            if (!stack_effect_mod.hasAnyRowVariable(eff.*)) {
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
                                        if (!applied.exact) window_exact = false;

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
                                    .unknown, .alternatives => return .unknown,
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
                            if (declaredKnownDelta(eff.*)) |declared_delta| {
                                delta += declared_delta;
                                try self.applyEffectToModel(&stack_model, eff, null);
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
                            if (!try self.adjustStackModelTyped(&wd, &stack_model, callee_delta)) window_exact = false;

                            // The model applied the declared effect, so a callee whose body
                            // disagrees with it leaves the window out of step with `delta`.
                            if (wd.stack_effect) |eff| {
                                if (declaredKnownDelta(eff.*)) |declared_delta| {
                                    if (declared_delta != callee_delta) window_exact = false;
                                }
                            }
                        },
                        .unknown => {
                            if (wd.stack_effect) |eff| {
                                if (declaredKnownDelta(eff.*)) |declared_delta| {
                                    delta += declared_delta;
                                    try self.applyEffectToModel(&stack_model, eff, null);
                                    uncertain = true;
                                    uncertain_source = name;
                                    uncertain_is_dynamic = false;
                                    continue;
                                }
                            }
                            return .unknown;
                        },

                        // The arity after the call depends on which alternative ran, so nothing
                        // after it can be counted. The caller trusts its own declaration.
                        .alternatives => {
                            self.last_unknown_callee = name;
                            self.last_unknown_is_polymorphic = true;
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

        if (alternatives_result) |set| return .{ .alternatives = set };

        return .{ .known = delta };
    }

    const CallerInfo = struct {
        word_name: []const u8,
        source_file: ?[]const u8,
        source_line: usize,
        declared_input_count: ?usize = null,

        /// The word declares `|` alternative outputs and the code being inferred ends its body,
        /// so a final branch may leave a different arity on each arm.
        alternatives_ok: bool = false,
    };

    const CombinatorKind = enum { none, branch, loop, recovery };

    fn classifyCombinator(word_def: *const WordDefinition) CombinatorKind {
        for (word_def.markers) |mk| {
            if (markers.isBranchCombinatorMarker(mk)) return .branch;
            if (markers.isLoopCombinatorMarker(mk)) return .loop;
            if (markers.isRecoveryCombinatorMarker(mk)) return .recovery;
        }
        return .none;
    }

    const CombinatorResult = union(enum) {
        applied: struct {
            new_delta: i64,
            new_model_size: usize,
            output_types: ?[]StackEntry = null,
            terminal: bool = false,
            /// True when `output_types` is the whole model, exact in the `body_window_exact`
            /// sense, rather than the combinator's outputs alone.
            exact: bool = false,
        },
        unknown,
        fallthrough,

        /// The call ends the body and its arms leave these different deltas.
        alternatives: stack_effect_mod.DeltaSet,
    };

    /// A literal quotation argument that inferred to a known delta.
    const ArmRecord = struct {
        annotation: *const StackEffect,
        delta: i64,
        exact: bool,
    };

    /// The whole stack model after a composed combinator, and whether it is still an exact window.
    const ComposedModel = struct {
        model: []StackEntry,
        exact: bool,
    };

    /// Model a non-branch combinator by walking its declared outputs in order.
    ///
    /// A row that one arm's annotation produces replays that arm. The inputs the arm names are
    /// pushed, then its window is applied over them.
    ///
    /// A concrete output takes the popped entry of the input sharing its name, so `keep` and `dip`
    /// put `x` back above the arm.
    ///
    /// Returns null when the shape is not one this walk understands: a row produced by no arm or
    /// by several, an arm left unused, or an arm naming an input the combinator does not take.
    /// The caller then falls back to treating the arms as alternatives or to unresolved outputs.
    fn composeArms(
        self: *InferenceEngine,
        eff: *const StackEffect,
        model: []const StackEntry,
        arms: []const ArmRecord,
        windows: []const std.ArrayListUnmanaged(StackEntry),
    ) Allocator.Error!?ComposedModel {
        var bottom_row: ?[]const u8 = null;
        for (eff.inputs, 0..) |param, i| {
            if (!param.is_row_variable) continue;
            if (i != 0) return null;
            bottom_row = param.name;
        }

        const concrete_inputs = eff.inputs[@intFromBool(bottom_row != null)..];
        if (model.len < concrete_inputs.len) return null;
        const popped = model[model.len - concrete_inputs.len ..];

        // `toOwnedSlice` empties `out` on success, so this releases it only on a null or error return.
        var out: std.ArrayListUnmanaged(StackEntry) = .{};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, model[0 .. model.len - concrete_inputs.len]);

        var used = [_]bool{false} ** 8;
        var exact = true;

        for (eff.outputs, 0..) |param, oi| {
            if (!param.is_row_variable) {
                try out.append(self.allocator, namedEntry(concrete_inputs, popped, param.name) orelse .other);
                continue;
            }

            if (oi == 0 and bottom_row != null and std.mem.eql(u8, param.name, bottom_row.?)) continue;

            var producer: ?usize = null;
            for (arms, 0..) |arm, k| {
                const arm_out = arm.annotation.outputs;
                if (arm_out.len != 1 or !arm_out[0].is_row_variable) continue;
                if (!std.mem.eql(u8, arm_out[0].name, param.name)) continue;
                if (producer != null) return null;
                producer = k;
            }

            const k = producer orelse return null;
            if (used[k]) return null;
            used[k] = true;

            for (arms[k].annotation.inputs) |arm_in| {
                if (arm_in.is_row_variable) continue;
                const entry = namedEntry(concrete_inputs, popped, arm_in.name) orelse return null;
                try out.append(self.allocator, entry);
            }

            // An inexact arm still leaves a correct top portion, but nothing beneath it can be
            // placed, so the composed model restarts from that portion.
            const window = windows[k].items;
            const replayed = arms[k].exact and try self.applyWindow(&out, window, arms[k].delta);
            if (!replayed) {
                out.clearRetainingCapacity();
                try out.appendSlice(self.allocator, window);
                exact = false;
            }
        }

        for (used[0..arms.len]) |u| {
            if (!u) return null;
        }

        return .{ .model = try out.toOwnedSlice(self.allocator), .exact = exact };
    }

    /// True when two or more arms all produce the same single row and the combinator's only output
    /// is that row, so exactly one arm runs and their stacks merge as branches do.
    ///
    /// A lone arm is not an alternative. Whether it ran at all is unknown.
    fn armsAreAlternatives(eff: *const StackEffect, arms: []const ArmRecord) bool {
        if (arms.len < 2) return false;
        if (eff.outputs.len != 1 or !eff.outputs[0].is_row_variable) return false;

        const row = eff.outputs[0].name;
        for (arms) |arm| {
            const arm_out = arm.annotation.outputs;
            if (arm_out.len != 1 or !arm_out[0].is_row_variable) return false;
            if (!std.mem.eql(u8, arm_out[0].name, row)) return false;
        }

        return true;
    }

    /// How many entries a loop combinator's output row sits above its input row.
    ///
    /// A loop that leaves its input row, such as `loop`, shifts nothing. One that leaves another
    /// row exits after the arm producing it, so `while` ends on its predicate's `..a -- ..b` and
    /// that arm's adjustment is the shift. Null when no single arm leads from one row to the other.
    fn loopOutputShift(eff: *const StackEffect, arms: []const ArmRecord) ?i64 {
        const in_row = firstRowName(eff.inputs);
        const out_row = firstRowName(eff.outputs);
        if (in_row == null and out_row == null) return 0;

        const from = in_row orelse return null;
        const to = out_row orelse return null;
        if (std.mem.eql(u8, from, to)) return 0;

        var shift: ?i64 = null;
        for (arms) |arm| {
            const arm_from = firstRowName(arm.annotation.inputs) orelse continue;
            const arm_to = firstRowName(arm.annotation.outputs) orelse continue;
            if (!std.mem.eql(u8, arm_from, from) or !std.mem.eql(u8, arm_to, to)) continue;
            if (shift != null) return null;
            shift = arm.delta - arm.annotation.concreteDelta();
        }

        return shift;
    }

    fn firstRowName(params: []const StackEffectParam) ?[]const u8 {
        for (params) |param| {
            if (param.is_row_variable) return param.name;
        }

        return null;
    }

    /// The popped entry of the topmost input named `name`, or null when no input has that name.
    fn namedEntry(inputs: []const StackEffectParam, popped: []const StackEntry, name: []const u8) ?StackEntry {
        var i = inputs.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, inputs[i].name, name)) return popped[i];
        }

        return null;
    }

    fn handleCombinator(
        self: *InferenceEngine,
        word_def: *const WordDefinition,
        kind: CombinatorKind,
        stack_model: *std.ArrayListUnmanaged(StackEntry),
        current_delta: i64,
        caller: CallerInfo,
    ) Allocator.Error!CombinatorResult {
        const eff = word_def.stack_effect orelse return .fallthrough;
        const declared = declaredKnownDelta(eff.*) orelse return .fallthrough;

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
                    quot_caller.alternatives_ok = false;

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
                        .unknown, .alternatives => {
                            all_literal = false;
                            branch_out.deinit(self.allocator);
                        },
                    }
                },
                .typed, .typed_union, .protocol_bounded, .other, .struct_literal => {},
            }
        }

        if (kind == .branch and quot_arm_count >= 2 and all_arms_terminal) {
            const consumed = @min(stack_model.items.len, input_count);
            const new_model_size = stack_model.items.len - consumed;
            return .{ .applied = .{
                .new_delta = current_delta + declared,
                .new_model_size = new_model_size,
                .terminal = true,
            } };
        }

        if (!all_literal or !found_any_quot or quot_deltas.items.len == 0) {
            const new_delta = current_delta + declared;
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

                const total_delta = current_delta + declared + first;
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

                const total_delta = current_delta + declared;
                const consumed = @min(stack_model.items.len, input_count);
                const new_model_size = stack_model.items.len - consumed;
                return .{ .applied = .{ .new_delta = total_delta, .new_model_size = new_model_size } };
            },

            // A handler takes the error its try arm does not, so raw deltas cannot be compared
            // without the annotations only the row-polymorphic path reads.
            .recovery, .none => return .fallthrough,
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
            .other, .struct_literal => return .other,
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
        line: usize,
        is_tail: bool,
    ) Allocator.Error!CombinatorResult {
        const eff = word_def.stack_effect orelse return .fallthrough;
        const concrete_inputs = eff.concreteInputCount();

        if (stack_model.items.len < concrete_inputs) return .fallthrough;

        var adjustments: std.ArrayListUnmanaged(i64) = .{};
        defer adjustments.deinit(self.allocator);

        const max_rp_stacks = 8;
        var rp_branch_stacks: [max_rp_stacks]std.ArrayListUnmanaged(StackEntry) = undefined;
        var rp_arms: [max_rp_stacks]ArmRecord = undefined;
        var rp_branch_count: usize = 0;
        var rp_arms_dropped = false;
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
                        quot_caller.alternatives_ok = caller.alternatives_ok and is_tail and kind == .branch;

                        const qd = try self.inferInstructions(quot.instructions, quot_caller, &rp_out);
                        const arm_exact = self.body_window_exact;
                        if (!self.body_terminal) all_arms_terminal = false;
                        switch (qd) {
                            .known => |d| {
                                const annotated_qcd = annotation.concreteDelta();

                                // An annotation with no row variable is a count, not an arm to
                                // compare against the others, so the literal must meet it.
                                if (kind == .none and !self.body_terminal and
                                    !stack_effect_mod.hasAnyRowVariable(annotation.*) and
                                    self.isInCheckedSource(caller.source_file))
                                {
                                    try self.reportAnnotationMismatch(param.name, annotation, d, caller, line);
                                }

                                try adjustments.append(self.allocator, d - annotated_qcd);
                                if (rp_branch_count < max_rp_stacks) {
                                    rp_branch_stacks[rp_branch_count] = rp_out;
                                    rp_arms[rp_branch_count] = .{ .annotation = annotation, .delta = d, .exact = arm_exact };
                                    rp_branch_count += 1;
                                } else {
                                    rp_out.deinit(self.allocator);
                                    rp_arms_dropped = true;
                                }
                            },
                            .unknown => {
                                all_literal = false;
                                rp_out.deinit(self.allocator);
                            },

                            // An arm ending in its own diverging branch contributes one
                            // adjustment per arity it may leave.
                            .alternatives => |set| {
                                const annotated_qcd = annotation.concreteDelta();
                                for (set.slice()) |d| try adjustments.append(self.allocator, d - annotated_qcd);
                                rp_out.deinit(self.allocator);
                            },
                        }
                    },
                    .typed, .typed_union, .protocol_bounded, .other, .struct_literal => {
                        all_literal = false;
                        all_arms_terminal = false;
                    },
                }
            }
        }

        if ((kind == .branch or kind == .recovery) and quot_arm_count >= 2 and all_arms_terminal) {
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

                if (rp_arms_dropped) return .unknown;
                const shift = loopOutputShift(eff, rp_arms[0..rp_branch_count]) orelse return .unknown;
                const shifted_size = @as(i64, @intCast(new_model_size)) + shift;

                return .{ .applied = .{
                    .new_delta = current_delta + concrete_delta + shift,
                    .new_model_size = @intCast(@max(0, shifted_size)),
                } };
            },

            // A handler runs in place of a try arm that raised, from the same entry stack, so
            // the two must leave the same stack, as the arms of a branch must.
            .branch, .recovery => {
                const first = adjustments.items[0];
                for (adjustments.items[1..]) |adj| {
                    if (adj != first) {
                        // The last branch of a word declaring `|` alternatives may leave a
                        // different arity on each arm. Each one is checked against the
                        // declaration once the body is inferred.
                        if (kind == .branch and caller.alternatives_ok and is_tail) {
                            var set: stack_effect_mod.DeltaSet = .{};
                            var fits = true;
                            for (adjustments.items) |a| {
                                if (!set.add(current_delta + concrete_delta + a)) fits = false;
                            }
                            if (fits) return .{ .alternatives = set };
                        }

                        try self.emitDiagnostic(.{
                            .word_name = caller.word_name,
                            .source_file = caller.source_file,
                            .source_line = caller.source_line,
                            .severity = .err,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "{s} quotations have mismatched row variable adjustments",
                                .{if (kind == .recovery) "recovery" else "branch"},
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
                const new_delta = current_delta + concrete_delta + adj_sum;

                if (!rp_arms_dropped) {
                    if (try self.composeArms(eff, stack_model.items, rp_arms[0..rp_branch_count], rp_branch_stacks[0..rp_branch_count])) |composed| {
                        return .{ .applied = .{
                            .new_delta = new_delta,
                            .new_model_size = 0,
                            .output_types = composed.model,
                            .exact = composed.exact,
                        } };
                    }
                }

                const out_types = if (armsAreAlternatives(eff, rp_arms[0..rp_branch_count]))
                    try self.mergeBranchTypes(rp_branch_stacks[0..rp_branch_count])
                else
                    null;

                return .{
                    .applied = .{
                        .new_delta = new_delta,
                        .new_model_size = new_model_size,
                        .output_types = out_types,
                    },
                };
            },
        }
    }

    /// Report a literal quotation argument whose stack adjustment disagrees with the effect it
    /// will run under.
    ///
    /// `validateParameterEffects` makes the same comparison when the word is called. This reports
    /// the literal before anything runs. An annotation with a row variable is left to the
    /// combinator paths, which compare arms against each other rather than against a count.
    fn checkLiteralQuotationArgs(
        self: *InferenceEngine,
        word_def: *const WordDefinition,
        stack_model: []const StackEntry,
        instructions: []const Instruction,
        idx: usize,
        caller: CallerInfo,
        line: usize,
    ) Allocator.Error!void {
        try self.checkHandlerArgs(word_def, stack_model, instructions, idx, caller, line);

        // A row-polymorphic word has each literal arm walked by `handleRowPoly`, which checks a
        // concrete annotation there. Walking it here too would report its diagnostics twice.
        const eff = word_def.stack_effect orelse return;
        if (stack_effect_mod.hasAnyRowVariable(eff.*)) return;

        const concrete_inputs = eff.concreteInputCount();
        if (stack_model.len < concrete_inputs) return;
        const base = stack_model.len - concrete_inputs;

        for (eff.inputs, 0..) |param, i| {
            const annotation = param.quotation_effect orelse continue;
            if (stack_effect_mod.hasAnyRowVariable(annotation.*)) continue;

            const quot = switch (stack_model[base + i]) {
                .quotation => |q| q,
                else => continue,
            };
            const actual = try self.inferLiteralDelta(quot, caller) orelse continue;
            try self.reportAnnotationMismatch(param.name, annotation, actual, caller, line);
        }
    }

    /// The handler words whose quotation's effect depends on another argument, so no single
    /// annotation can declare it. Each is checked when that argument is a literal.
    ///
    /// The words are matched by name, arity, and defining file: `add-hook` from the prelude, and the
    /// two callback constructors from `lib/ffi.1z`.
    fn checkHandlerArgs(
        self: *InferenceEngine,
        word_def: *const WordDefinition,
        stack_model: []const StackEntry,
        instructions: []const Instruction,
        idx: usize,
        caller: CallerInfo,
        line: usize,
    ) Allocator.Error!void {
        const eff = word_def.stack_effect orelse return;
        const arity = eff.inputs.len;
        if (stack_model.len < arity) return;
        const args = stack_model[stack_model.len - arity ..];

        if (std.mem.eql(u8, word_def.name, "add-hook") and arity == 2 and definedIn(word_def, "prelude")) {
            // The variant word's declared output is untyped, so the event is read from the call
            // that pushed it, just ahead of the quotation literal.
            if (idx < 2) return;
            if (instructions[idx - 1].op != .push_literal) return;
            const variant = instructions[idx - 2].op.callTargetName() orelse return;
            const event = hookEventEffect(variant) orelse return;
            const quot = switch (args[1]) {
                .quotation => |q| q,
                else => return,
            };
            const actual = try self.inferLiteralDelta(quot, caller) orelse return;
            return self.reportDeltaMismatch("quot", event.delta, event.text, actual, caller, line);
        }

        const is_callback = definedIn(word_def, "ffi") and
            (std.mem.eql(u8, word_def.name, "ffi-callback") and arity == 2 or
                std.mem.eql(u8, word_def.name, "ffi-callback-with-error-hook") and arity == 4);
        if (is_callback) {
            const sig = switch (args[1]) {
                .struct_literal => |v| v,
                else => return,
            };
            const shape = callbackShape(sig) orelse return;
            const quot = switch (args[0]) {
                .quotation => |q| q,
                else => return,
            };
            const actual = try self.inferLiteralDelta(quot, caller) orelse return;

            var buf: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "( {d} argument{s} -- {d} result{s} )", .{
                shape.inputs,
                if (shape.inputs == 1) @as([]const u8, "") else "s",
                shape.outputs,
                if (shape.outputs == 1) @as([]const u8, "") else "s",
            }) catch return;
            const delta = @as(i64, @intCast(shape.outputs)) - @as(i64, @intCast(shape.inputs));
            return self.reportDeltaMismatch("quotation", delta, text, actual, caller, line);
        }
    }

    /// A literal quotation's inferred stack adjustment, or null when it cannot be inferred or the
    /// quotation never returns, since such a quotation satisfies any effect.
    ///
    /// The engine state a caller reads after a walk is put back, because this walk only answers
    /// the delta for a check made beside the caller's own.
    fn inferLiteralDelta(self: *InferenceEngine, quot: Quotation, caller: CallerInfo) Allocator.Error!?i64 {
        const saved_terminal = self.body_terminal;
        const saved_unknown_callee = self.last_unknown_callee;
        const saved_unknown_polymorphic = self.last_unknown_is_polymorphic;
        defer {
            self.body_terminal = saved_terminal;
            self.last_unknown_callee = saved_unknown_callee;
            self.last_unknown_is_polymorphic = saved_unknown_polymorphic;
        }

        var quot_caller = caller;
        quot_caller.declared_input_count = null;
        quot_caller.alternatives_ok = false;
        const result = try self.inferInstructions(quot.instructions, quot_caller, null);
        if (self.body_terminal) return null;

        return switch (result) {
            .known => |d| d,
            .unknown, .alternatives => null,
        };
    }

    fn reportAnnotationMismatch(
        self: *InferenceEngine,
        param_name: []const u8,
        annotation: *const StackEffect,
        actual: i64,
        caller: CallerInfo,
        line: usize,
    ) Allocator.Error!void {
        var buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        annotation.write(fbs.writer()) catch {};
        try self.reportDeltaMismatch(param_name, annotation.concreteDelta(), fbs.getWritten(), actual, caller, line);
    }

    /// Report a quotation whose adjustment `actual` differs from `expected_delta`, worded as the
    /// runtime check words it.
    fn reportDeltaMismatch(
        self: *InferenceEngine,
        param_name: []const u8,
        expected_delta: i64,
        expected_text: []const u8,
        actual: i64,
        caller: CallerInfo,
        line: usize,
    ) Allocator.Error!void {
        if (actual == expected_delta) return;

        const diff = actual - expected_delta;
        const message = if (diff > 0)
            try std.fmt.allocPrint(self.allocator, "parameter '{s}' expects {s} but quotation leaves {d} extra value{s} on the stack", .{
                param_name,
                expected_text,
                diff,
                if (diff == 1) @as([]const u8, "") else "s",
            })
        else
            try std.fmt.allocPrint(self.allocator, "parameter '{s}' expects {s} but quotation consumes {d} extra value{s} from the stack", .{
                param_name,
                expected_text,
                -diff,
                if (diff == -1) @as([]const u8, "") else "s",
            });

        try self.emitDiagnostic(.{
            .word_name = caller.word_name,
            .source_file = caller.source_file,
            .source_line = line,
            .severity = .err,
            .message = message,
        });
    }

    /// Infer every dispatch entry of a generic, reporting a delta, declared output, or conversion
    /// mismatch. Each entry's window is appended to `entry_windows`. A null `conv_target` skips
    /// the conversion check.
    ///
    /// Returns false when some entry cannot stand in a merged window: a native entry, an unknown
    /// or inexact one, or one whose delta differs from the base body's.
    fn validateDispatchEntries(
        self: *InferenceEngine,
        name: []const u8,
        base_result: InferenceResult,
        word_def: *const WordDefinition,
        caller: CallerInfo,
        conv_target: ?*const TypeValue,
        entry_windows: *std.ArrayListUnmanaged(std.ArrayListUnmanaged(StackEntry)),
    ) Allocator.Error!bool {
        // The context's analysis view adds the arms a check-mode load registered, which sit in
        // its check overlay rather than in the dispatch table.
        const dispatch_entries = try self.ctx.analysisDispatchEntriesForId(word_def.dispatch_id, .by_sequence, self.allocator);
        defer self.allocator.free(dispatch_entries);

        const check_outputs = self.type_check_mode != .off and self.isInCheckedSource(word_def.source_file);
        var mergeable = true;

        for (dispatch_entries) |pair| {
            const entry_instrs = switch (pair.entry.body) {
                .quotation => |q| q.instructions,
                .native_fn, .host_callback => {
                    mergeable = false;
                    continue;
                },
            };
            var entry_out: std.ArrayListUnmanaged(StackEntry) = .{};
            errdefer entry_out.deinit(self.allocator);
            const entry_result = try self.inferInstructions(entry_instrs, caller, &entry_out);
            const entry_exact = self.body_window_exact;

            if (entry_result != .known or !entry_exact or base_result != .known or base_result.known != entry_result.known) {
                mergeable = false;
            }

            // A declaration with `|` alternatives lets each body leave any listed arity, so an
            // entry answers to the declaration rather than to the base body.
            const declared_alternatives: ?InferenceResult = if (word_def.stack_effect) |eff|
                if (eff.hasAlternativeOutput()) computeDeclaredDelta(eff.*) else null
            else
                null;

            if (declared_alternatives) |declared| {
                const admitted = switch (entry_result) {
                    .known => |d| declaredAdmits(declared, d),
                    .alternatives => |set| blk: {
                        for (set.slice()) |d| {
                            if (!declaredAdmits(declared, d)) break :blk false;
                        }
                        break :blk true;
                    },
                    .unknown => true,
                };

                if (!admitted) {
                    const declared_text = try formatDeltas(self.allocator, declared);
                    defer self.allocator.free(declared_text);
                    const entry_text = try formatDeltas(self.allocator, entry_result);
                    defer self.allocator.free(entry_text);

                    try self.emitDiagnostic(.{
                        .word_name = name,
                        .source_file = word_def.source_file,
                        .source_line = word_def.source_line,
                        .severity = .err,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "dispatch entry for ({s}, {s}) has delta {s}, but the declared delta is {s}",
                            .{ self.descriptorName(pair.key.type_a), self.descriptorName(pair.key.type_b), entry_text, declared_text },
                        ),
                    });
                }
            } else if (base_result == .known and entry_result == .known) {
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
            if (entry_result == .known and (check_outputs or conv_target != null)) {
                const type_b = self.descriptorName(pair.key.type_b);
                const method_types = if (type_b.len == 0)
                    try self.allocator.dupe(u8, self.descriptorName(pair.key.type_a))
                else
                    try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ self.descriptorName(pair.key.type_a), type_b });
                defer self.allocator.free(method_types);

                if (check_outputs) {
                    try self.checkDeclaredOutputs(name, word_def, entry_result.known, entry_out.items, method_types);
                }
                if (conv_target) |target| {
                    try self.checkConversionOutput(name, word_def, target, &entry_out, method_types);
                }
            }

            try entry_windows.append(self.allocator, entry_out);
        }

        return mergeable;
    }

    /// Replace a generic's cached window, which so far describes only its base body, with the
    /// merge of the base body and every dispatch entry. A call may reach any of them, so the base
    /// body alone cannot stand for the call. When some entry cannot be merged the cache entry is
    /// dropped, and callers fall back to passthroughs and the declaration.
    fn mergeDispatchWindows(
        self: *InferenceEngine,
        name: []const u8,
        base_window: []const StackEntry,
        entry_windows: []const std.ArrayListUnmanaged(StackEntry),
        entries_mergeable: bool,
    ) Allocator.Error!void {
        if (entry_windows.len == 0) return;

        const base_exact = self.exact_windows.contains(name);
        if (self.type_cache.fetchRemove(name)) |old| {
            if (old.value) |types| self.allocator.free(types);
        }
        _ = self.exact_windows.remove(name);

        if (!entries_mergeable or !base_exact) return;

        var windows: std.ArrayListUnmanaged(std.ArrayListUnmanaged(StackEntry)) = .{};
        defer windows.deinit(self.allocator);
        try windows.append(self.allocator, .{ .items = @constCast(base_window), .capacity = base_window.len });
        try windows.appendSlice(self.allocator, entry_windows);

        var all_empty = true;
        for (windows.items) |w| {
            if (w.items.len != 0) all_empty = false;
        }

        if (all_empty) {
            try self.exact_windows.put(self.allocator, name, {});
            return;
        }

        const merged = try self.mergeBranchTypes(windows.items) orelse return;
        try self.type_cache.put(self.allocator, name, merged);
        try self.exact_windows.put(self.allocator, name, {});
    }

    /// Convention-derived output type for a `>name` conversion word, or null when the word is not
    /// subject to the check. A `>name` word is expected to return a value of type `name`. The check
    /// is skipped unless the suffix names a known builtin type.
    fn conversionTarget(self: *const InferenceEngine, name: []const u8, word_def: *const WordDefinition) ?*const TypeValue {
        if (self.type_check_mode == .off) return null;
        if (name.len < 2 or name[0] != '>') return null;
        if (!self.isInCheckedSource(word_def.source_file)) return null;

        return self.ctx.lookupBuiltinTypeValue(name[1..]);
    }

    /// The conversion target a `>name` word's bodies are still checked against once its top
    /// output annotation is accounted for, or null when no body check is needed.
    ///
    /// A type annotation that satisfies the target is at least as specific, so the declared
    /// output check already covers the body and a second report would duplicate it. One that
    /// contradicts the target is reported here, once, against the declaration itself. A
    /// protocol, combination, or `any` annotation says nothing the convention does not, so the
    /// body is checked against the target as if it were unannotated.
    fn conversionBodyTarget(self: *InferenceEngine, name: []const u8, word_def: *const WordDefinition) Allocator.Error!?*const TypeValue {
        const target = self.conversionTarget(name, word_def) orelse return null;
        const eff = word_def.stack_effect orelse return target;
        if (eff.outputs.len == 0) return target;

        const top = eff.outputs[eff.outputs.len - 1];
        const ann = top.type_annotation orelse return target;
        const declared = switch (ann) {
            .type => |tv| tv,
            .protocol, .combination => return target,
        };
        if (self.any_type_sentinel) |any_tv| {
            if (declared == any_tv) return target;
        }

        if (helpers.typeMatchesConstraint(declared, target)) return null;

        const severity: Severity = if (self.type_check_mode == .warning) .warning else .err;
        try self.emitDiagnostic(.{
            .word_name = name,
            .source_file = word_def.source_file,
            .source_line = word_def.source_line,
            .severity = severity,
            .message = try std.fmt.allocPrint(
                self.allocator,
                "{s} declares output '{s}' as {s}, but a {s} conversion returns {s}",
                .{ name, top.name, declared.name, name, target.name },
            ),
        });
        return null;
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
            .quotation, .protocol_bounded, .other, .struct_literal => null,
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
            const actual_name = self.annotationMismatch(stack_model.items[stack_pos], ann) orelse continue;

            const message = switch (ann) {
                .type => |expected_tv| try std.fmt.allocPrint(
                    self.allocator,
                    "type mismatch: {s} expects {s} for parameter '{s}', but got {s}",
                    .{ word_def.name, expected_tv.name, param.name, actual_name },
                ),
                .protocol => |descriptor| try std.fmt.allocPrint(
                    self.allocator,
                    "{s}: type '{s}' does not satisfy protocol '{s}' for parameter '{s}'",
                    .{ word_def.name, actual_name, descriptor.name, param.name },
                ),
                .combination => continue,
            };

            const severity: Severity = if (self.type_check_mode == .warning) .warning else .err;
            try self.emitDiagnostic(.{
                .word_name = caller.word_name,
                .source_file = caller.source_file,
                .source_line = caller.source_line,
                .severity = severity,
                .message = message,
            });
        }
    }

    /// Compare declared outputs against the stack the body left, top-aligned, and report each
    /// entry that contradicts its annotation. An output below the modelled window is exempt,
    /// as is any entry `annotationMismatch` cannot decide.
    ///
    /// `method_types` names the dispatching types for a method entry, or is null for the base
    /// body. `delta` picks the alternative to compare against when the effect declares `|`
    /// alternatives, and a body matching none of them is left to the delta check.
    fn checkDeclaredOutputs(
        self: *InferenceEngine,
        name: []const u8,
        word_def: *const WordDefinition,
        delta: i64,
        out_stack: []const StackEntry,
        method_types: ?[]const u8,
    ) Allocator.Error!void {
        const eff = word_def.stack_effect orelse return;
        const outputs = eff.outputsForDelta(delta) orelse return;

        const body = if (method_types) |mt|
            try std.fmt.allocPrint(self.allocator, "method{{ {s} }}", .{mt})
        else
            "its body";
        defer if (method_types != null) self.allocator.free(body);

        for (outputs, 0..) |param, i| {
            const ann = param.type_annotation orelse continue;
            const depth = outputs.len - i;
            if (depth > out_stack.len) continue;

            const actual_name = self.annotationMismatch(out_stack[out_stack.len - depth], ann) orelse continue;

            const message = switch (ann) {
                .type => |expected_tv| try std.fmt.allocPrint(
                    self.allocator,
                    "{s} declares output '{s}' as {s}, but {s} returns {s}",
                    .{ name, param.name, expected_tv.name, body, actual_name },
                ),
                .protocol => |descriptor| try std.fmt.allocPrint(
                    self.allocator,
                    "{s} declares output '{s}' as {s}, but {s} returns {s}, which does not satisfy it",
                    .{ name, param.name, descriptor.name, body, actual_name },
                ),
                .combination => continue,
            };

            const severity: Severity = if (self.type_check_mode == .warning) .warning else .err;
            try self.emitDiagnostic(.{
                .word_name = name,
                .source_file = word_def.source_file,
                .source_line = word_def.source_line,
                .severity = severity,
                .message = message,
            });
        }
    }

    /// The name of the type `entry` holds when it contradicts `ann`, or null when the entry
    /// satisfies the annotation or cannot be decided statically.
    fn annotationMismatch(self: *InferenceEngine, entry: StackEntry, ann: stack_effect_mod.TypeAnnotation) ?[]const u8 {
        switch (ann) {
            .type => |expected_tv| return switch (entry) {
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
                .protocol_bounded, .other, .struct_literal => null,
            },
            .protocol => |descriptor| {
                const ctx = self.ctx;
                return switch (entry) {
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
                    .protocol_bounded, .quotation, .other, .struct_literal => null,
                };
            },
            // A combination annotation is not checked statically, so it never contradicts.
            .combination => return null,
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
        if (stack_effect_mod.hasAnyRowVariable(callee_eff.*)) return false;
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

    /// Apply a call to `word_def` to the stack model. Returns false when the model afterwards
    /// holds only a correct top portion of the stack rather than an exact window.
    fn adjustStackModelTyped(
        self: *InferenceEngine,
        word_def: *const WordDefinition,
        stack_model: *std.ArrayListUnmanaged(StackEntry),
        callee_delta: i64,
    ) Allocator.Error!bool {
        const eff = word_def.stack_effect orelse {
            if (!self.exact_windows.contains(word_def.name)) {
                stack_model.shrinkRetainingCapacity(0);
                return false;
            }

            const window: []const StackEntry = if (self.type_cache.get(word_def.name)) |c| c orelse &.{} else &.{};
            return self.applyWindow(stack_model, window, callee_delta);
        };

        if (stack_effect_mod.hasAnyRowVariable(eff.*)) {
            stack_model.shrinkRetainingCapacity(0);
            return false;
        }

        // A declaration with `|` alternatives lists every arity, but the call left only the one
        // the body inferred, so only that alternative's outputs are placed.
        const outputs = eff.outputsForDelta(callee_delta) orelse {
            stack_model.shrinkRetainingCapacity(0);
            return false;
        };
        const chosen = StackEffect{ .inputs = eff.inputs, .outputs = outputs };

        const cached: ?[]const StackEntry = if (self.type_cache.get(word_def.name)) |c| c else null;
        try self.applyEffectToModel(stack_model, &chosen, cached);
        return true;
    }

    /// Replay a body with net `delta` whose exact window is `window`: it consumed
    /// `window.len - delta` entries from beneath its start and left `window` in their place.
    /// Returns false, leaving an empty model, when the counts are inconsistent.
    fn applyWindow(
        self: *InferenceEngine,
        stack_model: *std.ArrayListUnmanaged(StackEntry),
        window: []const StackEntry,
        delta: i64,
    ) Allocator.Error!bool {
        const consumed = @as(i64, @intCast(window.len)) - delta;
        if (consumed < 0) {
            stack_model.shrinkRetainingCapacity(0);
            return false;
        }

        const pop_count = @min(@as(usize, @intCast(consumed)), stack_model.items.len);
        stack_model.shrinkRetainingCapacity(stack_model.items.len - pop_count);
        try stack_model.appendSlice(self.allocator, window);
        return true;
    }

    /// Apply a row-free effect to the stack model by popping its inputs and pushing exactly one
    /// entry per output, so the model stays an aligned top window of the real stack. Adjusting
    /// by delta alone would leave `swap` a no-op and make `nip` drop the wrong entry.
    ///
    /// Each output slot, matched top-aligned against `cached`, takes the first resolved source:
    /// the inferred entry, then the popped entry of the input sharing its name, then the declared
    /// annotation. Inference wins over the annotation because the annotation is only a claim,
    /// one `checkDeclaredOutputs` verifies against that same inference.
    fn applyEffectToModel(
        self: *InferenceEngine,
        stack_model: *std.ArrayListUnmanaged(StackEntry),
        eff: *const StackEffect,
        cached: ?[]const StackEntry,
    ) Allocator.Error!void {
        const pop_count = @min(eff.inputs.len, stack_model.items.len);
        const popped = try self.allocator.dupe(StackEntry, stack_model.items[stack_model.items.len - pop_count ..]);
        defer self.allocator.free(popped);
        stack_model.shrinkRetainingCapacity(stack_model.items.len - pop_count);

        // An input the model never held, because the body consumed below its own pushes, has no
        // popped entry. `popped` lines up with the top `pop_count` inputs.
        const unmodeled_inputs = eff.inputs.len - pop_count;

        for (eff.outputs, 0..) |param, i| {
            const depth = eff.outputs.len - i;

            if (cached) |c| {
                if (depth <= c.len) {
                    const entry = c[c.len - depth];
                    if (entry != .other) {
                        try stack_model.append(self.allocator, entry);
                        continue;
                    }
                }
            }

            if (passthroughEntry(eff, param.name, popped, unmodeled_inputs)) |entry| {
                try stack_model.append(self.allocator, entry);
                continue;
            }

            const entry: StackEntry = if (param.type_annotation) |ann| switch (ann) {
                .type => |tv| .{ .typed = .{ .tv = tv } },
                .protocol => |desc| .{ .protocol_bounded = desc },
                .combination => .other,
            } else .other;
            try stack_model.append(self.allocator, entry);
        }
    }

    /// The popped model entry for the input named `name`, or null when no input shares the name,
    /// the input sat below the model, or its entry is unresolved. The topmost input wins a
    /// repeated name.
    fn passthroughEntry(eff: *const StackEffect, name: []const u8, popped: []const StackEntry, unmodeled_inputs: usize) ?StackEntry {
        var i = eff.inputs.len;
        while (i > 0) {
            i -= 1;
            if (!std.mem.eql(u8, eff.inputs[i].name, name)) continue;
            if (i < unmodeled_inputs) return null;

            const entry = popped[i - unmodeled_inputs];
            return if (entry == .other) null else entry;
        }

        return null;
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
};

fn computeDeclaredDelta(effect: StackEffect) ?InferenceResult {
    if (stack_effect_mod.hasAnyRowVariable(effect)) return null;
    if (effect.hasAlternativeOutput()) {
        const set = effect.alternativeDeltas() orelse return null;
        return .{ .alternatives = set };
    }

    const inputs: i64 = @intCast(effect.inputs.len);
    const outputs: i64 = @intCast(effect.outputs.len);
    return .{ .known = outputs - inputs };
}

/// The declared delta when the effect fixes a single one, or null for a row-polymorphic effect
/// or one with `|` alternatives.
fn declaredKnownDelta(effect: StackEffect) ?i64 {
    const declared = computeDeclaredDelta(effect) orelse return null;
    return switch (declared) {
        .known => |d| d,
        .unknown, .alternatives => null,
    };
}

/// Whether a body that leaves `delta` meets a declaration of `declared`.
fn declaredAdmits(declared: InferenceResult, delta: i64) bool {
    return switch (declared) {
        .known => |d| d == delta,
        .alternatives => |set| set.contains(delta),
        .unknown => true,
    };
}

/// Render a delta or a set of them for a diagnostic, as `1` or `1 or 0`.
fn formatDeltas(allocator: Allocator, result: InferenceResult) Allocator.Error![]const u8 {
    return switch (result) {
        .known => |d| std.fmt.allocPrint(allocator, "{d}", .{d}),
        .unknown => allocator.dupe(u8, "unknown"),
        .alternatives => |set| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            errdefer buf.deinit(allocator);
            for (set.slice(), 0..) |d, i| {
                if (i > 0) try buf.appendSlice(allocator, " or ");
                try buf.writer(allocator).print("{d}", .{d});
            }
            break :blk buf.toOwnedSlice(allocator);
        },
    };
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

/// Whether `word_def` comes from the file named `stem`, whether recorded as a path such as
/// `src/prelude.1z` or as a module name such as `ffi`.
fn definedIn(word_def: *const WordDefinition, comptime stem: []const u8) bool {
    const source = word_def.source_file orelse return false;
    const base = std.fs.path.basename(source);
    const name = if (std.mem.endsWith(u8, base, ".1z")) base[0 .. base.len - 3] else base;
    return std.mem.eql(u8, name, stem);
}

const HandlerEffect = struct {
    delta: i64,
    text: []const u8,
};

/// What a hook for each lifecycle event is handed, as `fireHooks` and `fireScopedHooks` in
/// `primitives/hooks.zig` push it. A hook takes its arguments and leaves nothing.
fn hookEventEffect(variant: []const u8) ?HandlerEffect {
    const events = [_]struct { name: []const u8, effect: HandlerEffect }{
        .{ .name = "on:exit", .effect = .{ .delta = -1, .text = "( code -- )" } },
        .{ .name = "on:unhandled-error", .effect = .{ .delta = -1, .text = "( error -- )" } },
        .{ .name = "on:word-defined", .effect = .{ .delta = -1, .text = "( word-info -- )" } },
        .{ .name = "on:module-loaded", .effect = .{ .delta = -2, .text = "( name path -- )" } },
    };
    for (events) |event| {
        if (std.mem.eql(u8, variant, event.name)) return event.effect;
    }
    return null;
}

const CallbackShape = struct {
    inputs: usize,
    outputs: usize,
};

/// The stack shape an FFI callback built over `sig` runs under: the trampoline pushes one value
/// per parameter and pops one return value unless the return type is void.
fn callbackShape(sig: Value) ?CallbackShape {
    const inst = switch (sig) {
        .struct_instance => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, inst.struct_type.name, "ffi-sig")) return null;

    var params: ?usize = null;
    var returns: ?bool = null;
    for (inst.struct_type.fields, inst.fields) |name, field| {
        if (std.mem.eql(u8, name, "params") and field == .array) params = field.array.items.len;
        if (std.mem.eql(u8, name, "return-type") and field == .string) returns = !std.mem.eql(u8, field.string.bytes, "void");
    }

    return .{
        .inputs = params orelse return null,
        .outputs = if (returns orelse return null) 1 else 0,
    };
}

fn isPartialDispatch(word_def: *const WordDefinition) bool {
    for (word_def.markers) |mk| {
        if (markers.isPartialDispatchMarker(mk)) return true;
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

/// An engine over a full context, with no arity check and no suppression.
fn testEngine(
    ctx: *Context,
    type_check_mode: InferenceEngine.TypeCheckMode,
    default_arm_mode: InferenceEngine.DefaultArmMode,
    never_returns_mode: InferenceEngine.NeverReturnsMode,
) InferenceEngine {
    return InferenceEngine.init(ctx, testing.allocator, null, false, true, null, type_check_mode, .off, default_arm_mode, never_returns_mode);
}

test "native word uses declared effect" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("dup", .{
        .name = "dup",
        .stack_effect = &.{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .action = .{ .native = dummy },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("dup");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
}

test "an engine on a child resolves the root's words and analyzes only the child's frames" {
    var root = Context.init(testing.allocator);
    defer root.deinit();

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try root.dictionary.put("root-dup", .{
        .name = "root-dup",
        .stack_effect = &.{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .action = .{ .native = dummy },
    });

    const root_body: []const Instruction = &.{makeInstr(.{ .call_word = "root-dup" })};
    try root.dictionary.put("root-compound", .{
        .name = "root-compound",
        .source_file = "test.1z",
        .action = .{ .compound = root_body },
    });

    var child = try Context.initChild(testing.allocator, &root, .analysis);
    defer child.deinit();

    try child.pushLocalFrame();

    const child_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "root-dup" }),
        makeInstr(.{ .call_word = "root-dup" }),
    };
    try child.local_frames.items[0].put(child.allocator, "child-compound", .{
        .name = "child-compound",
        .source_file = "test.1z",
        .action = .{ .compound = child_body },
    });

    var engine = testEngine(&child, .off, .off, .off);
    defer engine.deinit();

    try engine.analyzeAll("test.1z");

    try testing.expectEqual(InferenceResult{ .known = 2 }, engine.cache.get("child-compound").?);
    try testing.expect(engine.cache.get("root-compound") == null);
}

test "compound word with inferrable body" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("dup", .{
        .name = "dup",
        .stack_effect = &.{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .action = .{ .native = dummy },
    });

    try dict.put("drop", .{
        .name = "drop",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("my-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
}

test "row-variable effect returns unknown" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const instrs: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };

    try dict.put("row-word", .{
        .name = "row-word",
        .source_file = "test.1z",
        .stack_effect = &.{
            .inputs = &.{.{ .name = "..a", .is_row_variable = true }},
            .outputs = &.{ .{ .name = "..a", .is_row_variable = true }, .{ .name = "n" } },
        },
        .action = .{ .compound = instrs },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("row-word");
    try testing.expectEqual(InferenceResult.unknown, result);
}

test "branch combinator with agreeing quotations" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "branch combinator with disagreeing quotations emits diagnostic" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .off, .off, .off);
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
        .markers = &.{
            @constCast(&markers.branch_combinator_marker),
            @constCast(&markers.partial_dispatch_marker),
        },
        .stack_effect = &.{
            .inputs = &.{ .{ .name = "val" }, .{ .name = "branches" } },
            .outputs = &.{.{ .name = "x" }},
        },
        .action = .{ .native = dummy },
    });
}

fn putCondWord(dict: *Dictionary) !void {
    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    try dict.put("cond", .{
        .name = "cond",
        .markers = &.{
            @constCast(&markers.branch_combinator_marker),
            @constCast(&markers.partial_dispatch_marker),
        },
        .stack_effect = &.{
            .inputs = &.{.{ .name = "branches" }},
            .outputs = &.{.{ .name = "x" }},
        },
        .action = .{ .native = dummy },
    });
}

test "case without default arm warns" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putCaseWord(dict);

    const arm_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 0 } })};
    // { { 1 [ 0 ] } } -- a single keyed arm, no bare-quotation default.
    const pair: []const Value = &.{ .{ .fixnum = 1 }, .{ .quotation = .{ .instructions = arm_body } } };
    var pair_arr = value_mod.Array{ .header = undefined, .items = pair, .storage = .static };
    const branches: []const Value = &.{.{ .array = &pair_arr }};
    var branches_arr = value_mod.Array{ .header = undefined, .items = branches, .storage = .static };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .array = &branches_arr } }),
        makeInstr(.{ .call_word = "case" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .warning, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.warning, engine.diagnostics.items[0].severity);
    try testing.expectEqualStrings("case expression has no default arm", engine.diagnostics.items[0].message);
}

test "case with default arm does not warn" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putCaseWord(dict);

    const arm_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 0 } })};
    const default_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 9 } })};
    const pair: []const Value = &.{ .{ .fixnum = 1 }, .{ .quotation = .{ .instructions = arm_body } } };
    var pair_arr = value_mod.Array{ .header = undefined, .items = pair, .storage = .static };
    // { { 1 [ 0 ] } [ 9 ] } -- a keyed arm plus a bare-quotation default.
    const branches: []const Value = &.{
        .{ .array = &pair_arr },
        .{ .quotation = .{ .instructions = default_body } },
    };
    var branches_arr = value_mod.Array{ .header = undefined, .items = branches, .storage = .static };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .array = &branches_arr } }),
        makeInstr(.{ .call_word = "case" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .warning, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

// A compound word whose body pushes exactly one literal, so its inferred delta is
// +1. Paired with a `( -- <out> )` declaration this keeps the declared-vs-inferred
// delta check quiet, isolating the never-returns consistency diagnostic.
fn putNeverReturnsWord(dict: *Dictionary, name: []const u8, out_name: []const u8, marked: bool) !void {
    const body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 0 } })};
    const marker_slice: []const *value_mod.Marker = if (marked)
        &.{@constCast(&markers.never_returns_marker)}
    else
        &.{};
    try dict.put(name, .{
        .name = name,
        .source_file = "test.1z",
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = out_name }},
        },
        .markers = marker_slice,
        .action = .{ .compound = body },
    });
}

test "bottom output without never-returns marker warns" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putNeverReturnsWord(dict, "w", "*", false);

    var engine = testEngine(&ctx, .off, .off, .warning);
    defer engine.deinit();

    _ = try engine.inferWord("w");
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.warning, engine.diagnostics.items[0].severity);
    try testing.expectEqualStrings("declares a `-- *` output but is not marked never-returns", engine.diagnostics.items[0].message);
}

test "never-returns marker without bottom output warns" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putNeverReturnsWord(dict, "w", "a", true);

    var engine = testEngine(&ctx, .off, .off, .warning);
    defer engine.deinit();

    _ = try engine.inferWord("w");
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.warning, engine.diagnostics.items[0].severity);
    try testing.expectEqualStrings("carries the never-returns marker but does not declare a `-- *` output", engine.diagnostics.items[0].message);
}

test "bottom output with never-returns marker is consistent" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putNeverReturnsWord(dict, "w", "*", true);

    var engine = testEngine(&ctx, .off, .off, .warning);
    defer engine.deinit();

    _ = try engine.inferWord("w");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "no bottom output and no marker is consistent" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putNeverReturnsWord(dict, "w", "a", false);

    var engine = testEngine(&ctx, .off, .off, .warning);
    defer engine.deinit();

    _ = try engine.inferWord("w");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "never-returns consistency pragma gate off suppresses the check" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putNeverReturnsWord(dict, "w", "*", false);

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();
    _ = try engine.inferWord("w");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "never-returns consistency pragma error raises severity" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putNeverReturnsWord(dict, "w", "*", false);

    var engine = testEngine(&ctx, .off, .off, .err);
    defer engine.deinit();
    _ = try engine.inferWord("w");
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "cond without default arm warns" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putCondWord(dict);

    // { { [ pred ] [ body ] } } -- a single predicate/body pair, no default.
    const pred_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .boolean = false } })};
    const arm_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 0 } })};
    const pair: []const Value = &.{
        .{ .quotation = .{ .instructions = pred_body } },
        .{ .quotation = .{ .instructions = arm_body } },
    };
    var pair_arr = value_mod.Array{ .header = undefined, .items = pair, .storage = .static };
    const branches: []const Value = &.{.{ .array = &pair_arr }};
    var branches_arr = value_mod.Array{ .header = undefined, .items = branches, .storage = .static };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .array = &branches_arr } }),
        makeInstr(.{ .call_word = "cond" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .warning, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.warning, engine.diagnostics.items[0].severity);
    try testing.expectEqualStrings("cond expression has no default arm", engine.diagnostics.items[0].message);
}

test "case without default arm errors when default_arm_mode is err" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putCaseWord(dict);

    const arm_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 0 } })};
    const pair: []const Value = &.{ .{ .fixnum = 1 }, .{ .quotation = .{ .instructions = arm_body } } };
    var pair_arr = value_mod.Array{ .header = undefined, .items = pair, .storage = .static };
    const branches: []const Value = &.{.{ .array = &pair_arr }};
    var branches_arr = value_mod.Array{ .header = undefined, .items = branches, .storage = .static };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .array = &branches_arr } }),
        makeInstr(.{ .call_word = "case" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .err, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
    try testing.expectEqualStrings("case expression has no default arm", engine.diagnostics.items[0].message);
}

test "case without default arm is silent when default_arm_mode is off" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    try putCaseWord(dict);

    const arm_body: []const Instruction = &.{makeInstr(.{ .push_literal = .{ .fixnum = 0 } })};
    const pair: []const Value = &.{ .{ .fixnum = 1 }, .{ .quotation = .{ .instructions = arm_body } } };
    var pair_arr = value_mod.Array{ .header = undefined, .items = pair, .storage = .static };
    const branches: []const Value = &.{.{ .array = &pair_arr }};
    var branches_arr = value_mod.Array{ .header = undefined, .items = branches, .storage = .static };

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .array = &branches_arr } }),
        makeInstr(.{ .call_word = "case" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
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
        var ctx = Context.init(testing.allocator);
        defer ctx.deinit();
        const dict = &ctx.dictionary;

        try dict.put("my-eval", .{
            .name = "my-eval",
            .markers = &.{@constCast(&markers.dynamic_eval_marker)},
            .stack_effect = &eval_effect,
            .action = .{ .native = dummy },
        });
        try dict.put("caller", .{
            .name = "caller",
            .source_file = "test.1z",
            .action = .{ .compound = caller_body },
        });

        var engine = testEngine(&ctx, .off, .off, .off);
        defer engine.deinit();

        const result = try engine.inferWord("caller");
        try testing.expect(result == .unknown);
        try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
    }

    // The identical word without the marker is an ordinary concrete-effect
    // callee, so the caller infers cleanly to a known delta of 0.
    {
        var ctx = Context.init(testing.allocator);
        defer ctx.deinit();
        const dict = &ctx.dictionary;

        try dict.put("my-eval", .{
            .name = "my-eval",
            .stack_effect = &eval_effect,
            .action = .{ .native = dummy },
        });
        try dict.put("caller", .{
            .name = "caller",
            .source_file = "test.1z",
            .action = .{ .compound = caller_body },
        });

        var engine = testEngine(&ctx, .off, .off, .off);
        defer engine.deinit();

        const result = try engine.inferWord("caller");
        try testing.expect(result == .known and result.known == 0);
        try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
    }
}

test "loop combinator with zero-delta body" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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
        .stack_effect = &.{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .action = .{ .native = dummy },
    });

    try dict.put("drop", .{
        .name = "drop",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "loop combinator with non-zero-delta body emits diagnostic" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "transitive inference" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("outer");
    try testing.expectEqual(InferenceResult{ .known = 2 }, result);
}

test "recursive cycle with declared effect breaks correctly" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "rec" }),
    };

    try dict.put("rec", .{
        .name = "rec",
        .source_file = "test.1z",
        .stack_effect = &.{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{.{ .name = "b" }},
        },
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("rec");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
}

test "recursive cycle without declared effect returns unknown" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "rec-no-decl" }),
    };

    try dict.put("rec-no-decl", .{
        .name = "rec-no-decl",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("rec-no-decl");
    try testing.expectEqual(InferenceResult.unknown, result);
}

test "generic word with agreeing dispatch entries" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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

    try ctx.dispatch.register(
        .{
            .dispatch_id = 1,
            .type_a = duration_desc,
            .type_b = unary_desc,
        },
        .{ .body = .{ .quotation = .{ .instructions = dispatch_body } } },
        false,
    );

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("my-generic");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "generic word with disagreeing dispatch entries emits diagnostic" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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

    try ctx.dispatch.register(
        .{
            .dispatch_id = 1,
            .type_a = duration_desc2,
            .type_b = unary_desc2,
        },
        .{ .body = .{ .quotation = .{ .instructions = dispatch_body } } },
        false,
    );

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("my-generic");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "generic dispatch entry calling back into the generic does not recurse infinitely" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const base_body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };

    try dict.put("widget", .{
        .name = "widget",
        .source_file = "test.1z",
        .dispatch_id = 1,
        .markers = &.{@constCast(&markers.generic_marker)},
        .action = .{ .compound = base_body },
    });

    const dispatch_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "widget" }),
    };
    const thing_desc = try value_mod.createBuiltinTypeDescriptor(testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(testing.allocator, thing_desc);
    const other_desc = try value_mod.createBuiltinTypeDescriptor(testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(testing.allocator, other_desc);

    try ctx.dispatch.register(
        .{
            .dispatch_id = 1,
            .type_a = thing_desc,
            .type_b = other_desc,
        },
        .{ .body = .{ .quotation = .{ .instructions = dispatch_body } } },
        false,
    );

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("widget");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
}

test "non-literal quotation args fall back to declared effect" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "declared vs inferred mismatch emits diagnostic" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .fixnum = 2 } }),
    };

    try dict.put("bad-decl", .{
        .name = "bad-decl",
        .source_file = "test.1z",
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = "a" }},
        },
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("bad-decl");
    try testing.expectEqual(InferenceResult{ .known = 2 }, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "unknown word returns unknown" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const body: []const Instruction = &.{
        makeInstr(.{ .call_word = "nonexistent" }),
    };

    try dict.put("calls-unknown", .{
        .name = "calls-unknown",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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
        .stack_effect = &.{
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
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{},
        },
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{},
        },
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

const recover_try_annotation = StackEffect{
    .inputs = &.{.{ .name = "..a", .is_row_variable = true }},
    .outputs = &.{.{ .name = "..b", .is_row_variable = true }},
};

const recover_handler_annotation = StackEffect{
    .inputs = &.{ .{ .name = "..a", .is_row_variable = true }, .{ .name = "error" } },
    .outputs = &.{.{ .name = "..b", .is_row_variable = true }},
};

/// Register `recover` with its declared effect and marker, `drop`, and a word whose body is
/// `[ try ] [ handler ] recover`.
fn putRecoverCaller(dict: *Dictionary, try_body: []const Instruction, handler_body: []const Instruction, body: *[3]Instruction) !void {
    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("recover", .{
        .name = "recover",
        .markers = &.{@constCast(&markers.recovery_combinator_marker)},
        .stack_effect = &.{
            .inputs = &.{
                .{ .name = "..a", .is_row_variable = true },
                .{ .name = "try", .quotation_effect = &recover_try_annotation },
                .{ .name = "handler", .quotation_effect = &recover_handler_annotation },
            },
            .outputs = &.{.{ .name = "..b", .is_row_variable = true }},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("drop", .{
        .name = "drop",
        .stack_effect = &.{ .inputs = &.{.{ .name = "x" }}, .outputs = &.{} },
        .action = .{ .native = dummy },
    });

    body.* = .{
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = try_body } } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = handler_body } } }),
        makeInstr(.{ .call_word = "recover" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });
}

test "recovery arms that leave the same stack agree" {
    // try: [ drop 1 ] has delta 0 against a concrete delta of 0. handler: [ drop drop 1 ] has
    // delta -1 against a concrete delta of -1, since it also takes the error. Both adjust by 0.
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const try_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "drop" }),
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };
    const handler_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "drop" }),
        makeInstr(.{ .call_word = "drop" }),
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };

    var body: [3]Instruction = undefined;
    try putRecoverCaller(dict, try_body, handler_body, &body);

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "a recovery handler that drops only the error is reported" {
    // try: [ drop 1 ] adjusts by 0. handler: [ drop 1 ] has delta 0 against -1, so it adjusts by
    // 1 and leaves the try quotation's input behind.
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const arm: []const Instruction = &.{
        makeInstr(.{ .call_word = "drop" }),
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };

    var body: [3]Instruction = undefined;
    try putRecoverCaller(dict, arm, arm, &body);

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
    try testing.expectEqualStrings("recovery quotations have mismatched row variable adjustments", engine.diagnostics.items[0].message);
}

const handler_annotation = StackEffect{ .inputs = &.{.{ .name = "signum" }}, .outputs = &.{} };

/// Register `on-handler ( signal quot: ( signum -- ) -- )`, `drop`, and a word whose body is
/// `1 [ handler ] on-handler`.
fn putHandlerCaller(dict: *Dictionary, handler_body: []const Instruction, body: *[3]Instruction) !void {
    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("on-handler", .{
        .name = "on-handler",
        .stack_effect = &.{
            .inputs = &.{ .{ .name = "signal" }, .{ .name = "quot", .quotation_effect = &handler_annotation } },
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("drop", .{
        .name = "drop",
        .stack_effect = &.{ .inputs = &.{.{ .name = "x" }}, .outputs = &.{} },
        .action = .{ .native = dummy },
    });

    body.* = .{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = .{ .quotation = .{ .instructions = handler_body } } }),
        makeInstr(.{ .call_word = "on-handler" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });
}

test "a literal quotation matching a concrete annotation is silent" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const handler_body: []const Instruction = &.{makeInstr(.{ .call_word = "drop" })};
    var body: [3]Instruction = undefined;
    try putHandlerCaller(dict, handler_body, &body);

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "a literal quotation that leaves a value against a concrete annotation is reported" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const handler_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "drop" }),
        makeInstr(.{ .push_literal = .{ .fixnum = 777 } }),
    };
    var body: [3]Instruction = undefined;
    try putHandlerCaller(dict, handler_body, &body);

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
    try testing.expect(std.mem.indexOf(u8, engine.diagnostics.items[0].message, "quotation leaves 1 extra value") != null);
}

test "a literal quotation whose effect cannot be inferred is not reported" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const handler_body: []const Instruction = &.{makeInstr(.{ .call_word = "no-such-word" })};
    var body: [3]Instruction = undefined;
    try putHandlerCaller(dict, handler_body, &body);

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "row-poly keep with insufficient stack falls through" {
    // When the stack model has fewer entries than concreteInputCount,
    // handleRowPoly should return .fallthrough
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    // Falls through to inferWord which returns unknown for row-poly keep
    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult.unknown, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "row-poly keep with non-literal quotation falls through" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

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
        .stack_effect = &.{
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
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .off, .off, .off);
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const mod = try makeTestModule(testing.allocator);
    defer testing.allocator.destroy(mod);
    defer mod.words.deinit(testing.allocator);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try mod.words.put(testing.allocator, "double", .{
        .stack_effect = &.{
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
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = "n" }},
        },
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "polymorphic qualified name falls back to declared delta with note" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const mod = try makeTestModule(testing.allocator);
    defer testing.allocator.destroy(mod);
    defer mod.words.deinit(testing.allocator);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try mod.words.put(testing.allocator, "poly-word", .{
        .polymorphic = true,
        .stack_effect = &.{
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
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = "x" }},
        },
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
    engine.checked_source = "test.1z";
    defer engine.deinit();

    const result = try engine.inferWord("caller");
    try testing.expectEqual(InferenceResult{ .known = 1 }, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.note, engine.diagnostics.items[0].severity);
}

test "declared-delta fallback prevents cascade" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    // Word A calls an unknown callee, but has a declared effect
    const body_a: []const Instruction = &.{
        makeInstr(.{ .call_word = "nonexistent" }),
    };

    try dict.put("word-a", .{
        .name = "word-a",
        .source_file = "test.1z",
        .stack_effect = &.{
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
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = "r" }},
        },
        .action = .{ .compound = body_b },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    const mod = try makeTestModule(testing.allocator);
    defer testing.allocator.destroy(mod);
    defer mod.words.deinit(testing.allocator);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try mod.words.put(testing.allocator, "poly-word", .{
        .polymorphic = true,
        .stack_effect = &.{
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
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = "x" }},
        },
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "type mismatch emits diagnostic" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);
    try ctx.builtin_type_values.put(ctx.allocator, "string", &string_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = &.{
            .inputs = &.{.{ .name = "n", .type_annotation = .{ .type = &fixnum_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = value_mod.stringValue("hello") }),
        makeInstr(.{ .call_word = "consume-fixnum" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqual(Severity.err, engine.diagnostics.items[0].severity);
}

test "declared union input accepts matching typed value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };
    var union_members = [_]*const TypeValue{ &fixnum_tv, &string_tv };
    var union_tv = TypeValue{ .name = "fixnum|string", .descriptor = null, .member_types = union_members[0..] };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);
    try ctx.builtin_type_values.put(ctx.allocator, "string", &string_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-union", .{
        .name = "consume-union",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "declared any input accepts concrete typed value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var any_tv = TypeValue{ .name = "any", .descriptor = null };
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-any", .{
        .name = "consume-any",
        .stack_effect = &.{
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

    var engine = InferenceEngine.init(&ctx, testing.allocator, null, false, true, &any_tv, .err, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "declared parent enum input accepts tagged variant value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var color_tv = TypeValue{ .name = "color", .descriptor = null };
    var color_red_tv = TypeValue{ .name = "color:red", .descriptor = null };

    var tagged_type = value_mod.VirtualType{
        .name = "color:red",
        .inner_type = "symbol",
        .parent_type = &color_tv,
        .type_val = &color_red_tv,
    };
    var inner = value_mod.symbolValue("red");
    const tagged = Value{ .tagged = .{ .tag = &tagged_type, .inner = &inner } };

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-color", .{
        .name = "consume-color",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "declared base input accepts parameterized tagged value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var array_tv = TypeValue{ .name = "array", .descriptor = null };
    var array_fixnum_tv = TypeValue{ .name = "array(fixnum)", .descriptor = null };

    var tagged_type = value_mod.VirtualType{
        .name = "array(fixnum)",
        .inner_type = "array",
        .base_type = &array_tv,
        .type_val = &array_fixnum_tv,
    };
    var elems = [_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } };
    var elems_arr = value_mod.Array{ .header = undefined, .items = elems[0..], .storage = .static };
    var inner = Value{ .array = &elems_arr };
    const tagged = Value{ .tagged = .{ .tag = &tagged_type, .inner = &inner } };

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-array", .{
        .name = "consume-array",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .err, .off, .off);
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("unknown-producer", .{
        .name = "unknown-producer",
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = "x" }},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "type check mode off skips all checks" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);
    try ctx.builtin_type_values.put(ctx.allocator, "string", &string_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = &.{
            .inputs = &.{.{ .name = "n", .type_annotation = .{ .type = &fixnum_tv } }},
            .outputs = &.{},
        },
        .action = .{ .native = dummy },
    });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = value_mod.stringValue("hello") }),
        makeInstr(.{ .call_word = "consume-fixnum" }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .off, .off, .off);
    defer engine.deinit();

    const result = try engine.inferWord("test-word");
    try testing.expectEqual(InferenceResult{ .known = 0 }, result);
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

// =============================================================================
// Protocol-bound annotation tests
// =============================================================================

test "protocol-bounded output flowing into same-protocol input emits no diagnostic" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var p_desc = value_mod.ProtocolDescriptor{ .name = "P", .methods = &.{}, .protocol_id = 1 };

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("produce-p", .{
        .name = "produce-p",
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = "y", .type_annotation = .{ .protocol = &p_desc } }},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("consume-p", .{
        .name = "consume-p",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "protocol-bounded output flowing into different-protocol input defers silently" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var p_desc = value_mod.ProtocolDescriptor{ .name = "P", .methods = &.{}, .protocol_id = 1 };
    var q_desc = value_mod.ProtocolDescriptor{ .name = "Q", .methods = &.{}, .protocol_id = 2 };

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("produce-p", .{
        .name = "produce-p",
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = "y", .type_annotation = .{ .protocol = &p_desc } }},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("consume-q", .{
        .name = "consume-q",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "protocol-bounded output flowing into concrete input defers silently" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var p_desc = value_mod.ProtocolDescriptor{ .name = "P", .methods = &.{}, .protocol_id = 1 };
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("produce-p", .{
        .name = "produce-p",
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{.{ .name = "y", .type_annotation = .{ .protocol = &p_desc } }},
        },
        .action = .{ .native = dummy },
    });

    try dict.put("consume-fixnum", .{
        .name = "consume-fixnum",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "concrete typed entry flowing into protocol input without ctx is silently skipped" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var p_desc = value_mod.ProtocolDescriptor{ .name = "P", .methods = &.{}, .protocol_id = 1 };
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("consume-p", .{
        .name = "consume-p",
        .stack_effect = &.{
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

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

fn expectModelTypes(model: []const StackEntry, expected: []const ?*const TypeValue) !void {
    try testing.expectEqual(expected.len, model.len);
    for (model, expected) |entry, want| {
        if (want) |tv| {
            try testing.expect(entry == .typed);
            try testing.expectEqual(tv, entry.typed.tv);
        } else {
            try testing.expect(entry == .other);
        }
    }
}

test "applying a shuffle effect permutes model entries by parameter name" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    var model: std.ArrayListUnmanaged(StackEntry) = .{};
    defer model.deinit(testing.allocator);

    const swap_eff = StackEffect{ .inputs = &.{ .{ .name = "a" }, .{ .name = "b" } }, .outputs = &.{ .{ .name = "b" }, .{ .name = "a" } } };
    try model.appendSlice(testing.allocator, &.{ .{ .typed = .{ .tv = &string_tv } }, .{ .typed = .{ .tv = &fixnum_tv } } });
    try engine.applyEffectToModel(&model, &swap_eff, null);
    try expectModelTypes(model.items, &.{ &fixnum_tv, &string_tv });

    const nip_eff = StackEffect{ .inputs = &.{ .{ .name = "a" }, .{ .name = "b" } }, .outputs = &.{.{ .name = "b" }} };
    try engine.applyEffectToModel(&model, &nip_eff, null);
    try expectModelTypes(model.items, &.{&string_tv});

    const over_eff = StackEffect{ .inputs = &.{ .{ .name = "a" }, .{ .name = "b" } }, .outputs = &.{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "a" } } };
    try model.insert(testing.allocator, 0, .{ .typed = .{ .tv = &fixnum_tv } });
    try engine.applyEffectToModel(&model, &over_eff, null);
    try expectModelTypes(model.items, &.{ &fixnum_tv, &string_tv, &fixnum_tv });
}

test "applying an effect past the bottom of the model pushes unresolved outputs" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    var model: std.ArrayListUnmanaged(StackEntry) = .{};
    defer model.deinit(testing.allocator);

    // The model holds only `b`. `a` sat below it, so the `a` the swap brings to the top is
    // unresolved rather than a stale copy of `b`.
    const swap_eff = StackEffect{ .inputs = &.{ .{ .name = "a" }, .{ .name = "b" } }, .outputs = &.{ .{ .name = "b" }, .{ .name = "a" } } };
    try model.append(testing.allocator, .{ .typed = .{ .tv = &fixnum_tv } });
    try engine.applyEffectToModel(&model, &swap_eff, null);
    try expectModelTypes(model.items, &.{ &fixnum_tv, null });

    const add_eff = StackEffect{ .inputs = &.{ .{ .name = "x" }, .{ .name = "y" }, .{ .name = "z" } }, .outputs = &.{.{ .name = "sum" }} };
    try engine.applyEffectToModel(&model, &add_eff, null);
    try expectModelTypes(model.items, &.{null});
}

test "an inferred output entry outranks a passthrough and a contradicting annotation" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    var model: std.ArrayListUnmanaged(StackEntry) = .{};
    defer model.deinit(testing.allocator);
    try model.append(testing.allocator, .{ .typed = .{ .tv = &fixnum_tv } });

    // `( x -- x: fixnum y: fixnum )`, whose body was inferred to leave `.other string`.
    const eff = StackEffect{
        .inputs = &.{.{ .name = "x" }},
        .outputs = &.{
            .{ .name = "x", .type_annotation = .{ .type = &fixnum_tv } },
            .{ .name = "y", .type_annotation = .{ .type = &fixnum_tv } },
        },
    };
    const cached = [_]StackEntry{ .other, .{ .typed = .{ .tv = &string_tv } } };

    // `y` takes the inferred string over its annotation. `x` has no resolved inferred entry, so it
    // carries the caller's fixnum through.
    try engine.applyEffectToModel(&model, &eff, &cached);
    try expectModelTypes(model.items, &.{ &fixnum_tv, &string_tv });
}

test "a callee without a declared effect is replayed from its inferred window" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);
    try ctx.builtin_type_values.put(ctx.allocator, "string", &string_tv);

    const dummy: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("drop", .{
        .name = "drop",
        .stack_effect = &.{ .inputs = &.{.{ .name = "x" }}, .outputs = &.{} },
        .action = .{ .native = dummy },
    });

    // `helper` replaces its input with a fixnum. Adjusting by its delta of zero alone would
    // leave the caller's string in place.
    const helper_body: []const Instruction = &.{
        makeInstr(.{ .call_word = "drop" }),
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
    };
    try dict.put("helper", .{ .name = "helper", .source_file = "test.1z", .action = .{ .compound = helper_body } });

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = value_mod.stringValue("s") }),
        makeInstr(.{ .call_word = "helper" }),
    };
    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .stack_effect = &.{ .inputs = &.{}, .outputs = &.{.{ .name = "n", .type_annotation = .{ .type = &fixnum_tv } }} },
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "a declared output the body contradicts is reported at the definition" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const dict = &ctx.dictionary;

    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var string_tv = TypeValue{ .name = "string", .descriptor = null };
    try ctx.builtin_type_values.put(ctx.allocator, "fixnum", &fixnum_tv);
    try ctx.builtin_type_values.put(ctx.allocator, "string", &string_tv);

    const body: []const Instruction = &.{
        makeInstr(.{ .push_literal = .{ .fixnum = 1 } }),
        makeInstr(.{ .push_literal = value_mod.stringValue("two") }),
    };

    try dict.put("test-word", .{
        .name = "test-word",
        .source_file = "test.1z",
        .source_line = 7,
        .stack_effect = &.{
            .inputs = &.{},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "b", .type_annotation = .{ .type = &fixnum_tv } } },
        },
        .action = .{ .compound = body },
    });

    var engine = testEngine(&ctx, .err, .off, .off);
    defer engine.deinit();

    _ = try engine.inferWord("test-word");
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);

    const d = engine.diagnostics.items[0];
    try testing.expectEqual(Severity.err, d.severity);
    try testing.expectEqual(@as(usize, 7), d.source_line);
    try testing.expectEqualStrings("test-word declares output 'b' as fixnum, but its body returns string", d.message);
}
