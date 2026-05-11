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
pub const format_version: u32 = 3;

/// Counts that the metadata emitter plumbs back into `AotMetadata`. The
/// codegen knows these as it walks the manifest, so emitting them here
/// avoids a second pass.
pub const ImageEmissionStats = struct {
    /// Number of program-defined words in the image. Maps to
    /// `runtime-image-word-count`.
    word_count: u32 = 0,
    /// Whether any blob-path entries are present. Maps to
    /// `runtime-image-blob-present`. Always false after the
    /// `type_val` migration to the static C data path; retained as a
    /// reserved-for-future-use flag so the metadata schema stays
    /// stable.
    blob_present: bool = false,
    /// Size of the shared TypeValue slot table. May grow as later
    /// emission passes discover PIC snapshot references.
    typevalue_slot_count: u32 = 0,
    /// Number of distinct stack-effect entries (excluding the
    /// reserved sentinel at index 0).
    stack_effect_count: u32 = 0,
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

    // Per-word TypeValue-slot map. For every word whose body pushes a
    // `type_val` literal, intern the TypeValue into the shared slot
    // table and record the slot index here. The loader uses the slot
    // index to look up the runtime TypeValue after `populateTypeValueSlots`
    // has filled the table, then rewrites the word body to push that
    // TypeValue directly. Zero means "this word does not publish a
    // TypeValue".
    const word_to_typevalue_slot = try allocator.alloc(u32, manifest.entries.len);
    defer allocator.free(word_to_typevalue_slot);
    @memset(word_to_typevalue_slot, 0);
    for (manifest.entries, 0..) |entry, idx| {
        const mw_ptr = lookupModuleWord(ctx, entry) orelse continue;
        if (findTypeValueLiteral(mw_ptr)) |tv| {
            word_to_typevalue_slot[idx] = try effect_table.internType(tv);
        }
    }

    var struct_plans: std.ArrayListUnmanaged(StructTypePlan) = .{};
    defer struct_plans.deinit(allocator);
    var struct_index: std.AutoHashMapUnmanaged(*const value_mod.StructType, u32) = .{};
    defer struct_index.deinit(allocator);
    try collectDescriptorCrossRefs(&struct_plans, &struct_index, &effect_table);

    // Tracks per-word body bytecode emission. When entry is non-zero,
    // the word references `onez_image_w_<idx>_body` at that length;
    // zero means the word table emits NULL.
    const word_body_lens = try allocator.alloc(u32, manifest.entries.len);
    defer allocator.free(word_body_lens);
    @memset(word_body_lens, 0);

    try emitMarkerPool(out, allocator, &marker_pool, &stats);
    try emitTypeValueSlotTable(out, allocator, &effect_table);
    try emitStackEffectTable(out, allocator, &effect_table);
    try emitTypeValueData(out, allocator, &effect_table, struct_plans.items, &struct_index);

    try emitWordNameStrings(out, allocator, manifest);
    try emitWordBodyBytecode(out, allocator, ctx, manifest, word_body_lens);
    try emitModuleAndWordTables(out, allocator, ctx, manifest, word_id_lookup, &marker_pool, &effect_table, word_to_typevalue_slot, word_body_lens, &stats);
    try emitHeader(out, allocator, manifest, &marker_pool, &effect_table, struct_plans.items, stats);

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

/// Pre-resolved data for one image-side StructType. StructTypes are
/// reached through `virtual.anon_struct` and have no slot of their own
/// in the TypeValue slot table -- the loader allocates a parallel
/// `*StructType` per row in `onez_image_struct_types_storage[]` and
/// references it from the owning virtual descriptor by index.
const StructTypePlan = struct {
    struct_type: *const value_mod.StructType,
};

/// Walk every interned TypeValue's descriptor and `member_types` slice,
/// interning each cross-referenced TypeValue back into the slot table.
/// The walk runs to a fixed point: newly interned TypeValues may
/// themselves carry cross-references through their own descriptors, so
/// the cursor extends past the original slot count and the loop only
/// terminates when no new slot is added.
///
/// Cross-references through `virtual.anon_struct` populate the
/// `struct_plans` list; the anon-struct's `field_types` cross-references
/// intern back into the TypeValue slot table on the way through. Each
/// StructType is interned once via `struct_index` regardless of how
/// many virtual TypeValues point at it.
fn collectDescriptorCrossRefs(
    struct_plans: *std.ArrayListUnmanaged(StructTypePlan),
    struct_index: *std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    effect_table: *StackEffectTable,
) Allocator.Error!void {
    var cursor: usize = 0;
    while (cursor < effect_table.type_slots.items.len) {
        const tv = effect_table.type_slots.items[cursor];
        cursor += 1;
        if (tv.member_types) |members| {
            for (members) |m| {
                _ = try effect_table.internType(m);
            }
        }
        const desc = tv.descriptor orelse continue;
        try internDescriptorCrossRefs(struct_plans, struct_index, effect_table, desc);
    }
}

/// Intern every TypeValue and StructType reachable from `desc` into
/// the slot table / struct-plan list. Recursive only into StructType
/// field_types (the StructType itself is interned just once via
/// `struct_index`); reachable TypeValues feed back through the
/// fixed-point cursor in `collectDescriptorCrossRefs`.
fn internDescriptorCrossRefs(
    struct_plans: *std.ArrayListUnmanaged(StructTypePlan),
    struct_index: *std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    effect_table: *StackEffectTable,
    desc: *const value_mod.TypeDescriptor,
) Allocator.Error!void {
    switch (desc.kind) {
        .builtin, .sentinel, .union_, .resource => {},
        .struct_ => |sd| {
            for (sd.field_types) |maybe| {
                if (maybe) |tv| _ = try effect_table.internType(tv);
            }
        },
        .virtual => |vd| {
            if (vd.inner_type) |tv| _ = try effect_table.internType(tv);
            for (vd.type_params) |tv| _ = try effect_table.internType(tv);
            if (vd.anon_struct) |st| {
                _ = try internStructType(struct_plans, struct_index, effect_table, st);
            }
        },
        .enum_ => |ed| {
            for (ed.variants) |v| {
                if (v.type_val) |tv| _ = try effect_table.internType(tv);
            }
        },
        .enum_variant => |evd| {
            if (evd.parent) |tv| _ = try effect_table.internType(tv);
            if (evd.inner_type) |tv| _ = try effect_table.internType(tv);
        },
        .ffi_struct => |fsd| {
            for (fsd.field_types) |maybe| {
                if (maybe) |tv| _ = try effect_table.internType(tv);
            }
        },
    }
}

fn internStructType(
    struct_plans: *std.ArrayListUnmanaged(StructTypePlan),
    struct_index: *std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    effect_table: *StackEffectTable,
    st: *const value_mod.StructType,
) Allocator.Error!u32 {
    if (struct_index.get(st)) |idx| return idx;
    const idx: u32 = @intCast(struct_plans.items.len);
    try struct_plans.append(effect_table.allocator, .{ .struct_type = st });
    try struct_index.put(effect_table.allocator, st, idx);
    for (st.field_types) |maybe| {
        if (maybe) |tv| _ = try effect_table.internType(tv);
    }
    return idx;
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

/// Emit the static C data tables that carry TypeValue and
/// TypeDescriptor metadata: enum-variant pool, struct-type pool,
/// typedescriptor table, and the typevalue table itself. Cross-
/// references between TypeValues encode as slot indices into the
/// `onez_image_typevalue_slots[]` table that the loader fills at
/// startup; cross-references to `StructType` (anonymous structs
/// backing virtual TypeValues) encode as indices into
/// `onez_image_struct_types_storage[]`.
///
/// Marked `__attribute__((used))` so the C compiler does not strip
/// them while the header still references the (in-tree-deprecated)
/// blob tables. Header restructuring in a follow-up step removes the
/// attribute by making the new tables reachable from
/// `onez_image_v1`.
fn emitTypeValueData(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    effect_table: *const StackEffectTable,
    struct_plans: []const StructTypePlan,
    struct_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
) Allocator.Error!void {
    if (effect_table.type_slots.items.len == 0 and struct_plans.len == 0) return;

    var num_buf: [32]u8 = undefined;

    // -- 1. Struct types (referenced by virtual.anon_struct) ----------
    if (struct_plans.len > 0) {
        for (struct_plans, 0..) |plan, i| {
            try emitStructTypeStrings(out, allocator, plan.struct_type, i, effect_table);
        }
        try out.appendSlice(allocator, "\n__attribute__((used)) static const onez_image_struct_type_t onez_image_struct_types_storage[] = {\n");
        for (struct_plans, 0..) |plan, i| {
            const st = plan.struct_type;
            try out.appendSlice(allocator, "    { .name = ");
            try writeStructTypeNameSym(out, allocator, i);
            try out.appendSlice(allocator, ", .name_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{st.name.len}) catch unreachable);
            if (st.fields.len > 0) {
                try out.appendSlice(allocator, ", .field_names = ");
                try writeStructFieldNamesSym(out, allocator, i);
                try out.appendSlice(allocator, ", .field_name_lens = ");
                try writeStructFieldNameLensSym(out, allocator, i);
            } else {
                try out.appendSlice(allocator, ", .field_names = NULL, .field_name_lens = NULL");
            }
            try out.appendSlice(allocator, ", .field_count = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{st.fields.len}) catch unreachable);
            if (st.field_types.len > 0) {
                try out.appendSlice(allocator, ", .field_type_slots = ");
                try writeStructFieldTypeSlotsSym(out, allocator, i);
            } else {
                try out.appendSlice(allocator, ", .field_type_slots = NULL");
            }
            try out.appendSlice(allocator, ", .field_type_count = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{st.field_types.len}) catch unreachable);
            try out.appendSlice(allocator, " },\n");
        }
        try out.appendSlice(allocator, "};\n\n");
    }

    // -- 2. Type descriptors + enum variant pools ---------------------
    for (effect_table.type_slots.items, 0..) |tv, i| {
        try emitTypeDescriptorStrings(out, allocator, tv, i, effect_table, struct_index);
    }

    try out.appendSlice(allocator, "\n__attribute__((used)) static const onez_image_typedescriptor_t onez_image_typedescriptors_storage[] = {\n");
    for (effect_table.type_slots.items, 0..) |tv, i| {
        try emitTypeDescriptorRow(out, allocator, tv, i, effect_table, struct_index);
    }
    try out.appendSlice(allocator, "};\n\n");

    // -- 3. Member-type slot arrays + TypeValue table -----------------
    for (effect_table.type_slots.items, 0..) |tv, i| {
        try emitTypeValueStrings(out, allocator, tv, i, effect_table);
    }

    try out.appendSlice(allocator, "\n__attribute__((used)) static const onez_image_typevalue_t onez_image_typevalues_storage[] = {\n");
    for (effect_table.type_slots.items, 0..) |tv, i| {
        const slot = i + 1;
        try out.appendSlice(allocator, "    { .name = ");
        try writeTypeValueNameSym(out, allocator, i);
        try out.appendSlice(allocator, ", .name_len = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{tv.name.len}) catch unreachable);
        try out.appendSlice(allocator, ", .slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{slot}) catch unreachable);
        try out.appendSlice(allocator, ", .descriptor = ");
        if (tv.descriptor != null) {
            try out.appendSlice(allocator, "&onez_image_typedescriptors_storage[");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
            try out.appendSlice(allocator, "]");
        } else {
            try out.appendSlice(allocator, "NULL");
        }
        const mt_len: usize = if (tv.member_types) |m| m.len else 0;
        if (mt_len > 0) {
            try out.appendSlice(allocator, ", .member_type_slots = ");
            try writeTypeValueMembersSym(out, allocator, i);
        } else {
            try out.appendSlice(allocator, ", .member_type_slots = NULL");
        }
        try out.appendSlice(allocator, ", .member_type_count = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{mt_len}) catch unreachable);
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn typeKindIndex(kind: value_mod.TypeKindData) u8 {
    return switch (kind) {
        .builtin => 0,
        .sentinel => 1,
        .struct_ => 2,
        .virtual => 3,
        .enum_ => 4,
        .enum_variant => 5,
        .resource => 6,
        .ffi_struct => 7,
        .union_ => 8,
    };
}

fn lookupTypeSlot(
    effect_table: *const StackEffectTable,
    maybe_tv: ?*const value_mod.TypeValue,
) u32 {
    const tv = maybe_tv orelse return 0;
    return effect_table.type_slot_index.get(tv) orelse 0;
}

/// Emit auxiliary strings + arrays needed by one struct-type row.
fn emitStructTypeStrings(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    st: *const value_mod.StructType,
    idx: usize,
    effect_table: *const StackEffectTable,
) Allocator.Error!void {
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "static const char ");
    try writeStructTypeNameSym(out, allocator, idx);
    try out.appendSlice(allocator, "[] = ");
    try emitCStringLiteral(out, allocator, st.name);
    try out.appendSlice(allocator, ";\n");

    if (st.fields.len > 0) {
        for (st.fields, 0..) |fname, fi| {
            try out.appendSlice(allocator, "static const char ");
            try writeStructFieldNameSym(out, allocator, idx, fi);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, fname);
            try out.appendSlice(allocator, ";\n");
        }

        try out.appendSlice(allocator, "static const char *const ");
        try writeStructFieldNamesSym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = {");
        for (st.fields, 0..) |_, fi| {
            if (fi > 0) try out.append(allocator, ',');
            try out.append(allocator, ' ');
            try writeStructFieldNameSym(out, allocator, idx, fi);
        }
        try out.appendSlice(allocator, " };\n");

        try out.appendSlice(allocator, "static const uint32_t ");
        try writeStructFieldNameLensSym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = {");
        for (st.fields, 0..) |fname, fi| {
            if (fi > 0) try out.append(allocator, ',');
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{fname.len}) catch unreachable);
        }
        try out.appendSlice(allocator, " };\n");
    }

    if (st.field_types.len > 0) {
        try out.appendSlice(allocator, "static const uint32_t ");
        try writeStructFieldTypeSlotsSym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = {");
        for (st.field_types, 0..) |maybe_tv, fi| {
            if (fi > 0) try out.append(allocator, ',');
            try out.append(allocator, ' ');
            const slot = lookupTypeSlot(effect_table, maybe_tv);
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{slot}) catch unreachable);
        }
        try out.appendSlice(allocator, " };\n");
    }
}

fn writeStructTypeNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_st_{d}_name", .{idx}) catch unreachable);
}

fn writeStructFieldNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    st_idx: usize,
    fi: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_st_{d}_f{d}_name", .{ st_idx, fi }) catch unreachable);
}

fn writeStructFieldNamesSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_st_{d}_field_names", .{idx}) catch unreachable);
}

fn writeStructFieldNameLensSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_st_{d}_field_name_lens", .{idx}) catch unreachable);
}

fn writeStructFieldTypeSlotsSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_st_{d}_field_type_slots", .{idx}) catch unreachable);
}

/// Emit per-descriptor auxiliary strings and arrays.
fn emitTypeDescriptorStrings(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    tv: *const value_mod.TypeValue,
    idx: usize,
    effect_table: *const StackEffectTable,
    struct_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
) Allocator.Error!void {
    _ = struct_index;
    var num_buf: [32]u8 = undefined;
    const desc = tv.descriptor orelse return;
    switch (desc.kind) {
        .builtin, .sentinel, .union_ => {},
        .struct_ => |sd| try emitFieldArrays(out, allocator, idx, sd.fields, sd.field_types, effect_table),
        .ffi_struct => |fsd| try emitFieldArrays(out, allocator, idx, fsd.fields, fsd.field_types, effect_table),
        .virtual => |vd| {
            if (vd.type_params.len > 0) {
                try out.appendSlice(allocator, "static const uint32_t ");
                try writeTypeParamSlotsSym(out, allocator, idx);
                try out.appendSlice(allocator, "[] = {");
                for (vd.type_params, 0..) |tp, ti| {
                    if (ti > 0) try out.append(allocator, ',');
                    try out.append(allocator, ' ');
                    const slot = effect_table.type_slot_index.get(tp) orelse 0;
                    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{slot}) catch unreachable);
                }
                try out.appendSlice(allocator, " };\n");
            }
        },
        .enum_ => |ed| {
            if (ed.variants.len > 0) {
                for (ed.variants, 0..) |v, vi| {
                    try out.appendSlice(allocator, "static const char ");
                    try writeEnumVariantNameSym(out, allocator, idx, vi);
                    try out.appendSlice(allocator, "[] = ");
                    try emitCStringLiteral(out, allocator, v.name);
                    try out.appendSlice(allocator, ";\n");
                }
                try out.appendSlice(allocator, "static const onez_image_enum_variant_t ");
                try writeEnumVariantsSym(out, allocator, idx);
                try out.appendSlice(allocator, "[] = {\n");
                for (ed.variants, 0..) |v, vi| {
                    const slot = lookupTypeSlot(effect_table, v.type_val);
                    try out.appendSlice(allocator, "    { .name = ");
                    try writeEnumVariantNameSym(out, allocator, idx, vi);
                    try out.appendSlice(allocator, ", .name_len = ");
                    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{v.name.len}) catch unreachable);
                    try out.appendSlice(allocator, ", .type_slot = ");
                    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{slot}) catch unreachable);
                    try out.appendSlice(allocator, " },\n");
                }
                try out.appendSlice(allocator, "};\n");
            }
        },
        .enum_variant => {},
        .resource => |rd| {
            try out.appendSlice(allocator, "static const char ");
            try writeResourceKindSym(out, allocator, idx);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, rd.resource_kind);
            try out.appendSlice(allocator, ";\n");
        },
    }
}

fn emitFieldArrays(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
    fields: []const []const u8,
    field_types: []const ?*const value_mod.TypeValue,
    effect_table: *const StackEffectTable,
) Allocator.Error!void {
    var num_buf: [32]u8 = undefined;
    if (fields.len > 0) {
        for (fields, 0..) |fname, fi| {
            try out.appendSlice(allocator, "static const char ");
            try writeDescFieldNameSym(out, allocator, idx, fi);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, fname);
            try out.appendSlice(allocator, ";\n");
        }
        try out.appendSlice(allocator, "static const char *const ");
        try writeDescFieldNamesSym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = {");
        for (fields, 0..) |_, fi| {
            if (fi > 0) try out.append(allocator, ',');
            try out.append(allocator, ' ');
            try writeDescFieldNameSym(out, allocator, idx, fi);
        }
        try out.appendSlice(allocator, " };\n");

        try out.appendSlice(allocator, "static const uint32_t ");
        try writeDescFieldNameLensSym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = {");
        for (fields, 0..) |fname, fi| {
            if (fi > 0) try out.append(allocator, ',');
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{fname.len}) catch unreachable);
        }
        try out.appendSlice(allocator, " };\n");
    }
    if (field_types.len > 0) {
        try out.appendSlice(allocator, "static const uint32_t ");
        try writeDescFieldTypeSlotsSym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = {");
        for (field_types, 0..) |maybe_tv, fi| {
            if (fi > 0) try out.append(allocator, ',');
            try out.append(allocator, ' ');
            const slot = lookupTypeSlot(effect_table, maybe_tv);
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{slot}) catch unreachable);
        }
        try out.appendSlice(allocator, " };\n");
    }
}

fn writeDescFieldNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
    fi: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_td_{d}_f{d}_name", .{ idx, fi }) catch unreachable);
}

fn writeDescFieldNamesSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_td_{d}_field_names", .{idx}) catch unreachable);
}

fn writeDescFieldNameLensSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_td_{d}_field_name_lens", .{idx}) catch unreachable);
}

fn writeDescFieldTypeSlotsSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_td_{d}_field_type_slots", .{idx}) catch unreachable);
}

fn writeTypeParamSlotsSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_td_{d}_type_param_slots", .{idx}) catch unreachable);
}

fn writeEnumVariantsSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_td_{d}_variants", .{idx}) catch unreachable);
}

fn writeEnumVariantNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
    vi: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_td_{d}_v{d}_name", .{ idx, vi }) catch unreachable);
}

fn writeResourceKindSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_td_{d}_resource_kind", .{idx}) catch unreachable);
}

/// Emit one row of the `onez_image_typedescriptors_storage[]` table.
fn emitTypeDescriptorRow(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    tv: *const value_mod.TypeValue,
    idx: usize,
    effect_table: *const StackEffectTable,
    struct_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
) Allocator.Error!void {
    var num_buf: [32]u8 = undefined;
    // Zero-default descriptor for TypeValues with desc == null.
    if (tv.descriptor == null) {
        try out.appendSlice(allocator, "    { .numeric = 0, .exact = 0, .integer = 0, .mutable = 0, .kind = 0, ._pad = {0,0,0}, .field_names = NULL, .field_name_lens = NULL, .field_count = 0, .field_type_slots = NULL, .field_type_count = 0, .inner_type_slot = 0, .anon_struct_idx = 0xFFFFFFFFu, .type_param_slots = NULL, .type_param_count = 0, .parent_type_slot = 0, .variants = NULL, .variant_count = 0, .resource_kind = NULL, .resource_kind_len = 0, .ffi_layout = 0 },\n");
        return;
    }
    const desc = tv.descriptor.?;

    try out.appendSlice(allocator, "    { .numeric = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{@intFromBool(desc.numeric)}) catch unreachable);
    try out.appendSlice(allocator, ", .exact = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{@intFromBool(desc.exact)}) catch unreachable);
    try out.appendSlice(allocator, ", .integer = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{@intFromBool(desc.integer)}) catch unreachable);
    try out.appendSlice(allocator, ", .mutable = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{@intFromBool(desc.mutable)}) catch unreachable);
    try out.appendSlice(allocator, ", .kind = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{typeKindIndex(desc.kind)}) catch unreachable);
    try out.appendSlice(allocator, ", ._pad = {0,0,0}");

    // Initialize fields/field_types based on kind.
    var field_count: usize = 0;
    var field_type_count: usize = 0;
    var has_field_names = false;
    var has_field_type_slots = false;
    switch (desc.kind) {
        .struct_ => |sd| {
            field_count = sd.fields.len;
            field_type_count = sd.field_types.len;
            has_field_names = sd.fields.len > 0;
            has_field_type_slots = sd.field_types.len > 0;
        },
        .ffi_struct => |fsd| {
            field_count = fsd.fields.len;
            field_type_count = fsd.field_types.len;
            has_field_names = fsd.fields.len > 0;
            has_field_type_slots = fsd.field_types.len > 0;
        },
        else => {},
    }
    if (has_field_names) {
        try out.appendSlice(allocator, ", .field_names = ");
        try writeDescFieldNamesSym(out, allocator, idx);
        try out.appendSlice(allocator, ", .field_name_lens = ");
        try writeDescFieldNameLensSym(out, allocator, idx);
    } else {
        try out.appendSlice(allocator, ", .field_names = NULL, .field_name_lens = NULL");
    }
    try out.appendSlice(allocator, ", .field_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{field_count}) catch unreachable);
    if (has_field_type_slots) {
        try out.appendSlice(allocator, ", .field_type_slots = ");
        try writeDescFieldTypeSlotsSym(out, allocator, idx);
    } else {
        try out.appendSlice(allocator, ", .field_type_slots = NULL");
    }
    try out.appendSlice(allocator, ", .field_type_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{field_type_count}) catch unreachable);

    // inner_type_slot
    var inner_type_slot: u32 = 0;
    switch (desc.kind) {
        .virtual => |vd| inner_type_slot = lookupTypeSlot(effect_table, vd.inner_type),
        .enum_variant => |evd| inner_type_slot = lookupTypeSlot(effect_table, evd.inner_type),
        else => {},
    }
    try out.appendSlice(allocator, ", .inner_type_slot = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{inner_type_slot}) catch unreachable);

    // anon_struct_idx
    var anon_idx_str: []const u8 = "0xFFFFFFFFu";
    var anon_idx_buf: [32]u8 = undefined;
    switch (desc.kind) {
        .virtual => |vd| if (vd.anon_struct) |st| {
            if (struct_index.get(st)) |i| {
                anon_idx_str = std.fmt.bufPrint(&anon_idx_buf, "{d}u", .{i}) catch unreachable;
            }
        },
        else => {},
    }
    try out.appendSlice(allocator, ", .anon_struct_idx = ");
    try out.appendSlice(allocator, anon_idx_str);

    // type_param_slots
    var type_param_count: usize = 0;
    var has_type_param_slots = false;
    switch (desc.kind) {
        .virtual => |vd| {
            type_param_count = vd.type_params.len;
            has_type_param_slots = vd.type_params.len > 0;
        },
        else => {},
    }
    if (has_type_param_slots) {
        try out.appendSlice(allocator, ", .type_param_slots = ");
        try writeTypeParamSlotsSym(out, allocator, idx);
    } else {
        try out.appendSlice(allocator, ", .type_param_slots = NULL");
    }
    try out.appendSlice(allocator, ", .type_param_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{type_param_count}) catch unreachable);

    // parent_type_slot
    var parent_slot: u32 = 0;
    switch (desc.kind) {
        .enum_variant => |evd| parent_slot = lookupTypeSlot(effect_table, evd.parent),
        else => {},
    }
    try out.appendSlice(allocator, ", .parent_type_slot = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{parent_slot}) catch unreachable);

    // variants
    var variant_count: usize = 0;
    var has_variants = false;
    switch (desc.kind) {
        .enum_ => |ed| {
            variant_count = ed.variants.len;
            has_variants = ed.variants.len > 0;
        },
        else => {},
    }
    if (has_variants) {
        try out.appendSlice(allocator, ", .variants = ");
        try writeEnumVariantsSym(out, allocator, idx);
    } else {
        try out.appendSlice(allocator, ", .variants = NULL");
    }
    try out.appendSlice(allocator, ", .variant_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{variant_count}) catch unreachable);

    // resource_kind
    switch (desc.kind) {
        .resource => |rd| {
            try out.appendSlice(allocator, ", .resource_kind = ");
            try writeResourceKindSym(out, allocator, idx);
            try out.appendSlice(allocator, ", .resource_kind_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{rd.resource_kind.len}) catch unreachable);
        },
        else => {
            try out.appendSlice(allocator, ", .resource_kind = NULL, .resource_kind_len = 0");
        },
    }

    // ffi_layout
    var ffi_layout: u64 = 0;
    switch (desc.kind) {
        .ffi_struct => |fsd| ffi_layout = @intCast(fsd.ffi_layout),
        else => {},
    }
    try out.appendSlice(allocator, ", .ffi_layout = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{ffi_layout}) catch unreachable);
    try out.appendSlice(allocator, "u },\n");
}

/// Emit per-TypeValue auxiliary strings: the name and (if present)
/// the member_type_slots array.
fn emitTypeValueStrings(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    tv: *const value_mod.TypeValue,
    idx: usize,
    effect_table: *const StackEffectTable,
) Allocator.Error!void {
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "static const char ");
    try writeTypeValueNameSym(out, allocator, idx);
    try out.appendSlice(allocator, "[] = ");
    try emitCStringLiteral(out, allocator, tv.name);
    try out.appendSlice(allocator, ";\n");

    const mts: []const *const value_mod.TypeValue = if (tv.member_types) |m| m else &.{};
    if (mts.len > 0) {
        try out.appendSlice(allocator, "static const uint32_t ");
        try writeTypeValueMembersSym(out, allocator, idx);
        try out.appendSlice(allocator, "[] = {");
        for (mts, 0..) |m, mi| {
            if (mi > 0) try out.append(allocator, ',');
            try out.append(allocator, ' ');
            const slot = effect_table.type_slot_index.get(m) orelse 0;
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{slot}) catch unreachable);
        }
        try out.appendSlice(allocator, " };\n");
    }
}

fn writeTypeValueNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_tv_{d}_name", .{idx}) catch unreachable);
}

fn writeTypeValueMembersSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_tv_{d}_members", .{idx}) catch unreachable);
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
        \\/* AOT runtime image: static C data layout. */
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
        \\    uint32_t typevalue_slot;          /* 0 when this word does not publish a TypeValue. */
        \\} onez_image_word_t;
        \\
        \\/* TypeValue static C data schema. Every TypeValue reachable from any */
        \\/* module-private word's body or from another descriptor's cross-     */
        \\/* references gets a row in onez_image_typevalues_storage[] and a    */
        \\/* paired row in onez_image_typedescriptors_storage[] indexed by the */
        \\/* same slot number. Cross-references between TypeValues encode as   */
        \\/* slot indices into onez_image_typevalue_slots[]; the loader fills  */
        \\/* the slot table during pass 2 of the load and reads it during      */
        \\/* pass 3 when materializing each descriptor's kind-specific data.   */
        \\/* `kind` matches Zig TypeKind: 0=builtin, 1=sentinel, 2=struct_,    */
        \\/* 3=virtual, 4=enum_, 5=enum_variant, 6=resource, 7=ffi_struct,     */
        \\/* 8=union_.                                                          */
        \\typedef struct onez_image_enum_variant {
        \\    const char *name;
        \\    uint32_t name_len;
        \\    uint32_t type_slot;               /* 0 if variant has no inner type. */
        \\} onez_image_enum_variant_t;
        \\
        \\typedef struct onez_image_struct_type {
        \\    const char *name;
        \\    uint32_t name_len;
        \\    const char *const *field_names;
        \\    const uint32_t    *field_name_lens;
        \\    uint32_t           field_count;
        \\    const uint32_t    *field_type_slots;
        \\    uint32_t           field_type_count;
        \\} onez_image_struct_type_t;
        \\
        \\typedef struct onez_image_typedescriptor {
        \\    uint8_t  numeric;
        \\    uint8_t  exact;
        \\    uint8_t  integer;
        \\    uint8_t  mutable;
        \\    uint8_t  kind;
        \\    uint8_t  _pad[3];
        \\    /* struct_, ffi_struct: field names + optional type slots. */
        \\    const char *const *field_names;
        \\    const uint32_t    *field_name_lens;
        \\    uint32_t           field_count;
        \\    const uint32_t    *field_type_slots;
        \\    uint32_t           field_type_count;
        \\    /* virtual, enum_variant: inner type slot (0 = absent). */
        \\    uint32_t inner_type_slot;
        \\    /* virtual: anon_struct_idx into onez_image_struct_types_storage    */
        \\    /* (0xFFFFFFFFu when absent).                                       */
        \\    uint32_t anon_struct_idx;
        \\    /* virtual: parameterized type-parameter slots. */
        \\    const uint32_t *type_param_slots;
        \\    uint32_t        type_param_count;
        \\    /* enum_variant: parent type slot (0 = absent). */
        \\    uint32_t parent_type_slot;
        \\    /* enum_: variants array. */
        \\    const struct onez_image_enum_variant *variants;
        \\    uint32_t variant_count;
        \\    /* resource: kind name. */
        \\    const char *resource_kind;
        \\    uint32_t    resource_kind_len;
        \\    /* ffi_struct: layout pointer-as-fixnum. */
        \\    uint64_t ffi_layout;
        \\} onez_image_typedescriptor_t;
        \\
        \\typedef struct onez_image_typevalue {
        \\    const char *name;
        \\    uint32_t    name_len;
        \\    uint32_t    slot;                 /* index into onez_image_typevalue_slots */
        \\    const struct onez_image_typedescriptor *descriptor;
        \\    const uint32_t *member_type_slots;
        \\    uint32_t        member_type_count;
        \\} onez_image_typevalue_t;
        \\
        \\typedef struct onez_image_header {
        \\    uint32_t format_version;
        \\    uint32_t module_count;
        \\    uint32_t word_count;
        \\    uint32_t marker_pool_count;
        \\    uint32_t typevalue_slot_count;
        \\    uint32_t stack_effect_count;
        \\    uint32_t typevalue_count;
        \\    uint32_t struct_type_count;
        \\    const struct onez_image_module *modules;
        \\    const struct onez_image_word *words;
        \\    const struct onez_image_marker *markers;
        \\    const struct onez_image_stack_effect *stack_effects;
        \\    const struct onez_image_typevalue *typevalues;
        \\    const struct onez_image_typedescriptor *typedescriptors;
        \\    const struct onez_image_struct_type *struct_types;
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
        // Words that push a TypeValue have their body rewritten by the
        // runtime-image loader after it allocates the runtime
        // TypeValue. Encoding the body as bytecode would lower the
        // `push_literal: type_val` to `call_word value.name`, which for
        // a type-defining word is the word itself -- infinite
        // recursion at runtime. Skip emission and let the loader
        // populate the body from `typevalue_slot`.
        if (findTypeValueLiteral(mw_ptr) != null) continue;

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
/// up front by `emitWordNameStrings` so the typevalue table (emitted
/// earlier) can reference them.
fn emitModuleAndWordTables(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    ctx: *const Context,
    manifest: ImageManifest,
    word_id_lookup: *const std.StringHashMapUnmanaged(u32),
    pool: *const MarkerPool,
    effect_table: *const StackEffectTable,
    word_to_typevalue_slot: []const u32,
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
    for (manifest.entries, 0..) |entry, idx| {
        if (!std.mem.eql(u8, entry.module_name, current_module_name)) {
            current_module_idx += 1;
            current_module_name = entry.module_name;
        }

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

        try out.appendSlice(allocator, "        .typevalue_slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}u", .{word_to_typevalue_slot[idx]}) catch unreachable);
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
    stats.blob_present = manifest.blob_count > 0;

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
    struct_plans: []const StructTypePlan,
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

    const typevalue_count: u32 = @intCast(effect_table.type_slots.items.len);
    const struct_type_count: u32 = @intCast(struct_plans.len);

    const has_entries = manifest.entries.len > 0;
    const modules_ref: []const u8 = if (has_entries) "onez_image_modules_storage" else "NULL";
    const words_ref: []const u8 = if (has_entries) "onez_image_words_storage" else "NULL";
    const markers_ref: []const u8 = if (pool.count() > 0) "onez_image_markers_storage" else "NULL";
    const effects_ref: []const u8 = if (effect_table.effectCount() > 1) "onez_image_stack_effects_storage" else "NULL";
    const typevalues_ref: []const u8 = if (typevalue_count > 0) "onez_image_typevalues_storage" else "NULL";
    const typedescriptors_ref: []const u8 = if (typevalue_count > 0) "onez_image_typedescriptors_storage" else "NULL";
    const struct_types_ref: []const u8 = if (struct_type_count > 0) "onez_image_struct_types_storage" else "NULL";

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
    try out.appendSlice(allocator, ",\n    .typevalue_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{typevalue_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .struct_type_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{struct_type_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .modules = ");
    try out.appendSlice(allocator, modules_ref);
    try out.appendSlice(allocator, ",\n    .words = ");
    try out.appendSlice(allocator, words_ref);
    try out.appendSlice(allocator, ",\n    .markers = ");
    try out.appendSlice(allocator, markers_ref);
    try out.appendSlice(allocator, ",\n    .stack_effects = ");
    try out.appendSlice(allocator, effects_ref);
    try out.appendSlice(allocator, ",\n    .typevalues = ");
    try out.appendSlice(allocator, typevalues_ref);
    try out.appendSlice(allocator, ",\n    .typedescriptors = ");
    try out.appendSlice(allocator, typedescriptors_ref);
    try out.appendSlice(allocator, ",\n    .struct_types = ");
    try out.appendSlice(allocator, struct_types_ref);
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

    try testing.expect(std.mem.indexOf(u8, out.items, ".format_version = 3") != null);
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
        "struct onez_image_typevalue",
        "struct onez_image_typedescriptor",
        "struct onez_image_struct_type",
        "struct onez_image_enum_variant",
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
    const blob_mm = try arena.create(value_mod.MutableMap);
    blob_mm.* = .{};
    const blob_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .mutable_map = blob_mm } }, .line = 0, .column = 0 },
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

    // The blob word (`needs-blob` pushes a mutable_map) classifies as blob.
    try testing.expect(std.mem.indexOf(u8, out.items, ".classification = 1") != null);
    const blob_reason_value = @intFromEnum(BlobReason.mutable_map);
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

test "emitImageC: type_val word writes typevalue_slot and reserves a slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

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

    try testing.expectEqual(false, stats.blob_present);
    try testing.expectEqual(@as(u32, 2), stats.typevalue_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typevalues_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typedescriptors_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".typevalue_slot = 1u") != null);
}

test "emitImageC: same TypeValue across multiple words shares one slot" {
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

    try testing.expectEqual(@as(u32, 2), stats.typevalue_slot_count);

    var occurrences: usize = 0;
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, search_idx, ".typevalue_slot = 1u")) |pos| {
        occurrences += 1;
        search_idx = pos + 1;
    }
    try testing.expect(occurrences == 3);
}

test "emitImageC: structural words without a type_val write typevalue_slot = 0" {
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

    // Four words; none push a type_val, so every row's typevalue_slot is 0.
    var occurrences: usize = 0;
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, search_idx, ".typevalue_slot = 0u")) |pos| {
        occurrences += 1;
        search_idx = pos + 1;
    }
    try testing.expectEqual(@as(usize, 4), occurrences);
}

test "collectTypeValueData dedupes against stack-effect-discovered TypeValues" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // One TypeValue referenced by both a stack-effect param and a
    // word's body. The slot pool should collapse it to a single entry;
    // both sites read slot 1.
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
}

test "collectDescriptorCrossRefs interns struct field_types into the slot table" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // Two field-type TypeValues that are NOT pushed by any module-private
    // word. They should still land in the slot table by virtue of being
    // descriptor cross-references on a struct TypeValue that is pushed.
    const tv_fix = try arena.create(value_mod.TypeValue);
    tv_fix.* = .{ .name = "fixnum", .descriptor = null };
    const tv_str = try arena.create(value_mod.TypeValue);
    tv_str.* = .{ .name = "string", .descriptor = null };

    const fields = try arena.dupe([]const u8, &.{ "x", "y" });
    const field_types = try arena.alloc(?*const value_mod.TypeValue, 2);
    field_types[0] = tv_fix;
    field_types[1] = tv_str;
    const desc = try value_mod.createTypeDescriptor(arena, .{
        .struct_ = .{ .fields = fields, .field_types = field_types },
    }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "point", .descriptor = desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "point", .{ .action = .{ .compound = instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Sentinel + (point, fixnum, string) = 4 slots. The two field
    // types were collected by the descriptor cross-ref walk even
    // though no word pushes them.
    try testing.expectEqual(@as(u32, 4), stats.typevalue_slot_count);
}

test "collectDescriptorCrossRefs interns enum variant inner_types" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // Two variant inner-types that are not pushed by any word.
    const tv_unit = try arena.create(value_mod.TypeValue);
    tv_unit.* = .{ .name = "unit", .descriptor = null };
    const tv_str = try arena.create(value_mod.TypeValue);
    tv_str.* = .{ .name = "string", .descriptor = null };

    const variants = try arena.alloc(value_mod.Variant, 2);
    variants[0] = .{ .name = "none", .type_val = tv_unit };
    variants[1] = .{ .name = "some", .type_val = tv_str };
    const desc = try value_mod.createTypeDescriptor(arena, .{
        .enum_ = .{ .variants = variants },
    }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "option", .descriptor = desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "option", .{ .action = .{ .compound = instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Sentinel + (option, unit, string).
    try testing.expectEqual(@as(u32, 4), stats.typevalue_slot_count);
}

test "collectDescriptorCrossRefs reaches transitively through multiple descriptors" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // A -> B -> C. Only A is pushed; B and C must be reached
    // transitively through the fixed-point walk over the slot list.
    const tv_c = try arena.create(value_mod.TypeValue);
    tv_c.* = .{ .name = "C", .descriptor = null };

    const b_desc = try value_mod.createTypeDescriptor(arena, .{
        .virtual = .{ .inner_type = tv_c },
    }, .{});
    const tv_b = try arena.create(value_mod.TypeValue);
    tv_b.* = .{ .name = "B", .descriptor = b_desc };

    const a_desc = try value_mod.createTypeDescriptor(arena, .{
        .virtual = .{ .inner_type = tv_b },
    }, .{});
    const tv_a = try arena.create(value_mod.TypeValue);
    tv_a.* = .{ .name = "A", .descriptor = a_desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv_a } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "A", .{ .action = .{ .compound = instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Sentinel + (A, B, C) = 4. Transitive walk reaches C through
    // B's descriptor even though no word pushes B or C directly.
    try testing.expectEqual(@as(u32, 4), stats.typevalue_slot_count);
}

test "emitTypeValueData emits typevalue/descriptor tables with slot-indexed cross-refs" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // A struct TypeValue with two field_types. Cross-references resolve
    // through onez_image_typevalue_slots[] -- the loader walks the
    // table at startup.
    const tv_fix = try arena.create(value_mod.TypeValue);
    tv_fix.* = .{ .name = "fixnum", .descriptor = null };

    const fields = try arena.dupe([]const u8, &.{"x"});
    const field_types = try arena.alloc(?*const value_mod.TypeValue, 1);
    field_types[0] = tv_fix;
    const desc = try value_mod.createTypeDescriptor(arena, .{
        .struct_ = .{ .fields = fields, .field_types = field_types },
    }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "point", .descriptor = desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "point", .{ .action = .{ .compound = instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // The new typevalue + typedescriptor tables appear.
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typevalues_storage[] = {") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typedescriptors_storage[] = {") != null);
    // Struct field array references appear (the struct descriptor
    // emits field_names + field_type_slots).
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_td_") != null);
    // Per-name symbols match.
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_tv_0_name") != null);
}

test "emitTypeValueData emits enum variant pool referenced from descriptor row" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const tv_unit = try arena.create(value_mod.TypeValue);
    tv_unit.* = .{ .name = "unit", .descriptor = null };

    const variants = try arena.alloc(value_mod.Variant, 2);
    variants[0] = .{ .name = "red", .type_val = tv_unit };
    variants[1] = .{ .name = "blue", .type_val = tv_unit };
    const desc = try value_mod.createTypeDescriptor(arena, .{
        .enum_ = .{ .variants = variants },
    }, .{});
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

    // The enum variants pool exists; both variant names appear.
    try testing.expect(std.mem.indexOf(u8, out.items, "_variants[] = {") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"red\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"blue\"") != null);
    // The descriptor row references the variant pool via .variants =.
    try testing.expect(std.mem.indexOf(u8, out.items, ".variants = onez_image_td_") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".variant_count = 2") != null);
}

test "emitTypeValueData emits struct-type table for virtual anon_struct" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const tv_int = try arena.create(value_mod.TypeValue);
    tv_int.* = .{ .name = "int", .descriptor = null };

    const st_fields = try arena.dupe([]const u8, &.{"n"});
    const st_field_types = try arena.alloc(?*const value_mod.TypeValue, 1);
    st_field_types[0] = tv_int;
    const st = try arena.create(value_mod.StructType);
    st.* = .{
        .name = "wrap-inner",
        .fields = st_fields,
        .field_types = st_field_types,
    };

    const desc = try value_mod.createTypeDescriptor(arena, .{
        .virtual = .{ .anon_struct = st },
    }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "wrap", .descriptor = desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "wrap", .{ .action = .{ .compound = instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // The struct-type table exists with the StructType's name.
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_struct_types_storage[] = {") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"wrap-inner\"") != null);
    // The descriptor row references the struct-type by index.
    try testing.expect(std.mem.indexOf(u8, out.items, ".anon_struct_idx = 0u") != null);
}

test "collectDescriptorCrossRefs collects virtual anon_struct and its field types" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const tv_int = try arena.create(value_mod.TypeValue);
    tv_int.* = .{ .name = "int", .descriptor = null };

    const st_fields = try arena.dupe([]const u8, &.{"n"});
    const st_field_types = try arena.alloc(?*const value_mod.TypeValue, 1);
    st_field_types[0] = tv_int;
    const st = try arena.create(value_mod.StructType);
    st.* = .{
        .name = "wrapper-inner",
        .fields = st_fields,
        .field_types = st_field_types,
    };

    const desc = try value_mod.createTypeDescriptor(arena, .{
        .virtual = .{ .anon_struct = st },
    }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "wrapper", .descriptor = desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "wrapper", .{ .action = .{ .compound = instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    // Sentinel + (wrapper, int) = 3 slots. The StructType "wrapper-inner"
    // is not in the TypeValue slot table; its field types intern back.
    try testing.expectEqual(@as(u32, 3), stats.typevalue_slot_count);
}

test "emitTypeValueData renders resource descriptor with resource_kind string" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

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
    try m.words.put(arena, "res-kinds", .{ .action = .{ .compound = res_instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typedescriptors_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "demo-handle") != null);
    // kind index 6 is `resource` in the TypeKindData encoding.
    try testing.expect(std.mem.indexOf(u8, out.items, ".kind = 6") != null);
}

test "emitTypeValueData renders ffi_struct descriptor with ffi_layout" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const ffi_desc = try value_mod.createTypeDescriptor(arena, .{
        .ffi_struct = .{ .ffi_layout = 42 },
    }, .{});
    const ffi_tv = try arena.create(value_mod.TypeValue);
    ffi_tv.* = .{ .name = "ffi-kinds", .descriptor = ffi_desc };
    const ffi_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = ffi_tv } }, .line = 0, .column = 0 },
    });

    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "ffi-kinds", .{ .action = .{ .compound = ffi_instrs } });
    try ctx.module_cache_value.put(arena, "demo", .{ .module = m });

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup);

    try testing.expect(std.mem.indexOf(u8, out.items, ".ffi_layout = 42") != null);
    // kind index 7 is `ffi_struct` in the TypeKindData encoding.
    try testing.expect(std.mem.indexOf(u8, out.items, ".kind = 7") != null);
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
