//! Runtime-image loader: rehydrates the AOT runtime image into a Context.
//!
//! Companion to `aot_image_emit.zig`. Walks the embedded `onez_image_v1`
//! header at startup, decodes the static C data tables (typevalues,
//! typedescriptors, struct types, modules, words, stack effects, markers)
//! into runtime Module/ModuleWord/TypeValue instances, and patches the
//! shared TypeValue slot table so PIC dispatch and stack-effect
//! annotations resolve to live pointers.
//!
//! The struct layouts here MUST match the C declarations emitted by
//! `aot_image_emit.emitTypeDeclarations`. Field order, types, and
//! padding are all part of the contract; drift on either side breaks
//! the loader silently.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const stack_effect_mod = @import("stack_effect.zig");
const aot_image_emit = @import("aot_image_emit.zig");
const instruction_bytecode = @import("instruction_bytecode.zig");
const container_backing = @import("container_backing.zig");
const Context = @import("context.zig").Context;
const dictionary_mod = @import("dictionary.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const markers_mod = @import("primitives/markers.zig");

/// Errors the loader can surface. The C-side caller maps these to
/// `ONEZ_ERR_LOAD_FAILED` and uses `ctx.error_details` for the
/// human-readable message.
pub const LoaderError = error{
    UnsupportedFormat,
    BadSlotIndex,
    BadWordIndex,
    BadStackEffectIndex,
    BadTypeKind,
    BadStructTypeIndex,
    OutOfMemory,
};

/// `classification` field values from `onez_image_word`.
const classification_structural: u8 = 0;
const classification_blob: u8 = 1;

// -- C-layout struct mirrors --------------------------------------------

pub const Module = extern struct {
    name: [*]const u8,
    name_len: u32,
    word_start_idx: u32,
    word_count: u32,
};

pub const Marker = extern struct {
    name: [*]const u8,
    name_len: u32,
};

pub const StackEffectParam = extern struct {
    name: [*]const u8,
    name_len: u32,
    is_row_variable: u8,
    has_type_annotation: u8,
    has_quotation_effect: u8,
    _pad: u8,
    typevalue_slot: u32,
    quotation_effect_idx: u32,
};

pub const StackEffect = extern struct {
    inputs: ?[*]const StackEffectParam,
    input_count: u32,
    outputs: ?[*]const StackEffectParam,
    output_count: u32,
};

pub const Word = extern struct {
    name: [*]const u8,
    name_len: u32,
    word_id: u32,
    module_idx: u32,
    classification: u8,
    blob_reason: u8,
    flags: u8,
    _reserved: u8,
    input_count: u8,
    output_count: u8,
    _pad: u16,
    stack_effect_idx: u32,
    markers: ?[*]const *const Marker,
    marker_count: u32,
    body_bytecode: ?[*]const u8,
    body_bytecode_len: u32,
    typevalue_slot: u32,
    doc: ?[*]const u8,
    doc_len: u32,
    source_file: ?[*]const u8,
    source_file_len: u32,
    source_line: u32,
    source_column: u32,
    provenance_generator: ?[*]const u8,
    provenance_generator_len: u32,
    provenance_parent: ?[*]const u8,
    provenance_parent_len: u32,
    provenance_role: ?[*]const u8,
    provenance_role_len: u32,
};

/// Zig mirror of the C `onez_image_enum_variant_t` row. The loader walks
/// these to materialize `value_mod.Variant` records inside an
/// `EnumData.variants` slice; the variant's `type_slot` indexes the
/// runtime slot table (0 = no inner type).
pub const EnumVariant = extern struct {
    name: [*]const u8,
    name_len: u32,
    type_slot: u32,
};

/// Zig mirror of `onez_image_struct_type_t`. One row per
/// `StructType` referenced by a struct-backed virtual type's
/// `anon_struct`. Allocated separately from `TypeValue`s because
/// the anonymous struct is not itself a first-class TypeValue.
pub const StructType = extern struct {
    name: [*]const u8,
    name_len: u32,
    field_names: ?[*]const [*]const u8,
    field_name_lens: ?[*]const u32,
    field_count: u32,
    field_type_slots: ?[*]const u32,
    field_type_count: u32,
};

/// Zig mirror of `onez_image_typedescriptor_t`. Layout must stay in
/// lockstep with the C struct emitted in `aot_image_emit.emitTypeDeclarations`.
/// Fields not relevant to a given `kind` are zero-initialized at emit
/// time and the loader ignores them.
pub const TypeDescriptor = extern struct {
    numeric: u8,
    exact: u8,
    integer: u8,
    mutable: u8,
    kind: u8,
    _pad: [3]u8,
    field_names: ?[*]const [*]const u8,
    field_name_lens: ?[*]const u32,
    field_count: u32,
    field_type_slots: ?[*]const u32,
    field_type_count: u32,
    inner_type_slot: u32,
    anon_struct_idx: u32,
    type_param_slots: ?[*]const u32,
    type_param_count: u32,
    parent_type_slot: u32,
    variants: ?[*]const EnumVariant,
    variant_count: u32,
    resource_kind: ?[*]const u8,
    resource_kind_len: u32,
    ffi_layout: u64,
};

/// Zig mirror of `onez_image_typevalue_t`. One row per slot in
/// `onez_image_typevalue_slots[]`; `slot` matches the row's index in
/// the slot table and is used to anchor the loader's slot-table
/// patching pass.
pub const TypeValueRow = extern struct {
    name: [*]const u8,
    name_len: u32,
    slot: u32,
    descriptor: ?*const TypeDescriptor,
    member_type_slots: ?[*]const u32,
    member_type_count: u32,
};

/// Sentinel for absent anon_struct in `TypeDescriptor.anon_struct_idx`.
pub const anon_struct_absent: u32 = 0xFFFFFFFF;

/// Zig mirror of `onez_image_marker_description_t`. One row per slot in
/// `onez_image_marker_slots[]`; the loader resolves the name to either a
/// well-known marker singleton or a freshly-allocated `*Marker`, then
/// patches `onez_image_marker_slots[slot]` with the resolved pointer.
pub const MarkerDescription = extern struct {
    name: [*]const u8,
    name_len: u32,
    slot: u32,
};

/// Zig mirror of `onez_image_parameter_description_t`. One row per slot
/// in `onez_image_parameter_slots[]`. The loader deserializes the
/// default-quotation bytecode, allocates a `*Parameter`, and patches the
/// matching slot.
pub const ParameterDescription = extern struct {
    name: [*]const u8,
    name_len: u32,
    slot: u32,
    default_quotation_bytecode: ?[*]const u8,
    default_quotation_bytecode_len: u32,
};

/// Zig mirror of `onez_image_tagged_description_t`. One row per slot in
/// `onez_image_tagged_slots[]`. The loader recovers the tag's
/// `*const VirtualType` through `tag_typevalue_slot` (reading
/// `typevalues[slot].virtual_type`), deserializes the inner Value via
/// `instruction_bytecode.deserializeValueAtForImage`, allocates a
/// runtime `*const Value` carrying `.tagged`, and patches the matching
/// slot.
pub const TaggedDescription = extern struct {
    name: [*]const u8,
    name_len: u32,
    slot: u32,
    tag_typevalue_slot: u32,
    inner_bytecode: ?[*]const u8,
    inner_bytecode_len: u32,
};

/// Zig mirror of `onez_image_mutable_map_description_t`. One row per
/// slot in `onez_image_mutable_map_slots[]`. The loader allocates a
/// fresh `*MutableMap`, decodes the entries via
/// `instruction_bytecode.deserializeValueAtForImage`, populates the
/// map, and patches the slot.
pub const MutableMapDescription = extern struct {
    slot: u32,
    entries_bytecode: ?[*]const u8,
    entries_bytecode_len: u32,
};

pub const Header = extern struct {
    format_version: u32,
    module_count: u32,
    word_count: u32,
    marker_pool_count: u32,
    typevalue_slot_count: u32,
    stack_effect_count: u32,
    typevalue_count: u32,
    struct_type_count: u32,
    marker_slot_count: u32,
    parameter_slot_count: u32,
    tagged_slot_count: u32,
    mutable_map_slot_count: u32,
    modules: ?[*]const Module,
    words: ?[*]const Word,
    markers: ?[*]const Marker,
    stack_effects: ?[*]const StackEffect,
    typevalues: ?[*]const TypeValueRow,
    typedescriptors: ?[*]const TypeDescriptor,
    struct_types: ?[*]const StructType,
    marker_descriptions: ?[*]const MarkerDescription,
    parameter_descriptions: ?[*]const ParameterDescription,
    tagged_descriptions: ?[*]const TaggedDescription,
    mutable_map_descriptions: ?[*]const MutableMapDescription,
};

/// Slot table type matching the C declaration:
///   const struct onez_typevalue *onez_image_typevalue_slots[N]
/// `const` qualifies the pointee (an opaque TypeValue), not the array
/// elements -- the elements are writable, which is what lets the loader
/// patch them at startup.
pub const SlotTable = [*]?*const value_mod.TypeValue;

/// Slot table for StructType pointers, mirroring `SlotTable` for the
/// runtime `*StructType` allocations the loader produces from
/// `onez_image_struct_types_storage[]`. The C declaration is:
///   struct onez_struct_type *onez_image_struct_type_slots[N]
/// `struct onez_struct_type` is an opaque type at the C level; the
/// loader patches each slot with the runtime `*value_mod.StructType`
/// address allocated in `populateTypeValueSlots` Pass 1.
pub const StructTypeSlotTable = [*]?*value_mod.StructType;

/// Slot table for Marker pointers. The runtime allocates markers as
/// part of `populateModulesAndWords` and patches each slot with the
/// canonical runtime pointer. `null` when no marker slots were
/// emitted.
pub const MarkerSlotTable = [*]?*value_mod.Marker;

/// Slot table for Parameter pointers. Parameter binding state is
/// mutable; the loader allocates the runtime Parameter row and
/// patches each slot accordingly.
pub const ParameterSlotTable = [*]?*value_mod.Parameter;

/// Slot table for `.tagged` Value pointers. Each entry is allocated on
/// the context arena by the loader: an inner Value plus a wrapping
/// Value carrying `.tagged = .{ .tag = vt, .inner = inner_ptr }`. The
/// codegen-side push helper reads through this slot table to recover
/// the freeze-time tagged identity at runtime.
pub const TaggedSlotTable = [*]?*const value_mod.Value;

/// Slot table for `.mutable_map` pointers. Each entry is allocated by
/// the loader via `MutableMap.create`; the entries are populated from
/// the matching description row's bytecode. The compiled-code helper
/// retains the pointer before pushing so the cache's strong reference
/// is preserved.
pub const MutableMapSlotTable = [*]?*value_mod.MutableMap;

/// All loader-populated slot tables, passed together so the
/// `loadIntoContext` signature stays compact as new tables land. Any
/// individual field may be null when its corresponding C symbol was
/// not emitted (zero-slot count).
pub const SlotTables = struct {
    typevalues: ?SlotTable = null,
    struct_types: ?StructTypeSlotTable = null,
    markers: ?MarkerSlotTable = null,
    parameters: ?ParameterSlotTable = null,
    tagged: ?TaggedSlotTable = null,
    mutable_maps: ?MutableMapSlotTable = null,
};

/// PIC snapshot relocation entry. Each entry says "rewrite this
/// pointer-sized slot in the snapshot to the runtime address of slot
/// `slot_index` from the TypeValue slot table after task 2 fills it".
///
/// 248.3 emission does not yet produce these; the type is declared
/// here so task 3 can exercise the patch contract via synthetic test
/// fixtures and a future emission can light it up without redesign.
pub const PicRelocation = extern struct {
    /// Pointer to the slot inside the PIC snapshot that needs the
    /// runtime address written into it. The slot is opaque
    /// (`?*const value_mod.TypeValue`); the loader writes the
    /// resolved pointer with no further interpretation.
    target: *?*const value_mod.TypeValue,
    /// Index into `onez_image_typevalue_slots` to read the runtime
    /// address from. Must be < `header.typevalue_slot_count`.
    slot_index: u32,
};

/// Optional PIC relocation table the loader walks after slot
/// population. Passing `null` skips the PIC pass.
pub const PicRelocationTable = struct {
    items: []const PicRelocation,
};

/// Public entry point. The runtime calls this once after the prelude
/// finishes loading, before any user code runs.
///
/// `slots` carries the TypeValue / StructType / Marker / Parameter
/// slot tables that codegen consults for slot-indexed literal pushes.
/// Any field may be null when its corresponding C symbol was not
/// emitted (zero-slot count).
pub fn loadIntoContext(
    ctx: *Context,
    header: *const Header,
    slots: SlotTables,
    pic_relocs: ?PicRelocationTable,
) LoaderError!void {
    if (header.format_version != aot_image_emit.format_version) {
        recordLoaderError(
            ctx,
            "runtime-image format version mismatch (binary={d} runtime={d})",
            .{ header.format_version, aot_image_emit.format_version },
        );
        return LoaderError.UnsupportedFormat;
    }

    ctx.runtime_image_loaded = true;
    try populateModulesAndWords(ctx, header);
    try populateTypeValueSlots(ctx, header, slots.typevalues, slots.struct_types);
    try populateMarkerSlots(ctx, header, slots.markers);
    try populateParameterSlots(ctx, header, slots.parameters);
    if (pic_relocs) |relocs| {
        try resolvePicRelocations(header, slots.typevalues, relocs);
    }

    // Cache slot-table pointers on the Context so the compiled-code
    // helpers (`jitPushTypeValueSlot`, `jitPushStructTypeSlot`, etc.)
    // can resolve slot-indexed literal pushes with a direct table
    // lookup rather than a runtime dictionary search.
    ctx.image_typevalue_slots = slots.typevalues;
    ctx.image_typevalue_slot_count = header.typevalue_slot_count;
    ctx.image_struct_type_slots = slots.struct_types;
    ctx.image_struct_type_slot_count = header.struct_type_count;
    ctx.image_marker_slots = slots.markers;
    ctx.image_marker_slot_count = header.marker_slot_count;
    ctx.image_parameter_slots = slots.parameters;
    ctx.image_parameter_slot_count = header.parameter_slot_count;
    ctx.image_tagged_slots = slots.tagged;
    ctx.image_tagged_slot_count = header.tagged_slot_count;
    ctx.image_mutable_map_slots = slots.mutable_maps;
    ctx.image_mutable_map_slot_count = header.mutable_map_slot_count;

    // Mutable_map slots populate before tagged slots so a tagged
    // inner value carrying a `.mutable_map` resolves correctly.
    try populateMutableMapSlots(ctx, header, slots.mutable_maps);

    // Tagged slot population runs last because each row's inner
    // bytecode may reference the typevalue, struct-type, marker,
    // parameter, or mutable_map slot tables (recursive `.tagged.inner`
    // routes through `deserializeValueAtForImage`), so those tables
    // must be patched first.
    try populateTaggedSlots(ctx, header, slots.tagged);
}

// -- Module + word population ------------------------------------------

fn populateModulesAndWords(ctx: *Context, header: *const Header) LoaderError!void {
    if (header.module_count == 0) return;
    const modules = header.modules orelse return;
    const words = header.words orelse return;
    const arena = ctx.quotationAllocator();

    var module_i: u32 = 0;
    while (module_i < header.module_count) : (module_i += 1) {
        const m = modules[module_i];
        const name = nameSlice(m.name, m.name_len);

        const module_ptr = arena.create(value_mod.Module) catch return LoaderError.OutOfMemory;
        module_ptr.* = .{
            .name = name,
            .words = .{},
        };

        var word_i: u32 = 0;
        while (word_i < m.word_count) : (word_i += 1) {
            const word_idx = m.word_start_idx + word_i;
            if (word_idx >= header.word_count) return LoaderError.BadWordIndex;
            const w = words[word_idx];
            const word_name = nameSlice(w.name, w.name_len);

            const markers_slice = try buildMarkerSlice(arena, w);
            const stack_effect = try decodeStackEffect(arena, header, w.stack_effect_idx);
            const body = try decodeWordBody(arena, w);
            const diag = decodeDiagnosticMetadata(w);

            // Treat `aot_image_emit.word_id_sentinel` (0xFFFFFFFFu) as
            // "no AOT dispatch entry" -- the codegen marker for words
            // that didn't make it into `jit_dispatch`. Real word_ids
            // pass through unchanged.
            const word_id_opt: ?u32 = if (w.word_id == aot_image_emit.word_id_sentinel)
                null
            else
                w.word_id;

            const mw = value_mod.ModuleWord{
                .stack_effect = stack_effect,
                .markers = markers_slice,
                .source_module = module_ptr,
                .doc = diag.doc,
                .source_file = diag.source_file,
                .source_line = diag.source_line,
                .source_column = diag.source_column,
                .provenance = diag.provenance,
                .word_id = word_id_opt,
                .action = .{ .compound = body },
            };
            module_ptr.words.put(arena, word_name, mw) catch return LoaderError.OutOfMemory;
        }

        const cache_alloc = ctx.module_cache_value.header.allocator;
        const name_owned = cache_alloc.dupe(u8, name) catch return LoaderError.OutOfMemory;
        ctx.module_cache_value.map.put(cache_alloc, name_owned, .{ .module = module_ptr }) catch
            return LoaderError.OutOfMemory;
    }
}

/// Decode a word's body bytecode into a runtime `[]Instruction` slice.
/// Words emitted with no body bytecode keep the empty-body stub; the
/// blob loader rewrites that stub for `type_val` blob entries
/// downstream. The decoder allocates instructions, names, and any
/// nested literal payloads through the arena, matching the lifetime of
/// every other loader allocation.
///
/// `instruction_bytecode.deserializeQuotationInstructions` collapses
/// both true OOM and malformed-buffer detections into
/// `error.OutOfMemory`. We surface that as `LoaderError.OutOfMemory`
/// here; if the decoder grows a separate format-error path later, this
/// catch can split apart without disturbing callers.
fn decodeWordBody(arena: Allocator, w: Word) LoaderError![]const value_mod.Instruction {
    if (w.body_bytecode == null or w.body_bytecode_len == 0) return &.{};
    const bytes = w.body_bytecode.?[0..w.body_bytecode_len];
    return instruction_bytecode.deserializeQuotationInstructions(bytes, arena) catch
        return LoaderError.OutOfMemory;
}

/// Decoded diagnostic metadata for one image word. Each field mirrors a
/// nullable counterpart on `ModuleWord`/`WordDefinition`, so the loader
/// can populate `>word-info`, `all-words`, and stack-trace renderers
/// directly from the static image without re-reading the source.
const DecodedDiagnostics = struct {
    doc: ?[]const u8,
    source_file: ?[]const u8,
    source_line: usize,
    source_column: usize,
    provenance: ?WordProvenance,
};

/// Decode the doc, source-location, and provenance fields from one
/// image word row. Strings are pointer-aliased into the image, not
/// copied; the image lives for the process lifetime, so the slices
/// share that lifetime with everything else the loader returns.
fn decodeDiagnosticMetadata(w: Word) DecodedDiagnostics {
    const doc_opt: ?[]const u8 = if (w.doc) |p|
        if (w.doc_len > 0) p[0..w.doc_len] else null
    else
        null;
    const sf_opt: ?[]const u8 = if (w.source_file) |p|
        if (w.source_file_len > 0) p[0..w.source_file_len] else null
    else
        null;
    const provenance_opt: ?WordProvenance = if (w.provenance_generator) |gp|
        WordProvenance{
            .generator = gp[0..w.provenance_generator_len],
            .parent = if (w.provenance_parent) |pp|
                pp[0..w.provenance_parent_len]
            else
                "",
            .role = if (w.provenance_role) |rp|
                rp[0..w.provenance_role_len]
            else
                "",
        }
    else
        null;
    return .{
        .doc = doc_opt,
        .source_file = sf_opt,
        .source_line = w.source_line,
        .source_column = w.source_column,
        .provenance = provenance_opt,
    };
}

/// Walk the marker-pointer array for one word and produce a runtime
/// `[]const *Marker` slice owned by the context arena.
fn buildMarkerSlice(arena: Allocator, w: Word) LoaderError![]const *value_mod.Marker {
    if (w.marker_count == 0 or w.markers == null) return &.{};
    const ptrs = w.markers.?;
    const out = arena.alloc(*value_mod.Marker, w.marker_count) catch
        return LoaderError.OutOfMemory;
    var i: u32 = 0;
    while (i < w.marker_count) : (i += 1) {
        const image_marker = ptrs[i];
        const marker_ptr = arena.create(value_mod.Marker) catch return LoaderError.OutOfMemory;
        marker_ptr.* = .{ .name = nameSlice(image_marker.name, image_marker.name_len) };
        out[i] = marker_ptr;
    }
    return out;
}

/// Resolve a stack-effect index against the image's effect table and
/// produce a runtime `StackEffect` allocated in the arena. Index 0 is
/// the "no effect" sentinel; structural decoding only at M1 -- the
/// type-annotation slot lookup yields a structural pointer if the
/// blob loader has already filled the slot, NULL otherwise.
fn decodeStackEffect(
    arena: Allocator,
    header: *const Header,
    effect_idx: u32,
) LoaderError!?stack_effect_mod.StackEffect {
    if (effect_idx == 0) return null;
    if (effect_idx >= header.stack_effect_count) return LoaderError.BadStackEffectIndex;
    const effects = header.stack_effects orelse return LoaderError.BadStackEffectIndex;
    const eff = effects[effect_idx];

    const inputs = try decodeStackEffectParams(arena, eff.inputs, eff.input_count);
    const outputs = try decodeStackEffectParams(arena, eff.outputs, eff.output_count);
    return stack_effect_mod.StackEffect{
        .inputs = inputs,
        .outputs = outputs,
    };
}

fn decodeStackEffectParams(
    arena: Allocator,
    src: ?[*]const StackEffectParam,
    count: u32,
) LoaderError![]const stack_effect_mod.StackEffectParam {
    if (count == 0 or src == null) return &.{};
    const ptr = src.?;
    const out = arena.alloc(stack_effect_mod.StackEffectParam, count) catch
        return LoaderError.OutOfMemory;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const ip = ptr[i];
        out[i] = .{
            .name = nameSlice(ip.name, ip.name_len),
            .is_row_variable = ip.is_row_variable != 0,
            // Quotation effects and type annotations are deferred to
            // future fidelity work; M1 carries names + row-variable
            // flag only. Slot-based annotations fill in lazily once
            // the blob path patches the slot table (task 2/3).
            .quotation_effect = null,
            .type_annotation = null,
        };
    }
    return out;
}

// -- Structural TypeValue population -----------------------------------

/// Walk the typevalue + typedescriptor + struct-type tables and
/// allocate live runtime instances for each row. Four passes:
///
///   1. Allocate `*StructType` for each onez_image_struct_type_t.
///   2. Allocate `*TypeValue` (with a zero-init `*TypeDescriptor`) for
///      each onez_image_typevalue_t, patching the slot table so
///      cross-references in pass 3 can resolve through it.
///   3. Walk the typedescriptor table in lockstep with the typevalue
///      table; populate kind-specific data using the slot table.
///   4. Walk the word table; for words with a non-zero typevalue_slot,
///      rewrite the M1 stub body to push the runtime TypeValue.
///
/// Pass 2 allocates TypeValues before their descriptors are populated.
/// That ordering matters: it lets pass 3 resolve descriptor
/// cross-references through the slot table for TypeValues that have
/// not yet had their descriptors filled in (only the pointer identity
/// is required, not the descriptor contents).
fn populateTypeValueSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?SlotTable,
    struct_type_slots: ?StructTypeSlotTable,
) LoaderError!void {
    if (header.typevalue_count == 0 and header.struct_type_count == 0) {
        return;
    }
    const arena = ctx.quotationAllocator();

    // Pass 1: allocate runtime StructTypes and patch the struct-type
    // slot table so codegen-emitted slot-indexed pushes can resolve
    // through it. The slot index matches the row's position in
    // `onez_image_struct_types_storage[]`, mirroring the typevalue
    // slot-table contract.
    //
    // If a StructType with the same name already exists in the context
    // (e.g., allocated by `loadPrelude`), reuse it so prelude-
    // interpreted code and AOT-compiled code share the same identity.
    var struct_types_out: []*value_mod.StructType = &.{};
    if (header.struct_type_count > 0) {
        struct_types_out = arena.alloc(*value_mod.StructType, header.struct_type_count) catch
            return LoaderError.OutOfMemory;
        const rows = header.struct_types orelse return LoaderError.OutOfMemory;
        var i: u32 = 0;
        while (i < header.struct_type_count) : (i += 1) {
            const row = rows[i];
            const name = nameSlice(row.name, row.name_len);
            const existing_st: ?*value_mod.StructType = blk: {
                if (ctx.lookupTypeValueByName(name)) |tv| {
                    const desc = tv.descriptor orelse break :blk null;
                    switch (desc.kind) {
                        .struct_ => {
                            if (tv.virtual_type) |vt| {
                                if (vt.anon_struct) |as| break :blk @constCast(as);
                            }
                            break :blk null;
                        },
                        .virtual => |vdata| {
                            if (vdata.anon_struct) |as| break :blk @constCast(as);
                            break :blk null;
                        },
                        else => break :blk null,
                    }
                }
                break :blk null;
            };
            const st = if (existing_st) |reused| reused else blk: {
                const fresh = arena.create(value_mod.StructType) catch
                    return LoaderError.OutOfMemory;
                fresh.* = .{
                    .name = name,
                    .fields = try decodeFieldNames(arena, row.field_names, row.field_name_lens, row.field_count),
                    .field_types = &.{},
                };
                break :blk fresh;
            };
            struct_types_out[i] = st;
            if (struct_type_slots) |table| table[i] = st;
        }
    }

    // Pass 2: allocate TypeValues and patch the slot table. If a
    // TypeValue with the same name already exists in the context
    // (e.g. allocated by `loadPrelude`), reuse it so identity stays
    // single-sourced. Without this, prelude-interpreted code keeps
    // pointing at the prelude allocation while AOT-compiled code
    // would route through a fresh loader allocation, splitting the
    // identity surface that dispatch table lookups and predicate
    // checks key on.
    const tv_count = header.typevalue_count;
    if (tv_count == 0) return;
    const tv_rows = header.typevalues orelse return LoaderError.OutOfMemory;
    const tv_out = arena.alloc(*value_mod.TypeValue, tv_count) catch
        return LoaderError.OutOfMemory;
    const tv_reused = arena.alloc(bool, tv_count) catch
        return LoaderError.OutOfMemory;
    {
        var i: u32 = 0;
        while (i < tv_count) : (i += 1) {
            const row = tv_rows[i];
            if (row.slot == 0 or row.slot >= header.typevalue_slot_count) {
                return LoaderError.BadSlotIndex;
            }
            const name = nameSlice(row.name, row.name_len);
            const existing = ctx.lookupTypeValueByName(name) orelse
                findEnumVariantTypeValueByName(ctx, name);
            if (existing) |reused| {
                tv_out[i] = reused;
                tv_reused[i] = true;
            } else {
                const desc = arena.create(value_mod.TypeDescriptor) catch
                    return LoaderError.OutOfMemory;
                desc.* = .{ .kind = .{ .builtin = {} } };
                const tv = arena.create(value_mod.TypeValue) catch
                    return LoaderError.OutOfMemory;
                tv.* = .{
                    .name = name,
                    .descriptor = desc,
                };
                tv_out[i] = tv;
                tv_reused[i] = false;
            }
            if (slots) |slot_table| slot_table[row.slot] = tv_out[i];
        }
    }

    // Pass 3: populate descriptor kind-data through the slot table.
    {
        const desc_rows = header.typedescriptors orelse return LoaderError.OutOfMemory;
        var i: u32 = 0;
        while (i < tv_count) : (i += 1) {
            if (tv_reused[i]) continue;
            const row = tv_rows[i];
            const drow = desc_rows[i];
            const tv = tv_out[i];
            const desc = @constCast(tv.descriptor.?);
            desc.numeric = drow.numeric != 0;
            desc.exact = drow.exact != 0;
            desc.integer = drow.integer != 0;
            desc.mutable = drow.mutable != 0;
            desc.kind = try decodeKindData(arena, header, slots, struct_types_out, drow);

            const member_types = try decodeTypeValuePointers(
                arena,
                slots,
                header.typevalue_slot_count,
                row.member_type_slots,
                row.member_type_count,
            );
            tv.member_types = if (member_types.len == 0) null else member_types;
        }
    }

    // Pass 3.5: link the runtime TypeValue back to its peer aggregate.
    //
    // For `.struct_` TypeValues, find the runtime `*StructType` allocated
    // in Pass 1 with the matching name and set its `type_val`
    // back-reference. Generator-emitted compound bodies push the
    // StructType and the natives recover the owning TypeValue through
    // `st.type_val.?`; interpreter mode sets this at type-definition
    // time, so mirror that here.
    //
    // For `.virtual` and `.enum_variant` TypeValues, allocate a fresh
    // `*VirtualType` and link both directions: `vt.type_val = tv` and
    // `tv.virtual_type = vt`. Generator-emitted compound bodies push the
    // TypeValue and the natives recover the VirtualType through the
    // back-reference. When a virtual is struct-backed, also patch the
    // backing StructType's `type_val` so struct-instance natives (hash
    // wrap, destructure, etc.) reach the owning TypeValue.
    {
        var i: u32 = 0;
        while (i < tv_count) : (i += 1) {
            // Reused TypeValues already carry their virtual_type and
            // struct_type back-references from the prelude path.
            if (tv_reused[i]) continue;
            const tv = tv_out[i];
            const desc = tv.descriptor orelse continue;
            switch (desc.kind) {
                .struct_ => {
                    for (struct_types_out) |st| {
                        if (std.mem.eql(u8, st.name, tv.name)) {
                            st.type_val = tv;
                            break;
                        }
                    }
                },
                .virtual => |vdata| {
                    const vt = arena.create(value_mod.VirtualType) catch
                        return LoaderError.OutOfMemory;
                    const inner_name: []const u8 = if (vdata.anon_struct != null)
                        tv.name
                    else if (vdata.inner_type) |it|
                        it.name
                    else
                        "";
                    const type_params_slice: ?[]*const value_mod.TypeValue = blk: {
                        if (vdata.type_params.len == 0) break :blk null;
                        const tp = arena.alloc(*const value_mod.TypeValue, vdata.type_params.len) catch
                            return LoaderError.OutOfMemory;
                        for (vdata.type_params, 0..) |t, idx| tp[idx] = t;
                        break :blk tp;
                    };
                    vt.* = .{
                        .name = tv.name,
                        .inner_type = inner_name,
                        .anon_struct = vdata.anon_struct,
                        .type_params = type_params_slice,
                        .type_val = tv,
                    };
                    tv.virtual_type = vt;
                    if (vdata.anon_struct) |st| {
                        @constCast(st).type_val = tv;
                    }
                },
                .enum_variant => |evdata| {
                    const vt = arena.create(value_mod.VirtualType) catch
                        return LoaderError.OutOfMemory;
                    const inner_name: []const u8 = if (evdata.inner_type) |it| it.name else "";
                    const anon_struct: ?*const value_mod.StructType = blk: {
                        const inner_tv = evdata.inner_type orelse break :blk null;
                        const inner_desc = inner_tv.descriptor orelse break :blk null;
                        break :blk switch (inner_desc.kind) {
                            .struct_ => null,
                            else => null,
                        };
                    };
                    vt.* = .{
                        .name = tv.name,
                        .inner_type = inner_name,
                        .anon_struct = anon_struct,
                        .parent_type = evdata.parent,
                        .type_val = tv,
                    };
                    tv.virtual_type = vt;
                },
                else => {},
            }
        }
    }

    // Pass 4: rewrite word bodies that publish a TypeValue.
    if (header.word_count == 0) return;
    const words = header.words orelse return;
    var wi: u32 = 0;
    while (wi < header.word_count) : (wi += 1) {
        const w = words[wi];
        if (w.typevalue_slot == 0) continue;
        if (w.typevalue_slot >= header.typevalue_slot_count) {
            return LoaderError.BadSlotIndex;
        }
        const slot_table = slots orelse continue;
        const tv_const = slot_table[w.typevalue_slot] orelse continue;
        const tv: *value_mod.TypeValue = @constCast(tv_const);
        try replaceWordBodyWithTypeValuePush(ctx, header, wi, tv);
    }
}

/// Walk the marker description table and patch
/// `onez_image_marker_slots[]` so compiled bodies that pushed
/// freeze-time `.marker` literals reach a live runtime `*Marker` of
/// matching identity. Each description resolves to the well-known marker
/// singleton when its name matches a built-in; otherwise the loader
/// allocates a fresh `*Marker` from the context arena.
fn populateMarkerSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?MarkerSlotTable,
) LoaderError!void {
    if (header.marker_slot_count == 0) return;
    const descs = header.marker_descriptions orelse return;
    const slot_table = slots orelse return;
    const arena = ctx.quotationAllocator();
    var i: u32 = 0;
    while (i < header.marker_slot_count) : (i += 1) {
        const row = descs[i];
        if (row.slot >= header.marker_slot_count) return LoaderError.BadSlotIndex;
        const name = nameSlice(row.name, row.name_len);
        const resolved: *value_mod.Marker = blk: {
            if (markers_mod.lookupWellKnownMarker(name)) |well_known| break :blk well_known;
            const fresh = arena.create(value_mod.Marker) catch return LoaderError.OutOfMemory;
            fresh.* = .{ .name = name };
            break :blk fresh;
        };
        slot_table[row.slot] = resolved;
    }
}

/// Walk the parameter description table and patch
/// `onez_image_parameter_slots[]`. Each row carries the parameter's name
/// and the bytecode for its lazy default quotation; the loader
/// deserializes the bytecode into a runtime `Quotation` and allocates a
/// fresh `*Parameter` from the context arena.
fn populateParameterSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?ParameterSlotTable,
) LoaderError!void {
    if (header.parameter_slot_count == 0) return;
    const descs = header.parameter_descriptions orelse return;
    const slot_table = slots orelse return;
    const arena = ctx.quotationAllocator();
    var i: u32 = 0;
    while (i < header.parameter_slot_count) : (i += 1) {
        const row = descs[i];
        if (row.slot >= header.parameter_slot_count) return LoaderError.BadSlotIndex;
        const name = nameSlice(row.name, row.name_len);
        const instructions: []const value_mod.Instruction = if (row.default_quotation_bytecode) |p|
            if (row.default_quotation_bytecode_len > 0)
                instruction_bytecode.deserializeQuotationInstructions(
                    p[0..row.default_quotation_bytecode_len],
                    arena,
                ) catch return LoaderError.OutOfMemory
            else
                &.{}
        else
            &.{};
        const param = arena.create(value_mod.Parameter) catch return LoaderError.OutOfMemory;
        param.* = .{
            .name = name,
            .default_quotation = .{ .instructions = instructions, .code_ptr = null },
        };
        slot_table[row.slot] = param;
    }
}

/// Walk the mutable_map description table and patch
/// `onez_image_mutable_map_slots[]`. For each row: allocate a fresh
/// `*MutableMap` via `MutableMap.create(ctx.allocator)`, decode the
/// entries blob (u32 entry_count followed by u32 key_len + key bytes +
/// image-mode serialized Value per entry), and put each key/value pair
/// into the map. The map's initial refcount of 1 is donated to the slot;
/// the slot holds a strong reference for the process lifetime. Entry
/// values are retained before storage so the map's destroy path remains
/// ownership-balanced even though it never fires in practice.
///
/// Runs before `populateTaggedSlots` so a tagged-inner value carrying a
/// `.mutable_map` resolves correctly; entries that themselves reference
/// later mutable_map slots or any tagged slot are not supported by the
/// single-pass ordering, which matches the existing constraint on
/// tagged-slot self-references.
fn populateMutableMapSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?MutableMapSlotTable,
) LoaderError!void {
    if (header.mutable_map_slot_count == 0) return;
    const descs = header.mutable_map_descriptions orelse return;
    const slot_table = slots orelse return;

    // The slot maps and their interior allocations all sit on the
    // context arena. The arena is freed wholesale at `Context.deinit`,
    // so the slot table never needs explicit release; storing the
    // header allocator as the arena keeps any runtime mutation of the
    // map (key dupes, hashmap grows) flowing through the same arena
    // for the same wholesale teardown. The slot's refcount of 1 is
    // ignored at teardown because nothing decrements it; the destroy
    // callback would no-op anyway since the arena does not free
    // individual allocations.
    const arena = ctx.quotationAllocator();

    const slot_tables: instruction_bytecode.SlotResolutionTables = .{
        .typevalue_slots = ctx.image_typevalue_slots,
        .typevalue_slot_count = ctx.image_typevalue_slot_count,
        .struct_type_slots = ctx.image_struct_type_slots,
        .struct_type_slot_count = ctx.image_struct_type_slot_count,
        .marker_slots = ctx.image_marker_slots,
        .marker_slot_count = ctx.image_marker_slot_count,
        .parameter_slots = ctx.image_parameter_slots,
        .parameter_slot_count = ctx.image_parameter_slot_count,
        .tagged_slots = ctx.image_tagged_slots,
        .tagged_slot_count = ctx.image_tagged_slot_count,
        .mutable_map_slots = ctx.image_mutable_map_slots,
        .mutable_map_slot_count = ctx.image_mutable_map_slot_count,
    };

    var i: u32 = 0;
    while (i < header.mutable_map_slot_count) : (i += 1) {
        const row = descs[i];
        if (row.slot >= header.mutable_map_slot_count) return LoaderError.BadSlotIndex;

        const mmap = value_mod.MutableMap.create(arena) catch return LoaderError.OutOfMemory;

        // Patch the slot now so any entry whose value resolves through
        // this same slot table (e.g., recursive references) sees the
        // allocated map. Initial refcount is 1; the slot owns it.
        slot_table[row.slot] = mmap;

        const bytes = if (row.entries_bytecode) |p|
            if (row.entries_bytecode_len > 0) p[0..row.entries_bytecode_len] else &[_]u8{}
        else
            &[_]u8{};

        if (bytes.len == 0) continue;
        if (bytes.len < @sizeOf(u32)) return LoaderError.OutOfMemory;

        var offset: usize = 0;
        const entry_count = std.mem.bytesToValue(u32, bytes[offset .. offset + @sizeOf(u32)]);
        offset += @sizeOf(u32);

        var e: u32 = 0;
        while (e < entry_count) : (e += 1) {
            if (offset + @sizeOf(u32) > bytes.len) return LoaderError.OutOfMemory;
            const key_len = std.mem.bytesToValue(u32, bytes[offset .. offset + @sizeOf(u32)]);
            offset += @sizeOf(u32);
            if (offset + key_len > bytes.len) return LoaderError.OutOfMemory;
            const key_src = bytes[offset .. offset + key_len];
            offset += key_len;

            const value = instruction_bytecode.deserializeValueAtForImage(
                bytes,
                &offset,
                arena,
                &slot_tables,
            ) catch return LoaderError.OutOfMemory;

            const key_copy = arena.dupe(u8, key_src) catch return LoaderError.OutOfMemory;
            mmap.map.put(arena, key_copy, value) catch return LoaderError.OutOfMemory;
        }
    }
}

/// Walk the tagged description table and patch
/// `onez_image_tagged_slots[]`. For each row, recover the tag's
/// `*const VirtualType` by reading the typevalue slot at
/// `tag_typevalue_slot` and following the loader-populated
/// `TypeValue.virtual_type` back-reference. Deserialize the inner
/// Value via `instruction_bytecode.deserializeValueAtForImage`, passing
/// the already-patched slot tables so nested `.tagged` / `.type_val` /
/// etc. inner values resolve through their own slots. Allocate a
/// runtime `*const Value` carrying `.tagged = .{ .tag = vt,
/// .inner = inner_ptr }` and patch the slot.
fn populateTaggedSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?TaggedSlotTable,
) LoaderError!void {
    if (header.tagged_slot_count == 0) return;
    const descs = header.tagged_descriptions orelse return;
    const slot_table = slots orelse return;
    const arena = ctx.quotationAllocator();

    const slot_tables: instruction_bytecode.SlotResolutionTables = .{
        .typevalue_slots = ctx.image_typevalue_slots,
        .typevalue_slot_count = ctx.image_typevalue_slot_count,
        .struct_type_slots = ctx.image_struct_type_slots,
        .struct_type_slot_count = ctx.image_struct_type_slot_count,
        .marker_slots = ctx.image_marker_slots,
        .marker_slot_count = ctx.image_marker_slot_count,
        .parameter_slots = ctx.image_parameter_slots,
        .parameter_slot_count = ctx.image_parameter_slot_count,
        .tagged_slots = ctx.image_tagged_slots,
        .tagged_slot_count = ctx.image_tagged_slot_count,
        .mutable_map_slots = ctx.image_mutable_map_slots,
        .mutable_map_slot_count = ctx.image_mutable_map_slot_count,
    };

    var i: u32 = 0;
    while (i < header.tagged_slot_count) : (i += 1) {
        const row = descs[i];
        if (row.slot >= header.tagged_slot_count) return LoaderError.BadSlotIndex;
        if (row.tag_typevalue_slot == 0) return LoaderError.BadSlotIndex;
        if (row.tag_typevalue_slot >= header.typevalue_slot_count) return LoaderError.BadSlotIndex;
        const tv_table = ctx.image_typevalue_slots orelse return LoaderError.BadSlotIndex;
        const tv_const = tv_table[row.tag_typevalue_slot] orelse return LoaderError.BadSlotIndex;
        const vt = tv_const.virtual_type orelse return LoaderError.BadSlotIndex;

        const inner = arena.create(value_mod.Value) catch return LoaderError.OutOfMemory;
        if (row.inner_bytecode) |p| {
            if (row.inner_bytecode_len > 0) {
                var offset: usize = 0;
                inner.* = instruction_bytecode.deserializeValueAtForImage(
                    p[0..row.inner_bytecode_len],
                    &offset,
                    arena,
                    &slot_tables,
                ) catch return LoaderError.OutOfMemory;
            } else {
                inner.* = .{ .unit = {} };
            }
        } else {
            inner.* = .{ .unit = {} };
        }

        const tagged = arena.create(value_mod.Value) catch return LoaderError.OutOfMemory;
        tagged.* = .{ .tagged = .{ .tag = vt, .inner = inner } };
        slot_table[row.slot] = tagged;
    }
}

/// Decode a TypeKindData payload from one typedescriptor row.
/// Cross-references resolve through the slot table populated by
/// pass 2; an out-of-range slot index returns `BadSlotIndex`. The
/// kind field is treated as a closed vocabulary; an unrecognized
/// kind value returns `BadTypeKind`.
fn decodeKindData(
    arena: Allocator,
    header: *const Header,
    slots: ?SlotTable,
    struct_types_out: []*value_mod.StructType,
    drow: TypeDescriptor,
) LoaderError!value_mod.TypeKindData {
    return switch (drow.kind) {
        0 => .{ .builtin = {} },
        1 => .{ .sentinel = {} },
        2 => .{
            .struct_ = .{
                .fields = try decodeFieldNames(arena, drow.field_names, drow.field_name_lens, drow.field_count),
                .field_types = try decodeOptionalTypeValuePointers(
                    arena,
                    slots,
                    header.typevalue_slot_count,
                    drow.field_type_slots,
                    drow.field_type_count,
                ),
            },
        },
        3 => blk: {
            const inner = try lookupSlot(slots, header.typevalue_slot_count, drow.inner_type_slot);
            const params = try decodeTypeValuePointers(
                arena,
                slots,
                header.typevalue_slot_count,
                drow.type_param_slots,
                drow.type_param_count,
            );
            const anon_struct: ?*value_mod.StructType = if (drow.anon_struct_idx == anon_struct_absent)
                null
            else if (drow.anon_struct_idx < struct_types_out.len)
                struct_types_out[drow.anon_struct_idx]
            else
                return LoaderError.BadStructTypeIndex;
            break :blk .{ .virtual = .{
                .inner_type = inner,
                .type_params = params,
                .anon_struct = anon_struct,
            } };
        },
        4 => blk: {
            const variants = try decodeEnumVariants(
                arena,
                slots,
                header.typevalue_slot_count,
                drow.variants,
                drow.variant_count,
            );
            break :blk .{ .enum_ = .{ .variants = variants } };
        },
        5 => .{
            .enum_variant = .{
                .parent = try lookupSlot(slots, header.typevalue_slot_count, drow.parent_type_slot),
                .inner_type = try lookupSlot(slots, header.typevalue_slot_count, drow.inner_type_slot),
            },
        },
        6 => .{
            .resource = .{
                .resource_kind = if (drow.resource_kind) |p| p[0..drow.resource_kind_len] else "",
            },
        },
        7 => .{
            .ffi_struct = .{
                .fields = try decodeFieldNames(arena, drow.field_names, drow.field_name_lens, drow.field_count),
                .field_types = try decodeOptionalTypeValuePointers(
                    arena,
                    slots,
                    header.typevalue_slot_count,
                    drow.field_type_slots,
                    drow.field_type_count,
                ),
                .ffi_layout = drow.ffi_layout,
            },
        },
        8 => .{ .union_ = {} },
        else => LoaderError.BadTypeKind,
    };
}

fn decodeFieldNames(
    arena: Allocator,
    names: ?[*]const [*]const u8,
    lens: ?[*]const u32,
    count: u32,
) LoaderError![]const []const u8 {
    if (count == 0 or names == null or lens == null) return &.{};
    const np = names.?;
    const lp = lens.?;
    const out = arena.alloc([]const u8, count) catch return LoaderError.OutOfMemory;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        out[i] = np[i][0..lp[i]];
    }
    return out;
}

fn decodeTypeValuePointers(
    arena: Allocator,
    slots: ?SlotTable,
    slot_count: u32,
    slot_array: ?[*]const u32,
    count: u32,
) LoaderError![]const *const value_mod.TypeValue {
    if (count == 0 or slot_array == null) return &.{};
    const sp = slot_array.?;
    const out = arena.alloc(*const value_mod.TypeValue, count) catch
        return LoaderError.OutOfMemory;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const tv = try lookupSlot(slots, slot_count, sp[i]) orelse return LoaderError.BadSlotIndex;
        out[i] = tv;
    }
    return out;
}

fn decodeOptionalTypeValuePointers(
    arena: Allocator,
    slots: ?SlotTable,
    slot_count: u32,
    slot_array: ?[*]const u32,
    count: u32,
) LoaderError![]const ?*const value_mod.TypeValue {
    if (count == 0 or slot_array == null) return &.{};
    const sp = slot_array.?;
    const out = arena.alloc(?*const value_mod.TypeValue, count) catch
        return LoaderError.OutOfMemory;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        out[i] = try lookupSlot(slots, slot_count, sp[i]);
    }
    return out;
}

fn decodeEnumVariants(
    arena: Allocator,
    slots: ?SlotTable,
    slot_count: u32,
    variants: ?[*]const EnumVariant,
    count: u32,
) LoaderError![]const value_mod.Variant {
    if (count == 0 or variants == null) return &.{};
    const vp = variants.?;
    const out = arena.alloc(value_mod.Variant, count) catch
        return LoaderError.OutOfMemory;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const v = vp[i];
        out[i] = .{
            .name = nameSlice(v.name, v.name_len),
            .type_val = try lookupSlot(slots, slot_count, v.type_slot),
        };
    }
    return out;
}

fn lookupSlot(
    slots: ?SlotTable,
    slot_count: u32,
    slot_index: u32,
) LoaderError!?*const value_mod.TypeValue {
    if (slot_index == 0) return null;
    if (slot_index >= slot_count) return LoaderError.BadSlotIndex;
    const slot_table = slots orelse return null;
    return slot_table[slot_index];
}

fn replaceWordBodyWithTypeValuePush(
    ctx: *Context,
    header: *const Header,
    word_idx: u32,
    tv: *value_mod.TypeValue,
) LoaderError!void {
    if (word_idx >= header.word_count) return LoaderError.BadWordIndex;
    const words = header.words orelse return LoaderError.BadWordIndex;
    const w = words[word_idx];
    if (w.module_idx >= header.module_count) return LoaderError.BadWordIndex;
    const modules = header.modules orelse return LoaderError.BadWordIndex;
    const m = modules[w.module_idx];

    const module_name = nameSlice(m.name, m.name_len);
    const word_name = nameSlice(w.name, w.name_len);

    const cache_entry = ctx.module_cache_value.map.getPtr(module_name) orelse return;
    if (cache_entry.* != .module) return;
    const module_ptr = cache_entry.*.module;
    const word_entry = module_ptr.words.getPtr(word_name) orelse return;

    const arena = ctx.quotationAllocator();
    const instrs = arena.alloc(value_mod.Instruction, 1) catch return LoaderError.OutOfMemory;
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 };
    word_entry.action = .{ .compound = instrs };
}

// -- PIC relocation walk -----------------------------------------------

fn resolvePicRelocations(
    header: *const Header,
    slots: ?SlotTable,
    relocs: PicRelocationTable,
) LoaderError!void {
    const slot_table = slots orelse return;
    for (relocs.items) |entry| {
        if (entry.slot_index == 0 or entry.slot_index >= header.typevalue_slot_count) {
            return LoaderError.BadSlotIndex;
        }
        entry.target.* = slot_table[entry.slot_index];
    }
}

// -- Helpers -----------------------------------------------------------

fn nameSlice(ptr: [*]const u8, len: u32) []const u8 {
    return ptr[0..len];
}

/// Scan the context's enum variant registries for a TypeValue with the
/// given name. `lookupTypeValueByName` only walks the dictionary, but
/// data-carrying enum variant TypeValues (e.g. `option:some`) are not
/// dictionary-resolvable -- only their wrap / predicate words are.
/// The variant's TypeValue is reachable through the enum's variant
/// VirtualType list.
fn findEnumVariantTypeValueByName(ctx: *Context, name: []const u8) ?*value_mod.TypeValue {
    for (ctx.type_registry_frames.items) |*frame| {
        var iter = frame.enum_registry.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.*) |variant_vt| {
                const tv = variant_vt.type_val orelse continue;
                if (std.mem.eql(u8, tv.name, name)) return tv;
            }
        }
    }
    return null;
}

/// Push a structured error onto `ctx.error_details` so `captureError`
/// in capi.zig surfaces it on the user-visible last-error line.
fn recordLoaderError(
    ctx: *Context,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const arena = ctx.quotationAllocator();
    const msg = std.fmt.allocPrint(arena, fmt, args) catch return;
    appendErrorDetail(ctx, "runtime-image-load-failed", msg);
}

fn recordLoaderNote(
    ctx: *Context,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const arena = ctx.quotationAllocator();
    const msg = std.fmt.allocPrint(arena, fmt, args) catch return;
    appendErrorDetail(ctx, "runtime-image-load-note", msg);
}

fn appendErrorDetail(ctx: *Context, error_type: []const u8, message: []const u8) void {
    ctx.error_details.append(ctx.allocator, .{
        .source = "<aot-runtime-image>",
        .line = 0,
        .error_type = error_type,
        .message = message,
        .word_name = null,
    }) catch {};
}

// -- Tests -------------------------------------------------------------

const testing = std.testing;
const Instruction = value_mod.Instruction;

fn emptyHeader() Header {
    return .{
        .format_version = aot_image_emit.format_version,
        .module_count = 0,
        .word_count = 0,
        .marker_pool_count = 0,
        .typevalue_slot_count = 1,
        .stack_effect_count = 1,
        .typevalue_count = 0,
        .struct_type_count = 0,
        .marker_slot_count = 0,
        .parameter_slot_count = 0,
        .tagged_slot_count = 0,
        .mutable_map_slot_count = 0,
        .modules = null,
        .words = null,
        .markers = null,
        .stack_effects = null,
        .typevalues = null,
        .typedescriptors = null,
        .struct_types = null,
        .marker_descriptions = null,
        .parameter_descriptions = null,
        .tagged_descriptions = null,
        .mutable_map_descriptions = null,
    };
}

fn wordRow(name: []const u8, word_id: u32, module_idx: u32) Word {
    return .{
        .name = name.ptr,
        .name_len = @intCast(name.len),
        .word_id = word_id,
        .module_idx = module_idx,
        .classification = classification_structural,
        .blob_reason = 0,
        .flags = 0,
        ._reserved = 0,
        .input_count = 0,
        .output_count = 0,
        ._pad = 0,
        .stack_effect_idx = 0,
        .markers = null,
        .marker_count = 0,
        .body_bytecode = null,
        .body_bytecode_len = 0,
        .typevalue_slot = 0,
        .doc = null,
        .doc_len = 0,
        .source_file = null,
        .source_file_len = 0,
        .source_line = 0,
        .source_column = 0,
        .provenance_generator = null,
        .provenance_generator_len = 0,
        .provenance_parent = null,
        .provenance_parent_len = 0,
        .provenance_role = null,
        .provenance_role_len = 0,
    };
}

fn zeroDescriptor() TypeDescriptor {
    return .{
        .numeric = 0,
        .exact = 0,
        .integer = 0,
        .mutable = 0,
        .kind = 0,
        ._pad = .{ 0, 0, 0 },
        .field_names = null,
        .field_name_lens = null,
        .field_count = 0,
        .field_type_slots = null,
        .field_type_count = 0,
        .inner_type_slot = 0,
        .anon_struct_idx = anon_struct_absent,
        .type_param_slots = null,
        .type_param_count = 0,
        .parent_type_slot = 0,
        .variants = null,
        .variant_count = 0,
        .resource_kind = null,
        .resource_kind_len = 0,
        .ffi_layout = 0,
    };
}

test "loadIntoContext: rejects unsupported format version" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var header = emptyHeader();
    header.format_version = aot_image_emit.format_version + 1;

    try testing.expectError(
        LoaderError.UnsupportedFormat,
        loadIntoContext(&ctx, &header, .{}, null),
    );
}

test "loadIntoContext: empty header populates nothing" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const header = emptyHeader();

    try loadIntoContext(&ctx, &header, .{}, null);

    var iter = ctx.module_cache_value.map.iterator();
    var seen: u32 = 0;
    while (iter.next()) |_| seen += 1;
    try testing.expectEqual(@as(u32, 0), seen);
}

test "loadIntoContext: structural-only image populates module cache" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const w0_name = "alpha";
    const w1_name = "beta";
    const m_name = "demo";

    const words = [_]Word{
        wordRow(w0_name, 100, 0),
        wordRow(w1_name, 101, 0),
    };
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 2 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 2;
    header.modules = &modules;
    header.words = &words;

    try loadIntoContext(&ctx, &header, .{}, null);

    const entry = ctx.module_cache_value.map.get(m_name) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(value_mod.Value{ .module = entry.module }, entry);
    const module_ptr = entry.module;

    const a = module_ptr.words.get(w0_name) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(?u32, 100), a.word_id);
    try testing.expect(a.action == .compound);
    try testing.expectEqual(@as(usize, 0), a.action.compound.len);

    const b = module_ptr.words.get(w1_name) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(?u32, 101), b.word_id);
}

test "loadIntoContext: resource TypeValue rehydrates kind + universal bools + resource_kind" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const tv_name = "demo-resource";
    const w_name = "DemoResource";
    const m_name = "demo";

    const resource_kind = "demo-handle";

    var drow = zeroDescriptor();
    drow.numeric = 1;
    drow.exact = 1;
    drow.integer = 0;
    drow.mutable = 1;
    drow.kind = 6;
    drow.resource_kind = resource_kind.ptr;
    drow.resource_kind_len = resource_kind.len;

    const descriptors = [_]TypeDescriptor{drow};
    const typevalues = [_]TypeValueRow{
        .{
            .name = tv_name.ptr,
            .name_len = tv_name.len,
            .slot = 1,
            .descriptor = &descriptors[0],
            .member_type_slots = null,
            .member_type_count = 0,
        },
    };
    const words = [_]Word{
        blk: {
            var w = wordRow(w_name, 200, 0);
            w.typevalue_slot = 1;
            break :blk w;
        },
    };
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };

    var slot_storage: [2]?*const value_mod.TypeValue = .{ null, null };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.typevalue_slot_count = 2;
    header.typevalue_count = typevalues.len;
    header.modules = &modules;
    header.words = &words;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;

    try loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, null);

    const tv = slot_storage[1] orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqualStrings(tv_name, tv.name);

    const desc = tv.descriptor.?;
    try testing.expect(desc.kind == .resource);
    try testing.expectEqual(true, desc.numeric);
    try testing.expectEqual(true, desc.exact);
    try testing.expectEqual(false, desc.integer);
    try testing.expectEqual(true, desc.mutable);
    try testing.expectEqualStrings("demo-handle", desc.kind.resource.resource_kind);

    const cache_entry = ctx.module_cache_value.map.get(m_name) orelse return error.TestUnexpectedResult;
    const module_ptr = cache_entry.module;
    const w = module_ptr.words.get(w_name) orelse return error.TestUnexpectedResult;
    try testing.expect(w.action == .compound);
    try testing.expectEqual(@as(usize, 1), w.action.compound.len);
    try testing.expect(w.action.compound[0].op == .push_literal);
    try testing.expectEqual(tv, w.action.compound[0].op.push_literal.type_val);
}

test "loadIntoContext: struct TypeDescriptor with field-types resolves cross-references" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const a_name = "A";
    const b_name = "B";

    var a_desc = zeroDescriptor();
    a_desc.kind = 0; // builtin
    var b_desc = zeroDescriptor();
    b_desc.kind = 2; // struct_

    const b_field_names = [_][*]const u8{"x".ptr};
    const b_field_lens = [_]u32{1};
    const b_field_slots = [_]u32{1}; // points at A
    b_desc.field_names = &b_field_names;
    b_desc.field_name_lens = &b_field_lens;
    b_desc.field_count = 1;
    b_desc.field_type_slots = &b_field_slots;
    b_desc.field_type_count = 1;

    const descriptors = [_]TypeDescriptor{ a_desc, b_desc };
    const typevalues = [_]TypeValueRow{
        .{
            .name = a_name.ptr,
            .name_len = a_name.len,
            .slot = 1,
            .descriptor = &descriptors[0],
            .member_type_slots = null,
            .member_type_count = 0,
        },
        .{
            .name = b_name.ptr,
            .name_len = b_name.len,
            .slot = 2,
            .descriptor = &descriptors[1],
            .member_type_slots = null,
            .member_type_count = 0,
        },
    };

    var slot_storage: [3]?*const value_mod.TypeValue = .{ null, null, null };
    var header = emptyHeader();
    header.typevalue_slot_count = 3;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;

    try loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, null);

    const tv_a = slot_storage[1] orelse return error.TestUnexpectedResult;
    const tv_b = slot_storage[2] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("A", tv_a.name);
    try testing.expectEqualStrings("B", tv_b.name);
    const b_kind = tv_b.descriptor.?.kind;
    try testing.expect(b_kind == .struct_);
    try testing.expectEqual(@as(usize, 1), b_kind.struct_.field_types.len);
    try testing.expectEqual(@as(?*const value_mod.TypeValue, tv_a), b_kind.struct_.field_types[0]);
}

test "loadIntoContext: enum descriptor decodes variants and cross-references" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const color_name = "Color";
    const red_name = "red";

    var color_desc = zeroDescriptor();
    color_desc.kind = 4; // enum_
    var red_desc = zeroDescriptor();
    red_desc.kind = 5; // enum_variant
    red_desc.parent_type_slot = 1; // -> Color

    const variants = [_]EnumVariant{
        .{ .name = red_name.ptr, .name_len = red_name.len, .type_slot = 2 },
    };
    color_desc.variants = &variants;
    color_desc.variant_count = variants.len;

    const descriptors = [_]TypeDescriptor{ color_desc, red_desc };
    const typevalues = [_]TypeValueRow{
        .{
            .name = color_name.ptr,
            .name_len = color_name.len,
            .slot = 1,
            .descriptor = &descriptors[0],
            .member_type_slots = null,
            .member_type_count = 0,
        },
        .{
            .name = red_name.ptr,
            .name_len = red_name.len,
            .slot = 2,
            .descriptor = &descriptors[1],
            .member_type_slots = null,
            .member_type_count = 0,
        },
    };

    var slot_storage: [3]?*const value_mod.TypeValue = .{ null, null, null };
    var header = emptyHeader();
    header.typevalue_slot_count = 3;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;

    try loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, null);

    const color = slot_storage[1] orelse return error.TestUnexpectedResult;
    const red = slot_storage[2] orelse return error.TestUnexpectedResult;
    const color_kind = color.descriptor.?.kind;
    try testing.expect(color_kind == .enum_);
    try testing.expectEqual(@as(usize, 1), color_kind.enum_.variants.len);
    try testing.expectEqualStrings("red", color_kind.enum_.variants[0].name);
    try testing.expectEqual(@as(?*const value_mod.TypeValue, red), color_kind.enum_.variants[0].type_val);
    const red_kind = red.descriptor.?.kind;
    try testing.expect(red_kind == .enum_variant);
    try testing.expectEqual(@as(?*const value_mod.TypeValue, color), red_kind.enum_variant.parent);
}

test "loadIntoContext: virtual with anon_struct allocates StructType" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const inner_name = "Pair";
    const outer_name = "Wrapper";

    var inner_desc = zeroDescriptor();
    inner_desc.kind = 0; // builtin
    var outer_desc = zeroDescriptor();
    outer_desc.kind = 3; // virtual
    outer_desc.anon_struct_idx = 0;

    const struct_field_names = [_][*]const u8{"value".ptr};
    const struct_field_lens = [_]u32{5};
    const struct_field_slots = [_]u32{1};
    const struct_types = [_]StructType{
        .{
            .name = "pair-fields".ptr,
            .name_len = 11,
            .field_names = &struct_field_names,
            .field_name_lens = &struct_field_lens,
            .field_count = 1,
            .field_type_slots = &struct_field_slots,
            .field_type_count = 1,
        },
    };

    const descriptors = [_]TypeDescriptor{ inner_desc, outer_desc };
    const typevalues = [_]TypeValueRow{
        .{
            .name = inner_name.ptr,
            .name_len = inner_name.len,
            .slot = 1,
            .descriptor = &descriptors[0],
            .member_type_slots = null,
            .member_type_count = 0,
        },
        .{
            .name = outer_name.ptr,
            .name_len = outer_name.len,
            .slot = 2,
            .descriptor = &descriptors[1],
            .member_type_slots = null,
            .member_type_count = 0,
        },
    };

    var slot_storage: [3]?*const value_mod.TypeValue = .{ null, null, null };
    var header = emptyHeader();
    header.typevalue_slot_count = 3;
    header.typevalue_count = typevalues.len;
    header.struct_type_count = struct_types.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;
    header.struct_types = &struct_types;

    try loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, null);

    const outer = slot_storage[2] orelse return error.TestUnexpectedResult;
    const outer_kind = outer.descriptor.?.kind;
    try testing.expect(outer_kind == .virtual);
    const anon = outer_kind.virtual.anon_struct orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("pair-fields", anon.name);
    try testing.expectEqual(@as(usize, 1), anon.fields.len);
    try testing.expectEqualStrings("value", anon.fields[0]);
}

test "loadIntoContext: PIC relocation rewrites snapshot slot to runtime TypeValue" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const tv_name = "color";

    var desc = zeroDescriptor();
    desc.kind = 0;
    const descriptors = [_]TypeDescriptor{desc};
    const typevalues = [_]TypeValueRow{
        .{
            .name = tv_name.ptr,
            .name_len = tv_name.len,
            .slot = 1,
            .descriptor = &descriptors[0],
            .member_type_slots = null,
            .member_type_count = 0,
        },
    };
    var slot_storage: [2]?*const value_mod.TypeValue = .{ null, null };

    var snapshot_slot: ?*const value_mod.TypeValue = null;
    const relocs = [_]PicRelocation{
        .{ .target = &snapshot_slot, .slot_index = 1 },
    };
    const reloc_table: PicRelocationTable = .{ .items = &relocs };

    var header = emptyHeader();
    header.typevalue_slot_count = 2;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;

    try loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, reloc_table);

    const tv = slot_storage[1] orelse return error.TestUnexpectedResult;
    try testing.expectEqual(tv, snapshot_slot);
    try testing.expectEqualStrings("color", tv.name);
}

test "loadIntoContext: PIC relocation with out-of-range slot index errors" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var slot_storage: [2]?*const value_mod.TypeValue = .{ null, null };
    var snapshot_slot: ?*const value_mod.TypeValue = null;
    const relocs = [_]PicRelocation{
        .{ .target = &snapshot_slot, .slot_index = 99 },
    };
    const reloc_table: PicRelocationTable = .{ .items = &relocs };

    var header = emptyHeader();
    header.typevalue_slot_count = 2;

    try testing.expectError(
        LoaderError.BadSlotIndex,
        loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, reloc_table),
    );
}

test "loadIntoContext: rejects out-of-range typevalue slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const tv_name = "x";
    var desc = zeroDescriptor();
    desc.kind = 0;
    const descriptors = [_]TypeDescriptor{desc};
    const typevalues = [_]TypeValueRow{
        .{
            .name = tv_name.ptr,
            .name_len = tv_name.len,
            .slot = 99, // out of range vs typevalue_slot_count below
            .descriptor = &descriptors[0],
            .member_type_slots = null,
            .member_type_count = 0,
        },
    };

    var slot_storage: [2]?*const value_mod.TypeValue = .{ null, null };
    var header = emptyHeader();
    header.typevalue_slot_count = 2;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;

    try testing.expectError(
        LoaderError.BadSlotIndex,
        loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, null),
    );
}

test "loadIntoContext: tagged slot rejects out-of-range tag_typevalue_slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var desc = zeroDescriptor();
    desc.kind = 0;
    const descriptors = [_]TypeDescriptor{desc};
    const tv_name = "color:red";
    const typevalues = [_]TypeValueRow{
        .{
            .name = tv_name.ptr,
            .name_len = tv_name.len,
            .slot = 1,
            .descriptor = &descriptors[0],
            .member_type_slots = null,
            .member_type_count = 0,
        },
    };

    const tag_name = "color:red";
    const tagged_descs = [_]TaggedDescription{
        .{
            .name = tag_name.ptr,
            .name_len = tag_name.len,
            .slot = 0,
            .tag_typevalue_slot = 99,
            .inner_bytecode = null,
            .inner_bytecode_len = 0,
        },
    };

    var tv_storage: [2]?*const value_mod.TypeValue = .{ null, null };
    var tagged_storage: [1]?*const value_mod.Value = .{null};

    var header = emptyHeader();
    header.typevalue_slot_count = 2;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;
    header.tagged_slot_count = 1;
    header.tagged_descriptions = &tagged_descs;

    try testing.expectError(
        LoaderError.BadSlotIndex,
        loadIntoContext(
            &ctx,
            &header,
            .{ .typevalues = &tv_storage, .tagged = &tagged_storage },
            null,
        ),
    );
}

test "loadIntoContext: tagged slot reconstructs Value via VirtualType back-reference" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var desc = zeroDescriptor();
    desc.kind = 3; // virtual
    desc.anon_struct_idx = anon_struct_absent;
    const descriptors = [_]TypeDescriptor{desc};
    const tv_name = "color:red";
    const typevalues = [_]TypeValueRow{
        .{
            .name = tv_name.ptr,
            .name_len = tv_name.len,
            .slot = 1,
            .descriptor = &descriptors[0],
            .member_type_slots = null,
            .member_type_count = 0,
        },
    };

    // Inner Value bytecode: a 5-byte symbol "red". Use the canonical
    // encoder so the schema stays in sync with the deserializer.
    var inner_enc: std.ArrayListUnmanaged(u8) = .{};
    defer inner_enc.deinit(testing.allocator);
    try instruction_bytecode.serializeValueInto(
        &inner_enc,
        .{ .symbol = "red" },
        testing.allocator,
    );

    const tag_name = "color:red";
    const tagged_descs = [_]TaggedDescription{
        .{
            .name = tag_name.ptr,
            .name_len = tag_name.len,
            .slot = 0,
            .tag_typevalue_slot = 1,
            .inner_bytecode = inner_enc.items.ptr,
            .inner_bytecode_len = @intCast(inner_enc.items.len),
        },
    };

    var tv_storage: [2]?*const value_mod.TypeValue = .{ null, null };
    var tagged_storage: [1]?*const value_mod.Value = .{null};

    var header = emptyHeader();
    header.typevalue_slot_count = 2;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;
    header.tagged_slot_count = 1;
    header.tagged_descriptions = &tagged_descs;

    try loadIntoContext(
        &ctx,
        &header,
        .{ .typevalues = &tv_storage, .tagged = &tagged_storage },
        null,
    );

    const tagged_ptr = tagged_storage[0] orelse return error.TestUnexpectedResult;
    try testing.expect(tagged_ptr.* == .tagged);
    try testing.expectEqualStrings("color:red", tagged_ptr.tagged.tag.name);
    try testing.expect(tagged_ptr.tagged.inner.* == .symbol);
    try testing.expectEqualStrings("red", tagged_ptr.tagged.inner.symbol);
}

test "loadIntoContext: bytecode body decodes into compound action" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    const sample = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 1, .column = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1, .column = 3 },
    };
    try instruction_bytecode.serializeInstructionsInto(&encoded, &sample, testing.allocator);

    const w_name = "twiddle";
    const m_name = "demo";
    var w = wordRow(w_name, 100, 0);
    w.body_bytecode = encoded.items.ptr;
    w.body_bytecode_len = @intCast(encoded.items.len);
    const words = [_]Word{w};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;

    try loadIntoContext(&ctx, &header, .{}, null);

    const entry = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const module_ptr = entry.module;
    const mw = module_ptr.words.get(w_name) orelse return error.TestExpectedWord;
    try testing.expect(mw.action == .compound);
    const decoded = mw.action.compound;
    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expect(decoded[0].op == .push_literal);
    try testing.expectEqual(@as(i64, 7), decoded[0].op.push_literal.fixnum);
    try testing.expect(decoded[1].op == .call_word);
    try testing.expectEqualStrings("+", decoded[1].op.call_word);
}

test "loadIntoContext: null body bytecode preserves empty compound" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const w_name = "stub";
    const m_name = "demo";
    const words = [_]Word{wordRow(w_name, 0, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;

    try loadIntoContext(&ctx, &header, .{}, null);

    const entry = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const mw = entry.module.words.get(w_name) orelse return error.TestExpectedWord;
    try testing.expect(mw.action == .compound);
    try testing.expectEqual(@as(usize, 0), mw.action.compound.len);
}

test "loadIntoContext: nested quotation literal round-trips" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const inner = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 0, .column = 0 },
    };
    const outer = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner } } }, .line = 0, .column = 0 },
        .{ .op = .{ .call_word = "call" }, .line = 0, .column = 0 },
    };

    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &outer, testing.allocator);

    const w_name = "wrap";
    const m_name = "demo";
    var w = wordRow(w_name, 1, 0);
    w.body_bytecode = encoded.items.ptr;
    w.body_bytecode_len = @intCast(encoded.items.len);
    const words = [_]Word{w};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;

    try loadIntoContext(&ctx, &header, .{}, null);

    const entry = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const mw = entry.module.words.get(w_name) orelse return error.TestExpectedWord;
    const decoded = mw.action.compound;
    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expect(decoded[0].op == .push_literal);
    try testing.expect(decoded[0].op.push_literal == .quotation);
    const nested = decoded[0].op.push_literal.quotation.instructions;
    try testing.expectEqual(@as(usize, 1), nested.len);
    try testing.expectEqual(@as(i64, 3), nested[0].op.push_literal.fixnum);
}

test "loadIntoContext: truncated body bytecode surfaces OutOfMemory" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const truncated = [_]u8{0x42};

    const w_name = "broken";
    const m_name = "demo";
    var w = wordRow(w_name, 1, 0);
    w.body_bytecode = &truncated;
    w.body_bytecode_len = truncated.len;
    const words = [_]Word{w};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;

    try testing.expectError(
        LoaderError.OutOfMemory,
        loadIntoContext(&ctx, &header, .{}, null),
    );
}

test "loadIntoContext: diagnostic metadata fields round-trip into ModuleWord" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const w_name = "annotated";
    const m_name = "demo";
    const doc_str = "doubles the input";
    const file_str = "/projects/demo.1z";
    const gen_str = "struct";
    const parent_str = "person";
    const role_str = "field-getter";

    var w = wordRow(w_name, 7, 0);
    w.doc = doc_str.ptr;
    w.doc_len = @intCast(doc_str.len);
    w.source_file = file_str.ptr;
    w.source_file_len = @intCast(file_str.len);
    w.source_line = 12;
    w.source_column = 4;
    w.provenance_generator = gen_str.ptr;
    w.provenance_generator_len = @intCast(gen_str.len);
    w.provenance_parent = parent_str.ptr;
    w.provenance_parent_len = @intCast(parent_str.len);
    w.provenance_role = role_str.ptr;
    w.provenance_role_len = @intCast(role_str.len);

    const words = [_]Word{w};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;

    try loadIntoContext(&ctx, &header, .{}, null);

    const entry = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const mw = entry.module.words.get(w_name) orelse return error.TestExpectedWord;
    try testing.expectEqualStrings(doc_str, mw.doc orelse return error.TestExpectedDoc);
    try testing.expectEqualStrings(file_str, mw.source_file orelse return error.TestExpectedSourceFile);
    try testing.expectEqual(@as(usize, 12), mw.source_line);
    try testing.expectEqual(@as(usize, 4), mw.source_column);
    const prov = mw.provenance orelse return error.TestExpectedProvenance;
    try testing.expectEqualStrings(gen_str, prov.generator);
    try testing.expectEqualStrings(parent_str, prov.parent);
    try testing.expectEqualStrings(role_str, prov.role);
}

test "loadIntoContext: absent diagnostic metadata leaves ModuleWord fields null" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const w_name = "bare";
    const m_name = "demo";
    const words = [_]Word{wordRow(w_name, 0, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;

    try loadIntoContext(&ctx, &header, .{}, null);

    const entry = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const mw = entry.module.words.get(w_name) orelse return error.TestExpectedWord;
    try testing.expect(mw.doc == null);
    try testing.expect(mw.source_file == null);
    try testing.expectEqual(@as(usize, 0), mw.source_line);
    try testing.expectEqual(@as(usize, 0), mw.source_column);
    try testing.expect(mw.provenance == null);
}
