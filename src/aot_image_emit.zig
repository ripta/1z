//! Codegen-side companion to `aot_image.zig`. Takes an `ImageManifest` and
//! emits a static C representation that the AOT runtime loader rehydrates
//! into the runtime Context at startup.
//!
//! This file owns the C-side data layout: header struct, module table, word
//! table, marker pool, typed stack-effect table, and the shared TypeValue
//! slot table that the blob path fills in. The schema is versioned via the
//! header's `format_version` field, surfaced through `runtime-image-format-version`
//! in the AOT metadata record.

const std = @import("std");
const Allocator = std.mem.Allocator;

const aot_image = @import("aot_image.zig");
const ImageEntry = aot_image.ImageEntry;
const ImageManifest = aot_image.ImageManifest;
const ImagePath = aot_image.ImagePath;
const BlobReason = aot_image.BlobReason;

const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");
const ModuleWord = value_mod.ModuleWord;
const TypeValue = value_mod.TypeValue;
const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;
const instruction_bytecode = @import("instruction_bytecode.zig");

/// Error set returned by the runtime-image emitter. `NotEncodable`
/// surfaces when the bytecode encoder cannot serialize a literal
/// inside a structural compound body. The freeze classifier should
/// rule that out, so callers treat it as a hard codegen failure.
pub const ImageEmitError = Allocator.Error || error{NotEncodable};

/// Sentinel for an image word that has no entry in the AOT dispatch
/// table. The loader treats this as "this word is metadata-only --
/// resolve through the linked interpreter when invoked".
pub const word_id_sentinel: u32 = 0xFFFFFFFF;

/// Bit positions in `onez_image_word.flags`. Kept in sync with the
/// emitted C struct.
const flag_bit_polymorphic: u8 = 1 << 0;
const flag_bit_native: u8 = 1 << 1;
const flag_bit_host_callback: u8 = 1 << 2;
const flag_bit_has_stack_effect: u8 = 1 << 3;
const flag_bit_never_returns: u8 = 1 << 4;

/// Format version emitted into `onez_image_header.format_version`. Bumped
/// when the on-disk layout changes in a way the loader cannot ignore.
pub const format_version: u32 = 2;

/// Counts that the metadata emitter plumbs back into `AotMetadata`. The
/// codegen knows these as it walks the manifest, so emitting them here
/// avoids a second pass.
pub const ImageEmissionStats = struct {
    /// Number of program-defined words in the image. Maps to
    /// `runtime-image-word-count`.
    word_count: u32 = 0,
    /// Whether any blob-path entries are present. Maps to
    /// `runtime-image-blob-present`.
    blob_present: bool = false,
    /// Size of the shared TypeValue slot table. May grow as later
    /// emission passes discover PIC snapshot references.
    typevalue_slot_count: u32 = 0,
    /// Number of distinct stack-effect entries (excluding the
    /// reserved sentinel at index 0).
    stack_effect_count: u32 = 0,
    /// Number of `type_val` blob entries actually emitted. Upperbound
    /// is `manifest.blob_count`. Non-`type_val` blob reasons emit a
    /// sentinel and don't contribute to this count.
    blob_typevalues_emitted: u32 = 0,
};

/// Emit the runtime image as static C data into `out`. Returns counts
/// suitable for downstream metadata reporting.
///
/// `ctx` supplies the live `ModuleWord` records (markers, stack
/// effects, action variant). `manifest` orders the walk and assigns the
/// classification path. `word_id_lookup` maps each in-image word's
/// resolved name to the AOT dispatch-table id; words missing from the
/// map land on `word_id_sentinel`.
///
/// The output is appended to `out`; the caller is responsible for the
/// surrounding C source (preamble, dispatch table, main, etc.).
pub fn emitImageC(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    ctx: *const Context,
    manifest: ImageManifest,
    word_id_lookup: *const std.StringHashMapUnmanaged(u32),
) ImageEmitError!ImageEmissionStats {
    var stats: ImageEmissionStats = .{};

    try emitTypeDeclarations(out, allocator);

    var marker_pool = MarkerPool.init(allocator);
    defer marker_pool.deinit();
    try collectMarkers(&marker_pool, ctx, manifest);

    var effect_table = StackEffectTable.init(allocator);
    defer effect_table.deinit();
    try collectStackEffects(&effect_table, ctx, manifest);

    var blob_plans: std.ArrayListUnmanaged(BlobEntryPlan) = .{};
    defer blob_plans.deinit(allocator);
    try collectBlobEntries(&blob_plans, &effect_table, ctx, manifest);

    const no_blob_entry: u32 = 0xFFFFFFFF;
    const word_to_blob = try allocator.alloc(u32, manifest.entries.len);
    defer allocator.free(word_to_blob);
    @memset(word_to_blob, no_blob_entry);
    for (blob_plans.items, 0..) |plan, i| {
        word_to_blob[plan.word_idx] = @intCast(i);
    }

    // Tracks per-word body bytecode emission. When entry is non-zero,
    // the word references `onez_image_w_<idx>_body` at that length;
    // zero means the word table emits NULL.
    const word_body_lens = try allocator.alloc(u32, manifest.entries.len);
    defer allocator.free(word_body_lens);
    @memset(word_body_lens, 0);

    try emitMarkerPool(out, allocator, &marker_pool, &stats);
    try emitTypeValueSlotTable(out, allocator, &effect_table);
    try emitStackEffectTable(out, allocator, &effect_table);

    // Word name string literals are emitted up front so the blob
    // entries below can reference each word's `onez_image_w_<idx>_name`
    // symbol without a forward declaration.
    try emitWordNameStrings(out, allocator, manifest);
    try emitWordBodyBytecode(out, allocator, ctx, manifest, word_body_lens);
    try emitBlobEntries(out, allocator, blob_plans.items, &stats);
    try emitModuleAndWordTables(out, allocator, ctx, manifest, word_id_lookup, &marker_pool, &effect_table, blob_plans.items, word_to_blob, word_body_lens, &stats);
    try emitHeader(out, allocator, manifest, &marker_pool, &effect_table, blob_plans.items, stats);

    stats.typevalue_slot_count = effect_table.slotCount();
    stats.stack_effect_count = effect_table.effectCount();
    return stats;
}

/// Combined table for stack effects, the params they reference, and
/// the TypeValue slot table they share with the blob path.
///
/// The effect table reserves index 0 as a sentinel ("no effect"), so
/// real effects start at 1. The slot table reserves index 0 as the
/// "no annotation" sentinel for the same reason. Params do not get
/// their own dedup pool: they are owned by exactly one effect, so
/// emitting them inline keeps the bookkeeping local.
const StackEffectTable = struct {
    allocator: Allocator,
    /// Effects in deterministic insertion order. Index 0 is a
    /// reserved sentinel that the loader must treat as "no effect".
    effects: std.ArrayListUnmanaged(*const StackEffect) = .{},
    /// Map from effect pointer -> table index. Identity-keyed.
    effect_index: std.AutoHashMapUnmanaged(*const StackEffect, u32) = .{},
    /// Distinct TypeValue pointers reached from any param annotation.
    /// Index 0 is the "no annotation" sentinel; real slots start at 1.
    type_slots: std.ArrayListUnmanaged(*const TypeValue) = .{},
    type_slot_index: std.AutoHashMapUnmanaged(*const TypeValue, u32) = .{},

    fn init(allocator: Allocator) StackEffectTable {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StackEffectTable) void {
        self.effects.deinit(self.allocator);
        self.effect_index.deinit(self.allocator);
        self.type_slots.deinit(self.allocator);
        self.type_slot_index.deinit(self.allocator);
    }

    /// Insert if absent, returning the assigned index. The sentinel
    /// effect at index 0 is implicit and never inserted.
    fn internEffect(self: *StackEffectTable, effect: *const StackEffect) Allocator.Error!u32 {
        if (self.effect_index.get(effect)) |idx| return idx;
        // Reserve index 0 for the sentinel: actual effects are
        // numbered from 1.
        const idx: u32 = @intCast(self.effects.items.len + 1);
        try self.effects.append(self.allocator, effect);
        try self.effect_index.put(self.allocator, effect, idx);
        return idx;
    }

    fn internType(self: *StackEffectTable, tv: *const TypeValue) Allocator.Error!u32 {
        if (self.type_slot_index.get(tv)) |idx| return idx;
        const idx: u32 = @intCast(self.type_slots.items.len + 1);
        try self.type_slots.append(self.allocator, tv);
        try self.type_slot_index.put(self.allocator, tv, idx);
        return idx;
    }

    fn effectCount(self: *const StackEffectTable) u32 {
        // +1 for the reserved sentinel at index 0.
        return @intCast(self.effects.items.len + 1);
    }

    fn slotCount(self: *const StackEffectTable) u32 {
        // +1 for the reserved sentinel at index 0.
        return @intCast(self.type_slots.items.len + 1);
    }

    fn lookupEffect(self: *const StackEffectTable, effect: *const StackEffect) u32 {
        return self.effect_index.get(effect) orelse 0;
    }
};

/// Pre-resolved data for one blob entry. Built before emission so the
/// slot-table sizing pass can run in lockstep with the manifest walk
/// while the actual blob emission consumes the same plan.
const BlobEntryPlan = struct {
    /// Index into `manifest.entries` (also matches the word's index in
    /// `onez_image_words_storage`).
    word_idx: u32,
    /// Mirrors `manifest.entries[word_idx].blob_reason`. Non-`type_val`
    /// reasons emit with `typevalue == null` so the loader can route to
    /// the appropriate (still-missing) decoder.
    blob_kind: BlobReason,
    /// Resolved blob-path TypeValue for `.type_val_descriptor`.
    typevalue: ?*const TypeValue = null,
    /// Slot index assigned by `internType`; `0` when no slot was
    /// reserved (non-`type_val` blob reasons).
    typevalue_slot: u32 = 0,
};

/// Walk the manifest, classify each blob entry, intern any blob-path
/// TypeValues into the shared slot table, and return the plan list.
/// The plan list is sized by the blob count; the caller frees it.
///
/// For `.type_val_descriptor` entries, the blob-path TypeValue is
/// located by inspecting the live `ModuleWord` body for its first
/// `push_literal: type_val` instruction. The fixture pattern (an enum
/// type word, its constructor, and its predicate all push the same
/// `*TypeValue`) makes this a single dedup-friendly lookup; the
/// `internType` call is identity-keyed and idempotent against any
/// stack-effect-discovered slot.
fn collectBlobEntries(
    plans: *std.ArrayListUnmanaged(BlobEntryPlan),
    effect_table: *StackEffectTable,
    ctx: *const Context,
    manifest: ImageManifest,
) Allocator.Error!void {
    for (manifest.entries, 0..) |entry, idx| {
        if (entry.path != .blob) continue;
        var plan: BlobEntryPlan = .{
            .word_idx = @intCast(idx),
            .blob_kind = entry.blob_reason,
        };
        if (entry.blob_reason == .type_val_descriptor) {
            if (lookupModuleWord(ctx, entry)) |mw_ptr| {
                if (findTypeValueLiteral(mw_ptr)) |tv| {
                    plan.typevalue = tv;
                    plan.typevalue_slot = try effect_table.internType(tv);
                }
            }
        }
        try plans.append(effect_table.allocator, plan);
    }
}

/// Inspect a compound body for its first `push_literal: type_val`
/// operand. Returns null when the action is not a compound, when the
/// body has no instructions, or when no `type_val` literal is found.
/// 248.3 only relies on the first match because the audited fixtures
/// all carry exactly one TypeValue per blob word; a richer search is
/// only necessary if multiple TypeValue literals coexist in one body.
fn findTypeValueLiteral(mw: *const ModuleWord) ?*const TypeValue {
    const body = switch (mw.action) {
        .compound => |b| b,
        else => return null,
    };
    for (body) |instr| {
        switch (instr.op) {
            .push_literal => |lit| switch (lit) {
                .type_val => |tv| return tv,
                else => {},
            },
            .call_word => {},
        }
    }
    return null;
}

/// Walk the manifest, register each word's stack effect, and recurse
/// into nested quotation effects.
fn collectStackEffects(
    table: *StackEffectTable,
    ctx: *const Context,
    manifest: ImageManifest,
) Allocator.Error!void {
    for (manifest.entries) |entry| {
        const mw_ptr = lookupModuleWord(ctx, entry) orelse continue;
        if (mw_ptr.stack_effect == null) continue;
        try registerStackEffect(table, &mw_ptr.stack_effect.?);
    }
}

fn registerStackEffect(
    table: *StackEffectTable,
    effect: *const StackEffect,
) Allocator.Error!void {
    _ = try table.internEffect(effect);
    for (effect.inputs) |param| try registerParam(table, param);
    for (effect.outputs) |param| try registerParam(table, param);
}

fn registerParam(
    table: *StackEffectTable,
    param: StackEffectParam,
) Allocator.Error!void {
    if (param.type_annotation) |tv| {
        _ = try table.internType(tv);
    }
    if (param.quotation_effect) |nested| {
        try registerStackEffect(table, nested);
    }
}

/// Pool of unique marker names. The vector preserves insertion order
/// so codegen output is deterministic; the map gives O(1) dedup.
const MarkerPool = struct {
    allocator: Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .{},
    indices: std.StringHashMapUnmanaged(u32) = .{},

    fn init(allocator: Allocator) MarkerPool {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MarkerPool) void {
        self.names.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }

    /// Insert if absent, returning the pool index. The marker name
    /// slice is borrowed from the runtime Context; the pool only
    /// stores the slice header.
    fn intern(self: *MarkerPool, name: []const u8) Allocator.Error!u32 {
        if (self.indices.get(name)) |idx| return idx;
        const idx: u32 = @intCast(self.names.items.len);
        try self.names.append(self.allocator, name);
        try self.indices.put(self.allocator, name, idx);
        return idx;
    }

    fn count(self: *const MarkerPool) u32 {
        return @intCast(self.names.items.len);
    }
};

/// Walk every word in the manifest and intern its markers into the
/// pool. Walking via the manifest order keeps marker insertion order
/// deterministic.
fn collectMarkers(
    pool: *MarkerPool,
    ctx: *const Context,
    manifest: ImageManifest,
) Allocator.Error!void {
    for (manifest.entries) |entry| {
        const mw_ptr = lookupModuleWord(ctx, entry) orelse continue;
        for (mw_ptr.markers) |marker_ptr| {
            _ = try pool.intern(marker_ptr.name);
        }
    }
}

/// Emit `onez_image_markers_storage[]` plus the per-name string
/// literals it points to. No-op when the pool is empty.
fn emitMarkerPool(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    pool: *const MarkerPool,
    stats: *ImageEmissionStats,
) Allocator.Error!void {
    _ = stats;
    if (pool.count() == 0) return;

    var num_buf: [32]u8 = undefined;

    for (pool.names.items, 0..) |name, idx| {
        try out.appendSlice(allocator, "static const char ");
        try writeMarkerNameSym(out, allocator, @intCast(idx));
        try out.appendSlice(allocator, "[] = ");
        try emitCStringLiteral(out, allocator, name);
        try out.appendSlice(allocator, ";\n");
    }
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "static const onez_image_marker_t onez_image_markers_storage[] = {\n");
    for (pool.names.items, 0..) |name, idx| {
        try out.appendSlice(allocator, "    { .name = ");
        try writeMarkerNameSym(out, allocator, @intCast(idx));
        try out.appendSlice(allocator, ", .name_len = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{name.len}) catch unreachable);
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit the shared TypeValue slot table. Entry 0 is the "no
/// annotation" sentinel; real slots are NULL-initialized so the
/// blob-path loader (run after this code is loaded) can patch them
/// to point at runtime-allocated TypeValues.
fn emitTypeValueSlotTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "__attribute__((used)) const struct onez_typevalue *onez_image_typevalue_slots[");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{table.slotCount()}) catch unreachable);
    try out.appendSlice(allocator, "] = {\n    NULL, /* slot 0: \"no annotation\" sentinel. */\n");
    for (table.type_slots.items, 0..) |tv, i| {
        const slot_idx = i + 1;
        try out.appendSlice(allocator, "    NULL, /* slot ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{slot_idx}) catch unreachable);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, tv.name);
        try out.appendSlice(allocator, " (filled by the loader). */\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit the per-effect param arrays plus the `onez_image_stack_effects_storage[]`
/// table. Stack-effect index 0 is the reserved sentinel emitted as
/// `{ NULL, 0, NULL, 0 }`; real effects start at index 1.
fn emitStackEffectTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    var num_buf: [32]u8 = undefined;

    // Param strings and per-effect param arrays.
    for (table.effects.items, 0..) |effect, i| {
        const eff_idx = i + 1;
        try emitEffectParamStrings(out, allocator, effect, eff_idx);
        if (effect.inputs.len > 0) {
            try emitEffectParamArray(out, allocator, table, effect, eff_idx, true);
        }
        if (effect.outputs.len > 0) {
            try emitEffectParamArray(out, allocator, table, effect, eff_idx, false);
        }
    }
    try out.append(allocator, '\n');

    // Effect table itself.
    try out.appendSlice(allocator, "static const onez_image_stack_effect_t onez_image_stack_effects_storage[] = {\n");
    try out.appendSlice(allocator, "    { NULL, 0, NULL, 0 }, /* index 0: \"no effect\" sentinel. */\n");
    for (table.effects.items, 0..) |effect, i| {
        const eff_idx = i + 1;
        try out.appendSlice(allocator, "    { ");
        if (effect.inputs.len > 0) {
            try out.appendSlice(allocator, ".inputs = ");
            try writeEffectParamArraySym(out, allocator, eff_idx, true);
        } else {
            try out.appendSlice(allocator, ".inputs = NULL");
        }
        try out.appendSlice(allocator, ", .input_count = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{effect.inputs.len}) catch unreachable);
        try out.appendSlice(allocator, ", ");
        if (effect.outputs.len > 0) {
            try out.appendSlice(allocator, ".outputs = ");
            try writeEffectParamArraySym(out, allocator, eff_idx, false);
        } else {
            try out.appendSlice(allocator, ".outputs = NULL");
        }
        try out.appendSlice(allocator, ", .output_count = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{effect.outputs.len}) catch unreachable);
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn emitEffectParamStrings(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    effect: *const StackEffect,
    eff_idx: usize,
) Allocator.Error!void {
    for (effect.inputs, 0..) |param, i| {
        try out.appendSlice(allocator, "static const char ");
        try writeParamNameSym(out, allocator, eff_idx, true, i);
        try out.appendSlice(allocator, "[] = ");
        try emitCStringLiteral(out, allocator, param.name);
        try out.appendSlice(allocator, ";\n");
    }
    for (effect.outputs, 0..) |param, i| {
        try out.appendSlice(allocator, "static const char ");
        try writeParamNameSym(out, allocator, eff_idx, false, i);
        try out.appendSlice(allocator, "[] = ");
        try emitCStringLiteral(out, allocator, param.name);
        try out.appendSlice(allocator, ";\n");
    }
}

fn emitEffectParamArray(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
    effect: *const StackEffect,
    eff_idx: usize,
    is_input: bool,
) Allocator.Error!void {
    var num_buf: [32]u8 = undefined;
    const params = if (is_input) effect.inputs else effect.outputs;
    try out.appendSlice(allocator, "static const onez_image_stack_effect_param_t ");
    try writeEffectParamArraySym(out, allocator, eff_idx, is_input);
    try out.appendSlice(allocator, "[] = {\n");
    for (params, 0..) |param, i| {
        const has_type: u8 = if (param.type_annotation != null) 1 else 0;
        const has_quot: u8 = if (param.quotation_effect != null) 1 else 0;
        const is_row: u8 = if (param.is_row_variable) 1 else 0;
        const type_slot: u32 = if (param.type_annotation) |tv|
            table.type_slot_index.get(tv) orelse 0
        else
            0;
        const quot_idx: u32 = if (param.quotation_effect) |nested|
            table.lookupEffect(nested)
        else
            0;
        try out.appendSlice(allocator, "    { .name = ");
        try writeParamNameSym(out, allocator, eff_idx, is_input, i);
        try out.appendSlice(allocator, ", .name_len = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{param.name.len}) catch unreachable);
        try out.appendSlice(allocator, ", .is_row_variable = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{is_row}) catch unreachable);
        try out.appendSlice(allocator, ", .has_type_annotation = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{has_type}) catch unreachable);
        try out.appendSlice(allocator, ", .has_quotation_effect = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{has_quot}) catch unreachable);
        try out.appendSlice(allocator, ", ._pad = 0, .typevalue_slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{type_slot}) catch unreachable);
        try out.appendSlice(allocator, ", .quotation_effect_idx = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{quot_idx}) catch unreachable);
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator, "};\n");
}

fn writeParamNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    eff_idx: usize,
    is_input: bool,
    param_idx: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const tag: u8 = if (is_input) 'i' else 'o';
    const s = std.fmt.bufPrint(&buf, "onez_image_se_{d}_{c}{d}_name", .{ eff_idx, tag, param_idx }) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeEffectParamArraySym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    eff_idx: usize,
    is_input: bool,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const tag: []const u8 = if (is_input) "in" else "out";
    const s = std.fmt.bufPrint(&buf, "onez_image_se_{d}_{s}", .{ eff_idx, tag }) catch unreachable;
    try out.appendSlice(allocator, s);
}

/// Value-kind tags emitted into `onez_image_blob_descriptor_entry.value_kind`.
/// The set covers exactly what `createTypeDescriptor` produces (symbols,
/// booleans, fixnums, strings, unit). The `unsupported` sentinel keeps
/// codegen total when a TypeValue carries a descriptor entry the loader
/// is not prepared to decode; the loader will drop it with a diagnostic.
const BlobValueKind = enum(u8) {
    symbol = 0,
    boolean = 1,
    fixnum = 2,
    string = 3,
    unit = 4,
    unsupported = 5,
};

const BlobDescriptorEntry = struct {
    key: []const u8,
    kind: BlobValueKind,
    bool_value: bool = false,
    fixnum_value: i64 = 0,
    string_value: []const u8 = "",
};

/// Emit per-blob descriptor arrays plus the
/// `onez_image_blob_typevalues_storage[]` and
/// `onez_image_blob_entries_storage[]` tables. No-op when no blob
/// entries are present (the header still emits a NULL pointer so the
/// loader can branch on count).
fn emitBlobEntries(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    plans: []const BlobEntryPlan,
    stats: *ImageEmissionStats,
) Allocator.Error!void {
    if (plans.len == 0) return;

    var num_buf: [32]u8 = undefined;

    // Per-blob descriptor entry arrays. Indexed by position in
    // `plans` so the typevalue struct below can reference each by
    // its symbol. Non-`type_val` plans contribute no descriptor
    // array.
    const descriptor_entry_counts = try allocator.alloc(u32, plans.len);
    defer allocator.free(descriptor_entry_counts);
    @memset(descriptor_entry_counts, 0);

    var emitted_typevalues: u32 = 0;
    for (plans, 0..) |plan, i| {
        const tv = plan.typevalue orelse continue;
        emitted_typevalues += 1;

        var descriptor_entries: std.ArrayListUnmanaged(BlobDescriptorEntry) = .{};
        defer descriptor_entries.deinit(allocator);

        if (tv.descriptor) |desc| {
            try collectDescriptorEntries(&descriptor_entries, allocator, desc);
        }
        descriptor_entry_counts[i] = @intCast(descriptor_entries.items.len);

        // Lex sort by key; StringHashMap iteration is unstable.
        std.mem.sort(BlobDescriptorEntry, descriptor_entries.items, {}, struct {
            fn lessThan(_: void, a: BlobDescriptorEntry, b: BlobDescriptorEntry) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lessThan);

        if (descriptor_entries.items.len > 0) {
            try out.appendSlice(allocator, "static const onez_image_blob_descriptor_entry_t ");
            try writeBlobDescSym(out, allocator, i);
            try out.appendSlice(allocator, "[] = {\n");
            for (descriptor_entries.items) |de| {
                try out.appendSlice(allocator, "    { .key = ");
                try emitCStringLiteral(out, allocator, de.key);
                try out.appendSlice(allocator, ", .key_len = ");
                try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{de.key.len}) catch unreachable);
                try out.appendSlice(allocator, ", .value_kind = ");
                try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{@intFromEnum(de.kind)}) catch unreachable);
                try out.appendSlice(allocator, ", .bool_value = ");
                try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{@intFromBool(de.bool_value)}) catch unreachable);
                try out.appendSlice(allocator, ", ._pad = 0, .fixnum_value = ");
                try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{de.fixnum_value}) catch unreachable);
                try out.appendSlice(allocator, ", .string_value = ");
                if (de.kind == .symbol or de.kind == .string) {
                    try emitCStringLiteral(out, allocator, de.string_value);
                } else {
                    try out.appendSlice(allocator, "NULL");
                }
                try out.appendSlice(allocator, ", .string_value_len = ");
                if (de.kind == .symbol or de.kind == .string) {
                    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{de.string_value.len}) catch unreachable);
                } else {
                    try out.appendSlice(allocator, "0");
                }
                try out.appendSlice(allocator, " },\n");
            }
            try out.appendSlice(allocator, "};\n");
        }
    }
    if (emitted_typevalues > 0) try out.append(allocator, '\n');
    stats.blob_typevalues_emitted = emitted_typevalues;

    // Per-blob TypeValue records. One per `type_val` plan. The
    // `name`/`name_len` mirror the word's name symbol that
    // `emitModuleAndWordTables` already emits, so we can reuse that
    // pool by referencing `onez_image_w_<idx>_name`.
    if (emitted_typevalues > 0) {
        try out.appendSlice(allocator, "static const onez_image_blob_typevalue_t onez_image_blob_typevalues_storage[] = {\n");
        for (plans, 0..) |plan, i| {
            const tv = plan.typevalue orelse continue;
            try out.appendSlice(allocator, "    { .name = ");
            try writeWordNameSym(out, allocator, plan.word_idx);
            try out.appendSlice(allocator, ", .name_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{tv.name.len}) catch unreachable);
            try out.appendSlice(allocator, ", .typevalue_slot = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{plan.typevalue_slot}) catch unreachable);

            // Descriptor entry array reference + count. The per-blob
            // symbol exists iff the first-loop count is non-zero.
            const entry_count = descriptor_entry_counts[i];
            if (entry_count > 0) {
                try out.appendSlice(allocator, ", .descriptor_entries = ");
                try writeBlobDescSym(out, allocator, i);
                try out.appendSlice(allocator, ", .descriptor_entry_count = ");
                try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{entry_count}) catch unreachable);
            } else {
                try out.appendSlice(allocator, ", .descriptor_entries = NULL, .descriptor_entry_count = 0");
            }
            try out.appendSlice(allocator, ", .member_type_slots = NULL, .member_type_count = 0 },\n");
        }
        try out.appendSlice(allocator, "};\n\n");
    }

    // Top-level blob entry table. One per plan (covers both `type_val`
    // and non-`type_val` reasons; the latter emit `typevalue = NULL`
    // so the loader can route by `blob_kind`).
    try out.appendSlice(allocator, "static const onez_image_blob_entry_t onez_image_blob_entries_storage[] = {\n");
    var emitted_typevalue_idx: u32 = 0;
    for (plans) |plan| {
        try out.appendSlice(allocator, "    { .word_idx = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{plan.word_idx}) catch unreachable);
        try out.appendSlice(allocator, ", .blob_kind = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{@intFromEnum(plan.blob_kind)}) catch unreachable);
        try out.appendSlice(allocator, ", ._pad = {0,0,0}, .typevalue = ");
        if (plan.typevalue != null) {
            try out.appendSlice(allocator, "&onez_image_blob_typevalues_storage[");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{emitted_typevalue_idx}) catch unreachable);
            try out.appendSlice(allocator, "]");
            emitted_typevalue_idx += 1;
        } else {
            try out.appendSlice(allocator, "NULL");
        }
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn writeBlobDescSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    plan_idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_blob_desc_{d}", .{plan_idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

/// Walk a TypeDescriptor and append blob entries to `out`. Always emits the
/// `type` discriminator and the four universal booleans, then per-kind
/// fields. Kind-specific fields whose runtime payload would require a
/// type_val reference (struct/virtual/enum cross-links) land on
/// `BlobValueKind.unsupported` so the loader can skip them with a
/// diagnostic; primitive fields (`resource-kind`, `ffi-layout`) round-trip.
fn collectDescriptorEntries(
    out: *std.ArrayListUnmanaged(BlobDescriptorEntry),
    allocator: Allocator,
    desc: *const value_mod.TypeDescriptor,
) Allocator.Error!void {
    try out.append(allocator, .{
        .key = "type",
        .kind = .symbol,
        .string_value = value_mod.typeKindSymbol(desc.kind),
    });
    try out.append(allocator, .{ .key = "numeric", .kind = .boolean, .bool_value = desc.numeric });
    try out.append(allocator, .{ .key = "exact", .kind = .boolean, .bool_value = desc.exact });
    try out.append(allocator, .{ .key = "integer", .kind = .boolean, .bool_value = desc.integer });
    try out.append(allocator, .{ .key = "mutable", .kind = .boolean, .bool_value = desc.mutable });
    switch (desc.kind) {
        .builtin, .sentinel, .union_ => {},
        .struct_ => |sd| {
            try out.append(allocator, .{ .key = "fields", .kind = .unsupported });
            if (sd.field_types.len != 0) {
                try out.append(allocator, .{ .key = "field-types", .kind = .unsupported });
            }
        },
        .virtual => |vd| {
            if (vd.inner_type != null or vd.anon_struct != null) {
                try out.append(allocator, .{ .key = "inner-type", .kind = .unsupported });
            }
            if (vd.type_params.len == 1) {
                try out.append(allocator, .{ .key = "element-type", .kind = .unsupported });
            }
        },
        .enum_ => {
            try out.append(allocator, .{ .key = "variants", .kind = .unsupported });
        },
        .enum_variant => |evd| {
            if (evd.parent != null) {
                try out.append(allocator, .{ .key = "parent", .kind = .unsupported });
            }
            if (evd.inner_type != null) {
                try out.append(allocator, .{ .key = "inner-type", .kind = .unsupported });
            }
        },
        .resource => |rd| {
            try out.append(allocator, .{
                .key = "resource-kind",
                .kind = .string,
                .string_value = rd.resource_kind,
            });
        },
        .ffi_struct => |fsd| {
            try out.append(allocator, .{ .key = "fields", .kind = .unsupported });
            if (fsd.ffi_layout != 0) {
                try out.append(allocator, .{
                    .key = "ffi-layout",
                    .kind = .fixnum,
                    .fixnum_value = @intCast(fsd.ffi_layout),
                });
            }
        },
    }
}

fn writeMarkerNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: u32,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_mk_{d}_name", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeWordMarkersSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    word_idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_w_{d}_markers", .{word_idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

/// Resolve an image word back to the live `ModuleWord` so the emitter
/// can read markers, the stack effect, and the action variant. Returns
/// a pointer into the module's words map so callers may take stable
/// addresses of nested fields (e.g., the stack effect).
fn lookupModuleWord(ctx: *const Context, entry: ImageEntry) ?*const ModuleWord {
    var it = ctx.module_cache_value.iterator();
    while (it.next()) |cached| {
        if (cached.value_ptr.* != .module) continue;
        const mod = cached.value_ptr.*.module;
        if (!std.mem.eql(u8, mod.name, entry.module_name)) continue;
        return mod.words.getPtr(entry.word_name);
    }
    return null;
}

/// Compose the lookup key used against `word_id_lookup`. Tries the
/// module-qualified form first, then the bare word name. Mirrors the
/// AOT freezer's convention of recording calls to module-private
/// words by their qualified name when discovered through `use`.
fn resolveWordId(
    entry: ImageEntry,
    word_id_lookup: *const std.StringHashMapUnmanaged(u32),
    qualified_buf: []u8,
) u32 {
    const qualified_len = entry.module_name.len + 1 + entry.word_name.len;
    if (qualified_len <= qualified_buf.len) {
        @memcpy(qualified_buf[0..entry.module_name.len], entry.module_name);
        qualified_buf[entry.module_name.len] = '.';
        @memcpy(
            qualified_buf[entry.module_name.len + 1 .. qualified_len],
            entry.word_name,
        );
        if (word_id_lookup.get(qualified_buf[0..qualified_len])) |id| return id;
    }
    if (word_id_lookup.get(entry.word_name)) |id| return id;
    return word_id_sentinel;
}

/// Compute the word's flags byte from its `ModuleWord` action and
/// markers. Marker presence is decided here even though the marker
/// pool itself is emitted by a later sub-pass; the bit just records
/// which words *have* markers, not what they are.
fn computeFlags(mw: *const ModuleWord) u8 {
    var flags: u8 = 0;
    if (mw.polymorphic) flags |= flag_bit_polymorphic;
    switch (mw.action) {
        .native => flags |= flag_bit_native,
        .host_callback => flags |= flag_bit_host_callback,
        .compound => {},
    }
    if (mw.stack_effect != null) flags |= flag_bit_has_stack_effect;
    return flags;
}

/// Emit the C type declarations for every struct used by the image.
/// All struct shapes are declared here so the loader has a single
/// canonical layout reference.
fn emitTypeDeclarations(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
) Allocator.Error!void {
    try out.appendSlice(allocator,
        \\/* AOT runtime image: static-C-data layout. */
        \\/* The loader walks `onez_image_v1` to populate the runtime */
        \\/* Context's dictionary, modules, and slot tables. */
        \\
        \\struct onez_typevalue;  /* opaque; layout owned by the blob path. */
        \\
        \\typedef struct onez_image_module {
        \\    const char *name;
        \\    uint32_t name_len;
        \\    uint32_t word_start_idx;
        \\    uint32_t word_count;
        \\} onez_image_module_t;
        \\
        \\typedef struct onez_image_marker {
        \\    const char *name;
        \\    uint32_t name_len;
        \\} onez_image_marker_t;
        \\
        \\typedef struct onez_image_stack_effect_param {
        \\    const char *name;
        \\    uint32_t name_len;
        \\    uint8_t  is_row_variable;
        \\    uint8_t  has_type_annotation;
        \\    uint8_t  has_quotation_effect;
        \\    uint8_t  _pad;
        \\    uint32_t typevalue_slot;
        \\    uint32_t quotation_effect_idx;
        \\} onez_image_stack_effect_param_t;
        \\
        \\typedef struct onez_image_stack_effect {
        \\    const struct onez_image_stack_effect_param *inputs;
        \\    uint32_t input_count;
        \\    const struct onez_image_stack_effect_param *outputs;
        \\    uint32_t output_count;
        \\} onez_image_stack_effect_t;
        \\
        \\typedef struct onez_image_word {
        \\    const char *name;
        \\    uint32_t name_len;
        \\    uint32_t word_id;
        \\    uint32_t module_idx;
        \\    uint8_t  classification;
        \\    uint8_t  blob_reason;
        \\    uint8_t  flags;
        \\    uint8_t  _reserved;
        \\    uint8_t  input_count;
        \\    uint8_t  output_count;
        \\    uint16_t _pad;
        \\    uint32_t stack_effect_idx;
        \\    const struct onez_image_marker *const *markers;
        \\    uint32_t marker_count;
        \\    const uint8_t *body_bytecode;
        \\    uint32_t body_bytecode_len;
        \\    uint32_t blob_entry_idx;          /* 0xFFFFFFFFu when no blob entry. */
        \\    uint32_t typevalue_slot;          /* 0 when this word does not publish a slot. */
        \\} onez_image_word_t;
        \\
        \\/* Blob-path schema. The structural-C-data structs above ARE the */
        \\/* runtime values; these blob structs DESCRIBE values that the   */
        \\/* loader must allocate at startup (TypeValue.descriptor is a    */
        \\/* StringHashMapUnmanaged whose layout is allocator-dependent).  */
        \\/* value_kind in onez_image_blob_descriptor_entry: */
        \\/*   0 = symbol  (string_value points to interned name)         */
        \\/*   1 = boolean (bool_value carries 0 or 1)                    */
        \\/*   2 = fixnum  (fixnum_value carries the i64)                 */
        \\/*   3 = string  (string_value points to the literal)           */
        \\/*   4 = unit    (no payload)                                   */
        \\/*   5 = unsupported (loader skips with diagnostic)             */
        \\typedef struct onez_image_blob_descriptor_entry {
        \\    const char *key;
        \\    uint32_t key_len;
        \\    uint8_t  value_kind;
        \\    uint8_t  bool_value;
        \\    uint16_t _pad;
        \\    int64_t  fixnum_value;
        \\    const char *string_value;
        \\    uint32_t string_value_len;
        \\} onez_image_blob_descriptor_entry_t;
        \\
        \\typedef struct onez_image_blob_typevalue {
        \\    const char *name;
        \\    uint32_t name_len;
        \\    uint32_t typevalue_slot;          /* index into onez_image_typevalue_slots */
        \\    const struct onez_image_blob_descriptor_entry *descriptor_entries;
        \\    uint32_t descriptor_entry_count;
        \\    /* Reserved for deeper type-graph rehydration. */
        \\    const uint32_t *member_type_slots;
        \\    uint32_t member_type_count;
        \\} onez_image_blob_typevalue_t;
        \\
        \\typedef struct onez_image_blob_entry {
        \\    uint32_t word_idx;                /* back-pointer into onez_image_words_storage */
        \\    uint8_t  blob_kind;               /* matches BlobReason; today always type_val_descriptor */
        \\    uint8_t  _pad[3];
        \\    /* typevalue is non-NULL for type_val blob entries; NULL for other blob kinds. */
        \\    const struct onez_image_blob_typevalue *typevalue;
        \\} onez_image_blob_entry_t;
        \\
        \\typedef struct onez_image_header {
        \\    uint32_t format_version;
        \\    uint32_t module_count;
        \\    uint32_t word_count;
        \\    uint32_t marker_pool_count;
        \\    uint32_t typevalue_slot_count;
        \\    uint32_t stack_effect_count;
        \\    uint32_t blob_entry_count;
        \\    uint32_t _pad;
        \\    const struct onez_image_module *modules;
        \\    const struct onez_image_word *words;
        \\    const struct onez_image_marker *markers;
        \\    const struct onez_image_stack_effect *stack_effects;
        \\    const struct onez_image_blob_entry *blob_entries;
        \\} onez_image_header_t;
        \\
        \\
    );
}

/// Emit per-word name string literals (`onez_image_w_<idx>_name`).
/// Hoisted out of the module/word table emit pass so blob entries,
/// emitted before the word table, can reference each word's name
/// symbol without forward declarations.
fn emitWordNameStrings(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    manifest: ImageManifest,
) Allocator.Error!void {
    if (manifest.entries.len == 0) return;
    for (manifest.entries, 0..) |entry, idx| {
        try out.appendSlice(allocator, "static const char ");
        try writeWordNameSym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = ");
        try emitCStringLiteral(out, allocator, entry.word_name);
        try out.appendSlice(allocator, ";\n");
    }
    try out.append(allocator, '\n');
}

/// Serialize each structural compound word's body to bytecode and
/// emit it as a `static const uint8_t onez_image_w_<idx>_body[]`
/// array. Records the per-word byte length in `word_body_lens` so
/// `emitModuleAndWordTables` can reference the symbol from the
/// matching word-table row. Words that fall on the blob path, lack a
/// compound action, or carry an empty body get a length of zero and
/// the word table emits NULL for `body_bytecode`. The blob loader
/// still rewrites empty bodies for `type_val` blob entries
/// downstream, so dropping bytes there avoids redundant work.
///
/// Generator-emitted words (those with a non-null `provenance` such
/// as virtual-type predicates, struct constructors, and FFI
/// accessors) are also skipped: their bodies encode `@intFromPtr` of
/// a runtime type as a fixnum literal, which is non-deterministic
/// across builds and stale across runtime-image load. Such words
/// still reach runtime through compiled dispatch via `word_id`; the
/// only fidelity loss is that `>word-info` reports their body as
/// empty instead of the original instruction stream.
///
/// Serialized bytes are owned by the codegen allocator for the
/// duration of this helper -- they are rendered into `out` and
/// freed before return -- mirroring the lifetime convention used by
/// `emitMarkerPool` and `emitBlobEntries`.
fn emitWordBodyBytecode(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    ctx: *const Context,
    manifest: ImageManifest,
    word_body_lens: []u32,
) ImageEmitError!void {
    if (manifest.entries.len == 0) return;

    var emitted_any = false;
    var num_buf: [32]u8 = undefined;

    for (manifest.entries, 0..) |entry, idx| {
        if (entry.path != .structural) continue;
        const mw_ptr = lookupModuleWord(ctx, entry) orelse continue;
        const body = switch (mw_ptr.action) {
            .compound => |b| b,
            .native, .host_callback => continue,
        };
        if (body.len == 0) continue;
        if (mw_ptr.provenance != null) continue;

        const bytes = instruction_bytecode.serializeQuotationInstructions(body, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotEncodable => return error.NotEncodable,
        };
        defer allocator.free(bytes);

        try out.appendSlice(allocator, "static const uint8_t ");
        try writeWordBodySym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = {");
        for (bytes, 0..) |byte, bi| {
            if (bi > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{byte}) catch unreachable);
        }
        try out.appendSlice(allocator, "};\n");
        word_body_lens[idx] = @intCast(bytes.len);
        emitted_any = true;
    }
    if (emitted_any) try out.append(allocator, '\n');
}

fn writeWordBodySym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_w_{d}_body", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

/// Emit `onez_image_modules[]` and `onez_image_words[]` along with
/// each word's marker pointer array. Word name strings are emitted
/// up front by `emitWordNameStrings` so the blob entries (emitted
/// earlier) can reference them.
fn emitModuleAndWordTables(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    ctx: *const Context,
    manifest: ImageManifest,
    word_id_lookup: *const std.StringHashMapUnmanaged(u32),
    pool: *const MarkerPool,
    effect_table: *const StackEffectTable,
    blob_plans: []const BlobEntryPlan,
    word_to_blob: []const u32,
    word_body_lens: []const u32,
    stats: *ImageEmissionStats,
) Allocator.Error!void {
    if (manifest.entries.len == 0) {
        try out.appendSlice(allocator,
            \\/* No image modules: tables omitted. */
            \\
            \\
        );
        return;
    }

    var num_buf: [32]u8 = undefined;
    var qualified_buf: [256]u8 = undefined;

    // Per-word marker pointer arrays. A word with zero markers
    // emits nothing here and references NULL in the word table; a
    // word with markers emits a `static const onez_image_marker_t
    // *const onez_image_w_<idx>_markers[]` of pool pointers.
    for (manifest.entries, 0..) |entry, idx| {
        const mw_ptr = lookupModuleWord(ctx, entry) orelse continue;
        if (mw_ptr.markers.len == 0) continue;
        try out.appendSlice(allocator, "static const onez_image_marker_t *const ");
        try writeWordMarkersSym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = {\n");
        for (mw_ptr.markers) |marker_ptr| {
            const pool_idx = pool.indices.get(marker_ptr.name) orelse continue;
            try out.appendSlice(allocator, "    &onez_image_markers_storage[");
            var n_buf: [16]u8 = undefined;
            try out.appendSlice(allocator, std.fmt.bufPrint(&n_buf, "{d}", .{pool_idx}) catch unreachable);
            try out.appendSlice(allocator, "],\n");
        }
        try out.appendSlice(allocator, "};\n");
    }
    try out.append(allocator, '\n');

    // Module string literals are emitted in the same lexicographic
    // order the manifest already established. Walk once to collect
    // each distinct module's name and its [start, end) range over the
    // word table.
    var module_idx: u32 = 0;
    {
        var i: usize = 0;
        while (i < manifest.entries.len) {
            const mod_name = manifest.entries[i].module_name;
            try out.appendSlice(allocator, "static const char ");
            try writeModuleNameSym(out, allocator, module_idx);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, mod_name);
            try out.appendSlice(allocator, ";\n");
            module_idx += 1;
            while (i < manifest.entries.len and
                std.mem.eql(u8, manifest.entries[i].module_name, mod_name)) : (i += 1)
            {}
        }
    }
    const module_count: u32 = module_idx;
    try out.append(allocator, '\n');

    // Word table.
    try out.appendSlice(allocator,
        \\static const onez_image_word_t onez_image_words_storage[] = {
        \\
    );
    var current_module_idx: u32 = 0;
    var current_module_name: []const u8 = manifest.entries[0].module_name;
    var blob_present = false;
    for (manifest.entries, 0..) |entry, idx| {
        if (!std.mem.eql(u8, entry.module_name, current_module_name)) {
            current_module_idx += 1;
            current_module_name = entry.module_name;
        }
        if (entry.path == .blob) blob_present = true;

        const fallback_mw = ModuleWord{ .action = .{ .compound = &.{} } };
        const mw_ptr: *const ModuleWord = lookupModuleWord(ctx, entry) orelse &fallback_mw;

        const flags = computeFlags(mw_ptr);
        const input_count: u8 = if (mw_ptr.stack_effect) |eff|
            @intCast(eff.concreteInputCount())
        else
            0;
        const output_count: u8 = if (mw_ptr.stack_effect) |eff|
            @intCast(eff.concreteOutputCount())
        else
            0;

        const word_id = resolveWordId(entry, word_id_lookup, &qualified_buf);

        try out.appendSlice(allocator, "    {\n        .name = ");
        try writeWordNameSym(out, allocator, idx);
        try out.appendSlice(allocator, ",\n        .name_len = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{entry.word_name.len}) catch unreachable);
        try out.appendSlice(allocator, ",\n        .word_id = ");
        try writeU32Hex(out, allocator, word_id);
        try out.appendSlice(allocator, ",\n        .module_idx = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{current_module_idx}) catch unreachable);
        try out.appendSlice(allocator, ",\n        .classification = ");
        try out.appendSlice(allocator, switch (entry.path) {
            .structural => "0",
            .blob => "1",
        });
        try out.appendSlice(allocator, ",\n        .blob_reason = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{@intFromEnum(entry.blob_reason)}) catch unreachable);
        try out.appendSlice(allocator, ",\n        .flags = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{flags}) catch unreachable);
        try out.appendSlice(allocator, ",\n        ._reserved = 0,\n        .input_count = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{input_count}) catch unreachable);
        try out.appendSlice(allocator, ",\n        .output_count = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{output_count}) catch unreachable);
        const stack_effect_idx: u32 = if (mw_ptr.stack_effect != null)
            effect_table.lookupEffect(&mw_ptr.stack_effect.?)
        else
            0;
        try out.appendSlice(allocator,
            \\,
            \\        ._pad = 0,
            \\        .stack_effect_idx =
        );
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, " {d}", .{stack_effect_idx}) catch unreachable);
        try out.appendSlice(allocator, ",\n");
        if (mw_ptr.markers.len > 0) {
            try out.appendSlice(allocator, "        .markers = ");
            try writeWordMarkersSym(out, allocator, idx);
            try out.appendSlice(allocator, ",\n        .marker_count = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{mw_ptr.markers.len}) catch unreachable);
            try out.appendSlice(allocator, ",\n");
        } else {
            try out.appendSlice(allocator,
                \\        .markers = NULL,
                \\        .marker_count = 0,
                \\
            );
        }
        const body_len = word_body_lens[idx];
        if (body_len > 0) {
            try out.appendSlice(allocator, "        .body_bytecode = ");
            try writeWordBodySym(out, allocator, idx);
            try out.appendSlice(allocator, ",\n        .body_bytecode_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{body_len}) catch unreachable);
            try out.appendSlice(allocator, ",\n");
        } else {
            try out.appendSlice(allocator, "        .body_bytecode = NULL,\n");
            try out.appendSlice(allocator, "        .body_bytecode_len = 0,\n");
        }

        const blob_idx = word_to_blob[idx];
        try out.appendSlice(allocator, "        .blob_entry_idx = ");
        if (blob_idx == 0xFFFFFFFF) {
            try out.appendSlice(allocator, "0xFFFFFFFFu");
        } else {
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}u", .{blob_idx}) catch unreachable);
        }
        try out.appendSlice(allocator, ",\n        .typevalue_slot = ");
        const tv_slot: u32 = if (blob_idx == 0xFFFFFFFF) 0 else blob_plans[blob_idx].typevalue_slot;
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}u", .{tv_slot}) catch unreachable);
        try out.appendSlice(allocator,
            \\,
            \\    },
            \\
        );
    }
    try out.appendSlice(allocator, "};\n\n");

    // Module table.
    try out.appendSlice(allocator,
        \\static const onez_image_module_t onez_image_modules_storage[] = {
        \\
    );
    {
        var i: usize = 0;
        var emitted_modules: u32 = 0;
        while (i < manifest.entries.len) {
            const mod_name = manifest.entries[i].module_name;
            const start = i;
            while (i < manifest.entries.len and
                std.mem.eql(u8, manifest.entries[i].module_name, mod_name)) : (i += 1)
            {}
            const word_count = i - start;

            try out.appendSlice(allocator, "    { .name = ");
            try writeModuleNameSym(out, allocator, emitted_modules);
            try out.appendSlice(allocator, ", .name_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{mod_name.len}) catch unreachable);
            try out.appendSlice(allocator, ", .word_start_idx = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{start}) catch unreachable);
            try out.appendSlice(allocator, ", .word_count = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{word_count}) catch unreachable);
            try out.appendSlice(allocator, " },\n");
            emitted_modules += 1;
        }
    }
    try out.appendSlice(allocator, "};\n\n");

    stats.word_count = @intCast(manifest.entries.len);
    stats.blob_present = blob_present;

    _ = module_count;
}

fn writeWordNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_w_{d}_name", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeModuleNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: u32,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_m_{d}_name", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeU32Hex(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    v: u32,
) Allocator.Error!void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "0x{X:0>8}u", .{v}) catch unreachable;
    try out.appendSlice(allocator, s);
}

/// Emit a C string literal that survives the names we expect (kebab,
/// dots, colons, slashes). Backslashes and double-quotes are escaped;
/// other ASCII passes through; non-ASCII bytes are written as
/// `\xNN` octets to keep the output portable.
fn emitCStringLiteral(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    text: []const u8,
) Allocator.Error!void {
    try out.append(allocator, '"');
    var hex_buf: [8]u8 = undefined;
    for (text) |b| {
        switch (b) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (b >= 0x20 and b < 0x7F) {
                    try out.append(allocator, b);
                } else {
                    const s = std.fmt.bufPrint(&hex_buf, "\\x{X:0>2}", .{b}) catch unreachable;
                    try out.appendSlice(allocator, s);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

/// Emit the `onez_image_v1` header symbol referencing the storage
/// arrays above. The header is the single externally-visible entry
/// point the loader reads.
fn emitHeader(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    manifest: ImageManifest,
    pool: *const MarkerPool,
    effect_table: *const StackEffectTable,
    blob_plans: []const BlobEntryPlan,
    stats: ImageEmissionStats,
) Allocator.Error!void {
    var num_buf: [32]u8 = undefined;

    var module_count: u32 = 0;
    {
        var i: usize = 0;
        while (i < manifest.entries.len) {
            module_count += 1;
            const m = manifest.entries[i].module_name;
            while (i < manifest.entries.len and
                std.mem.eql(u8, manifest.entries[i].module_name, m)) : (i += 1)
            {}
        }
    }

    const has_entries = manifest.entries.len > 0;
    const modules_ref: []const u8 = if (has_entries) "onez_image_modules_storage" else "NULL";
    const words_ref: []const u8 = if (has_entries) "onez_image_words_storage" else "NULL";
    const markers_ref: []const u8 = if (pool.count() > 0) "onez_image_markers_storage" else "NULL";
    const effects_ref: []const u8 = if (effect_table.effectCount() > 1) "onez_image_stack_effects_storage" else "NULL";
    const blobs_ref: []const u8 = if (blob_plans.len > 0) "onez_image_blob_entries_storage" else "NULL";

    try out.appendSlice(allocator,
        \\__attribute__((used)) const onez_image_header_t onez_image_v1 = {
        \\    .format_version =
    );
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, " {d}", .{format_version}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .module_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{module_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .word_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{stats.word_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .marker_pool_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{pool.count()}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .typevalue_slot_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{effect_table.slotCount()}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .stack_effect_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{effect_table.effectCount()}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .blob_entry_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{blob_plans.len}) catch unreachable);
    try out.appendSlice(allocator, ",\n    ._pad = 0,\n    .modules = ");
    try out.appendSlice(allocator, modules_ref);
    try out.appendSlice(allocator, ",\n    .words = ");
    try out.appendSlice(allocator, words_ref);
    try out.appendSlice(allocator, ",\n    .markers = ");
    try out.appendSlice(allocator, markers_ref);
    try out.appendSlice(allocator, ",\n    .stack_effects = ");
    try out.appendSlice(allocator, effects_ref);
    try out.appendSlice(allocator, ",\n    .blob_entries = ");
    try out.appendSlice(allocator, blobs_ref);
    try out.appendSlice(allocator,
        \\,
        \\};
        \\
        \\
    );
}

// -- Tests --------------------------------------------------------------

const testing = std.testing;
const Instruction = value_mod.Instruction;
const Module = value_mod.Module;

test "emitImageC: empty manifest emits header with zero counts and NULL tables" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup);

    try testing.expectEqual(@as(u32, 0), stats.word_count);
    try testing.expectEqual(false, stats.blob_present);
    // Slot 0 and effect 0 are reserved sentinels even for an empty
    // manifest, so each "count" is 1 (sentinel-only) rather than 0.
    try testing.expectEqual(@as(u32, 1), stats.typevalue_slot_count);
    try testing.expectEqual(@as(u32, 1), stats.stack_effect_count);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_header_t") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_v1") != null);

    try testing.expect(std.mem.indexOf(u8, out.items, ".format_version = 2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".module_count = 0") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".word_count = 0") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".modules = NULL") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".words = NULL") != null);
}

test "emitImageC: type declarations include all schema structs" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup);

    const required_structs = [_][]const u8{
        "struct onez_image_module",
        "struct onez_image_word",
        "struct onez_image_marker",
        "struct onez_image_stack_effect",
        "struct onez_image_stack_effect_param",
        "struct onez_image_blob_descriptor_entry",
        "struct onez_image_blob_typevalue",
        "struct onez_image_blob_entry",
        "struct onez_image_header",
    };
    for (required_structs) |needle| {
        try testing.expect(std.mem.indexOf(u8, out.items, needle) != null);
    }
}

/// Build a synthetic Context populated with two modules so the
/// emitter has a manifest with multiple structural entries plus one
/// blob entry.
fn buildSyntheticImageContext(ctx: *Context) !void {
    const arena = ctx.quotationAllocator();

    const struct_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0, .column = 0 },
    });
    const blob_desc = try value_mod.createBuiltinTypeDescriptor(arena, .{});
    const blob_tv = try arena.create(value_mod.TypeValue);
    blob_tv.* = .{ .name = "t", .descriptor = blob_desc };
    const blob_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = blob_tv } }, .line = 0, .column = 0 },
    });

    const zeta = try arena.create(Module);
    zeta.* = .{ .name = "zeta", .words = .{} };
    try zeta.words.put(arena, "alpha", .{ .action = .{ .compound = struct_instrs } });
    try zeta.words.put(arena, "beta", .{ .action = .{ .compound = struct_instrs } });

    const alpha = try arena.create(Module);
    alpha.* = .{ .name = "alpha", .words = .{} };
    try alpha.words.put(arena, "good", .{ .action = .{ .compound = struct_instrs } });
    try alpha.words.put(arena, "needs-blob", .{ .action = .{ .compound = blob_instrs } });

    try ctx.module_cache_value.put(arena, "zeta", .{ .module = zeta });
    try ctx.module_cache_value.put(arena, "alpha", .{ .module = alpha });
}

test "emitImageC: module and word tables match the manifest order" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try buildSyntheticImageContext(&ctx);

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);
    try lookup.put(testing.allocator, "good", 42);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    try testing.expectEqual(@as(u32, 4), stats.word_count);
    try testing.expectEqual(true, stats.blob_present);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_modules_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_words_storage") != null);

    // Module-table entries appear in alphabetical order. The
    // module-storage section references each module's name symbol
    // (`onez_image_m_<idx>_name`), so order is encoded in the symbol
    // suffix.
    const modules_section_idx = std.mem.indexOf(u8, out.items, "onez_image_modules_storage[]").?;
    const tail = out.items[modules_section_idx..];
    const m0_idx = std.mem.indexOf(u8, tail, "onez_image_m_0_name").?;
    const m1_idx = std.mem.indexOf(u8, tail, "onez_image_m_1_name").?;
    try testing.expect(m0_idx < m1_idx);

    // The string-literal definitions also confirm the names are sorted.
    const alpha_def = std.mem.indexOf(u8, out.items, "onez_image_m_0_name[] = \"alpha\"").?;
    const zeta_def = std.mem.indexOf(u8, out.items, "onez_image_m_1_name[] = \"zeta\"").?;
    try testing.expect(alpha_def < zeta_def);

    // The matched lookup ("good" -> 42) shows up; misses fall back to
    // the sentinel.
    try testing.expect(std.mem.indexOf(u8, out.items, "0x0000002Au") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "0xFFFFFFFFu") != null);

    // Header reflects the populated tables and counts.
    try testing.expect(std.mem.indexOf(u8, out.items, ".module_count = 2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".word_count = 4") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".modules = onez_image_modules_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".words = onez_image_words_storage") != null);

    // Blob entry classification = 1 with type-value descriptor reason.
    try testing.expect(std.mem.indexOf(u8, out.items, ".classification = 1") != null);
    const blob_reason_value = @intFromEnum(BlobReason.type_val_descriptor);
    var reason_buf: [32]u8 = undefined;
    const reason_needle = std.fmt.bufPrint(&reason_buf, ".blob_reason = {d}", .{blob_reason_value}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out.items, reason_needle) != null);
}

test "emitImageC: marker pool dedupes shared marker names across words" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const struct_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    });

    const shared_marker = try arena.create(value_mod.Marker);
    shared_marker.* = .{ .name = "generic" };
    const exclusive_marker = try arena.create(value_mod.Marker);
    exclusive_marker.* = .{ .name = "never-returns" };

    const markers_a = try arena.dupe(*value_mod.Marker, &.{shared_marker});
    const markers_b = try arena.dupe(*value_mod.Marker, &.{ shared_marker, exclusive_marker });

    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "alpha", .{
        .action = .{ .compound = struct_instrs },
        .markers = markers_a,
    });
    try m.words.put(arena, "beta", .{
        .action = .{ .compound = struct_instrs },
        .markers = markers_b,
    });

    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Pool has exactly two entries (shared marker counted once).
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_mk_0_name[] = \"generic\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_mk_1_name[] = \"never-returns\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_mk_2_name") == null);

    try testing.expect(std.mem.indexOf(u8, out.items, ".marker_pool_count = 2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".markers = onez_image_markers_storage") != null);

    // Both words have a per-word markers array; each references the
    // shared `&onez_image_markers_storage[0]` entry.
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_w_0_markers") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_w_1_markers") != null);

    var occurrences: usize = 0;
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, search_idx, "&onez_image_markers_storage[0]")) |pos| {
        occurrences += 1;
        search_idx = pos + 1;
    }
    try testing.expect(occurrences >= 2);
}

test "emitImageC: stack-effect table dedupes type slots and emits sentinel index 0" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const struct_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    });

    // Two TypeValues that share identity by pointer.
    const desc_a = try value_mod.createBuiltinTypeDescriptor(arena, .{});
    const tv_a = try arena.create(value_mod.TypeValue);
    tv_a.* = .{ .name = "color", .descriptor = desc_a };

    const desc_b = try value_mod.createBuiltinTypeDescriptor(arena, .{});
    const tv_b = try arena.create(value_mod.TypeValue);
    tv_b.* = .{ .name = "shape", .descriptor = desc_b };

    // A nested quotation effect: ( q -- ) where q is itself a quotation.
    const nested_inputs = try arena.dupe(StackEffectParam, &.{.{ .name = "elem" }});
    const nested_outputs = try arena.dupe(StackEffectParam, &.{});
    const nested_effect = try arena.create(StackEffect);
    nested_effect.* = .{ .inputs = nested_inputs, .outputs = nested_outputs };

    const eff_a_inputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "x", .type_annotation = tv_a },
        .{ .name = "y", .type_annotation = tv_a }, // dedup target
    });
    const eff_a_outputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "z", .type_annotation = tv_b },
    });

    const eff_b_inputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "q", .quotation_effect = nested_effect },
    });
    const eff_b_outputs = try arena.dupe(StackEffectParam, &.{});

    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "alpha", .{
        .action = .{ .compound = struct_instrs },
        .stack_effect = .{ .inputs = eff_a_inputs, .outputs = eff_a_outputs },
    });
    try m.words.put(arena, "beta", .{
        .action = .{ .compound = struct_instrs },
        .stack_effect = .{ .inputs = eff_b_inputs, .outputs = eff_b_outputs },
    });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Sentinel + alpha + beta + nested = 4 entries, but nested only
    // appears if reachable through registerParam recursion.
    try testing.expectEqual(@as(u32, 4), stats.stack_effect_count);
    // Slot 0 = sentinel; slot 1 = tv_a; slot 2 = tv_b. Two TypeValues.
    try testing.expectEqual(@as(u32, 3), stats.typevalue_slot_count);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_stack_effects_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typevalue_slots[3]") != null);

    // Sentinel at index 0.
    try testing.expect(std.mem.indexOf(u8, out.items, "{ NULL, 0, NULL, 0 }") != null);

    // Header references the populated tables.
    try testing.expect(std.mem.indexOf(u8, out.items, ".stack_effects = onez_image_stack_effects_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".typevalue_slot_count = 3") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".stack_effect_count = 4") != null);

    // The nested-quotation param should reference an effect index >= 1.
    try testing.expect(std.mem.indexOf(u8, out.items, ".has_quotation_effect = 1") != null);

    // Two different params reference the same TypeValue slot index.
    var occurrences: usize = 0;
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, search_idx, ".typevalue_slot = 1")) |pos| {
        occurrences += 1;
        search_idx = pos + 1;
    }
    try testing.expect(occurrences >= 2);
}

test "emitImageC: word_id_lookup falls back from qualified to bare name" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try buildSyntheticImageContext(&ctx);

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);
    // Match the qualified form for one entry; bare form for another.
    try lookup.put(testing.allocator, "alpha.good", 7);
    try lookup.put(testing.allocator, "beta", 19);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    try testing.expect(std.mem.indexOf(u8, out.items, "0x00000007u") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "0x00000013u") != null);
}

test "emitImageC: required runtime-image symbols all appear" {
    // Asserts the contract that the loader and `1z inspect` rely on:
    // every populated image must expose `onez_image_v1` (the header),
    // `onez_image_modules_storage`, `onez_image_words_storage`, and
    // `onez_image_typevalue_slots` so the loader can walk them by
    // symbol name from the embedded binary.
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try buildSyntheticImageContext(&ctx);

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_v1") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_modules_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_words_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typevalue_slots") != null);
}

test "emitImageC: type_val blob produces descriptor entry table and slot reservation" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // Synthesize a single blob word whose body pushes a TypeValue with
    // a fully populated TypeDescriptor.
    const desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{ .exact = true });
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "color", .descriptor = desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "color", .{ .action = .{ .compound = instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    try testing.expectEqual(@as(u32, 1), stats.blob_typevalues_emitted);
    try testing.expectEqual(true, stats.blob_present);
    // Sentinel + the one blob TypeValue.
    try testing.expectEqual(@as(u32, 2), stats.typevalue_slot_count);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_blob_desc_0[]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_blob_typevalues_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_blob_entries_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".blob_entries = onez_image_blob_entries_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".blob_entry_count = 1") != null);
    // Word entry references blob entry index 0 and slot 1.
    try testing.expect(std.mem.indexOf(u8, out.items, ".blob_entry_idx = 0u") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".typevalue_slot = 1u") != null);
}

test "emitImageC: same TypeValue across multiple blob words shares one slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "color", .descriptor = desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "color", .{ .action = .{ .compound = instrs } });
    try m.words.put(arena, ">color", .{ .action = .{ .compound = instrs } });
    try m.words.put(arena, "color?", .{ .action = .{ .compound = instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Three blob words share one slot, so we get three blob entries
    // but the slot table only grew by 1 (sentinel + 1 = 2).
    try testing.expectEqual(@as(u32, 3), stats.blob_typevalues_emitted);
    try testing.expectEqual(@as(u32, 2), stats.typevalue_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, ".blob_entry_count = 3") != null);

    // All three words reference slot 1.
    var occurrences: usize = 0;
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, search_idx, ".typevalue_slot = 1u")) |pos| {
        occurrences += 1;
        search_idx = pos + 1;
    }
    try testing.expect(occurrences == 3);
}

test "emitImageC: structural words have sentinel blob_entry_idx" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try buildSyntheticImageContext(&ctx);

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Three structural words plus one blob word; the structurals carry
    // the sentinel and the blob carries the live index.
    var sentinel_occurrences: usize = 0;
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, search_idx, ".blob_entry_idx = 0xFFFFFFFFu")) |pos| {
        sentinel_occurrences += 1;
        search_idx = pos + 1;
    }
    try testing.expectEqual(@as(usize, 3), sentinel_occurrences);
    try testing.expect(std.mem.indexOf(u8, out.items, ".blob_entry_idx = 0u") != null);
}

test "collectBlobEntries dedupes against stack-effect-discovered TypeValues" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // One TypeValue referenced by both a stack-effect param and a
    // blob word's body. The slot pool should collapse it to a single
    // entry; both sites read slot 1.
    const desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "color", .descriptor = desc };

    const eff_inputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "x", .type_annotation = tv },
    });
    const eff_outputs = try arena.dupe(StackEffectParam, &.{});

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });

    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "color", .{
        .action = .{ .compound = instrs },
        .stack_effect = .{ .inputs = eff_inputs, .outputs = eff_outputs },
    });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Sentinel + 1 TV = 2 slots, regardless of the two reference sites.
    try testing.expectEqual(@as(u32, 2), stats.typevalue_slot_count);
    try testing.expectEqual(@as(u32, 1), stats.blob_typevalues_emitted);
}

test "emitImageC: descriptor surfaces symbol, boolean, fixnum, string, unsupported value_kind tags" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // An ffi_struct descriptor exercises three value kinds in one
    // record: symbol (the `type` discriminator), boolean (the four
    // universal flags), fixnum (`ffi-layout`), and unsupported (the
    // `fields` placeholder for the type_val array). A resource
    // TypeValue follows below to add the string kind.
    const ffi_desc = try value_mod.createTypeDescriptor(arena, .{
        .ffi_struct = .{ .ffi_layout = 42 },
    }, .{});
    const ffi_tv = try arena.create(value_mod.TypeValue);
    ffi_tv.* = .{ .name = "ffi-kinds", .descriptor = ffi_desc };
    const ffi_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = ffi_tv } }, .line = 0, .column = 0 },
    });

    const res_desc = try value_mod.createTypeDescriptor(arena, .{
        .resource = .{ .resource_kind = "demo-handle" },
    }, .{});
    const res_tv = try arena.create(value_mod.TypeValue);
    res_tv.* = .{ .name = "res-kinds", .descriptor = res_desc };
    const res_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = res_tv } }, .line = 0, .column = 0 },
    });

    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "ffi-kinds", .{ .action = .{ .compound = ffi_instrs } });
    try m.words.put(arena, "res-kinds", .{ .action = .{ .compound = res_instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Each value_kind tag the emitter can produce appears at least once.
    try testing.expect(std.mem.indexOf(u8, out.items, ".value_kind = 0") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".value_kind = 1") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".value_kind = 2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".value_kind = 3") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".value_kind = 5") != null);
    // Specific payloads survive the round-trip.
    try testing.expect(std.mem.indexOf(u8, out.items, ".string_value = \"ffi-struct-type\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".string_value = \"demo-handle\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".fixnum_value = 42") != null);
}

test "emitImageC: descriptor entries are sorted by key" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // A virtual descriptor with all four universal flags produces the
    // five base keys (`type`, `numeric`, `exact`, `integer`, `mutable`).
    // The emitter must surface them in lexicographic order.
    const desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{ .exact = true });
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "color", .descriptor = desc };
    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "color", .{ .action = .{ .compound = instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // The expected positions follow the lex order: exact, integer,
    // mutable, numeric, type.
    const i_exact = std.mem.indexOf(u8, out.items, ".key = \"exact\"").?;
    const i_integer = std.mem.indexOf(u8, out.items, ".key = \"integer\"").?;
    const i_mutable = std.mem.indexOf(u8, out.items, ".key = \"mutable\"").?;
    const i_numeric = std.mem.indexOf(u8, out.items, ".key = \"numeric\"").?;
    const i_type = std.mem.indexOf(u8, out.items, ".key = \"type\"").?;

    try testing.expect(i_exact < i_integer);
    try testing.expect(i_integer < i_mutable);
    try testing.expect(i_mutable < i_numeric);
    try testing.expect(i_numeric < i_type);
}

test "emitImageC: structural compound emits body bytecode symbol" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const body = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 0, .column = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "twiddle", .{ .action = .{ .compound = body } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // The byte-array definition appears, and the word-table row points
    // at it with a non-zero length.
    try testing.expect(std.mem.indexOf(u8, out.items, "static const uint8_t onez_image_w_0_body[] = {") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".body_bytecode = onez_image_w_0_body") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".body_bytecode = NULL") == null);
}

test "emitImageC: blob word does not emit body bytecode" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // A blob-path word: a single `push_literal: type_val` body. The
    // blob loader rewrites the body at startup, so emission skips the
    // bytecode bytes.
    const desc = try value_mod.createBuiltinTypeDescriptor(arena, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "color", .descriptor = desc };
    const body = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "color", .{ .action = .{ .compound = body } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_w_0_body[]") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".body_bytecode = NULL") != null);
}

test "emitImageC: empty compound body emits NULL bytecode" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const empty_body: []const Instruction = &.{};
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "noop", .{ .action = .{ .compound = empty_body } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_w_0_body[]") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".body_bytecode = NULL") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".body_bytecode_len = 0") != null);
}

test "emitImageC: structural bytecode round-trips through decoder" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // A purely structural body so classification keeps the word on
    // the bytecode-emitting path. Confirms the bytes appended to the
    // C array round-trip through the decoder, not just that a symbol
    // is referenced from the word table.
    const body = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 21 } }, .line = 5, .column = 7 },
        .{ .op = .{ .call_word = "double" }, .line = 5, .column = 9 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "twiddle", .{ .action = .{ .compound = body } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    const sym = "onez_image_w_0_body[] = {";
    const start = std.mem.indexOf(u8, out.items, sym) orelse return error.TestExpectedSymbol;
    const after = start + sym.len;
    const end_offset = std.mem.indexOfPos(u8, out.items, after, "};") orelse return error.TestExpectedTerminator;
    const list = out.items[after..end_offset];

    var bytes: std.ArrayListUnmanaged(u8) = .{};
    defer bytes.deinit(testing.allocator);
    var iter = std.mem.tokenizeScalar(u8, list, ',');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \n\t");
        if (trimmed.len == 0) continue;
        const v = try std.fmt.parseInt(u8, trimmed, 10);
        try bytes.append(testing.allocator, v);
    }

    const decoded = try instruction_bytecode.deserializeQuotationInstructions(bytes.items, testing.allocator);
    defer {
        for (decoded) |instr| {
            switch (instr.op) {
                .call_word => |n| testing.allocator.free(n),
                else => {},
            }
        }
        testing.allocator.free(decoded);
    }
    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expect(decoded[0].op == .push_literal);
    try testing.expectEqual(@as(i64, 21), decoded[0].op.push_literal.fixnum);
    try testing.expectEqual(@as(usize, 5), decoded[0].line);
    try testing.expectEqual(@as(usize, 7), decoded[0].column);
    try testing.expect(decoded[1].op == .call_word);
    try testing.expectEqualStrings("double", decoded[1].op.call_word);
}

test "emitImageC: generator-provenanced word skips body bytecode" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // Generator-emitted words encode @intFromPtr of a runtime type as
    // a fixnum literal -- non-deterministic across builds. Provenance
    // is the signal we filter on; the body shape mirrors what
    // `definePredicate` produces.
    const body = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 184500376 } }, .line = 0, .column = 0 },
        .{ .op = .{ .call_word = "native.virtual-type-predicate" }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "color?", .{
        .action = .{ .compound = body },
        .provenance = .{ .generator = "virtual", .parent = "color", .role = "predicate" },
    });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_w_0_body[]") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".body_bytecode = NULL") != null);
}
