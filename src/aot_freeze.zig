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
const markers_mod = @import("primitives/markers.zig");
const pic_mod = @import("pic.zig");

pub const AotQuotationDesc = struct {
    quotation_id: u32,
    instructions: []const Instruction,
    c_name: []const u8,
    inferred_effect: ?ir_codegen.InferredEffect = null,
    compiled: bool = false,
};

pub const FreezeResult = struct {
    words: []AotWordDesc,
    quotations: []AotQuotationDesc,
    entry_word_id: u32,
    max_word_id: u32,
    max_quotation_id: u32,
    skipped_words: []const []const u8,
    entry_instrs: []const Instruction,
    /// One entry per reachable `call_word` instruction, recording where the
    /// call originates and which callee freeze resolved it to. Built during
    /// Word Discovery BFS and remapped to caller word ids in buildAotDescs.
    /// Stable ordering: insertion order from the BFS.
    call_targets: []const CallTargetEntry = &.{},

    pub fn deinit(self: *FreezeResult, allocator: Allocator) void {
        allocator.free(self.entry_instrs);
        for (self.words) |w| {
            if (w.pic_snapshot) |ps| {
                ps.deinit();
                allocator.destroy(ps);
            }
        }
        allocator.free(self.words);
        for (self.quotations) |q| allocator.free(q.c_name);
        allocator.free(self.quotations);
        allocator.free(self.skipped_words);
        for (self.call_targets) |entry| {
            if (entry.quotation_path.len > 0) allocator.free(entry.quotation_path);
        }
        allocator.free(self.call_targets);
    }
};

/// Why a `call_word` could not be resolved to a concrete callee during the
/// freeze BFS. Distinct reasons exist so downstream enforcement can apply
/// different rules to each.
pub const UnresolvedReason = enum {
    /// Neither `Context.lookupWord` nor `resolveQualifiedModuleWord` returned
    /// a definition for the name. The callee is genuinely absent from the
    /// dictionary visible at freeze time.
    not_in_dictionary,
    /// The name resolves to a compound word marked `parse_time_only`. The
    /// existing BFS skips such words because they have no runtime presence
    /// and no `word_id` is ever assigned.
    skipped_parse_time_only,
    /// The callee resolved during BFS but was dropped by buildAotDescs
    /// because its definition has no stack effect. Only reachable on the
    /// MissingStackEffects error path; the surrounding FreezeResult is
    /// deinit'd before any consumer observes the call_targets array.
    skipped_no_stack_effect,
};

/// Classification placeholder for words materialized by generators
/// (struct accessors, virtual constructors, `method{` dispatchers).
/// Reserved for future use; not emitted today.
pub const GeneratedKind = enum {
    placeholder,
};

/// The result of resolving a `call_word` instruction's name at freeze time.
/// The `native` and `compound` variants carry the assigned word id from
/// `buildAotDescs`; the `unresolved` variant carries a reason; `generated`
/// is reserved for future generator-classification work.
pub const ResolvedCallee = union(enum) {
    native: u32,
    compound: u32,
    generated: GeneratedKind,
    unresolved: UnresolvedReason,
};

/// One reachable call_word instruction, identified by its containing word
/// and the path within that word's instruction tree.
///
/// `instruction_index` indexes into the containing word's top-level
/// instruction body. `quotation_path` walks into nested quotation literals
/// to reach the call site; an empty path means the call is at the top
/// level of the containing word's body. For example, a call at index 2 of
/// the quotation at index 5 of the caller's body has
/// `instruction_index = 5` and `quotation_path = .{ 2 }`.
pub const CallTargetEntry = struct {
    caller_word_id: u32,
    instruction_index: u32,
    quotation_path: []const u32,
    resolved: ResolvedCallee,
};

pub const FreezeFeatureUse = struct {
    caller_name: []const u8,
    feature_name: []const u8,
};

pub const FreezeDiagnostics = struct {
    fatal_dynamic_feature: ?FreezeFeatureUse = null,
    fatal_native_interpreter_dependency: ?FreezeFeatureUse = null,
    missing_stack_effects: []const []const u8 = &.{},
};

pub const FreezeError = error{
    FileNotFound,
    FileReadFailed,
    ExecutionFailed,
    OutOfMemory,
    DisallowedDynamicFeature,
    DisallowedNativeInterpreterDependency,
    MissingStackEffects,
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
    diagnostics: *FreezeDiagnostics,
    allocator: Allocator,
) (FreezeError || Allocator.Error)!FreezeResult {
    return freezeModuleGraphOpts(ctx, entry_file, diagnostics, allocator, .{});
}

pub const FreezeOptions = struct {
    compile_all_prelude: bool = false,
    runtime_image: bool = false,
};

pub fn freezeModuleGraphOpts(
    ctx: *Context,
    entry_file: []const u8,
    diagnostics: *FreezeDiagnostics,
    allocator: Allocator,
    options: FreezeOptions,
) (FreezeError || Allocator.Error)!FreezeResult {
    diagnostics.* = .{};

    // Snapshot prelude word names before loading the entry file. Words
    // that exist now will be available in the AOT runtime dictionary
    // (which also calls loadPrelude). In permissive AOT, codegen failures
    // for these words can fall through to `jitInterpretedCall`; strict
    // AOT rejects compound fallback regardless of prelude membership.
    const prelude_frame_count = ctx.local_frames.items.len;
    var prelude_words = std.StringHashMapUnmanaged(void){};
    defer prelude_words.deinit(allocator);
    for (ctx.local_frames.items[0..prelude_frame_count]) |frame| {
        var it = frame.iterator();
        while (it.next()) |entry| {
            try prelude_words.put(allocator, entry.key_ptr.*, {});
        }
    }
    // Include global dictionary words containing native primitives, so
    // that compile-all-prelude can add them to the resolver.
    {
        var dict_it = ctx.dictionary.entries.iterator();
        while (dict_it.next()) |entry| {
            try prelude_words.put(allocator, entry.key_ptr.*, {});
        }
    }

    // Phase 1: Execute entry file, collect non-definition instructions.
    // The local frame and pragma frame are kept alive so that lookupWord
    // can find words defined in the entry file during discovery.
    const entry_instrs = executeAndCollectEntry(ctx, entry_file, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.FileNotFound,
        error.FileReadFailed => return error.FileReadFailed,
        else => return error.ExecutionFailed,
    };

    // Phase 2: Discover all reachable compound words via BFS.
    // The entry file's local frame is still on the stack, so lookupWord
    // finds entry-file definitions and their imports.
    var discovered = discoverReachableWords(ctx, entry_instrs, diagnostics, options.runtime_image, allocator) catch |err| {
        ctx.popPragmaFrame();
        ctx.popLocalFrame();
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.DisallowedDynamicFeature => error.DisallowedDynamicFeature,
            error.DisallowedNativeInterpreterDependency => error.DisallowedNativeInterpreterDependency,
        };
    };
    defer discovered.names.deinit(ctx.quotationAllocator());
    defer discovered.defs.deinit(ctx.quotationAllocator());
    defer discovered.native_names.deinit(ctx.quotationAllocator());
    defer discovered.native_defs.deinit(ctx.quotationAllocator());
    defer discovered.quotation_bodies.deinit(ctx.quotationAllocator());
    defer discovered.pending_call_targets.deinit(ctx.quotationAllocator());
    // Path slices in pending entries are allocated from the result
    // allocator and transferred to FreezeResult.call_targets by
    // buildAotDescs. On any error between here and a successful return,
    // those slices must be freed manually since the FreezeResult never
    // takes ownership. buildAotDescs zeros out the transferred slice
    // references on success so this errdefer is a no-op after handoff.
    errdefer freePendingCallTargetPaths(&discovered.pending_call_targets, allocator);

    if (options.compile_all_prelude) {
        const temp_allocator = ctx.quotationAllocator();
        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(temp_allocator);
        for (discovered.names.items) |name| {
            try seen.put(temp_allocator, name, {});
        }
        for (discovered.native_names.items) |name| {
            try seen.put(temp_allocator, name, {});
        }

        var prelude_it = prelude_words.iterator();
        while (prelude_it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (seen.contains(name)) continue;
            const word = ctx.lookupWord(name) orelse continue;
            if (word.parse_time_only) continue;
            if (word.stack_effect == null) continue;
            switch (word.action) {
                .compound => {
                    try discovered.names.append(temp_allocator, name);
                    try discovered.defs.append(temp_allocator, word);
                },
                .native, .host_callback => {
                    try discovered.native_names.append(temp_allocator, name);
                    try discovered.native_defs.append(temp_allocator, word);
                },
            }
        }
    }

    // Phase 2b: Scan all discovered compound words for native calls that
    // the BFS couldn't resolve. This catches:
    //
    // 1. Module-qualified names, e.g., "native.struct-field-get", that
    //    lookupWord can't handle.
    // 2. Direct dictionary words referenced by prelude words added by
    //    compile_all_prelude which never went through the BFS.
    {
        const temp_allocator = ctx.quotationAllocator();
        var qual_seen = std.StringHashMapUnmanaged(void){};
        defer qual_seen.deinit(temp_allocator);
        for (discovered.native_names.items) |name| {
            try qual_seen.put(temp_allocator, name, {});
        }
        for (discovered.names.items) |name| {
            try qual_seen.put(temp_allocator, name, {});
        }

        for (discovered.defs.items) |def| {
            const instrs = switch (def.action) {
                .compound => |c| c,
                else => continue,
            };
            for (instrs) |instr| {
                switch (instr.op) {
                    .call_word => |call_name| {
                        if (qual_seen.contains(call_name)) continue;
                        try qual_seen.put(temp_allocator, call_name, {});
                        if (!options.runtime_image and isInterpreterDependentNative(ctx, call_name)) {
                            diagnostics.fatal_native_interpreter_dependency = .{
                                .caller_name = def.name,
                                .feature_name = call_name,
                            };
                            ctx.popPragmaFrame();
                            ctx.popLocalFrame();
                            return error.DisallowedNativeInterpreterDependency;
                        }
                        try discoverCalleeWord(ctx, call_name, &discovered, temp_allocator);
                    },
                    .push_literal => |val| {
                        // Also scan nested quotations
                        if (val == .quotation) {
                            for (val.quotation.instructions) |q_instr| {
                                switch (q_instr.op) {
                                    .call_word => |call_name| {
                                        if (qual_seen.contains(call_name)) continue;
                                        try qual_seen.put(temp_allocator, call_name, {});
                                        if (!options.runtime_image and isInterpreterDependentNative(ctx, call_name)) {
                                            diagnostics.fatal_native_interpreter_dependency = .{
                                                .caller_name = def.name,
                                                .feature_name = call_name,
                                            };
                                            ctx.popPragmaFrame();
                                            ctx.popLocalFrame();
                                            return error.DisallowedNativeInterpreterDependency;
                                        }
                                        try discoverCalleeWord(ctx, call_name, &discovered, temp_allocator);
                                    },
                                    else => {},
                                }
                            }
                        }
                    },
                }
            }
        }
    }

    // Now safe to pop the frames
    ctx.popPragmaFrame();
    ctx.popLocalFrame();

    // Phase 3: Build AotWordDesc array
    var result = try buildAotDescs(entry_instrs, &discovered, discovered.pending_call_targets.items, &prelude_words, ctx, allocator);
    if (result.skipped_words.len > 0) {
        diagnostics.missing_stack_effects = result.skipped_words;
        result.skipped_words = &.{};
        result.deinit(allocator);
        return error.MissingStackEffects;
    }

    // Success: path slices have been duped into result.call_targets. Free
    // the BFS-time originals; the idempotent free renders the errdefer
    // above a no-op if any subsequent step fails.
    freePendingCallTargetPaths(&discovered.pending_call_targets, allocator);

    return result;
}

/// Accumulated non-definition instructions from the entry file and
/// the set of word names defined in the entry file's local frame.
const EntryInstructions = []const Instruction;

/// Execute the entry file through the interpreter, collecting
/// non-definition top-level instructions as the entry point body.
fn executeAndCollectEntry(
    ctx: *Context,
    entry_file: []const u8,
    _: Allocator,
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
    const temp_allocator = ctx.quotationAllocator();

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
                                try entry_instrs.appendSlice(temp_allocator, instrs);
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
                        try entry_instrs.appendSlice(temp_allocator, instrs);
                    }
                }
                processor.reset();
            },
        }
    }

    // Do NOT pop the local frame or pragma frame here. The caller
    // (freezeModuleGraph) keeps them alive for word discovery, then pops.

    return entry_instrs.toOwnedSlice(temp_allocator);
}

const DiscoveredWords = struct {
    names: std.ArrayListUnmanaged([]const u8),
    defs: std.ArrayListUnmanaged(WordDefinition),
    native_names: std.ArrayListUnmanaged([]const u8),
    native_defs: std.ArrayListUnmanaged(WordDefinition),
    quotation_bodies: std.ArrayListUnmanaged([]const Instruction),
    /// One entry per reachable `call_word` instruction encountered during
    /// BFS. Caller is recorded by name here; buildAotDescs remaps to the
    /// assigned word id when producing FreezeResult.call_targets. The
    /// callee discriminator and assigned id are filled in at remap time
    /// from the discovered name tables.
    pending_call_targets: std.ArrayListUnmanaged(PendingCallTarget) = .{},
};

/// Where a callee name should be looked up at remap time so that the
/// final ResolvedCallee can carry an assigned word id. The BFS performs
/// the dictionary lookup once per call site to decide which table will
/// hold the id (compound vs native) or whether the callee is unresolved.
const PendingResolution = union(enum) {
    compound_name: []const u8,
    native_name: []const u8,
    unresolved: UnresolvedReason,
};

/// A call_word instruction recorded during BFS, awaiting remap to the
/// caller's assigned word id and (for resolved callees) lookup of the
/// callee's assigned word id.
const PendingCallTarget = struct {
    caller_name: []const u8,
    instruction_index: u32,
    quotation_path: []const u32,
    pending: PendingResolution,
};

/// BFS over call_word references starting from entry instructions,
/// collecting all reachable compound words.
fn discoverReachableWords(
    ctx: *Context,
    entry_instrs: []const Instruction,
    diagnostics: *FreezeDiagnostics,
    runtime_image: bool,
    result_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!DiscoveredWords {
    const temp_allocator = ctx.quotationAllocator();

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(temp_allocator);

    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(temp_allocator);

    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(temp_allocator);

    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(temp_allocator);

    var result = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
        .pending_call_targets = .{},
    };

    // Push deps frames for every loaded module so that lookupWord can find
    // module-private words during BFS. At runtime the executor pushes a
    // module's deps frame just before running its words; the AOT freeze
    // walks every word statically, so it needs all loaded modules' deps
    // visible for the duration of discovery.
    var pushed_module_frames: usize = 0;
    {
        var cache_iter = ctx.module_cache_value.iterator();
        while (cache_iter.next()) |entry| {
            if (entry.value_ptr.* == .module) {
                ctx.pushModuleDepsFrame(entry.value_ptr.*.module) catch continue;
                pushed_module_frames += 1;
            }
        }
    }
    defer {
        var i: usize = 0;
        while (i < pushed_module_frames) : (i += 1) ctx.popLocalFrame();
    }

    // Seed worklist from entry instructions
    collectCallWords(ctx, entry_instrs, "__entry__", &worklist, &seen, &result.quotation_bodies, &quotation_seen, &result.pending_call_targets, &quotation_path, diagnostics, runtime_image, temp_allocator, result_allocator) catch |err| {
        freePendingCallTargetPaths(&result.pending_call_targets, result_allocator);
        result.names.deinit(temp_allocator);
        result.defs.deinit(temp_allocator);
        result.native_names.deinit(temp_allocator);
        result.native_defs.deinit(temp_allocator);
        result.quotation_bodies.deinit(temp_allocator);
        result.pending_call_targets.deinit(temp_allocator);
        return err;
    };

    // BFS
    while (worklist.pop()) |name| {
        const word = ctx.lookupWord(name) orelse {
            // Try module-qualified resolution (e.g., "native.struct-field-get").
            // Generated words from struct{, virtual{, and enum{ call native
            // operations via qualified names that lookupWord cannot resolve
            // directly.
            if (resolveQualifiedModuleWord(ctx, name)) |mod_word| {
                switch (mod_word.action) {
                    .native, .host_callback => {
                        // Polymorphic natives without a declared stack effect
                        // are also registered so pre-scan can resolve every
                        // reachable native; `buildAotDescs` enters them with
                        // zero input/output counts and the codegen either
                        // special-cases or bails out per native.
                        try result.native_names.append(temp_allocator, name);
                        try result.native_defs.append(temp_allocator, wordDefFromModuleWord(name, mod_word));
                    },
                    .compound => |compound_instrs| {
                        try result.names.append(temp_allocator, name);
                        try result.defs.append(temp_allocator, wordDefFromModuleWord(name, mod_word));
                        collectCallWords(ctx, compound_instrs, name, &worklist, &seen, &result.quotation_bodies, &quotation_seen, &result.pending_call_targets, &quotation_path, diagnostics, runtime_image, temp_allocator, result_allocator) catch |err| {
                            freePendingCallTargetPaths(&result.pending_call_targets, result_allocator);
                            result.names.deinit(temp_allocator);
                            result.defs.deinit(temp_allocator);
                            result.native_names.deinit(temp_allocator);
                            result.native_defs.deinit(temp_allocator);
                            result.quotation_bodies.deinit(temp_allocator);
                            result.pending_call_targets.deinit(temp_allocator);
                            return err;
                        };
                    },
                }
            }
            continue;
        };

        // Skip parse-time-only words
        if (word.parse_time_only) continue;

        // Record native words for the resolver, but don't BFS into them, since
        // they have no instructions to discover more words
        const instrs = switch (word.action) {
            .compound => |c| c,
            .native, .host_callback => {
                try result.native_names.append(temp_allocator, name);
                try result.native_defs.append(temp_allocator, word);
                continue;
            },
        };

        try result.names.append(temp_allocator, name);
        try result.defs.append(temp_allocator, word);

        // Discover callees
        collectCallWords(ctx, instrs, name, &worklist, &seen, &result.quotation_bodies, &quotation_seen, &result.pending_call_targets, &quotation_path, diagnostics, runtime_image, temp_allocator, result_allocator) catch |err| {
            freePendingCallTargetPaths(&result.pending_call_targets, result_allocator);
            result.names.deinit(temp_allocator);
            result.defs.deinit(temp_allocator);
            result.native_names.deinit(temp_allocator);
            result.native_defs.deinit(temp_allocator);
            result.quotation_bodies.deinit(temp_allocator);
            result.pending_call_targets.deinit(temp_allocator);
            return err;
        };
    }

    return result;
}

/// Free quotation_path slices owned by entries in `pending_call_targets`.
/// Idempotent: clears each entry's slice reference after freeing so that
/// the success-path explicit call and the error-path errdefer can both
/// run safely without risking double-free.
fn freePendingCallTargetPaths(pending: *std.ArrayListUnmanaged(PendingCallTarget), allocator: Allocator) void {
    for (pending.items) |*entry| {
        if (entry.quotation_path.len > 0) {
            allocator.free(entry.quotation_path);
            entry.quotation_path = &.{};
        }
    }
}

/// Resolve a callee name into its `PendingResolution` form without
/// performing any side-effecting work. Used at every call site to record
/// the call_targets entry; the result is finalized to a `ResolvedCallee`
/// after buildAotDescs assigns word ids.
fn classifyCallee(ctx: *const Context, name: []const u8) PendingResolution {
    if (ctx.lookupWord(name)) |word| {
        if (word.parse_time_only) {
            return .{ .unresolved = .skipped_parse_time_only };
        }
        return switch (word.action) {
            .native, .host_callback => .{ .native_name = name },
            .compound => .{ .compound_name = name },
        };
    }
    if (resolveQualifiedModuleWord(ctx, name)) |mod_word| {
        return switch (mod_word.action) {
            .native, .host_callback => .{ .native_name = name },
            .compound => .{ .compound_name = name },
        };
    }
    return .{ .unresolved = .not_in_dictionary };
}

/// Extract call_word names from instructions and add unseen ones to the worklist.
/// Also collects reachable quotation bodies, dwduped by pointer identity.
/// Per-call-site records are appended to `pending_call_targets` for later
/// remap to caller word ids.
fn collectCallWords(
    ctx: *const Context,
    instrs: []const Instruction,
    caller_name: []const u8,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    quotation_bodies: *std.ArrayListUnmanaged([]const Instruction),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    pending_call_targets: *std.ArrayListUnmanaged(PendingCallTarget),
    quotation_path: *std.ArrayListUnmanaged(u32),
    diagnostics: *FreezeDiagnostics,
    runtime_image: bool,
    allocator: Allocator,
    path_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!void {
    for (instrs, 0..) |instr, idx| {
        switch (instr.op) {
            .call_word => |name| {
                if (bannedDynamicFeatureForCall(ctx, name, runtime_image)) |_| {
                    diagnostics.fatal_dynamic_feature = .{
                        .caller_name = caller_name,
                        .feature_name = name,
                    };
                    return error.DisallowedDynamicFeature;
                }
                if (!runtime_image and isInterpreterDependentNative(ctx, name)) {
                    diagnostics.fatal_native_interpreter_dependency = .{
                        .caller_name = caller_name,
                        .feature_name = name,
                    };
                    return error.DisallowedNativeInterpreterDependency;
                }
                const gop = try seen.getOrPut(allocator, name);
                if (!gop.found_existing) {
                    try worklist.append(allocator, name);
                }
                const path_copy: []const u32 = if (quotation_path.items.len == 0)
                    &.{}
                else
                    try path_allocator.dupe(u32, quotation_path.items);
                try pending_call_targets.append(allocator, .{
                    .caller_name = caller_name,
                    .instruction_index = @intCast(idx),
                    .quotation_path = path_copy,
                    .pending = classifyCallee(ctx, name),
                });
            },
            .push_literal => |val| {
                // Recurse into nested quotations
                switch (val) {
                    .quotation => |q| {
                        const ptr_key = @intFromPtr(q.instructions.ptr);
                        const qgop = try quotation_seen.getOrPut(allocator, ptr_key);
                        if (!qgop.found_existing) {
                            try quotation_bodies.append(allocator, q.instructions);
                        }
                        try quotation_path.append(allocator, @intCast(idx));
                        const recurse_err = collectCallWords(ctx, q.instructions, caller_name, worklist, seen, quotation_bodies, quotation_seen, pending_call_targets, quotation_path, diagnostics, runtime_image, allocator, path_allocator);
                        _ = quotation_path.pop();
                        try recurse_err;
                    },
                    else => {},
                }
            },
        }
    }
}

/// Returns true if `name` resolves to a native (or host-callback) word
/// definition that carries the well-known `interpreter-dependent` marker.
/// Compound words and unresolved names return false: this audit only
/// concerns native code paths reachable from the compiled AOT graph.
fn isInterpreterDependentNative(ctx: *const Context, name: []const u8) bool {
    if (ctx.lookupWord(name)) |word| {
        switch (word.action) {
            .native, .host_callback => return hasInterpreterDependentMarker(word),
            .compound => return false,
        }
    }
    if (resolveQualifiedModuleWord(ctx, name)) |mod_word| {
        switch (mod_word.action) {
            .native, .host_callback => {
                const word = wordDefFromModuleWord(name, mod_word);
                return hasInterpreterDependentMarker(word);
            },
            .compound => return false,
        }
    }
    return false;
}

/// Resolve a module-qualified name (e.g., "native.struct-field-get") to
/// its ModuleWord without executing the module word. Splits on the last
/// dot, looks up the module in the dictionary, and extracts the word from
/// the module's word map.
fn resolveQualifiedModuleWord(ctx: *const Context, name: []const u8) ?value_mod.ModuleWord {
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const module_path = name[0..dot_index];
    const word_name = name[dot_index + 1 ..];
    if (module_path.len == 0 or word_name.len == 0) return null;

    const module_word_def = ctx.lookupWord(module_path) orelse return null;
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

/// Convert a ModuleWord to a WordDefinition, using the given qualified
/// name (e.g., "native.struct-field-get") as the word name.
fn wordDefFromModuleWord(name: []const u8, mod_word: value_mod.ModuleWord) WordDefinition {
    return .{
        .name = name,
        .stack_effect = mod_word.stack_effect,
        .action = switch (mod_word.action) {
            .native => |f| .{ .native = f },
            .host_callback => |h| .{ .host_callback = h },
            .compound => |c| .{ .compound = c },
        },
        .capability = mod_word.capability,
    };
}

/// Try to discover a callee word that isn't yet in the discovered set.
///
/// It tries in order:
///
/// - module-qualified resolution, e.g., `native.struct-field-get`; then
/// - direct dictionary lookup for unqualified names.
///
/// Only adds native words with declared stack effects, plus known
/// polymorphic struct native words (which have no fixed stack_effect).
fn discoverCalleeWord(ctx: *const Context, call_name: []const u8, discovered: *DiscoveredWords, allocator: Allocator) Allocator.Error!void {
    // Try module-qualified resolution first
    if (resolveQualifiedModuleWord(ctx, call_name)) |mod_word| {
        switch (mod_word.action) {
            .native, .host_callback => {
                try discovered.native_names.append(allocator, call_name);
                try discovered.native_defs.append(allocator, wordDefFromModuleWord(call_name, mod_word));
            },
            .compound => {},
        }
        return;
    }

    // Fall back to direct dictionary lookup for unqualified names.
    // This catches native words called by prelude words that were added
    // via compile_all_prelude but never went through the BFS.
    const word = ctx.lookupWord(call_name) orelse return;
    switch (word.action) {
        .native, .host_callback => {
            try discovered.native_names.append(allocator, call_name);
            try discovered.native_defs.append(allocator, word);
        },
        .compound => {
            // Compound words without a stack effect cannot be assigned
            // input/output counts; let `buildAotDescs` route them to
            // the missing-stack-effects error path.
            if (word.stack_effect == null) return;
            try discovered.names.append(allocator, call_name);
            try discovered.defs.append(allocator, word);
        },
    }
}

/// Return the first `dynamic-*` marker on `def` that the current AOT
/// artifact class disallows, or null. Detection is by marker identity, so
/// it survives natives being renamed in the registry: the policy follows
/// the function, not its name.
///
/// The current two-class transition keeps `runtime_image` as a bool. The
/// matrix:
///
///   `dynamic-compile`                  banned in every AOT class.
///   `dynamic-eval`                     banned when not runtime-image.
///   `dynamic-load`                     banned when not runtime-image.
///   `dynamic-quotation-construction`   banned when not runtime-image.
///
/// The interpreter class is not reachable from freeze.
fn bannedDynamicMarker(def: WordDefinition, runtime_image: bool) ?*const value_mod.Marker {
    for (def.markers) |mk| {
        if (markers_mod.isDynamicCompileMarker(mk)) return mk;
        if (runtime_image) continue;
        if (markers_mod.isDynamicEvalMarker(mk)) return mk;
        if (markers_mod.isDynamicLoadMarker(mk)) return mk;
        if (markers_mod.isDynamicQuotationConstructionMarker(mk)) return mk;
    }
    return null;
}

/// Resolve `name` against the current dictionary (direct lookup, then
/// qualified-module lookup) and return any banned `dynamic-*` marker on
/// the resolved callee. Returns null when the name is unresolved or the
/// resolved word carries no banned markers. Mirrors the shape of
/// `isInterpreterDependentNative`.
fn bannedDynamicFeatureForCall(ctx: *const Context, name: []const u8, runtime_image: bool) ?*const value_mod.Marker {
    if (ctx.lookupWord(name)) |def| {
        return bannedDynamicMarker(def, runtime_image);
    }
    if (resolveQualifiedModuleWord(ctx, name)) |mod_word| {
        return bannedDynamicMarker(wordDefFromModuleWord(name, mod_word), runtime_image);
    }
    return null;
}

fn hasNeverReturnsMarker(def: WordDefinition) bool {
    for (def.markers) |mk| {
        if (markers_mod.isNeverReturnsMarker(mk)) return true;
    }
    return false;
}

fn hasInterpreterDependentMarker(def: WordDefinition) bool {
    for (def.markers) |mk| {
        if (markers_mod.isInterpreterDependentMarker(mk)) return true;
    }
    return false;
}

fn hasGenericMarker(def: WordDefinition) bool {
    for (def.markers) |mk| {
        if (markers_mod.isGenericMarker(mk)) return true;
    }
    return false;
}

/// Generic words generated from struct/virtual/enum definitions carry an
/// empty compound body; the actual implementation lives in dispatch table
/// entries keyed by runtime type. They cannot be compiled directly because
/// the empty body cannot satisfy a non-trivial declared stack effect, and
/// even when input_count == output_count the compiled body would silently
/// no-op rather than dispatching. They must always fall through to the
/// dispatch callback -- `jitInterpretedCall` for the compound-uncompiled
/// case and `jitNativeWordCall` for native generics -- which then routes
/// through `tryDispatchGenericWithPic`.
fn isDispatchOnlyGeneric(def: WordDefinition) bool {
    return def.action == .compound and def.action.compound.len == 0 and hasGenericMarker(def);
}

/// Assign word IDs and build the AotWordDesc array. When `ctx` is
/// provided, PIC snapshots are captured from the interpreter's cache
/// and stored on each compound word descriptor.
fn buildAotDescs(
    entry_instrs: []const Instruction,
    discovered: *const DiscoveredWords,
    pending_call_targets: []const PendingCallTarget,
    prelude_words: *const std.StringHashMapUnmanaged(void),
    ctx: ?*Context,
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

        // Generic words with empty compound bodies (struct/virtual/enum
        // setters, getters, predicates) are runtime-dispatched on type;
        // their compiled body would either fail to satisfy the declared
        // effect or silently no-op. Route them through interpreter
        // dispatch by marking them like natives -- skipped during
        // compilation, looked up by name at runtime.
        if (isDispatchOnlyGeneric(def)) {
            try words.append(allocator, .{
                .name = name,
                .instructions = &.{},
                .input_count = @intCast(effect.concreteInputCount()),
                .output_count = @intCast(effect.concreteOutputCount()),
                .word_id = id,
                .is_prelude = true,
                .is_native = true,
                .stack_effect = effect,
                .never_returns = hasNeverReturnsMarker(def),
            });
            continue;
        }

        const pic_snapshot: ?*pic_mod.PicTable = blk: {
            const ictx = ctx orelse break :blk null;
            const key = @intFromPtr(def.action.compound.ptr);
            const pt = ictx.pic_cache.get(key) orelse break :blk null;
            const cloned = allocator.create(pic_mod.PicTable) catch break :blk null;
            cloned.* = pt.clone(allocator) catch {
                allocator.destroy(cloned);
                break :blk null;
            };
            break :blk cloned;
        };
        try words.append(allocator, .{
            .name = name,
            .instructions = def.action.compound,
            .input_count = @intCast(effect.concreteInputCount()),
            .output_count = @intCast(effect.concreteOutputCount()),
            .word_id = id,
            .is_prelude = prelude_words.contains(name),
            .stack_effect = effect,
            .never_returns = hasNeverReturnsMarker(def),
            .pic_snapshot = pic_snapshot,
        });
    }

    // Assign IDs to discovered native words. Polymorphic natives (no
    // declared stack effect) are registered with zero input/output counts
    // so pre-scan accepts every reachable native referenced by frozen
    // compound bodies. The codegen either special-cases the native (e.g.,
    // `native.make-struct-instance` via `emitStructNativeCall`) or routes
    // it through `jitNativeWordCall` by word_id; runtime-virtual-pointer
    // natives still bail out in AOT mode via `isRuntimeVirtualPtrNative`.
    for (discovered.native_names.items, discovered.native_defs.items) |name, def| {
        const effect = def.stack_effect orelse {
            const id = next_id;
            next_id += 1;
            try words.append(allocator, .{
                .name = name,
                .instructions = &.{},
                .input_count = 0,
                .output_count = 0,
                .word_id = id,
                .is_prelude = true,
                .is_native = true,
                .never_returns = hasNeverReturnsMarker(def),
            });
            continue;
        };
        const id = next_id;
        next_id += 1;
        try words.append(allocator, .{
            .name = name,
            .instructions = &.{},
            .input_count = @intCast(effect.concreteInputCount()),
            .output_count = @intCast(effect.concreteOutputCount()),
            .word_id = id,
            .is_prelude = true,
            .is_native = true,
            .native_fn_ptr = blk: {
                if (def.action != .native) break :blk null;
                for (def.markers) |mk| {
                    if (markers_mod.isGenericMarker(mk)) break :blk @intFromPtr(def.action.native);
                }
                break :blk null;
            },
            .stack_effect = effect,
            .never_returns = hasNeverReturnsMarker(def),
        });
    }

    const max_word_id = if (next_id > 0) next_id - 1 else 0;

    // Build a resolver
    var word_map: std.StringHashMapUnmanaged(AotWordDesc) = .{};
    defer word_map.deinit(allocator);
    for (words.items) |w| {
        try word_map.put(allocator, w.name, w);
    }

    // Remap pending call targets: substitute caller word ids and resolve
    // callee word ids via word_map. Path slices are duped into the result
    // allocator so the FreezeResult owns them; the BFS-time originals are
    // freed by the caller after this function returns.
    var call_targets_list: std.ArrayListUnmanaged(CallTargetEntry) = .{};
    errdefer {
        for (call_targets_list.items) |entry| {
            if (entry.quotation_path.len > 0) allocator.free(entry.quotation_path);
        }
        call_targets_list.deinit(allocator);
    }
    for (pending_call_targets) |p| {
        const caller_entry = word_map.get(p.caller_name) orelse continue;
        const resolved: ResolvedCallee = blk: switch (p.pending) {
            .unresolved => |r| break :blk .{ .unresolved = r },
            .native_name, .compound_name => {
                const callee_name = switch (p.pending) {
                    .native_name, .compound_name => |n| n,
                    .unresolved => unreachable,
                };
                if (word_map.get(callee_name)) |w| {
                    break :blk if (w.is_native)
                        ResolvedCallee{ .native = w.word_id }
                    else
                        ResolvedCallee{ .compound = w.word_id };
                }
                break :blk .{ .unresolved = .skipped_no_stack_effect };
            },
        };
        const path_dup: []const u32 = if (p.quotation_path.len == 0)
            &.{}
        else
            try allocator.dupe(u32, p.quotation_path);
        try call_targets_list.append(allocator, .{
            .caller_word_id = caller_entry.word_id,
            .instruction_index = p.instruction_index,
            .quotation_path = path_dup,
            .resolved = resolved,
        });
    }
    const call_targets_slice = try call_targets_list.toOwnedSlice(allocator);
    errdefer {
        for (call_targets_slice) |entry| {
            if (entry.quotation_path.len > 0) allocator.free(entry.quotation_path);
        }
        allocator.free(call_targets_slice);
    }

    const FreezeResolverData = struct {
        map: *const std.StringHashMapUnmanaged(AotWordDesc),

        fn resolve(name_ptr: []const u8, user_data: *anyopaque) ?ir_codegen.ResolvedWord {
            const self: *const @This() = @ptrCast(@alignCast(user_data));
            const entry = self.map.getPtr(name_ptr) orelse return null;
            var result = ir_codegen.ResolvedWord{
                .word_id = entry.word_id,
                .input_count = entry.input_count,
                .output_count = entry.output_count,
                .never_returns = entry.never_returns,
                .is_native = entry.is_native,
                .native_fn_ptr = entry.native_fn_ptr,
            };
            if (entry.stack_effect) |*eff| {
                if (stack_effect_mod.hasAnyRowVariable(eff.*)) {
                    result.callee_effect = eff;
                }
            }
            return result;
        }
    };

    var resolver_data = FreezeResolverData{ .map = &word_map };
    const resolver = ir_codegen.WordResolver{
        .resolve = &FreezeResolverData.resolve,
        .user_data = @ptrCast(&resolver_data),
        .dispatch_table_ptr = undefined,
    };

    // Sequential ID for quot descriptors
    var quotations = std.ArrayListUnmanaged(AotQuotationDesc){};
    var next_q_id: u32 = 0;
    for (discovered.quotation_bodies.items) |body| {
        const id = next_q_id;
        next_q_id += 1;
        const c_name = try std.fmt.allocPrint(allocator, "onez_q_{d}", .{id});
        try quotations.append(allocator, .{
            .quotation_id = id,
            .instructions = body,
            .c_name = c_name,
            .inferred_effect = ir_codegen.inferQuotationEffect(body, resolver) catch null,
        });
    }
    const max_quotation_id = if (next_q_id > 0) next_q_id - 1 else 0;

    return FreezeResult{
        .words = try words.toOwnedSlice(allocator),
        .quotations = try quotations.toOwnedSlice(allocator),
        .entry_word_id = entry_word_id,
        .max_word_id = max_word_id,
        .max_quotation_id = max_quotation_id,
        .skipped_words = try skipped.toOwnedSlice(allocator),
        .entry_instrs = try allocator.dupe(Instruction, entry_instrs),
        .call_targets = call_targets_slice,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "collectCallWords extracts call_word names from instructions" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    const instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .call_word = "double" }, .line = 1 },
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    try testing.expectEqual(@as(usize, 2), worklist.items.len);
    try testing.expect(seen.contains("double"));
    try testing.expect(seen.contains("drop"));
    try testing.expect(diagnostics.fatal_dynamic_feature == null);
}

test "buildAotDescs assigns sequential IDs and skips effectless words" {
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    const effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
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

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &.{}, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    // Entry word (id 0) + foo (id 1) = 2 words; bar skipped
    try testing.expectEqual(@as(usize, 2), result.words.len);
    try testing.expectEqual(@as(u32, 0), result.entry_word_id);
    try testing.expectEqual(@as(u32, 1), result.max_word_id);
    try testing.expectEqual(@as(usize, 0), result.quotations.len);
    try testing.expectEqual(@as(usize, 1), result.skipped_words.len);
    try testing.expect(std.mem.eql(u8, result.skipped_words[0], "bar"));
}

test "freezeModuleGraphOpts cleanup releases pic snapshots when stack effects are missing" {
    const allocator = testing.allocator;

    // A real Context is needed so pic_cache lookups during buildAotDescs
    // succeed. Context.deinit later frees the cached PicTable we install.
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Compound body for the cached word. The pointer identity of this
    // slice is what the cache keys on, so it must outlive both
    // buildAotDescs and the failure-path cleanup. Allocated on testing
    // allocator and freed at the end of the test.
    const compound_instrs = try allocator.alloc(Instruction, 1);
    defer allocator.free(compound_instrs);
    compound_instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 0 };

    // Populate ctx.pic_cache so buildAotDescs clones a snapshot for the
    // compound word with a stack effect. ctx.deinit handles the table.
    const pt = try allocator.create(pic_mod.PicTable);
    pt.* = try pic_mod.PicTable.init(allocator, compound_instrs.len);
    try ctx.pic_cache.put(allocator, @intFromPtr(compound_instrs.ptr), pt);

    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    const effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };
    defer discovered.names.deinit(allocator);
    defer discovered.defs.deinit(allocator);

    // Word with effect AND a pic_cache entry: snapshot will be cloned.
    try discovered.names.append(allocator, "foo");
    try discovered.defs.append(allocator, .{
        .name = "foo",
        .action = .{ .compound = compound_instrs },
        .stack_effect = effect,
    });

    // Word without effect: triggers the MissingStackEffects path in the
    // production caller.
    try discovered.names.append(allocator, "bar");
    try discovered.defs.append(allocator, .{
        .name = "bar",
        .action = .{ .compound = &.{} },
    });

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &.{}, &prelude_words, &ctx, allocator);

    // Sanity: foo got a pic snapshot, bar was skipped.
    try testing.expect(result.words[1].pic_snapshot != null);
    try testing.expectEqual(@as(usize, 1), result.skipped_words.len);

    // Mirror the freezeModuleGraphOpts failure-path cleanup. testing.allocator
    // panics on leaks, so a regression in pic_snapshot freeing fails this test.
    const skipped = result.skipped_words;
    result.skipped_words = &.{};
    result.deinit(allocator);
    allocator.free(skipped);
}

test "buildAotDescs includes native words with is_prelude and empty instructions" {
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    const effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };
    const native_effect = StackEffect{
        .inputs = &.{.{ .name = "val" }},
        .outputs = &.{.{ .name = "type" }},
    };

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };
    defer discovered.names.deinit(allocator);
    defer discovered.defs.deinit(allocator);
    defer discovered.native_names.deinit(allocator);
    defer discovered.native_defs.deinit(allocator);

    // Compound word
    try discovered.names.append(allocator, "foo");
    try discovered.defs.append(allocator, .{
        .name = "foo",
        .action = .{ .compound = &.{} },
        .stack_effect = effect,
    });

    // Native word
    try discovered.native_names.append(allocator, "type-of");
    try discovered.native_defs.append(allocator, .{
        .name = "type-of",
        .action = .{ .native = undefined },
        .stack_effect = native_effect,
    });

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &.{}, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    // Entry (id 0) + foo (id 1) + type-of (id 2) = 3 words
    try testing.expectEqual(@as(usize, 3), result.words.len);
    try testing.expectEqual(@as(u32, 2), result.max_word_id);

    // Native word is last, with is_prelude and empty instructions
    const native_word = result.words[2];
    try testing.expectEqualStrings("type-of", native_word.name);
    try testing.expectEqual(@as(u32, 2), native_word.word_id);
    try testing.expect(native_word.is_prelude);
    try testing.expectEqual(@as(usize, 0), native_word.instructions.len);
    try testing.expectEqual(@as(u8, 1), native_word.input_count);
    try testing.expectEqual(@as(u8, 1), native_word.output_count);
}

test "collectCallWords rejects '>quotation' in interpreter-free mode" {
    try expectInterpreterFreeRejection(">quotation", "make-word", &markers_mod.dynamic_quotation_construction_marker);
}

test "collectCallWords rejects disallowed dynamic features with caller" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "eval-string" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try testing.expectError(error.DisallowedDynamicFeature, collectCallWords(
        &ctx,
        instrs,
        "__entry__",
        &worklist,
        &seen,
        &quotation_bodies,
        &quotation_seen,
        &pending_call_targets,
        &quotation_path,
        &diagnostics,
        false,
        allocator,
        allocator,
    ));
    try testing.expect(diagnostics.fatal_dynamic_feature != null);
    try testing.expectEqualStrings("__entry__", diagnostics.fatal_dynamic_feature.?.caller_name);
    try testing.expectEqualStrings("eval-string", diagnostics.fatal_dynamic_feature.?.feature_name);
}

test "collectCallWords in runtime-image mode permits eval-string, load, and >quotation" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "eval-string" }, .line = 1 },
        .{ .op = .{ .call_word = "load" }, .line = 1 },
        .{ .op = .{ .call_word = "reload" }, .line = 1 },
        .{ .op = .{ .call_word = "load-file" }, .line = 1 },
        .{ .op = .{ .call_word = ">quotation" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, true, allocator, allocator);

    try testing.expectEqual(@as(usize, 5), worklist.items.len);
    try testing.expect(diagnostics.fatal_dynamic_feature == null);
}

test "collectCallWords in runtime-image mode still rejects compile!" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "compile!" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try testing.expectError(error.DisallowedDynamicFeature, collectCallWords(
        &ctx,
        instrs,
        "do-compile",
        &worklist,
        &seen,
        &quotation_bodies,
        &quotation_seen,
        &pending_call_targets,
        &quotation_path,
        &diagnostics,
        true,
        allocator,
        allocator,
    ));
    try testing.expect(diagnostics.fatal_dynamic_feature != null);
    try testing.expectEqualStrings("do-compile", diagnostics.fatal_dynamic_feature.?.caller_name);
    try testing.expectEqualStrings("compile!", diagnostics.fatal_dynamic_feature.?.feature_name);
}

test "collectCallWords rejects 'load' in interpreter-free mode" {
    try expectInterpreterFreeRejection("load", "needs-load", &markers_mod.dynamic_load_marker);
}

test "collectCallWords rejects 'reload' in interpreter-free mode" {
    try expectInterpreterFreeRejection("reload", "needs-reload", &markers_mod.dynamic_load_marker);
}

test "collectCallWords rejects 'load-file' in interpreter-free mode" {
    try expectInterpreterFreeRejection("load-file", "needs-load-file", &markers_mod.dynamic_load_marker);
}

test "collectCallWords rejects 'compile!' in interpreter-free mode" {
    try expectInterpreterFreeRejection("compile!", "needs-compile-bang", &markers_mod.dynamic_compile_marker);
}

fn expectInterpreterFreeRejection(feature: []const u8, caller: []const u8, marker: *const value_mod.Marker) !void {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Pin the feature name to a native carrying the banned marker. This
    // keeps the test independent of whether the corresponding word is
    // available in a prelude-less Context: `load` and `reload` are prelude
    // compounds, while `load-file` and `compile!` are natives populated by
    // Context.init. The overwrite is harmless in both cases since the
    // marker check is identity-based.
    const marker_slice = try allocator.dupe(*value_mod.Marker, &.{@constCast(marker)});
    defer allocator.free(marker_slice);
    try ctx.dictionary.put(feature, .{
        .name = feature,
        .action = .{ .native = auditTestNoopNative },
        .markers = marker_slice,
    });
    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = feature }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try testing.expectError(error.DisallowedDynamicFeature, collectCallWords(
        &ctx,
        instrs,
        caller,
        &worklist,
        &seen,
        &quotation_bodies,
        &quotation_seen,
        &pending_call_targets,
        &quotation_path,
        &diagnostics,
        false,
        allocator,
        allocator,
    ));
    try testing.expect(diagnostics.fatal_dynamic_feature != null);
    try testing.expectEqualStrings(caller, diagnostics.fatal_dynamic_feature.?.caller_name);
    try testing.expectEqualStrings(feature, diagnostics.fatal_dynamic_feature.?.feature_name);
}

test "collectCallWords discovers quotation bodies" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    const inner_body = &[_]Instruction{
        .{ .op = .{ .call_word = "dup" }, .line = 2 },
    };
    const instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_body } } }, .line = 1 },
        .{ .op = .{ .call_word = "call" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    try testing.expectEqual(@as(usize, 1), quotation_bodies.items.len);
    try testing.expectEqual(inner_body.ptr, quotation_bodies.items[0].ptr);
}

test "collectCallWords discovers nested quotations" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    const innermost = &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 3 },
    };
    const middle = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = innermost } } }, .line = 2 },
        .{ .op = .{ .call_word = "call" }, .line = 2 },
    };
    const instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = middle } } }, .line = 1 },
        .{ .op = .{ .call_word = "call" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    // Both middle and innermost quotations discovered
    try testing.expectEqual(@as(usize, 2), quotation_bodies.items.len);
    try testing.expectEqual(middle.ptr, quotation_bodies.items[0].ptr);
    try testing.expectEqual(innermost.ptr, quotation_bodies.items[1].ptr);
}

test "collectCallWords deduplicates quotations by pointer" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    const shared_body = &[_]Instruction{
        .{ .op = .{ .call_word = "dup" }, .line = 2 },
    };
    // Same quotation body referenced twice
    const instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = shared_body } } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = shared_body } } }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    // Only recorded once despite appearing twice
    try testing.expectEqual(@as(usize, 1), quotation_bodies.items.len);
}

test "buildAotDescs assigns sequential quotation IDs" {
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    const effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };
    const q_body_1 = &[_]Instruction{
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
    };
    const q_body_2 = &[_]Instruction{
        .{ .op = .{ .call_word = "swap" }, .line = 1 },
    };

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };
    defer discovered.names.deinit(allocator);
    defer discovered.defs.deinit(allocator);
    defer discovered.quotation_bodies.deinit(allocator);

    try discovered.names.append(allocator, "foo");
    try discovered.defs.append(allocator, .{
        .name = "foo",
        .action = .{ .compound = &.{} },
        .stack_effect = effect,
    });

    try discovered.quotation_bodies.append(allocator, q_body_1);
    try discovered.quotation_bodies.append(allocator, q_body_2);

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &.{}, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.quotations.len);
    try testing.expectEqual(@as(u32, 0), result.quotations[0].quotation_id);
    try testing.expectEqual(@as(u32, 1), result.quotations[1].quotation_id);
    try testing.expectEqual(@as(u32, 1), result.max_quotation_id);
    try testing.expectEqualStrings("onez_q_0", result.quotations[0].c_name);
    try testing.expectEqualStrings("onez_q_1", result.quotations[1].c_name);
    try testing.expectEqual(q_body_1.ptr, result.quotations[0].instructions.ptr);
    try testing.expectEqual(q_body_2.ptr, result.quotations[1].instructions.ptr);

    // dup: ( a -- a a ) = 1 input, 2 outputs
    const eff_1 = result.quotations[0].inferred_effect.?;
    try testing.expectEqual(@as(u8, 1), eff_1.input_count);
    try testing.expectEqual(@as(u8, 2), eff_1.output_count);

    // swap: ( a b -- b a ) = 2 inputs, 2 outputs
    const eff_2 = result.quotations[1].inferred_effect.?;
    try testing.expectEqual(@as(u8, 2), eff_2.input_count);
    try testing.expectEqual(@as(u8, 2), eff_2.output_count);
}

test "buildAotDescs infers effect for quotation calling discovered word" {
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    // A compound word "double" with effect ( n -- n )
    const double_effect = StackEffect{
        .inputs = &.{.{ .name = "n" }},
        .outputs = &.{.{ .name = "n" }},
    };
    const double_body = &[_]Instruction{
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };

    // A quotation that calls "double"
    const q_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .call_word = "double" }, .line = 1 },
    };

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };
    defer discovered.names.deinit(allocator);
    defer discovered.defs.deinit(allocator);
    defer discovered.quotation_bodies.deinit(allocator);

    try discovered.names.append(allocator, "double");
    try discovered.defs.append(allocator, .{
        .name = "double",
        .action = .{ .compound = double_body },
        .stack_effect = double_effect,
    });

    try discovered.quotation_bodies.append(allocator, q_body);

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &.{}, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    // Quotation pushes 1, then calls double (1 in, 1 out) => net (0, 1)
    const eff = result.quotations[0].inferred_effect.?;
    try testing.expectEqual(@as(u8, 0), eff.input_count);
    try testing.expectEqual(@as(u8, 1), eff.output_count);
}

test "buildAotDescs returns null effect for unresolvable quotation" {
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    // A quotation calling a word not in the discovered set
    const q_body = &[_]Instruction{
        .{ .op = .{ .call_word = "unknown-word" }, .line = 1 },
    };

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };
    defer discovered.quotation_bodies.deinit(allocator);

    try discovered.quotation_bodies.append(allocator, q_body);

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &.{}, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.quotations.len);
    try testing.expect(result.quotations[0].inferred_effect == null);
}

test "buildAotDescs infers effect for push-only quotation" {
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    // A quotation that just pushes two values: ( -- a b )
    const q_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
    };

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };
    defer discovered.quotation_bodies.deinit(allocator);

    try discovered.quotation_bodies.append(allocator, q_body);

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &.{}, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    const eff = result.quotations[0].inferred_effect.?;
    try testing.expectEqual(@as(u8, 0), eff.input_count);
    try testing.expectEqual(@as(u8, 2), eff.output_count);
}

// ── Audit-bar tests for the interpreter-dependent marker ──────────────

/// No-op native used to register synthetic marked words in audit-bar tests.
fn auditTestNoopNative(_: *Context) anyerror!void {}

test "collectCallWords rejects marked native in interpreter-free mode" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Register a synthetic native carrying the interpreter-dependent
    // marker. The name is intentionally not in `isDisallowedDynamicFeature`
    // so the marker check is what fires.
    try ctx.dictionary.put("audit-dep", .{
        .name = "audit-dep",
        .action = .{ .native = auditTestNoopNative },
        .markers = &.{@constCast(&markers_mod.interpreter_dependent_marker)},
    });

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "audit-dep" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try testing.expectError(error.DisallowedNativeInterpreterDependency, collectCallWords(
        &ctx,
        instrs,
        "caller",
        &worklist,
        &seen,
        &quotation_bodies,
        &quotation_seen,
        &pending_call_targets,
        &quotation_path,
        &diagnostics,
        false,
        allocator,
        allocator,
    ));
    try testing.expect(diagnostics.fatal_native_interpreter_dependency != null);
    try testing.expectEqualStrings("caller", diagnostics.fatal_native_interpreter_dependency.?.caller_name);
    try testing.expectEqualStrings("audit-dep", diagnostics.fatal_native_interpreter_dependency.?.feature_name);
}

test "collectCallWords permits marked native in runtime-image mode" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.dictionary.put("audit-dep", .{
        .name = "audit-dep",
        .action = .{ .native = auditTestNoopNative },
        .markers = &.{@constCast(&markers_mod.interpreter_dependent_marker)},
    });

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "audit-dep" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, true, allocator, allocator);

    try testing.expect(diagnostics.fatal_native_interpreter_dependency == null);
    try testing.expect(diagnostics.fatal_dynamic_feature == null);
    try testing.expectEqual(@as(usize, 1), worklist.items.len);
}

test "collectCallWords ignores marker on compound words" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Compound bodies cannot host interpreter machinery directly; the
    // marker only governs native code paths.
    try ctx.dictionary.put("audit-dep-compound", .{
        .name = "audit-dep-compound",
        .action = .{ .compound = &.{} },
        .markers = &.{@constCast(&markers_mod.interpreter_dependent_marker)},
    });

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "audit-dep-compound" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    try testing.expect(diagnostics.fatal_native_interpreter_dependency == null);
    try testing.expectEqual(@as(usize, 1), worklist.items.len);
}

test "dynamic-feature check fires before interpreter-dependent check on a doubly-marked native" {
    // `eval-string` carries both interpreter-dependent and dynamic-eval
    // markers. `collectCallWords` checks dynamic-feature markers first so
    // the diagnostic surfaces as DisallowedDynamicFeature, not the
    // narrower DisallowedNativeInterpreterDependency. This test locks in
    // that ordering so future refactors keep the more actionable error.
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "eval-string" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try testing.expectError(error.DisallowedDynamicFeature, collectCallWords(
        &ctx,
        instrs,
        "caller",
        &worklist,
        &seen,
        &quotation_bodies,
        &quotation_seen,
        &pending_call_targets,
        &quotation_path,
        &diagnostics,
        false,
        allocator,
        allocator,
    ));
    try testing.expect(diagnostics.fatal_dynamic_feature != null);
    try testing.expect(diagnostics.fatal_native_interpreter_dependency == null);
}

test "collectCallWords does not flag a compound that shadows eval-string and lacks dynamic-eval" {
    // Identity-based detection must respect shadowing: when the resolver
    // sees the user's `eval-string` first and that word carries no banned
    // marker, the call is permitted regardless of the homonymous native
    // sitting in the global dictionary.
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const shadow_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1 },
    };
    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();
    const top_idx = ctx.local_frames.items.len - 1;
    try ctx.local_frames.items[top_idx].put(ctx.allocator, "eval-string", .{
        .name = "eval-string",
        .action = .{ .compound = shadow_body },
    });

    const resolved = ctx.lookupWord("eval-string").?;
    try testing.expectEqual(@as(usize, 0), resolved.markers.len);

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "eval-string" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "user-entry", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    try testing.expect(diagnostics.fatal_dynamic_feature == null);
    try testing.expect(diagnostics.fatal_native_interpreter_dependency == null);
    try testing.expectEqual(@as(usize, 1), worklist.items.len);
}

test "collectCallWords flags a user-defined native carrying dynamic-eval" {
    // A user-registered native whose name is not on any historical
    // deny list still trips the dynamic-feature check because policy is
    // attached to the marker, not the name.
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.dictionary.put("user-evaller", .{
        .name = "user-evaller",
        .action = .{ .native = auditTestNoopNative },
        .markers = &.{@constCast(&markers_mod.dynamic_eval_marker)},
    });

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "user-evaller" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try testing.expectError(error.DisallowedDynamicFeature, collectCallWords(
        &ctx,
        instrs,
        "caller",
        &worklist,
        &seen,
        &quotation_bodies,
        &quotation_seen,
        &pending_call_targets,
        &quotation_path,
        &diagnostics,
        false,
        allocator,
        allocator,
    ));
    try testing.expect(diagnostics.fatal_dynamic_feature != null);
    try testing.expectEqualStrings("caller", diagnostics.fatal_dynamic_feature.?.caller_name);
    try testing.expectEqualStrings("user-evaller", diagnostics.fatal_dynamic_feature.?.feature_name);
}

test "collectCallWords does not flag an eval-string whose marker has been stripped" {
    // Stripping the markers from the eval-string slot models a registry
    // rename where the deny list and the implementation drift apart. The
    // old string-compare check would still fire on the unchanged name;
    // identity-based detection correctly stays silent because the marker
    // moved (or was deleted) with the function it certifies. The
    // complementary failure -- that calling under the new, marker-bearing
    // name still trips the check -- is covered by the user-defined
    // dynamic-eval test above.
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.dictionary.put("eval-string", .{
        .name = "eval-string",
        .action = .{ .native = auditTestNoopNative },
        .markers = &.{},
    });

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "eval-string" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    try testing.expect(diagnostics.fatal_dynamic_feature == null);
    try testing.expect(diagnostics.fatal_native_interpreter_dependency == null);
    try testing.expectEqual(@as(usize, 1), worklist.items.len);
}

// ── Call-Target Recording Tests ────────────────────────────────────────

fn callTargetsNoopNative(ctx: *Context) anyerror!void {
    _ = ctx;
}

test "collectCallWords records a top-level call with empty quotation_path" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Register two natives so classification is .native_name and resolution
    // succeeds in a downstream buildAotDescs pass. The names are arbitrary;
    // classification only consults the dictionary.
    try ctx.dictionary.put("noop-a", .{ .name = "noop-a", .action = .{ .native = callTargetsNoopNative } });
    try ctx.dictionary.put("noop-b", .{ .name = "noop-b", .action = .{ .native = callTargetsNoopNative } });

    const instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .call_word = "noop-a" }, .line = 1 },
        .{ .op = .{ .call_word = "noop-b" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    try testing.expectEqual(@as(usize, 2), pending_call_targets.items.len);
    try testing.expectEqualStrings("__entry__", pending_call_targets.items[0].caller_name);
    try testing.expectEqual(@as(u32, 1), pending_call_targets.items[0].instruction_index);
    try testing.expectEqual(@as(usize, 0), pending_call_targets.items[0].quotation_path.len);
    try testing.expectEqualStrings("noop-a", pending_call_targets.items[0].pending.native_name);
    try testing.expectEqual(@as(u32, 2), pending_call_targets.items[1].instruction_index);
    try testing.expectEqualStrings("noop-b", pending_call_targets.items[1].pending.native_name);
}

test "collectCallWords records calls inside nested quotations with quotation_path" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.dictionary.put("inner-noop", .{ .name = "inner-noop", .action = .{ .native = callTargetsNoopNative } });

    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "inner-noop" }, .line = 1 },
    };
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_instrs } } }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, outer_instrs, "outer", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    try testing.expectEqual(@as(usize, 1), pending_call_targets.items.len);
    const entry = pending_call_targets.items[0];
    try testing.expectEqualStrings("outer", entry.caller_name);
    try testing.expectEqual(@as(u32, 0), entry.instruction_index);
    try testing.expectEqual(@as(usize, 1), entry.quotation_path.len);
    // Outer instruction index 1 is the quotation literal we recursed into.
    try testing.expectEqual(@as(u32, 1), entry.quotation_path[0]);
    try testing.expectEqualStrings("inner-noop", entry.pending.native_name);
}

test "collectCallWords classifies an unresolved name with .not_in_dictionary" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "no-such-word" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    try testing.expectEqual(@as(usize, 1), pending_call_targets.items.len);
    try testing.expectEqual(UnresolvedReason.not_in_dictionary, pending_call_targets.items[0].pending.unresolved);
}

test "collectCallWords classifies a parse-time-only callee as skipped" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.dictionary.put("parse-only", .{
        .name = "parse-only",
        .action = .{ .compound = &.{} },
        .parse_time_only = true,
    });

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "parse-only" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    try testing.expectEqual(@as(usize, 1), pending_call_targets.items.len);
    try testing.expectEqual(UnresolvedReason.skipped_parse_time_only, pending_call_targets.items[0].pending.unresolved);
}

test "collectCallWords does not deduplicate call-site records" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.dictionary.put("once", .{ .name = "once", .action = .{ .native = callTargetsNoopNative } });

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "once" }, .line = 1 },
        .{ .op = .{ .call_word = "once" }, .line = 1 },
    };

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var quotation_path = std.ArrayListUnmanaged(u32){};
    defer quotation_path.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, false, allocator, allocator);

    // BFS dedup is independent of per-call-site recording: two call_word
    // instructions to the same callee produce two pending entries.
    try testing.expectEqual(@as(usize, 2), pending_call_targets.items.len);
    try testing.expectEqual(@as(u32, 0), pending_call_targets.items[0].instruction_index);
    try testing.expectEqual(@as(u32, 1), pending_call_targets.items[1].instruction_index);
}

test "buildAotDescs remaps caller name to caller_word_id and resolves callees" {
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "foo" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    const effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };
    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };
    defer discovered.names.deinit(allocator);
    defer discovered.defs.deinit(allocator);
    defer discovered.native_names.deinit(allocator);
    defer discovered.native_defs.deinit(allocator);

    // Compound "foo" gets word_id 1; native "bar" gets word_id 2.
    try discovered.names.append(allocator, "foo");
    try discovered.defs.append(allocator, .{
        .name = "foo",
        .action = .{ .compound = &.{} },
        .stack_effect = effect,
    });
    try discovered.native_names.append(allocator, "bar");
    try discovered.native_defs.append(allocator, .{
        .name = "bar",
        .action = .{ .native = callTargetsNoopNative },
        .stack_effect = effect,
    });

    const pending = [_]PendingCallTarget{
        // Entry calls foo.
        .{ .caller_name = "__entry__", .instruction_index = 0, .quotation_path = &.{}, .pending = .{ .compound_name = "foo" } },
        // foo calls bar.
        .{ .caller_name = "foo", .instruction_index = 0, .quotation_path = &.{}, .pending = .{ .native_name = "bar" } },
    };

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &pending, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.call_targets.len);
    // First entry: __entry__ (id 0) -> foo (compound, id 1).
    try testing.expectEqual(@as(u32, 0), result.call_targets[0].caller_word_id);
    try testing.expectEqual(@as(u32, 0), result.call_targets[0].instruction_index);
    try testing.expectEqual(@as(u32, 1), result.call_targets[0].resolved.compound);
    // Second entry: foo (id 1) -> bar (native, id 2).
    try testing.expectEqual(@as(u32, 1), result.call_targets[1].caller_word_id);
    try testing.expectEqual(@as(u32, 2), result.call_targets[1].resolved.native);
}

test "buildAotDescs preserves unresolved variant from pending entries" {
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "no-such" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };

    const pending = [_]PendingCallTarget{
        .{ .caller_name = "__entry__", .instruction_index = 0, .quotation_path = &.{}, .pending = .{ .unresolved = .not_in_dictionary } },
    };

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &pending, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.call_targets.len);
    try testing.expectEqual(@as(u32, 0), result.call_targets[0].caller_word_id);
    try testing.expectEqual(UnresolvedReason.not_in_dictionary, result.call_targets[0].resolved.unresolved);
}

test "buildAotDescs preserves quotation_path through dupe" {
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "n" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    const effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };
    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };
    defer discovered.native_names.deinit(allocator);
    defer discovered.native_defs.deinit(allocator);
    try discovered.native_names.append(allocator, "n");
    try discovered.native_defs.append(allocator, .{
        .name = "n",
        .action = .{ .native = callTargetsNoopNative },
        .stack_effect = effect,
    });

    // BFS-time path slice owned by the test; the dupe-into-result pattern
    // means buildAotDescs allocates its own copy. The test leaves this
    // slice intact (no transfer) because pending is a stack literal here.
    const path_data = [_]u32{ 3, 1 };
    const pending = [_]PendingCallTarget{
        .{ .caller_name = "__entry__", .instruction_index = 5, .quotation_path = &path_data, .pending = .{ .native_name = "n" } },
    };

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, &discovered, &pending, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.call_targets.len);
    const out = result.call_targets[0];
    try testing.expectEqual(@as(u32, 5), out.instruction_index);
    try testing.expectEqual(@as(usize, 2), out.quotation_path.len);
    try testing.expectEqual(@as(u32, 3), out.quotation_path[0]);
    try testing.expectEqual(@as(u32, 1), out.quotation_path[1]);
    // Confirm the dupe is a distinct allocation, not aliased to path_data.
    try testing.expect(@intFromPtr(out.quotation_path.ptr) != @intFromPtr(&path_data[0]));
}

test "buildAotDescs throughput ceiling on synthetic graph" {
    // Ceiling, not a baseline diff. Chosen generously so it passes today and
    // would fail only on catastrophic regression; tune downward as the path
    // becomes hotter or upward as the synthetic workload grows.
    const allocator = testing.allocator;
    const word_count: usize = 200;
    const calls_per_word: usize = 20;
    const ceiling_ns: u64 = 250 * std.time.ns_per_ms;

    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{});
    defer allocator.free(entry_instrs);

    var discovered = DiscoveredWords{
        .names = .{},
        .defs = .{},
        .native_names = .{},
        .native_defs = .{},
        .quotation_bodies = .{},
    };
    defer discovered.names.deinit(allocator);
    defer discovered.defs.deinit(allocator);

    const effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };
    // Generate word names "w0".. "wN-1" and append. Each compound's body is
    // a hand-built array of call_word instructions pointing at neighbors;
    // bodies own their backing slices and are freed at test end.
    var name_buf = std.ArrayListUnmanaged([]u8){};
    defer {
        for (name_buf.items) |n| allocator.free(n);
        name_buf.deinit(allocator);
    }
    var body_buf = std.ArrayListUnmanaged([]Instruction){};
    defer {
        for (body_buf.items) |b| allocator.free(b);
        body_buf.deinit(allocator);
    }

    var i: usize = 0;
    while (i < word_count) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "w{d}", .{i});
        try name_buf.append(allocator, name);
    }
    i = 0;
    while (i < word_count) : (i += 1) {
        const body = try allocator.alloc(Instruction, calls_per_word);
        var j: usize = 0;
        while (j < calls_per_word) : (j += 1) {
            const target_idx = (i + j + 1) % word_count;
            body[j] = .{ .op = .{ .call_word = name_buf.items[target_idx] }, .line = 1 };
        }
        try body_buf.append(allocator, body);
        try discovered.names.append(allocator, name_buf.items[i]);
        try discovered.defs.append(allocator, .{
            .name = name_buf.items[i],
            .action = .{ .compound = body },
            .stack_effect = effect,
        });
    }

    // Build pending_call_targets: one entry per call_word in every body.
    var pending = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending.deinit(allocator);
    i = 0;
    while (i < word_count) : (i += 1) {
        var j: usize = 0;
        while (j < calls_per_word) : (j += 1) {
            const target_idx = (i + j + 1) % word_count;
            try pending.append(allocator, .{
                .caller_name = name_buf.items[i],
                .instruction_index = @intCast(j),
                .quotation_path = &.{},
                .pending = .{ .compound_name = name_buf.items[target_idx] },
            });
        }
    }

    var prelude_words = std.StringHashMapUnmanaged(void){};

    var timer = try std.time.Timer.start();
    var result = try buildAotDescs(entry_instrs, &discovered, pending.items, &prelude_words, null, allocator);
    const elapsed_ns = timer.read();
    defer result.deinit(allocator);

    try testing.expectEqual(word_count * calls_per_word, result.call_targets.len);
    try testing.expect(elapsed_ns < ceiling_ns);
}
