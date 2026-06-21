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
const Marker = value_mod.Marker;
const Parameter = value_mod.Parameter;
const VirtualType = value_mod.VirtualType;
const Value = value_mod.Value;
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

/// `quotation_id` value a dispatch-entry row carries when its method body
/// was never reached by the freeze and so has no compiled quotation
/// function: the row's `body_bytecode` carries the interpreter-run body
/// directly, and the loader skips the quotation-function-table lookup.
pub const dispatch_interp_quotation_id_sentinel: u32 = 0xFFFFFFFF;

/// Bit positions in `onez_image_word.flags`. Kept in sync with the
/// emitted C struct.
const flag_bit_polymorphic: u8 = 1 << 0;
const flag_bit_native: u8 = 1 << 1;
const flag_bit_host_callback: u8 = 1 << 2;
const flag_bit_has_stack_effect: u8 = 1 << 3;
const flag_bit_never_returns: u8 = 1 << 4;

/// Format version emitted into `onez_image_header.format_version`. Bumped
/// when the on-disk layout changes in a way the loader cannot ignore.
pub const format_version: u32 = 10;

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
    /// Number of distinct Marker pointers reachable through compiled
    /// word bodies. Emitted as `onez_image_marker_slots[]`; nothing
    /// consumes the table yet, but its existence is a prerequisite
    /// for the slot-indexed Marker emission.
    marker_slot_count: u32 = 0,
    /// Number of distinct Parameter pointers reachable through
    /// compiled word bodies. Emitted as `onez_image_parameter_slots[]`;
    /// reserved for the slot-indexed Parameter emission.
    parameter_slot_count: u32 = 0,
    /// Number of distinct StructType pointers reachable through the
    /// descriptor cross-reference walk. Emitted as
    /// `onez_image_struct_type_slots[]`; mirrors the typevalue slot
    /// table so codegen can push struct-type literals through a
    /// link-time-resolvable slot rather than a runtime name lookup.
    struct_type_slot_count: u32 = 0,
    /// Number of distinct `.tagged` Values reachable through compiled
    /// word bodies, keyed on `(tag, inner)` pointer identity. Emitted
    /// as `onez_image_tagged_slots[]` and patched at load time with the
    /// runtime tagged Value the description row reconstructs.
    tagged_slot_count: u32 = 0,
    /// Number of distinct `*MutableMap` pointers reachable through
    /// compiled word bodies. Emitted as `onez_image_mutable_map_slots[]`
    /// and patched at load time with a freshly-allocated `*MutableMap`
    /// populated from the row's serialized entry bytes.
    mutable_map_slot_count: u32 = 0,
    /// Number of distinct `*StructInstance` pointers reachable through
    /// compiled word bodies or frozen mutable maps. Emitted as
    /// `onez_image_struct_instance_slots[]` and patched at load time with a
    /// freshly-allocated `*StructInstance` populated from the row's
    /// serialized field bytes.
    struct_instance_slot_count: u32 = 0,
    /// Number of distinct `*ProtocolDescriptor` pointers from protocol-bounded
    /// call sites. Emitted as `onez_image_protocoldescriptor_slots[]` and
    /// patched at load time by name lookup in the runtime context.
    protocoldescriptor_slot_count: u32 = 0,
    /// Number of distinct `*ConstraintCombinator` pointers reached from `.combination` annotations.
    /// Emitted as `onez_image_constraintcombinator_slots[]` and patched at load time by
    /// reconstructing each combinator from its description row.
    constraintcombinator_slot_count: u32 = 0,
    /// Number of reachable user `.quotation` method dispatch entries
    /// serialized into `onez_image_dispatch_entry_descriptions_storage[]`.
    /// The loader replays each row into `ctx.dispatch` at startup.
    dispatch_entry_slot_count: u32 = 0,
};

/// Knobs for `emitImageC`. The default (`metadata_only = false`) emits
/// a full runtime image with executable body bytecode. With
/// `metadata_only = true` the emitter retains the read-only diagnostic
/// surface (names, stack effects, markers, source locations,
/// doc-strings, provenance, type descriptors) but skips per-word body
/// bytecode and the word-level typevalue body rewrite. The loader then
/// leaves compound words with empty instruction streams so
/// `>word-info` reflects the "frozen metadata, no body" contract for
/// interpreter-free AOT binaries.
pub const ImageEmitOptions = struct {
    metadata_only: bool = false,
};

/// Aggregate of the populated slot tables, struct-plan list, marker
/// pool, and per-word typevalue-slot vector that the codegen consumer
/// and the C emitter both read. `collectImageSlots` populates it
/// once; `emitImageCFromCollection` consumes the same instance for
/// its slot-table emission.
///
/// Owned by the caller. Free with `deinit` once both the codegen
/// pass and the emit pass have finished reading from it.
pub const ImageCollection = struct {
    allocator: Allocator,
    effect_table: StackEffectTable,
    marker_pool: MarkerPool,
    struct_plans: std.ArrayListUnmanaged(StructTypePlan) = .{},
    struct_index: std.AutoHashMapUnmanaged(*const value_mod.StructType, u32) = .{},
    word_to_typevalue_slot: []u32,

    pub fn deinit(self: *ImageCollection) void {
        self.struct_index.deinit(self.allocator);
        self.struct_plans.deinit(self.allocator);
        self.marker_pool.deinit();
        self.effect_table.deinit();
        self.allocator.free(self.word_to_typevalue_slot);
    }

    /// Look up the slot index for a StructType. Returns null when the
    /// pointer has not been interned via the collection walk. Codegen
    /// consumers gate slot-table emission on a non-null return.
    pub fn lookupStructTypeSlot(self: *const ImageCollection, st: *const value_mod.StructType) ?u32 {
        return self.struct_index.get(st);
    }
};

/// Run every collection walk that backs the slot tables, returning
/// the populated `ImageCollection`. The caller takes ownership and
/// must call `deinit` once it has finished consuming the result.
///
/// Splitting collection from emission lets `emitProgramC` populate
/// the slot maps before Pass 2 codegen runs, so compiled word bodies
/// can reference link-time-resolvable slot indices instead of
/// runtime name lookups.
///
/// `extra_bodies` carries instruction streams that are reachable from
/// the AOT program but absent from both `manifest` (module-cache
/// scope only) and `ctx.local_frames[import_frame_index]` (the freeze
/// step pops the user's top-level frame before collection runs). The
/// post-freeze `AotWordDesc` array is the canonical source: it
/// preserves the identity of every Parameter and Marker pointer
/// referenced by a discovered word body, so codegen and the loader
/// agree on slot indices.
pub fn collectImageSlots(
    allocator: Allocator,
    ctx: *const Context,
    manifest: ImageManifest,
    options: ImageEmitOptions,
    extra_bodies: []const []const value_mod.Instruction,
) Allocator.Error!ImageCollection {
    var collection: ImageCollection = .{
        .allocator = allocator,
        .effect_table = StackEffectTable.init(allocator),
        .marker_pool = MarkerPool.init(allocator),
        .word_to_typevalue_slot = try allocator.alloc(u32, manifest.entries.len),
    };
    errdefer collection.deinit();
    @memset(collection.word_to_typevalue_slot, 0);

    try collectMarkers(&collection.marker_pool, ctx, manifest);
    try collectStackEffects(&collection.effect_table, ctx, manifest);

    if (!options.metadata_only) {
        for (manifest.entries, 0..) |entry, idx| {
            const mw_ptr = lookupModuleWord(ctx, entry) orelse continue;
            if (findTypeValueLiteral(mw_ptr)) |tv| {
                collection.word_to_typevalue_slot[idx] = try collection.effect_table.internType(tv);
            }
        }
    }

    if (!options.metadata_only) {
        for (manifest.entries) |entry| {
            const mw_ptr = lookupModuleWord(ctx, entry) orelse continue;
            try internBodyTypeLiterals(&collection.struct_plans, &collection.struct_index, &collection.effect_table, mw_ptr);
        }
        try internTopLevelFrameLiterals(&collection.struct_plans, &collection.struct_index, &collection.effect_table, ctx);
        try internDispatchTableLiterals(&collection.struct_plans, &collection.struct_index, &collection.effect_table, ctx);
        for (extra_bodies) |body| {
            try internInstructionTypeLiterals(&collection.struct_plans, &collection.struct_index, &collection.effect_table, body);
        }
    }

    try collectDescriptorCrossRefs(&collection.struct_plans, &collection.struct_index, &collection.effect_table);

    return collection;
}

/// Emit the runtime image as static C data into `out`, reading
/// slot-table contents from a pre-populated `ImageCollection`. Use
/// this entry point when the caller has already run
/// `collectImageSlots` and needs the slot indices for codegen
/// purposes; otherwise the convenience wrapper `emitImageC` runs both
/// back to back.
pub fn emitImageCFromCollection(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    ctx: *const Context,
    manifest: ImageManifest,
    word_id_lookup: *const std.StringHashMapUnmanaged(u32),
    collection: *ImageCollection,
    options: ImageEmitOptions,
    quotation_id_map: ?*const std.AutoHashMapUnmanaged(usize, u32),
    dispatch_id_names: ?*const std.AutoHashMapUnmanaged(u32, []const u8),
    interpreter_run_bodies: ?*const std.AutoHashMapUnmanaged(u32, []const u8),
) ImageEmitError!ImageEmissionStats {
    var stats: ImageEmissionStats = .{};

    // Protocol descriptors may have been interned after the collection
    // walk (bounded call sites come from the post-freeze word list), so
    // their method effects join the tables here, before any emission
    // reads them. The cross-ref re-run picks up TypeValues reached only
    // through those method effects; both walks dedupe, so re-running is
    // idempotent. Appending after body codegen is safe because slot and
    // effect indices are append-only.
    try registerProtocolMethodEffects(&collection.effect_table);
    try collectDescriptorCrossRefs(&collection.struct_plans, &collection.struct_index, &collection.effect_table);

    try emitTypeDeclarations(out, allocator);

    const effect_table = &collection.effect_table;
    const marker_pool = &collection.marker_pool;
    const struct_plans_items = collection.struct_plans.items;
    const struct_index = &collection.struct_index;
    const word_to_typevalue_slot = collection.word_to_typevalue_slot;

    const word_body_lens = try allocator.alloc(u32, manifest.entries.len);
    defer allocator.free(word_body_lens);
    @memset(word_body_lens, 0);

    try emitMarkerPool(out, allocator, marker_pool, &stats);
    try emitTypeValueSlotTable(out, allocator, effect_table);
    try emitMarkerSlotTable(out, allocator, effect_table);
    try emitParameterSlotTable(out, allocator, effect_table);
    try emitTaggedSlotTable(out, allocator, effect_table);
    try emitMutableMapSlotTable(out, allocator, effect_table);
    try emitStructInstanceSlotTable(out, allocator, effect_table);
    try emitMarkerDescriptionsStorage(out, allocator, effect_table);
    try emitParameterDescriptionsStorage(out, allocator, effect_table);
    try emitStructTypeSlotTable(out, allocator, struct_plans_items);
    try emitStackEffectTable(out, allocator, effect_table);
    try emitTypeValueData(out, allocator, effect_table, struct_plans_items, struct_index);
    try emitTaggedDescriptionsStorage(out, allocator, effect_table, struct_index);
    try emitMutableMapDescriptionsStorage(out, allocator, effect_table, struct_index);
    try emitStructInstanceDescriptionsStorage(out, allocator, effect_table, struct_index);
    try emitProtocolDescriptorSlotTable(out, allocator, effect_table);
    try emitProtocolDescriptorStorage(out, allocator, effect_table);
    try emitConstraintCombinatorSlotTable(out, allocator, effect_table);
    try emitConstraintCombinatorStorage(out, allocator, effect_table);
    stats.dispatch_entry_slot_count = try emitDispatchEntryTable(out, allocator, ctx, effect_table, struct_index, !options.metadata_only, quotation_id_map, dispatch_id_names, interpreter_run_bodies);

    try emitWordNameStrings(out, allocator, manifest);
    try emitWordDiagnosticStrings(out, allocator, ctx, manifest);
    if (!options.metadata_only) {
        try emitWordBodyBytecode(out, allocator, ctx, manifest, word_body_lens, effect_table, struct_index);
    }
    try emitModuleAndWordTables(out, allocator, ctx, manifest, word_id_lookup, marker_pool, effect_table, word_to_typevalue_slot, word_body_lens, &stats);
    try emitHeader(out, allocator, manifest, marker_pool, effect_table, struct_plans_items, stats);

    stats.typevalue_slot_count = effect_table.slotCount();
    stats.stack_effect_count = effect_table.effectCount();
    stats.marker_slot_count = effect_table.markerSlotCount();
    stats.parameter_slot_count = effect_table.parameterSlotCount();
    stats.struct_type_slot_count = @intCast(struct_plans_items.len);
    stats.tagged_slot_count = effect_table.taggedSlotCount();
    stats.mutable_map_slot_count = effect_table.mutableMapSlotCount();
    stats.struct_instance_slot_count = effect_table.structInstanceSlotCount();
    stats.protocoldescriptor_slot_count = effect_table.protocolSlotCount();
    stats.constraintcombinator_slot_count = effect_table.combinatorSlotCount();
    return stats;
}

/// Emit the runtime image as static C data into `out`. Returns counts
/// suitable for downstream metadata reporting.
///
/// `ctx` supplies the live `ModuleWord` records (markers, stack
/// effects, action variant). `manifest` orders the walk and assigns the
/// classification path. `word_id_lookup` maps each in-image word's
/// resolved name to the AOT dispatch-table id; words missing from the
/// map land on `word_id_sentinel`. `options` controls whether the
/// emitter is producing a full runtime image or a metadata-only image
/// (interpreter-free read-only introspection surface).
///
/// The output is appended to `out`; the caller is responsible for the
/// surrounding C source (preamble, dispatch table, main, etc.).
pub fn emitImageC(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    ctx: *const Context,
    manifest: ImageManifest,
    word_id_lookup: *const std.StringHashMapUnmanaged(u32),
    options: ImageEmitOptions,
) ImageEmitError!ImageEmissionStats {
    var collection = try collectImageSlots(allocator, ctx, manifest, options, &.{});
    defer collection.deinit();
    return emitImageCFromCollection(out, allocator, ctx, manifest, word_id_lookup, &collection, options, null, null, null);
}

/// Combined table for stack effects, the params they reference, and
/// the TypeValue slot table they share with the blob path.
///
/// The effect table reserves index 0 as a sentinel ("no effect"), so
/// real effects start at 1. The slot table reserves index 0 as the
/// "no annotation" sentinel for the same reason. Params do not get
/// their own dedup pool: they are owned by exactly one effect, so
/// emitting them inline keeps the bookkeeping local.
pub const TaggedSlotKey = instruction_bytecode.TaggedKey;

pub const TaggedSlotEntry = struct {
    tag: *const VirtualType,
    inner: *const Value,
};

pub const StackEffectTable = struct {
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
    /// Distinct Marker pointers reached from compiled word bodies via
    /// `.marker` literals. Identity-keyed because the user-facing
    /// Marker identity is the pointer itself. Indices are 0-based and
    /// carry no sentinel; an empty table emits no C symbol.
    marker_slots: std.ArrayListUnmanaged(*const Marker) = .{},
    marker_slot_index: std.AutoHashMapUnmanaged(*const Marker, u32) = .{},
    /// Distinct Parameter pointers reached from compiled word bodies
    /// via `.parameter` literals. Identity-keyed for the same reason
    /// as the Marker table. Indices are 0-based with no sentinel.
    parameter_slots: std.ArrayListUnmanaged(*const Parameter) = .{},
    parameter_slot_index: std.AutoHashMapUnmanaged(*const Parameter, u32) = .{},
    /// Distinct `.tagged` Values reached from compiled word bodies,
    /// keyed on `(tag, inner)` pointer identity. The loader allocates a
    /// runtime `*const Value` per entry by reconstructing the tag from
    /// the TypeValue slot table and deserializing the inner Value.
    /// Indices are 0-based with no sentinel.
    tagged_slots: std.ArrayListUnmanaged(TaggedSlotEntry) = .{},
    tagged_slot_index: std.AutoHashMapUnmanaged(TaggedSlotKey, u32) = .{},
    /// Distinct `*MutableMap` pointers reached from compiled word
    /// bodies. Each unique parse-time-materialized mutable map gets
    /// its own slot; the loader allocates a fresh `MutableMap` per
    /// slot at image load and populates it from serialized entries,
    /// so all freeze-time call sites that shared the same map share
    /// the same runtime pointer. Indices are 0-based with no sentinel.
    mutable_map_slots: std.ArrayListUnmanaged(*const value_mod.MutableMap) = .{},
    mutable_map_slot_index: std.AutoHashMapUnmanaged(*const value_mod.MutableMap, u32) = .{},
    /// Distinct `*StructInstance` pointers reached from compiled word bodies and from inside frozen
    /// mutable maps. Each unique freeze-time instance gets its own slot; the loader allocates a fresh
    /// `StructInstance` per slot and populates its fields from serialized bytecode, so every freeze-
    /// time reference shares one runtime pointer (instance fields are mutable, so aliasing must be
    /// preserved).
    ///
    /// Indices are 0-based with no sentinel.
    struct_instance_slots: std.ArrayListUnmanaged(*const value_mod.StructInstance) = .{},
    struct_instance_slot_index: std.AutoHashMapUnmanaged(*const value_mod.StructInstance, u32) = .{},
    /// Distinct `*ProtocolDescriptor` pointers reached from protocol-bounded call sites in
    /// AOT-compiled word bodies or from `.protocol` annotations in serialized stack effects.
    ///
    /// The loader reuses a same-named descriptor from the runtime context when one exists,
    /// reconstructs it from the description row otherwise, and patches the slot.
    ///
    /// Indices are 0-based with no sentinel.
    protocol_slots: std.ArrayListUnmanaged(*const value_mod.ProtocolDescriptor) = .{},
    protocol_slot_index: std.AutoHashMapUnmanaged(*const value_mod.ProtocolDescriptor, u32) = .{},
    /// Distinct `*ConstraintCombinator` pointers reached from `.combination` annotations in
    /// serialized stack effects.
    ///
    /// Interned post-order: a combinator's nested-combinator elements are interned before the
    /// combinator itself, so that children carry lower indices than parents and the loader can
    /// reconstruct in ascending slot order. This allows every nested reference to already be
    /// resolved.
    ///
    /// Indices are 0-based with no sentinel.
    combinator_slots: std.ArrayListUnmanaged(*const value_mod.ConstraintCombinator) = .{},
    combinator_slot_index: std.AutoHashMapUnmanaged(*const value_mod.ConstraintCombinator, u32) = .{},

    fn init(allocator: Allocator) StackEffectTable {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StackEffectTable) void {
        self.effects.deinit(self.allocator);
        self.effect_index.deinit(self.allocator);
        self.type_slots.deinit(self.allocator);
        self.type_slot_index.deinit(self.allocator);
        self.marker_slots.deinit(self.allocator);
        self.marker_slot_index.deinit(self.allocator);
        self.parameter_slots.deinit(self.allocator);
        self.parameter_slot_index.deinit(self.allocator);
        self.tagged_slots.deinit(self.allocator);
        self.tagged_slot_index.deinit(self.allocator);
        self.mutable_map_slots.deinit(self.allocator);
        self.mutable_map_slot_index.deinit(self.allocator);
        self.struct_instance_slots.deinit(self.allocator);
        self.struct_instance_slot_index.deinit(self.allocator);
        self.protocol_slots.deinit(self.allocator);
        self.protocol_slot_index.deinit(self.allocator);
        self.combinator_slots.deinit(self.allocator);
        self.combinator_slot_index.deinit(self.allocator);
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

    /// Intern a Marker pointer. The first call assigns slot 0; later
    /// calls with the same pointer return the same slot. The 0-based
    /// index is recorded in the C output as a comment on each row of
    /// `onez_image_marker_slots[]`.
    fn internMarker(self: *StackEffectTable, marker: *const Marker) Allocator.Error!u32 {
        if (self.marker_slot_index.get(marker)) |idx| return idx;
        const idx: u32 = @intCast(self.marker_slots.items.len);
        try self.marker_slots.append(self.allocator, marker);
        try self.marker_slot_index.put(self.allocator, marker, idx);
        return idx;
    }

    /// Intern a Parameter pointer. Same conventions as `internMarker`.
    fn internParameter(self: *StackEffectTable, param: *const Parameter) Allocator.Error!u32 {
        if (self.parameter_slot_index.get(param)) |idx| return idx;
        const idx: u32 = @intCast(self.parameter_slots.items.len);
        try self.parameter_slots.append(self.allocator, param);
        try self.parameter_slot_index.put(self.allocator, param, idx);
        return idx;
    }

    /// Intern a `.tagged` Value identity. Two tagged Values are the same
    /// entry when their `tag` and `inner` pointers both match. Returns
    /// the assigned 0-based slot index.
    fn internTagged(self: *StackEffectTable, tag: *const VirtualType, inner: *const Value) Allocator.Error!u32 {
        const key: TaggedSlotKey = .{ .tag = tag, .inner_ptr = inner };
        if (self.tagged_slot_index.get(key)) |idx| return idx;
        const idx: u32 = @intCast(self.tagged_slots.items.len);
        try self.tagged_slots.append(self.allocator, .{ .tag = tag, .inner = inner });
        try self.tagged_slot_index.put(self.allocator, key, idx);
        return idx;
    }

    /// Intern a `*MutableMap` pointer. Returns the assigned 0-based
    /// slot index; identical pointers collapse to the same slot.
    fn internMutableMap(self: *StackEffectTable, m: *const value_mod.MutableMap) Allocator.Error!u32 {
        if (self.mutable_map_slot_index.get(m)) |idx| return idx;
        const idx: u32 = @intCast(self.mutable_map_slots.items.len);
        try self.mutable_map_slots.append(self.allocator, m);
        try self.mutable_map_slot_index.put(self.allocator, m, idx);
        return idx;
    }

    /// Intern a `*StructInstance` pointer. Returns the assigned 0-based
    /// slot index; identical pointers collapse to the same slot.
    fn internStructInstance(self: *StackEffectTable, si: *const value_mod.StructInstance) Allocator.Error!u32 {
        if (self.struct_instance_slot_index.get(si)) |idx| return idx;
        const idx: u32 = @intCast(self.struct_instance_slots.items.len);
        try self.struct_instance_slots.append(self.allocator, si);
        try self.struct_instance_slot_index.put(self.allocator, si, idx);
        return idx;
    }

    /// Intern a `*ProtocolDescriptor` pointer. Returns the assigned
    /// 0-based slot index; identical pointers collapse to the same slot.
    pub fn internProtocol(self: *StackEffectTable, pd: *const value_mod.ProtocolDescriptor) Allocator.Error!u32 {
        if (self.protocol_slot_index.get(pd)) |idx| return idx;
        const idx: u32 = @intCast(self.protocol_slots.items.len);
        try self.protocol_slots.append(self.allocator, pd);
        try self.protocol_slot_index.put(self.allocator, pd, idx);
        return idx;
    }

    /// Intern a `*ConstraintCombinator` pointer post-order. Each element is
    /// interned first -- `.type` into the typevalue slots, `.protocol` into the
    /// protocol slots, `.combinator` recursively -- so a nested combinator lands
    /// at a lower index than the combinator that references it. Returns the
    /// assigned 0-based slot index; identical pointers collapse to the same slot.
    pub fn internCombinator(self: *StackEffectTable, cc: *const value_mod.ConstraintCombinator) Allocator.Error!u32 {
        if (self.combinator_slot_index.get(cc)) |idx| return idx;
        for (cc.elements) |element| {
            switch (element) {
                .type => |tv| _ = try self.internType(tv),
                .protocol => |pd| _ = try self.internProtocol(pd),
                .combinator => |nested| _ = try self.internCombinator(nested),
            }
        }
        const idx: u32 = @intCast(self.combinator_slots.items.len);
        try self.combinator_slots.append(self.allocator, cc);
        try self.combinator_slot_index.put(self.allocator, cc, idx);
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

    fn markerSlotCount(self: *const StackEffectTable) u32 {
        return @intCast(self.marker_slots.items.len);
    }

    fn parameterSlotCount(self: *const StackEffectTable) u32 {
        return @intCast(self.parameter_slots.items.len);
    }

    fn taggedSlotCount(self: *const StackEffectTable) u32 {
        return @intCast(self.tagged_slots.items.len);
    }

    fn mutableMapSlotCount(self: *const StackEffectTable) u32 {
        return @intCast(self.mutable_map_slots.items.len);
    }

    fn structInstanceSlotCount(self: *const StackEffectTable) u32 {
        return @intCast(self.struct_instance_slots.items.len);
    }

    fn protocolSlotCount(self: *const StackEffectTable) u32 {
        return @intCast(self.protocol_slots.items.len);
    }

    fn combinatorSlotCount(self: *const StackEffectTable) u32 {
        return @intCast(self.combinator_slots.items.len);
    }

    fn lookupEffect(self: *const StackEffectTable, effect: *const StackEffect) u32 {
        return self.effect_index.get(effect) orelse 0;
    }

    /// Look up the 1-based TypeValue slot index for `tv`. Returns 0
    /// (the "no annotation" sentinel) when the pointer has not been
    /// interned. Codegen consumers gate emission on a non-zero return.
    pub fn lookupTypeSlot(self: *const StackEffectTable, tv: *const TypeValue) u32 {
        return self.type_slot_index.get(tv) orelse 0;
    }

    /// Look up the 0-based Marker slot index for `marker`. Returns
    /// null when the pointer has not been interned. Codegen consumers
    /// must intern via the collection walk before consulting this
    /// method.
    pub fn lookupMarkerSlot(self: *const StackEffectTable, marker: *const Marker) ?u32 {
        return self.marker_slot_index.get(marker);
    }

    /// Look up the 0-based Parameter slot index for `param`. Returns
    /// null when the pointer has not been interned.
    pub fn lookupParameterSlot(self: *const StackEffectTable, param: *const Parameter) ?u32 {
        return self.parameter_slot_index.get(param);
    }

    /// Look up the 0-based tagged slot index for the `(tag, inner)`
    /// identity. Returns null when the pair has not been interned.
    pub fn lookupTaggedSlot(self: *const StackEffectTable, tag: *const VirtualType, inner: *const Value) ?u32 {
        return self.tagged_slot_index.get(.{ .tag = tag, .inner_ptr = inner });
    }

    /// Look up the 0-based mutable_map slot index for `m`. Returns
    /// null when the pointer has not been interned.
    pub fn lookupMutableMapSlot(self: *const StackEffectTable, m: *const value_mod.MutableMap) ?u32 {
        return self.mutable_map_slot_index.get(m);
    }

    /// Look up the 0-based struct_instance slot index for `si`. Returns
    /// null when the pointer has not been interned.
    pub fn lookupStructInstanceSlot(self: *const StackEffectTable, si: *const value_mod.StructInstance) ?u32 {
        return self.struct_instance_slot_index.get(si);
    }

    /// Look up the 0-based protocol slot index for `pd`. Returns
    /// null when the pointer has not been interned.
    pub fn lookupProtocolSlot(self: *const StackEffectTable, pd: *const value_mod.ProtocolDescriptor) ?u32 {
        return self.protocol_slot_index.get(pd);
    }

    /// Look up the 0-based combinator slot index for `cc`. Returns
    /// null when the pointer has not been interned.
    pub fn lookupCombinatorSlot(self: *const StackEffectTable, cc: *const value_mod.ConstraintCombinator) ?u32 {
        return self.combinator_slot_index.get(cc);
    }
};

/// Pre-resolved data for one image-side StructType. StructTypes are
/// reached through `virtual.anon_struct` and have no slot of their own
/// in the TypeValue slot table -- the loader allocates a parallel
/// `*StructType` per row in `onez_image_struct_types_storage[]` and
/// references it from the owning virtual descriptor by index.
pub const StructTypePlan = struct {
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
                if (maybe) |element| {
                    if (element == .type) _ = try effect_table.internType(element.type);
                }
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
            if (evd.anon_struct) |st| {
                _ = try internStructType(struct_plans, struct_index, effect_table, st);
            }
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
        if (maybe) |element| {
            if (element == .type) _ = try effect_table.internType(element.type);
        }
    }
    // Intern the owning TypeValue alongside the StructType so the loader
    // can rehydrate `StructType.type_val` from the matching runtime
    // `*TypeValue`. Without this, generator-emitted natives that read
    // `st.type_val.?` (e.g. struct predicate, destructure) panic at
    // runtime on a null back-reference.
    if (st.type_val) |tv| _ = try effect_table.internType(tv);
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
            .call_word, .call_word_direct => {},
        }
    }
    return null;
}

/// Walk every `push_literal` in a compound body, interning every
/// type-carrier literal variant the slot tables track: `.type_val`,
/// `.struct_type`, `.tagged` (recursing into `inner` so nested tagged
/// values contribute their inner type references too), `.parameter`,
/// and `.marker`. Recurses into nested quotation literals so combinator
/// bodies that carry inner quotations still contribute their type
/// references. The fixed-point closure in `collectDescriptorCrossRefs`
/// picks up the transitive descriptor surface for every newly-interned
/// TypeValue.
///
/// Unlike `findTypeValueLiteral`, which returns the first match for
/// the per-word body-rewrite mechanism, this walker visits every
/// literal in the body and contributes side effects only -- it has no
/// return value because the slot table is the surface every caller
/// reads.
fn internBodyTypeLiterals(
    struct_plans: *std.ArrayListUnmanaged(StructTypePlan),
    struct_index: *std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    effect_table: *StackEffectTable,
    mw: *const ModuleWord,
) Allocator.Error!void {
    const body = switch (mw.action) {
        .compound => |b| b,
        else => return,
    };
    try internInstructionTypeLiterals(struct_plans, struct_index, effect_table, body);
}

fn internInstructionTypeLiterals(
    struct_plans: *std.ArrayListUnmanaged(StructTypePlan),
    struct_index: *std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    effect_table: *StackEffectTable,
    instrs: []const value_mod.Instruction,
) Allocator.Error!void {
    for (instrs) |instr| {
        switch (instr.op) {
            .push_literal => |lit| try internValueTypeLiterals(struct_plans, struct_index, effect_table, lit),
            .call_word, .call_word_direct => {},
        }
    }
}

fn internValueTypeLiterals(
    struct_plans: *std.ArrayListUnmanaged(StructTypePlan),
    struct_index: *std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    effect_table: *StackEffectTable,
    val: value_mod.Value,
) Allocator.Error!void {
    switch (val) {
        .type_val => |tv| _ = try effect_table.internType(tv),
        .struct_type => |st| _ = try internStructType(struct_plans, struct_index, effect_table, st),
        .tagged => |t| {
            if (t.tag.type_val) |tv| _ = try effect_table.internType(tv);
            try internValueTypeLiterals(struct_plans, struct_index, effect_table, t.inner.*);
            _ = try effect_table.internTagged(t.tag, t.inner);
        },
        .parameter => |p| _ = try effect_table.internParameter(p),
        .marker => |m| _ = try effect_table.internMarker(m),
        .mutable_map => |m| {
            _ = try effect_table.internMutableMap(m);
            var iter = m.map.iterator();
            while (iter.next()) |entry| {
                try internValueTypeLiterals(struct_plans, struct_index, effect_table, entry.value_ptr.*);
            }
        },
        .struct_instance => |si| {
            _ = try effect_table.internStructInstance(si);
            _ = try internStructType(struct_plans, struct_index, effect_table, si.struct_type);
            for (si.fields) |field| {
                try internValueTypeLiterals(struct_plans, struct_index, effect_table, field);
            }
        },
        .array => |elems| {
            for (elems) |elem| {
                try internValueTypeLiterals(struct_plans, struct_index, effect_table, elem);
            }
        },
        .hash => |h| {
            var iter = h.iterator();
            while (iter.next()) |entry| {
                try internValueTypeLiterals(struct_plans, struct_index, effect_table, entry.value_ptr.*);
            }
        },
        .quotation => |q| try internInstructionTypeLiterals(
            struct_plans,
            struct_index,
            effect_table,
            q.instructions,
        ),
        else => {},
    }
}

/// Walk every compound word definition in the import frame (top-level
/// program scope) and intern type-carrier literals from each body. The
/// import frame holds definitions a user wrote outside any `use`d
/// module; without this pass, user-defined `struct{` / `virtual{` /
/// `enum{` constructors at program scope would not contribute to the
/// slot tables because `manifest.entries` only covers module-cached
/// words.
fn internTopLevelFrameLiterals(
    struct_plans: *std.ArrayListUnmanaged(StructTypePlan),
    struct_index: *std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    effect_table: *StackEffectTable,
    ctx: *const Context,
) Allocator.Error!void {
    const idx = ctx.import_frame_index orelse return;
    if (idx >= ctx.local_frames.items.len) return;
    const frame = &ctx.local_frames.items[idx];
    var iter = frame.iterator();
    while (iter.next()) |entry| {
        const def = entry.value_ptr.*;
        switch (def.action) {
            .compound => |body| try internInstructionTypeLiterals(
                struct_plans,
                struct_index,
                effect_table,
                body,
            ),
            .native, .host_callback => {},
        }
    }
}

/// Walk both halves of the dispatch table (`entries` and
/// `native_entries`) and intern type references reachable from each
/// entry. For quotation-bodied entries, the body walker picks up
/// `.type_val` and friends. For key TypeDescriptors, the descriptor
/// itself does not back-reference its owning TypeValue, so build a
/// one-shot index over the Context's known TypeValue registries and
/// intern via that map. Descriptors not present in any registry are
/// silently skipped -- they correspond to TypeValues that no live
/// reference path reaches, and the slot table cannot rehydrate them
/// either.
fn internDispatchTableLiterals(
    struct_plans: *std.ArrayListUnmanaged(StructTypePlan),
    struct_index: *std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    effect_table: *StackEffectTable,
    ctx: *const Context,
) Allocator.Error!void {
    var desc_index: std.AutoHashMapUnmanaged(*const value_mod.TypeDescriptor, *const value_mod.TypeValue) = .{};
    defer desc_index.deinit(effect_table.allocator);
    try indexKnownTypeValues(&desc_index, effect_table.allocator, ctx);

    inline for (.{ &ctx.dispatch.entries, &ctx.dispatch.native_entries }) |table| {
        var iter = table.iterator();
        while (iter.next()) |slot| {
            const key = slot.key_ptr.*;
            if (desc_index.get(key.type_a)) |tv| _ = try effect_table.internType(tv);
            if (desc_index.get(key.type_b)) |tv| _ = try effect_table.internType(tv);

            const entry = slot.value_ptr.*;
            switch (entry.body) {
                .quotation => |q| try internInstructionTypeLiterals(
                    struct_plans,
                    struct_index,
                    effect_table,
                    q.instructions,
                ),
                .native_fn, .host_callback => {},
            }
        }
    }
}

/// Build a descriptor→TypeValue index from the Context's known
/// TypeValue registries. Used to recover the TypeValue identity of a
/// dispatch key's `*const TypeDescriptor` since TypeDescriptor itself
/// carries no back-pointer to its owning TypeValue.
fn indexKnownTypeValues(
    desc_index: *std.AutoHashMapUnmanaged(*const value_mod.TypeDescriptor, *const value_mod.TypeValue),
    allocator: Allocator,
    ctx: *const Context,
) Allocator.Error!void {
    var builtin_iter = ctx.builtin_type_values.iterator();
    while (builtin_iter.next()) |entry| {
        const tv = entry.value_ptr.*;
        if (tv.descriptor) |desc| try desc_index.put(allocator, desc, tv);
    }
    var resource_iter = ctx.resource_type_values.iterator();
    while (resource_iter.next()) |entry| {
        const tv = entry.value_ptr.*;
        if (tv.descriptor) |desc| try desc_index.put(allocator, desc, tv);
    }
    var union_iter = ctx.anonymous_union_type_values.iterator();
    while (union_iter.next()) |entry| {
        const tv = entry.value_ptr.*;
        if (tv.descriptor) |desc| try desc_index.put(allocator, desc, tv);
    }
    for (ctx.type_registry_frames.items) |*frame| {
        var enum_iter = frame.enum_registry.iterator();
        while (enum_iter.next()) |entry| {
            const tv = entry.key_ptr.*;
            if (tv.descriptor) |desc| try desc_index.put(allocator, desc, tv);
        }
    }
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
    if (param.type_annotation) |ann| {
        switch (ann) {
            .type => |tv| {
                _ = try table.internType(tv);
            },
            // The descriptor joins the protocol slot table so the loader can
            // reconstruct it at startup; the param row references it through
            // `annotation_slot` with kind 2.
            .protocol => |pd| {
                _ = try table.internProtocol(pd);
            },
            // The combinator and its element types, protocols, and nested
            // combinators join the parallel slot tables; the param row
            // references it through `annotation_slot` with kind 3.
            .combination => |cc| {
                _ = try table.internCombinator(cc);
            },
        }
    }
    if (param.quotation_effect) |nested| {
        try registerStackEffect(table, nested);
    }
}

/// Intern the per-method stack effects of every interned protocol
/// descriptor so the description rows can reference them by index.
/// Fixed-point walk: registering a method effect interns its param
/// annotations, and a `.protocol` annotation may append a new
/// descriptor to `protocol_slots`, whose methods then get walked in a
/// later iteration. Runs at emission time so it covers descriptors
/// interned after the collection walk (bounded call sites are interned
/// from the post-freeze word list).
fn registerProtocolMethodEffects(table: *StackEffectTable) Allocator.Error!void {
    var cursor: usize = 0;
    while (cursor < table.protocol_slots.items.len) : (cursor += 1) {
        const pd = table.protocol_slots.items[cursor];
        for (pd.methods) |*entry| {
            if (entry.* == .stack_effect) {
                try registerStackEffect(table, &entry.stack_effect);
            }
        }
    }
}

/// Pool of unique marker names. The vector preserves insertion order
/// so codegen output is deterministic; the map gives O(1) dedup.
pub const MarkerPool = struct {
    allocator: Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .{},
    indices: std.StringHashMapUnmanaged(u32) = .{},

    pub fn init(allocator: Allocator) MarkerPool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MarkerPool) void {
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

/// Emit `onez_image_marker_slots[]`: one NULL pointer per distinct
/// Marker reached through compiled word bodies. The slot index is
/// stable within a build and identifies the Marker for downstream
/// codegen passes (slot-table indirection that replaces runtime
/// name lookup). No-op when no `.marker` literals have been
/// interned.
fn emitMarkerSlotTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.markerSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "__attribute__((used)) struct onez_marker *onez_image_marker_slots[");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{table.markerSlotCount()}) catch unreachable);
    try out.appendSlice(allocator, "] = {\n");
    for (table.marker_slots.items, 0..) |marker, i| {
        try out.appendSlice(allocator, "    NULL, /* slot ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ": marker ");
        try out.appendSlice(allocator, marker.name);
        try out.appendSlice(allocator, " (filled by the loader). */\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_struct_type_slots[]`: one NULL pointer per
/// distinct StructType reached through compiled word bodies and
/// descriptor cross-references. The slot index matches the row's
/// position in `onez_image_struct_types_storage[]`, so the loader
/// can patch each entry with the runtime `*StructType` pointer it
/// allocates while walking the same `struct_types` table. No-op
/// when no struct types have been interned.
fn emitStructTypeSlotTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    struct_plans: []const StructTypePlan,
) Allocator.Error!void {
    if (struct_plans.len == 0) return;
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "__attribute__((used)) struct onez_struct_type *onez_image_struct_type_slots[");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{struct_plans.len}) catch unreachable);
    try out.appendSlice(allocator, "] = {\n");
    for (struct_plans, 0..) |plan, i| {
        try out.appendSlice(allocator, "    NULL, /* slot ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ": struct ");
        try out.appendSlice(allocator, plan.struct_type.name);
        try out.appendSlice(allocator, " (filled by the loader). */\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_parameter_slots[]`: one NULL pointer per
/// distinct Parameter reached through compiled word bodies. Same
/// shape and intent as `emitMarkerSlotTable`. Parameter binding
/// state is mutable, so the loader allocates the runtime Parameter
/// row and patches the slot; the codegen-side consumer reads the
/// patched pointer.
fn emitParameterSlotTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.parameterSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "__attribute__((used)) struct onez_parameter *onez_image_parameter_slots[");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{table.parameterSlotCount()}) catch unreachable);
    try out.appendSlice(allocator, "] = {\n");
    for (table.parameter_slots.items, 0..) |param, i| {
        try out.appendSlice(allocator, "    NULL, /* slot ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ": parameter ");
        try out.appendSlice(allocator, param.name);
        try out.appendSlice(allocator, " (filled by the loader). */\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn writeMarkerDescNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_marker_desc_{d}_name", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeParamDescNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_param_desc_{d}_name", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeParamDescBodySym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_param_desc_{d}_body", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

/// Emit `onez_image_marker_descriptions_storage[]`: one row per slot in
/// `onez_image_marker_slots[]`. Each row carries the marker's name; the
/// loader resolves the name to either a well-known marker singleton or
/// a freshly-allocated `*Marker`, then patches the slot. No-op when no
/// markers have been interned.
fn emitMarkerDescriptionsStorage(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.markerSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;

    for (table.marker_slots.items, 0..) |marker, i| {
        try out.appendSlice(allocator, "static const char ");
        try writeMarkerDescNameSym(out, allocator, i);
        try out.appendSlice(allocator, "[] = ");
        try emitCStringLiteral(out, allocator, marker.name);
        try out.appendSlice(allocator, ";\n");
    }
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "static const onez_image_marker_description_t onez_image_marker_descriptions_storage[] = {\n");
    for (table.marker_slots.items, 0..) |marker, i| {
        try out.appendSlice(allocator, "    { .name = ");
        try writeMarkerDescNameSym(out, allocator, i);
        try out.appendSlice(allocator, ", .name_len = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{marker.name.len}) catch unreachable);
        try out.appendSlice(allocator, ", .slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_parameter_descriptions_storage[]`: one row per slot
/// in `onez_image_parameter_slots[]`. Each row carries the parameter's
/// name and the serialized bytecode for its lazy default quotation. The
/// loader deserializes the bytecode and allocates the runtime
/// `*Parameter`, then patches the slot. No-op when no parameters have
/// been interned.
fn emitParameterDescriptionsStorage(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) ImageEmitError!void {
    if (table.parameterSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;

    for (table.parameter_slots.items, 0..) |param, i| {
        try out.appendSlice(allocator, "static const char ");
        try writeParamDescNameSym(out, allocator, i);
        try out.appendSlice(allocator, "[] = ");
        try emitCStringLiteral(out, allocator, param.name);
        try out.appendSlice(allocator, ";\n");

        const bytes = instruction_bytecode.serializeQuotationInstructions(param.default_quotation.instructions, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotEncodable => return error.NotEncodable,
        };
        defer allocator.free(bytes);

        try out.appendSlice(allocator, "static const uint8_t ");
        try writeParamDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, "[] = {");
        for (bytes, 0..) |byte, bi| {
            if (bi > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{byte}) catch unreachable);
        }
        try out.appendSlice(allocator, "};\n");
    }
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "static const onez_image_parameter_description_t onez_image_parameter_descriptions_storage[] = {\n");
    for (table.parameter_slots.items, 0..) |param, i| {
        try out.appendSlice(allocator, "    { .name = ");
        try writeParamDescNameSym(out, allocator, i);
        try out.appendSlice(allocator, ", .name_len = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{param.name.len}) catch unreachable);
        try out.appendSlice(allocator, ", .slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ", .default_quotation_bytecode = ");
        try writeParamDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, ", .default_quotation_bytecode_len = sizeof(");
        try writeParamDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, ") },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn writeTaggedDescNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_tagged_desc_{d}_name", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeTaggedDescBodySym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_tagged_desc_{d}_inner", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

/// Emit `onez_image_tagged_slots[]`: one NULL pointer per distinct
/// `.tagged` Value identity reached through compiled word bodies. The
/// loader patches each slot with a heap-allocated runtime `*const Value`
/// reconstructed from the description row's tag-typevalue slot and
/// serialized inner bytecode. No-op when no tagged literals have been
/// interned.
fn emitTaggedSlotTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.taggedSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "__attribute__((used)) const struct onez_value *onez_image_tagged_slots[");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{table.taggedSlotCount()}) catch unreachable);
    try out.appendSlice(allocator, "] = {\n");
    for (table.tagged_slots.items, 0..) |entry, i| {
        try out.appendSlice(allocator, "    NULL, /* slot ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ": tagged ");
        try out.appendSlice(allocator, entry.tag.name);
        try out.appendSlice(allocator, " (filled by the loader). */\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_tagged_descriptions_storage[]`: one row per slot in
/// `onez_image_tagged_slots[]`. Each row carries the tag's qualified
/// name (for diagnostics), the TypeValue slot of the tag (used to
/// recover the runtime `*const VirtualType` via `tv.virtual_type`), and
/// the inner Value bytecode (serialized in image mode so type-carrier
/// inners route through their slot tables). No-op when no tagged
/// literals have been interned.
fn emitTaggedDescriptionsStorage(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
    struct_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
) ImageEmitError!void {
    if (table.taggedSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;

    const slot_maps: instruction_bytecode.SlotEncodingMaps = .{
        .typevalue_slot_index = &table.type_slot_index,
        .struct_type_slot_index = struct_index,
        .marker_slot_index = &table.marker_slot_index,
        .parameter_slot_index = &table.parameter_slot_index,
        .tagged_slot_index = &table.tagged_slot_index,
        .mutable_map_slot_index = &table.mutable_map_slot_index,
        .struct_instance_slot_index = &table.struct_instance_slot_index,
    };

    for (table.tagged_slots.items, 0..) |entry, i| {
        try out.appendSlice(allocator, "static const char ");
        try writeTaggedDescNameSym(out, allocator, i);
        try out.appendSlice(allocator, "[] = ");
        try emitCStringLiteral(out, allocator, entry.tag.name);
        try out.appendSlice(allocator, ";\n");

        var inner_buf: std.ArrayListUnmanaged(u8) = .{};
        defer inner_buf.deinit(allocator);
        instruction_bytecode.serializeValueIntoForImage(&inner_buf, entry.inner.*, allocator, &slot_maps) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotEncodable => return error.NotEncodable,
        };

        try out.appendSlice(allocator, "static const uint8_t ");
        try writeTaggedDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, "[] = {");
        for (inner_buf.items, 0..) |byte, bi| {
            if (bi > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{byte}) catch unreachable);
        }
        try out.appendSlice(allocator, "};\n");
    }
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "static const onez_image_tagged_description_t onez_image_tagged_descriptions_storage[] = {\n");
    for (table.tagged_slots.items, 0..) |entry, i| {
        const tag_tv = entry.tag.type_val orelse return error.NotEncodable;
        const tag_slot = table.lookupTypeSlot(tag_tv);
        if (tag_slot == 0) return error.NotEncodable;

        try out.appendSlice(allocator, "    { .name = ");
        try writeTaggedDescNameSym(out, allocator, i);
        try out.appendSlice(allocator, ", .name_len = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{entry.tag.name.len}) catch unreachable);
        try out.appendSlice(allocator, ", .slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ", .tag_typevalue_slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{tag_slot}) catch unreachable);
        try out.appendSlice(allocator, ", .inner_bytecode = ");
        try writeTaggedDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, ", .inner_bytecode_len = sizeof(");
        try writeTaggedDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, ") },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn writeMutableMapDescBodySym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_mutable_map_desc_{d}_data", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

/// Emit `onez_image_mutable_map_slots[]`: one NULL pointer per distinct
/// `*MutableMap` reached through compiled word bodies. The loader
/// allocates a fresh `MutableMap` per slot at image load and patches
/// each entry with the runtime pointer. No-op when no mutable maps
/// have been interned.
fn emitMutableMapSlotTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.mutableMapSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "__attribute__((used)) struct onez_mutable_map *onez_image_mutable_map_slots[");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{table.mutableMapSlotCount()}) catch unreachable);
    try out.appendSlice(allocator, "] = {\n");
    var i: u32 = 0;
    while (i < table.mutableMapSlotCount()) : (i += 1) {
        try out.appendSlice(allocator, "    NULL, /* slot ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, " (filled by the loader). */\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_mutable_map_descriptions_storage[]`: one row per slot
/// in `onez_image_mutable_map_slots[]`. Each row carries the serialized
/// entries (key/value pairs) in image-mode bytecode so nested
/// type-carrier values resolve through their own slot tables. No-op
/// when no mutable maps have been interned.
fn emitMutableMapDescriptionsStorage(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
    struct_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
) ImageEmitError!void {
    if (table.mutableMapSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;

    const slot_maps: instruction_bytecode.SlotEncodingMaps = .{
        .typevalue_slot_index = &table.type_slot_index,
        .struct_type_slot_index = struct_index,
        .marker_slot_index = &table.marker_slot_index,
        .parameter_slot_index = &table.parameter_slot_index,
        .tagged_slot_index = &table.tagged_slot_index,
        .mutable_map_slot_index = &table.mutable_map_slot_index,
        .struct_instance_slot_index = &table.struct_instance_slot_index,
    };

    for (table.mutable_map_slots.items, 0..) |m, i| {
        var entries_buf: std.ArrayListUnmanaged(u8) = .{};
        defer entries_buf.deinit(allocator);

        const entry_count: u32 = @intCast(m.map.count());
        try entries_buf.appendSlice(allocator, std.mem.asBytes(&entry_count));
        var iter = m.map.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const key_len: u32 = @intCast(key.len);
            try entries_buf.appendSlice(allocator, std.mem.asBytes(&key_len));
            try entries_buf.appendSlice(allocator, key);
            instruction_bytecode.serializeValueIntoForImage(&entries_buf, entry.value_ptr.*, allocator, &slot_maps) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotEncodable => return error.NotEncodable,
            };
        }

        try out.appendSlice(allocator, "static const uint8_t ");
        try writeMutableMapDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, "[] = {");
        for (entries_buf.items, 0..) |byte, bi| {
            if (bi > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{byte}) catch unreachable);
        }
        try out.appendSlice(allocator, "};\n");
    }
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "static const onez_image_mutable_map_description_t onez_image_mutable_map_descriptions_storage[] = {\n");
    for (table.mutable_map_slots.items, 0..) |_, i| {
        try out.appendSlice(allocator, "    { .slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ", .entries_bytecode = ");
        try writeMutableMapDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, ", .entries_bytecode_len = sizeof(");
        try writeMutableMapDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, ") },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn writeStructInstanceDescBodySym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idx: usize,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_struct_instance_desc_{d}_data", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

/// Emit `onez_image_struct_instance_slots[]`: one NULL pointer per distinct
/// `*StructInstance` reached through compiled word bodies or nested inside a
/// frozen mutable map. The loader allocates a fresh `StructInstance` per slot
/// at image load and patches each entry with the runtime pointer. No-op when
/// no struct instances have been interned.
fn emitStructInstanceSlotTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.structInstanceSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "__attribute__((used)) struct onez_struct_instance *onez_image_struct_instance_slots[");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{table.structInstanceSlotCount()}) catch unreachable);
    try out.appendSlice(allocator, "] = {\n");
    var i: u32 = 0;
    while (i < table.structInstanceSlotCount()) : (i += 1) {
        try out.appendSlice(allocator, "    NULL, /* slot ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, " (filled by the loader). */\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_struct_instance_descriptions_storage[]`: one row per slot
/// in `onez_image_struct_instance_slots[]`. Each row carries the slot index of
/// the owning StructType and the field values in image-mode bytecode (a `u32`
/// count followed by each field), so nested type-carrier values, mutable maps,
/// and nested struct instances resolve through their own slot tables. No-op
/// when no struct instances have been interned.
fn emitStructInstanceDescriptionsStorage(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
    struct_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
) ImageEmitError!void {
    if (table.structInstanceSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;

    const slot_maps: instruction_bytecode.SlotEncodingMaps = .{
        .typevalue_slot_index = &table.type_slot_index,
        .struct_type_slot_index = struct_index,
        .marker_slot_index = &table.marker_slot_index,
        .parameter_slot_index = &table.parameter_slot_index,
        .tagged_slot_index = &table.tagged_slot_index,
        .mutable_map_slot_index = &table.mutable_map_slot_index,
        .struct_instance_slot_index = &table.struct_instance_slot_index,
    };

    for (table.struct_instance_slots.items, 0..) |si, i| {
        var fields_buf: std.ArrayListUnmanaged(u8) = .{};
        defer fields_buf.deinit(allocator);

        const field_count: u32 = @intCast(si.fields.len);
        try fields_buf.appendSlice(allocator, std.mem.asBytes(&field_count));
        for (si.fields) |field| {
            instruction_bytecode.serializeValueIntoForImage(&fields_buf, field, allocator, &slot_maps) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotEncodable => return error.NotEncodable,
            };
        }

        try out.appendSlice(allocator, "static const uint8_t ");
        try writeStructInstanceDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, "[] = {");
        for (fields_buf.items, 0..) |byte, bi| {
            if (bi > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{byte}) catch unreachable);
        }
        try out.appendSlice(allocator, "};\n");
    }
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "static const onez_image_struct_instance_description_t onez_image_struct_instance_descriptions_storage[] = {\n");
    for (table.struct_instance_slots.items, 0..) |si, i| {
        const st_slot = struct_index.get(si.struct_type) orelse return error.NotEncodable;
        try out.appendSlice(allocator, "    { .slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ", .struct_type_slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{st_slot}) catch unreachable);
        try out.appendSlice(allocator, ", .fields_bytecode = ");
        try writeStructInstanceDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, ", .fields_bytecode_len = sizeof(");
        try writeStructInstanceDescBodySym(out, allocator, i);
        try out.appendSlice(allocator, ") },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_protocoldescriptor_slots[]`: one NULL pointer per
/// distinct ProtocolDescriptor reached through protocol-bounded call sites
/// in compiled word bodies or `.protocol` annotations in serialized stack
/// effects. The loader patches each slot with the runtime descriptor
/// (reused by name or reconstructed from the description row). No-op when
/// no protocol descriptors have been interned.
fn emitProtocolDescriptorSlotTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.protocolSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "__attribute__((used)) struct onez_protocoldescriptor *onez_image_protocoldescriptor_slots[");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{table.protocolSlotCount()}) catch unreachable);
    try out.appendSlice(allocator, "] = {\n");
    for (table.protocol_slots.items, 0..) |pd, i| {
        try out.appendSlice(allocator, "    NULL, /* slot ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ": protocol ");
        try out.appendSlice(allocator, pd.name);
        try out.appendSlice(allocator, " (filled by the loader). */\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_protocoldescriptor_descriptions_storage[]`: one row per
/// slot in `onez_image_protocoldescriptor_slots[]`. Each row carries the
/// full descriptor fields (name, methods, protocol_id) so the loader can
/// reconstruct the descriptor when no same-named protocol exists in the
/// runtime context. No-op when no protocol descriptors have been interned.
fn emitProtocolDescriptorStorage(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.protocolSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;

    for (table.protocol_slots.items, 0..) |pd, i| {
        try out.appendSlice(allocator, "static const char onez_image_pd_");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, "_name[] = ");
        try emitCStringLiteral(out, allocator, pd.name);
        try out.appendSlice(allocator, ";\n");

        var mi: usize = 0;
        var m: u32 = 0;
        while (mi < pd.methods.len) : (mi += 1) {
            const entry = pd.methods[mi];
            if (entry != .symbol) continue;
            try out.appendSlice(allocator, "static const char ");
            try writeProtocolMethodNameSym(out, allocator, i, m);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, entry.symbol);
            try out.appendSlice(allocator, ";\n");
            m += 1;
        }

        if (m > 0) {
            try out.appendSlice(allocator, "static const onez_image_protocol_method_t ");
            try writeProtocolMethodsSym(out, allocator, i);
            try out.appendSlice(allocator, "[] = {\n");
            mi = 0;
            m = 0;
            while (mi < pd.methods.len) : (mi += 1) {
                if (pd.methods[mi] != .symbol) continue;
                const method_name = pd.methods[mi].symbol;
                // A `.stack_effect` immediately following the symbol is the
                // method's declared effect, mirroring the satisfies-check
                // walk in primitives/protocols.zig.
                const effect_idx: u32 = if (mi + 1 < pd.methods.len and pd.methods[mi + 1] == .stack_effect)
                    table.lookupEffect(&pd.methods[mi + 1].stack_effect)
                else
                    0;
                try out.appendSlice(allocator, "    { .name = ");
                try writeProtocolMethodNameSym(out, allocator, i, m);
                try out.appendSlice(allocator, ", .name_len = ");
                try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{method_name.len}) catch unreachable);
                try out.appendSlice(allocator, ", .stack_effect_idx = ");
                try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{effect_idx}) catch unreachable);
                try out.appendSlice(allocator, " },\n");
                m += 1;
            }
            try out.appendSlice(allocator, "};\n");
        }
    }
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "static const onez_image_protocoldescriptor_description_t onez_image_protocoldescriptor_descriptions_storage[] = {\n");
    for (table.protocol_slots.items, 0..) |pd, i| {
        const method_count = countProtocolMethods(pd);
        try out.appendSlice(allocator, "    { .name = onez_image_pd_");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, "_name, .name_len = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{pd.name.len}) catch unreachable);
        try out.appendSlice(allocator, ", .slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ", .protocol_id = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{pd.protocol_id}) catch unreachable);
        try out.appendSlice(allocator, ", .method_count = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{method_count}) catch unreachable);
        try out.appendSlice(allocator, ", .methods = ");
        if (method_count > 0) {
            try writeProtocolMethodsSym(out, allocator, i);
        } else {
            try out.appendSlice(allocator, "NULL");
        }
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_constraintcombinator_slots[]`: one NULL pointer per
/// distinct ConstraintCombinator reached through `.combination` annotations
/// in serialized stack effects. The loader patches each slot with a
/// reconstructed descriptor. No-op when no combinators have been interned.
fn emitConstraintCombinatorSlotTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.combinatorSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "__attribute__((used)) struct onez_constraintcombinator *onez_image_constraintcombinator_slots[");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{table.combinatorSlotCount()}) catch unreachable);
    try out.appendSlice(allocator, "] = {\n");
    for (table.combinator_slots.items, 0..) |cc, i| {
        try out.appendSlice(allocator, "    NULL, /* slot ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, @tagName(cc.kind));
        try out.appendSlice(allocator, " (filled by the loader). */\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

/// Emit `onez_image_constraintcombinator_descriptions_storage[]`: one row per
/// slot in `onez_image_constraintcombinator_slots[]`. Each row carries the
/// combinator's kind, build-time `combinator_id`, and element list so the
/// loader can reconstruct the descriptor. Each element is a tagged variant:
/// a 1-based typevalue slot, a 0-based protocol slot, or a 0-based combinator
/// slot. No-op when no combinators have been interned.
fn emitConstraintCombinatorStorage(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const StackEffectTable,
) Allocator.Error!void {
    if (table.combinatorSlotCount() == 0) return;
    var num_buf: [32]u8 = undefined;

    for (table.combinator_slots.items, 0..) |cc, i| {
        if (cc.elements.len == 0) continue;
        try out.appendSlice(allocator, "static const onez_image_combinator_element_t ");
        try writeCombinatorElementsSym(out, allocator, i);
        try out.appendSlice(allocator, "[] = {\n");
        for (cc.elements) |element| {
            const encoded: struct { kind: u32, slot: u32 } = switch (element) {
                // `.type` carries the 1-based typevalue slot directly; slot 0
                // is the table sentinel, so a present element is always > 0.
                .type => |tv| .{ .kind = 1, .slot = table.type_slot_index.get(tv) orelse 0 },
                .protocol => |pd| .{ .kind = 2, .slot = table.lookupProtocolSlot(pd) orelse 0 },
                // Post-order interning guarantees a nested combinator already
                // holds a slot at a lower index than its parent.
                .combinator => |nested| .{ .kind = 3, .slot = table.lookupCombinatorSlot(nested) orelse 0 },
            };
            try out.appendSlice(allocator, "    { .kind = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{encoded.kind}) catch unreachable);
            try out.appendSlice(allocator, ", .slot = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{encoded.slot}) catch unreachable);
            try out.appendSlice(allocator, " },\n");
        }
        try out.appendSlice(allocator, "};\n");
    }
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "static const onez_image_constraintcombinator_description_t onez_image_constraintcombinator_descriptions_storage[] = {\n");
    for (table.combinator_slots.items, 0..) |cc, i| {
        // 0 = intersection, 1 = union, matching the loader's kind decode.
        const kind: u32 = switch (cc.kind) {
            .intersection => 0,
            .@"union" => 1,
        };
        try out.appendSlice(allocator, "    { .slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable);
        try out.appendSlice(allocator, ", .combinator_id = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{cc.combinator_id}) catch unreachable);
        try out.appendSlice(allocator, ", .kind = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{kind}) catch unreachable);
        try out.appendSlice(allocator, ", .element_count = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{cc.elements.len}) catch unreachable);
        try out.appendSlice(allocator, ", .elements = ");
        if (cc.elements.len > 0) {
            try writeCombinatorElementsSym(out, allocator, i);
        } else {
            try out.appendSlice(allocator, "NULL");
        }
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn writeCombinatorElementsSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    cc_idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_cc_{d}_elements", .{cc_idx}) catch unreachable);
}

/// Reserved type-slot sentinels in a dispatch-entry row, kept in sync
/// with the `ONEZ_DISPATCH_TYPE_*` C macros.
const dispatch_type_unary: u32 = 0xFFFFFFFF;
const dispatch_type_any: u32 = 0xFFFFFFFE;

/// One serialized dispatch-entry row, collected before emission so the
/// rows can be sorted into a deterministic order independent of the
/// dispatch HashMap's iteration order.
const DispatchEntryRow = struct {
    dispatch_id: u32,
    type_a_slot: u32,
    type_b_slot: u32,
    quotation_id: u32,
    module_name: ?[]const u8,
    generic_name: ?[]const u8,
    /// Serialized body bytecode for a method body that did not compile to a native function but
    /// runs interpreted in a full runtime image. Null when the body compiled, since the loader
    /// resolves it through the quotation-function table by `quotation_id` instead). Borrowed from
    /// the codegen's interpreter-run-bodies map.
    body_bytecode: ?[]const u8 = null,
    /// True when `body_bytecode` was serialized fresh for this row (an
    /// undiscovered method body) and must be freed by the emitter; false
    /// when borrowed from the codegen's interpreter-run-bodies map.
    owns_body: bool = false,

    fn lessThan(_: void, a: DispatchEntryRow, b: DispatchEntryRow) bool {
        if (a.dispatch_id != b.dispatch_id) return a.dispatch_id < b.dispatch_id;
        if (a.type_a_slot != b.type_a_slot) return a.type_a_slot < b.type_a_slot;
        if (a.type_b_slot != b.type_b_slot) return a.type_b_slot < b.type_b_slot;
        return a.quotation_id < b.quotation_id;
    }
};

/// Resolve a dispatch key's `*const TypeDescriptor` to the value the
/// serialized row carries: the unary or wildcard sentinel when the
/// descriptor is one of the dispatch table's synthetic sentinels, the
/// 1-based typevalue slot otherwise, or 0 when no live TypeValue
/// reaches it.
fn dispatchTypeSlot(
    ctx: *const Context,
    table: *const StackEffectTable,
    desc_index: *const std.AutoHashMapUnmanaged(*const value_mod.TypeDescriptor, *const value_mod.TypeValue),
    descriptor: *const value_mod.TypeDescriptor,
) u32 {
    if (ctx.dispatch_unary_sentinel) |sentinel| {
        if (sentinel.descriptor == descriptor) return dispatch_type_unary;
    }
    if (ctx.dispatch_any_sentinel) |sentinel| {
        if (sentinel.descriptor == descriptor) return dispatch_type_any;
    }
    if (desc_index.get(descriptor)) |tv| {
        return table.type_slot_index.get(tv) orelse 0;
    }
    return 0;
}

/// Emit `onez_image_dispatch_entry_descriptions_storage[]`: one row per
/// reachable user `.quotation` method dispatch entry. An entry is
/// reachable when its body pointer appears in `quotation_id_map`, the
/// freeze-time quotation-compilation manifest; that key set is the
/// dispatch_id-granular reachable set since 308.1 adds every reached
/// generic's method bodies to it. Native and host-callback entries are
/// skipped: native dispatch is already present at runtime and
/// function-pointer bodies are not serializable. Returns the row count.
/// No-op (returns 0, emits nothing) when the map is null or no entry
/// qualifies.
fn emitDispatchEntryTable(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    ctx: *const Context,
    table: *const StackEffectTable,
    struct_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    // When true, a method the freeze never compiled gets an interpreter-run
    // row carrying its serialized body, so an interpreted quotation can
    // dispatch it. Only a full runtime image carries interpreter bodies, so a
    // metadata-only image keeps the prior behavior of emitting rows for
    // compiled methods only.
    emit_unreached_interp_run: bool,
    quotation_id_map: ?*const std.AutoHashMapUnmanaged(usize, u32),
    dispatch_id_names: ?*const std.AutoHashMapUnmanaged(u32, []const u8),
    interpreter_run_bodies: ?*const std.AutoHashMapUnmanaged(u32, []const u8),
) Allocator.Error!u32 {
    const map = quotation_id_map orelse return 0;

    var desc_index: std.AutoHashMapUnmanaged(*const value_mod.TypeDescriptor, *const value_mod.TypeValue) = .{};
    defer desc_index.deinit(allocator);
    try indexKnownTypeValues(&desc_index, allocator, ctx);
    // `indexKnownTypeValues` covers built-in, resource, union, and enum types
    // but not user-defined `virtual{` / `struct{` types. A method dispatched on
    // such a type would otherwise resolve to slot 0 (unresolved) and be dropped
    // by the loader. Every TypeValue already interned in the slot table has a
    // real slot, so index those descriptors too -- this is the canonical
    // TypeValue the dispatch key references, so pointer identity holds.
    var slot_iter = table.type_slot_index.iterator();
    while (slot_iter.next()) |slot| {
        const tv = slot.key_ptr.*;
        if (tv.descriptor) |desc| try desc_index.put(allocator, desc, tv);
    }

    const slot_maps: instruction_bytecode.SlotEncodingMaps = .{
        .typevalue_slot_index = &table.type_slot_index,
        .struct_type_slot_index = struct_index,
        .marker_slot_index = &table.marker_slot_index,
        .parameter_slot_index = &table.parameter_slot_index,
        .tagged_slot_index = &table.tagged_slot_index,
        .mutable_map_slot_index = &table.mutable_map_slot_index,
        .struct_instance_slot_index = &table.struct_instance_slot_index,
    };

    var rows: std.ArrayListUnmanaged(DispatchEntryRow) = .{};
    defer {
        // Free the bodies serialized fresh for undiscovered entries; rows
        // whose body bytes were borrowed from `interpreter_run_bodies` are
        // owned by the caller and left alone.
        for (rows.items) |row| {
            if (row.owns_body) {
                if (row.body_bytecode) |bytes| allocator.free(bytes);
            }
        }
        rows.deinit(allocator);
    }

    var iter = ctx.dispatch.entries.iterator();
    while (iter.next()) |slot| {
        const entry = slot.value_ptr.*;
        const body = switch (entry.body) {
            .quotation => |q| q.instructions,
            .native_fn, .host_callback => continue,
        };
        const key = slot.key_ptr.*;
        // A method body the freeze compiled or collected has a quotation_id; its interpreter-run
        // bytecode is already serialized into interpreter_run_bodies.
        //
        // A method body the freeze never reached, e.g., a generated field getter called only
        // through a dynamically-retrieved quotation, has no quotation_id; serialize its body here
        // (image-encoded for the struct_type literal) so the loader registers an interpreter-run
        // entry. Without this such a method is dropped and dispatching it from an interpreted
        // quotation fails with "no method found".
        var quotation_id: u32 = undefined;
        var body_bytecode: ?[]const u8 = null;
        var owns_body = false;
        if (map.get(@intFromPtr(body.ptr))) |qid| {
            quotation_id = qid;
            body_bytecode = if (interpreter_run_bodies) |m| m.get(qid) else null;
        } else {
            if (!emit_unreached_interp_run) continue;
            quotation_id = dispatch_interp_quotation_id_sentinel;
            body_bytecode = instruction_bytecode.serializeQuotationInstructionsForImage(body, allocator, &slot_maps) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotEncodable => continue,
            };
            owns_body = true;
        }

        try rows.append(allocator, .{
            .dispatch_id = key.dispatch_id,
            .type_a_slot = dispatchTypeSlot(ctx, table, &desc_index, key.type_a),
            .type_b_slot = dispatchTypeSlot(ctx, table, &desc_index, key.type_b),
            .quotation_id = quotation_id,
            .module_name = if (entry.source_module) |m| m.name else null,
            .generic_name = if (dispatch_id_names) |m| m.get(key.dispatch_id) else null,
            .body_bytecode = body_bytecode,
            .owns_body = owns_body,
        });
    }

    if (rows.items.len == 0) return 0;

    std.mem.sort(DispatchEntryRow, rows.items, {}, DispatchEntryRow.lessThan);

    var num_buf: [32]u8 = undefined;

    // Per-row body bytecode arrays for interpreter-run method bodies, emitted
    // before the row storage so each row can reference its array. Keyed by
    // quotation_id, which is unique per row.
    for (rows.items, 0..) |row, ri| {
        const bytes = row.body_bytecode orelse continue;
        try out.appendSlice(allocator, "static const uint8_t onez_image_dispatch_q_");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{ri}) catch unreachable);
        try out.appendSlice(allocator, "_body[] = {");
        for (bytes, 0..) |byte, bi| {
            if (bi > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{byte}) catch unreachable);
        }
        try out.appendSlice(allocator, "};\n");
    }

    try out.appendSlice(allocator, "static const onez_image_dispatch_entry_description_t onez_image_dispatch_entry_descriptions_storage[] = {\n");
    for (rows.items, 0..) |row, ri| {
        try out.appendSlice(allocator, "    { .dispatch_id = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{row.dispatch_id}) catch unreachable);
        try out.appendSlice(allocator, ", .type_a_slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{row.type_a_slot}) catch unreachable);
        try out.appendSlice(allocator, ", .type_b_slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{row.type_b_slot}) catch unreachable);
        try out.appendSlice(allocator, ", .quotation_id = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{row.quotation_id}) catch unreachable);
        try out.appendSlice(allocator, ", .module_name = ");
        if (row.module_name) |name| {
            try emitCStringLiteral(out, allocator, name);
            try out.appendSlice(allocator, ", .module_name_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{name.len}) catch unreachable);
        } else {
            try out.appendSlice(allocator, "NULL, .module_name_len = 0");
        }
        try out.appendSlice(allocator, ", .generic_name = ");
        if (row.generic_name) |name| {
            try emitCStringLiteral(out, allocator, name);
            try out.appendSlice(allocator, ", .generic_name_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{name.len}) catch unreachable);
        } else {
            try out.appendSlice(allocator, "NULL, .generic_name_len = 0");
        }
        try out.appendSlice(allocator, ", .body_bytecode = ");
        if (row.body_bytecode) |bytes| {
            try out.appendSlice(allocator, "onez_image_dispatch_q_");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{ri}) catch unreachable);
            try out.appendSlice(allocator, "_body, .body_bytecode_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{bytes.len}) catch unreachable);
        } else {
            try out.appendSlice(allocator, "NULL, .body_bytecode_len = 0");
        }
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator, "};\n\n");

    return @intCast(rows.items.len);
}

/// Count the method rows of a descriptor: one per `.symbol` entry in the
/// flat symbol/effect sequence.
fn countProtocolMethods(pd: *const value_mod.ProtocolDescriptor) u32 {
    var n: u32 = 0;
    for (pd.methods) |entry| {
        if (entry == .symbol) n += 1;
    }
    return n;
}

fn writeProtocolMethodNameSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    pd_idx: usize,
    method_idx: u32,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_pd_{d}_m{d}_name", .{ pd_idx, method_idx }) catch unreachable);
}

fn writeProtocolMethodsSym(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    pd_idx: usize,
) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "onez_image_pd_{d}_methods", .{pd_idx}) catch unreachable);
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
        for (st.field_types, 0..) |element, fi| {
            if (fi > 0) try out.append(allocator, ',');
            try out.append(allocator, ' ');
            const maybe_tv: ?*const value_mod.TypeValue = if (element) |e| switch (e) {
                .type => |tv| tv,
                .protocol, .combinator => null,
            } else null;
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
        .struct_ => |sd| {
            const tvs = try structFieldTypeValues(allocator, sd.field_types);
            defer if (tvs.len > 0) allocator.free(tvs);
            try emitFieldArrays(out, allocator, idx, sd.fields, tvs, effect_table);
        },
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

/// AOT serialization currently encodes only concrete-type field constraints;
/// protocol- and combinator-bound struct fields are serialized as unannotated
/// pending dedicated combinator serialization. Concrete-type fields round-trip.
fn structFieldTypeValues(
    allocator: Allocator,
    field_types: []const ?value_mod.ConstraintCombinator.Element,
) Allocator.Error![]const ?*const value_mod.TypeValue {
    if (field_types.len == 0) return &.{};
    const out = try allocator.alloc(?*const value_mod.TypeValue, field_types.len);
    for (field_types, 0..) |element, i| {
        out[i] = if (element) |e| switch (e) {
            .type => |tv| tv,
            .protocol, .combinator => null,
        } else null;
    }
    return out;
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
        .enum_variant => |evd| if (evd.anon_struct) |st| {
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
        // `annotation_kind` discriminates which slot table
        // `annotation_slot` indexes: 1 = typevalue slots (1-based, 0
        // doubles as a lookup miss), 2 = protocol descriptor slots
        // (0-based), 3 = constraint combinator slots (0-based). A
        // descriptor pointer missing from its intern table degrades to "no
        // annotation" rather than emitting a dangling index.
        const annotation: struct { kind: u8, slot: u32 } = if (param.type_annotation) |ann| switch (ann) {
            .type => |tv| .{ .kind = 1, .slot = table.type_slot_index.get(tv) orelse 0 },
            .protocol => |pd| if (table.lookupProtocolSlot(pd)) |slot|
                .{ .kind = 2, .slot = slot }
            else
                .{ .kind = 0, .slot = 0 },
            .combination => |cc| if (table.lookupCombinatorSlot(cc)) |slot|
                .{ .kind = 3, .slot = slot }
            else
                .{ .kind = 0, .slot = 0 },
        } else .{ .kind = 0, .slot = 0 };
        const has_quot: u8 = if (param.quotation_effect != null) 1 else 0;
        const is_row: u8 = if (param.is_row_variable) 1 else 0;
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
        try out.appendSlice(allocator, ", .annotation_kind = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{annotation.kind}) catch unreachable);
        try out.appendSlice(allocator, ", .has_quotation_effect = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{has_quot}) catch unreachable);
        try out.appendSlice(allocator, ", ._reserved = 0, .annotation_slot = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{annotation.slot}) catch unreachable);
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
    var it = ctx.module_cache_value.map.iterator();
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
        \\    uint8_t  annotation_kind;       /* 0 = none, 1 = type, 2 = protocol */
        \\    uint8_t  has_quotation_effect;
        \\    uint8_t  _reserved;
        \\    uint32_t annotation_slot;       /* kind 1: index into onez_image_typevalue_slots   */
        \\                                    /*         (1-based; 0 doubles as a lookup miss).  */
        \\                                    /* kind 2: index into                              */
        \\                                    /*         onez_image_protocoldescriptor_slots     */
        \\                                    /*         (0-based; kind discriminates).         */
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
        \\    /* Diagnostic metadata. Each string is NULL when absent; len 0 mirrors NULL.   */
        \\    /* Retained even in metadata-only images so >word-info and all-words can       */
        \\    /* surface source locations, doc-strings, and provenance for stack traces.    */
        \\    const char *doc;
        \\    uint32_t doc_len;
        \\    const char *source_file;
        \\    uint32_t source_file_len;
        \\    uint32_t source_line;
        \\    uint32_t source_column;
        \\    const char *provenance_generator;
        \\    uint32_t provenance_generator_len;
        \\    const char *provenance_parent;
        \\    uint32_t provenance_parent_len;
        \\    const char *provenance_role;
        \\    uint32_t provenance_role_len;
        \\} onez_image_word_t;
        \\
        \\/* TypeValue static C data schema. Every TypeValue reachable from any module-private word's body or
        \\ * from another descriptor's cross-references gets a row in onez_image_typevalues_storage[] and a
        \\ * paired row in onez_image_typedescriptors_storage[] indexed by the same slot number.
        \\ *
        \\ * Cross-references between TypeValues encode as slot indices into onez_image_typevalue_slots[]; the
        \\ * loader fills the slot table during pass 2 of the load and reads it during pass 3 when materializing
        \\ * each descriptor's kind-specific data.
        \\ *
        \\ * The `kind` matches Zig's TypeKind:
        \\ *
        \\ *   0  builtin
        \\ *   1  sentinel
        \\ *   2  struct_
        \\ *   3  virtual
        \\ *   4  enum_
        \\ *   5  enum_variant
        \\ *   6  resource
        \\ *   7  ffi_struct
        \\ *   8  union_
        \\ *
        \\**/
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
        \\/* Per-slot description for `.marker` literal pushes. The loader walks  */
        \\/* onez_image_marker_descriptions_storage[], resolves the name to a    */
        \\/* well-known *Marker if it matches a built-in singleton, otherwise   */
        \\/* allocates a fresh *Marker, then patches                            */
        \\/* onez_image_marker_slots[slot] with the resolved pointer.            */
        \\typedef struct onez_image_marker_description {
        \\    const char *name;
        \\    uint32_t    name_len;
        \\    uint32_t    slot;                 /* index into onez_image_marker_slots */
        \\} onez_image_marker_description_t;
        \\
        \\/* Per-slot description for `.parameter` literal pushes. Parameters    */
        \\/* are always loader-allocated; the default-quotation bytecode encodes */
        \\/* the lazily-evaluated default body, deserialized at startup via the  */
        \\/* same instruction_bytecode decoder the runtime uses for word bodies. */
        \\typedef struct onez_image_parameter_description {
        \\    const char *name;
        \\    uint32_t    name_len;
        \\    uint32_t    slot;                 /* index into onez_image_parameter_slots */
        \\    const uint8_t *default_quotation_bytecode;
        \\    uint32_t       default_quotation_bytecode_len;
        \\} onez_image_parameter_description_t;
        \\
        \\/* Per-slot description for `.tagged` literal pushes. The loader walks   */
        \\/* onez_image_tagged_descriptions_storage[], resolves the tag's          */
        \\/* `*const VirtualType` via the TypeValue slot table entry at            */
        \\/* `tag_typevalue_slot` (using `TypeValue.virtual_type` populated by     */
        \\/* the typevalue-load pass), deserializes the inner Value through        */
        \\/* `deserializeValueAtForImage`, allocates a runtime `*const Value`      */
        \\/* carrying `.tagged = .{ .tag = vt, .inner = inner_ptr }`, and patches  */
        \\/* `onez_image_tagged_slots[slot]` with that pointer.                    */
        \\typedef struct onez_image_tagged_description {
        \\    const char *name;
        \\    uint32_t    name_len;
        \\    uint32_t    slot;                 /* index into onez_image_tagged_slots */
        \\    uint32_t    tag_typevalue_slot;   /* index into onez_image_typevalue_slots */
        \\    const uint8_t *inner_bytecode;
        \\    uint32_t       inner_bytecode_len;
        \\} onez_image_tagged_description_t;
        \\
        \\/* Per-slot description for `.mutable_map` literal pushes. The loader  */
        \\/* allocates a fresh `*MutableMap` per row, decodes the serialized    */
        \\/* entry bytes through `deserializeValueAtForImage` (so nested type-  */
        \\/* carrier values resolve through their slot tables), populates the   */
        \\/* map, and patches `onez_image_mutable_map_slots[slot]` with the     */
        \\/* allocated pointer. Identity is preserved across the freeze        */
        \\/* boundary: every push site that referenced the same parse-time     */
        \\/* MutableMap shares the same runtime instance.                       */
        \\typedef struct onez_image_mutable_map_description {
        \\    uint32_t    slot;                 /* index into onez_image_mutable_map_slots */
        \\    const uint8_t *entries_bytecode;
        \\    uint32_t       entries_bytecode_len;
        \\} onez_image_mutable_map_description_t;
        \\
        \\/* One frozen struct instance. The loader allocates a fresh             */
        \\/* StructInstance whose struct_type is onez_image_struct_type_slots     */
        \\/* [struct_type_slot], decodes the field values from fields_bytecode    */
        \\/* (a u32 count followed by each field via deserializeValueAtForImage), */
        \\/* and patches onez_image_struct_instance_slots[slot]. Identity is      */
        \\/* preserved across the freeze boundary.                                */
        \\typedef struct onez_image_struct_instance_description {
        \\    uint32_t    slot;                 /* index into onez_image_struct_instance_slots */
        \\    uint32_t    struct_type_slot;     /* index into onez_image_struct_type_slots */
        \\    const uint8_t *fields_bytecode;
        \\    uint32_t       fields_bytecode_len;
        \\} onez_image_struct_instance_description_t;
        \\
        \\/* One required method of a protocol. The effect index points into       */
        \\/* onez_image_stack_effects_storage[]; 0 means no declared effect.        */
        \\typedef struct onez_image_protocol_method {
        \\    const char *name;
        \\    uint32_t    name_len;
        \\    uint32_t    stack_effect_idx;     /* 0 = no declared effect */
        \\} onez_image_protocol_method_t;
        \\
        \\/* Per-slot description for protocol-bounded dispatch. The loader reuses  */
        \\/* a same-named descriptor from the runtime context's protocol registry   */
        \\/* when one exists; otherwise it reconstructs the descriptor from these   */
        \\/* fields. Either way it patches                                          */
        \\/* onez_image_protocoldescriptor_slots[slot] with the pointer.            */
        \\typedef struct onez_image_protocoldescriptor_description {
        \\    const char *name;
        \\    uint32_t    name_len;
        \\    uint32_t    slot;                 /* index into onez_image_protocoldescriptor_slots */
        \\    uint32_t    protocol_id;          /* build-time intern key; preserved at load */
        \\    uint32_t    method_count;
        \\    const struct onez_image_protocol_method *methods;
        \\} onez_image_protocoldescriptor_description_t;
        \\
        \\/* One element of a constraint combinator. The kind discriminant picks    */
        \\/* the slot-numbering convention: kind 1 indexes the 1-based typevalue     */
        \\/* slot table, kind 2 the 0-based protocol descriptor slots, kind 3 the    */
        \\/* 0-based combinator slots (a nested combinator at a lower index).        */
        \\typedef struct onez_image_combinator_element {
        \\    uint32_t kind;   /* 1 = type, 2 = protocol, 3 = combinator */
        \\    uint32_t slot;
        \\} onez_image_combinator_element_t;
        \\
        \\/* Per-slot description for a constraint combinator. The loader rebuilds   */
        \\/* the descriptor from the kind, element list, and combinator_id, then     */
        \\/* patches onez_image_constraintcombinator_slots[slot] with the pointer.   */
        \\typedef struct onez_image_constraintcombinator_description {
        \\    uint32_t    slot;            /* index into onez_image_constraintcombinator_slots */
        \\    uint32_t    combinator_id;   /* build-time intern key; preserved at load */
        \\    uint32_t    kind;            /* 0 = intersection, 1 = union */
        \\    uint32_t    element_count;
        \\    const struct onez_image_combinator_element *elements;
        \\} onez_image_constraintcombinator_description_t;
        \\
        \\/* Reserved type-slot values in a dispatch-entry row. A real type     */
        \\/* references the 1-based typevalue slot table; these sentinels stand  */
        \\/* in for the dispatch keys' synthetic sentinel descriptors, which     */
        \\/* carry no typevalue slot. The loader maps them back to the runtime   */
        \\/* unary and wildcard sentinel descriptors.                            */
        \\#define ONEZ_DISPATCH_TYPE_UNARY 0xFFFFFFFFu  /* type_b for unary dispatch */
        \\#define ONEZ_DISPATCH_TYPE_ANY   0xFFFFFFFEu  /* wildcard `*` type_a       */
        \\
        \\/* One reachable user method dispatch entry. The loader resolves       */
        \\/* type_a / type_b through the typevalue slot table (or the reserved   */
        \\/* sentinels above), the body through onez_quotation_table by          */
        \\/* quotation_id, and the defining module by name, then replays the     */
        \\/* entry into the runtime dispatch table via registerDispatch.         */
        \\typedef struct onez_image_dispatch_entry_description {
        \\    uint32_t    dispatch_id;     /* freeze-time generic-word id, verbatim */
        \\    uint32_t    type_a_slot;     /* 1-based typevalue slot, or a reserved sentinel */
        \\    uint32_t    type_b_slot;     /* 1-based typevalue slot, or a reserved sentinel */
        \\    uint32_t    quotation_id;    /* index into onez_quotation_table */
        \\    const char *module_name;     /* defining module name, or NULL */
        \\    uint32_t    module_name_len;
        \\    const char *generic_name;    /* generic word name for name->dispatch_id replay, or NULL */
        \\    uint32_t    generic_name_len;
        \\    const uint8_t *body_bytecode; /* interpreter-run method body bytecode, or NULL when compiled */
        \\    uint32_t    body_bytecode_len;
        \\} onez_image_dispatch_entry_description_t;
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
        \\    uint32_t marker_slot_count;
        \\    uint32_t parameter_slot_count;
        \\    uint32_t tagged_slot_count;
        \\    uint32_t mutable_map_slot_count;
        \\    uint32_t struct_instance_slot_count;
        \\    uint32_t protocoldescriptor_slot_count;
        \\    uint32_t constraintcombinator_slot_count;
        \\    uint32_t dispatch_entry_slot_count;
        \\    const struct onez_image_module *modules;
        \\    const struct onez_image_word *words;
        \\    const struct onez_image_marker *markers;
        \\    const struct onez_image_stack_effect *stack_effects;
        \\    const struct onez_image_typevalue *typevalues;
        \\    const struct onez_image_typedescriptor *typedescriptors;
        \\    const struct onez_image_struct_type *struct_types;
        \\    const struct onez_image_marker_description *marker_descriptions;
        \\    const struct onez_image_parameter_description *parameter_descriptions;
        \\    const struct onez_image_tagged_description *tagged_descriptions;
        \\    const struct onez_image_mutable_map_description *mutable_map_descriptions;
        \\    const struct onez_image_struct_instance_description *struct_instance_descriptions;
        \\    const struct onez_image_protocoldescriptor_description *protocoldescriptor_descriptions;
        \\    const struct onez_image_constraintcombinator_description *constraintcombinator_descriptions;
        \\    const struct onez_image_dispatch_entry_description *dispatch_entry_descriptions;
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

/// Emit per-word diagnostic-metadata string literals: doc, source_file,
/// and the three provenance strings. Each absent field is left
/// unemitted; the word table emits NULL/0 for those rows. This is
/// retained for both runtime-image and metadata-only image modes so
/// `>word-info`, `all-words`, and stack traces can name source
/// locations and generator roles.
fn emitWordDiagnosticStrings(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    ctx: *const Context,
    manifest: ImageManifest,
) Allocator.Error!void {
    if (manifest.entries.len == 0) return;
    var emitted_any = false;
    for (manifest.entries, 0..) |entry, idx| {
        const mw_ptr = lookupModuleWord(ctx, entry) orelse continue;
        if (mw_ptr.doc) |d| {
            try out.appendSlice(allocator, "static const char ");
            try writeWordDocSym(out, allocator, idx);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, d);
            try out.appendSlice(allocator, ";\n");
            emitted_any = true;
        }
        if (mw_ptr.source_file) |sf| {
            try out.appendSlice(allocator, "static const char ");
            try writeWordSourceFileSym(out, allocator, idx);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, sf);
            try out.appendSlice(allocator, ";\n");
            emitted_any = true;
        }
        if (mw_ptr.provenance) |p| {
            try out.appendSlice(allocator, "static const char ");
            try writeWordProvGenSym(out, allocator, idx);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, p.generator);
            try out.appendSlice(allocator, ";\n");
            try out.appendSlice(allocator, "static const char ");
            try writeWordProvParentSym(out, allocator, idx);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, p.parent);
            try out.appendSlice(allocator, ";\n");
            try out.appendSlice(allocator, "static const char ");
            try writeWordProvRoleSym(out, allocator, idx);
            try out.appendSlice(allocator, "[] = ");
            try emitCStringLiteral(out, allocator, p.role);
            try out.appendSlice(allocator, ";\n");
            emitted_any = true;
        }
    }
    if (emitted_any) try out.append(allocator, '\n');
}

fn writeWordDocSym(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, idx: usize) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_w_{d}_doc", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeWordSourceFileSym(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, idx: usize) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_w_{d}_sf", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeWordProvGenSym(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, idx: usize) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_w_{d}_pg", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeWordProvParentSym(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, idx: usize) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_w_{d}_pp", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
}

fn writeWordProvRoleSym(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, idx: usize) Allocator.Error!void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "onez_image_w_{d}_pr", .{idx}) catch unreachable;
    try out.appendSlice(allocator, s);
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
    effect_table: *const StackEffectTable,
    struct_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
) ImageEmitError!void {
    if (manifest.entries.len == 0) return;

    const slot_maps: instruction_bytecode.SlotEncodingMaps = .{
        .typevalue_slot_index = &effect_table.type_slot_index,
        .struct_type_slot_index = struct_index,
        .marker_slot_index = &effect_table.marker_slot_index,
        .parameter_slot_index = &effect_table.parameter_slot_index,
        .tagged_slot_index = &effect_table.tagged_slot_index,
        .mutable_map_slot_index = &effect_table.mutable_map_slot_index,
        .struct_instance_slot_index = &effect_table.struct_instance_slot_index,
    };

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
        // Words that push a TypeValue have their body rewritten by the
        // runtime-image loader after it allocates the runtime
        // TypeValue. Encoding the body as bytecode would lower the
        // `push_literal: type_val` to `call_word value.name`, which for
        // a type-defining word is the word itself -- infinite
        // recursion at runtime. Skip emission and let the loader
        // populate the body from `typevalue_slot`.
        if (findTypeValueLiteral(mw_ptr) != null) continue;

        // Generator-emitted words (struct constructors, getters,
        // predicates, ...) push a runtime `.struct_type` literal the
        // by-value serializer cannot encode. Route them through the
        // image serializer so the literal slot-encodes and the loader
        // resolves it to the live runtime StructType; without a real
        // body these words run as no-ops when an interpreted quotation
        // (`jitCallQuotation`) calls them. A still-unencodable generated
        // body falls back to the prior empty-body behavior.
        if (std.posix.getenv("ONEZ_DEBUG_NTH") != null and mw_ptr.provenance != null) {
            std.debug.print("DBG emit-body parent={?s} role={?s} bodylen={d}\n", .{ if (mw_ptr.provenance) |p| p.parent else null, if (mw_ptr.provenance) |p| p.role else null, body.len });
        }
        const bytes = if (mw_ptr.provenance != null)
            instruction_bytecode.serializeQuotationInstructionsForImage(body, allocator, &slot_maps) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotEncodable => continue,
            }
        else
            instruction_bytecode.serializeQuotationInstructions(body, allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // A user word body may push a slot-encodable literal (i.e., a mutable_map holding
                // struct instances, a struct instance, a nested array of them) that the by-value
                // serializer cannot encode.
                //
                // Fall back to the image serializer so the literal slot-references the live runtime
                // value. The loader decodes every body through the image decoder, which resolves the
                // slot tags.
                error.NotEncodable => instruction_bytecode.serializeQuotationInstructionsForImage(body, allocator, &slot_maps) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NotEncodable => return error.NotEncodable,
                },
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
        try out.appendSlice(allocator, ",\n");

        // Diagnostic metadata: doc, source location, provenance. Each
        // string is NULL/0 when the underlying `WordDefinition` field
        // is absent. Doc / source_file / provenance triple are emitted
        // up front by `emitWordDiagnosticStrings`.
        if (mw_ptr.doc) |d| {
            try out.appendSlice(allocator, "        .doc = ");
            try writeWordDocSym(out, allocator, idx);
            try out.appendSlice(allocator, ",\n        .doc_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{d.len}) catch unreachable);
            try out.appendSlice(allocator, ",\n");
        } else {
            try out.appendSlice(allocator, "        .doc = NULL,\n        .doc_len = 0,\n");
        }
        if (mw_ptr.source_file) |sf| {
            try out.appendSlice(allocator, "        .source_file = ");
            try writeWordSourceFileSym(out, allocator, idx);
            try out.appendSlice(allocator, ",\n        .source_file_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{sf.len}) catch unreachable);
            try out.appendSlice(allocator, ",\n");
        } else {
            try out.appendSlice(allocator, "        .source_file = NULL,\n        .source_file_len = 0,\n");
        }
        try out.appendSlice(allocator, "        .source_line = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}u", .{mw_ptr.source_line}) catch unreachable);
        try out.appendSlice(allocator, ",\n        .source_column = ");
        try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}u", .{mw_ptr.source_column}) catch unreachable);
        try out.appendSlice(allocator, ",\n");
        if (mw_ptr.provenance) |p| {
            try out.appendSlice(allocator, "        .provenance_generator = ");
            try writeWordProvGenSym(out, allocator, idx);
            try out.appendSlice(allocator, ",\n        .provenance_generator_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{p.generator.len}) catch unreachable);
            try out.appendSlice(allocator, ",\n        .provenance_parent = ");
            try writeWordProvParentSym(out, allocator, idx);
            try out.appendSlice(allocator, ",\n        .provenance_parent_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{p.parent.len}) catch unreachable);
            try out.appendSlice(allocator, ",\n        .provenance_role = ");
            try writeWordProvRoleSym(out, allocator, idx);
            try out.appendSlice(allocator, ",\n        .provenance_role_len = ");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{p.role.len}) catch unreachable);
            try out.appendSlice(allocator, ",\n");
        } else {
            try out.appendSlice(allocator,
                \\        .provenance_generator = NULL,
                \\        .provenance_generator_len = 0,
                \\        .provenance_parent = NULL,
                \\        .provenance_parent_len = 0,
                \\        .provenance_role = NULL,
                \\        .provenance_role_len = 0,
                \\
            );
        }
        try out.appendSlice(allocator,
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
    const marker_slot_count: u32 = effect_table.markerSlotCount();
    const parameter_slot_count: u32 = effect_table.parameterSlotCount();
    const tagged_slot_count: u32 = effect_table.taggedSlotCount();
    const mutable_map_slot_count: u32 = effect_table.mutableMapSlotCount();
    const struct_instance_slot_count: u32 = effect_table.structInstanceSlotCount();
    const protocoldescriptor_slot_count: u32 = effect_table.protocolSlotCount();
    const constraintcombinator_slot_count: u32 = effect_table.combinatorSlotCount();

    const has_entries = manifest.entries.len > 0;
    const modules_ref: []const u8 = if (has_entries) "onez_image_modules_storage" else "NULL";
    const words_ref: []const u8 = if (has_entries) "onez_image_words_storage" else "NULL";
    const markers_ref: []const u8 = if (pool.count() > 0) "onez_image_markers_storage" else "NULL";
    const effects_ref: []const u8 = if (effect_table.effectCount() > 1) "onez_image_stack_effects_storage" else "NULL";
    const typevalues_ref: []const u8 = if (typevalue_count > 0) "onez_image_typevalues_storage" else "NULL";
    const typedescriptors_ref: []const u8 = if (typevalue_count > 0) "onez_image_typedescriptors_storage" else "NULL";
    const struct_types_ref: []const u8 = if (struct_type_count > 0) "onez_image_struct_types_storage" else "NULL";
    const marker_descs_ref: []const u8 = if (marker_slot_count > 0) "onez_image_marker_descriptions_storage" else "NULL";
    const parameter_descs_ref: []const u8 = if (parameter_slot_count > 0) "onez_image_parameter_descriptions_storage" else "NULL";
    const tagged_descs_ref: []const u8 = if (tagged_slot_count > 0) "onez_image_tagged_descriptions_storage" else "NULL";
    const mutable_map_descs_ref: []const u8 = if (mutable_map_slot_count > 0) "onez_image_mutable_map_descriptions_storage" else "NULL";
    const struct_instance_descs_ref: []const u8 = if (struct_instance_slot_count > 0) "onez_image_struct_instance_descriptions_storage" else "NULL";
    const protocoldescriptor_descs_ref: []const u8 = if (protocoldescriptor_slot_count > 0) "onez_image_protocoldescriptor_descriptions_storage" else "NULL";
    const constraintcombinator_descs_ref: []const u8 = if (constraintcombinator_slot_count > 0) "onez_image_constraintcombinator_descriptions_storage" else "NULL";
    const dispatch_entry_descs_ref: []const u8 = if (stats.dispatch_entry_slot_count > 0) "onez_image_dispatch_entry_descriptions_storage" else "NULL";

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
    try out.appendSlice(allocator, ",\n    .marker_slot_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{marker_slot_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .parameter_slot_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{parameter_slot_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .tagged_slot_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{tagged_slot_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .mutable_map_slot_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{mutable_map_slot_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .struct_instance_slot_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{struct_instance_slot_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .protocoldescriptor_slot_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{protocoldescriptor_slot_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .constraintcombinator_slot_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{constraintcombinator_slot_count}) catch unreachable);
    try out.appendSlice(allocator, ",\n    .dispatch_entry_slot_count = ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{stats.dispatch_entry_slot_count}) catch unreachable);
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
    try out.appendSlice(allocator, ",\n    .marker_descriptions = ");
    try out.appendSlice(allocator, marker_descs_ref);
    try out.appendSlice(allocator, ",\n    .parameter_descriptions = ");
    try out.appendSlice(allocator, parameter_descs_ref);
    try out.appendSlice(allocator, ",\n    .tagged_descriptions = ");
    try out.appendSlice(allocator, tagged_descs_ref);
    try out.appendSlice(allocator, ",\n    .mutable_map_descriptions = ");
    try out.appendSlice(allocator, mutable_map_descs_ref);
    try out.appendSlice(allocator, ",\n    .struct_instance_descriptions = ");
    try out.appendSlice(allocator, struct_instance_descs_ref);
    try out.appendSlice(allocator, ",\n    .protocoldescriptor_descriptions = ");
    try out.appendSlice(allocator, protocoldescriptor_descs_ref);
    try out.appendSlice(allocator, ",\n    .constraintcombinator_descriptions = ");
    try out.appendSlice(allocator, constraintcombinator_descs_ref);
    try out.appendSlice(allocator, ",\n    .dispatch_entry_descriptions = ");
    try out.appendSlice(allocator, dispatch_entry_descs_ref);
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

    const stats = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    try testing.expectEqual(@as(u32, 0), stats.word_count);
    try testing.expectEqual(false, stats.blob_present);
    // Slot 0 and effect 0 are reserved sentinels; the typevalue slot
    // count additionally includes every TypeValue reachable through
    // the boot-time dispatch table (builtin arithmetic, sequences,
    // strings, bitwise), so the floor is the sentinel plus those
    // entries rather than 1.
    try testing.expect(stats.typevalue_slot_count >= 1);
    try testing.expectEqual(@as(u32, 1), stats.stack_effect_count);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_header_t") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_v1") != null);

    try testing.expect(std.mem.indexOf(u8, out.items, ".format_version = 10") != null);
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

    _ = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

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
    const blob_ht_ptr = try arena.create(value_mod.HashTable);
    blob_ht_ptr.* = .{};
    const blob_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .hash = blob_ht_ptr } }, .line = 0, .column = 0 },
    });

    const zeta = try arena.create(Module);
    zeta.* = .{ .name = "zeta", .words = .{} };
    try zeta.words.put(arena, "alpha", .{ .action = .{ .compound = struct_instrs } });
    try zeta.words.put(arena, "beta", .{ .action = .{ .compound = struct_instrs } });

    const alpha = try arena.create(Module);
    alpha.* = .{ .name = "alpha", .words = .{} };
    try alpha.words.put(arena, "good", .{ .action = .{ .compound = struct_instrs } });
    try alpha.words.put(arena, "needs-blob", .{ .action = .{ .compound = blob_instrs } });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(cache_alloc, try cache_alloc.dupe(u8, "zeta"), .{ .module = zeta });
    try ctx.module_cache_value.map.put(cache_alloc, try cache_alloc.dupe(u8, "alpha"), .{ .module = alpha });
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

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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

    // The blob word (`needs-blob` pushes a hash) classifies as blob.
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

    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    const baseline = try baselineSlotCounts(&ctx);

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
        .{ .name = "x", .type_annotation = .{ .type = tv_a } },
        .{ .name = "y", .type_annotation = .{ .type = tv_a } }, // dedup target
    });
    const eff_a_outputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "z", .type_annotation = .{ .type = tv_b } },
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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    // Sentinel + alpha + beta + nested = 4 entries, but nested only
    // appears if reachable through registerParam recursion.
    try testing.expectEqual(@as(u32, 4), stats.stack_effect_count);
    // tv_a and tv_b add two slots on top of the baseline that the
    // boot-time dispatch widening contributes.
    try testing.expectEqual(baseline.typevalue_slot_count + 2, stats.typevalue_slot_count);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_stack_effects_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "color") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "shape") != null);

    // Sentinel at index 0.
    try testing.expect(std.mem.indexOf(u8, out.items, "{ NULL, 0, NULL, 0 }") != null);

    // Header references the populated tables.
    try testing.expect(std.mem.indexOf(u8, out.items, ".stack_effects = onez_image_stack_effects_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".stack_effect_count = 4") != null);

    // The nested-quotation param should reference an effect index >= 1.
    try testing.expect(std.mem.indexOf(u8, out.items, ".has_quotation_effect = 1") != null);

    // Type-annotated params carry kind 1 with a 1-based slot; a kind-1
    // row with slot 0 would mean the annotation lost its slot lookup.
    try testing.expect(std.mem.indexOf(u8, out.items, ".annotation_kind = 1") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".annotation_kind = 1, .has_quotation_effect = 0, ._reserved = 0, .annotation_slot = 0,") == null);

    // Dedup is implied by the slot-count check above (baseline + 2);
    // tv_a appearing twice in the inputs would push the count to
    // baseline + 3 if it were not shared.
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

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_v1") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_modules_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_words_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typevalue_slots") != null);
}

test "emitImageC: type_val word writes typevalue_slot and reserves a slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();
    const baseline = try baselineSlotCounts(&ctx);

    const desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{ .exact = true });
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "color", .descriptor = desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "color", .{ .action = .{ .compound = instrs } });
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    try testing.expectEqual(false, stats.blob_present);
    try testing.expectEqual(baseline.typevalue_slot_count + 1, stats.typevalue_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typevalues_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_typedescriptors_storage") != null);
    // The color TypeValue's slot is non-zero on the word's row -- a zero
    // slot means the word does not publish a TypeValue.
    try testing.expect(std.mem.indexOf(u8, out.items, ".typevalue_slot = 0u") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "color") != null);
}

test "emitImageC: same TypeValue across multiple words shares one slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();
    const baseline = try baselineSlotCounts(&ctx);

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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    // Three words share one TypeValue slot; the count grows by exactly
    // one over the baseline.
    try testing.expectEqual(baseline.typevalue_slot_count + 1, stats.typevalue_slot_count);

    // The per-manifest first-`.type_val` scan runs before the broader
    // dispatch widening, so color is the first non-sentinel slot
    // interned: index 1. Each of the three words writes that slot.
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

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    const baseline = try baselineSlotCounts(&ctx);

    // One TypeValue referenced by both a stack-effect param and a
    // word's body. The slot pool should collapse it to a single entry;
    // both sites read the same slot.
    const desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "color", .descriptor = desc };

    const eff_inputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "x", .type_annotation = .{ .type = tv } },
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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    // Baseline + 1 TV (color), regardless of the two reference sites.
    try testing.expectEqual(baseline.typevalue_slot_count + 1, stats.typevalue_slot_count);
}

test "collectDescriptorCrossRefs interns struct field_types into the slot table" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();
    const baseline = try baselineSlotCounts(&ctx);

    // Two field-type TypeValues that are NOT pushed by any module-private
    // word. They should still land in the slot table by virtue of being
    // descriptor cross-references on a struct TypeValue that is pushed.
    const tv_fix = try arena.create(value_mod.TypeValue);
    tv_fix.* = .{ .name = "fixnum", .descriptor = null };
    const tv_str = try arena.create(value_mod.TypeValue);
    tv_str.* = .{ .name = "string", .descriptor = null };

    const fields = try arena.dupe([]const u8, &.{ "x", "y" });
    const field_types = try arena.alloc(?value_mod.ConstraintCombinator.Element, 2);
    field_types[0] = .{ .type = tv_fix };
    field_types[1] = .{ .type = tv_str };
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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    // Baseline + (point, fixnum, string). The two field types were
    // collected by the descriptor cross-ref walk even though no word
    // pushes them.
    try testing.expectEqual(baseline.typevalue_slot_count + 3, stats.typevalue_slot_count);
}

test "collectDescriptorCrossRefs interns enum variant inner_types" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();
    const baseline = try baselineSlotCounts(&ctx);

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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    // Baseline + (option, unit, string).
    try testing.expectEqual(baseline.typevalue_slot_count + 3, stats.typevalue_slot_count);
}

test "collectDescriptorCrossRefs reaches transitively through multiple descriptors" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();
    const baseline = try baselineSlotCounts(&ctx);

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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    // Baseline + (A, B, C). Transitive walk reaches C through B's
    // descriptor even though no word pushes B or C directly.
    try testing.expectEqual(baseline.typevalue_slot_count + 3, stats.typevalue_slot_count);
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
    const field_types = try arena.alloc(?value_mod.ConstraintCombinator.Element, 1);
    field_types[0] = .{ .type = tv_fix };
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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    const st_field_types = try arena.alloc(?value_mod.ConstraintCombinator.Element, 1);
    st_field_types[0] = .{ .type = tv_int };
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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    const baseline = try baselineSlotCounts(&ctx);

    const tv_int = try arena.create(value_mod.TypeValue);
    tv_int.* = .{ .name = "int", .descriptor = null };

    const st_fields = try arena.dupe([]const u8, &.{"n"});
    const st_field_types = try arena.alloc(?value_mod.ConstraintCombinator.Element, 1);
    st_field_types[0] = .{ .type = tv_int };
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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    // Baseline + (wrapper, int). The StructType "wrapper-inner" is
    // not in the TypeValue slot table; its field types intern back.
    try testing.expectEqual(baseline.typevalue_slot_count + 2, stats.typevalue_slot_count);
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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

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

test "emitImageC: generator-provenanced word emits interpreter-run body bytecode" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // Generator-emitted words (struct constructors, getters, predicates)
    // push a slot-encodable type-carrier literal and call a native. Their
    // body is serialized through the image serializer so an interpreted
    // quotation calling them runs the real instructions instead of a
    // no-op. A plain scalar literal stands in for the type-carrier here;
    // it serializes by value, exercising the provenance-routes-to-image
    // path without setting up a full StructType slot table.
    const body = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
        .{ .op = .{ .call_word = "native.virtual-type-predicate" }, .line = 0, .column = 0 },
    });
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "color?", .{
        .action = .{ .compound = body },
        .provenance = .{ .generator = "virtual", .parent = "color", .role = "predicate" },
    });
    {
        const cache_alloc_demo = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc_demo, try cache_alloc_demo.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_w_0_body[]") != null);
}

const dispatch_mod = @import("dispatch.zig");

/// Push a top-level WordDefinition into ctx's import frame so its body
/// participates in the seed walk without entering the manifest. Useful
/// for tests that need to exercise literal-interning side effects
/// without forcing the body through the bytecode encoder, which does
/// not yet support every value-carrying variant.
fn putTopLevelWord(
    ctx: *Context,
    name: []const u8,
    instrs: []const Instruction,
) !void {
    if (ctx.import_frame_index == null) {
        try ctx.local_frames.append(ctx.allocator, .{});
        ctx.import_frame_index = ctx.local_frames.items.len - 1;
    }
    const frame = &ctx.local_frames.items[ctx.import_frame_index.?];
    try frame.put(ctx.allocator, name, .{
        .name = name,
        .action = .{ .compound = instrs },
    });
}

/// Run emitImageC against ctx with an empty manifest to discover the
/// slot table baseline. Built-in TypeValues registered through the
/// native dispatch table contribute to this baseline; tests use it as
/// a starting point when verifying that their fixtures add the
/// expected number of new slots.
fn baselineSlotCounts(ctx: *Context) !ImageEmissionStats {
    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    return try emitImageC(&out, testing.allocator, ctx, empty, &lookup, .{});
}

test "emitImageC: struct_type literal in top-level body interns into struct plans" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const st = try arena.create(value_mod.StructType);
    st.* = .{
        .name = "point",
        .fields = &.{},
        .field_types = &.{},
    };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .struct_type = st } }, .line = 0, .column = 0 },
    });
    try putTopLevelWord(&ctx, "make-point", instrs);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_struct_types_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_st_0_name[] = \"point\"") != null);
}

test "emitImageC: tagged literal interns tag's TypeValue and recurses into inner" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();
    const baseline = try baselineSlotCounts(&ctx);

    const inner_desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const inner_tv = try arena.create(value_mod.TypeValue);
    inner_tv.* = .{ .name = "inner-color", .descriptor = inner_desc };

    const outer_desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const outer_tv = try arena.create(value_mod.TypeValue);
    outer_tv.* = .{ .name = "outer-color", .descriptor = outer_desc };

    const outer_virtual = try arena.create(value_mod.VirtualType);
    outer_virtual.* = .{
        .name = "outer-color",
        .inner_type = "fixnum",
        .type_val = outer_tv,
    };

    const inner_value = try arena.create(value_mod.Value);
    inner_value.* = .{ .type_val = inner_tv };

    const instrs = try arena.dupe(Instruction, &.{
        .{
            .op = .{
                .push_literal = .{ .tagged = .{ .tag = outer_virtual, .inner = inner_value } },
            },
            .line = 0,
            .column = 0,
        },
    });
    try putTopLevelWord(&ctx, "wrap-color", instrs);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    // Baseline + outer + inner.
    try testing.expectEqual(baseline.typevalue_slot_count + 2, stats.typevalue_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, "outer-color") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "inner-color") != null);
}

test "emitImageC: tagged literal reserves a slot and emits a description row" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const tag_desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const tag_tv = try arena.create(value_mod.TypeValue);
    tag_tv.* = .{ .name = "color:red", .descriptor = tag_desc };

    const tag_virtual = try arena.create(value_mod.VirtualType);
    tag_virtual.* = .{ .name = "color:red", .inner_type = "symbol", .type_val = tag_tv };
    tag_tv.virtual_type = tag_virtual;

    const inner_value = try arena.create(value_mod.Value);
    inner_value.* = .{ .symbol = "red" };

    const instrs = try arena.dupe(Instruction, &.{
        .{
            .op = .{ .push_literal = .{ .tagged = .{ .tag = tag_virtual, .inner = inner_value } } },
            .line = 0,
            .column = 0,
        },
    });
    try putTopLevelWord(&ctx, "make-red", instrs);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    try testing.expectEqual(@as(u32, 1), stats.tagged_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_tagged_slots[1]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_tagged_descriptions_storage") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "color:red") != null);
}

test "emitImageC: repeated tagged literal with same (tag, inner) shares one slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const tag_desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const tag_tv = try arena.create(value_mod.TypeValue);
    tag_tv.* = .{ .name = "color:red", .descriptor = tag_desc };

    const tag_virtual = try arena.create(value_mod.VirtualType);
    tag_virtual.* = .{ .name = "color:red", .inner_type = "symbol", .type_val = tag_tv };
    tag_tv.virtual_type = tag_virtual;

    const inner_value = try arena.create(value_mod.Value);
    inner_value.* = .{ .symbol = "red" };

    const tagged_lit: value_mod.Value = .{ .tagged = .{ .tag = tag_virtual, .inner = inner_value } };
    const instrs_a = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = tagged_lit }, .line = 0, .column = 0 },
    });
    const instrs_b = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = tagged_lit }, .line = 0, .column = 0 },
    });
    try putTopLevelWord(&ctx, "red-a", instrs_a);
    try putTopLevelWord(&ctx, "red-b", instrs_b);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    try testing.expectEqual(@as(u32, 1), stats.tagged_slot_count);
}

test "emitImageC: parameter and marker literals create slot tables" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const param = try arena.create(value_mod.Parameter);
    param.* = .{ .name = "current-locale", .default_quotation = .{ .instructions = &.{} } };

    const marker = try arena.create(value_mod.Marker);
    marker.* = .{ .name = "deprecated" };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .parameter = param } }, .line = 0, .column = 0 },
        .{ .op = .{ .push_literal = .{ .marker = marker } }, .line = 0, .column = 0 },
    });
    try putTopLevelWord(&ctx, "demo-word", instrs);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    try testing.expectEqual(@as(u32, 1), stats.parameter_slot_count);
    try testing.expectEqual(@as(u32, 1), stats.marker_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_parameter_slots[1]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "parameter current-locale") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_marker_slots[1]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "marker deprecated") != null);
}

test "emitImageC: no parameter or marker literals emits no slot tables" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    try testing.expectEqual(@as(u32, 0), stats.marker_slot_count);
    try testing.expectEqual(@as(u32, 0), stats.parameter_slot_count);
    // Match the array-definition syntax (preceded by `*`) instead of
    // the bare symbol name; the typedef comments mention the slot
    // tables by name even when no array is emitted, so a plain
    // substring search would mis-trigger on those comments.
    try testing.expect(std.mem.indexOf(u8, out.items, "*onez_image_marker_slots[") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "*onez_image_parameter_slots[") == null);
}

test "emitImageC: nested quotation literal contributes type references" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "buried", .descriptor = desc };

    const inner_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    const outer_instrs = try arena.dupe(Instruction, &.{
        .{
            .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_instrs } } },
            .line = 0,
            .column = 0,
        },
    });
    try putTopLevelWord(&ctx, "outer-word", outer_instrs);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    try testing.expect(std.mem.indexOf(u8, out.items, "buried") != null);
}

test "emitImageC: top-level frame word body interns type literals" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();
    const baseline = try baselineSlotCounts(&ctx);

    const desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "user-defined", .descriptor = desc };

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 },
    });
    try putTopLevelWord(&ctx, "top-level-word", instrs);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    // Baseline + user-defined.
    try testing.expectEqual(baseline.typevalue_slot_count + 1, stats.typevalue_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, "user-defined") != null);
}

test "emitImageC: dispatch entry quotation body interns referenced types" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const ref_desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const ref_tv = try arena.create(value_mod.TypeValue);
    ref_tv.* = .{ .name = "method-body-ref", .descriptor = ref_desc };

    const key_desc = try value_mod.createTypeDescriptor(arena, .{ .virtual = .{} }, .{});
    const key_tv = try arena.create(value_mod.TypeValue);
    key_tv.* = .{ .name = "dispatch-key-type", .descriptor = key_desc };

    // Register the key TypeValue in a registry so the descriptor->TV
    // index can find it. The resource registry is convenient for tests
    // because it accepts arbitrary names without parsing.
    try ctx.resource_type_values.put(ctx.allocator, "dispatch-key-type", key_tv);

    const sentinel_desc = try value_mod.createSentinelTypeDescriptor(arena);
    const sentinel_tv = try arena.create(value_mod.TypeValue);
    sentinel_tv.* = .{ .name = "sentinel", .descriptor = sentinel_desc };

    const body_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .type_val = ref_tv } }, .line = 0, .column = 0 },
    });

    const key: dispatch_mod.DispatchKey = .{
        .dispatch_id = 1,
        .type_a = key_desc,
        .type_b = sentinel_desc,
    };
    const entry: dispatch_mod.DispatchEntry = .{
        .body = .{ .quotation = .{ .instructions = body_instrs } },
    };
    try ctx.dispatch.entries.put(ctx.allocator, key, entry);

    const empty: ImageManifest = .{
        .entries = &.{},
        .structural_count = 0,
        .blob_count = 0,
        .total_count = 0,
    };

    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageC(&out, testing.allocator, &ctx, empty, &lookup, .{});

    // Both the body-referenced and the key-referenced TypeValues must
    // land in the slot table.
    try testing.expect(std.mem.indexOf(u8, out.items, "method-body-ref") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "dispatch-key-type") != null);
}

test "emitImageC: protocol annotation interns descriptor and emits full description row" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // A protocol with one effect-carrying method and one bare method.
    const cmp_inputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "a" },
        .{ .name = "b" },
    });
    const cmp_outputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "r" },
    });
    const methods = [_]value_mod.Value{
        .{ .symbol = "cmp" },
        .{ .stack_effect = .{ .inputs = cmp_inputs, .outputs = cmp_outputs } },
        .{ .symbol = "show" },
    };
    const pd = try ctx.createProtocolDescriptor("orderly", &methods);

    // A word whose stack effect carries the protocol bound. The
    // collection walk reaches the descriptor through registerParam.
    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    });
    const eff_inputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "x", .type_annotation = .{ .protocol = pd } },
    });
    const eff_outputs = try arena.dupe(StackEffectParam, &.{});
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "bounded", .{
        .action = .{ .compound = instrs },
        .stack_effect = .{ .inputs = eff_inputs, .outputs = eff_outputs },
    });
    {
        const cache_alloc = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc, try cache_alloc.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    try testing.expectEqual(@as(u32, 1), stats.protocoldescriptor_slot_count);
    // Sentinel + the word's effect + the cmp method's effect.
    try testing.expectEqual(@as(u32, 3), stats.stack_effect_count);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_protocoldescriptor_slots[1]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_pd_0_name[] = \"orderly\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_pd_0_m0_name[] = \"cmp\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_pd_0_m1_name[] = \"show\"") != null);

    // The method array: cmp carries the interned effect index, show none.
    try testing.expect(std.mem.indexOf(u8, out.items, ".name = onez_image_pd_0_m0_name, .name_len = 3, .stack_effect_idx = 2 }") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".name = onez_image_pd_0_m1_name, .name_len = 4, .stack_effect_idx = 0 }") != null);

    // The description row carries the full reconstruction surface.
    var row_buf: [128]u8 = undefined;
    const row = std.fmt.bufPrint(
        &row_buf,
        ".slot = 0, .protocol_id = {d}, .method_count = 2, .methods = onez_image_pd_0_methods",
        .{pd.protocol_id},
    ) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out.items, row) != null);

    try testing.expect(std.mem.indexOf(u8, out.items, ".protocoldescriptor_slot_count = 1") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".protocoldescriptor_descriptions = onez_image_protocoldescriptor_descriptions_storage") != null);

    // The bounded param row references the descriptor's slot with kind 2;
    // the cmp method's bare params carry kind 0.
    try testing.expect(std.mem.indexOf(u8, out.items, ".annotation_kind = 2, .has_quotation_effect = 0, ._reserved = 0, .annotation_slot = 0,") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".annotation_kind = 0") != null);
}

test "emitImageC: combinator annotation interns descriptors across all three element kinds" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // Two protocols and a TypeValue, the three element-leaf kinds.
    const pd = try ctx.createProtocolDescriptor("cmp-able", &.{.{ .symbol = "cmp" }});
    const pd2 = try ctx.createProtocolDescriptor("show-able", &.{.{ .symbol = "show" }});
    const tv_desc = try value_mod.createBuiltinTypeDescriptor(arena, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "smallint", .descriptor = tv_desc };

    // A nested intersection and an outer union referencing it, so the walk
    // exercises a kind-3 (nested combinator) element. Post-order interning
    // lands the nested combinator at slot 0 and the outer at slot 1.
    const inner_elems = try arena.dupe(value_mod.ConstraintCombinator.Element, &.{
        .{ .protocol = pd2 },
    });
    const inner = try ctx.createConstraintCombinator(.intersection, inner_elems);
    const outer_elems = try arena.dupe(value_mod.ConstraintCombinator.Element, &.{
        .{ .type = tv },
        .{ .protocol = pd },
        .{ .combinator = inner },
    });
    const outer = try ctx.createConstraintCombinator(.@"union", outer_elems);

    // A word whose stack effect carries the outer combinator bound.
    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    });
    const eff_inputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "x", .type_annotation = .{ .combination = outer } },
    });
    const eff_outputs = try arena.dupe(StackEffectParam, &.{});
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "bounded", .{
        .action = .{ .compound = instrs },
        .stack_effect = .{ .inputs = eff_inputs, .outputs = eff_outputs },
    });
    {
        const cache_alloc = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc, try cache_alloc.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    // Inner (slot 0) and outer (slot 1) -- plus the two protocols those
    // elements reference, interned post-order.
    try testing.expectEqual(@as(u32, 2), stats.constraintcombinator_slot_count);
    try testing.expectEqual(@as(u32, 2), stats.protocoldescriptor_slot_count);

    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_constraintcombinator_slots[2]") != null);

    // The outer's element array carries one row per leaf kind: a type leaf
    // (1-based typevalue slot), a protocol leaf (pd at protocol slot 0), and
    // a nested-combinator leaf (inner at combinator slot 0).
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_cc_1_elements[] = {") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "{ .kind = 1, .slot = ") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "{ .kind = 2, .slot = 0 }") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "{ .kind = 3, .slot = 0 }") != null);
    // The inner's element array carries its single protocol leaf (pd2 at
    // protocol slot 1).
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_cc_0_elements[] = {") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "{ .kind = 2, .slot = 1 }") != null);

    // The description rows: inner is an intersection (kind 0) of one element;
    // outer is a union (kind 1) of three elements. Both preserve combinator_id.
    var row_buf: [160]u8 = undefined;
    const inner_row = std.fmt.bufPrint(
        &row_buf,
        ".slot = 0, .combinator_id = {d}, .kind = 0, .element_count = 1, .elements = onez_image_cc_0_elements",
        .{inner.combinator_id},
    ) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out.items, inner_row) != null);
    var row_buf2: [160]u8 = undefined;
    const outer_row = std.fmt.bufPrint(
        &row_buf2,
        ".slot = 1, .combinator_id = {d}, .kind = 1, .element_count = 3, .elements = onez_image_cc_1_elements",
        .{outer.combinator_id},
    ) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out.items, outer_row) != null);

    try testing.expect(std.mem.indexOf(u8, out.items, ".constraintcombinator_slot_count = 2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".constraintcombinator_descriptions = onez_image_constraintcombinator_descriptions_storage") != null);

    // The bounded param row references the outer combinator's slot with kind 3.
    try testing.expect(std.mem.indexOf(u8, out.items, ".annotation_kind = 3, .has_quotation_effect = 0, ._reserved = 0, .annotation_slot = 1,") != null);
}

fn dispatchEntryTestNativeFn(_: *Context) anyerror!void {}

test "emitDispatchEntryTable: one row per reachable user quotation entry, types and module preserved" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const fixnum_tv = ctx.builtin_type_values.get("fixnum").?;
    const string_tv = ctx.builtin_type_values.get("string").?;
    const unary = ctx.dispatch_unary_sentinel.?.descriptor.?;

    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };

    // Distinct allocations so the two bodies have distinct pointers.
    const body_bin = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    });
    const body_un = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0, .column = 0 },
    });

    try ctx.registerDispatch(
        .{ .dispatch_id = 7, .type_a = fixnum_tv.descriptor.?, .type_b = string_tv.descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body_bin } }, .source_module = m },
        false,
    );
    try ctx.registerDispatch(
        .{ .dispatch_id = 7, .type_a = fixnum_tv.descriptor.?, .type_b = unary },
        .{ .body = .{ .quotation = .{ .instructions = body_un } }, .source_module = m },
        false,
    );
    // A native entry on a reached generic must be excluded: native dispatch
    // is already present at runtime and a function pointer is not serializable.
    try ctx.registerDispatch(
        .{ .dispatch_id = 9, .type_a = fixnum_tv.descriptor.?, .type_b = unary },
        .{ .body = .{ .native_fn = dispatchEntryTestNativeFn } },
        false,
    );

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var qmap: std.AutoHashMapUnmanaged(usize, u32) = .{};
    defer qmap.deinit(testing.allocator);
    try qmap.put(testing.allocator, @intFromPtr(body_bin.ptr), 0);
    try qmap.put(testing.allocator, @intFromPtr(body_un.ptr), 1);

    var collection = try collectImageSlots(testing.allocator, &ctx, manifest, .{}, &.{});
    defer collection.deinit();

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageCFromCollection(&out, testing.allocator, &ctx, manifest, &lookup, &collection, .{}, &qmap, null, null);

    try testing.expectEqual(@as(u32, 2), stats.dispatch_entry_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_dispatch_entry_descriptions_storage[] = {") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".dispatch_entry_slot_count = 2") != null);
    // dispatch_id consistency invariant: the emitted rows carry the freeze-time
    // dispatch_id (7) verbatim, the same id a compiled call site bakes.
    try testing.expect(std.mem.indexOf(u8, out.items, ".dispatch_id = 7,") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".dispatch_id = 6,") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".dispatch_entry_descriptions = onez_image_dispatch_entry_descriptions_storage") != null);

    // The binary row resolves both key types to the same typevalue slots the
    // slot table assigns those exact TypeValue pointers (pointer identity).
    const a_slot = collection.effect_table.type_slot_index.get(fixnum_tv).?;
    const b_slot = collection.effect_table.type_slot_index.get(string_tv).?;
    var rb: [224]u8 = undefined;
    const bin_row = std.fmt.bufPrint(
        &rb,
        ".dispatch_id = 7, .type_a_slot = {d}, .type_b_slot = {d}, .quotation_id = 0, .module_name = \"demo\", .module_name_len = 4",
        .{ a_slot, b_slot },
    ) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out.items, bin_row) != null);

    // The unary row carries the reserved unary sentinel in type_b.
    var ru: [224]u8 = undefined;
    const un_row = std.fmt.bufPrint(
        &ru,
        ".dispatch_id = 7, .type_a_slot = {d}, .type_b_slot = 4294967295, .quotation_id = 1, .module_name = \"demo\", .module_name_len = 4",
        .{a_slot},
    ) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out.items, un_row) != null);

    // The native entry on dispatch_id 9 produces no row.
    try testing.expect(std.mem.indexOf(u8, out.items, ".dispatch_id = 9") == null);

    // With no interpreter-run-bodies map, compiled rows carry no body bytecode.
    try testing.expect(std.mem.indexOf(u8, out.items, ".body_bytecode = NULL, .body_bytecode_len = 0") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_dispatch_q_0_body[]") == null);
}

test "emitDispatchEntryTable: an interpreter-run method body carries its bytecode" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const fixnum_tv = ctx.builtin_type_values.get("fixnum").?;
    const unary = ctx.dispatch_unary_sentinel.?.descriptor.?;

    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };

    const body = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0, .column = 0 },
    });
    try ctx.registerDispatch(
        .{ .dispatch_id = 5, .type_a = fixnum_tv.descriptor.?, .type_b = unary },
        .{ .body = .{ .quotation = .{ .instructions = body } }, .source_module = m },
        false,
    );

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var qmap: std.AutoHashMapUnmanaged(usize, u32) = .{};
    defer qmap.deinit(testing.allocator);
    try qmap.put(testing.allocator, @intFromPtr(body.ptr), 0);

    // The body did not compile, so it appears in the interpreter-run-bodies map
    // keyed by quotation_id with its serialized bytecode.
    var run_bodies: std.AutoHashMapUnmanaged(u32, []const u8) = .{};
    defer run_bodies.deinit(testing.allocator);
    const bytes = [_]u8{ 1, 2, 3 };
    try run_bodies.put(testing.allocator, 0, &bytes);

    var collection = try collectImageSlots(testing.allocator, &ctx, manifest, .{}, &.{});
    defer collection.deinit();

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageCFromCollection(&out, testing.allocator, &ctx, manifest, &lookup, &collection, .{}, &qmap, null, &run_bodies);

    try testing.expectEqual(@as(u32, 1), stats.dispatch_entry_slot_count);
    // The per-row bytecode array is emitted and the row references it.
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_dispatch_q_0_body[] = {1,2,3}") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".body_bytecode = onez_image_dispatch_q_0_body, .body_bytecode_len = 3") != null);
}

test "emitDispatchEntryTable: a freeze-unreached entry body emits an interpreter-run row" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const fixnum_tv = ctx.builtin_type_values.get("fixnum").?;
    const unary = ctx.dispatch_unary_sentinel.?.descriptor.?;

    const body = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    });
    try ctx.registerDispatch(
        .{ .dispatch_id = 3, .type_a = fixnum_tv.descriptor.?, .type_b = unary },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    // The body pointer is absent from the manifest, so the freeze never
    // compiled this method. Its body is serialized fresh and emitted as an
    // interpreter-run row carrying the sentinel quotation_id, so a method
    // reached only through an interpreted quotation still dispatches.
    var qmap: std.AutoHashMapUnmanaged(usize, u32) = .{};
    defer qmap.deinit(testing.allocator);

    var collection = try collectImageSlots(testing.allocator, &ctx, manifest, .{}, &.{});
    defer collection.deinit();

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageCFromCollection(&out, testing.allocator, &ctx, manifest, &lookup, &collection, .{}, &qmap, null, null);

    try testing.expectEqual(@as(u32, 1), stats.dispatch_entry_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, "onez_image_dispatch_q_0_body[] = {") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".body_bytecode = onez_image_dispatch_q_0_body") != null);
    var qid_buf: [64]u8 = undefined;
    const qid_needle = std.fmt.bufPrint(&qid_buf, ".quotation_id = {d}", .{dispatch_interp_quotation_id_sentinel}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out.items, qid_needle) != null);
}

test "emitDispatchEntryTable: wildcard type_a emits the reserved ANY sentinel" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const any = ctx.dispatch_any_sentinel.?.descriptor.?;
    const unary = ctx.dispatch_unary_sentinel.?.descriptor.?;

    const body = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    });
    try ctx.registerDispatch(
        .{ .dispatch_id = 4, .type_a = any, .type_b = unary },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var qmap: std.AutoHashMapUnmanaged(usize, u32) = .{};
    defer qmap.deinit(testing.allocator);
    try qmap.put(testing.allocator, @intFromPtr(body.ptr), 0);

    var collection = try collectImageSlots(testing.allocator, &ctx, manifest, .{}, &.{});
    defer collection.deinit();

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageCFromCollection(&out, testing.allocator, &ctx, manifest, &lookup, &collection, .{}, &qmap, null, null);

    try testing.expectEqual(@as(u32, 1), stats.dispatch_entry_slot_count);
    // type_a = ANY (4294967294), type_b = UNARY (4294967295).
    try testing.expect(std.mem.indexOf(u8, out.items, ".dispatch_id = 4, .type_a_slot = 4294967294, .type_b_slot = 4294967295, .quotation_id = 0, .module_name = NULL, .module_name_len = 0") != null);
}

test "emitDispatchEntryTable: rows are emitted in deterministic sorted order" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const fixnum_tv = ctx.builtin_type_values.get("fixnum").?;
    const unary = ctx.dispatch_unary_sentinel.?.descriptor.?;

    var qmap: std.AutoHashMapUnmanaged(usize, u32) = .{};
    defer qmap.deinit(testing.allocator);

    // Register out of order (5, 3, 4); the emitted rows must sort by dispatch_id.
    const order = [_]u32{ 5, 3, 4 };
    for (order, 0..) |did, i| {
        const body = try arena.dupe(Instruction, &.{
            .{ .op = .{ .push_literal = .{ .fixnum = @intCast(did) } }, .line = 0, .column = 0 },
        });
        try ctx.registerDispatch(
            .{ .dispatch_id = did, .type_a = fixnum_tv.descriptor.?, .type_b = unary },
            .{ .body = .{ .quotation = .{ .instructions = body } } },
            false,
        );
        try qmap.put(testing.allocator, @intFromPtr(body.ptr), @intCast(i));
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);

    var collection = try collectImageSlots(testing.allocator, &ctx, manifest, .{}, &.{});
    defer collection.deinit();

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    _ = try emitImageCFromCollection(&out, testing.allocator, &ctx, manifest, &lookup, &collection, .{}, &qmap, null, null);

    const pos3 = std.mem.indexOf(u8, out.items, ".dispatch_id = 3, ").?;
    const pos4 = std.mem.indexOf(u8, out.items, ".dispatch_id = 4, ").?;
    const pos5 = std.mem.indexOf(u8, out.items, ".dispatch_id = 5, ").?;
    try testing.expect(pos3 < pos4);
    try testing.expect(pos4 < pos5);
}

test "registerProtocolMethodEffects reaches protocols and TypeValues through method effects" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();
    const baseline = try baselineSlotCounts(&ctx);

    // Protocol Q, reachable only through P's method-effect annotation.
    const q = try ctx.createProtocolDescriptor("quaffable", &.{.{ .symbol = "quaff" }});

    // A TypeValue reachable only through P's method-effect annotation.
    const desc = try value_mod.createBuiltinTypeDescriptor(arena, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "goblet", .descriptor = desc };

    const sip_inputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "x", .type_annotation = .{ .protocol = q } },
        .{ .name = "y", .type_annotation = .{ .type = tv } },
    });
    const sip_outputs = try arena.dupe(StackEffectParam, &.{});
    const p_methods = [_]value_mod.Value{
        .{ .symbol = "sip" },
        .{ .stack_effect = .{ .inputs = sip_inputs, .outputs = sip_outputs } },
    };
    const p = try ctx.createProtocolDescriptor("sippable", &p_methods);

    // Only P is annotated on a word; Q and the TypeValue must arrive
    // through the fixed-point method-effect walk.
    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    });
    const eff_inputs = try arena.dupe(StackEffectParam, &.{
        .{ .name = "x", .type_annotation = .{ .protocol = p } },
    });
    const eff_outputs = try arena.dupe(StackEffectParam, &.{});
    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "bounded", .{
        .action = .{ .compound = instrs },
        .stack_effect = .{ .inputs = eff_inputs, .outputs = eff_outputs },
    });
    {
        const cache_alloc = ctx.module_cache_value.header.allocator;
        try ctx.module_cache_value.map.put(cache_alloc, try cache_alloc.dupe(u8, "demo"), .{ .module = m });
    }

    var manifest = try aot_image.buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    var lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer lookup.deinit(testing.allocator);
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    const stats = try emitImageC(&out, testing.allocator, &ctx, manifest, &lookup, .{});

    try testing.expectEqual(@as(u32, 2), stats.protocoldescriptor_slot_count);
    try testing.expectEqual(baseline.typevalue_slot_count + 1, stats.typevalue_slot_count);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"sippable\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"quaffable\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"goblet\"") != null);
}
