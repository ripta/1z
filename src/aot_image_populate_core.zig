//! Context-free core of the runtime-image descriptor rehydration.
//!
//! The C-layout mirrors of the emitted image tables, the decode helpers over them, and the shared
//! `SlotPopulateCore` walk. Both the hosted loader (`aot_image_loader.zig`) and the freestanding
//! runtime (`capi_freestanding.zig`) consume this module; it must stay free of `context.zig` and
//! the other hosted-runtime imports.
//!
//! The struct layouts here MUST match the C declarations emitted by `emitTypeDeclarations`.
//!
//! Field order, types, and padding are all part of the contract. Drift on either side breaks the
//! loader silently. 😥

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const stack_effect_mod = @import("stack_effect.zig");

/// Errors the loader can surface.
///
/// The C-side caller maps these to `ONEZ_ERR_LOAD_FAILED` and uses the runtime's error surface
/// for the human-readable message.
pub const LoaderError = error{
    UnsupportedFormat,
    BadSlotIndex,
    BadWordIndex,
    BadStackEffectIndex,
    BadTypeKind,
    BadStructTypeIndex,
    OutOfMemory,
};

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
    /// `annotation_kind` values, mirroring the C declaration.
    pub const annotation_none: u8 = 0;
    pub const annotation_type: u8 = 1;
    pub const annotation_protocol: u8 = 2;
    pub const annotation_combinator: u8 = 3;

    name: [*]const u8,
    name_len: u32,
    is_row_variable: u8,

    /// Discriminates which slot table `annotation_slot` indexes:
    ///
    ///     0 = no annotation
    ///     1 = typevalue slots (1-based; 0 doubles as a lookup miss)
    ///     2 = protocol descriptor slots (0-based)
    ///     3 = constraint combinator slots (0-based)
    annotation_kind: u8,
    has_quotation_effect: u8,
    _reserved: u8,
    annotation_slot: u32,
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

/// Zig mirror of the C `onez_image_enum_variant_t` row.
///
/// The loader walks these to materialize `value_mod.Variant` records inside an `EnumData.variants`
/// slice. The variant's `type_slot` indexes the runtime slot table (0 = no inner type).
pub const EnumVariant = extern struct {
    name: [*]const u8,
    name_len: u32,
    type_slot: u32,
};

/// Zig mirror of `onez_image_struct_type_t`.
///
/// One row per `StructType` referenced by a struct-backed virtual type's `anon_struct`.
/// Allocated separately from `TypeValue`s because the anonymous struct is not itself a first-class TypeValue.
pub const StructType = extern struct {
    name: [*]const u8,
    name_len: u32,
    field_names: ?[*]const [*]const u8,
    field_name_lens: ?[*]const u32,
    field_count: u32,
    field_type_slots: ?[*]const u32,
    field_type_count: u32,
};

/// Zig mirror of `onez_image_typedescriptor_t`.
///
/// Layout must stay in lockstep with the C struct emitted in `aot_image_emit.emitTypeDeclarations`.
/// Fields not relevant to a given `kind` are zero-initialized at emit time and the loader ignores them.
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
    type_param_position: u32,
};

/// Zig mirror of `onez_image_typevalue_t`.
///
/// One row per slot in `onez_image_typevalue_slots[]`. `slot` matches the row's index in the slot
/// table and is used to anchor the loader's slot-table patching pass.
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

/// Zig mirror of `onez_image_marker_description_t`.
///
/// One row per slot in `onez_image_marker_slots[]`. The loader resolves the name to either a well-
/// known marker singleton or a freshly-allocated `*Marker`, then patches `onez_image_marker_slots[slot]`
/// with the resolved pointer.
pub const MarkerDescription = extern struct {
    name: [*]const u8,
    name_len: u32,
    slot: u32,
};

/// Zig mirror of `onez_image_parameter_description_t`.
///
/// One row per slot in `onez_image_parameter_slots[]`.
///
/// The loader deserializes the default-quotation bytecode, allocates a `*Parameter`, and patches
/// the matching slot.
pub const ParameterDescription = extern struct {
    name: [*]const u8,
    name_len: u32,
    slot: u32,
    default_quotation_bytecode: ?[*]const u8,
    default_quotation_bytecode_len: u32,
};

/// Zig mirror of `onez_image_tagged_description_t`.
///
/// One row per slot in `onez_image_tagged_slots[]`. The loader recovers the tag's
/// `*const VirtualType` through `tag_typevalue_slot` (reading `typevalues[slot].virtual_type`),
/// deserializes the inner Value via `instruction_bytecode.deserializeValueAtForImage`, allocates
/// a runtime `*const Value` carrying `.tagged`, and patches the matching slot.
pub const TaggedDescription = extern struct {
    name: [*]const u8,
    name_len: u32,
    slot: u32,
    tag_typevalue_slot: u32,
    inner_bytecode: ?[*]const u8,
    inner_bytecode_len: u32,
};

/// Zig mirror of `onez_image_mutable_map_description_t`.
///
/// One row per slot in `onez_image_mutable_map_slots[]`. The loader allocates a fresh
/// `*MutableMap`, decodes the entries via `instruction_bytecode.deserializeValueAtForImage`,
/// populates the map, and patches the slot.
pub const MutableMapDescription = extern struct {
    slot: u32,
    entries_bytecode: ?[*]const u8,
    entries_bytecode_len: u32,
};

/// Zig mirror of `onez_image_struct_instance_description_t`.
///
/// One row per slot in `onez_image_struct_instance_slots[]`. The loader allocates a fresh
/// `*StructInstance` whose `struct_type` is taken from
/// `onez_image_struct_type_slots[struct_type_slot]`, decodes the field values from
/// `fields_bytecode` via `instruction_bytecode.deserializeValueAtForImage`, and patches the slot.
pub const StructInstanceDescription = extern struct {
    slot: u32,
    struct_type_slot: u32,
    fields_bytecode: ?[*]const u8,
    fields_bytecode_len: u32,
};

/// Zig mirror of `onez_image_vector_description_t`.
///
/// One row per slot in `onez_image_vector_slots[]`. The loader allocates a fresh empty `*Vector`,
/// decodes the element values from `elements_bytecode` (a `u32` count followed by each element),
/// and patches the slot.
pub const VectorDescription = extern struct {
    slot: u32,
    elements_bytecode: ?[*]const u8,
    elements_bytecode_len: u32,
};

/// Zig mirror of `onez_image_protocol_method_t`.
///
/// One required method of a protocol. `stack_effect_idx` indexes the image's stack-effect table
/// and 0 means the method has no declared effect.
pub const ProtocolMethod = extern struct {
    name: [*]const u8,
    name_len: u32,
    stack_effect_idx: u32,
};

/// Zig mirror of `onez_image_protocoldescriptor_description_t`.
///
/// One row per slot in `onez_image_protocoldescriptor_slots[]`. The loader reuses a same-named
/// protocol from the runtime context when one exists, otherwise reconstructs the descriptor from
/// these fields, and patches the slot.
pub const ProtocolDescriptorDescription = extern struct {
    name: [*]const u8,
    name_len: u32,
    slot: u32,
    protocol_id: u32,
    method_count: u32,
    methods: ?[*]const ProtocolMethod,
};

/// Zig mirror of `onez_image_combinator_element_t`.
///
/// One element of a constraint combinator. `kind` picks the slot-numbering convention for `slot`:
///
///     1 = 1-based typevalue slot
///     2 = 0-based protocol descriptor slot
///     3 = 0-based combinator slot
pub const CombinatorElement = extern struct {
    kind: u32,
    slot: u32,
};

/// Zig mirror of `onez_image_constraintcombinator_description_t`.
///
/// One row per slot in `onez_image_constraintcombinator_slots[]`. The loader rebuilds the
/// descriptor from `kind` (0 = intersection, 1 = union), the element list, and the preserved
/// `combinator_id`, then patches the slot.
pub const ConstraintCombinatorDescription = extern struct {
    slot: u32,
    combinator_id: u32,
    kind: u32,
    element_count: u32,
    elements: ?[*]const CombinatorElement,
};

/// Reserved type-slot sentinels in a dispatch-entry row, mirroring the `ONEZ_DISPATCH_TYPE_*` C
/// macros.
///
/// A real type references the 1-based typevalue slot table; these stand in for the dispatch keys'
/// synthetic sentinel descriptors, which carry no typevalue slot.
pub const dispatch_type_unary: u32 = 0xFFFFFFFF;
pub const dispatch_type_any: u32 = 0xFFFFFFFE;

/// Reserved `quotation_id` in a dispatch-entry row marking an interpreter-run body: the method
/// never compiled, so the row carries `body_bytecode` instead of a quotation-table index.
pub const dispatch_interp_quotation_id_sentinel: u32 = 0xFFFFFFFF;

/// Zig mirror of `onez_image_dispatch_entry_description_t`.
///
/// One row per reachable user `.quotation` method dispatch entry. The loader resolves
/// `type_a_slot` / `type_b_slot` through the typevalue slot table (or the reserved sentinels
/// above), the body through the quotation-function table by `quotation_id`, and the defining
/// module by name, then replays the entry into `ctx.dispatch`.
pub const DispatchEntryDescription = extern struct {
    dispatch_id: u32,
    type_a_slot: u32,
    type_b_slot: u32,
    quotation_id: u32,
    module_name: ?[*]const u8,
    module_name_len: u32,
    generic_name: ?[*]const u8,
    generic_name_len: u32,

    /// Interpreter-run method body bytecode for a body that did not compile to a native function,
    /// or null when the body compiled (resolved through the quotation-function table by
    /// `quotation_id` instead).
    body_bytecode: ?[*]const u8,
    body_bytecode_len: u32,
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
    struct_instance_slot_count: u32,
    vector_slot_count: u32,
    protocoldescriptor_slot_count: u32,
    constraintcombinator_slot_count: u32,
    dispatch_entry_slot_count: u32,
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
    struct_instance_descriptions: ?[*]const StructInstanceDescription,
    vector_descriptions: ?[*]const VectorDescription,
    protocoldescriptor_descriptions: ?[*]const ProtocolDescriptorDescription,
    constraintcombinator_descriptions: ?[*]const ConstraintCombinatorDescription,
    dispatch_entry_descriptions: ?[*]const DispatchEntryDescription,
};

/// Slot table type matching the C declaration:
///
///     const struct onez_typevalue *onez_image_typevalue_slots[N]
///
/// `const` qualifies the pointee (an opaque TypeValue), not the array elements -- the elements
/// are writable, which is what lets the loader patch them at startup.
pub const SlotTable = [*]?*const value_mod.TypeValue;

/// Slot table for StructType pointers, mirroring `SlotTable` for the runtime `*StructType`
/// allocations the loader produces from `onez_image_struct_types_storage[]`.
///
/// The C declaration is:
///
///     struct onez_struct_type *onez_image_struct_type_slots[N]
///
/// `struct onez_struct_type` is an opaque type at the C level; the loader patches each slot with
/// the runtime `*value_mod.StructType` address allocated in
/// `SlotPopulateCore.populateTypeValueSlots` Pass 1.
pub const StructTypeSlotTable = [*]?*value_mod.StructType;

/// Slot table for Marker pointers.
///
/// The runtime allocates markers as part of `populateModulesAndWords` and patches each slot with
/// the canonical runtime pointer. `null` when no marker slots were emitted.
pub const MarkerSlotTable = [*]?*value_mod.Marker;

/// Slot table for Parameter pointers.
///
/// Parameter binding state is mutable; the loader allocates the runtime Parameter row and patches
/// each slot accordingly.
pub const ParameterSlotTable = [*]?*value_mod.Parameter;

/// Slot table for `.tagged` Value pointers.
///
/// Each entry is allocated on the context arena by the loader: an inner Value plus a wrapping
/// Value carrying `.tagged = .{ .tag = vt, .inner = inner_ptr }`. The codegen-side push helper
/// reads through this slot table to recover the freeze-time tagged identity at runtime.
pub const TaggedSlotTable = [*]?*const value_mod.Value;

/// Slot table for `.mutable_map` pointers.
///
/// Each entry is allocated by the loader via `MutableMap.create`; the entries are populated from
/// the matching description row's bytecode. The compiled-code helper retains the pointer before
/// pushing so the cache's strong reference is preserved.
pub const MutableMapSlotTable = [*]?*value_mod.MutableMap;

/// Slot table for `.struct_instance` pointers.
///
/// Each entry is allocated by the loader via `createStructInstance` with its field vector sized
/// from the owning StructType; the fields are populated from the matching description row's
/// bytecode. The compiled-code helper retains the instance header before pushing so the cache's
/// strong reference is preserved.
pub const StructInstanceSlotTable = [*]?*value_mod.StructInstance;

/// Slot table for `.vector` pointers.
///
/// Each entry is allocated by the loader via `Vector.create(arena)`; elements are populated from
/// the matching description row's bytecode. The compiled-code helper retains the pointer before
/// pushing so the cache's strong reference is preserved.
pub const VectorSlotTable = [*]?*value_mod.Vector;

/// Slot table for `*ProtocolDescriptor` pointers at protocol-bounded call sites.
///
/// Each slot is populated by the loader: a same-named protocol from the runtime context's
/// registry when one exists, a descriptor reconstructed from the description row otherwise. Null
/// when no bounded sites were emitted (zero-slot count).
pub const ProtocolDescriptorSlotTable = [*]?*const value_mod.ProtocolDescriptor;

/// Slot table for `*ConstraintCombinator` pointers reached from `.combination` annotations.
///
/// Each slot is populated by the loader with a combinator reconstructed from its description row.
/// Null when no combinators were emitted (zero-slot count).
pub const ConstraintCombinatorSlotTable = [*]?*const value_mod.ConstraintCombinator;

/// All loader-populated slot tables, passed together so the `loadIntoContext` signature stays
/// compact as new tables land.
///
/// Any individual field may be null when its corresponding C symbol was not emitted (zero-slot
/// count).
pub const SlotTables = struct {
    typevalues: ?SlotTable = null,
    struct_types: ?StructTypeSlotTable = null,
    markers: ?MarkerSlotTable = null,
    parameters: ?ParameterSlotTable = null,
    tagged: ?TaggedSlotTable = null,
    mutable_maps: ?MutableMapSlotTable = null,
    struct_instances: ?StructInstanceSlotTable = null,
    vectors: ?VectorSlotTable = null,
    protocol_descriptors: ?ProtocolDescriptorSlotTable = null,
    constraint_combinators: ?ConstraintCombinatorSlotTable = null,
};

// -- Decode helpers ------------------------------------------------------

pub fn nameSlice(ptr: [*]const u8, len: u32) []const u8 {
    return ptr[0..len];
}

pub fn lookupSlot(
    slots: ?SlotTable,
    slot_count: u32,
    slot_index: u32,
) LoaderError!?*const value_mod.TypeValue {
    if (slot_index == 0) return null;
    if (slot_index >= slot_count) return LoaderError.BadSlotIndex;
    const slot_table = slots orelse return null;
    return slot_table[slot_index];
}

/// Resolve a stack-effect index against the image's effect table and produce a runtime
/// `StackEffect` allocated in the arena.
///
/// Protocol annotations resolve through `protocol_slots` (populated before any word decoding
/// runs); a null table or a not-yet-patched slot leaves the annotation unrestored rather than
/// failing the load, which covers self- and forward-references while
/// `populateProtocolDescriptorSlots` is still patching the table.
pub fn decodeStackEffect(
    arena: Allocator,
    header: *const Header,
    effect_idx: u32,
    protocol_slots: ?ProtocolDescriptorSlotTable,
) LoaderError!?stack_effect_mod.StackEffect {
    if (effect_idx == 0) return null;
    if (effect_idx >= header.stack_effect_count) return LoaderError.BadStackEffectIndex;
    const effects = header.stack_effects orelse return LoaderError.BadStackEffectIndex;
    const eff = effects[effect_idx];

    const inputs = try decodeStackEffectParams(arena, header, eff.inputs, eff.input_count, protocol_slots);
    const outputs = try decodeStackEffectParams(arena, header, eff.outputs, eff.output_count, protocol_slots);
    return stack_effect_mod.StackEffect{
        .inputs = inputs,
        .outputs = outputs,
    };
}

fn decodeStackEffectParams(
    arena: Allocator,
    header: *const Header,
    src: ?[*]const StackEffectParam,
    count: u32,
    protocol_slots: ?ProtocolDescriptorSlotTable,
) LoaderError![]const stack_effect_mod.StackEffectParam {
    if (count == 0 or src == null) return &.{};
    const ptr = src.?;
    const out = arena.alloc(stack_effect_mod.StackEffectParam, count) catch
        return LoaderError.OutOfMemory;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const ip = ptr[i];
        const annotation: ?stack_effect_mod.TypeAnnotation = switch (ip.annotation_kind) {
            // TypeValue annotations are deferred to future fidelity
            // work; the row carries the slot index, but restoring it
            // needs the typevalue slot table patched before word
            // decoding, which the loader does not yet guarantee.
            StackEffectParam.annotation_type => null,
            StackEffectParam.annotation_protocol => blk: {
                if (ip.annotation_slot >= header.protocoldescriptor_slot_count)
                    return LoaderError.BadSlotIndex;
                const table = protocol_slots orelse break :blk null;
                const pd = table[ip.annotation_slot] orelse break :blk null;
                break :blk .{ .protocol = pd };
            },
            // Combinator annotations are deferred to future fidelity work:
            // the combinator slot table populates after typevalue slots, which
            // are themselves patched after word decoding, so the descriptor is
            // not yet available here. The row carries the slot index; the slot
            // table is still populated for the dispatch helper to consult.
            StackEffectParam.annotation_combinator => blk: {
                if (ip.annotation_slot >= header.constraintcombinator_slot_count)
                    return LoaderError.BadSlotIndex;
                break :blk null;
            },
            else => null,
        };
        out[i] = .{
            .name = nameSlice(ip.name, ip.name_len),
            .is_row_variable = ip.is_row_variable != 0,
            // Quotation-effect restoration is deferred to future
            // fidelity work; the row carries the effect index only.
            .quotation_effect = null,
            .type_annotation = annotation,
        };
    }
    return out;
}

/// Decode a TypeKindData payload from one typedescriptor row.
///
/// Cross-references resolve through the slot table populated by pass 2; an out-of-range slot
/// index returns `BadSlotIndex`. The kind field is treated as a closed vocabulary; an
/// unrecognized kind value returns `BadTypeKind`.
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
                .field_types = try decodeOptionalTypeElements(
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
        5 => blk: {
            const anon_struct: ?*value_mod.StructType = if (drow.anon_struct_idx == anon_struct_absent)
                null
            else if (drow.anon_struct_idx < struct_types_out.len)
                struct_types_out[drow.anon_struct_idx]
            else
                return LoaderError.BadStructTypeIndex;
            break :blk .{
                .enum_variant = .{
                    .parent = try lookupSlot(slots, header.typevalue_slot_count, drow.parent_type_slot),
                    .inner_type = try lookupSlot(slots, header.typevalue_slot_count, drow.inner_type_slot),
                    .anon_struct = anon_struct,
                },
            };
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
        9 => .{ .type_parameter = .{ .position = drow.type_param_position } },
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

/// Decode struct field constraints.
///
/// The AOT image currently serializes only concrete-type field constraints, so each decoded slot
/// wraps into a `.type` combinator element; a null slot is an unannotated field.
fn decodeOptionalTypeElements(
    arena: Allocator,
    slots: ?SlotTable,
    slot_count: u32,
    slot_array: ?[*]const u32,
    count: u32,
) LoaderError![]const ?value_mod.ConstraintCombinator.Element {
    if (count == 0 or slot_array == null) return &.{};
    const sp = slot_array.?;
    const out = arena.alloc(?value_mod.ConstraintCombinator.Element, count) catch
        return LoaderError.OutOfMemory;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        out[i] = if (try lookupSlot(slots, slot_count, sp[i])) |tv|
            .{ .type = tv }
        else
            null;
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

// -- Shared slot population core -----------------------------------------

/// Shared walk that materializes descriptor instances and patches slot tables.
///
/// Both runtimes instantiate it over their own environment. The hosted shell layers prelude
/// reuse, id-counter advancement, the enum variant registry, and word-body rewriting on top. The
/// freestanding shell has no prelude and no registries, so its reuse lookups always miss and its
/// create hooks only allocate.
///
/// The environment must provide:
///
/// - `allocator() Allocator` for allocations that live as long as the loaded image
/// - `lookupTypeValueByName(name: []const u8) ?*TypeValue`,
///   `lookupEnumVariantTypeValueByName(name: []const u8) ?*TypeValue`, and
///   `lookupStructTypeByName(name: []const u8) ?*StructType` reuse hooks; returning null makes
///   every row materialize fresh
/// - `lookupProtocolByName(name: []const u8) ?*ProtocolDescriptor`
/// - `createProtocolDescriptor(name, methods, protocol_id)` and
///   `createConstraintCombinator(kind, elements, combinator_id)`, each returning `LoaderError!*`
///   of its descriptor type and owning both registration and preservation of the build-time id
pub fn SlotPopulateCore(comptime Env: type) type {
    return struct {
        /// The pass-1/2 materialization arrays, index-aligned with `header.struct_types` and
        /// `header.typevalues`.
        ///
        /// The hosted shell's enum-registry and word-rewrite passes consume them; the
        /// freestanding shell ignores them.
        pub const TypeValueSlotResult = struct {
            struct_types: []*value_mod.StructType,
            type_values: []*value_mod.TypeValue,
            reused: []bool,
        };

        /// Walk the typevalue + typedescriptor + struct-type tables and allocate live runtime
        /// instances for each row. Passes:
        ///
        ///   1. Allocate `*StructType` for each onez_image_struct_type_t.
        ///   2. Allocate `*TypeValue` (with a zero-init `*TypeDescriptor`) for each
        ///      onez_image_typevalue_t, patching the slot table so cross-references in pass 3
        ///      can resolve through it.
        ///   3. Walk the typedescriptor table in lockstep with the typevalue table; populate
        ///      kind-specific data using the slot table.
        ///   3.5. Link each runtime TypeValue back to its peer aggregate (StructType `type_val`,
        ///      VirtualType both directions).
        ///
        /// Pass 2 allocates TypeValues before their descriptors are populated. That ordering
        /// matters: it lets pass 3 resolve descriptor cross-references through the slot table for
        /// TypeValues that have not yet had their descriptors filled in (only the pointer
        /// identity is required, not the descriptor contents).
        pub fn populateTypeValueSlots(
            env: Env,
            header: *const Header,
            slots: ?SlotTable,
            struct_type_slots: ?StructTypeSlotTable,
        ) LoaderError!TypeValueSlotResult {
            const empty = TypeValueSlotResult{
                .struct_types = &.{},
                .type_values = &.{},
                .reused = &.{},
            };
            if (header.typevalue_count == 0 and header.struct_type_count == 0) {
                return empty;
            }
            const arena = env.allocator();

            // Pass 1: allocate runtime StructTypes and patch the struct-type
            // slot table so codegen-emitted slot-indexed pushes can resolve
            // through it. The slot index matches the row's position in
            // `onez_image_struct_types_storage[]`, mirroring the typevalue
            // slot-table contract.
            //
            // If a StructType with the same name is already known to the
            // environment (e.g., allocated by `loadPrelude` on the hosted
            // runtime), reuse it so prelude-interpreted code and
            // AOT-compiled code share the same identity.
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
                        if (env.lookupTypeValueByName(name)) |tv| {
                            const desc = tv.descriptor orelse break :blk null;
                            switch (desc.kind) {
                                .struct_ => {
                                    if (tv.virtual_type) |vt| {
                                        if (vt.anon_struct) |as| break :blk @constCast(as);
                                    }
                                    // A plain `struct{` carries no pointer to its StructType, so we gotta
                                    // recover the interpreter's canonical StructType by name.
                                    //
                                    // Reusing it keeps a single StructType shared between interpreter-defined
                                    // and compiled-construction instances, so that struct dispatch resolves
                                    // identically.
                                    if (env.lookupStructTypeByName(name)) |reused| break :blk reused;
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
            // TypeValue with the same name is already known to the
            // environment (e.g. allocated by `loadPrelude`), reuse it so
            // identity stays single-sourced. Without this, prelude-
            // interpreted code keeps pointing at the prelude allocation
            // while AOT-compiled code would route through a fresh loader
            // allocation, splitting the identity surface that dispatch
            // table lookups and predicate checks key on.
            const tv_count = header.typevalue_count;
            if (tv_count == 0) return .{
                .struct_types = struct_types_out,
                .type_values = &.{},
                .reused = &.{},
            };
            const tv_rows = header.typevalues orelse return LoaderError.OutOfMemory;
            const tv_out = arena.alloc(*value_mod.TypeValue, tv_count) catch
                return LoaderError.OutOfMemory;
            const tv_reused = arena.alloc(bool, tv_count) catch
                return LoaderError.OutOfMemory;
            const desc_rows_p2 = header.typedescriptors orelse return LoaderError.OutOfMemory;
            {
                var i: u32 = 0;
                while (i < tv_count) : (i += 1) {
                    const row = tv_rows[i];
                    if (row.slot == 0 or row.slot >= header.typevalue_slot_count) {
                        return LoaderError.BadSlotIndex;
                    }
                    const name = nameSlice(row.name, row.name_len);
                    // Type-parameter TypeValues are per-definition and non-interned: two
                    // definitions each minting `T` are distinct pointers. Bypass the
                    // reuse-by-name dedup so they are always allocated fresh, with
                    // identity carried solely by the slot table.
                    const is_type_param = desc_rows_p2[i].kind == 9;
                    const existing = if (is_type_param)
                        null
                    else
                        env.lookupTypeValueByName(name) orelse
                            env.lookupEnumVariantTypeValueByName(name);
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
                                    // The runtime StructType is allocated in Pass 1 with
                                    // empty field_types; copy the decoded field types
                                    // from the descriptor so field-typed validation (e.g.
                                    // an enum variant payload) sees the parameter slots.
                                    if (st.field_types.len == 0)
                                        st.field_types = desc.kind.struct_.field_types;
                                    break;
                                }
                            }
                            // Reconstruct the declared type-parameter projection from the
                            // decoded field types, mirroring the interpreter's
                            // `deriveStructTypeParams`. Done here (not in `decodeKindData`)
                            // so every referenced parameter row has its descriptor
                            // populated; `isTypeParameter` reads that kind.
                            desc.kind.struct_.type_params =
                                value_mod.deriveStructTypeParams(arena, desc.kind.struct_.field_types) catch
                                    return LoaderError.OutOfMemory;
                        },
                        .enum_ => {
                            // Reconstruct the enum-level type-parameter projection from
                            // the variants' payload TypeValues (each a virtual carrying
                            // the parameters it binds), mirroring `deriveEnumTypeParams`.
                            const variants = desc.kind.enum_.variants;
                            var variant_tvs = std.ArrayListUnmanaged(*const value_mod.TypeValue){};
                            defer variant_tvs.deinit(arena);
                            for (variants) |v| {
                                if (v.type_val) |vtv| variant_tvs.append(arena, vtv) catch
                                    return LoaderError.OutOfMemory;
                            }
                            desc.kind.enum_.type_params =
                                value_mod.deriveEnumTypeParams(arena, variant_tvs.items) catch
                                    return LoaderError.OutOfMemory;
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
                            // A parameterized wrapper's descriptor stores its base type as
                            // `inner_type` and a non-empty `type_params`; the enum/struct
                            // instantiation wrap needs the base link on the runtime
                            // VirtualType. A plain virtual newtype has empty type_params and
                            // no base.
                            const base_type: ?*const value_mod.TypeValue =
                                if (vdata.type_params.len > 0) vdata.inner_type else null;
                            vt.* = .{
                                .name = tv.name,
                                .inner_type = inner_name,
                                .anon_struct = vdata.anon_struct,
                                .base_type = base_type,
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
                            const inner_name: []const u8 = if (evdata.anon_struct != null)
                                tv.name
                            else if (evdata.inner_type) |it|
                                it.name
                            else
                                "";
                            // Recover a parameterized variant's binding tuple from its
                            // base (`evdata.inner_type`, a virtual whose `type_params`
                            // are the enum parameters it binds), mirroring the
                            // define-time logic. The instantiation wrap needs it to
                            // validate the variant payload against the bound tuple.
                            const variant_type_params: ?[]*const value_mod.TypeValue = blk: {
                                const base = evdata.inner_type orelse break :blk null;
                                const base_desc = base.descriptor orelse break :blk null;
                                const src = switch (base_desc.kind) {
                                    .virtual => |vd| vd.type_params,
                                    else => break :blk null,
                                };
                                if (src.len == 0) break :blk null;
                                const tp = arena.alloc(*const value_mod.TypeValue, src.len) catch
                                    return LoaderError.OutOfMemory;
                                for (src, 0..) |t, idx| tp[idx] = t;
                                break :blk tp;
                            };
                            const variant_base_type: ?*const value_mod.TypeValue =
                                if (variant_type_params != null) evdata.inner_type else null;
                            vt.* = .{
                                .name = tv.name,
                                .inner_type = inner_name,
                                .anon_struct = evdata.anon_struct,
                                .parent_type = evdata.parent,
                                .base_type = variant_base_type,
                                .type_params = variant_type_params,
                                .type_val = tv,
                            };
                            tv.virtual_type = vt;
                            // Unlike a struct-backed virtual's anonymous struct, an
                            // enum variant's payload is a named struct with its own
                            // TypeValue; the `.struct_` pass already links its
                            // `type_val`, so do not overwrite it here.
                        },
                        else => {},
                    }
                }
            }

            return .{
                .struct_types = struct_types_out,
                .type_values = tv_out,
                .reused = tv_reused,
            };
        }

        /// Walk the protocol descriptor description table and patch
        /// `onez_image_protocoldescriptor_slots[]`.
        ///
        /// A same-named protocol already known to the environment is reused so identity stays
        /// single-sourced, mirroring the TypeValue reuse in `populateTypeValueSlots`. Otherwise
        /// the descriptor is reconstructed from the row's serialized fields (name, methods with
        /// optional declared effects, protocol_id), so the slot pointer is the same pointer the
        /// satisfies-memo and introspection see.
        pub fn populateProtocolDescriptorSlots(
            env: Env,
            header: *const Header,
            slots: ?ProtocolDescriptorSlotTable,
        ) LoaderError!void {
            if (header.protocoldescriptor_slot_count == 0) return;
            const descs = header.protocoldescriptor_descriptions orelse return;
            const slot_table = slots orelse return;
            var i: u32 = 0;
            while (i < header.protocoldescriptor_slot_count) : (i += 1) {
                const row = descs[i];
                if (row.slot >= header.protocoldescriptor_slot_count) return LoaderError.BadSlotIndex;
                const name = nameSlice(row.name, row.name_len);
                const pd = env.lookupProtocolByName(name) orelse
                    try reconstructProtocolDescriptor(env, header, row, slots);
                slot_table[row.slot] = pd;
            }
        }

        /// Allocate a runtime ProtocolDescriptor from a description row.
        ///
        /// Method rows decode into the flat symbol/effect Value sequence the satisfies-check
        /// walks: one `.symbol` per method, followed by a `.stack_effect` when the row carries a
        /// non-zero effect index. Method name slices point directly at the binary's static C
        /// data.
        ///
        /// `protocol_slots` is the in-progress slot table: a method effect whose param references
        /// an already-patched slot restores its protocol annotation; a self- or forward-reference
        /// reads an unpatched slot and the annotation stays unrestored. No runtime consumer reads
        /// protocol annotations on protocol-method effects, so the partial restoration is
        /// acceptable.
        fn reconstructProtocolDescriptor(
            env: Env,
            header: *const Header,
            row: ProtocolDescriptorDescription,
            protocol_slots: ?ProtocolDescriptorSlotTable,
        ) LoaderError!*value_mod.ProtocolDescriptor {
            const arena = env.allocator();
            var methods: std.ArrayListUnmanaged(value_mod.Value) = .{};
            defer methods.deinit(arena);
            if (row.method_count > 0) {
                const method_rows = row.methods orelse return LoaderError.BadStackEffectIndex;
                var m: u32 = 0;
                while (m < row.method_count) : (m += 1) {
                    const method = method_rows[m];
                    methods.append(arena, .{ .symbol = nameSlice(method.name, method.name_len) }) catch
                        return LoaderError.OutOfMemory;
                    if (method.stack_effect_idx != 0) {
                        const effect = (try decodeStackEffect(arena, header, method.stack_effect_idx, protocol_slots)) orelse
                            return LoaderError.BadStackEffectIndex;
                        methods.append(arena, .{ .stack_effect = effect }) catch
                            return LoaderError.OutOfMemory;
                    }
                }
            }
            return env.createProtocolDescriptor(
                nameSlice(row.name, row.name_len),
                methods.items,
                row.protocol_id,
            );
        }

        /// Walk the constraint combinator description table and patch
        /// `onez_image_constraintcombinator_slots[]`.
        ///
        /// Rows are processed in ascending slot order; because combinators are interned
        /// post-order at freeze time, a row's nested-combinator elements live at lower slots
        /// already patched this pass. Combinators are anonymous, so there is no reuse-by-name --
        /// each row is reconstructed and registered.
        pub fn populateConstraintCombinatorSlots(
            env: Env,
            header: *const Header,
            slots: SlotTables,
        ) LoaderError!void {
            if (header.constraintcombinator_slot_count == 0) return;
            const descs = header.constraintcombinator_descriptions orelse return;
            const slot_table = slots.constraint_combinators orelse return;
            var i: u32 = 0;
            while (i < header.constraintcombinator_slot_count) : (i += 1) {
                const row = descs[i];
                if (row.slot >= header.constraintcombinator_slot_count) return LoaderError.BadSlotIndex;
                const cc = try reconstructConstraintCombinator(env, header, row, slots);
                slot_table[row.slot] = cc;
            }
        }

        /// Allocate a runtime ConstraintCombinator from a description row.
        ///
        /// Each element resolves through its slot table by kind: kind 1 reads the 1-based
        /// typevalue slot, kind 2 the 0-based protocol slot, kind 3 the 0-based combinator slot
        /// (a lower index already patched). The per-kind bounds checks reject a row that
        /// references a slot outside its table.
        fn reconstructConstraintCombinator(
            env: Env,
            header: *const Header,
            row: ConstraintCombinatorDescription,
            slots: SlotTables,
        ) LoaderError!*value_mod.ConstraintCombinator {
            const arena = env.allocator();
            const elements = arena.alloc(value_mod.ConstraintCombinator.Element, row.element_count) catch
                return LoaderError.OutOfMemory;
            if (row.element_count > 0) {
                const element_rows = row.elements orelse return LoaderError.BadSlotIndex;
                var e: u32 = 0;
                while (e < row.element_count) : (e += 1) {
                    const er = element_rows[e];
                    elements[e] = switch (er.kind) {
                        1 => blk: {
                            const table = slots.typevalues orelse return LoaderError.BadSlotIndex;
                            if (er.slot == 0 or er.slot >= header.typevalue_slot_count) return LoaderError.BadSlotIndex;
                            const tv = table[er.slot] orelse return LoaderError.BadSlotIndex;
                            break :blk .{ .type = tv };
                        },
                        2 => blk: {
                            const table = slots.protocol_descriptors orelse return LoaderError.BadSlotIndex;
                            if (er.slot >= header.protocoldescriptor_slot_count) return LoaderError.BadSlotIndex;
                            const pd = table[er.slot] orelse return LoaderError.BadSlotIndex;
                            break :blk .{ .protocol = pd };
                        },
                        3 => blk: {
                            const table = slots.constraint_combinators orelse return LoaderError.BadSlotIndex;
                            if (er.slot >= header.constraintcombinator_slot_count) return LoaderError.BadSlotIndex;
                            const nested = table[er.slot] orelse return LoaderError.BadSlotIndex;
                            break :blk .{ .combinator = nested };
                        },
                        else => return LoaderError.BadSlotIndex,
                    };
                }
            }
            const kind: value_mod.ConstraintCombinator.Kind = switch (row.kind) {
                0 => .intersection,
                1 => .@"union",
                else => return LoaderError.BadSlotIndex,
            };
            return env.createConstraintCombinator(kind, elements, row.combinator_id);
        }
    };
}
