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
const ArtifactClass = markers_mod.ArtifactClass;

const dispatch_helpers = @import("primitives/dispatch_helpers.zig");
const pic_mod = @import("pic.zig");

const dispatch_mod = @import("dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;

const trace_mod = @import("trace.zig");

pub const AotQuotationDesc = struct {
    quotation_id: u32,
    instructions: []const Instruction,
    c_name: []const u8,
    inferred_effect: ?ir_codegen.InferredEffect = null,
    compiled: bool = false,
    /// Source file containing the defining word of this quotation,
    /// or null when unknown. Used by AOT C emission to attach a
    /// `#line` directive at the quotation's emitted C function
    /// entry.
    source_file: ?[]const u8 = null,
    /// 1-based line of the opening `[` in `source_file`. Zero when
    /// unknown. Used by both the `#line` directive and the asm-name
    /// override emitted on the quotation's forward declaration.
    source_line: usize = 0,
    /// 1-based column of the opening `[` in `source_file`. Zero when
    /// unknown. Used by the asm-name override; the `#line` directive
    /// reports line only.
    source_column: usize = 0,
    /// Name of the enclosing user-defined word, or `__entry__` for a
    /// quotation literal reached from the top-level entry program.
    /// Null when unknown. Used by AOT C emission to format the
    /// asm-name override as `<defining-word>/quot@<line>:<col>`.
    defining_word: ?[]const u8 = null,
    /// True when this quotation is the body of a `method{` dispatch entry discovered by walking a
    /// reached generic. Distinguishes method bodies from literal quotations so the codegen can
    /// apply the interpreter-run fallback and the method-body-specific build diagnostic to them.
    is_method_body: bool = false,
    /// True when this quotation was reached only through a composite literal (a hash, array, or
    /// dispatch container) rather than as a direct quotation literal. Buried bodies keep their
    /// callees undiscovered by design, so they compile opportunistically: an uncompiled one runs
    /// interpreted at its dispatch site instead of failing the build.
    from_composite: bool = false,
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
    /// Non-prelude words the freezer did not compile that are reachable from composite-buried
    /// quotations, deduped by callee name. Empty in strict builds, whose promoting walks discover
    /// those callees. Codegen rejects an interpreter-linked metadata-only build when any are
    /// present, since the interpreted call would run the word's empty rehydrated body.
    interpreted_reach: []const ir_codegen.InterpretedReachViolation = &.{},

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
        allocator.free(self.interpreted_reach);
    }
};

/// Why a `call_word` could not be resolved to a concrete callee during the
/// freeze BFS. Distinct reasons exist so downstream enforcement can apply
/// different rules to each.
///
/// Enforcement behavior against banned `dynamic-*` features:
///
/// - `not_in_dictionary`: BFS marker check returns null (no word to check),
///   so no ban can fire at this site. If a separate site in the same caller
///   does trigger a banned-feature diagnostic, the unresolved row is
///   surfaced as a hint so the user sees what freeze could not classify.
/// - `skipped_parse_time_only`: the only realistic path where a banned
///   marker can coexist with an unresolved row, since
///   `bannedDynamicFeatureForCall` calls `ctx.lookupWord` which returns
///   parse-time-only definitions. When this happens, freeze emits the
///   banned-feature error and populates `unresolved_callee_hint` so the
///   user-facing message can explain why the callee is unresolved at
///   runtime even though its marker was visible at parse time.
/// - `skipped_no_stack_effect`: BFS already raised any marker ban (or
///   chose not to) before remap. This row exists only on the
///   `MissingStackEffects` error path, and the surrounding FreezeResult
///   is deinit'd before consumers can observe `call_targets`.
pub const UnresolvedReason = enum {
    /// Neither `Context.lookupWord` nor `Context.resolveQualifiedModuleWord`
    /// returned a definition for the name. The callee is genuinely absent
    /// from the dictionary visible at freeze time.
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
/// (struct accessors, virtual constructors, `method{` dispatchers). The
/// `placeholder` variant is reserved for future first-use generators that
/// would materialize after the BFS sees a call site; today the variant is
/// unused because every known generator runs at parse time.
///
/// Generator-resolution contract (each known generator kind):
///
/// - **Struct accessors** (`field>>`, `>>field`) materialize during `;`
///   execution of `struct{ ... }`. `src/primitives/structs.zig` calls
///   `defineFieldGetter` and `defineFieldSetter`, which install real
///   `WordDefinition` entries whose bodies invoke the qualified natives
///   `native.struct-field-get` / `native.struct-field-set`. Both the
///   accessor (direct `ctx.lookupWord`) and the inner native call
///   (`Context.resolveQualifiedModuleWord`) are resolvable by freeze BFS, so call
///   sites surface as `compound` or `native` `ResolvedCallee` rows.
/// - **Virtual constructors** (`<name>`, `make-name`, `>name`, `name>`,
///   `name?`) materialize during `;` execution of `virtual{ ... }`.
///   `src/primitives/virtual.zig::defineWrap` / `defineUnwrap` install
///   the wrap, unwrap, and predicate words; their bodies call qualified
///   natives like `native.virtual-wrap`. Same resolution path as
///   struct accessors.
/// - **`method{` dispatchers**: the polymorphic word itself is defined
///   separately (built-in or user-authored with the `generic` marker).
///   `define-method` registers a dispatch table entry through
///   `ctx.registerDispatch`; no new dictionary word is created. Freeze
///   resolves the dispatcher directly and walks every registered method
///   body via `walkDispatchMethodBodies`, so reachable bodies behave like
///   nested quotation literals during BFS.
///
/// Implication: today the BFS never emits a `GeneratedKind` row, and
/// `unresolved` rows never name a known-generator output. If a future
/// generator changes its materialization timing, the regression tests in
/// this file (search for "generator") will flip to `unresolved` and
/// require an explicit decision to update the contract.
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
///
/// For calls discovered by walking a `method{` dispatch entry on a
/// generic, `caller_word_id` is the polymorphic word's id,
/// `instruction_index` is 0, and `quotation_path` begins with
/// `DISPATCH_PATH_SENTINEL`. The sentinel value (`maxInt(u32)`) is never a
/// real quotation-literal index, so this encoding cannot collide with any
/// real quotation literal path, whether or not the polymorphic word's body
/// is empty.
pub const CallTargetEntry = struct {
    caller_word_id: u32,
    instruction_index: u32,
    quotation_path: []const u32,
    resolved: ResolvedCallee,
};

/// Sentinel placed at the head of `CallTargetEntry.quotation_path` for
/// entries discovered by walking a `method{` dispatch entry on a generic.
/// The value (`maxInt(u32)`) is never a real quotation-literal index, so
/// consumers can rely on it to distinguish dispatch-walked rows from
/// direct quotation-literal rows.
pub const DISPATCH_PATH_SENTINEL: u32 = std.math.maxInt(u32);

pub const FreezeFeatureUse = struct {
    caller_name: []const u8,
    feature_name: []const u8,
};

/// One call chain from a compound word to a target native. `compound_chain`
/// holds word names from the outermost caller down to (and including) the
/// direct caller of the native; `native_name` is the native itself.
///
/// Example for a chain A → B → native.eval-string:
///   compound_chain = .{ "A", "B" }
///   native_name    = "native.eval-string"  (or the unqualified name)
///
/// A direct caller has `compound_chain.len == 1`.
pub const ReachChain = struct {
    compound_chain: []const []const u8,
    native_name: []const u8,

    pub fn deinit(self: ReachChain, allocator: Allocator) void {
        allocator.free(self.compound_chain);
    }
};

/// Recorded alongside a `DisallowedDynamicFeature` diagnostic when the
/// callee that triggered the ban classifies as unresolved (or, in a
/// future world, as a pending generator). Carries the resolution reason
/// so the user-facing message can explain why the callee is unresolved
/// at freeze time even though its marker was visible to the ban check.
pub const UnresolvedCalleeHint = struct {
    caller_name: []const u8,
    callee_name: []const u8,
    reason: UnresolvedReason,
};

pub const FreezeDiagnostics = struct {
    fatal_dynamic_feature: ?FreezeFeatureUse = null,
    fatal_native_interpreter_dependency: ?FreezeFeatureUse = null,
    /// Set in lockstep with `fatal_dynamic_feature` when the call_target
    /// row for the banned site does not resolve to a concrete callee
    /// id. Today the only realistic path that populates this field is a
    /// parse-time-only word carrying a `dynamic-*` marker; future
    /// first-use generators would also surface here.
    unresolved_callee_hint: ?UnresolvedCalleeHint = null,
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
    /// Which artifact class the build is targeting. Drives the
    /// `dynamic-*` marker policy and the interpreter-dependent native
    /// ban. Default `.interpreter_free_aot` is the strictest policy
    /// applied; callers (CLI build, embedded host) pick a class that
    /// matches the artifact they intend to produce.
    artifact_class: ArtifactClass = .interpreter_free_aot,
    /// True under `--interpreter-fallback=false`, with or without `--lock-interpreter-setting`.
    strict_interpreter_free: bool = false,
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
    var discovered = discoverReachableWords(ctx, entry_instrs, entry_file, &prelude_words, diagnostics, options.artifact_class, options.strict_interpreter_free, allocator) catch |err| {
        ctx.popPragmaFrame();
        ctx.popLocalFrame();
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.DisallowedDynamicFeature => error.DisallowedDynamicFeature,
            error.DisallowedNativeInterpreterDependency => error.DisallowedNativeInterpreterDependency,
        };
    };
    defer discovered.names.deinit(ctx.quotationAllocator());
    defer discovered.method_body_ptrs.deinit(ctx.quotationAllocator());
    defer discovered.composite_body_ptrs.deinit(ctx.quotationAllocator());
    defer discovered.interpreted_reach.deinit(ctx.quotationAllocator());
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
                .literal => |v| {
                    try discovered.names.append(temp_allocator, name);
                    try discovered.defs.append(temp_allocator, try literalWordAsCompound(temp_allocator, word, v));
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
            // Every entry ever appended to discovered.defs is normalized to
            // .compound first (the compile_all_prelude block above and
            // drainWorklist/discoverCalleeWord below all route a .literal
            // word through literalWordAsCompound before appending), so the
            // `else` arm is unreachable in practice, not a silent skip.
            const compound_instrs = switch (def.action) {
                .compound => |c| c,
                else => continue,
            };

            // Dispatch-only generics may be devirtualized at AOT freeze. When that fires, the compiled body
            // is the dispatch table's single method, not the empty compound body.
            //
            // Inspect that body too so its native calls, typically `native.struct-field-get` et al., land in
            // the resolver's discovered set even when the word arrived htrough `--compile-all-prelude`,
            // and never went through the BFS, which would have called `walkDispatchMethodBodies`.
            const instrs_list: [2][]const Instruction = blk: {
                if (try devirtualizeSingleMethod(ctx, def, temp_allocator)) |devirt| {
                    break :blk .{ compound_instrs, devirt.body };
                }
                break :blk .{ compound_instrs, &.{} };
            };

            for (instrs_list) |instrs| {
                scanUnresolvedCallees(ctx, instrs, def.name, &qual_seen, &discovered, diagnostics, options.artifact_class, temp_allocator) catch |err| {
                    ctx.popPragmaFrame();
                    ctx.popLocalFrame();
                    return err;
                };
            }
        }
    }

    // Now safe to pop the frames
    ctx.popPragmaFrame();
    ctx.popLocalFrame();

    // Phase 3: Build AotWordDesc array
    var result = try buildAotDescs(entry_instrs, entry_file, &discovered, discovered.pending_call_targets.items, &prelude_words, ctx, allocator);
    if (result.skipped_words.len > 0) {
        diagnostics.missing_stack_effects = result.skipped_words;
        result.skipped_words = &.{};
        result.deinit(allocator);
        return error.MissingStackEffects;
    }

    result.interpreted_reach = try allocator.dupe(ir_codegen.InterpretedReachViolation, discovered.interpreted_reach.items);

    // Success: path slices have been duped into result.call_targets. Free
    // the BFS-time originals; the idempotent free renders the errdefer
    // above a no-op if any subsequent step fails.
    freePendingCallTargetPaths(&discovered.pending_call_targets, allocator);

    return result;
}

/// Phase 2b helper: resolve every unseen callee in `instrs` into the discovered set, descending
/// nested quotation literals to arbitrary depth.
///
/// Under the interpreter-free artifact class an interpreter-dependent native is fatal; the
/// diagnostic is set here and the caller owns the frame cleanup on that error path.
fn scanUnresolvedCallees(
    ctx: *const Context,
    instrs: []const Instruction,
    caller_name: []const u8,
    qual_seen: *std.StringHashMapUnmanaged(void),
    discovered: *DiscoveredWords,
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    temp_allocator: Allocator,
) (Allocator.Error || error{DisallowedNativeInterpreterDependency})!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .call_word, .call_word_direct => {
                const call_name = instr.op.callTargetName().?;
                if (qual_seen.contains(call_name)) continue;
                try qual_seen.put(temp_allocator, call_name, {});

                if (artifact_class == .interpreter_free_aot and isInterpreterDependentNative(ctx, call_name)) {
                    diagnostics.fatal_native_interpreter_dependency = .{
                        .caller_name = caller_name,
                        .feature_name = call_name,
                    };
                    return error.DisallowedNativeInterpreterDependency;
                }

                try discoverCalleeWord(ctx, call_name, discovered, temp_allocator);
            },
            .push_literal => |val| {
                if (val == .quotation) {
                    try scanUnresolvedCallees(ctx, val.quotation.instructions, caller_name, qual_seen, discovered, diagnostics, artifact_class, temp_allocator);
                }
            },
        }
    }
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

    // Track the current file line so that parse-time word definitions
    // see file-relative line numbers via `parse_line_offset`. Without
    // this, every statement in the entry file looks like it starts at
    // line 1, and downstream consumers (error reporting, `#line`
    // directives in AOT C emission) lose file accuracy.
    var file_line: usize = 0;

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

        file_line += 1;
        processor.trackLine(file_line);
        if (processor.start_line > 0) {
            ctx.parse_line_offset = processor.start_line - 1;
        }

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
    /// Instruction-slice pointers of the quotation bodies that are `method{` dispatch bodies, used
    /// to set `AotQuotationDesc.is_method_body` at manifest-build time.
    method_body_ptrs: std.AutoHashMapUnmanaged(usize, void) = .{},
    /// Instruction-slice pointers of the quotation bodies reached only through composite literals,
    /// used to set `AotQuotationDesc.from_composite` at manifest-build time.
    composite_body_ptrs: std.AutoHashMapUnmanaged(usize, void) = .{},
    /// Violations found by the interpreted-reach detection walk, deduped by callee name.
    interpreted_reach: std.ArrayListUnmanaged(ir_codegen.InterpretedReachViolation) = .{},
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

/// Separates a callee's defining-module name from the word name inside a worklist entry.
/// `drainWorklist` re-establishes that module's scope before resolving, so two same-named words from
/// different modules (e.g. a `path>>` getter generated by two structs) resolve to the one the caller sees.
const word_identity_sep: u8 = 0x1e;

fn encodeWordIdentity(allocator: Allocator, module_name: ?[]const u8, name: []const u8) Allocator.Error![]const u8 {
    const m = module_name orelse return name;
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ m, word_identity_sep, name });
}

fn decodeWordIdentity(identity: []const u8) struct { module: ?[]const u8, name: []const u8 } {
    if (std.mem.indexOfScalar(u8, identity, word_identity_sep)) |i| {
        return .{ .module = identity[0..i], .name = identity[i + 1 ..] };
    }
    return .{ .module = null, .name = identity };
}

/// BFS over call_word references starting from entry instructions,
/// collecting all reachable compound words.
///
/// `entry_file` and `prelude_words` feed the interpreted-reach detection walk
/// that runs after discovery.
fn discoverReachableWords(
    ctx: *Context,
    entry_instrs: []const Instruction,
    entry_file: []const u8,
    prelude_words: *const std.StringHashMapUnmanaged(void),
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    strict_interpreter_free: bool,
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
    errdefer {
        freePendingCallTargetPaths(&result.pending_call_targets, result_allocator);
        result.names.deinit(temp_allocator);
        result.defs.deinit(temp_allocator);
        result.native_names.deinit(temp_allocator);
        result.native_defs.deinit(temp_allocator);
        result.quotation_bodies.deinit(temp_allocator);
        result.pending_call_targets.deinit(temp_allocator);
    }

    // Push deps frames for every loaded module so that lookupWord can find
    // module-private words during BFS. At runtime the executor pushes a
    // module's deps frame just before running its words; the AOT freeze
    // walks every word statically, so it needs all loaded modules' deps
    // visible for the duration of discovery.
    var pushed_module_frames: usize = 0;
    {
        var cache_iter = ctx.module_cache_value.map.iterator();
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
    try collectCallWords(ctx, entry_instrs, "__entry__", &worklist, &seen, &result.quotation_bodies, &quotation_seen, &result.pending_call_targets, &quotation_path, diagnostics, artifact_class, temp_allocator, result_allocator);

    // promote callees of composite-nested quotations in the entry instructions before draining,
    // so a runtime-selected dispatch, e.g., `H{ ... match: [ ... ] }`, has its branch quot
    // callees compile.
    if (strict_interpreter_free) try collectCompositeQuotationsPromoting(ctx, entry_instrs, "__entry__", &worklist, &seen, &result.quotation_bodies, &quotation_seen, &result.composite_body_ptrs, &result.pending_call_targets, &quotation_path, diagnostics, artifact_class, temp_allocator, result_allocator);

    // BFS
    try drainWorklist(ctx, &worklist, &seen, &quotation_seen, &quotation_path, &result, diagnostics, artifact_class, temp_allocator, result_allocator);

    // Word-body-scoped promoting walks, re-draining the BFS in a fixed-point loop since a
    // newly-promoted callee may itself call further undiscovered words. Two walks share the loop:
    //
    // Runtime-image dispatch containers (strict builds only): the lint registry's `.mutable_map` /
    // `.struct_instance` and the lexer rules' `.hash`. Promote the callees of a quotation found at
    // a named dispatch slot (the struct `check` field, the hash `match` key) so that quotation's
    // own compilation succeeds and it carries a real `code_ptr`.
    //
    // Branch tables (every build): a table literal immediately consumed by `unchecked-match` /
    // `case` / `cond`. Promote the buried arm callees so the arms compile and the word matches
    // interpreter behavior instead of dropping to an uncompiled arm at runtime.
    //
    // Both walks are keyed -- to the two known container shapes plus named slots, and to the
    // consuming combinator call -- not applied to arbitrary word-body composites: promoting
    // composite callees found anywhere in a word body was tried once and regressed by pulling
    // unrelated module-cached generic-dispatch getters and effect-less consts into the
    // must-compile set.
    {
        var scanned_entry = false;
        var scanned_def_count: usize = 0;
        while (true) {
            const worklist_len_before = worklist.items.len;

            if (!scanned_entry) {
                if (strict_interpreter_free) try collectDispatchContainerQuotationsPromoting(ctx, entry_instrs, "__entry__", &worklist, &seen, &result.quotation_bodies, &quotation_seen, &result.composite_body_ptrs, &result.pending_call_targets, &quotation_path, diagnostics, artifact_class, temp_allocator, result_allocator);
                try collectBranchTableQuotationsPromoting(ctx, entry_instrs, "__entry__", &worklist, &seen, &result.quotation_bodies, &quotation_seen, &result.composite_body_ptrs, &result.pending_call_targets, &quotation_path, diagnostics, artifact_class, temp_allocator, result_allocator);
                scanned_entry = true;
            }

            while (scanned_def_count < result.defs.items.len) : (scanned_def_count += 1) {
                const def = result.defs.items[scanned_def_count];
                const body = switch (def.action) {
                    .compound => |c| c,
                    // Every discovery site normalizes a .literal word into
                    // .compound before storing it here (see
                    // literalWordAsCompound), so this arm is unreachable in
                    // practice; kept only for switch exhaustiveness.
                    .native, .host_callback, .literal => continue,
                };
                if (strict_interpreter_free) try collectDispatchContainerQuotationsPromoting(ctx, body, result.names.items[scanned_def_count], &worklist, &seen, &result.quotation_bodies, &quotation_seen, &result.composite_body_ptrs, &result.pending_call_targets, &quotation_path, diagnostics, artifact_class, temp_allocator, result_allocator);
                try collectBranchTableQuotationsPromoting(ctx, body, result.names.items[scanned_def_count], &worklist, &seen, &result.quotation_bodies, &quotation_seen, &result.composite_body_ptrs, &result.pending_call_targets, &quotation_path, diagnostics, artifact_class, temp_allocator, result_allocator);
            }

            if (worklist.items.len == worklist_len_before) break;

            try drainWorklist(ctx, &worklist, &seen, &quotation_seen, &quotation_path, &result, diagnostics, artifact_class, temp_allocator, result_allocator);
        }
    }

    // Phase 4: collect quotations buried in composite literals which the main BFS never walks into.
    //
    // Only the quotation bodies are collected into the manifest, so the compiler attempts to
    // compile each and a `code_ptr` can later be attached to the ones that do. The words those
    // bodies call are deliberately NOT added to the discovered set: they remain ordinary runtime-
    // image words that run interpreted exactly as they did before composite discovery.
    //
    // Promoting them into the discovered set would reroute their AOT handling, e.g., a generic
    // getter through the dispatch-callback path, a `const` through a placeholder-effect body.
    //
    // The dispatch-container promoting walk above runs first so `result.defs` already includes
    // every word discovered via promotion by the time this pass collects their composite-nested
    // quotation bodies too.
    try collectCompositeQuotations(entry_instrs, &result.quotation_bodies, &quotation_seen, &result.composite_body_ptrs, temp_allocator);
    for (result.defs.items) |def| {
        const body = switch (def.action) {
            .compound => |c| c,
            // Every discovery site normalizes a .literal word into
            // .compound before storing it in result.defs (see
            // literalWordAsCompound), so this arm is unreachable in
            // practice; kept only for switch exhaustiveness.
            .native, .host_callback, .literal => continue,
        };
        try collectCompositeQuotations(body, &result.quotation_bodies, &quotation_seen, &result.composite_body_ptrs, temp_allocator);
    }

    // Detect interpreted reach to non-prelude words the BFS never discovered.
    //
    // Composite-buried quotations run interpreted when uncompiled, and a metadata-only image drops
    // the bodies of the words they call, so codegen must know whether any buried quotation reaches
    // a non-prelude word with no compiled dispatch.
    //
    // Runs in every build: the promoting walks above cover only keyed shapes (named dispatch slots,
    // branch tables), so this is the backstop that converts any shape they miss into a build-time
    // rejection instead of a dropped body at runtime. Callees the walks did promote are in the
    // discovered set and produce no violations.
    //
    // Runs inside discovery so name resolution sees the same module deps frames the BFS used.
    {
        var discovered_names = std.StringHashMapUnmanaged(void){};
        defer discovered_names.deinit(temp_allocator);
        for (result.names.items) |name| {
            try discovered_names.put(temp_allocator, name, {});
        }

        var detect_quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
        defer detect_quotation_seen.deinit(temp_allocator);
        var callee_seen = std.StringHashMapUnmanaged(void){};
        defer callee_seen.deinit(temp_allocator);

        const entry_source_file: ?[]const u8 = if (entry_file.len > 0) entry_file else null;
        try detectInterpretedReach(ctx, entry_instrs, "__entry__", entry_source_file, prelude_words, &discovered_names, &detect_quotation_seen, &callee_seen, &result.interpreted_reach, temp_allocator);
        for (result.names.items, result.defs.items) |name, def| {
            const body = switch (def.action) {
                .compound => |c| c,
                // Every discovery site normalizes a .literal word into
                // .compound before storing it in result.defs (see
                // literalWordAsCompound), so this arm is unreachable in
                // practice; kept only for switch exhaustiveness.
                .native, .host_callback, .literal => continue,
            };
            try detectInterpretedReach(ctx, body, name, def.source_file, prelude_words, &discovered_names, &detect_quotation_seen, &callee_seen, &result.interpreted_reach, temp_allocator);
        }
    }

    return result;
}

/// Emit a `--trace-aot=freeze` line naming a word committed to the compilation
/// manifest. `kind` is `"compound"` or `"native"`. No-op unless the axis is on.
fn emitFreezeWordTrace(ctx: *const Context, name: []const u8, kind: []const u8) void {
    if (!ctx.trace.trace_aot.freeze) return;
    if (!trace_mod.matchesPattern(name, ctx.trace.trace_aot_word_pattern)) return;
    var tw = trace_mod.TraceWriter.init();
    trace_mod.traceAotFreezeWord(&tw, name, kind);
}

/// Emit a `--trace-aot=freeze` line for a newly discovered quotation. A quotation
/// has no name, so it is identified by its body pointer and the caller it was
/// found in. No-op unless the axis is on.
fn emitFreezeQuotationTrace(ctx: *const Context, caller: []const u8, ptr_key: usize) void {
    if (!ctx.trace.trace_aot.freeze) return;
    if (!trace_mod.matchesPattern(caller, ctx.trace.trace_aot_word_pattern)) return;
    var tw = trace_mod.TraceWriter.init();
    trace_mod.traceAotFreezeQuotation(&tw, caller, ptr_key);
}

/// Drain `worklist` via BFS: for each popped name, look up the word, record it (or its native
/// entry) into `result`, discover its callees via `collectCallWords` (which appends more names to
/// `worklist`), and walk its dispatch method bodies. Extracted from a single inline loop so the
/// dispatch-container promoting walk (below) can re-drain after seeding more names without
/// duplicating the loop body. Error cleanup on `result`'s partially-built lists is the caller's
/// responsibility (this function may be called more than once per `discoverReachableWords`
/// invocation, so it must not free state it does not own).
fn drainWorklist(
    ctx: *Context,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    quotation_path: *std.ArrayListUnmanaged(u32),
    result: *DiscoveredWords,
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    allocator: Allocator,
    result_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!void {
    while (worklist.pop()) |identity| {
        const decoded = decodeWordIdentity(identity);
        const name = decoded.name;

        // Push the callee's own module on top so a bare word in its body resolves
        // against its defining module, matching the interpreter's per-word scope.
        // Record the frame only on a successful push: on failure `pushModuleDepsFrame`
        // unwinds its own append, so popping here would drop a live global frame.
        var scope_module: ?*const value_mod.Module = null;
        if (decoded.module) |mn| {
            if (ctx.moduleByNameInCache(mn)) |m| {
                if (ctx.pushModuleDepsFrame(m)) |_| {
                    scope_module = m;
                } else |_| {}
            }
        }
        defer if (scope_module) |m| ctx.popModuleDepsFrameTraced(m);

        const word = ctx.lookupWord(name) orelse {
            // Try module-qualified resolution (e.g., "native.struct-field-get").
            // Generated words from struct{, virtual{, and enum{ call native
            // operations via qualified names that lookupWord cannot resolve
            // directly.
            if (ctx.resolveQualifiedModuleWord(name)) |mod_word| {
                switch (mod_word.action) {
                    .native, .host_callback => {
                        // Polymorphic natives without a declared stack effect
                        // are also registered so pre-scan can resolve every
                        // reachable native; `buildAotDescs` enters them with
                        // zero input/output counts and the codegen either
                        // special-cases or bails out per native.
                        try result.native_names.append(allocator, name);
                        try result.native_defs.append(allocator, wordDefFromModuleWord(name, mod_word));
                        emitFreezeWordTrace(ctx, name, "native");
                    },
                    .compound => |compound_instrs| {
                        try result.names.append(allocator, name);
                        const qualified_def = wordDefFromModuleWord(name, mod_word);
                        try result.defs.append(allocator, qualified_def);
                        emitFreezeWordTrace(ctx, name, "compound");
                        try collectCallWords(ctx, compound_instrs, name, worklist, seen, &result.quotation_bodies, quotation_seen, &result.pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, result_allocator);
                        try walkDispatchMethodBodies(ctx, qualified_def, name, worklist, seen, &result.quotation_bodies, quotation_seen, &result.method_body_ptrs, &result.pending_call_targets, diagnostics, artifact_class, allocator, result_allocator);
                    },
                }
            }
            continue;
        };

        // Skip parse-time-only words
        if (word.parse_time_only) continue;

        // Record native words for the resolver, but don't BFS into them, since
        // they have no instructions to discover more words
        switch (word.action) {
            .native, .host_callback => {
                try result.native_names.append(allocator, name);
                try result.native_defs.append(allocator, word);
                emitFreezeWordTrace(ctx, name, "native");
                continue;
            },
            .compound, .literal => {},
        }

        // Normalize a .literal word into the one-instruction .compound
        // shape that a plain-value binding produced before this variant
        // existed, so the rest of discovery (and everything downstream of
        // it) keeps seeing only the .compound/.native shapes it already
        // supports.
        const store_word = if (word.action == .literal)
            try literalWordAsCompound(allocator, word, word.action.literal)
        else
            word;
        const instrs = store_word.action.compound;

        try result.names.append(allocator, name);
        try result.defs.append(allocator, store_word);
        emitFreezeWordTrace(ctx, name, "compound");

        // Discover callees
        try collectCallWords(ctx, instrs, name, worklist, seen, &result.quotation_bodies, quotation_seen, &result.pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, result_allocator);

        // Walk every method body registered for this word's dispatch_id so
        // reached generics' methods enter the compilation manifest. For
        // non-generics this is a noop.
        try walkDispatchMethodBodies(ctx, store_word, name, worklist, seen, &result.quotation_bodies, quotation_seen, &result.method_body_ptrs, &result.pending_call_targets, diagnostics, artifact_class, allocator, result_allocator);
    }
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
            // Downstream resolution re-looks-up the word by name and
            // normalizes .literal to .compound the same way discovery
            // does, so classifying it as compound_name here is correct.
            .compound, .literal => .{ .compound_name = name },
        };
    }
    if (ctx.resolveQualifiedModuleWord(name)) |mod_word| {
        return switch (mod_word.action) {
            .native, .host_callback => .{ .native_name = name },
            .compound => .{ .compound_name = name },
        };
    }
    return .{ .unresolved = .not_in_dictionary };
}

/// Seed the worklist with every word a reified quotation calls, without recording per-call-site
/// `pending_call_targets`.
///
/// A `parameter{ [ ... ] }` default is a quotation the interpreter runs on an unbound `get`. It is
/// serialized into the runtime image as bytecode, but the words it calls are not part of any
/// compiled instruction stream, so the main BFS never reaches them. Such a callee then has its
/// interpretable body dropped as empty at freeze while no compiled function is emitted for it, so
/// calling it from the interpreted default is a silent no-op that leaks the caller's inputs.
///
/// Seeding the callees compiles them, so `get` runs them through `executeCompiled`. Unlike
/// `collectCallWords`, no call-site record is appended: the call site lives inside the default, not
/// in the defining word's compiled body, so a `pending_call_target` keyed on the defining word
/// would name an instruction that body does not contain. `drainWorklist` walks each seeded word's
/// own body with the correct caller, so its transitive callees and call sites are discovered normally.
fn seedInterpretedQuotationCallees(instrs: []const Instruction, worklist: *std.ArrayListUnmanaged([]const u8), seen: *std.StringHashMapUnmanaged(void), allocator: Allocator) Allocator.Error!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .call_word => |name| {
                const gop = try seen.getOrPut(allocator, name);
                if (!gop.found_existing) try worklist.append(allocator, name);
            },
            .push_literal => |val| switch (val) {
                .quotation => |q| try seedInterpretedQuotationCallees(q.instructions, worklist, seen, allocator),
                .parameter => |p| try seedInterpretedQuotationCallees(p.default_quotation.instructions, worklist, seen, allocator),
                else => {},
            },
            else => {},
        }
    }
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
    artifact_class: ArtifactClass,
    allocator: Allocator,
    path_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!void {
    for (instrs, 0..) |instr, idx| {
        switch (instr.op) {
            .call_word, .call_word_direct => {
                const name = instr.op.callTargetName().?;
                if (bannedDynamicFeatureForCall(ctx, name, artifact_class)) |_| {
                    diagnostics.fatal_dynamic_feature = .{
                        .caller_name = caller_name,
                        .feature_name = name,
                    };
                    // If the same name classifies as unresolved (e.g., a
                    // parse-time-only word carrying a `dynamic-*` marker),
                    // attach a hint so the user-facing diagnostic can
                    // explain why the callee has no runtime presence even
                    // though the marker fired. See the generator-resolution
                    // contract on `GeneratedKind` for the forward-looking
                    // case where a first-use generator would surface here.
                    switch (classifyCallee(ctx, name)) {
                        .unresolved => |reason| {
                            diagnostics.unresolved_callee_hint = .{
                                .caller_name = caller_name,
                                .callee_name = name,
                                .reason = reason,
                            };
                        },
                        else => {},
                    }
                    return error.DisallowedDynamicFeature;
                }
                if (artifact_class == .interpreter_free_aot and isInterpreterDependentNative(ctx, name)) {
                    diagnostics.fatal_native_interpreter_dependency = .{
                        .caller_name = caller_name,
                        .feature_name = name,
                    };
                    return error.DisallowedNativeInterpreterDependency;
                }
                const callee = ctx.lookupWord(name);
                const callee_module: ?[]const u8 = if (callee) |w|
                    (if (w.source_module) |m| m.name else null)
                else
                    null;
                const identity = try encodeWordIdentity(allocator, callee_module, name);

                // Dedup by identity only for generated words (e.g., struct accessors), which inline
                // at the call site and emits no C symbol. Two same-named ones are safe. Hand-written
                // words dedup by name, since two would emit colliding C symbols that a name-keyed
                // callsite cannot pick between anyway. The worklist keeps the module either way.
                const dedup_by_identity = if (callee) |w| w.provenance != null else false;
                const seen_key = if (dedup_by_identity) identity else name;
                const gop = try seen.getOrPut(allocator, seen_key);
                if (!gop.found_existing) {
                    try worklist.append(allocator, identity);
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
                // Recurse into nested quotations unconditionally. This is
                // what implicitly covers banned natives inside quotation
                // literals passed to combinators like `call`, `if`,
                // `dip`, `each`, and so on: the freeze BFS sees the
                // literal body before the combinator runs, and the
                // banned-feature check above fires on the inner
                // `call_word` site. The recursion is intentionally
                // conservative -- it walks every literal quotation in
                // sight, including ones that may be `drop`ped or stored
                // without being called, so an unreachable banned call
                // still trips detection.
                switch (val) {
                    .quotation => |q| {
                        const ptr_key = @intFromPtr(q.instructions.ptr);
                        const qgop = try quotation_seen.getOrPut(allocator, ptr_key);
                        if (!qgop.found_existing) {
                            try quotation_bodies.append(allocator, q.instructions);
                            emitFreezeQuotationTrace(ctx, caller_name, ptr_key);
                        }
                        try quotation_path.append(allocator, @intCast(idx));
                        const recurse_err = collectCallWords(ctx, q.instructions, caller_name, worklist, seen, quotation_bodies, quotation_seen, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
                        _ = quotation_path.pop();
                        try recurse_err;
                    },
                    // A parameter's default quotation runs under the interpreter on an unbound
                    // `get`. Seed its callees so they compile and are runnable, without recording
                    // callsite records against this word's compiled body, which never contains them.
                    .parameter => |p| try seedInterpretedQuotationCallees(p.default_quotation.instructions, worklist, seen, allocator),
                    else => {},
                }
            },
        }
    }
}

/// Walk a discovered instruction stream looking for composite literal `push_literal` values
/// (`.array`, `.hash`, `.vector`) that bury quotations. The lexer's `H{ ... match: [ ... ] }`
/// rules are a single `.hash`.
///
/// The buried quotation bodies are collected into the compilation manifest; the words those
/// bodies call are intentionally left undiscovered. Branch tables consumed by a combinator call
/// were already promoted -- callees and all -- by `collectBranchTableQuotationsPromoting`, so the
/// pointer-identity dedupe skips them here.
///
/// This is the second discovery pass. The main BFS (`collectCallWords`) collects quotations
/// reachable through direct calls and nested quotation *literals* but never descends into
/// composite values, so this fills that gap. Nested quotation literals are descended into
/// here only to find composites buried inside them; the literals themselves were already
/// collected by the main BFS.
fn collectCompositeQuotations(instrs: []const Instruction, quotation_bodies: *std.ArrayListUnmanaged([]const Instruction), quotation_seen: *std.AutoHashMapUnmanaged(usize, void), composite_body_ptrs: *std.AutoHashMapUnmanaged(usize, void), allocator: Allocator) Allocator.Error!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .push_literal => |val| switch (val) {
                .quotation => |q| try collectCompositeQuotations(q.instructions, quotation_bodies, quotation_seen, composite_body_ptrs, allocator),
                .array, .hash, .vector, .mutable_map, .struct_instance => try collectQuotationsInValue(val, quotation_bodies, quotation_seen, composite_body_ptrs, allocator),
                else => {},
            },
            else => {},
        }
    }
}

/// Recurse through a composite literal Value (`.array`, `.hash`, `.vector`) to
/// reach every `.quotation` element buried inside it, collecting each body into
/// the freeze manifest under the same pointer-identity dedupe scheme
/// `collectCallWords` uses for direct quotation literals. A newly-seen body is
/// then scanned for further nested quotations -- in literals or deeper
/// composites -- via `collectNestedQuotations`. Composites nest arbitrarily (an
/// array of hashes whose values are quotations, and so on), so the walk is fully
/// recursive. Hash keys are strings, so only values are inspected. Freeze-time
/// literal composites are parse-constructed and acyclic, matching the
/// acyclic-instruction-tree assumption the discovery already relies on, so no
/// cycle guard is needed.
fn collectQuotationsInValue(val: Value, quotation_bodies: *std.ArrayListUnmanaged([]const Instruction), quotation_seen: *std.AutoHashMapUnmanaged(usize, void), composite_body_ptrs: *std.AutoHashMapUnmanaged(usize, void), allocator: Allocator) Allocator.Error!void {
    switch (val) {
        .quotation => |q| {
            const ptr_key = @intFromPtr(q.instructions.ptr);
            const qgop = try quotation_seen.getOrPut(allocator, ptr_key);
            if (!qgop.found_existing) {
                try quotation_bodies.append(allocator, q.instructions);
                try composite_body_ptrs.put(allocator, ptr_key, {});
                try collectNestedQuotations(q.instructions, quotation_bodies, quotation_seen, composite_body_ptrs, allocator);
            }
        },
        .array => |arr| {
            for (arr.items) |elem| try collectQuotationsInValue(elem, quotation_bodies, quotation_seen, composite_body_ptrs, allocator);
        },
        .hash => |h| {
            var it = h.map.iterator();
            while (it.next()) |entry| try collectQuotationsInValue(entry.value_ptr.*, quotation_bodies, quotation_seen, composite_body_ptrs, allocator);
        },
        .vector => |v| {
            for (v.list.items) |elem| try collectQuotationsInValue(elem, quotation_bodies, quotation_seen, composite_body_ptrs, allocator);
        },
        // Module-private mutable state serialized into the runtime image -- the
        // lint registry's `(lint-registry-storage)` map holds rule struct
        // instances whose `check` field is a quotation -- reaches the freeze
        // discovery as a parse-time-folded `push_literal` in a word body. The
        // quotations buried in it are dispatched at runtime (`check>> call`), so
        // they must be collected here to compile and get a `code_ptr`.
        .mutable_map => |m| {
            var it = m.map.iterator();
            while (it.next()) |entry| try collectQuotationsInValue(entry.value_ptr.*, quotation_bodies, quotation_seen, composite_body_ptrs, allocator);
        },
        .struct_instance => |si| {
            for (si.fields) |field| try collectQuotationsInValue(field, quotation_bodies, quotation_seen, composite_body_ptrs, allocator);
        },
        else => {},
    }
}

/// Promoting variant of `collectCompositeQuotations`.
///
/// Collects each composite-nested quotation body AND seeds the BFS worklist with the words that
/// body calls, so the ongoing drain compiles those callees and a runtime-selected dispatch of
/// the quotation has a real `code_ptr`.
///
/// Used only for the *entry* instructions. A composite-nested quotation dispatched at runtime
/// calls library words, e.g. `advance`,  that are reachable only through the dynamic dispatch,
/// so the static BFS never discovers them and the quotation fails to compile with
/// `.unresolvable_word`.
///
/// Scoped to entry composites deliberately.
///
/// Promoting callees of composites buried in *word bodies* pulls module-cached generic-dispatch
/// entries and effect-less consts into the discovered set, which reroutes their AOT handling
/// and trips the non-prelude must-compile backstop.
fn collectCompositeQuotationsPromoting(
    ctx: *const Context,
    instrs: []const Instruction,
    caller_name: []const u8,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    quotation_bodies: *std.ArrayListUnmanaged([]const Instruction),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    composite_body_ptrs: *std.AutoHashMapUnmanaged(usize, void),
    pending_call_targets: *std.ArrayListUnmanaged(PendingCallTarget),
    quotation_path: *std.ArrayListUnmanaged(u32),
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    allocator: Allocator,
    path_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .push_literal => |val| switch (val) {
                .quotation => |q| try collectCompositeQuotationsPromoting(ctx, q.instructions, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator),
                .array, .hash, .vector => try collectQuotationsInValuePromoting(ctx, val, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator),
                else => {},
            },
            else => {},
        }
    }
}

/// Recurse through a composite literal Value to reach every nested `.quotation`.
///
/// The companion to `collectQuotationsInValue` for the promoting walks: entry-scope composites
/// and consumer-keyed branch tables.
fn collectQuotationsInValuePromoting(
    ctx: *const Context,
    val: Value,
    caller_name: []const u8,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    quotation_bodies: *std.ArrayListUnmanaged([]const Instruction),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    composite_body_ptrs: *std.AutoHashMapUnmanaged(usize, void),
    pending_call_targets: *std.ArrayListUnmanaged(PendingCallTarget),
    quotation_path: *std.ArrayListUnmanaged(u32),
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    allocator: Allocator,
    path_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!void {
    switch (val) {
        .quotation => |q| try promoteQuotationCallees(ctx, q, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator),
        .array => |arr| {
            for (arr.items) |elem| try collectQuotationsInValuePromoting(ctx, elem, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
        },
        .hash => |h| {
            var it = h.map.iterator();
            while (it.next()) |entry| try collectQuotationsInValuePromoting(ctx, entry.value_ptr.*, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
        },
        .vector => |v| {
            for (v.list.items) |elem| try collectQuotationsInValuePromoting(ctx, elem, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
        },
        else => {},
    }
}

/// Dedupe a quotation body by pointer identity, collect it into the compilation manifest, and seed
/// the BFS worklist with the words it calls, so a runtime-selected dispatch of it has a compiled
/// `code_ptr`. Shared by every promoting walk that reaches a `.quotation` value: entry-scope
/// composites and branch tables (`collectQuotationsInValuePromoting`) and the word-body
/// dispatch-container named-slot walk (`walkDispatchContainerValue`).
///
/// A banned native inside the quotation (e.g. `>quotation`) is NOT promoted to a build rejection
/// here: the quotation stays uncompiled (its `code_ptr` stays null) and a runtime-selected dispatch
/// of it traps cleanly via the interpreter-free `call` path, preserving the designed runtime-trap
/// semantics rather than failing the build on a quotation that may never run.
fn promoteQuotationCallees(
    ctx: *const Context,
    q: value_mod.Quotation,
    caller_name: []const u8,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    quotation_bodies: *std.ArrayListUnmanaged([]const Instruction),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    composite_body_ptrs: *std.AutoHashMapUnmanaged(usize, void),
    pending_call_targets: *std.ArrayListUnmanaged(PendingCallTarget),
    quotation_path: *std.ArrayListUnmanaged(u32),
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    allocator: Allocator,
    path_allocator: Allocator,
) Allocator.Error!void {
    const ptr_key = @intFromPtr(q.instructions.ptr);
    const qgop = try quotation_seen.getOrPut(allocator, ptr_key);
    if (!qgop.found_existing) {
        try quotation_bodies.append(allocator, q.instructions);
        try composite_body_ptrs.put(allocator, ptr_key, {});
        collectCallWords(ctx, q.instructions, caller_name, worklist, seen, quotation_bodies, quotation_seen, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DisallowedDynamicFeature, error.DisallowedNativeInterpreterDependency => {},
        };
    }
}

/// The named dispatch slots the word-body promoting walk recognizes: a lint-rule struct's `check`
/// field, and a lexer-rule hash's `match` key (bare string -- 1z hash literal keys strip the
/// trailing colon). Extending this allowlist is required whenever a new runtime-image dispatch
/// container is added, or its promoted quotation keeps a null `code_ptr` and traps at runtime.
const dispatch_struct_field_check = "check";
const dispatch_hash_key_match = "match";

/// The combinators whose table argument the branch-table promoting walk recognizes. `match{`
/// desugars to a table push plus an `unchecked-match` call, so it is covered by the same key.
const branch_table_consumers = [_][]const u8{ "unchecked-match", "case", "cond" };

fn isBranchTableConsumer(name: []const u8) bool {
    for (branch_table_consumers) |consumer| {
        if (std.mem.eql(u8, name, consumer)) return true;
    }
    return false;
}

/// Promoting walk for branch tables, run over the entry instructions and every discovered word
/// body in every AOT build.
///
/// A `match{` / `unchecked-match` / `case` / `cond` table parses to a single `.array` push_literal
/// immediately followed by the consuming `call_word`, so the walk promotes the quotations buried
/// in an array literal only when the next instruction calls one of those combinators.
///
/// An arm left uncompiled would drop to the interpreter at dispatch, where a metadata-only image
/// no-ops its callees, so the arms must compile with their callees discovered.
///
/// Bare arrays with no consuming call are left alone; promoting arbitrary word-body composites
/// regressed once, as documented on the call site in `discoverReachableWords`.
fn collectBranchTableQuotationsPromoting(
    ctx: *const Context,
    instrs: []const Instruction,
    caller_name: []const u8,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    quotation_bodies: *std.ArrayListUnmanaged([]const Instruction),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    composite_body_ptrs: *std.AutoHashMapUnmanaged(usize, void),
    pending_call_targets: *std.ArrayListUnmanaged(PendingCallTarget),
    quotation_path: *std.ArrayListUnmanaged(u32),
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    allocator: Allocator,
    path_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!void {
    for (instrs, 0..) |instr, idx| {
        switch (instr.op) {
            .push_literal => |val| switch (val) {
                .quotation => |q| try collectBranchTableQuotationsPromoting(ctx, q.instructions, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator),
                .array => {
                    if (idx + 1 >= instrs.len) continue;
                    const next_name = instrs[idx + 1].op.callTargetName() orelse continue;
                    if (!isBranchTableConsumer(next_name)) continue;
                    try collectQuotationsInValuePromoting(ctx, val, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
                },
                else => {},
            },
            else => {},
        }
    }
}

/// Entry point for the word-body-scoped dispatch-container promoting walk: scans `push_literal`
/// instructions for the two known runtime-image dispatch-container shapes (`.mutable_map` /
/// `.struct_instance` for the lint registry, `.hash` for lexer rules) and promotes the callees of
/// the quotation found at a named dispatch slot inside each. Deliberately does NOT trigger on bare
/// `.array` / `.vector` at this level -- branch tables are promoted separately by
/// `collectBranchTableQuotationsPromoting`, keyed on the consuming combinator call, and promoting
/// other bare word-body composites would repeat the regression documented on the call site in
/// `discoverReachableWords`.
fn collectDispatchContainerQuotationsPromoting(
    ctx: *const Context,
    instrs: []const Instruction,
    caller_name: []const u8,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    quotation_bodies: *std.ArrayListUnmanaged([]const Instruction),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    composite_body_ptrs: *std.AutoHashMapUnmanaged(usize, void),
    pending_call_targets: *std.ArrayListUnmanaged(PendingCallTarget),
    quotation_path: *std.ArrayListUnmanaged(u32),
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    allocator: Allocator,
    path_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .push_literal => |val| switch (val) {
                .quotation => |q| try collectDispatchContainerQuotationsPromoting(ctx, q.instructions, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator),
                .mutable_map, .struct_instance, .hash => try walkDispatchContainerValue(ctx, val, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator),
                else => {},
            },
            else => {},
        }
    }
}

/// Recurse through a value reached from a dispatch-container entry point. `.array` / `.vector` /
/// `.mutable_map` are walked as pure pass-through, since the lint registry's `.mutable_map` "rules:"
/// entry is an `.array` of `.struct_instance` values. A `.struct_instance` promotes only its `check`
/// field if that field is a quotation (other fields are recursed into as pass-through, in case a
/// future field holds a nested container, but never promoted); a `.hash` promotes only its `match`
/// entry under the same rule. This is the named-slot-keying restriction: a quotation at any other
/// field or key is left alone, even though today `check` and `match` happen to be each container's
/// only quotation-valued slot.
fn walkDispatchContainerValue(
    ctx: *const Context,
    val: Value,
    caller_name: []const u8,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    quotation_bodies: *std.ArrayListUnmanaged([]const Instruction),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    composite_body_ptrs: *std.AutoHashMapUnmanaged(usize, void),
    pending_call_targets: *std.ArrayListUnmanaged(PendingCallTarget),
    quotation_path: *std.ArrayListUnmanaged(u32),
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    allocator: Allocator,
    path_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!void {
    switch (val) {
        .array => |arr| {
            for (arr.items) |elem| try walkDispatchContainerValue(ctx, elem, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
        },
        .vector => |v| {
            for (v.list.items) |elem| try walkDispatchContainerValue(ctx, elem, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
        },
        .mutable_map => |m| {
            var it = m.map.iterator();
            while (it.next()) |entry| try walkDispatchContainerValue(ctx, entry.value_ptr.*, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
        },
        .struct_instance => |si| {
            for (si.struct_type.fields, 0..) |field_name, i| {
                if (std.mem.eql(u8, field_name, dispatch_struct_field_check)) {
                    if (si.fields[i] == .quotation) {
                        try promoteQuotationCallees(ctx, si.fields[i].quotation, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
                    }
                } else {
                    try walkDispatchContainerValue(ctx, si.fields[i], caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
                }
            }
        },
        .hash => |h| {
            var it = h.map.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, dispatch_hash_key_match)) {
                    if (entry.value_ptr.* == .quotation) {
                        try promoteQuotationCallees(ctx, entry.value_ptr.*.quotation, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
                    }
                } else {
                    try walkDispatchContainerValue(ctx, entry.value_ptr.*, caller_name, worklist, seen, quotation_bodies, quotation_seen, composite_body_ptrs, pending_call_targets, quotation_path, diagnostics, artifact_class, allocator, path_allocator);
                }
            }
        },
        else => {},
    }
}

/// Collect every quotation nested inside a body that was itself reached through a
/// composite. Unlike `collectCompositeQuotations`, which descends into quotation
/// literals only to find composites, this collects the quotation literals too,
/// because a body buried in a composite was never visited by the main BFS.
fn collectNestedQuotations(
    instrs: []const Instruction,
    quotation_bodies: *std.ArrayListUnmanaged([]const Instruction),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    composite_body_ptrs: *std.AutoHashMapUnmanaged(usize, void),
    allocator: Allocator,
) Allocator.Error!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .push_literal => |val| try collectQuotationsInValue(val, quotation_bodies, quotation_seen, composite_body_ptrs, allocator),
            else => {},
        }
    }
}

/// Detect-only mirror of `collectCompositeQuotations`.
///
/// Descend to each composite-buried quotation and classify its callees instead of collecting its body.
/// Never seeds the BFS worklist, so it cannot repeat the compile-set regression that scoped the promoting walks.
fn detectInterpretedReach(
    ctx: *const Context,
    instrs: []const Instruction,
    caller_name: []const u8,
    source_file: ?[]const u8,
    prelude_words: *const std.StringHashMapUnmanaged(void),
    discovered_names: *const std.StringHashMapUnmanaged(void),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    callee_seen: *std.StringHashMapUnmanaged(void),
    violations: *std.ArrayListUnmanaged(ir_codegen.InterpretedReachViolation),
    allocator: Allocator,
) Allocator.Error!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .push_literal => |val| switch (val) {
                .quotation => |q| try detectInterpretedReach(ctx, q.instructions, caller_name, source_file, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator),
                .array, .hash, .vector, .mutable_map, .struct_instance => try detectReachInValue(ctx, val, caller_name, source_file, instr.line, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator),
                else => {},
            },
            else => {},
        }
    }
}

/// Recurse through a composite literal Value to each buried `.quotation`,
/// deduped by pointer identity, and classify that body's callees. `line` is
/// the burying composite literal's source line, carried onto each violation.
fn detectReachInValue(
    ctx: *const Context,
    val: Value,
    caller_name: []const u8,
    source_file: ?[]const u8,
    line: usize,
    prelude_words: *const std.StringHashMapUnmanaged(void),
    discovered_names: *const std.StringHashMapUnmanaged(void),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    callee_seen: *std.StringHashMapUnmanaged(void),
    violations: *std.ArrayListUnmanaged(ir_codegen.InterpretedReachViolation),
    allocator: Allocator,
) Allocator.Error!void {
    switch (val) {
        .quotation => |q| {
            const gop = try quotation_seen.getOrPut(allocator, @intFromPtr(q.instructions.ptr));
            if (!gop.found_existing) {
                try detectBuriedCallees(ctx, q.instructions, caller_name, source_file, line, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator);
            }
        },
        .array => |arr| {
            for (arr.items) |elem| try detectReachInValue(ctx, elem, caller_name, source_file, line, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator);
        },
        .hash => |h| {
            var it = h.map.iterator();
            while (it.next()) |entry| try detectReachInValue(ctx, entry.value_ptr.*, caller_name, source_file, line, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator);
        },
        .vector => |v| {
            for (v.list.items) |elem| try detectReachInValue(ctx, elem, caller_name, source_file, line, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator);
        },
        .mutable_map => |m| {
            var it = m.map.iterator();
            while (it.next()) |entry| try detectReachInValue(ctx, entry.value_ptr.*, caller_name, source_file, line, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator);
        },
        .struct_instance => |si| {
            for (si.fields) |field| try detectReachInValue(ctx, field, caller_name, source_file, line, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator);
        },
        else => {},
    }
}

/// Classify every callee of a composite-buried quotation body, descending
/// nested quotation literals and deeper composites, since a buried body was
/// never visited by the main BFS.
///
/// A callee is a violation when it is not a prelude word and resolves to a
/// compound word outside the discovered set: it will carry no compiled
/// dispatch, so an interpreted call runs its empty metadata-image body. A
/// prelude callee is fine (the linked interpreter reloads the prelude), a
/// native lives in the binary, and an unresolvable name fails runtime lookup
/// loudly rather than silently.
fn detectBuriedCallees(
    ctx: *const Context,
    instrs: []const Instruction,
    caller_name: []const u8,
    source_file: ?[]const u8,
    line: usize,
    prelude_words: *const std.StringHashMapUnmanaged(void),
    discovered_names: *const std.StringHashMapUnmanaged(void),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    callee_seen: *std.StringHashMapUnmanaged(void),
    violations: *std.ArrayListUnmanaged(ir_codegen.InterpretedReachViolation),
    allocator: Allocator,
) Allocator.Error!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .call_word, .call_word_direct => {
                const name = instr.op.callTargetName().?;
                if (prelude_words.contains(name)) continue;
                switch (classifyCallee(ctx, name)) {
                    .compound_name => {
                        if (discovered_names.contains(name)) continue;
                        const gop = try callee_seen.getOrPut(allocator, name);
                        if (gop.found_existing) continue;
                        try violations.append(allocator, .{
                            .callee_name = name,
                            .caller_word = caller_name,
                            .source_file = source_file,
                            .line = line,
                        });
                    },
                    .native_name, .unresolved => {},
                }
            },
            .push_literal => |val| switch (val) {
                .quotation => |q| {
                    const gop = try quotation_seen.getOrPut(allocator, @intFromPtr(q.instructions.ptr));
                    if (!gop.found_existing) {
                        try detectBuriedCallees(ctx, q.instructions, caller_name, source_file, line, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator);
                    }
                },
                .array, .hash, .vector, .mutable_map, .struct_instance => try detectReachInValue(ctx, val, caller_name, source_file, line, prelude_words, discovered_names, quotation_seen, callee_seen, violations, allocator),
                else => {},
            },
        }
    }
}

/// Walk every user `method{` dispatch entry registered for a generic word,
/// treating each method body as if it were a nested quotation literal inside
/// the polymorphic word. This serves two purposes:
///
/// - It adds every reached generic's method bodies to the freeze-time
///   quotation-compilation manifest, so they compile at build time and can be
///   serialized and replayed into the runtime dispatch table.
/// - It extends indirect call-coverage to those bodies: a banned native
///   reachable only through a method body is flagged with the same diagnostic
///   as a direct `call_word`.
///
/// Scope and limits:
///
/// - Only words carrying the `generic` marker participate. Native polymorphic
///   primitives like `+` keep their existing direct-call treatment; the BFS
///   records them in `native_defs` and never reaches this helper. Generics with
///   a non-empty default body participate too; their default body is collected
///   separately by `collectCallWords` on the word body, and this helper adds the
///   method bodies on top.
/// - All entries for the generic's `dispatch_id` are walked, regardless of how
///   many methods are registered.
/// - Only `.quotation` bodies are walked. `.native_fn` and `.host_callback`
///   entries are skipped: native dispatch is already present at runtime, and
///   function-pointer bodies have no serializable instruction stream.
///
/// The synthetic `quotation_path = [ DISPATCH_PATH_SENTINEL, ... ]` encoding
/// stays unambiguous because `DISPATCH_PATH_SENTINEL` is `maxInt(u32)`, never a
/// real quotation-literal index; this holds whether or not the polymorphic
/// word's own body is empty.
fn walkDispatchMethodBodies(
    ctx: *const Context,
    def: WordDefinition,
    polymorphic_name: []const u8,
    worklist: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    quotation_bodies: *std.ArrayListUnmanaged([]const Instruction),
    quotation_seen: *std.AutoHashMapUnmanaged(usize, void),
    method_body_ptrs: *std.AutoHashMapUnmanaged(usize, void),
    pending_call_targets: *std.ArrayListUnmanaged(PendingCallTarget),
    diagnostics: *FreezeDiagnostics,
    artifact_class: ArtifactClass,
    allocator: Allocator,
    path_allocator: Allocator,
) (Allocator.Error || error{ DisallowedDynamicFeature, DisallowedNativeInterpreterDependency })!void {
    if (!hasGenericMarker(def)) return;

    const pairs = try ctx.dispatchEntriesForId(def.dispatch_id, allocator);
    defer allocator.free(pairs);

    for (pairs) |pair| {
        const q_instrs = switch (pair.entry.body) {
            .quotation => |q| q.instructions,
            .native_fn, .host_callback => continue,
        };

        // Dedup the method body the same way collectCallWords dedups
        // nested quotations, so a re-entry through the polymorphic word's
        // worklist hit does not redo the walk.
        const ptr_key = @intFromPtr(q_instrs.ptr);
        const qgop = try quotation_seen.getOrPut(allocator, ptr_key);
        if (qgop.found_existing) continue;
        try quotation_bodies.append(allocator, q_instrs);
        try method_body_ptrs.put(allocator, ptr_key, {});

        var synth_path = std.ArrayListUnmanaged(u32){};
        defer synth_path.deinit(allocator);
        try synth_path.append(allocator, DISPATCH_PATH_SENTINEL);

        try collectCallWords(
            ctx,
            q_instrs,
            polymorphic_name,
            worklist,
            seen,
            quotation_bodies,
            quotation_seen,
            pending_call_targets,
            &synth_path,
            diagnostics,
            artifact_class,
            allocator,
            path_allocator,
        );
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
            .compound, .literal => return false,
        }
    }
    if (ctx.resolveQualifiedModuleWord(name)) |mod_word| {
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

/// Present a `.literal`-actioned word as a one-instruction `.compound` word,
/// exactly matching what a plain-value `name: swap ;` binding would have
/// produced before the `.literal` variant existed. AOT discovery and codegen
/// have no first-class `.literal` support yet, so every discovery site
/// normalizes through this helper before storing a word into the discovered
/// set, keeping AOT build output unchanged regardless of which
/// `WordDefinition.action` variant a word's binding happens to use.
fn literalWordAsCompound(allocator: Allocator, word: WordDefinition, value: Value) Allocator.Error!WordDefinition {
    const instrs = try allocator.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .push_literal = value }, .line = 0 };
    var compound_word = word;
    compound_word.action = .{ .compound = instrs };
    return compound_word;
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
    if (ctx.resolveQualifiedModuleWord(call_name)) |mod_word| {
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
        .literal => |v| {
            if (word.stack_effect == null) return;
            try discovered.names.append(allocator, call_name);
            try discovered.defs.append(allocator, try literalWordAsCompound(allocator, word, v));
        },
    }
}

/// Return the first `dynamic-*` marker on `def` whose policy bans the
/// current AOT artifact class, or null. Detection is by marker identity,
/// so it survives natives being renamed in the registry: the policy
/// follows the function, not its name. The policy table itself lives in
/// `primitives/markers.zig` next to the marker constants it governs.
fn bannedDynamicMarker(def: WordDefinition, class: ArtifactClass) ?*const value_mod.Marker {
    for (def.markers) |mk| {
        if (markers_mod.isDynamicMarkerBannedIn(mk, class)) return mk;
    }
    return null;
}

/// Resolve `name` against the current dictionary (direct lookup, then
/// qualified-module lookup) and return any banned `dynamic-*` marker on
/// the resolved callee. Returns null when the name is unresolved or the
/// resolved word carries no banned markers. Mirrors the shape of
/// `isInterpreterDependentNative`.
fn bannedDynamicFeatureForCall(ctx: *const Context, name: []const u8, class: ArtifactClass) ?*const value_mod.Marker {
    if (ctx.lookupWord(name)) |def| {
        return bannedDynamicMarker(def, class);
    }
    if (ctx.resolveQualifiedModuleWord(name)) |mod_word| {
        return bannedDynamicMarker(wordDefFromModuleWord(name, mod_word), class);
    }
    return null;
}

/// Walk `freeze_result.call_targets` to find every compound word that
/// transitively calls any native carrying `target_marker`. Returns one
/// `ReachChain` per reached compound, sorted by chain length (shortest first)
/// then by the outermost word name (alphabetically). Each chain includes the
/// word names from the outermost caller through the direct native caller, plus
/// the native name itself.
///
/// Run freeze with `.interpreter` artifact class so no bans fire; this lets
/// the function surface dynamic-feature usage in programs that would be
/// rejected under stricter classes.
pub fn computeReachabilityForMarker(
    freeze_result: *const FreezeResult,
    ctx: *const Context,
    target_marker: *const value_mod.Marker,
    allocator: Allocator,
) Allocator.Error![]ReachChain {
    // Build word_id → AotWordDesc for name lookup.
    var id_to_word = std.AutoHashMapUnmanaged(u32, *const AotWordDesc){};
    defer id_to_word.deinit(allocator);
    for (freeze_result.words) |*w| {
        try id_to_word.put(allocator, w.word_id, w);
    }

    // Find native word IDs that carry the target marker.
    var target_natives = std.AutoHashMapUnmanaged(u32, []const u8){}; // id → native name
    defer target_natives.deinit(allocator);
    for (freeze_result.words) |w| {
        if (!w.is_native) continue;
        const has_target = blk: {
            if (ctx.lookupWord(w.name)) |def| {
                for (def.markers) |mk| {
                    if (mk == target_marker) break :blk true;
                }
            } else if (ctx.resolveQualifiedModuleWord(w.name)) |mod_word| {
                for (mod_word.markers) |mk| {
                    if (mk == target_marker) break :blk true;
                }
            }
            break :blk false;
        };
        if (has_target) try target_natives.put(allocator, w.word_id, w.name);
    }

    if (target_natives.count() == 0) return &.{};

    // Direct callers: compound words that call a target native.
    // Stores the first native name seen for each caller (representative).
    var direct_callers = std.AutoHashMapUnmanaged(u32, []const u8){};
    defer direct_callers.deinit(allocator);
    for (freeze_result.call_targets) |entry| {
        switch (entry.resolved) {
            .native => |nid| {
                if (target_natives.get(nid)) |native_name| {
                    if (!direct_callers.contains(entry.caller_word_id)) {
                        try direct_callers.put(allocator, entry.caller_word_id, native_name);
                    }
                }
            },
            else => {},
        }
    }

    if (direct_callers.count() == 0) return &.{};

    // Reverse compound call graph: compound_id → list of compound word ids that call it.
    var reverse_graph = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)){};
    defer {
        var it = reverse_graph.iterator();
        while (it.next()) |rev_entry| rev_entry.value_ptr.deinit(allocator);
        reverse_graph.deinit(allocator);
    }
    for (freeze_result.call_targets) |entry| {
        switch (entry.resolved) {
            .compound => |cid| {
                const gop = try reverse_graph.getOrPut(allocator, cid);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(allocator, entry.caller_word_id);
            },
            else => {},
        }
    }

    // BFS from direct callers through the reverse graph. Track parent pointers
    // so chains can be reconstructed. parent_map[id] = (parent_id, native_name).
    // A direct caller has parent = null; native_name is the native it calls.
    const ParentEntry = struct {
        parent: ?u32,
        native_name: ?[]const u8,
    };
    var parent_map = std.AutoHashMapUnmanaged(u32, ParentEntry){};
    defer parent_map.deinit(allocator);

    var bfs_queue = std.ArrayListUnmanaged(u32){};
    defer bfs_queue.deinit(allocator);

    var dc_it = direct_callers.iterator();
    while (dc_it.next()) |dc_entry| {
        const word_id = dc_entry.key_ptr.*;
        try parent_map.put(allocator, word_id, .{ .parent = null, .native_name = dc_entry.value_ptr.* });
        try bfs_queue.append(allocator, word_id);
    }

    var qi: usize = 0;
    while (qi < bfs_queue.items.len) : (qi += 1) {
        const current_id = bfs_queue.items[qi];
        if (reverse_graph.get(current_id)) |callers| {
            for (callers.items) |caller_id| {
                if (parent_map.contains(caller_id)) continue;
                try parent_map.put(allocator, caller_id, .{ .parent = current_id, .native_name = null });
                try bfs_queue.append(allocator, caller_id);
            }
        }
    }

    // Build ReachChain for every word in parent_map.
    var chains = std.ArrayListUnmanaged(ReachChain){};
    errdefer {
        for (chains.items) |c| c.deinit(allocator);
        chains.deinit(allocator);
    }

    var pm_it = parent_map.iterator();
    while (pm_it.next()) |pm_entry| {
        const word_id = pm_entry.key_ptr.*;

        // Walk parent chain: word_id → parent → ... → direct_caller (no parent).
        var chain_ids = std.ArrayListUnmanaged(u32){};
        defer chain_ids.deinit(allocator);

        var cur = word_id;
        while (true) {
            try chain_ids.append(allocator, cur);
            const pe = parent_map.get(cur).?;
            const p = pe.parent orelse break;
            cur = p;
        }
        // chain_ids: [word_id, ..., direct_caller_id], already in call order
        // (outer caller first, direct caller last).

        // native_name is on the direct caller (last element).
        const direct_caller_id = chain_ids.items[chain_ids.items.len - 1];
        const native_name = parent_map.get(direct_caller_id).?.native_name orelse continue;

        // Convert word IDs to names.
        var compound_chain = try allocator.alloc([]const u8, chain_ids.items.len);
        errdefer allocator.free(compound_chain);
        var all_found = true;
        for (chain_ids.items, 0..) |cid, i| {
            const desc = id_to_word.get(cid) orelse {
                all_found = false;
                break;
            };
            compound_chain[i] = desc.name;
        }
        if (!all_found) {
            allocator.free(compound_chain);
            continue;
        }
        try chains.append(allocator, .{
            .compound_chain = compound_chain,
            .native_name = native_name,
        });
    }

    // Sort by chain length ascending, then by outermost name alphabetically.
    std.mem.sort(ReachChain, chains.items, {}, struct {
        fn lessThan(_: void, a: ReachChain, b: ReachChain) bool {
            if (a.compound_chain.len != b.compound_chain.len)
                return a.compound_chain.len < b.compound_chain.len;
            return std.mem.lessThan(u8, a.compound_chain[0], b.compound_chain[0]);
        }
    }.lessThan);

    return chains.toOwnedSlice(allocator);
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

/// If `def` is a dispatch-only generic whose dispatch table holds exactly one method, and that method is a
/// `.quotation` body, return that body so the AOT freeze pipeline can bind it directly as the word's compiled
/// body.
///
/// Returns null otherwise.
///
/// Devirtualization turns the single-method dispatch into a direct, statically-compiled call. The replacement
/// body still carries the `push_literal(.struct_type)` / `push_literal(.type_val)` instructions the dispatch
/// wrapper used, so AOT type-value slot routing produces the runtime-image descriptor pointer; downstream
/// natives like `native.struct-field-get` compare descriptor identity through that pointer and behave correctly
/// across the process boundary.
///
/// These are known scenarios under which this devirtualization is unsafe as-is:
///
/// - This only fires when there is exactly one method at freeze time. Multi-method generics still take the
///   runtime-dispatch path and are subject to the existing dispatch-callback machinery.
/// - Assumes the freeze-time dispatch table is final. If user code installs additional methods after freeze
///   (e.g., a future `define-method` primitive, a hot-reload of a module redefining a generic, or a dynamically-
///   constructed struct registering itself at runtime), the devirtualized binary will keep executing the freeze-
///   time method regardless of the runtime type. Today there is no such path: struct, virtual, and enum generators
///   install their methods at parse time only, and the AOT pipeline bans dynamic-define markers through the
///   `bannedDynamicMarker`. If any of those constraints ever relax, this helper must consult the same banned-
///   marker policy or be disabled for that generic.
/// - Only walks `.quotation` bodies. `.native_fn` and `.host_callback` entries do not have a serializable
///   instruction stream and must keep the dispatch-callback path. The dictionary scan needed to recover a
///   `WordDefinition` from a raw `NativeFn` pointer is deliberately out of scope here.
/// - The PIC interpreter path remains the source of truth in non-AOT modes. JIT-compiled callers still cache
///   method bodies in the PIC table and bail to the dispatch callback on a type-tag miss; this helper only
///   affects what AOT chooses to emit when freezing.
///
/// Devirtualized single-method body together with the originating dispatch entry's provenance, when present.
/// The provenance parent is what AOT codegen needs to format the qualified asm-name override (`<parent>/<name>`)
/// on the devirtualized forward declaration.
const DevirtualizedMethod = struct {
    body: []const Instruction,
    provenance: ?dispatch_mod.DispatchProvenance = null,
};

fn devirtualizeSingleMethod(
    ctx: ?*Context,
    def: WordDefinition,
    allocator: Allocator,
) Allocator.Error!?DevirtualizedMethod {
    if (!isDispatchOnlyGeneric(def)) return null;
    const ictx = ctx orelse return null;
    const pairs = try ictx.dispatchEntriesForId(def.dispatch_id, allocator);
    defer allocator.free(pairs);
    if (pairs.len != 1) return null;
    return switch (pairs[0].entry.body) {
        .quotation => |q| .{ .body = q.instructions, .provenance = pairs[0].entry.provenance },
        .native_fn, .host_callback => null,
    };
}

/// Returns the dispatch-entry-level provenance for a dispatch-only generic when all registered methods
/// agree on parent and at least one entry actually carries provenance. Used by AOT freeze for the non-
/// devirtualized branch, where multiple methods are registered but the word still routes through
/// compiled output and benefits from a qualified asm-name when the parent is unambiguous.
///
/// Returns null when parents disagree, when no entry carries provenance, when ctx is absent, or when
/// the word is not dispatch-only.
fn unanimousDispatchProvenanceParent(
    ctx: ?*Context,
    def: WordDefinition,
    allocator: Allocator,
) Allocator.Error!?[]const u8 {
    if (!isDispatchOnlyGeneric(def)) return null;
    const ictx = ctx orelse return null;
    const pairs = try ictx.dispatchEntriesForId(def.dispatch_id, allocator);
    defer allocator.free(pairs);
    var chosen: ?[]const u8 = null;
    for (pairs) |pair| {
        const prov = pair.entry.provenance orelse continue;
        if (prov.parent.len == 0) continue;
        if (chosen) |c| {
            if (!std.mem.eql(u8, c, prov.parent)) return null;
        } else {
            chosen = prov.parent;
        }
    }
    return chosen;
}

/// Provenance attached to each reachable quotation literal: the source
/// file of the defining word, the defining word's name (or
/// `__entry__` for top-level literals), and the line / column of the
/// opening `[` in source. The line / column come from the outer
/// `push_literal` instruction that wraps the `.quotation` value;
/// `src/parser.zig` writes that instruction with the `[` token's
/// position, so this is the bracket's position, not the first body
/// token's.
pub const QuotationSourceEntry = struct {
    source_file: []const u8,
    defining_word: []const u8,
    line: usize,
    column: usize,
};

/// Walk `instrs` and record every nested quotation literal under the
/// given `source_file` and `defining_word` in `map`. The discovery BFS
/// only recurses into `.quotation` literals (see `collectCallWords`);
/// this map follows the same shape so every reachable quotation body
/// that ends up in `discovered.quotation_bodies` finds a corresponding
/// entry.
fn mapQuotationSources(
    instrs: []const Instruction,
    source_file: []const u8,
    defining_word: []const u8,
    map: *std.AutoHashMapUnmanaged(usize, QuotationSourceEntry),
    allocator: Allocator,
) Allocator.Error!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .push_literal => |val| switch (val) {
                .quotation => |q| {
                    const gop = try map.getOrPut(allocator, @intFromPtr(q.instructions.ptr));
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{
                            .source_file = source_file,
                            .defining_word = defining_word,
                            .line = instr.line,
                            .column = instr.column,
                        };
                    }
                    try mapQuotationSources(q.instructions, source_file, defining_word, map, allocator);
                },
                else => {},
            },
            .call_word, .call_word_direct => {},
        }
    }
}

/// Assign word IDs and build the AotWordDesc array. When `ctx` is
/// provided, PIC snapshots are captured from the interpreter's cache
/// and stored on each compound word descriptor.
fn buildAotDescs(
    entry_instrs: []const Instruction,
    entry_file: []const u8,
    discovered: *const DiscoveredWords,
    pending_call_targets: []const PendingCallTarget,
    prelude_words: *const std.StringHashMapUnmanaged(void),
    ctx: ?*Context,
    allocator: Allocator,
) Allocator.Error!FreezeResult {
    var words = std.ArrayListUnmanaged(AotWordDesc){};
    var skipped = std.ArrayListUnmanaged([]const u8){};
    var next_id: u32 = 0;

    const entry_source_file: ?[]const u8 = if (entry_file.len > 0) entry_file else null;
    const entry_source_line: usize = if (entry_instrs.len > 0) entry_instrs[0].line else 1;

    // Entry word gets ID 0
    const entry_word_id = next_id;
    next_id += 1;
    try words.append(allocator, .{
        .name = "__entry__",
        .instructions = entry_instrs,
        .input_count = 0,
        .output_count = 0,
        .word_id = entry_word_id,
        .source_file = entry_source_file,
        .source_line = entry_source_line,
    });

    // Assign IDs to discovered words
    for (discovered.names.items, discovered.defs.items) |name, def| {
        const effect = def.stack_effect orelse {
            try skipped.append(allocator, name);
            continue;
        };
        const id = next_id;
        next_id += 1;

        // Generic words with empty compound bodies (struct/virtual/enum setters, getters, predicates)
        // are runtime-dispatched on type; their compiled body would either fail to satisfy the declared
        // effect or silently no-op. When the dispatch table holds exactly one method, bind that
        // method's body directly as the word's compiled body
        //
        // See `DevirtualizeSingleMethod` for the safety conditions this relies on.
        //
        // Otherwise mark the word like a native so the AOT runtime takes the dispatch-callback path.
        //
        // Without devirtualization, the AOT binary would have neither a compiled body for the word nor
        // a runtime dictionary entry to look up at call time, so the dispatch callback would fail with
        // a bare "unknown runtime error" the first time the word ran.
        if (isDispatchOnlyGeneric(def)) {
            if (try devirtualizeSingleMethod(ctx, def, allocator)) |devirt| {
                const parent: ?[]const u8 = blk: {
                    if (def.provenance) |p| if (p.parent.len > 0) break :blk p.parent;
                    if (devirt.provenance) |p| if (p.parent.len > 0) break :blk p.parent;
                    break :blk null;
                };
                try words.append(allocator, .{
                    .name = name,
                    .instructions = devirt.body,
                    .input_count = @intCast(effect.concreteInputCount()),
                    .output_count = @intCast(effect.concreteOutputCount()),
                    .word_id = id,
                    .is_prelude = prelude_words.contains(name),
                    .stack_effect = effect,
                    .never_returns = hasNeverReturnsMarker(def),
                    .source_file = def.source_file,
                    .source_line = def.source_line,
                    .is_generated = def.provenance != null or devirt.provenance != null,
                    .parent = parent,
                });
                continue;
            }
            const word_provenance_parent: ?[]const u8 = blk: {
                if (def.provenance) |p| if (p.parent.len > 0) break :blk p.parent;
                break :blk null;
            };
            const dispatch_parent = if (word_provenance_parent == null)
                try unanimousDispatchProvenanceParent(ctx, def, allocator)
            else
                null;
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
                .source_file = def.source_file,
                .source_line = def.source_line,
                .is_generated = def.provenance != null or dispatch_parent != null,
                .parent = word_provenance_parent orelse dispatch_parent,
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
        const compound_parent: ?[]const u8 = blk: {
            if (def.provenance) |p| if (p.parent.len > 0) break :blk p.parent;
            break :blk null;
        };
        const bounded = dispatch_helpers.boundedDispatchFor(&effect, def.markers, name);
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
            .source_file = def.source_file,
            .source_line = def.source_line,
            .is_generated = def.provenance != null,
            .parent = compound_parent,
            .dispatch_id = def.dispatch_id,
            .is_generic = hasGenericMarker(def),
            .bounded_dispatch_id = if (bounded != null) def.dispatch_id else 0,
            .bounded_constraint = if (bounded) |b| b.constraint else null,
            .bounded_arity = if (bounded) |b| b.arity else .unary,
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
                .source_file = def.source_file,
                .source_line = def.source_line,
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
            .source_file = def.source_file,
            .source_line = def.source_line,
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

    // Build a map from quotation-body pointer to the source file of the
    // word whose body contains the quotation (transitively for nested
    // quotations), plus the defining word's name and the opening `[`
    // position. Used to attach `#line` directives and asm-name
    // overrides to emitted quotation C functions in AOT mode. Walking
    // entry instructions and every discovered compound body once
    // covers every reachable quotation literal, mirroring the BFS
    // discovery walk.
    var quotation_source_map = std.AutoHashMapUnmanaged(usize, QuotationSourceEntry){};
    defer quotation_source_map.deinit(allocator);
    if (entry_source_file) |sf| {
        try mapQuotationSources(entry_instrs, sf, "__entry__", &quotation_source_map, allocator);
    }
    for (discovered.names.items, discovered.defs.items) |name, def| {
        if (def.action != .compound) continue;
        const sf = def.source_file orelse continue;
        try mapQuotationSources(def.action.compound, sf, name, &quotation_source_map, allocator);
    }

    // Sequential ID for quot descriptors
    var quotations = std.ArrayListUnmanaged(AotQuotationDesc){};
    var next_q_id: u32 = 0;
    for (discovered.quotation_bodies.items) |body| {
        const id = next_q_id;
        next_q_id += 1;
        const c_name = try std.fmt.allocPrint(allocator, "onez_q_{d}", .{id});
        const entry = quotation_source_map.get(@intFromPtr(body.ptr));
        try quotations.append(allocator, .{
            .quotation_id = id,
            .instructions = body,
            .c_name = c_name,
            .inferred_effect = ir_codegen.inferQuotationEffect(body, resolver) catch null,
            .source_file = if (entry) |e| e.source_file else null,
            .source_line = if (entry) |e| e.line else 0,
            .source_column = if (entry) |e| e.column else 0,
            .defining_word = if (entry) |e| e.defining_word else null,
            .is_method_body = discovered.method_body_ptrs.contains(@intFromPtr(body.ptr)),
            .from_composite = discovered.composite_body_ptrs.contains(@intFromPtr(body.ptr)),
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

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &.{}, &prelude_words, null, allocator);
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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &.{}, &prelude_words, &ctx, allocator);

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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &.{}, &prelude_words, null, allocator);
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
        .interpreter_free_aot,
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

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .runtime_image_aot, allocator, allocator);

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
        .runtime_image_aot,
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

test "collectCallWords permits 'compile!' in interpreter class" {
    try expectInterpreterClassPermits("compile!", &markers_mod.dynamic_compile_marker);
}

test "collectCallWords permits '>quotation' in interpreter class" {
    try expectInterpreterClassPermits(">quotation", &markers_mod.dynamic_quotation_construction_marker);
}

test "collectCallWords permits 'eval-string' in interpreter class" {
    try expectInterpreterClassPermits("eval-string", &markers_mod.dynamic_eval_marker);
}

test "collectCallWords permits 'load' in interpreter class" {
    try expectInterpreterClassPermits("load", &markers_mod.dynamic_load_marker);
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
        .interpreter_free_aot,
        allocator,
        allocator,
    ));
    try testing.expect(diagnostics.fatal_dynamic_feature != null);
    try testing.expectEqualStrings(caller, diagnostics.fatal_dynamic_feature.?.caller_name);
    try testing.expectEqualStrings(feature, diagnostics.fatal_dynamic_feature.?.feature_name);
}

/// Mirror of `expectInterpreterFreeRejection` for the `interpreter`
/// class: the marker policy allows every dynamic-* capability, so the
/// same call that triggers a diagnostic in interpreter-free mode must
/// complete without flagging the feature.
fn expectInterpreterClassPermits(feature: []const u8, marker: *const value_mod.Marker) !void {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

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

    try collectCallWords(
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
        .interpreter,
        allocator,
        allocator,
    );
    try testing.expect(diagnostics.fatal_dynamic_feature == null);
    try testing.expect(diagnostics.fatal_native_interpreter_dependency == null);
    try testing.expectEqual(@as(usize, 1), worklist.items.len);
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

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &.{}, &prelude_words, null, allocator);
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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &.{}, &prelude_words, null, allocator);
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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &.{}, &prelude_words, null, allocator);
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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &.{}, &prelude_words, null, allocator);
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
        .interpreter_free_aot,
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

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .runtime_image_aot, allocator, allocator);

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

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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
        .interpreter_free_aot,
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

    try collectCallWords(&ctx, instrs, "user-entry", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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
        .interpreter_free_aot,
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

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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

    try collectCallWords(&ctx, instrs, "__entry__", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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

    try collectCallWords(&ctx, outer_instrs, "outer", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

    try testing.expectEqual(@as(usize, 1), pending_call_targets.items.len);
    const entry = pending_call_targets.items[0];
    try testing.expectEqualStrings("outer", entry.caller_name);
    try testing.expectEqual(@as(u32, 0), entry.instruction_index);
    try testing.expectEqual(@as(usize, 1), entry.quotation_path.len);
    // Outer instruction index 1 is the quotation literal we recursed into.
    try testing.expectEqual(@as(u32, 1), entry.quotation_path[0]);
    try testing.expectEqualStrings("inner-noop", entry.pending.native_name);
}

test "collectCompositeQuotations collects a quotation nested in an array literal" {
    const allocator = testing.allocator;

    // A `case` / `cond` branch table parses to a single `.array` push_literal;
    // its branch quotation is invisible to the main BFS and is found only by
    // the composite walk.
    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "inner-noop" }, .line = 1 },
    };
    const elems = [_]Value{
        .{ .quotation = .{ .instructions = inner_instrs } },
    };
    var elems_arr = value_mod.Array{ .header = undefined, .items = &elems, .storage = .static };
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &elems_arr } }, .line = 1 },
    };

    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);

    try collectCompositeQuotations(outer_instrs, &quotation_bodies, &quotation_seen, &composite_body_ptrs, allocator);

    // The nested quotation body joins the compilation manifest, deduped by
    // instruction-pointer identity.
    try testing.expectEqual(@as(usize, 1), quotation_bodies.items.len);
    try testing.expectEqual(@intFromPtr(inner_instrs.ptr), @intFromPtr(quotation_bodies.items[0].ptr));
}

test "collectCompositeQuotations collects a quotation nested in a hash literal" {
    const allocator = testing.allocator;

    // The lexer's `H{ ... match: [ ... ] }` rules are a single `.hash`; the
    // dispatched quotation is stored as a value under the `match:` symbol key.
    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "inner-noop" }, .line = 1 },
    };
    const hash = try value_mod.HashTable.create(allocator);
    defer hash.header.release();
    try hash.map.put(allocator, try allocator.dupe(u8, "match"), .{ .quotation = .{ .instructions = inner_instrs } });
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = hash } }, .line = 1 },
    };

    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);

    try collectCompositeQuotations(outer_instrs, &quotation_bodies, &quotation_seen, &composite_body_ptrs, allocator);

    try testing.expectEqual(@as(usize, 1), quotation_bodies.items.len);
    try testing.expectEqual(@intFromPtr(inner_instrs.ptr), @intFromPtr(quotation_bodies.items[0].ptr));
}

test "collectCompositeQuotations collects a quotation nested in a nested composite" {
    const allocator = testing.allocator;

    // A quotation buried two levels deep (a hash whose value is an array
    // holding the quotation) proves the walk is fully recursive, not one level.
    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "inner-noop" }, .line = 1 },
    };
    const arr_elems = [_]Value{
        .{ .quotation = .{ .instructions = inner_instrs } },
    };
    // The hash releases its values at destroy, so the array wrapper needs an
    // initialized header; the static no-op destroy leaves the struct to the
    // deferred free.
    const arr_elems_arr = try value_mod.Array.createStatic(allocator, &arr_elems);
    defer allocator.destroy(arr_elems_arr);
    const hash = try value_mod.HashTable.create(allocator);
    defer hash.header.release();
    try hash.map.put(allocator, try allocator.dupe(u8, "match"), .{ .array = arr_elems_arr });
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = hash } }, .line = 1 },
    };

    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);

    try collectCompositeQuotations(outer_instrs, &quotation_bodies, &quotation_seen, &composite_body_ptrs, allocator);

    try testing.expectEqual(@as(usize, 1), quotation_bodies.items.len);
    try testing.expectEqual(@intFromPtr(inner_instrs.ptr), @intFromPtr(quotation_bodies.items[0].ptr));
}

test "collectCompositeQuotations does not collect a top-level quotation literal" {
    const allocator = testing.allocator;

    // A bare quotation literal (not inside a composite) is the main BFS's job,
    // not this pass's. Descending into it must only look for composites, never
    // collect the literal itself, so the two passes do not double-collect.
    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "inner-noop" }, .line = 1 },
    };
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_instrs } } }, .line = 1 },
    };

    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);

    try collectCompositeQuotations(outer_instrs, &quotation_bodies, &quotation_seen, &composite_body_ptrs, allocator);

    try testing.expectEqual(@as(usize, 0), quotation_bodies.items.len);
}

test "collectCompositeQuotations dedupes a quotation reached twice" {
    const allocator = testing.allocator;

    // The same body referenced by two array elements is collected once, under
    // the shared pointer-identity dedupe.
    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "inner-noop" }, .line = 1 },
    };
    const elems = [_]Value{
        .{ .quotation = .{ .instructions = inner_instrs } },
        .{ .quotation = .{ .instructions = inner_instrs } },
    };
    var elems_arr = value_mod.Array{ .header = undefined, .items = &elems, .storage = .static };
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &elems_arr } }, .line = 1 },
    };

    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);

    try collectCompositeQuotations(outer_instrs, &quotation_bodies, &quotation_seen, &composite_body_ptrs, allocator);

    try testing.expectEqual(@as(usize, 1), quotation_bodies.items.len);
}

test "collectCompositeQuotations collects a quotation nested in a mutable_map literal" {
    const allocator = testing.allocator;

    // The lint registry `(lint-registry-storage)` is a parse-time-folded
    // `.mutable_map` push_literal in a word body; its rule values hold the
    // dispatched `check` quotations, which the composite walk must reach.
    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "inner-noop" }, .line = 1 },
    };
    var map = value_mod.MutableMap{ .header = undefined, .map = .{} };
    defer map.map.deinit(allocator);
    try map.map.put(allocator, "rules", .{ .quotation = .{ .instructions = inner_instrs } });
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .mutable_map = &map } }, .line = 1 },
    };

    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);

    try collectCompositeQuotations(outer_instrs, &quotation_bodies, &quotation_seen, &composite_body_ptrs, allocator);

    try testing.expectEqual(@as(usize, 1), quotation_bodies.items.len);
    try testing.expectEqual(@intFromPtr(inner_instrs.ptr), @intFromPtr(quotation_bodies.items[0].ptr));
}

test "collectCompositeQuotations collects a quotation in a struct_instance field" {
    const allocator = testing.allocator;

    // Each lint rule is a struct instance whose `check` field is a quotation;
    // the walk reaches it through the struct-instance field values.
    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "inner-noop" }, .line = 1 },
    };
    var st = value_mod.StructType{ .name = "lint-rule", .fields = &.{ "id", "check" } };
    var fields = [_]Value{
        .{ .string = "rule-id" },
        .{ .quotation = .{ .instructions = inner_instrs } },
    };
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &fields };
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_instance = &si } }, .line = 1 },
    };

    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);

    try collectCompositeQuotations(outer_instrs, &quotation_bodies, &quotation_seen, &composite_body_ptrs, allocator);

    try testing.expectEqual(@as(usize, 1), quotation_bodies.items.len);
    try testing.expectEqual(@intFromPtr(inner_instrs.ptr), @intFromPtr(quotation_bodies.items[0].ptr));
}

test "collectDispatchContainerQuotationsPromoting promotes the check field quotation's callee in a mutable_map/array/struct_instance chain" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Mirrors the lint registry shape: a `.mutable_map` "rules:" entry holds an
    // `.array` of `.struct_instance` lint-rule values, each with a `check` field
    // quotation dispatched at runtime via `check>> call`.
    const check_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "promoted-callee" }, .line = 1 },
    };
    var st = value_mod.StructType{ .name = "lint-rule", .fields = &.{ "id", "check" } };
    var fields = [_]Value{
        .{ .string = "rule-id" },
        .{ .quotation = .{ .instructions = check_instrs } },
    };
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &fields };
    var rule_elems = [_]Value{.{ .struct_instance = &si }};
    var rule_elems_arr = value_mod.Array{ .header = undefined, .items = &rule_elems, .storage = .static };
    var map = value_mod.MutableMap{ .header = undefined, .map = .{} };
    defer map.map.deinit(allocator);
    try map.map.put(allocator, "rules", .{ .array = &rule_elems_arr });
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .mutable_map = &map } }, .line = 1 },
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
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectDispatchContainerQuotationsPromoting(&ctx, outer_instrs, "registry-holder", &worklist, &seen, &quotation_bodies, &quotation_seen, &composite_body_ptrs, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

    try testing.expect(seen.contains("promoted-callee"));
    try testing.expectEqual(@as(usize, 1), worklist.items.len);
    try testing.expectEqualStrings("promoted-callee", worklist.items[0]);
}

test "collectDispatchContainerQuotationsPromoting promotes the match key quotation's callee in a hash" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Mirrors a lexer rule `H{ kind: ... match: [ ... ] }`; the dispatched
    // quotation lives under the bare `match` key (the trailing colon is
    // stripped from 1z hash literal keys).
    const match_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "promoted-rule-callee" }, .line = 1 },
    };
    const hash = try value_mod.HashTable.create(allocator);
    defer hash.header.release();
    try hash.map.put(allocator, try allocator.dupe(u8, "kind"), .{ .symbol = "word" });
    try hash.map.put(allocator, try allocator.dupe(u8, "match"), .{ .quotation = .{ .instructions = match_instrs } });
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = hash } }, .line = 1 },
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
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectDispatchContainerQuotationsPromoting(&ctx, outer_instrs, "lexer-holder", &worklist, &seen, &quotation_bodies, &quotation_seen, &composite_body_ptrs, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

    try testing.expect(seen.contains("promoted-rule-callee"));
    try testing.expectEqual(@as(usize, 1), worklist.items.len);
    try testing.expectEqualStrings("promoted-rule-callee", worklist.items[0]);
}

test "collectDispatchContainerQuotationsPromoting does not promote a struct_instance field not named check" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Named-slot keying: a quotation under a field other than `check` (here
    // `fix`, which in practice is always `f`) must never be promoted, even
    // though it sits inside an otherwise-recognized struct_instance shape.
    const other_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "should-not-promote" }, .line = 1 },
    };
    var st = value_mod.StructType{ .name = "lint-rule", .fields = &.{ "id", "fix" } };
    var fields = [_]Value{
        .{ .string = "rule-id" },
        .{ .quotation = .{ .instructions = other_instrs } },
    };
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &fields };
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_instance = &si } }, .line = 1 },
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
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectDispatchContainerQuotationsPromoting(&ctx, outer_instrs, "registry-holder", &worklist, &seen, &quotation_bodies, &quotation_seen, &composite_body_ptrs, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

    try testing.expect(!seen.contains("should-not-promote"));
    try testing.expectEqual(@as(usize, 0), worklist.items.len);
}

test "collectDispatchContainerQuotationsPromoting does not promote a hash entry not keyed match" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Named-slot keying: a quotation under a key other than `match` must
    // never be promoted, even inside an otherwise-recognized hash shape.
    const other_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "should-not-promote-2" }, .line = 1 },
    };
    const hash = try value_mod.HashTable.create(allocator);
    defer hash.header.release();
    try hash.map.put(allocator, try allocator.dupe(u8, "fallback"), .{ .quotation = .{ .instructions = other_instrs } });
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = hash } }, .line = 1 },
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
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectDispatchContainerQuotationsPromoting(&ctx, outer_instrs, "lexer-holder", &worklist, &seen, &quotation_bodies, &quotation_seen, &composite_body_ptrs, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

    try testing.expect(!seen.contains("should-not-promote-2"));
    try testing.expectEqual(@as(usize, 0), worklist.items.len);
}

test "collectBranchTableQuotationsPromoting promotes arm callees of a table consumed by case" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // A `case` table is an `.array` of `{ key quot }` pair sub-arrays pushed
    // immediately before the consuming call; the arm callee is reachable only
    // through the table.
    const arm_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "branch-arm-callee" }, .line = 1 },
    };
    const pair_elems = [_]Value{
        .{ .fixnum = 1 },
        .{ .quotation = .{ .instructions = arm_instrs } },
    };
    var pair_arr = value_mod.Array{ .header = undefined, .items = &pair_elems, .storage = .static };
    const table_elems = [_]Value{.{ .array = &pair_arr }};
    var table_arr = value_mod.Array{ .header = undefined, .items = &table_elems, .storage = .static };
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &table_arr } }, .line = 1 },
        .{ .op = .{ .call_word = "case" }, .line = 1 },
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
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectBranchTableQuotationsPromoting(&ctx, outer_instrs, "case-holder", &worklist, &seen, &quotation_bodies, &quotation_seen, &composite_body_ptrs, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

    try testing.expect(seen.contains("branch-arm-callee"));
    try testing.expectEqual(@as(usize, 1), worklist.items.len);
    try testing.expectEqual(@as(usize, 1), quotation_bodies.items.len);
    try testing.expectEqual(@intFromPtr(arm_instrs.ptr), @intFromPtr(quotation_bodies.items[0].ptr));
}

test "collectBranchTableQuotationsPromoting ignores an array with no consuming combinator call" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Consumer keying: the same table followed by an unrelated call must not
    // promote, or arbitrary word-body arrays would regress the must-compile
    // set.
    const arm_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "should-not-promote-arm" }, .line = 1 },
    };
    const table_elems = [_]Value{
        .{ .quotation = .{ .instructions = arm_instrs } },
    };
    var table_arr = value_mod.Array{ .header = undefined, .items = &table_elems, .storage = .static };
    const outer_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &table_arr } }, .line = 1 },
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
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectBranchTableQuotationsPromoting(&ctx, outer_instrs, "table-holder", &worklist, &seen, &quotation_bodies, &quotation_seen, &composite_body_ptrs, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

    try testing.expect(!seen.contains("should-not-promote-arm"));
    try testing.expectEqual(@as(usize, 0), worklist.items.len);
    try testing.expectEqual(@as(usize, 0), quotation_bodies.items.len);
}

test "collectBranchTableQuotationsPromoting promotes an unchecked-match table inside a nested quotation literal" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // An `unchecked-match` table (alternating symbol/quotation pairs) sitting
    // inside a quotation literal, e.g. an `if` arm, is reached through the
    // walk's recursion into nested quotation bodies.
    const arm_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "match-arm-callee" }, .line = 1 },
    };
    const table_elems = [_]Value{
        .{ .symbol = "cons" },
        .{ .quotation = .{ .instructions = arm_instrs } },
    };
    var table_arr = value_mod.Array{ .header = undefined, .items = &table_elems, .storage = .static };
    const inner_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &table_arr } }, .line = 1 },
        .{ .op = .{ .call_word = "unchecked-match" }, .line = 1 },
    };
    const outer_instrs = &[_]Instruction{
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
    var composite_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer composite_body_ptrs.deinit(allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try collectBranchTableQuotationsPromoting(&ctx, outer_instrs, "match-holder", &worklist, &seen, &quotation_bodies, &quotation_seen, &composite_body_ptrs, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

    try testing.expect(seen.contains("match-arm-callee"));
    try testing.expectEqual(@as(usize, 1), worklist.items.len);
    try testing.expectEqualStrings("match-arm-callee", worklist.items[0]);
}

test "discoverReachableWords re-drains the BFS to reach a promoted callee's own callee" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // A word-body dispatch container (mimicking a module-private registry
    // holder) whose `check` field quotation calls a word that is itself
    // undiscovered until promoted; that word in turn calls a second,
    // previously-unreachable word. A single promoting pass finds only the
    // first; the fixed-point re-drain must reach the second.
    const check_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "promoted-callee" }, .line = 1 },
    };
    var st = value_mod.StructType{ .name = "lint-rule", .fields = &.{"check"} };
    var fields = [_]Value{
        .{ .quotation = .{ .instructions = check_instrs } },
    };
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &fields };
    var rule_elems = [_]Value{.{ .struct_instance = &si }};
    var rule_elems_arr = value_mod.Array{ .header = undefined, .items = &rule_elems, .storage = .static };
    var map = value_mod.MutableMap{ .header = undefined, .map = .{} };
    defer map.map.deinit(allocator);
    try map.map.put(allocator, "rules", .{ .array = &rule_elems_arr });

    const registry_holder_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .mutable_map = &map } }, .line = 1 },
    };
    try ctx.dictionary.put("registry-holder", .{
        .name = "registry-holder",
        .action = .{ .compound = registry_holder_body },
    });

    const promoted_callee_body = &[_]Instruction{
        .{ .op = .{ .call_word = "second-order-callee" }, .line = 1 },
    };
    try ctx.dictionary.put("promoted-callee", .{
        .name = "promoted-callee",
        .action = .{ .compound = promoted_callee_body },
    });

    try ctx.dictionary.put("second-order-callee", .{
        .name = "second-order-callee",
        .action = .{ .compound = &.{} },
    });

    const entry_instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "registry-holder" }, .line = 1 },
    };

    var diagnostics: FreezeDiagnostics = .{};
    var prelude_words = std.StringHashMapUnmanaged(void){};
    defer prelude_words.deinit(allocator);
    // result.names/defs/native_names/native_defs/quotation_bodies/method_body_ptrs are all
    // appended with ctx.quotationAllocator() (an arena), freed wholesale by ctx.deinit() above;
    // only pending_call_targets' quotation_path dupes use the passed-in result_allocator.
    var result = try discoverReachableWords(&ctx, entry_instrs, "", &prelude_words, &diagnostics, .interpreter_free_aot, true, allocator);
    defer freePendingCallTargetPaths(&result.pending_call_targets, allocator);

    try testing.expect(wordNamesContain(result.names.items, "promoted-callee"));
    try testing.expect(wordNamesContain(result.names.items, "second-order-callee"));
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

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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

    try collectCallWords(&ctx, instrs, "caller", &worklist, &seen, &quotation_bodies, &quotation_seen, &pending_call_targets, &quotation_path, &diagnostics, .interpreter_free_aot, allocator, allocator);

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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &pending, &prelude_words, null, allocator);
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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &pending, &prelude_words, null, allocator);
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
    var result = try buildAotDescs(entry_instrs, "", &discovered, &pending, &prelude_words, null, allocator);
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
    var result = try buildAotDescs(entry_instrs, "", &discovered, pending.items, &prelude_words, null, allocator);
    const elapsed_ns = timer.read();
    defer result.deinit(allocator);

    try testing.expectEqual(word_count * calls_per_word, result.call_targets.len);
    try testing.expect(elapsed_ns < ceiling_ns);
}

// ── Generator-Resolution Contract Tests ────────────────────────────────
//
// Pin the rule that struct accessors, virtual constructors, and method{
// dispatchers materialize as ordinary dictionary or dispatch-table
// entries by the time freeze BFS observes them. A regression that moves
// any of these to first-use materialization will flip the resolved
// variant from `.compound` / `.native` to `.unresolved`, failing these
// tests loudly. Integration coverage of the same contract lives in
// `tests/aot/generator_*.1z`; this file's tests pin the resolution
// machinery without standing up a full parser run.

fn generatorTestNoopNative(_: *Context) anyerror!void {}

test "struct accessor body resolves through buildAotDescs as a compound call" {
    // Mirrors the shape installed by
    // `src/primitives/structs.zig::defineFieldGetter`: a compound word
    // whose body invokes a qualified native helper. The test asserts
    // call_targets carries `.compound = caller_id` for the entry hitting
    // the accessor, locking in parse-time materialization.
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "x>>" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    const accessor_body = &[_]Instruction{
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 1 },
    };
    const effect = StackEffect{
        .inputs = &.{.{ .name = "rec" }},
        .outputs = &.{.{ .name = "val" }},
    };
    const native_effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };

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

    try discovered.names.append(allocator, "x>>");
    try discovered.defs.append(allocator, .{
        .name = "x>>",
        .action = .{ .compound = accessor_body },
        .stack_effect = effect,
    });
    try discovered.native_names.append(allocator, "native.struct-field-get");
    try discovered.native_defs.append(allocator, .{
        .name = "native.struct-field-get",
        .action = .{ .native = generatorTestNoopNative },
        .stack_effect = native_effect,
    });

    const pending = [_]PendingCallTarget{
        .{ .caller_name = "__entry__", .instruction_index = 0, .quotation_path = &.{}, .pending = .{ .compound_name = "x>>" } },
        .{ .caller_name = "x>>", .instruction_index = 0, .quotation_path = &.{}, .pending = .{ .native_name = "native.struct-field-get" } },
    };

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, "", &discovered, &pending, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.call_targets.len);
    // Entry -> accessor: compound call.
    try testing.expectEqual(@as(u32, 0), result.call_targets[0].caller_word_id);
    switch (result.call_targets[0].resolved) {
        .compound => |id| try testing.expect(id != 0),
        else => return error.TestExpectedCompound,
    }
    // Accessor body -> qualified native.
    switch (result.call_targets[1].resolved) {
        .native => |id| try testing.expect(id != 0),
        else => return error.TestExpectedNative,
    }
}

test "virtual constructor body resolves through buildAotDescs as a compound call" {
    // Mirrors the shape installed by
    // `src/primitives/virtual.zig::defineWrap`: a compound word whose
    // body invokes a qualified `native.virtual-wrap`. Asserts the same
    // resolution rule as the struct-accessor case.
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = ">point" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    const wrap_body = &[_]Instruction{
        .{ .op = .{ .call_word = "native.virtual-wrap" }, .line = 1 },
    };
    const effect = StackEffect{
        .inputs = &.{.{ .name = "raw" }},
        .outputs = &.{.{ .name = "wrapped" }},
    };
    const native_effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };

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

    try discovered.names.append(allocator, ">point");
    try discovered.defs.append(allocator, .{
        .name = ">point",
        .action = .{ .compound = wrap_body },
        .stack_effect = effect,
    });
    try discovered.native_names.append(allocator, "native.virtual-wrap");
    try discovered.native_defs.append(allocator, .{
        .name = "native.virtual-wrap",
        .action = .{ .native = generatorTestNoopNative },
        .stack_effect = native_effect,
    });

    const pending = [_]PendingCallTarget{
        .{ .caller_name = "__entry__", .instruction_index = 0, .quotation_path = &.{}, .pending = .{ .compound_name = ">point" } },
        .{ .caller_name = ">point", .instruction_index = 0, .quotation_path = &.{}, .pending = .{ .native_name = "native.virtual-wrap" } },
    };

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, "", &discovered, &pending, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.call_targets.len);
    switch (result.call_targets[0].resolved) {
        .compound => {},
        else => return error.TestExpectedCompound,
    }
    switch (result.call_targets[1].resolved) {
        .native => {},
        else => return error.TestExpectedNative,
    }
}

test "method dispatcher resolves through buildAotDescs as a compound call" {
    // Mirrors a generic word produced by `define-method`: an empty-body
    // compound carrying the `generic` marker. The dispatch table holds
    // the actual method bodies; freeze BFS resolves the dispatcher word
    // itself directly. The synthetic dispatch path
    // (`walkDispatchMethodBodies`) is exercised by the dedicated tests
    // below that populate `Context.dispatch`.
    const allocator = testing.allocator;
    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "area" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    const effect = StackEffect{
        .inputs = &.{.{ .name = "shape" }},
        .outputs = &.{.{ .name = "n" }},
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

    try discovered.names.append(allocator, "area");
    try discovered.defs.append(allocator, .{
        .name = "area",
        .action = .{ .compound = &.{} },
        .stack_effect = effect,
        .markers = &.{@constCast(&markers_mod.generic_marker)},
    });

    const pending = [_]PendingCallTarget{
        .{ .caller_name = "__entry__", .instruction_index = 0, .quotation_path = &.{}, .pending = .{ .compound_name = "area" } },
    };

    var prelude_words = std.StringHashMapUnmanaged(void){};
    var result = try buildAotDescs(entry_instrs, "", &discovered, &pending, &prelude_words, null, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.call_targets.len);
    // The dispatcher word is descriptor-wise a compound; buildAotDescs
    // routes empty-body generics through the native-shaped descriptor so
    // codegen falls back to interpreter dispatch, but the call_targets
    // entry still records the assigned word id and resolved kind.
    switch (result.call_targets[0].resolved) {
        .native, .compound => {},
        else => return error.TestExpectedResolved,
    }
}

test "DisallowedDynamicFeature surfaces unresolved-callee hint for parse-time-only banned word" {
    // The only realistic path today where a banned `dynamic-*` marker
    // can coexist with an unresolved call_target row: a user word marked
    // `parse_time_only = true` carrying `dynamic-eval`. BFS-time
    // bannedDynamicFeatureForCall fires (the marker is visible via
    // lookupWord), and classifyCallee returns `.skipped_parse_time_only`
    // because the runtime never sees the word. The diagnostic should
    // carry the hint so the user-facing message can explain the gap.
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.dictionary.put("hidden-evaller", .{
        .name = "hidden-evaller",
        .action = .{ .compound = &.{} },
        .parse_time_only = true,
        .markers = &.{@constCast(&markers_mod.dynamic_eval_marker)},
    });

    const instrs = &[_]Instruction{
        .{ .op = .{ .call_word = "hidden-evaller" }, .line = 1 },
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
        .interpreter_free_aot,
        allocator,
        allocator,
    ));

    try testing.expect(diagnostics.fatal_dynamic_feature != null);
    try testing.expectEqualStrings("caller", diagnostics.fatal_dynamic_feature.?.caller_name);
    try testing.expectEqualStrings("hidden-evaller", diagnostics.fatal_dynamic_feature.?.feature_name);

    try testing.expect(diagnostics.unresolved_callee_hint != null);
    const hint = diagnostics.unresolved_callee_hint.?;
    try testing.expectEqualStrings("caller", hint.caller_name);
    try testing.expectEqualStrings("hidden-evaller", hint.callee_name);
    try testing.expectEqual(UnresolvedReason.skipped_parse_time_only, hint.reason);
}

/// True if any slice in `bodies` aliases `needle`'s backing storage.
fn quotationBodiesContain(bodies: []const []const Instruction, needle: []const Instruction) bool {
    for (bodies) |body| {
        if (body.ptr == needle.ptr) return true;
    }
    return false;
}

/// True if `names` contains a string equal to `needle`.
fn wordNamesContain(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

test "walkDispatchMethodBodies adds every quotation method body and skips native ones" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Three method bodies on one generic: two user quotations and one native.
    // Distinct heap allocations guarantee distinct pointers so the pointer
    // dedup in the walk does not collapse them.
    const body_a = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
    });
    defer allocator.free(body_a);
    const body_b = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
    });
    defer allocator.free(body_b);

    // Distinct type-descriptor pointers serve as dispatch keys; their
    // contents are irrelevant to the walk, which collects by dispatch_id.
    const td_a = try allocator.create(value_mod.TypeDescriptor);
    defer allocator.destroy(td_a);
    td_a.* = .{ .kind = .builtin };
    const td_b = try allocator.create(value_mod.TypeDescriptor);
    defer allocator.destroy(td_b);
    td_b.* = .{ .kind = .builtin };
    const td_c = try allocator.create(value_mod.TypeDescriptor);
    defer allocator.destroy(td_c);
    td_c.* = .{ .kind = .builtin };
    const td_sentinel = try allocator.create(value_mod.TypeDescriptor);
    defer allocator.destroy(td_sentinel);
    td_sentinel.* = .{ .kind = .sentinel };

    const Stub = struct {
        fn noop(_: *Context) anyerror!void {}
    };

    const did: u32 = 7;
    try ctx.registerDispatch(.{ .dispatch_id = did, .type_a = td_a, .type_b = td_sentinel }, .{ .body = .{ .quotation = .{ .instructions = body_a } } }, false);
    try ctx.registerDispatch(.{ .dispatch_id = did, .type_a = td_b, .type_b = td_sentinel }, .{ .body = .{ .quotation = .{ .instructions = body_b } } }, false);
    try ctx.registerDispatch(.{ .dispatch_id = did, .type_a = td_c, .type_b = td_sentinel }, .{ .body = .{ .native_fn = Stub.noop } }, false);

    const def = WordDefinition{
        .name = "shape-area",
        .action = .{ .compound = &.{} },
        .markers = &.{@constCast(&markers_mod.generic_marker)},
        .dispatch_id = did,
    };

    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(allocator);
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var quotation_bodies = std.ArrayListUnmanaged([]const Instruction){};
    defer quotation_bodies.deinit(allocator);
    var quotation_seen = std.AutoHashMapUnmanaged(usize, void){};
    defer quotation_seen.deinit(allocator);
    var method_body_ptrs = std.AutoHashMapUnmanaged(usize, void){};
    defer method_body_ptrs.deinit(allocator);
    var pending_call_targets = std.ArrayListUnmanaged(PendingCallTarget){};
    defer pending_call_targets.deinit(allocator);
    defer freePendingCallTargetPaths(&pending_call_targets, allocator);
    var diagnostics: FreezeDiagnostics = .{};

    try walkDispatchMethodBodies(&ctx, def, "shape-area", &worklist, &seen, &quotation_bodies, &quotation_seen, &method_body_ptrs, &pending_call_targets, &diagnostics, .runtime_image_aot, allocator, allocator);

    try testing.expectEqual(@as(usize, 2), quotation_bodies.items.len);
    try testing.expect(quotationBodiesContain(quotation_bodies.items, body_a));
    try testing.expect(quotationBodiesContain(quotation_bodies.items, body_b));
    try testing.expect(method_body_ptrs.contains(@intFromPtr(body_a.ptr)));
    try testing.expect(method_body_ptrs.contains(@intFromPtr(body_b.ptr)));
}

test "discoverReachableWords includes reached generic's method bodies and excludes unreached" {
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Reached generic `area` has two method bodies; unreached generic
    // `volume` has one. Only `area` is called from the entry instructions.
    const area_body_a = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
    });
    defer allocator.free(area_body_a);
    const area_body_b = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
    });
    defer allocator.free(area_body_b);
    const volume_body = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
    });
    defer allocator.free(volume_body);

    const td_a = try allocator.create(value_mod.TypeDescriptor);
    defer allocator.destroy(td_a);
    td_a.* = .{ .kind = .builtin };
    const td_b = try allocator.create(value_mod.TypeDescriptor);
    defer allocator.destroy(td_b);
    td_b.* = .{ .kind = .builtin };
    const td_v = try allocator.create(value_mod.TypeDescriptor);
    defer allocator.destroy(td_v);
    td_v.* = .{ .kind = .builtin };
    const td_sentinel = try allocator.create(value_mod.TypeDescriptor);
    defer allocator.destroy(td_sentinel);
    td_sentinel.* = .{ .kind = .sentinel };

    const area_id: u32 = 11;
    const volume_id: u32 = 12;
    try ctx.registerDispatch(.{ .dispatch_id = area_id, .type_a = td_a, .type_b = td_sentinel }, .{ .body = .{ .quotation = .{ .instructions = area_body_a } } }, false);
    try ctx.registerDispatch(.{ .dispatch_id = area_id, .type_a = td_b, .type_b = td_sentinel }, .{ .body = .{ .quotation = .{ .instructions = area_body_b } } }, false);
    try ctx.registerDispatch(.{ .dispatch_id = volume_id, .type_a = td_v, .type_b = td_sentinel }, .{ .body = .{ .quotation = .{ .instructions = volume_body } } }, false);

    const generic_markers: []const *value_mod.Marker = &.{@constCast(&markers_mod.generic_marker)};
    try ctx.dictionary.put("area", .{
        .name = "area",
        .action = .{ .compound = &.{} },
        .markers = generic_markers,
        .dispatch_id = area_id,
    });
    try ctx.dictionary.put("volume", .{
        .name = "volume",
        .action = .{ .compound = &.{} },
        .markers = generic_markers,
        .dispatch_id = volume_id,
    });

    const entry_instrs = try allocator.dupe(Instruction, &[_]Instruction{
        .{ .op = .{ .call_word = "area" }, .line = 1 },
    });
    defer allocator.free(entry_instrs);

    var diagnostics: FreezeDiagnostics = .{};
    var prelude_words = std.StringHashMapUnmanaged(void){};
    defer prelude_words.deinit(allocator);
    var result = try discoverReachableWords(&ctx, entry_instrs, "", &prelude_words, &diagnostics, .runtime_image_aot, false, allocator);
    defer freePendingCallTargetPaths(&result.pending_call_targets, allocator);

    try testing.expect(quotationBodiesContain(result.quotation_bodies.items, area_body_a));
    try testing.expect(quotationBodiesContain(result.quotation_bodies.items, area_body_b));
    try testing.expect(!quotationBodiesContain(result.quotation_bodies.items, volume_body));
}

test "DisallowedDynamicFeature leaves unresolved-callee hint null for resolved native" {
    // Confirms the hint stays null on the normal banned-feature path so
    // existing error messages do not regress with stray hint lines.
    const allocator = testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.dictionary.put("user-evaller", .{
        .name = "user-evaller",
        .action = .{ .native = generatorTestNoopNative },
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
        .interpreter_free_aot,
        allocator,
        allocator,
    ));

    try testing.expect(diagnostics.fatal_dynamic_feature != null);
    try testing.expect(diagnostics.unresolved_callee_hint == null);
}
