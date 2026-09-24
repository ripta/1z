//! Runtime-image loader: rehydrates the AOT runtime image into a Context.
//!
//! Companion to `aot_image_emit.zig`. Walks the embedded `onez_image_v1`
//! header at startup, decodes the static C data tables (typevalues,
//! typedescriptors, struct types, modules, words, stack effects, markers)
//! into runtime Module/ModuleWord/TypeValue instances, and patches the
//! shared TypeValue slot table so PIC dispatch and stack-effect
//! annotations resolve to live pointers.
//!
//! The C-layout struct mirrors, the decode helpers over them, and the
//! shared slot-population walk live in `aot_image_populate_core.zig`,
//! which the freestanding runtime consumes as well; this file re-exports
//! them and layers the Context-only concerns on top.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const stack_effect_mod = @import("stack_effect.zig");
const aot_image_emit = @import("aot_image_emit.zig");
const instruction_bytecode = @import("instruction_bytecode.zig");
const container_backing = @import("container_backing.zig");
const populate_core = @import("aot_image_populate_core.zig");
const Context = @import("context.zig").Context;
const dispatch_mod = @import("dispatch.zig");
const dictionary_mod = @import("dictionary.zig");
const may_define = @import("may_define.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const markers_mod = @import("primitives/markers.zig");
const inline_expand = @import("inline_expand.zig");

/// The runtime run record, distinct from the image row `ImageInlineRegion` mirrors.
const InlineRegion = @import("inline_region_table.zig").InlineRegion;

pub const LoaderError = populate_core.LoaderError;

/// `classification` field values from `onez_image_word`.
const classification_structural: u8 = 0;
const classification_blob: u8 = 1;

// -- C-layout struct mirrors (defined in aot_image_populate_core.zig) ----

pub const Module = populate_core.Module;
pub const Marker = populate_core.Marker;
pub const StackEffectParam = populate_core.StackEffectParam;
pub const StackEffect = populate_core.StackEffect;
pub const Word = populate_core.Word;
pub const ImageInlineRegion = populate_core.InlineRegion;
pub const ImageInlineRegionSet = populate_core.InlineRegionSet;
pub const ImageNestedInlineRegionSet = populate_core.NestedInlineRegionSet;
pub const EnumVariant = populate_core.EnumVariant;
pub const StructType = populate_core.StructType;
pub const TypeDescriptor = populate_core.TypeDescriptor;
pub const TypeValueRow = populate_core.TypeValueRow;
pub const anon_struct_absent = populate_core.anon_struct_absent;
pub const MarkerDescription = populate_core.MarkerDescription;
pub const ParameterDescription = populate_core.ParameterDescription;
pub const TaggedDescription = populate_core.TaggedDescription;
pub const MutableMapDescription = populate_core.MutableMapDescription;
pub const MutableValueMapDescription = populate_core.MutableValueMapDescription;
pub const StructInstanceDescription = populate_core.StructInstanceDescription;
pub const VectorDescription = populate_core.VectorDescription;
pub const OnceCellDescription = populate_core.OnceCellDescription;
pub const ProtocolMethod = populate_core.ProtocolMethod;
pub const ProtocolDescriptorDescription = populate_core.ProtocolDescriptorDescription;
pub const CombinatorElement = populate_core.CombinatorElement;
pub const ConstraintCombinatorDescription = populate_core.ConstraintCombinatorDescription;
pub const dispatch_type_unary = populate_core.dispatch_type_unary;
pub const dispatch_type_any = populate_core.dispatch_type_any;
pub const DispatchEntryDescription = populate_core.DispatchEntryDescription;
pub const ModuleDep = populate_core.ModuleDep;
pub const EntryImport = populate_core.EntryImport;
pub const Header = populate_core.Header;

pub const SlotTable = populate_core.SlotTable;
pub const StructTypeSlotTable = populate_core.StructTypeSlotTable;
pub const MarkerSlotTable = populate_core.MarkerSlotTable;
pub const ParameterSlotTable = populate_core.ParameterSlotTable;
pub const TaggedSlotTable = populate_core.TaggedSlotTable;
pub const MutableMapSlotTable = populate_core.MutableMapSlotTable;
pub const MutableValueMapSlotTable = populate_core.MutableValueMapSlotTable;
pub const StructInstanceSlotTable = populate_core.StructInstanceSlotTable;
pub const VectorSlotTable = populate_core.VectorSlotTable;
pub const OnceCellSlotTable = populate_core.OnceCellSlotTable;
pub const ProtocolDescriptorSlotTable = populate_core.ProtocolDescriptorSlotTable;
pub const ConstraintCombinatorSlotTable = populate_core.ConstraintCombinatorSlotTable;
pub const SlotTables = populate_core.SlotTables;

const nameSlice = populate_core.nameSlice;
const lookupSlot = populate_core.lookupSlot;
const decodeStackEffect = populate_core.decodeStackEffect;

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

    // Load-scoped parking lot for value-map entries the decoder produces while container contents
    // are still placeholders. The Context only borrows it, so it has to outlive every pass below.
    //
    // The drain runs after `installPendingValueMapEntries` has emptied it, so on the success path it
    // finds nothing. On a failure path it releases the halves of every entry that never landed.
    var pending_value_map_entries: std.ArrayListUnmanaged(value_mod.PendingValueMapEntry) = .{};
    defer {
        drainPendingValueMapEntries(&pending_value_map_entries);
        pending_value_map_entries.deinit(ctx.allocator);
    }
    ctx.image_pending_value_map_entries = &pending_value_map_entries;
    defer ctx.image_pending_value_map_entries = null;

    // Protocol descriptor slots populate before word decoding so the
    // `.protocol` annotations in word stack effects resolve through the
    // patched table. The reverse dependency does not exist: protocol
    // reconstruction reads only the header's effect tables and the
    // runtime's pre-image protocol registry.
    try populateProtocolDescriptorSlots(ctx, header, slots.protocol_descriptors);
    try populateModulesAndWords(ctx, header, slots.protocol_descriptors);
    try populateTypeValueSlots(ctx, header, slots.typevalues, slots.struct_types);
    try populateMarkerSlots(ctx, header, slots.markers);
    try populateParameterSlots(ctx, header, slots.parameters);
    // Once cells populate beside parameters, for the same reason: a cell's body is serialized by
    // value, so it resolves against no other slot table.
    try populateOnceCellSlots(ctx, header, slots.once_cells);
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
    ctx.image_mutable_value_map_slots = slots.mutable_value_maps;
    ctx.image_mutable_value_map_slot_count = header.mutable_value_map_slot_count;
    ctx.image_struct_instance_slots = slots.struct_instances;
    ctx.image_struct_instance_slot_count = header.struct_instance_slot_count;
    ctx.image_vector_slots = slots.vectors;
    ctx.image_vector_slot_count = header.vector_slot_count;
    ctx.image_once_cell_slots = slots.once_cells;
    ctx.image_once_cell_slot_count = header.once_cell_slot_count;
    ctx.image_protocoldescriptor_slots = slots.protocol_descriptors;
    ctx.image_protocoldescriptor_slot_count = header.protocoldescriptor_slot_count;
    ctx.image_constraintcombinator_slots = slots.constraint_combinators;
    ctx.image_constraintcombinator_slot_count = header.constraintcombinator_slot_count;

    // Stash the method-dispatch replay table; the actual replay runs in
    // `replayMethodDispatch` after the quotation-function table is
    // registered, which happens after this loader pass.
    ctx.image_dispatch_entry_descriptions = @ptrCast(header.dispatch_entry_descriptions);
    ctx.image_dispatch_entry_count = header.dispatch_entry_slot_count;

    // Combinator slots populate after both protocol and typevalue slots are
    // patched: a `.type` element indexes the typevalue slot table, a
    // `.protocol` element indexes the protocol slot table, and a nested
    // combinator (interned post-order, so always a lower index) indexes a slot
    // already filled this pass.
    try populateConstraintCombinatorSlots(ctx, header, slots);

    // Struct-instance slots allocate before mutable-map entries decode: a
    // frozen mutable map may hold struct instances as values, so every
    // struct-instance pointer must be live before any entry that references
    // it is deserialized. Allocation only sizes each instance's field vector
    // and patches the slot; the fields themselves fill in after the
    // mutable-map slots exist, since a struct field may reference a map.
    try allocateStructInstanceSlots(ctx, header, slots.struct_instances);

    // Vector slots allocate alongside struct instances and before any
    // content decode: a frozen composite may hold a vector, so every vector
    // pointer must be live before an entry referencing it is deserialized.
    try allocateVectorSlots(ctx, header, slots.vectors);

    // Mutable-value-map slots allocate here too, so any other family's content decode can
    // reference one. Their entries decode last, after `populateTaggedSlots`, which is what lets an
    // entry hold a tagged slot reference at all; the mutable-map loader documents that as
    // unsupported precisely because it runs earlier.
    try allocateMutableValueMapSlots(ctx, header, slots.mutable_value_maps);

    // Mutable_map slots populate before tagged slots so a tagged
    // inner value carrying a `.mutable_map` resolves correctly.
    try populateMutableMapSlots(ctx, header, slots.mutable_maps);

    // Struct-instance fields decode after the mutable-map slots are live,
    // so a field that references a `.mutable_map` (or another struct
    // instance, already allocated above) resolves correctly.
    try populateStructInstanceFields(ctx, header, slots.struct_instances);

    // Vector elements decode after the other slot tables are live, so an
    // element that references a map, struct instance, or another vector
    // resolves through the already-patched slot tables.
    try populateVectorElements(ctx, header, slots.vectors);

    // Tagged slot population runs last because each row's inner
    // bytecode may reference the typevalue, struct-type, marker,
    // parameter, or mutable_map slot tables (recursive `.tagged.inner`
    // routes through `deserializeValueAtForImage`), so those tables
    // must be patched first.
    try populateTaggedSlots(ctx, header, slots.tagged);

    // Mutable-value-map entries decode once every other container is live, so an entry may hold a
    // reference into any of them, tagged slots included. It stays ahead of
    // `allocateCallTargetSlots` because only `emitWordBodyBytecode` supplies a `CallTargetResolver`,
    // so a container description never carries a baked call target.
    try populateMutableValueMapEntries(
        ctx,
        header,
        slots.mutable_value_maps,
        &pending_value_map_entries,
    );

    // Install every parked value-map entry, now that all contents are final and two keys are
    // distinguishable. Nothing above this point may probe a value-map decoded from the image.
    installPendingValueMapEntries(&pending_value_map_entries);

    // Detach the parking lot, so everything below inserts immediately. `decodeWordBodies` is the
    // one pass that still decodes an inline `value_map`, and its keys hash correctly because every
    // container they can reference is already final.
    ctx.image_pending_value_map_entries = null;

    // Mint the call-target slots before any body decodes, since a decoded `call_word_module`
    // instruction stores the slot address.
    //
    // Every decode above this point captures an `imageSlotTables` snapshot whose
    // `call_target_slots` is still null, so a baked target in a parameter default, a container
    // slot description, or a tagged inner value would fail to decode. Only `emitWordBodyBytecode`
    // supplies a `CallTargetResolver`, which is what keeps those streams free of the tag.
    try allocateCallTargetSlots(ctx, header);

    // Word bodies decode last: their slot-encoded literals (struct_type,
    // mutable_map, struct_instance, ...) resolve through the now-patched
    // slot tables.
    try decodeWordBodies(ctx, header);

    // Stamp every decoded body with its module once all bodies are final.
    //
    // The stamp is what lets a buried quotation inside an interpreter-run word body resolve its
    // bare words against its own module's scope instead of falling through to the module-cache
    // scan.
    try stampWordBodies(ctx, header);

    // Replay the inlined runs, so a raise inside one still names the `inline` word its code came
    // from.
    //
    // The table is keyed by the body's address, which only the decode above makes final.
    try recordInlineRegions(ctx, header);

    // Resolve the reified-quotation module table so `jitPushQuotation` can
    // stamp each decoded escaping-quotation body with its defining module.
    try populateReifiedQuotationModules(ctx, header);

    // Populate each module's import edges after every body is decoded and
    // stamped, so the dep copies carry final bodies. This must run before
    // `replayMethodDispatch` builds the deps-and-words frame templates.
    try populateModuleDeps(ctx, header);

    // Restore the entry file's `use` imports last, so the frame definitions
    // copy final decoded, stamped bodies.
    try populateEntryImports(ctx, header);

    // Fill the call-target slots now that every module's `words` and `deps` hold final bodies.
    try fillCallTargetSlots(ctx, header);
}

/// Build the slot-resolution tables for image-mode bytecode decoding from
/// the Context's patched slot-table pointers. Both the generated-word-body
/// pass and method-dispatch replay decode `.struct_type` (and other
/// type-carrier) literals against these.
fn imageSlotTables(ctx: *Context) instruction_bytecode.SlotResolutionTables {
    return .{
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
        .mutable_value_map_slots = ctx.image_mutable_value_map_slots,
        .mutable_value_map_slot_count = ctx.image_mutable_value_map_slot_count,
        .struct_instance_slots = ctx.image_struct_instance_slots,
        .struct_instance_slot_count = ctx.image_struct_instance_slot_count,
        .vector_slots = ctx.image_vector_slots,
        .vector_slot_count = ctx.image_vector_slot_count,
        .once_cell_slots = ctx.image_once_cell_slots,
        .once_cell_slot_count = ctx.image_once_cell_slot_count,
        .call_target_slots = ctx.image_call_target_slots,
        .call_target_slot_count = ctx.image_call_target_slot_count,
        // Compiled-quotation table (registered before image load, so available
        // here), so a quotation nested in a container slot value -- the lint
        // registry's `check` quotations -- decodes with its compiled code_ptr.
        .quotation_fns = if (ctx.aot_quotation_fns) |f| f.table[0..f.size] else null,
        // Ownership side channel: nested quotation streams whose operands
        // carry container literals register on the context release list so
        // their operand references drop at teardown.
        .decoded_streams = &ctx.container_release_list,
        .decoded_streams_allocator = ctx.allocator,
        // Parking side channel: a value-map's entries are held here until every population pass has
        // run, since a key cannot be hashed before the containers it references are final. Null
        // outside the population phase of the image load.
        .pending_value_map_entries = ctx.image_pending_value_map_entries,
        .pending_value_map_allocator = ctx.allocator,
    };
}

/// Decode every flagged word body and install it on the entry `populateModulesAndWords` left
/// empty. This pass runs after the slot tables are patched, so the image decoder can resolve
/// the slot-encoded literals and baked call targets a flagged body carries.
fn decodeWordBodies(ctx: *Context, header: *const Header) LoaderError!void {
    if (header.word_count == 0) return;
    const words = header.words orelse return;
    const modules = header.modules orelse return;
    const arena = ctx.quotationAllocator();

    const tables = imageSlotTables(ctx);

    var wi: u32 = 0;
    while (wi < header.word_count) : (wi += 1) {
        const w = words[wi];
        if (w.body_bytecode == null or w.body_bytecode_len == 0) continue;
        if (w.module_idx >= header.module_count) return LoaderError.BadWordIndex;
        // An unflagged row's body was already decoded during the initial population pass.
        if (w.flags & aot_image_emit.flag_bit_image_decode == 0) continue;

        const m = modules[w.module_idx];
        const module_name = nameSlice(m.name, m.name_len);
        const word_name = nameSlice(w.name, w.name_len);

        const cache_entry = ctx.module_cache_value.map.getPtr(module_name) orelse continue;
        if (cache_entry.* != .module) continue;
        // A same-named public word and private helper may coexist in one module, so the row's own
        // flag picks the map.
        const word_entry = if (w.flags & aot_image_emit.flag_bit_module_private != 0)
            cache_entry.*.module.deps.getPtr(word_name) orelse continue
        else
            cache_entry.*.module.words.getPtr(word_name) orelse continue;

        const bytes = w.body_bytecode.?[0..w.body_bytecode_len];
        var diag: instruction_bytecode.DecodeDiagnostic = undefined;
        const decoded = instruction_bytecode.deserializeQuotationInstructionsForImage(bytes, arena, &tables, &diag) catch |err| {
            reportDecodeFailure(ctx, &diag, err);
            return err;
        };
        ctx.registerQuotationContainerLiterals(decoded.instructions) catch return LoaderError.OutOfMemory;
        word_entry.action = .{ .compound = decoded.instructions };
    }
}

/// Body of a call-target slot between `allocateCallTargetSlots` and `fillCallTargetSlots`, and of
/// one the fill could not resolve. The emitter only writes a row for a word it found in the
/// manifest, so an unresolved slot means a corrupt image; raising at the call beats silently
/// running an empty body.
fn unresolvedCallTargetSentinel(_: *Context) anyerror!void {
    return error.UnknownWord;
}

/// Mint one `WordSlot` per call-target row, before any word body decodes.
///
/// The decoder writes the slot's address into each `call_word_module` instruction, so every
/// address must exist first and must not move afterwards. `fillCallTargetSlots` replaces the
/// definition through the box once the modules are final, leaving the address alone.
fn allocateCallTargetSlots(ctx: *Context, header: *const Header) LoaderError!void {
    if (header.call_target_count == 0) return;
    const rows = header.call_targets orelse return;
    const words = header.words orelse return;
    const arena = ctx.quotationAllocator();

    const slots = arena.alloc(?*dictionary_mod.WordSlot, header.call_target_count) catch
        return LoaderError.OutOfMemory;

    var i: u32 = 0;
    while (i < header.call_target_count) : (i += 1) {
        const word_idx = rows[i];
        if (word_idx >= header.word_count) return LoaderError.BadWordIndex;
        const name = nameSlice(words[word_idx].name, words[word_idx].name_len);
        slots[i] = dictionary_mod.createDetachedSlot(arena, name, .{
            .name = name,
            .action = .{ .native = unresolvedCallTargetSentinel },
        }) catch return LoaderError.OutOfMemory;
    }

    ctx.image_call_target_slots = slots.ptr;
    ctx.image_call_target_slot_count = header.call_target_count;
}

/// Fill each call-target slot with the definition its module scope resolves, matching what the
/// runtime's own-module probe would have synthesized for the same hit.
///
/// Runs after `populateModuleDeps`, so a target that is a `private{ }` helper or a `use`-imported
/// word is reachable. A row that cannot be resolved is skipped, the loader's convention for
/// module-name references, leaving the raising sentinel in place.
fn fillCallTargetSlots(ctx: *Context, header: *const Header) LoaderError!void {
    const slots = ctx.image_call_target_slots orelse return;
    const rows = header.call_targets orelse return;
    const words = header.words orelse return;
    const modules = header.modules orelse return;

    var i: u32 = 0;
    while (i < ctx.image_call_target_slot_count) : (i += 1) {
        const slot = slots[i] orelse continue;
        const w = words[rows[i]];
        if (w.module_idx >= header.module_count) return LoaderError.BadWordIndex;

        const m = modules[w.module_idx];
        const module_name = nameSlice(m.name, m.name_len);
        const word_name = nameSlice(w.name, w.name_len);

        const cached = ctx.module_cache_value.map.get(module_name) orelse continue;
        if (cached != .module) continue;

        const mw = if (w.flags & aot_image_emit.flag_bit_module_private != 0)
            cached.module.deps.get(word_name) orelse continue
        else
            cached.module.words.get(word_name) orelse continue;

        dictionary_mod.loadSlot(slot).* = Context.moduleScopeWordDef(word_name, mw, cached.module);
    }
}

/// Resolve each reified-quotation row's module name against the loaded module
/// cache and build the data-pointer-keyed table `jitPushQuotation` consults
/// when it decodes an escaping quotation. The map lives on the loader arena
/// for the life of the process and is shared by pointer with task contexts.
fn populateReifiedQuotationModules(ctx: *Context, header: *const Header) LoaderError!void {
    if (header.reified_quotation_module_count == 0) return;
    const rows = header.reified_quotation_modules orelse return;
    const arena = ctx.quotationAllocator();

    const map = arena.create(std.AutoHashMapUnmanaged(usize, *const value_mod.Module)) catch
        return LoaderError.OutOfMemory;
    map.* = .{};

    var i: u32 = 0;
    while (i < header.reified_quotation_module_count) : (i += 1) {
        const row = rows[i];
        const module_name = nameSlice(row.module_name, row.module_name_len);
        const cached = ctx.module_cache_value.map.get(module_name) orelse continue;
        if (cached != .module) continue;
        map.put(arena, @intFromPtr(row.data), cached.module) catch return LoaderError.OutOfMemory;
    }

    ctx.image_reified_quotation_modules = map;
}

/// Populate each image module's `deps` from the serialized import edges.
///
/// Each dep entry is a copy of the source module's word, so it carries the decoded body and the
/// source module as its `source_module`. A row whose source module or word cannot be resolved is
/// skipped, matching the loader's silent-miss convention for module-name references.
fn populateModuleDeps(ctx: *Context, header: *const Header) LoaderError!void {
    if (header.module_dep_count == 0) return;
    const rows = header.module_deps orelse return;
    const modules = header.modules orelse return;
    const arena = ctx.quotationAllocator();

    var i: u32 = 0;
    while (i < header.module_dep_count) : (i += 1) {
        const row = rows[i];
        if (row.module_idx >= header.module_count) return LoaderError.BadWordIndex;
        const owner_row = modules[row.module_idx];
        const owner_name = nameSlice(owner_row.name, owner_row.name_len);
        const owner_cached = ctx.module_cache_value.map.get(owner_name) orelse continue;
        if (owner_cached != .module) continue;

        const source_name = nameSlice(row.source_module_name, row.source_module_name_len);
        const source_cached = ctx.module_cache_value.map.get(source_name) orelse continue;
        if (source_cached != .module) continue;

        const name = nameSlice(row.name, row.name_len);
        const mw = source_cached.module.words.get(name) orelse continue;
        owner_cached.module.deps.put(arena, name, mw) catch return LoaderError.OutOfMemory;
    }
}

/// Restore the entry file's `use` imports into the durable entry frame, so an interpreted
/// entry-body call resolves them at the frame walk instead of the module-cache scan.
///
/// The frame itself is pushed by the generated `main` through `onez_push_entry_frame`, before any
/// image load and on every tier, so this pass only writes into it. The gate is
/// `image_entry_import_frame`, which only that push sets: a boot that never pushed skips the pass
/// rather than landing entry imports in whatever frame `import_frame_index` happens to name.
fn populateEntryImports(ctx: *Context, header: *const Header) LoaderError!void {
    if (header.entry_import_count == 0) return;
    const rows = header.entry_imports orelse return;
    if (ctx.image_entry_import_frame == null) return;

    var i: u32 = 0;
    while (i < header.entry_import_count) : (i += 1) {
        const row = rows[i];
        const source_name = nameSlice(row.source_module_name, row.source_module_name_len);
        const source_cached = ctx.module_cache_value.map.get(source_name) orelse continue;
        if (source_cached != .module) continue;

        const name = nameSlice(row.name, row.name_len);
        const mw = source_cached.module.words.get(name) orelse continue;
        ctx.defineImageEntryImport(name, mw, source_cached.module) catch return LoaderError.OutOfMemory;
    }
}

/// Record each image module as the defining module of its words' bodies and every quotation
/// literal nested inside them, mirroring what `nativeLoadImpl` does at interpreter module
/// finalization.
///
/// Runs as a post-pass because `decodeWordBodies` skips the majority of bodies -- those already
/// decoded inline in `populateModulesAndWords` -- and only here are all bodies final.
///
/// Iterates the header's modules so interpreter-loaded modules, already stamped at their own
/// load, are not re-walked.
fn stampWordBodies(ctx: *Context, header: *const Header) LoaderError!void {
    if (header.module_count == 0) return;
    const modules = header.modules orelse return;

    var module_i: u32 = 0;
    while (module_i < header.module_count) : (module_i += 1) {
        const m = modules[module_i];
        const module_name = nameSlice(m.name, m.name_len);

        const cache_entry = ctx.module_cache_value.map.get(module_name) orelse continue;
        if (cache_entry != .module) continue;
        const module_ptr = cache_entry.module;

        var word_it = module_ptr.words.valueIterator();
        while (word_it.next()) |mw| {
            if (mw.action != .compound) continue;
            ctx.stampQuotationBodies(mw.action.compound, module_ptr) catch
                return LoaderError.OutOfMemory;
        }

        // `deps` holds only the module's private helpers at this point, since `populateModuleDeps`
        // runs after this pass, so their bodies stamp with the owning module.
        var dep_it = module_ptr.deps.valueIterator();
        while (dep_it.next()) |mw| {
            if (mw.action != .compound) continue;
            ctx.stampQuotationBodies(mw.action.compound, module_ptr) catch
                return LoaderError.OutOfMemory;
        }
    }
}

/// Rebuild the inlined-run table over every decoded word body that carries runs.
///
/// The expansion pass fills that table from `defineWord`, which a body installed from the image
/// never reaches, so the runs travel in the image and are replayed here.
///
/// Runs after `decodeWordBodies`, the first point where every body is final and its address is the
/// one the error path will look up.
fn recordInlineRegions(ctx: *Context, header: *const Header) LoaderError!void {
    if (header.word_count == 0) return;
    const words = header.words orelse return;
    const modules = header.modules orelse return;

    var scratch: std.ArrayListUnmanaged(InlineRegion) = .{};
    defer scratch.deinit(ctx.allocator);

    var wi: u32 = 0;
    while (wi < header.word_count) : (wi += 1) {
        const w = words[wi];
        if (w.inline_regions == null and w.nested_inline_region_count == 0) continue;
        if (w.module_idx >= header.module_count) return LoaderError.BadWordIndex;

        const m = modules[w.module_idx];
        const module_name = nameSlice(m.name, m.name_len);
        const word_name = nameSlice(w.name, w.name_len);

        const cached = ctx.module_cache_value.map.get(module_name) orelse continue;
        if (cached != .module) continue;
        const mw = if (w.flags & aot_image_emit.flag_bit_module_private != 0)
            cached.module.deps.get(word_name) orelse continue
        else
            cached.module.words.get(word_name) orelse continue;
        const body = switch (mw.action) {
            .compound => |b| b,
            .native, .host_callback => continue,
        };

        if (w.inline_regions) |set| try replayRegionSet(ctx, &scratch, set.*, body);

        const nested = w.nested_inline_regions orelse continue;
        var ni: u32 = 0;
        while (ni < w.nested_inline_region_count) : (ni += 1) {
            const row = nested[ni];
            const path = row.path[0..row.path_len];
            const nested_body = nestedBodyAt(body, path) orelse return LoaderError.BadInlineRegion;
            try replayRegionSet(ctx, &scratch, row.set, nested_body);
        }
    }
}

/// The body `path` names inside `body`, or null when a step does not land on a quotation literal.
///
/// A path that misses is a corrupt image rather than a body the emitter chose not to describe, so
/// the caller fails the load on null.
fn nestedBodyAt(
    body: []const value_mod.Instruction,
    path: []const u32,
) ?[]const value_mod.Instruction {
    var at = body;
    for (path) |i| {
        if (i >= at.len) return null;
        const q = inline_expand.nestedQuotation(at[i].op) orelse return null;
        at = q.instructions;
    }
    return at;
}

/// Copy one image region set into the runtime table, keyed by the decoded body it describes.
fn replayRegionSet(
    ctx: *Context,
    scratch: *std.ArrayListUnmanaged(InlineRegion),
    set: ImageInlineRegionSet,
    body: []const value_mod.Instruction,
) LoaderError!void {
    scratch.clearRetainingCapacity();

    var ri: u32 = 0;
    while (ri < set.region_count) : (ri += 1) {
        const row = set.regions[ri];
        // A run naming instructions the body does not have is a corrupt image. Failing the load
        // beats booting a binary whose traces name the wrong word.
        if (row.start > row.end or row.end > body.len) return LoaderError.BadInlineRegion;
        scratch.append(ctx.allocator, .{
            .start = row.start,
            .end = row.end,
            .word_name = nameSlice(row.word_name, row.word_name_len),
            .body_source = nameSlice(row.body_source, row.body_source_len),
            .call_line = row.call_line,
            .call_column = row.call_column,
        }) catch return LoaderError.OutOfMemory;
    }

    const body_source = nameSlice(set.body_source, set.body_source_len);
    ctx.recordInlineRegions(body, body_source, scratch.items) catch return LoaderError.OutOfMemory;
}

/// Decode a word body through the by-value decoder during the initial population pass.
///
/// The emitter cleared `flag_bit_image_decode` on this row, so the stream is self-contained and
/// a failure is a real failure, not a routing signal.
fn decodeWordBodyInline(
    ctx: *Context,
    arena: Allocator,
    w: Word,
    qfns: ?[]const ?*const anyopaque,
) LoaderError![]const value_mod.Instruction {
    if (w.body_bytecode == null or w.body_bytecode_len == 0) return &.{};
    const bytes = w.body_bytecode.?[0..w.body_bytecode_len];
    var diag: instruction_bytecode.DecodeDiagnostic = undefined;
    const decoded = instruction_bytecode.deserializeQuotationInstructions(bytes, arena, qfns, &diag) catch |err| {
        reportDecodeFailure(ctx, &diag, err);
        return err;
    };
    return decoded.instructions;
}

// -- Module + word population ------------------------------------------

fn populateModulesAndWords(
    ctx: *Context,
    header: *const Header,
    protocol_slots: ?ProtocolDescriptorSlotTable,
) LoaderError!void {
    if (header.module_count == 0) return;
    const modules = header.modules orelse return;
    const words = header.words orelse return;
    const arena = ctx.quotationAllocator();
    const qfns: ?[]const ?*const anyopaque =
        if (ctx.aot_quotation_fns) |f| f.table[0..f.size] else null;

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
            const stack_effect = try decodeStackEffect(arena, header, w.stack_effect_idx, protocol_slots);
            // The flag routes each body to the decoder that can read it, so a failure here is a
            // real failure and propagates instead of installing a silent empty body.
            const body: []const value_mod.Instruction = if (w.flags & aot_image_emit.flag_bit_image_decode != 0)
                &.{}
            else
                try decodeWordBodyInline(ctx, arena, w, qfns);
            ctx.registerQuotationContainerLiterals(body) catch return LoaderError.OutOfMemory;
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
                .may_define = may_define.bodyCallsDefiningNative(body),
                .action = .{ .compound = body },
            };
            // A `private{ }` helper row goes into `deps`, not `words`. The public by-name surface
            // never sees it, since `lookupModuleCacheWordLocked` scans `words` only, while the
            // own-module probe and the module's deps frame still reach it.
            if (w.flags & aot_image_emit.flag_bit_module_private != 0) {
                module_ptr.deps.put(arena, word_name, mw) catch return LoaderError.OutOfMemory;
            } else {
                module_ptr.words.put(arena, word_name, mw) catch return LoaderError.OutOfMemory;
            }
        }

        const cache_alloc = ctx.module_cache_value.header.allocator;
        const name_owned = cache_alloc.dupe(u8, name) catch return LoaderError.OutOfMemory;
        ctx.module_cache_value.map.put(cache_alloc, name_owned, .{ .module = module_ptr }) catch
            return LoaderError.OutOfMemory;
    }
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
        const name = nameSlice(image_marker.name, image_marker.name_len);
        // Resolve well-known markers to their runtime singletons so
        // pointer-identity marker checks (e.g. `isGenericMarker`, which
        // gates interpreter generic dispatch) recognize them. A fresh
        // allocation here would compare unequal to every singleton,
        // silently disabling marker-driven behavior for loaded words.
        if (markers_mod.lookupWellKnownMarker(name)) |well_known| {
            out[i] = well_known;
        } else {
            const marker_ptr = arena.create(value_mod.Marker) catch return LoaderError.OutOfMemory;
            marker_ptr.* = .{ .name = name };
            out[i] = marker_ptr;
        }
    }
    return out;
}

// -- Shared slot population core -----------------------------------------

/// Hosted environment for `SlotPopulateCore`: reuse lookups hit the
/// prelude-populated Context registries, and the create hooks register on
/// the Context and advance its id counters past the build-time ids so
/// later runtime-created descriptors cannot collide.
const HostedPopulateEnv = struct {
    ctx: *Context,

    pub fn allocator(self: HostedPopulateEnv) Allocator {
        return self.ctx.quotationAllocator();
    }

    pub fn lookupTypeValueByName(self: HostedPopulateEnv, name: []const u8) ?*value_mod.TypeValue {
        return self.ctx.lookupTypeValueByName(name);
    }

    pub fn lookupEnumVariantTypeValueByName(self: HostedPopulateEnv, name: []const u8) ?*value_mod.TypeValue {
        return findEnumVariantTypeValueByName(self.ctx, name);
    }

    pub fn lookupStructTypeByName(self: HostedPopulateEnv, name: []const u8) ?*value_mod.StructType {
        return self.ctx.lookupStructTypeByName(name);
    }

    pub fn lookupProtocolByName(self: HostedPopulateEnv, name: []const u8) ?*value_mod.ProtocolDescriptor {
        for (self.ctx.protocol_descriptors.items) |pd| {
            if (std.mem.eql(u8, pd.name, name)) return pd;
        }
        return null;
    }

    pub fn createProtocolDescriptor(
        self: HostedPopulateEnv,
        name: []const u8,
        methods: []const value_mod.Value,
        protocol_id: u32,
    ) LoaderError!*value_mod.ProtocolDescriptor {
        const pd = self.ctx.createProtocolDescriptor(name, methods) catch
            return LoaderError.OutOfMemory;
        pd.protocol_id = protocol_id;
        _ = self.ctx.next_protocol_id.fetchMax(protocol_id + 1, .monotonic);
        return pd;
    }

    pub fn createConstraintCombinator(
        self: HostedPopulateEnv,
        kind: value_mod.ConstraintCombinator.Kind,
        elements: []const value_mod.ConstraintCombinator.Element,
        combinator_id: u32,
    ) LoaderError!*value_mod.ConstraintCombinator {
        const cc = self.ctx.createConstraintCombinator(kind, elements) catch
            return LoaderError.OutOfMemory;
        cc.combinator_id = combinator_id;
        _ = self.ctx.next_combinator_id.fetchMax(combinator_id + 1, .monotonic);
        return cc;
    }

    pub fn lookupInternedStructDescriptor(self: HostedPopulateEnv, desc: *const value_mod.TypeDescriptor) ?*value_mod.TypeDescriptor {
        std.debug.assert(desc.kind == .struct_);
        const data = desc.kind.struct_;
        return self.ctx.lookupStructDescriptor(data.fields, data.field_types, desc.mutable);
    }
};

const HostedPopulate = populate_core.SlotPopulateCore(HostedPopulateEnv);

// -- Structural TypeValue population -----------------------------------

/// Hosted shell over `SlotPopulateCore.populateTypeValueSlots`: runs the
/// shared materialization passes with prelude reuse, then layers the two
/// Context-only passes on top:
///
///   3.6. Rebuild the enum -> variant registry so `match` /
///        `unchecked-match` can resolve user enums at runtime.
///   4. Walk the word table; for words with a non-zero typevalue_slot,
///      rewrite the stub body to push the runtime TypeValue.
fn populateTypeValueSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?SlotTable,
    struct_type_slots: ?StructTypeSlotTable,
) LoaderError!void {
    const result = try HostedPopulate.populateTypeValueSlots(
        .{ .ctx = ctx },
        header,
        slots,
        struct_type_slots,
    );
    const tv_count = header.typevalue_count;
    if (tv_count == 0) return;
    const tv_out = result.type_values;
    const tv_reused = result.reused;
    const arena = ctx.quotationAllocator();

    // Pass 3.6: rebuild the enum -> variant registry so `match` /
    // `unchecked-match` can resolve user enums at runtime. The interpreter
    // populates this when the enum is defined; AOT never runs the definition.
    // The enum descriptor's variant list points at each variant's payload
    // type, not the variant TypeValue, so reconstruct the registry by grouping
    // the `enum_variant` TypeValues by their parent enum, using the
    // `virtual_type` back-references set in Pass 3.5.
    {
        // Insertion-ordered so registration follows typevalue slot order rather
        // than pointer allocation order, which varies run to run.
        var groups = std.AutoArrayHashMapUnmanaged(
            *const value_mod.TypeValue,
            std.ArrayListUnmanaged(*const value_mod.VirtualType),
        ){};
        var i: u32 = 0;
        while (i < tv_count) : (i += 1) {
            if (tv_reused[i]) continue;
            const tv = tv_out[i];
            const desc = tv.descriptor orelse continue;
            switch (desc.kind) {
                .enum_variant => |evd| {
                    const parent = evd.parent orelse continue;
                    const vt = tv.virtual_type orelse continue;
                    const gop = groups.getOrPut(arena, parent) catch
                        return LoaderError.OutOfMemory;
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    gop.value_ptr.append(arena, vt) catch
                        return LoaderError.OutOfMemory;
                },
                else => {},
            }
        }
        var it = groups.iterator();
        while (it.next()) |entry| {
            ctx.registerEnumVariants(entry.key_ptr.*, entry.value_ptr.items) catch
                return LoaderError.OutOfMemory;
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
        var instructions: []const value_mod.Instruction = &.{};
        var default_effect: ?*const stack_effect_mod.StackEffect = null;
        if (row.default_quotation_bytecode) |p| {
            if (row.default_quotation_bytecode_len > 0) {
                var diag: instruction_bytecode.DecodeDiagnostic = undefined;
                const decoded = instruction_bytecode.deserializeQuotationInstructions(
                    p[0..row.default_quotation_bytecode_len],
                    arena,
                    null,
                    &diag,
                ) catch |err| {
                    reportDecodeFailure(ctx, &diag, err);
                    return err;
                };
                instructions = decoded.instructions;
                default_effect = decoded.effect;
            }
        }
        const param = arena.create(value_mod.Parameter) catch return LoaderError.OutOfMemory;
        param.* = .{
            .name = name,
            .default_quotation = .{ .instructions = instructions, .effect = default_effect, .code_ptr = null },
        };
        slot_table[row.slot] = param;

        // The default runs standalone through `executeQuotation`, so the stamp is its only route
        // to its module's scope.
        //
        // The module cache is live: `populateModulesAndWords` runs first.
        if (row.module_name) |mn_ptr| {
            const module_name = nameSlice(mn_ptr, row.module_name_len);
            if (ctx.module_cache_value.map.get(module_name)) |cached| {
                if (cached == .module) {
                    ctx.stampQuotationBodies(instructions, cached.module) catch
                        return LoaderError.OutOfMemory;
                }
            }
        }
    }
}

/// Walk the once-cell description table and patch `onez_image_once_cell_slots[]`.
///
/// Single pass. A cell's body can reach another `once` word, but only as a call at force time,
/// which the cycle detector already covers. Nothing in a body names another cell's *slot*, so
/// there is no forward reference for a second pass to resolve.
///
/// Each cell is registered on the dictionary's teardown list, which is what releases the value it
/// eventually publishes. The cell itself lives on the arena and is not freed separately.
fn populateOnceCellSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?OnceCellSlotTable,
) LoaderError!void {
    if (header.once_cell_slot_count == 0) return;
    const descs = header.once_cell_descriptions orelse return;
    const slot_table = slots orelse return;
    const arena = ctx.quotationAllocator();
    var i: u32 = 0;
    while (i < header.once_cell_slot_count) : (i += 1) {
        const row = descs[i];
        if (row.slot >= header.once_cell_slot_count) return LoaderError.BadSlotIndex;
        const name = nameSlice(row.name, row.name_len);
        var instructions: []const value_mod.Instruction = &.{};
        var body_effect: ?*const stack_effect_mod.StackEffect = null;
        if (row.body_bytecode) |p| {
            if (row.body_bytecode_len > 0) {
                var diag: instruction_bytecode.DecodeDiagnostic = undefined;
                const decoded = instruction_bytecode.deserializeQuotationInstructions(
                    p[0..row.body_bytecode_len],
                    arena,
                    null,
                    &diag,
                ) catch |err| {
                    reportDecodeFailure(ctx, &diag, err);
                    return err;
                };
                instructions = decoded.instructions;
                body_effect = decoded.effect;
            }
        }

        // The table entry, not the id, is what says the body compiled: a body the freeze reached
        // but could not compile holds an id whose entry is null. A compiled body is the only way
        // a force runs at all in a build with no interpreter.
        var code_ptr: ?*const anyopaque = null;
        if (row.body_quotation_id != instruction_bytecode.quotation_id_sentinel) {
            if (ctx.aot_quotation_fns) |fns| {
                if (row.body_quotation_id < fns.size) code_ptr = fns.table[row.body_quotation_id];
            }
        }

        const cell = arena.create(value_mod.OnceCell) catch return LoaderError.OutOfMemory;
        cell.* = .{
            .body = .{ .instructions = instructions, .effect = body_effect, .code_ptr = code_ptr },
            .may_define = row.may_define != 0,
            .name = name,
            .allocator = ctx.allocator,
        };
        ctx.registerOnceCell(cell) catch return LoaderError.OutOfMemory;
        slot_table[row.slot] = cell;

        // The module cache is live: `populateModulesAndWords` runs first.
        if (row.module_name) |mn_ptr| {
            const module_name = nameSlice(mn_ptr, row.module_name_len);
            if (ctx.module_cache_value.map.get(module_name)) |cached| {
                if (cached == .module) {
                    ctx.stampQuotationBodies(instructions, cached.module) catch
                        return LoaderError.OutOfMemory;
                }
            }
        }
    }
}

/// Walk the mutable_map description table and patch
/// `onez_image_mutable_map_slots[]`. A first pass allocates a fresh
/// `*MutableMap` via `MutableMap.create(ctx.allocator)` for every slot and
/// patches the slot table; a second pass decodes each row's entries blob
/// (u32 entry_count followed by u32 key_len + key bytes + image-mode
/// serialized Value per entry) and puts each key/value pair into the map.
/// The two passes let an entry reference any other mutable_map slot in
/// either direction -- the flag descriptor chain
/// `flag-registry -> registry-entry -> descriptor` is a forward reference
/// from a lower slot to a higher one. Each map's initial refcount of 1 is
/// donated to the slot and released by the context's image-slot teardown
/// walk.
///
/// Runs before `populateTaggedSlots` so a tagged-inner value carrying a
/// `.mutable_map` resolves correctly; an entry that references a tagged
/// slot is still unsupported, matching the existing constraint on
/// tagged-slot self-references.
fn populateMutableMapSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?MutableMapSlotTable,
) LoaderError!void {
    if (header.mutable_map_slot_count == 0) return;
    const descs = header.mutable_map_descriptions orelse return;
    const slot_table = slots orelse return;

    // The slot maps sit on the context arena, and storing the header
    // allocator as the arena keeps runtime mutation of the map (key dupes,
    // hashmap grows) flowing through the same arena. The map's ELEMENT
    // references are not arena-scoped: runtime `@set!` transfers ownership
    // of refcounted values into the map, so the context's image-slot
    // teardown walk releases each slot's donated reference and the destroy
    // drops those element references before the arena is freed.
    const arena = ctx.quotationAllocator();

    const slot_tables = imageSlotTables(ctx);

    // Pass 1: allocate every slot's map and patch the slot table before
    // any entry is decoded. A map entry may reference another mutable_map
    // slot in either direction -- the flag descriptor chain
    // `flag-registry -> registry-entry -> descriptor` is a forward
    // reference from a lower slot to a higher one -- so every slot must
    // hold a live map before deserialization runs, or the forward
    // reference resolves through a still-null table cell. Each map's
    // initial refcount of 1 is donated to the slot.
    var i: u32 = 0;
    while (i < header.mutable_map_slot_count) : (i += 1) {
        const row = descs[i];
        if (row.slot >= header.mutable_map_slot_count) return LoaderError.BadSlotIndex;
        const mmap = value_mod.MutableMap.create(arena) catch return LoaderError.OutOfMemory;
        slot_table[row.slot] = mmap;
    }

    // Pass 2: decode each slot's entries. Every mutable_map slot is now
    // populated, so a `value_tag_mutable_map_slot` reference resolves to a
    // live map regardless of slot ordering.
    i = 0;
    while (i < header.mutable_map_slot_count) : (i += 1) {
        const row = descs[i];
        const mmap = slot_table[row.slot] orelse return LoaderError.BadSlotIndex;

        const bytes = if (row.entries_bytecode) |p|
            if (row.entries_bytecode_len > 0) p[0..row.entries_bytecode_len] else &[_]u8{}
        else
            &[_]u8{};

        if (bytes.len == 0) continue;
        if (bytes.len < @sizeOf(u32)) return LoaderError.TruncatedBytecode;

        var offset: usize = 0;
        const entry_count = std.mem.bytesToValue(u32, bytes[offset .. offset + @sizeOf(u32)]);
        offset += @sizeOf(u32);

        var e: u32 = 0;
        while (e < entry_count) : (e += 1) {
            if (offset + @sizeOf(u32) > bytes.len) return LoaderError.TruncatedBytecode;
            const key_len = std.mem.bytesToValue(u32, bytes[offset .. offset + @sizeOf(u32)]);
            offset += @sizeOf(u32);
            if (offset + key_len > bytes.len) return LoaderError.TruncatedBytecode;
            const key_src = bytes[offset .. offset + key_len];
            offset += key_len;

            var diag: instruction_bytecode.DecodeDiagnostic = undefined;
            const value = instruction_bytecode.deserializeValueAtForImage(
                bytes,
                &offset,
                arena,
                &slot_tables,
                &diag,
            ) catch |err| {
                reportDecodeFailure(ctx, &diag, err);
                return err;
            };

            const key_copy = arena.dupe(u8, key_src) catch return LoaderError.OutOfMemory;
            mmap.map.put(arena, key_copy, value) catch return LoaderError.OutOfMemory;
        }
    }
}

/// Install every parked value-map entry, in decode order, and empty the list.
///
/// A key cannot be hashed while the load is still filling containers. `ValueEntries` stores hashes
/// and `Value.hashValue` is deep, so a key holding a struct-instance or tagged slot reference is
/// hashed over the loader's placeholder contents. `Value.eql` reads the same contents, which makes
/// two distinct instances of one struct type equal, so an insert there does not merely misplace the
/// entry: it reports a duplicate and drops one. Recomputing the hashes afterwards cannot recover a
/// dropped entry.
///
/// Decode order is post-order, so a map nested inside a later entry's key is already full by the
/// time that entry is installed. Every installing site reserved capacity as it parked, which is what
/// lets this be infallible.
///
/// Emptying the list is what distinguishes the success path from the failure path: the caller's
/// drain releases whatever is left, so an entry installed here must not be released again.
fn installPendingValueMapEntries(
    pending: *std.ArrayListUnmanaged(value_mod.PendingValueMapEntry),
) void {
    for (pending.items) |entry| {
        instruction_bytecode.putDecodedValueMapEntry(entry.map, entry.key, entry.value);
    }
    pending.clearRetainingCapacity();
}

/// Release both halves of every entry still parked, for the failure path where the load aborts
/// before `installPendingValueMapEntries` runs.
///
/// The map pointer is deliberately untouched. An abort releases the enclosing `ValueMap` through the
/// decoder's own `errdefer`, so the pointer parked beside the entry may already be freed.
fn drainPendingValueMapEntries(
    pending: *std.ArrayListUnmanaged(value_mod.PendingValueMapEntry),
) void {
    for (pending.items) |entry| {
        container_backing.releaseValue(entry.key);
        container_backing.releaseValue(entry.value);
    }
    pending.clearRetainingCapacity();
}

/// Allocate one empty `*MutableValueMap` per mutable-value-map slot and patch the slot table
/// before any content is decoded, so a reference from any other family resolves regardless of
/// ordering. Each map's initial refcount of 1 is donated to the slot and released by the context's
/// image-slot teardown walk.
///
/// The family splits allocation from population, where `mutable_map` does both in one function. A
/// slot reference resolves as soon as its table cell is non-null, so allocation order is what
/// governs cross-family references, and a combined function would fix allocation and population at
/// one point in the pass order. The two need different ones.
fn allocateMutableValueMapSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?MutableValueMapSlotTable,
) LoaderError!void {
    if (header.mutable_value_map_slot_count == 0) return;
    const descs = header.mutable_value_map_descriptions orelse return;
    const slot_table = slots orelse return;
    const arena = ctx.quotationAllocator();

    var i: u32 = 0;
    while (i < header.mutable_value_map_slot_count) : (i += 1) {
        const row = descs[i];
        if (row.slot >= header.mutable_value_map_slot_count) return LoaderError.BadSlotIndex;
        const map = value_mod.MutableValueMap.create(arena) catch return LoaderError.OutOfMemory;
        slot_table[row.slot] = map;
    }
}

/// Second pass over the mutable-value-map description table: decode each row's entries into the map
/// `allocateMutableValueMapSlots` allocated. The blob is a `u32` entry count followed by
/// `key | value` per entry, both through `deserializeValueAtForImage`, so a slot-encoded half
/// resolves against the already-live slot tables.
///
/// Runs after every other population pass, including `populateTaggedSlots`, so an entry may hold a
/// reference into any other family. That lifts the "an entry referencing a tagged slot is
/// unsupported" limit the mutable-map loader carries, which it carries only because it runs earlier.
///
/// The entries are parked rather than inserted, on the same terms as an inline `value_map`. Running
/// last is not enough on its own: an inline `value_map` used as a key parks its own entries, so it is
/// still empty at the moment this entry would hash it.
///
/// Both halves of an entry arrive owning their own reference, which is
/// `deserializeValueAtForImage`'s contract, and `MutableValueMap`'s destroy releases key and value
/// alike. So neither is duped and neither is retained here, unlike the mutable-map loader's key
/// bytes. No `errdefer` covers a partly populated map: the slot owns the donated reference and
/// `Context.deinit` releases it, which is why the sibling passes carry none either.
fn populateMutableValueMapEntries(
    ctx: *Context,
    header: *const Header,
    slots: ?MutableValueMapSlotTable,
    pending: *std.ArrayListUnmanaged(value_mod.PendingValueMapEntry),
) LoaderError!void {
    if (header.mutable_value_map_slot_count == 0) return;
    const descs = header.mutable_value_map_descriptions orelse return;
    const slot_table = slots orelse return;
    const arena = ctx.quotationAllocator();
    const slot_tables = imageSlotTables(ctx);

    var i: u32 = 0;
    while (i < header.mutable_value_map_slot_count) : (i += 1) {
        const row = descs[i];
        const map = slot_table[row.slot] orelse return LoaderError.BadSlotIndex;

        const bytes = if (row.entries_bytecode) |p|
            if (row.entries_bytecode_len > 0) p[0..row.entries_bytecode_len] else &[_]u8{}
        else
            &[_]u8{};

        if (bytes.len == 0) continue;
        if (bytes.len < @sizeOf(u32)) return LoaderError.TruncatedBytecode;

        var offset: usize = 0;
        const entry_count = std.mem.bytesToValue(u32, bytes[offset .. offset + @sizeOf(u32)]);
        offset += @sizeOf(u32);

        var e: u32 = 0;
        while (e < entry_count) : (e += 1) {
            // Room for this one entry before either half is decoded, so the install pass cannot
            // fail. One at a time rather than the whole count, which a malformed blob could inflate
            // past what the stream backs.
            map.map.ensureUnusedCapacity(arena, 1) catch return LoaderError.OutOfMemory;

            var diag: instruction_bytecode.DecodeDiagnostic = undefined;
            const key = instruction_bytecode.deserializeValueAtForImage(
                bytes,
                &offset,
                arena,
                &slot_tables,
                &diag,
            ) catch |err| {
                reportDecodeFailure(ctx, &diag, err);
                return err;
            };
            // The key has no owner until the entry lands, so a truncated value strands it.
            errdefer container_backing.releaseValue(key);

            const value = instruction_bytecode.deserializeValueAtForImage(
                bytes,
                &offset,
                arena,
                &slot_tables,
                &diag,
            ) catch |err| {
                reportDecodeFailure(ctx, &diag, err);
                return err;
            };

            pending.append(ctx.allocator, .{ .map = &map.map, .key = key, .value = value }) catch {
                container_backing.releaseValue(value);
                return LoaderError.OutOfMemory;
            };
        }
    }
}

/// First pass over the struct-instance description table: allocate a fresh
/// `*StructInstance` for every slot, size its field vector from the owning
/// StructType (resolved through the already-patched struct-type slot table),
/// fill the fields with `.unit` placeholders, and patch
/// `onez_image_struct_instance_slots[]`. Runs before the mutable-map entry
/// decode so a frozen map holding struct instances resolves them, and before
/// the field decode so a struct field referencing another struct instance
/// resolves regardless of slot ordering.
fn allocateStructInstanceSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?StructInstanceSlotTable,
) LoaderError!void {
    if (header.struct_instance_slot_count == 0) return;
    const descs = header.struct_instance_descriptions orelse return;
    const slot_table = slots orelse return;
    const struct_type_slots = ctx.image_struct_type_slots orelse return LoaderError.BadSlotIndex;
    const arena = ctx.quotationAllocator();

    var i: u32 = 0;
    while (i < header.struct_instance_slot_count) : (i += 1) {
        const row = descs[i];
        if (row.slot >= header.struct_instance_slot_count) return LoaderError.BadSlotIndex;
        if (row.struct_type_slot >= header.struct_type_count) return LoaderError.BadSlotIndex;
        const st = struct_type_slots[row.struct_type_slot] orelse return LoaderError.BadSlotIndex;

        const fields = arena.alloc(value_mod.Value, st.fields.len) catch return LoaderError.OutOfMemory;
        for (fields) |*f| f.* = .{ .unit = {} };

        // The fresh header's single reference is donated to the slot table, released by the
        // context's image-slot teardown walk. The arena allocator is safe here despite
        // createStructInstance's process-lifetime contract: the donation pins the refcount
        // above zero until that walk, which runs before the arena is torn down.
        const si = value_mod.createStructInstance(arena, st, fields) catch return LoaderError.OutOfMemory;
        slot_table[row.slot] = si;
    }
}

/// Second pass over the struct-instance description table: decode each row's
/// field blob (u32 field_count followed by each field via
/// `instruction_bytecode.deserializeValueAtForImage`) into the instance
/// allocated by `allocateStructInstanceSlots`. Runs after the mutable-map
/// slots are live so a field referencing a `.mutable_map` resolves.
fn populateStructInstanceFields(
    ctx: *Context,
    header: *const Header,
    slots: ?StructInstanceSlotTable,
) LoaderError!void {
    if (header.struct_instance_slot_count == 0) return;
    const descs = header.struct_instance_descriptions orelse return;
    const slot_table = slots orelse return;
    const arena = ctx.quotationAllocator();
    const slot_tables = imageSlotTables(ctx);

    var i: u32 = 0;
    while (i < header.struct_instance_slot_count) : (i += 1) {
        const row = descs[i];
        const si = slot_table[row.slot] orelse return LoaderError.BadSlotIndex;

        const bytes = if (row.fields_bytecode) |p|
            if (row.fields_bytecode_len > 0) p[0..row.fields_bytecode_len] else &[_]u8{}
        else
            &[_]u8{};

        if (bytes.len < @sizeOf(u32)) return LoaderError.TruncatedBytecode;

        var offset: usize = 0;
        const field_count = std.mem.bytesToValue(u32, bytes[offset .. offset + @sizeOf(u32)]);
        offset += @sizeOf(u32);
        if (field_count != si.fields.len) return LoaderError.BadSlotIndex;

        var f: u32 = 0;
        while (f < field_count) : (f += 1) {
            var diag: instruction_bytecode.DecodeDiagnostic = undefined;
            si.fields[f] = instruction_bytecode.deserializeValueAtForImage(
                bytes,
                &offset,
                arena,
                &slot_tables,
                &diag,
            ) catch |err| {
                reportDecodeFailure(ctx, &diag, err);
                return err;
            };
        }
    }
}

/// Allocate one empty `*Vector` per vector slot and patch the slot table
/// before any element is decoded, so a forward reference from a lower slot to
/// a higher one resolves regardless of slot ordering. Each vector's initial
/// refcount of 1 is donated to the slot and released by the context's
/// image-slot teardown walk, so runtime-appended element references drop
/// before the arena that owns the vector struct is freed.
fn allocateVectorSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?VectorSlotTable,
) LoaderError!void {
    if (header.vector_slot_count == 0) return;
    const descs = header.vector_descriptions orelse return;
    const slot_table = slots orelse return;
    const arena = ctx.quotationAllocator();

    var i: u32 = 0;
    while (i < header.vector_slot_count) : (i += 1) {
        const row = descs[i];
        if (row.slot >= header.vector_slot_count) return LoaderError.BadSlotIndex;
        const vec = value_mod.Vector.create(arena) catch return LoaderError.OutOfMemory;
        slot_table[row.slot] = vec;
    }
}

/// Second pass over the vector description table: decode each row's element
/// blob into the vector allocated by `allocateVectorSlots`. The blob is a
/// `u32` element count followed by each element, decoded through
/// `deserializeValueAtForImage` (the same path the mutable-map and
/// struct-instance loaders use), so slot-encoded elements resolve against the
/// already-live slot tables. Each decoded value is appended directly; the
/// vector's destroy callback releases the elements symmetrically.
fn populateVectorElements(
    ctx: *Context,
    header: *const Header,
    slots: ?VectorSlotTable,
) LoaderError!void {
    if (header.vector_slot_count == 0) return;
    const descs = header.vector_descriptions orelse return;
    const slot_table = slots orelse return;
    const arena = ctx.quotationAllocator();
    const slot_tables = imageSlotTables(ctx);

    var i: u32 = 0;
    while (i < header.vector_slot_count) : (i += 1) {
        const row = descs[i];
        const vec = slot_table[row.slot] orelse return LoaderError.BadSlotIndex;

        const bytes = if (row.elements_bytecode) |p|
            if (row.elements_bytecode_len > 0) p[0..row.elements_bytecode_len] else &[_]u8{}
        else
            &[_]u8{};

        if (bytes.len < @sizeOf(u32)) return LoaderError.TruncatedBytecode;
        var offset: usize = 0;
        const elem_count = std.mem.bytesToValue(u32, bytes[offset .. offset + @sizeOf(u32)]);
        offset += @sizeOf(u32);

        var e: u32 = 0;
        while (e < elem_count) : (e += 1) {
            var diag: instruction_bytecode.DecodeDiagnostic = undefined;
            const value = instruction_bytecode.deserializeValueAtForImage(
                bytes,
                &offset,
                arena,
                &slot_tables,
                &diag,
            ) catch |err| {
                reportDecodeFailure(ctx, &diag, err);
                return err;
            };
            vec.list.append(arena, value) catch return LoaderError.OutOfMemory;
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

    const slot_tables = imageSlotTables(ctx);

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
                var diag: instruction_bytecode.DecodeDiagnostic = undefined;
                inner.* = instruction_bytecode.deserializeValueAtForImage(
                    p[0..row.inner_bytecode_len],
                    &offset,
                    arena,
                    &slot_tables,
                    &diag,
                ) catch |err| {
                    reportDecodeFailure(ctx, &diag, err);
                    return err;
                };
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

/// Resolve a serialized dispatch type-slot value to the
/// `*const TypeDescriptor` the dispatch key needs. The reserved sentinels
/// map to the dispatch table's synthetic unary/wildcard descriptors; a
/// 1-based slot resolves through the typevalue slot table; 0 or a missing
/// slot yields null so the caller skips the row rather than registering a
/// malformed key.
fn resolveDispatchTypeDescriptor(
    ctx: *Context,
    slots: ?SlotTable,
    slot_count: u32,
    slot: u32,
) LoaderError!?*const value_mod.TypeDescriptor {
    if (slot == dispatch_type_unary) return ctx.getDispatchUnarySentinel().descriptor.?;
    if (slot == dispatch_type_any) return ctx.getDispatchAnySentinel().descriptor.?;
    const tv = (try lookupSlot(slots, slot_count, slot)) orelse return null;
    return tv.descriptor;
}

/// Replay the freeze-time method dispatch entries into `ctx.dispatch`.
///
/// Runs after `loadIntoContext` stashed the table and populated the
/// typevalue slots and module surface, and after the quotation-function
/// table is registered, so each row's body resolves to its compiled
/// function pointer. Each row keys `registerDispatch` on its serialized
/// `dispatch_id` verbatim -- the same id compiled call sites bake -- so a
/// replayed method resolves at exactly the dispatch key a compiled call
/// site uses. A row whose types, body, or defining module fails to resolve
/// is skipped rather than aborting the whole replay.
pub fn replayMethodDispatch(ctx: *Context) LoaderError!void {
    const count = ctx.image_dispatch_entry_count;
    if (count == 0) return;
    const rows_raw = ctx.image_dispatch_entry_descriptions orelse return;
    // The quotation-function table may be absent when every dispatch entry is
    // interpreter-run (no method body compiled). Treat that as an empty table:
    // entries resolve their bodies from the row bytecode instead.
    const fns_opt = ctx.aot_quotation_fns;
    const rows: [*]const DispatchEntryDescription = @ptrCast(@alignCast(rows_raw));

    const slots = ctx.image_typevalue_slots;
    const slot_count = ctx.image_typevalue_slot_count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const row = rows[i];

        // The row's id was issued by the freeze's counter, not this process's. Advance the mint
        // counter past it, before any skip below, so a runtime definition can never mint an id
        // that aliases this row's identity.
        ctx.advanceDispatchIdPast(row.dispatch_id);

        const type_a = (try resolveDispatchTypeDescriptor(ctx, slots, slot_count, row.type_a_slot)) orelse continue;
        const type_b = (try resolveDispatchTypeDescriptor(ctx, slots, slot_count, row.type_b_slot)) orelse continue;

        // A method body resolves either to a compiled native function (the
        // common case, indexed by `quotation_id` in the quotation-function
        // table) or, when the freeze never compiled it, to interpreter-run
        // bytecode the row carries directly (`quotation_id` is the sentinel,
        // or the table is absent). Register the bytecode with a null code_ptr
        // so the dispatcher runs it through the interpreter. A row with
        // neither is skipped, as before.
        var body_instructions: []const value_mod.Instruction = &.{};
        var body_effect: ?*const stack_effect_mod.StackEffect = null;
        const is_interp_only = row.quotation_id == aot_image_emit.dispatch_interp_quotation_id_sentinel;
        const compiled_fn: ?*const anyopaque = blk: {
            if (is_interp_only) break :blk null;
            const fns = fns_opt orelse break :blk null;
            if (row.quotation_id >= fns.size) break :blk null;
            break :blk fns.table[row.quotation_id];
        };
        const code_ptr: ?*const anyopaque = compiled_fn orelse blk: {
            const bc_ptr = row.body_bytecode orelse continue;
            if (row.body_bytecode_len == 0) continue;
            const bytes = bc_ptr[0..row.body_bytecode_len];
            // Slot-aware decode: method bodies may carry slot-encoded
            // `.struct_type` literals (e.g. generated field getters). The
            // tables are patched before replay runs, so they resolve here.
            const body_tables = imageSlotTables(ctx);
            var diag: instruction_bytecode.DecodeDiagnostic = undefined;
            const decoded = instruction_bytecode.deserializeQuotationInstructionsForImage(bytes, ctx.quotationAllocator(), &body_tables, &diag) catch |err| {
                reportDecodeFailure(ctx, &diag, err);
                return err;
            };
            body_instructions = decoded.instructions;
            body_effect = decoded.effect;
            ctx.registerQuotationContainerLiterals(body_instructions) catch
                return LoaderError.OutOfMemory;
            break :blk null;
        };

        const module: ?*const value_mod.Module = if (row.module_name) |name_ptr| blk: {
            const name = nameSlice(name_ptr, row.module_name_len);
            const cached = ctx.module_cache_value.map.get(name) orelse break :blk null;
            break :blk switch (cached) {
                .module => |m| m,
                else => null,
            };
        } else null;

        // Stamp an interpreter-run body and its nested quotation literals with the method's
        // defining module.
        //
        // The entry's `source_module` covers only the top-level body, via the deps frame
        // `executeDispatchBody` pushes around it. A buried quotation runs standalone and has only
        // the stamp.
        if (module) |mod| {
            if (body_instructions.len > 0) {
                ctx.stampQuotationBodies(body_instructions, mod) catch
                    return LoaderError.OutOfMemory;
            }
        }

        if (row.generic_name) |gname_ptr| {
            const gname = nameSlice(gname_ptr, row.generic_name_len);
            ctx.aot_generic_dispatch_ids.put(ctx.allocator, gname, row.dispatch_id) catch
                return LoaderError.OutOfMemory;
        }

        // dispatch_id consistency invariant: the row carries the freeze-time
        // dispatch_id verbatim and the key reuses it directly. The loader never
        // re-mints replayed ids from the `next_dispatch_id` counter, so a
        // replayed entry's dispatch_id equals the id a compiled call site bakes
        // as a u32 literal for the same generic; otherwise dispatch would
        // silently misroute. The counter is only advanced past the row ids,
        // which preserves them.
        const key = dispatch_mod.DispatchKey{
            .dispatch_id = row.dispatch_id,
            .type_a = type_a,
            .type_b = type_b,
        };
        std.debug.assert(key.dispatch_id == row.dispatch_id);
        const entry = dispatch_mod.DispatchEntry{
            .body = .{ .quotation = .{ .instructions = body_instructions, .effect = body_effect, .code_ptr = code_ptr } },
            .source_module = module,
        };
        // Fill gaps only: in interpreter-linked AOT the prelude reload already
        // registers its methods (with working bytecode bodies), so replay must
        // not clobber them with a compiled code_ptr body. A duplicate key means
        // the method is already live; keep it.
        ctx.registerDispatch(key, entry, false) catch |err| switch (err) {
            error.DuplicateMethod => {},
            else => return LoaderError.OutOfMemory,
        };
    }

    // Patch each loaded generic word's `dispatch_id` to the value its
    // replayed methods registered under. The image word table does not
    // serialize `dispatch_id`, so a loaded generic word defaults to 0;
    // interpreter generic dispatch (`tryDispatchGenericById`) keys on
    // `word.dispatch_id`, so without this it never matches the replayed
    // method entries and every generic call from an interpreted quotation
    // fails with "no method found". Dep entries are value copies made in
    // `populateModuleDeps` before this patch, so they are patched too.
    var mod_it = ctx.module_cache_value.map.valueIterator();
    while (mod_it.next()) |cached| {
        if (cached.* != .module) continue;
        var word_it = cached.*.module.words.iterator();
        while (word_it.next()) |word_entry| {
            if (ctx.aot_generic_dispatch_ids.get(word_entry.key_ptr.*)) |did| {
                word_entry.value_ptr.dispatch_id = did;
            }
        }
        var dep_it = cached.*.module.deps.iterator();
        while (dep_it.next()) |dep_entry| {
            if (ctx.aot_generic_dispatch_ids.get(dep_entry.key_ptr.*)) |did| {
                dep_entry.value_ptr.dispatch_id = did;
            }
        }

        // Warm the deps-and-words frame template now that this module's word
        // bodies (decoded in `loadIntoContext`) and dispatch_ids are final. The
        // loader arena outlives the process. A binary with no dispatch entries
        // returns early above and leaves modules to the per-entry rebuild.
        Context.buildModuleDepsTemplate(cached.*.module, ctx.quotationAllocator()) catch return LoaderError.OutOfMemory;
    }

    // Entry-import frame definitions are value copies made in `populateEntryImports` before this
    // patch, so patch them too, or a generic imported by the entry never matches its replayed
    // methods.
    if (ctx.image_entry_import_frame) |frame_idx| {
        var frame_it = ctx.local_frames.items[frame_idx].iterator();
        while (frame_it.next()) |entry| {
            if (ctx.aot_generic_dispatch_ids.get(entry.key_ptr.*)) |did| {
                entry.value_ptr.dispatch_id = did;
            }
        }
    }

    // Call-target slot definitions are value copies made in `fillCallTargetSlots`, also before
    // this patch, so a generic reached through a baked call site needs the same treatment.
    if (ctx.image_call_target_slots) |target_slots| {
        var ti: u32 = 0;
        while (ti < ctx.image_call_target_slot_count) : (ti += 1) {
            const slot = target_slots[ti] orelse continue;
            if (ctx.aot_generic_dispatch_ids.get(slot.name)) |did| {
                dictionary_mod.loadSlot(slot).dispatch_id = did;
            }
        }
    }
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
    const word_entry = if (w.flags & aot_image_emit.flag_bit_module_private != 0)
        module_ptr.deps.getPtr(word_name) orelse return
    else
        module_ptr.words.getPtr(word_name) orelse return;

    const arena = ctx.quotationAllocator();
    const instrs = arena.alloc(value_mod.Instruction, 1) catch return LoaderError.OutOfMemory;
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0, .column = 0 };
    word_entry.action = .{ .compound = instrs };
}

// -- Protocol descriptor slot population --------------------------------

/// Hosted shell over `SlotPopulateCore.populateProtocolDescriptorSlots`:
/// reuse hits `ctx.protocol_descriptors`, and reconstruction registers on
/// the Context with the build-time `protocol_id` preserved and
/// `next_protocol_id` advanced past it.
fn populateProtocolDescriptorSlots(
    ctx: *Context,
    header: *const Header,
    slots: ?ProtocolDescriptorSlotTable,
) LoaderError!void {
    try HostedPopulate.populateProtocolDescriptorSlots(.{ .ctx = ctx }, header, slots);
}

// -- Constraint combinator slot population ------------------------------

/// Hosted shell over `SlotPopulateCore.populateConstraintCombinatorSlots`:
/// reconstruction registers on the Context with the build-time
/// `combinator_id` preserved and `next_combinator_id` advanced past it.
fn populateConstraintCombinatorSlots(
    ctx: *Context,
    header: *const Header,
    slots: SlotTables,
) LoaderError!void {
    try HostedPopulate.populateConstraintCombinatorSlots(.{ .ctx = ctx }, header, slots);
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

/// Surface a decode failure's diagnostic as an error-detail row before the error propagates.
/// An unresolved slot goes through `Context.recordImageSlotMiss`; the other two structural
/// members render the offset and tag the decoder captured. On `OutOfMemory` the diagnostic is
/// unwritten and nothing is recorded.
fn reportDecodeFailure(
    ctx: *Context,
    diag: *const instruction_bytecode.DecodeDiagnostic,
    err: instruction_bytecode.DecodeError,
) void {
    switch (err) {
        error.UnresolvedSlot => ctx.recordImageSlotMiss(diag.slot_kind, diag.slot),
        error.TruncatedBytecode, error.UnknownTag => {
            var buf: [128]u8 = undefined;
            recordLoaderError(ctx, "{s}", .{diag.describe(&buf)});
        },
        error.OutOfMemory => {},
    }
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
        .mutable_value_map_slot_count = 0,
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
        .mutable_value_map_descriptions = null,
        .struct_instance_slot_count = 0,
        .struct_instance_descriptions = null,
        .vector_slot_count = 0,
        .vector_descriptions = null,
        .once_cell_slot_count = 0,
        .once_cell_descriptions = null,
        .protocoldescriptor_slot_count = 0,
        .protocoldescriptor_descriptions = null,
        .constraintcombinator_slot_count = 0,
        .constraintcombinator_descriptions = null,
        .dispatch_entry_slot_count = 0,
        .dispatch_entry_descriptions = null,
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
        .inline_regions = null,
        .nested_inline_regions = null,
        .nested_inline_region_count = 0,
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
        .type_param_position = 0,
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

test "loadIntoContext: private-flagged type word's deps body rewrites to the runtime TypeValue" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const tv_name = "priv-type";
    const w_name = "PrivType";
    const m_name = "demo";

    var drow = zeroDescriptor();
    drow.kind = 6;
    const resource_kind = "priv-handle";
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
            w.flags = aot_image_emit.flag_bit_module_private;
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

    const tv = slot_storage[1] orelse return error.TestExpectedTypeValue;
    const module_ptr = (ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule).module;
    const mw = module_ptr.deps.get(w_name) orelse return error.TestExpectedDep;
    try testing.expectEqual(@as(usize, 1), mw.action.compound.len);
    try testing.expectEqual(@as(*const value_mod.TypeValue, tv), mw.action.compound[0].op.push_literal.type_val);
    try testing.expect(module_ptr.words.get(w_name) == null);
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
    try testing.expect(b_kind.struct_.field_types[0].? == .type);
    try testing.expectEqual(@as(*const value_mod.TypeValue, tv_a), b_kind.struct_.field_types[0].?.type);
}

test "loadIntoContext: same-shaped struct descriptors intern to one pointer" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const field_names = [_][*]const u8{ "src".ptr, "pos".ptr };
    const field_lens = [_]u32{ 3, 3 };

    var a_desc = zeroDescriptor();
    a_desc.kind = 2; // struct_
    a_desc.mutable = 1;
    a_desc.field_names = &field_names;
    a_desc.field_name_lens = &field_lens;
    a_desc.field_count = 2;

    const b_desc = a_desc;

    // Same fields but immutable: a different shape, so it must stay distinct.
    var c_desc = a_desc;
    c_desc.mutable = 0;

    const descriptors = [_]TypeDescriptor{ a_desc, b_desc, c_desc };
    const a_name = "a-state";
    const b_name = "b-state";
    const c_name = "c-state";
    const typevalues = [_]TypeValueRow{
        .{ .name = a_name.ptr, .name_len = a_name.len, .slot = 1, .descriptor = &descriptors[0], .member_type_slots = null, .member_type_count = 0 },
        .{ .name = b_name.ptr, .name_len = b_name.len, .slot = 2, .descriptor = &descriptors[1], .member_type_slots = null, .member_type_count = 0 },
        .{ .name = c_name.ptr, .name_len = c_name.len, .slot = 3, .descriptor = &descriptors[2], .member_type_slots = null, .member_type_count = 0 },
    };

    var slot_storage: [4]?*const value_mod.TypeValue = .{ null, null, null, null };
    var header = emptyHeader();
    header.typevalue_slot_count = 4;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;

    try loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, null);

    const tv_a = slot_storage[1] orelse return error.TestUnexpectedResult;
    const tv_b = slot_storage[2] orelse return error.TestUnexpectedResult;
    const tv_c = slot_storage[3] orelse return error.TestUnexpectedResult;

    // The two same-shaped structs share one descriptor, so pointer-identity checks treat them as
    // one type, matching the interpreter's structural interning.
    try testing.expect(tv_a != tv_b);
    try testing.expectEqual(tv_a.descriptor.?, tv_b.descriptor.?);
    try testing.expect(tv_a.descriptor.? != tv_c.descriptor.?);
}

test "loadIntoContext: possibly-erased field constraints block struct descriptor interning" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const field_names = [_][*]const u8{"x".ptr};
    const field_lens = [_]u32{1};
    // Slot 0 is the "no annotation" sentinel. The emitter also writes it for a protocol- or
    // combinator-bound field, so a decoded null element is ambiguous and must not intern.
    const field_slots = [_]u32{0};

    var a_desc = zeroDescriptor();
    a_desc.kind = 2; // struct_
    a_desc.field_names = &field_names;
    a_desc.field_name_lens = &field_lens;
    a_desc.field_count = 1;
    a_desc.field_type_slots = &field_slots;
    a_desc.field_type_count = 1;

    const b_desc = a_desc;

    const descriptors = [_]TypeDescriptor{ a_desc, b_desc };
    const a_name = "a-state";
    const b_name = "b-state";
    const typevalues = [_]TypeValueRow{
        .{ .name = a_name.ptr, .name_len = a_name.len, .slot = 1, .descriptor = &descriptors[0], .member_type_slots = null, .member_type_count = 0 },
        .{ .name = b_name.ptr, .name_len = b_name.len, .slot = 2, .descriptor = &descriptors[1], .member_type_slots = null, .member_type_count = 0 },
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
    try testing.expect(tv_a.descriptor.? != tv_b.descriptor.?);
}

test "loadIntoContext: struct descriptor interning is shared with the context registry" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const fields = [_][]const u8{ "src", "pos" };
    const no_ft = [_]?value_mod.ConstraintCombinator.Element{};
    const pre_interned = try ctx.getOrCreateStructDescriptor(&fields, &no_ft, true);

    const field_names = [_][*]const u8{ "src".ptr, "pos".ptr };
    const field_lens = [_]u32{ 3, 3 };

    var a_desc = zeroDescriptor();
    a_desc.kind = 2; // struct_
    a_desc.mutable = 1;
    a_desc.field_names = &field_names;
    a_desc.field_name_lens = &field_lens;
    a_desc.field_count = 2;

    var c_desc = a_desc;
    c_desc.mutable = 0;

    const descriptors = [_]TypeDescriptor{ a_desc, c_desc };
    const a_name = "a-state";
    const c_name = "c-state";
    const typevalues = [_]TypeValueRow{
        .{ .name = a_name.ptr, .name_len = a_name.len, .slot = 1, .descriptor = &descriptors[0], .member_type_slots = null, .member_type_count = 0 },
        .{ .name = c_name.ptr, .name_len = c_name.len, .slot = 2, .descriptor = &descriptors[1], .member_type_slots = null, .member_type_count = 0 },
    };

    var slot_storage: [3]?*const value_mod.TypeValue = .{ null, null, null };
    var header = emptyHeader();
    header.typevalue_slot_count = 3;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;

    try loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, null);

    // A loaded row whose shape the context already interned adopts the existing descriptor.
    const tv_a = slot_storage[1] orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(*const value_mod.TypeDescriptor, pre_interned), tv_a.descriptor.?);

    // A loaded row with a new shape is not seeded into the registry; see the no-seeding rationale
    // on the interning pass in `aot_image_populate_core.zig`.
    const tv_c = slot_storage[2] orelse return error.TestUnexpectedResult;
    const later = try ctx.getOrCreateStructDescriptor(&fields, &no_ft, false);
    try testing.expect(tv_c.descriptor.? != later);
}

test "loadIntoContext: type_parameter descriptor round-trips position and reconstructs struct type_params" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Slot 1: a type parameter `T` at position 5.
    var param_desc = zeroDescriptor();
    param_desc.kind = 9; // type_parameter
    param_desc.type_param_position = 5;

    // Slot 2: a struct `S` whose only field is typed by the parameter at slot 1.
    var struct_desc = zeroDescriptor();
    struct_desc.kind = 2; // struct_
    const s_field_names = [_][*]const u8{"v".ptr};
    const s_field_lens = [_]u32{1};
    const s_field_slots = [_]u32{1}; // points at T
    struct_desc.field_names = &s_field_names;
    struct_desc.field_name_lens = &s_field_lens;
    struct_desc.field_count = 1;
    struct_desc.field_type_slots = &s_field_slots;
    struct_desc.field_type_count = 1;

    // Slot 3: a second parameter spelled `fixnum`, colliding with the builtin.
    // The reuse-by-name dedup must be bypassed so it stays a fresh parameter.
    var collide_desc = zeroDescriptor();
    collide_desc.kind = 9; // type_parameter
    collide_desc.type_param_position = 0;

    const descriptors = [_]TypeDescriptor{ param_desc, struct_desc, collide_desc };
    const t_name = "T";
    const s_name = "S";
    const fx_name = "fixnum";
    const typevalues = [_]TypeValueRow{
        .{ .name = t_name.ptr, .name_len = t_name.len, .slot = 1, .descriptor = &descriptors[0], .member_type_slots = null, .member_type_count = 0 },
        .{ .name = s_name.ptr, .name_len = s_name.len, .slot = 2, .descriptor = &descriptors[1], .member_type_slots = null, .member_type_count = 0 },
        .{ .name = fx_name.ptr, .name_len = fx_name.len, .slot = 3, .descriptor = &descriptors[2], .member_type_slots = null, .member_type_count = 0 },
    };

    var slot_storage: [4]?*const value_mod.TypeValue = .{ null, null, null, null };
    var header = emptyHeader();
    header.typevalue_slot_count = 4;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;

    try loadIntoContext(&ctx, &header, .{ .typevalues = &slot_storage }, null);

    // The parameter round-trips: kind, position, and name all survive.
    const tv_t = slot_storage[1] orelse return error.TestUnexpectedResult;
    try testing.expect(value_mod.isTypeParameter(tv_t));
    try testing.expectEqual(@as(?u32, 5), value_mod.typeParameterPosition(tv_t));
    try testing.expectEqualStrings("T", tv_t.name);

    // The struct's declared type_params projection is reconstructed from its
    // field types and points at the same parameter TypeValue.
    const tv_s = slot_storage[2] orelse return error.TestUnexpectedResult;
    const s_kind = tv_s.descriptor.?.kind;
    try testing.expect(s_kind == .struct_);
    try testing.expectEqual(@as(usize, 1), s_kind.struct_.type_params.len);
    try testing.expectEqual(@as(*const value_mod.TypeValue, tv_t), s_kind.struct_.type_params[0]);

    // The `fixnum`-spelled parameter is NOT collapsed into the builtin fixnum
    // TypeValue: the reuse-by-name path is bypassed for the parameter kind.
    const tv_fx = slot_storage[3] orelse return error.TestUnexpectedResult;
    try testing.expect(value_mod.isTypeParameter(tv_fx));
    try testing.expect(tv_fx != ctx.lookupTypeValueByName("fixnum").?);
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
        value_mod.symbolValue("red"),
        testing.allocator,
        null,
        null,
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
    try testing.expectEqualStrings("red", tagged_ptr.tagged.inner.symbol.bytes);
}

test "populateMutableMapSlots: lower slot forward-references a higher slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // A dummy MutableMap used only as the encoding key that maps to slot
    // index 1; released after encoding. The loader allocates its own maps.
    const key_map = try value_mod.MutableMap.create(testing.allocator);
    defer key_map.header.release();

    var mm_index: std.AutoHashMapUnmanaged(*const value_mod.MutableMap, u32) = .{};
    defer mm_index.deinit(testing.allocator);
    try mm_index.put(testing.allocator, key_map, 1);

    var mvm_index: std.AutoHashMapUnmanaged(*const value_mod.MutableValueMap, u32) = .{};
    defer mvm_index.deinit(testing.allocator);

    var tv_index: std.AutoHashMapUnmanaged(*const value_mod.TypeValue, u32) = .{};
    defer tv_index.deinit(testing.allocator);
    var st_index: std.AutoHashMapUnmanaged(*const value_mod.StructType, u32) = .{};
    defer st_index.deinit(testing.allocator);
    var mk_index: std.AutoHashMapUnmanaged(*const value_mod.Marker, u32) = .{};
    defer mk_index.deinit(testing.allocator);
    var pm_index: std.AutoHashMapUnmanaged(*const value_mod.Parameter, u32) = .{};
    defer pm_index.deinit(testing.allocator);
    var tg_index: std.AutoHashMapUnmanaged(instruction_bytecode.TaggedKey, u32) = .{};
    defer tg_index.deinit(testing.allocator);
    var si_index: std.AutoHashMapUnmanaged(*const value_mod.StructInstance, u32) = .{};
    defer si_index.deinit(testing.allocator);
    var vx_index: std.AutoHashMapUnmanaged(*const value_mod.Vector, u32) = .{};
    defer vx_index.deinit(testing.allocator);
    var oc_index: std.AutoHashMapUnmanaged(*const value_mod.OnceCell, u32) = .{};
    defer oc_index.deinit(testing.allocator);

    const enc_maps = instruction_bytecode.SlotEncodingMaps{
        .typevalue_slot_index = &tv_index,
        .struct_type_slot_index = &st_index,
        .marker_slot_index = &mk_index,
        .parameter_slot_index = &pm_index,
        .tagged_slot_index = &tg_index,
        .mutable_map_slot_index = &mm_index,
        .mutable_value_map_slot_index = &mvm_index,
        .struct_instance_slot_index = &si_index,
        .vector_slot_index = &vx_index,
        .once_cell_slot_index = &oc_index,
    };

    const one: u32 = 1;

    // Slot 0: one entry "ref" -> mutable_map_slot 1, a forward reference to
    // a higher-numbered slot that the single-pass loader had not yet
    // allocated when it decoded this slot's entries.
    var enc0: std.ArrayListUnmanaged(u8) = .{};
    defer enc0.deinit(testing.allocator);
    try enc0.appendSlice(testing.allocator, std.mem.asBytes(&one));
    const klen0: u32 = 3;
    try enc0.appendSlice(testing.allocator, std.mem.asBytes(&klen0));
    try enc0.appendSlice(testing.allocator, "ref");
    try instruction_bytecode.serializeValueIntoForImage(&enc0, .{ .mutable_map = key_map }, testing.allocator, &enc_maps, null);

    // Slot 1: one entry "v" -> fixnum 42.
    var enc1: std.ArrayListUnmanaged(u8) = .{};
    defer enc1.deinit(testing.allocator);
    try enc1.appendSlice(testing.allocator, std.mem.asBytes(&one));
    const klen1: u32 = 1;
    try enc1.appendSlice(testing.allocator, std.mem.asBytes(&klen1));
    try enc1.appendSlice(testing.allocator, "v");
    try instruction_bytecode.serializeValueIntoForImage(&enc1, .{ .fixnum = 42 }, testing.allocator, &enc_maps, null);

    const descs = [_]MutableMapDescription{
        .{ .slot = 0, .entries_bytecode = enc0.items.ptr, .entries_bytecode_len = @intCast(enc0.items.len) },
        .{ .slot = 1, .entries_bytecode = enc1.items.ptr, .entries_bytecode_len = @intCast(enc1.items.len) },
    };

    var mm_storage: [2]?*value_mod.MutableMap = .{ null, null };

    var header = emptyHeader();
    header.mutable_map_slot_count = 2;
    header.mutable_map_descriptions = &descs;

    try loadIntoContext(&ctx, &header, .{ .mutable_maps = &mm_storage }, null);

    const slot0 = mm_storage[0] orelse return error.TestUnexpectedResult;
    const slot1 = mm_storage[1] orelse return error.TestUnexpectedResult;

    const ref = slot0.map.get("ref") orelse return error.TestUnexpectedResult;
    try testing.expect(ref == .mutable_map);
    // The forward reference resolves to the very map the loader allocated
    // for slot 1, not a fresh or null one.
    try testing.expect(ref.mutable_map == slot1);

    const v = slot1.map.get("v") orelse return error.TestUnexpectedResult;
    try testing.expect(v == .fixnum);
    try testing.expectEqual(@as(i64, 42), v.fixnum);
}

/// Test-only holder for the slot-index maps a family under test does not populate. Each map is
/// empty unless a test fills one, so a value reaching an un-interned family encodes as
/// `NotEncodable`. It has to outlive the `SlotEncodingMaps` `maps` returns.
const EmptyEncodingIndices = struct {
    typevalue: std.AutoHashMapUnmanaged(*const value_mod.TypeValue, u32) = .{},
    struct_type: std.AutoHashMapUnmanaged(*const value_mod.StructType, u32) = .{},
    marker: std.AutoHashMapUnmanaged(*const value_mod.Marker, u32) = .{},
    parameter: std.AutoHashMapUnmanaged(*const value_mod.Parameter, u32) = .{},
    tagged: std.AutoHashMapUnmanaged(instruction_bytecode.TaggedKey, u32) = .{},
    mutable_map: std.AutoHashMapUnmanaged(*const value_mod.MutableMap, u32) = .{},
    struct_instance: std.AutoHashMapUnmanaged(*const value_mod.StructInstance, u32) = .{},
    vector: std.AutoHashMapUnmanaged(*const value_mod.Vector, u32) = .{},
    once_cell: std.AutoHashMapUnmanaged(*const value_mod.OnceCell, u32) = .{},

    fn deinit(self: *EmptyEncodingIndices) void {
        self.typevalue.deinit(testing.allocator);
        self.struct_type.deinit(testing.allocator);
        self.marker.deinit(testing.allocator);
        self.parameter.deinit(testing.allocator);
        self.tagged.deinit(testing.allocator);
        self.mutable_map.deinit(testing.allocator);
        self.struct_instance.deinit(testing.allocator);
        self.vector.deinit(testing.allocator);
        self.once_cell.deinit(testing.allocator);
    }

    fn maps(
        self: *const EmptyEncodingIndices,
        mutable_value_map: *const std.AutoHashMapUnmanaged(*const value_mod.MutableValueMap, u32),
    ) instruction_bytecode.SlotEncodingMaps {
        return .{
            .typevalue_slot_index = &self.typevalue,
            .struct_type_slot_index = &self.struct_type,
            .marker_slot_index = &self.marker,
            .parameter_slot_index = &self.parameter,
            .tagged_slot_index = &self.tagged,
            .mutable_map_slot_index = &self.mutable_map,
            .mutable_value_map_slot_index = mutable_value_map,
            .struct_instance_slot_index = &self.struct_instance,
            .vector_slot_index = &self.vector,
            .once_cell_slot_index = &self.once_cell,
        };
    }
};

test "populateMutableValueMapEntries: a lower slot forward-references a higher one" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // A dummy map used only as the encoding key for slot 1, released after encoding. The loader
    // allocates its own maps.
    const key_map = try value_mod.MutableValueMap.create(testing.allocator);
    defer key_map.header.release();

    var mvm_index: std.AutoHashMapUnmanaged(*const value_mod.MutableValueMap, u32) = .{};
    defer mvm_index.deinit(testing.allocator);
    try mvm_index.put(testing.allocator, key_map, 1);

    var enc_holder = EmptyEncodingIndices{};
    defer enc_holder.deinit();
    const enc_maps = enc_holder.maps(&mvm_index);

    const one: u32 = 1;

    // Slot 0: one entry, fixnum 1 -> mutable_value_map_slot 1.
    var enc0: std.ArrayListUnmanaged(u8) = .{};
    defer enc0.deinit(testing.allocator);
    try enc0.appendSlice(testing.allocator, std.mem.asBytes(&one));
    try instruction_bytecode.serializeValueIntoForImage(&enc0, .{ .fixnum = 1 }, testing.allocator, &enc_maps, null);
    try instruction_bytecode.serializeValueIntoForImage(&enc0, .{ .mutable_value_map = key_map }, testing.allocator, &enc_maps, null);

    // Slot 1: one entry, fixnum 2 -> fixnum 42.
    var enc1: std.ArrayListUnmanaged(u8) = .{};
    defer enc1.deinit(testing.allocator);
    try enc1.appendSlice(testing.allocator, std.mem.asBytes(&one));
    try instruction_bytecode.serializeValueIntoForImage(&enc1, .{ .fixnum = 2 }, testing.allocator, &enc_maps, null);
    try instruction_bytecode.serializeValueIntoForImage(&enc1, .{ .fixnum = 42 }, testing.allocator, &enc_maps, null);

    const descs = [_]MutableValueMapDescription{
        .{ .slot = 0, .entries_bytecode = enc0.items.ptr, .entries_bytecode_len = @intCast(enc0.items.len) },
        .{ .slot = 1, .entries_bytecode = enc1.items.ptr, .entries_bytecode_len = @intCast(enc1.items.len) },
    };

    var storage: [2]?*value_mod.MutableValueMap = .{ null, null };

    var header = emptyHeader();
    header.mutable_value_map_slot_count = 2;
    header.mutable_value_map_descriptions = &descs;

    try loadIntoContext(&ctx, &header, .{ .mutable_value_maps = &storage }, null);

    const slot0 = storage[0] orelse return error.TestUnexpectedResult;
    const slot1 = storage[1] orelse return error.TestUnexpectedResult;

    const ref = slot0.map.get(.{ .fixnum = 1 }) orelse return error.TestUnexpectedResult;
    try testing.expect(ref == .mutable_value_map);
    try testing.expect(ref.mutable_value_map == slot1);

    const v = slot1.map.get(.{ .fixnum = 2 }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 42), v.fixnum);
}

test "populateMutableValueMapEntries: a struct-instance key stays findable after its fields fill" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // `hashValue` on a struct instance folds in its fields, and `ValueEntries` stores the hash it
    // computed at insert. A key inserted while the instance was still holding `.unit` placeholders
    // would sit in the wrong bucket forever, which is what the post-population re-index repairs.
    var struct_type = value_mod.StructType{ .name = "box", .fields = &.{"data"} };
    const key_instance = try value_mod.createStructInstance(
        testing.allocator,
        &struct_type,
        try testing.allocator.dupe(value_mod.Value, &.{.{ .fixnum = 99 }}),
    );
    defer container_backing.releaseValue(.{ .struct_instance = key_instance });

    var mvm_index: std.AutoHashMapUnmanaged(*const value_mod.MutableValueMap, u32) = .{};
    defer mvm_index.deinit(testing.allocator);

    // The holder owns these two maps' backings, so they are filled in place rather than copied in.
    var enc_holder = EmptyEncodingIndices{};
    defer enc_holder.deinit();
    try enc_holder.struct_instance.put(testing.allocator, key_instance, 0);
    try enc_holder.struct_type.put(testing.allocator, &struct_type, 0);
    const enc_maps = enc_holder.maps(&mvm_index);

    const one: u32 = 1;

    var fields_enc: std.ArrayListUnmanaged(u8) = .{};
    defer fields_enc.deinit(testing.allocator);
    try fields_enc.appendSlice(testing.allocator, std.mem.asBytes(&one));
    try instruction_bytecode.serializeValueIntoForImage(&fields_enc, .{ .fixnum = 99 }, testing.allocator, &enc_maps, null);

    var entries_enc: std.ArrayListUnmanaged(u8) = .{};
    defer entries_enc.deinit(testing.allocator);
    try entries_enc.appendSlice(testing.allocator, std.mem.asBytes(&one));
    try instruction_bytecode.serializeValueIntoForImage(&entries_enc, .{ .struct_instance = key_instance }, testing.allocator, &enc_maps, null);
    try instruction_bytecode.serializeValueIntoForImage(&entries_enc, .{ .fixnum = 7 }, testing.allocator, &enc_maps, null);

    const st_name = "box";
    const field_name = "data";
    const field_names = [_][*]const u8{field_name.ptr};
    const field_lens = [_]u32{field_name.len};
    const struct_types = [_]StructType{.{
        .name = st_name.ptr,
        .name_len = st_name.len,
        .field_names = &field_names,
        .field_name_lens = &field_lens,
        .field_count = 1,
        .field_type_slots = null,
        .field_type_count = 0,
    }};

    const si_descs = [_]StructInstanceDescription{
        .{
            .slot = 0,
            .struct_type_slot = 0,
            .fields_bytecode = fields_enc.items.ptr,
            .fields_bytecode_len = @intCast(fields_enc.items.len),
        },
    };
    const mvm_descs = [_]MutableValueMapDescription{
        .{ .slot = 0, .entries_bytecode = entries_enc.items.ptr, .entries_bytecode_len = @intCast(entries_enc.items.len) },
    };

    var si_storage: [1]?*value_mod.StructInstance = .{null};
    var st_storage: [1]?*value_mod.StructType = .{null};
    var mvm_storage: [1]?*value_mod.MutableValueMap = .{null};

    var header = emptyHeader();
    header.struct_type_count = 1;
    header.struct_types = &struct_types;
    header.struct_instance_slot_count = 1;
    header.struct_instance_descriptions = &si_descs;
    header.mutable_value_map_slot_count = 1;
    header.mutable_value_map_descriptions = &mvm_descs;

    try loadIntoContext(&ctx, &header, .{
        .struct_types = &st_storage,
        .struct_instances = &si_storage,
        .mutable_value_maps = &mvm_storage,
    }, null);

    const map = mvm_storage[0] orelse return error.TestUnexpectedResult;
    const loaded_key = si_storage[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 99), loaded_key.fields[0].fixnum);

    const found = map.map.get(.{ .struct_instance = loaded_key }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 7), found.fixnum);
}

test "populateMutableValueMapEntries: an entry key reaches a tagged slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // The whole point of running this pass last. `populateTaggedSlots` has already filled the slot,
    // so the reference both resolves and holds its final inner value. The mutable-map loader
    // documents the same shape as unsupported, because it decodes its entries before that pass.
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

    var inner_enc: std.ArrayListUnmanaged(u8) = .{};
    defer inner_enc.deinit(testing.allocator);
    try instruction_bytecode.serializeValueInto(
        &inner_enc,
        value_mod.symbolValue("red"),
        testing.allocator,
        null,
        null,
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

    // A tagged key is interned by the pair of addresses, and the encoder reads neither target, so
    // these two stand in for the parse-time value the freeze would have interned.
    var encode_tag: value_mod.VirtualType = undefined;
    const encode_inner: value_mod.Value = .{ .fixnum = 0 };

    var mvm_index: std.AutoHashMapUnmanaged(*const value_mod.MutableValueMap, u32) = .{};
    defer mvm_index.deinit(testing.allocator);

    var enc_holder = EmptyEncodingIndices{};
    defer enc_holder.deinit();
    try enc_holder.tagged.put(
        testing.allocator,
        .{ .tag = &encode_tag, .inner_ptr = &encode_inner },
        0,
    );
    const enc_maps = enc_holder.maps(&mvm_index);

    const one: u32 = 1;
    var entries_enc: std.ArrayListUnmanaged(u8) = .{};
    defer entries_enc.deinit(testing.allocator);
    try entries_enc.appendSlice(testing.allocator, std.mem.asBytes(&one));
    try instruction_bytecode.serializeValueIntoForImage(
        &entries_enc,
        .{ .tagged = .{ .tag = &encode_tag, .inner = &encode_inner } },
        testing.allocator,
        &enc_maps,
        null,
    );
    try instruction_bytecode.serializeValueIntoForImage(&entries_enc, .{ .fixnum = 8 }, testing.allocator, &enc_maps, null);

    const mvm_descs = [_]MutableValueMapDescription{
        .{ .slot = 0, .entries_bytecode = entries_enc.items.ptr, .entries_bytecode_len = @intCast(entries_enc.items.len) },
    };

    var tv_storage: [2]?*const value_mod.TypeValue = .{ null, null };
    var tagged_storage: [1]?*const value_mod.Value = .{null};
    var mvm_storage: [1]?*value_mod.MutableValueMap = .{null};

    var header = emptyHeader();
    header.typevalue_slot_count = 2;
    header.typevalue_count = typevalues.len;
    header.typevalues = &typevalues;
    header.typedescriptors = &descriptors;
    header.tagged_slot_count = 1;
    header.tagged_descriptions = &tagged_descs;
    header.mutable_value_map_slot_count = 1;
    header.mutable_value_map_descriptions = &mvm_descs;

    try loadIntoContext(&ctx, &header, .{
        .typevalues = &tv_storage,
        .tagged = &tagged_storage,
        .mutable_value_maps = &mvm_storage,
    }, null);

    const map = mvm_storage[0] orelse return error.TestUnexpectedResult;
    const tagged_ptr = tagged_storage[0] orelse return error.TestUnexpectedResult;
    const found = map.map.get(tagged_ptr.*) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 8), found.fixnum);
}

test "installPendingValueMapEntries: an inline value_map keyed on a struct instance is findable" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // An inline `value_map` inside a mutable-map entries blob decodes during
    // `populateMutableMapSlots`, which runs before `populateStructInstanceFields`. Inserting its
    // struct-instance key there hashes over `.unit` placeholders, and `ValueEntries` stores that
    // hash, so the entry would be unreachable by the very key that was inserted.
    var struct_type = value_mod.StructType{ .name = "box", .fields = &.{"data"} };
    const key_instance = try value_mod.createStructInstance(
        testing.allocator,
        &struct_type,
        try testing.allocator.dupe(value_mod.Value, &.{.{ .fixnum = 99 }}),
    );
    defer container_backing.releaseValue(.{ .struct_instance = key_instance });

    var mvm_index: std.AutoHashMapUnmanaged(*const value_mod.MutableValueMap, u32) = .{};
    defer mvm_index.deinit(testing.allocator);

    var enc_holder = EmptyEncodingIndices{};
    defer enc_holder.deinit();
    try enc_holder.struct_instance.put(testing.allocator, key_instance, 0);
    try enc_holder.struct_type.put(testing.allocator, &struct_type, 0);
    const enc_maps = enc_holder.maps(&mvm_index);

    const one: u32 = 1;

    var fields_enc: std.ArrayListUnmanaged(u8) = .{};
    defer fields_enc.deinit(testing.allocator);
    try fields_enc.appendSlice(testing.allocator, std.mem.asBytes(&one));
    try instruction_bytecode.serializeValueIntoForImage(&fields_enc, .{ .fixnum = 99 }, testing.allocator, &enc_maps, null);

    // The inline value-map that rides inside the mutable map's entry, keyed on the slot reference.
    const inline_map = try value_mod.ValueMap.create(testing.allocator);
    defer inline_map.header.release();
    container_backing.retainValue(.{ .struct_instance = key_instance });
    try inline_map.map.put(testing.allocator, .{ .struct_instance = key_instance }, .{ .fixnum = 5 });

    var mm_enc: std.ArrayListUnmanaged(u8) = .{};
    defer mm_enc.deinit(testing.allocator);
    try mm_enc.appendSlice(testing.allocator, std.mem.asBytes(&one));
    const klen: u32 = 5;
    try mm_enc.appendSlice(testing.allocator, std.mem.asBytes(&klen));
    try mm_enc.appendSlice(testing.allocator, "inner");
    try instruction_bytecode.serializeValueIntoForImage(&mm_enc, .{ .value_map = inline_map }, testing.allocator, &enc_maps, null);

    const st_name = "box";
    const field_name = "data";
    const field_names = [_][*]const u8{field_name.ptr};
    const field_lens = [_]u32{field_name.len};
    const struct_types = [_]StructType{.{
        .name = st_name.ptr,
        .name_len = st_name.len,
        .field_names = &field_names,
        .field_name_lens = &field_lens,
        .field_count = 1,
        .field_type_slots = null,
        .field_type_count = 0,
    }};

    const si_descs = [_]StructInstanceDescription{
        .{
            .slot = 0,
            .struct_type_slot = 0,
            .fields_bytecode = fields_enc.items.ptr,
            .fields_bytecode_len = @intCast(fields_enc.items.len),
        },
    };
    const mm_descs = [_]MutableMapDescription{
        .{ .slot = 0, .entries_bytecode = mm_enc.items.ptr, .entries_bytecode_len = @intCast(mm_enc.items.len) },
    };

    var si_storage: [1]?*value_mod.StructInstance = .{null};
    var st_storage: [1]?*value_mod.StructType = .{null};
    var mm_storage: [1]?*value_mod.MutableMap = .{null};

    var header = emptyHeader();
    header.struct_type_count = 1;
    header.struct_types = &struct_types;
    header.struct_instance_slot_count = 1;
    header.struct_instance_descriptions = &si_descs;
    header.mutable_map_slot_count = 1;
    header.mutable_map_descriptions = &mm_descs;

    try loadIntoContext(&ctx, &header, .{
        .struct_types = &st_storage,
        .struct_instances = &si_storage,
        .mutable_maps = &mm_storage,
    }, null);

    const outer = mm_storage[0] orelse return error.TestUnexpectedResult;
    const loaded_key = si_storage[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 99), loaded_key.fields[0].fixnum);

    const inner = outer.map.get("inner") orelse return error.TestUnexpectedResult;
    try testing.expect(inner == .value_map);
    const found = inner.value_map.map.get(.{ .struct_instance = loaded_key }) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 5), found.fixnum);
}

test "installPendingValueMapEntries: two struct-instance keys in one inline value_map both survive" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Two distinct instances of one struct type. During the placeholder window every instance's
    // fields are `.unit`, and `Value.eql` compares a struct instance by descriptor plus fields, so
    // the two keys are indistinguishable at that moment. An insert that hashes then is not merely
    // misplaced: it reports a duplicate and drops the second entry outright, which is why the
    // entries are parked rather than hashed and re-indexed.
    var struct_type = value_mod.StructType{ .name = "box", .fields = &.{"data"} };
    const key_a = try value_mod.createStructInstance(
        testing.allocator,
        &struct_type,
        try testing.allocator.dupe(value_mod.Value, &.{.{ .fixnum = 1 }}),
    );
    defer container_backing.releaseValue(.{ .struct_instance = key_a });
    const key_b = try value_mod.createStructInstance(
        testing.allocator,
        &struct_type,
        try testing.allocator.dupe(value_mod.Value, &.{.{ .fixnum = 2 }}),
    );
    defer container_backing.releaseValue(.{ .struct_instance = key_b });

    var mvm_index: std.AutoHashMapUnmanaged(*const value_mod.MutableValueMap, u32) = .{};
    defer mvm_index.deinit(testing.allocator);

    var enc_holder = EmptyEncodingIndices{};
    defer enc_holder.deinit();
    try enc_holder.struct_instance.put(testing.allocator, key_a, 0);
    try enc_holder.struct_instance.put(testing.allocator, key_b, 1);
    try enc_holder.struct_type.put(testing.allocator, &struct_type, 0);
    const enc_maps = enc_holder.maps(&mvm_index);

    const one: u32 = 1;

    var fields_a: std.ArrayListUnmanaged(u8) = .{};
    defer fields_a.deinit(testing.allocator);
    try fields_a.appendSlice(testing.allocator, std.mem.asBytes(&one));
    try instruction_bytecode.serializeValueIntoForImage(&fields_a, .{ .fixnum = 1 }, testing.allocator, &enc_maps, null);

    var fields_b: std.ArrayListUnmanaged(u8) = .{};
    defer fields_b.deinit(testing.allocator);
    try fields_b.appendSlice(testing.allocator, std.mem.asBytes(&one));
    try instruction_bytecode.serializeValueIntoForImage(&fields_b, .{ .fixnum = 2 }, testing.allocator, &enc_maps, null);

    const inline_map = try value_mod.ValueMap.create(testing.allocator);
    defer inline_map.header.release();
    container_backing.retainValue(.{ .struct_instance = key_a });
    try inline_map.map.put(testing.allocator, .{ .struct_instance = key_a }, .{ .fixnum = 10 });
    container_backing.retainValue(.{ .struct_instance = key_b });
    try inline_map.map.put(testing.allocator, .{ .struct_instance = key_b }, .{ .fixnum = 20 });

    var mm_enc: std.ArrayListUnmanaged(u8) = .{};
    defer mm_enc.deinit(testing.allocator);
    try mm_enc.appendSlice(testing.allocator, std.mem.asBytes(&one));
    const klen: u32 = 5;
    try mm_enc.appendSlice(testing.allocator, std.mem.asBytes(&klen));
    try mm_enc.appendSlice(testing.allocator, "inner");
    try instruction_bytecode.serializeValueIntoForImage(&mm_enc, .{ .value_map = inline_map }, testing.allocator, &enc_maps, null);

    const st_name = "box";
    const field_name = "data";
    const field_names = [_][*]const u8{field_name.ptr};
    const field_lens = [_]u32{field_name.len};
    const struct_types = [_]StructType{.{
        .name = st_name.ptr,
        .name_len = st_name.len,
        .field_names = &field_names,
        .field_name_lens = &field_lens,
        .field_count = 1,
        .field_type_slots = null,
        .field_type_count = 0,
    }};

    const si_descs = [_]StructInstanceDescription{
        .{ .slot = 0, .struct_type_slot = 0, .fields_bytecode = fields_a.items.ptr, .fields_bytecode_len = @intCast(fields_a.items.len) },
        .{ .slot = 1, .struct_type_slot = 0, .fields_bytecode = fields_b.items.ptr, .fields_bytecode_len = @intCast(fields_b.items.len) },
    };
    const mm_descs = [_]MutableMapDescription{
        .{ .slot = 0, .entries_bytecode = mm_enc.items.ptr, .entries_bytecode_len = @intCast(mm_enc.items.len) },
    };

    var si_storage: [2]?*value_mod.StructInstance = .{ null, null };
    var st_storage: [1]?*value_mod.StructType = .{null};
    var mm_storage: [1]?*value_mod.MutableMap = .{null};

    var header = emptyHeader();
    header.struct_type_count = 1;
    header.struct_types = &struct_types;
    header.struct_instance_slot_count = 2;
    header.struct_instance_descriptions = &si_descs;
    header.mutable_map_slot_count = 1;
    header.mutable_map_descriptions = &mm_descs;

    try loadIntoContext(&ctx, &header, .{
        .struct_types = &st_storage,
        .struct_instances = &si_storage,
        .mutable_maps = &mm_storage,
    }, null);

    const outer = mm_storage[0] orelse return error.TestUnexpectedResult;
    const loaded_a = si_storage[0] orelse return error.TestUnexpectedResult;
    const loaded_b = si_storage[1] orelse return error.TestUnexpectedResult;

    const inner = outer.map.get("inner") orelse return error.TestUnexpectedResult;
    try testing.expect(inner == .value_map);
    try testing.expectEqual(@as(usize, 2), inner.value_map.map.count());

    const found_a = inner.value_map.map.get(.{ .struct_instance = loaded_a }) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 10), found_a.fixnum);
    const found_b = inner.value_map.map.get(.{ .struct_instance = loaded_b }) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 20), found_b.fixnum);
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
    try instruction_bytecode.serializeInstructionsInto(&encoded, &sample, null, testing.allocator, null, null);

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
    const declared = stack_effect_mod.StackEffect{
        .inputs = &.{},
        .outputs = &[_]stack_effect_mod.StackEffectParam{.{ .name = "n" }},
    };
    const outer = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner, .effect = &declared } } }, .line = 0, .column = 0 },
        .{ .op = .{ .call_word = "call" }, .line = 0, .column = 0 },
    };

    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &outer, null, testing.allocator, null, null);

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

    // The nested literal's declared effect survives the image round trip.
    const nested_effect = decoded[0].op.push_literal.quotation.effect.?;
    try testing.expectEqual(@as(usize, 0), nested_effect.inputs.len);
    try testing.expectEqual(@as(usize, 1), nested_effect.outputs.len);
    try testing.expectEqualStrings("n", nested_effect.outputs[0].name);
}

test "loadIntoContext: stamps decoded bodies and nested quotations with their module" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const inner = [_]value_mod.Instruction{
        .{ .op = .{ .call_word = "probe" }, .line = 0, .column = 0 },
    };
    const outer = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner } } }, .line = 0, .column = 0 },
    };

    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &outer, null, testing.allocator, null, null);

    const w_name = "handout";
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
    const module_ptr = entry.module;
    const mw = module_ptr.words.get(w_name) orelse return error.TestExpectedWord;
    const decoded = mw.action.compound;

    try testing.expectEqual(
        @as(?*const value_mod.Module, module_ptr),
        ctx.quotation_stamp_store.lookup(@intFromPtr(decoded.ptr)),
    );

    const nested = decoded[0].op.push_literal.quotation.instructions;
    try testing.expectEqual(
        @as(?*const value_mod.Module, module_ptr),
        ctx.quotation_stamp_store.lookup(@intFromPtr(nested.ptr)),
    );
}

test "replayMethodDispatch: stamps interpreter-run body with its module" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const inner = [_]value_mod.Instruction{
        .{ .op = .{ .call_word = "probe" }, .line = 0, .column = 0 },
    };
    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner } } }, .line = 0, .column = 0 },
        .{ .op = .{ .call_word = "call" }, .line = 0, .column = 0 },
    };

    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const m_name = "demo";
    const words = [_]Word{wordRow("stub", 0, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const rows = [_]DispatchEntryDescription{.{
        .dispatch_id = 7,
        .type_a_slot = dispatch_type_any,
        .type_b_slot = dispatch_type_unary,
        .quotation_id = populate_core.dispatch_interp_quotation_id_sentinel,
        .module_name = m_name.ptr,
        .module_name_len = m_name.len,
        .generic_name = null,
        .generic_name_len = 0,
        .body_bytecode = encoded.items.ptr,
        .body_bytecode_len = @intCast(encoded.items.len),
    }};
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.dispatch_entry_slot_count = 1;
    header.dispatch_entry_descriptions = &rows;

    try loadIntoContext(&ctx, &header, .{}, null);
    try replayMethodDispatch(&ctx);

    const entry = ctx.dispatch.entries.get(.{
        .dispatch_id = 7,
        .type_a = ctx.getDispatchAnySentinel().descriptor.?,
        .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
    }) orelse return error.TestExpectedEntry;
    const decoded = entry.body.quotation.instructions;
    try testing.expectEqual(@as(usize, 2), decoded.len);

    const cached = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const module_ptr = cached.module;
    try testing.expectEqual(@as(?*const value_mod.Module, module_ptr), entry.source_module);

    try testing.expectEqual(
        @as(?*const value_mod.Module, module_ptr),
        ctx.quotation_stamp_store.lookup(@intFromPtr(decoded.ptr)),
    );

    const nested = decoded[0].op.push_literal.quotation.instructions;
    try testing.expectEqual(
        @as(?*const value_mod.Module, module_ptr),
        ctx.quotation_stamp_store.lookup(@intFromPtr(nested.ptr)),
    );
}

test "populateParameterSlots: stamps a module-attributed default" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const inner = [_]value_mod.Instruction{
        .{ .op = .{ .call_word = "probe" }, .line = 0, .column = 0 },
    };
    const default_body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner } } }, .line = 0, .column = 0 },
        .{ .op = .{ .call_word = "call" }, .line = 0, .column = 0 },
    };

    const declared = stack_effect_mod.StackEffect{
        .inputs = &.{},
        .outputs = &[_]stack_effect_mod.StackEffectParam{.{ .name = "v" }},
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &default_body, &declared, testing.allocator, null, null);

    const m_name = "demo";
    const p_name = "p";
    const words = [_]Word{wordRow("stub", 0, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const param_rows = [_]ParameterDescription{.{
        .name = p_name.ptr,
        .name_len = p_name.len,
        .slot = 0,
        .default_quotation_bytecode = encoded.items.ptr,
        .default_quotation_bytecode_len = @intCast(encoded.items.len),
        .module_name = m_name.ptr,
        .module_name_len = m_name.len,
    }};
    var param_slots = [_]?*value_mod.Parameter{null};

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.parameter_slot_count = 1;
    header.parameter_descriptions = &param_rows;

    try loadIntoContext(&ctx, &header, .{ .parameters = &param_slots }, null);

    const cached = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const module_ptr = cached.module;
    const param = param_slots[0] orelse return error.TestExpectedParameter;

    try testing.expectEqual(
        @as(?*const value_mod.Module, module_ptr),
        ctx.quotation_stamp_store.lookup(@intFromPtr(param.default_quotation.instructions.ptr)),
    );

    const nested = param.default_quotation.instructions[0].op.push_literal.quotation.instructions;
    try testing.expectEqual(
        @as(?*const value_mod.Module, module_ptr),
        ctx.quotation_stamp_store.lookup(@intFromPtr(nested.ptr)),
    );

    // The default's declared effect survives the image round trip.
    const dec_eff = param.default_quotation.effect.?;
    try testing.expectEqual(@as(usize, 0), dec_eff.inputs.len);
    try testing.expectEqual(@as(usize, 1), dec_eff.outputs.len);
    try testing.expectEqualStrings("v", dec_eff.outputs[0].name);
}

test "populateOnceCellSlots: decodes the body, attaches its compiled function, and stamps it" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .call_word = "probe" }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    // The compiled function the row names. Never called here: the test is that the loader wires
    // the pointer through, which is what lets a force run without the interpreter.
    var fake_fn: u8 = 0;
    var quotation_table = [_]?*const anyopaque{@ptrCast(&fake_fn)};
    ctx.aot_quotation_fns = .{ .table = &quotation_table, .size = quotation_table.len };

    const m_name = "demo";
    const w_name = "answer";
    const words = [_]Word{wordRow("stub", 0, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const once_rows = [_]OnceCellDescription{.{
        .name = w_name.ptr,
        .name_len = w_name.len,
        .slot = 0,
        .body_bytecode = encoded.items.ptr,
        .body_bytecode_len = @intCast(encoded.items.len),
        .body_quotation_id = 0,
        .may_define = 1,
        .module_name = m_name.ptr,
        .module_name_len = m_name.len,
    }};
    var once_slots = [_]?*value_mod.OnceCell{null};

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.once_cell_slot_count = 1;
    header.once_cell_descriptions = &once_rows;

    try loadIntoContext(&ctx, &header, .{ .once_cells = &once_slots }, null);

    const cached = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const cell = once_slots[0] orelse return error.TestExpectedOnceCell;

    try testing.expectEqualStrings("answer", cell.name);
    try testing.expect(cell.may_define);
    try testing.expectEqual(value_mod.OnceCell.State.cold, cell.state.load(.acquire));
    try testing.expectEqual(@as(usize, 1), cell.body.instructions.len);
    try testing.expectEqual(@as(?*const anyopaque, @ptrCast(&fake_fn)), cell.body.code_ptr);
    try testing.expectEqual(
        @as(?*const value_mod.Module, cached.module),
        ctx.quotation_stamp_store.lookup(@intFromPtr(cell.body.instructions.ptr)),
    );
}

test "populateOnceCellSlots: an uncompiled body leaves the code pointer null" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const w_name = "answer";
    const once_rows = [_]OnceCellDescription{.{
        .name = w_name.ptr,
        .name_len = w_name.len,
        .slot = 0,
        .body_bytecode = encoded.items.ptr,
        .body_bytecode_len = @intCast(encoded.items.len),
        .body_quotation_id = instruction_bytecode.quotation_id_sentinel,
        .may_define = 0,
    }};
    var once_slots = [_]?*value_mod.OnceCell{null};

    var header = emptyHeader();
    header.once_cell_slot_count = 1;
    header.once_cell_descriptions = &once_rows;

    try loadIntoContext(&ctx, &header, .{ .once_cells = &once_slots }, null);

    const cell = once_slots[0] orelse return error.TestExpectedOnceCell;
    try testing.expectEqual(@as(?*const anyopaque, null), cell.body.code_ptr);
    // The decoded body is still there, so the interpreted path can run what did not compile.
    try testing.expectEqual(@as(usize, 1), cell.body.instructions.len);
}

/// A word row carrying `body` as bytecode and `set` as its inlined runs, for the two tests below.
fn inlineRegionWordRow(name: []const u8, encoded: []const u8, set: *const ImageInlineRegionSet) Word {
    var w = wordRow(name, 0, 0);
    w.body_bytecode = encoded.ptr;
    w.body_bytecode_len = @intCast(encoded.len);
    w.inline_regions = set;
    return w;
}

test "recordInlineRegions: a row's runs reach the table keyed by the decoded body" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .call_word = "stream-write" }, .line = 2, .column = 5 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2, .column = 18 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const m_name = "demo";
    const w_name = "outer";
    const inner_name = "inner";

    // Two files, because the set's and the run's are different quantities: the run's is where the
    // copied code was written, the set's is where the call it replaced sat. One string for both
    // would pass on a loader that read either into the other's slot.
    const caller_file = "demo.1z";
    const lib = "lib.1z";

    const regions = [_]ImageInlineRegion{.{
        .word_name = inner_name.ptr,
        .body_source = lib.ptr,
        .word_name_len = inner_name.len,
        .body_source_len = lib.len,
        .start = 0,
        .end = 2,
        .call_line = 9,
        .call_column = 3,
    }};
    const set: ImageInlineRegionSet = .{
        .body_source = caller_file.ptr,
        .regions = &regions,
        .body_source_len = caller_file.len,
        .region_count = regions.len,
    };

    const words = [_]Word{inlineRegionWordRow(w_name, encoded.items, &set)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;

    try loadIntoContext(&ctx, &header, .{}, null);

    const cached = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const mw = cached.module.words.get(w_name) orelse return error.TestExpectedWord;
    const recorded = ctx.inlineRegionsFor(mw.action.compound) orelse return error.TestExpectedRegions;

    try testing.expectEqualStrings(caller_file, recorded.body_source);
    try testing.expectEqual(@as(usize, 1), recorded.regions.len);
    try testing.expectEqualStrings(inner_name, recorded.regions[0].word_name);
    try testing.expectEqualStrings(lib, recorded.regions[0].body_source);
    try testing.expectEqual(@as(u32, 9), recorded.regions[0].call_line);
    try testing.expectEqual(@as(u32, 3), recorded.regions[0].call_column);

    // The row an error inside the run would queue, which is what the whole round trip is for.
    var frames = recorded.framesAt(0);
    const frame = frames.next() orelse return error.TestExpectedFrame;
    try testing.expectEqualStrings(inner_name, frame.word_name);
    try testing.expectEqualStrings(lib, frame.body_source);
    try testing.expectEqualStrings(caller_file, frame.call_source);
    try testing.expect(frames.next() == null);
}

test "recordInlineRegions: a run reaching past the decoded body fails the load" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1, .column = 1 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const m_name = "demo";
    const w_name = "outer";
    const inner_name = "inner";
    const lib = "lib.1z";

    // The body decodes to one instruction, so this run names an index it does not have.
    const regions = [_]ImageInlineRegion{.{
        .word_name = inner_name.ptr,
        .body_source = lib.ptr,
        .word_name_len = inner_name.len,
        .body_source_len = lib.len,
        .start = 0,
        .end = 4,
        .call_line = 9,
        .call_column = 3,
    }};
    const set: ImageInlineRegionSet = .{
        .body_source = lib.ptr,
        .regions = &regions,
        .body_source_len = lib.len,
        .region_count = regions.len,
    };

    const words = [_]Word{inlineRegionWordRow(w_name, encoded.items, &set)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;

    try testing.expectError(LoaderError.BadInlineRegion, loadIntoContext(&ctx, &header, .{}, null));
}

test "recordInlineRegions: a nested row's runs reach the body its path names" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Two levels, so the walk iterates rather than taking one step.
    const inner = [_]value_mod.Instruction{
        .{ .op = .{ .call_word = "stream-write" }, .line = 5, .column = 7 },
    };
    const middle = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner } } }, .line = 4, .column = 3 },
        .{ .op = .{ .call_word = "call" }, .line = 4, .column = 9 },
    };
    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2, .column = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &middle } } }, .line = 2, .column = 5 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const m_name = "demo";
    const w_name = "outer";
    const inner_name = "inner";
    const caller_file = "demo.1z";
    const lib = "lib.1z";

    const regions = [_]ImageInlineRegion{.{
        .word_name = inner_name.ptr,
        .body_source = lib.ptr,
        .word_name_len = inner_name.len,
        .body_source_len = lib.len,
        .start = 0,
        .end = 1,
        .call_line = 5,
        .call_column = 7,
    }};
    const path = [_]u32{ 1, 0 };
    const nested_rows = [_]ImageNestedInlineRegionSet{.{
        .path = &path,
        .path_len = path.len,
        .set = .{
            .body_source = caller_file.ptr,
            .regions = &regions,
            .body_source_len = caller_file.len,
            .region_count = regions.len,
        },
    }};

    var w = wordRow(w_name, 0, 0);
    w.body_bytecode = encoded.items.ptr;
    w.body_bytecode_len = @intCast(encoded.items.len);
    w.nested_inline_regions = &nested_rows;
    w.nested_inline_region_count = nested_rows.len;

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

    const cached = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const mw = cached.module.words.get(w_name) orelse return error.TestExpectedWord;

    // The word's own body carries nothing, and neither does the level between. Only the innermost
    // does, which is what the path is for: a decoded nested body has no name and no row of its own.
    try testing.expect(ctx.inlineRegionsFor(mw.action.compound) == null);

    const decoded_middle = mw.action.compound[1].op.push_literal.quotation.instructions;
    try testing.expect(ctx.inlineRegionsFor(decoded_middle) == null);

    const decoded_inner = decoded_middle[0].op.push_literal.quotation.instructions;
    const recorded = ctx.inlineRegionsFor(decoded_inner) orelse return error.TestExpectedRegions;
    try testing.expectEqualStrings(caller_file, recorded.body_source);
    try testing.expectEqual(@as(usize, 1), recorded.regions.len);
    try testing.expectEqualStrings(inner_name, recorded.regions[0].word_name);
    try testing.expectEqualStrings(lib, recorded.regions[0].body_source);
    try testing.expectEqual(@as(u32, 5), recorded.regions[0].call_line);
}

test "recordInlineRegions: a path not landing on a quotation fails the load" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1, .column = 1 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const m_name = "demo";
    const w_name = "outer";
    const inner_name = "inner";
    const lib = "lib.1z";

    const regions = [_]ImageInlineRegion{.{
        .word_name = inner_name.ptr,
        .body_source = lib.ptr,
        .word_name_len = inner_name.len,
        .body_source_len = lib.len,
        .start = 0,
        .end = 1,
        .call_line = 9,
        .call_column = 3,
    }};

    // Instruction 0 pushes a fixnum, so the walk has nothing to step into.
    const path = [_]u32{0};
    const nested_rows = [_]ImageNestedInlineRegionSet{.{
        .path = &path,
        .path_len = path.len,
        .set = .{
            .body_source = lib.ptr,
            .regions = &regions,
            .body_source_len = lib.len,
            .region_count = regions.len,
        },
    }};

    var w = wordRow(w_name, 0, 0);
    w.body_bytecode = encoded.items.ptr;
    w.body_bytecode_len = @intCast(encoded.items.len);
    w.nested_inline_regions = &nested_rows;
    w.nested_inline_region_count = nested_rows.len;

    const words = [_]Word{w};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;

    try testing.expectError(LoaderError.BadInlineRegion, loadIntoContext(&ctx, &header, .{}, null));
}

test "populateReifiedQuotationModules: keys rows by data pointer" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const m_name = "demo";
    const words = [_]Word{wordRow("stub", 0, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const data = [_]u8{ 1, 2, 3 };
    const rows = [_]populate_core.ReifiedQuotationModule{
        .{ .data = &data, .module_name = m_name.ptr, .module_name_len = m_name.len },
    };

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.reified_quotation_module_count = 1;
    header.reified_quotation_modules = &rows;

    try loadIntoContext(&ctx, &header, .{}, null);

    const cached = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const map = ctx.image_reified_quotation_modules orelse return error.TestExpectedTable;
    const module = map.get(@intFromPtr(&data)) orelse return error.TestExpectedEntry;
    try testing.expectEqual(@as(*const value_mod.Module, cached.module), module);
}

test "populateModuleDeps: fills owner deps from the source module's words" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const owner_name = "moda";
    const source_name = "modc";
    const dep_name = "probe";
    var probe = wordRow(dep_name, 1, 1);
    probe.body_bytecode = encoded.items.ptr;
    probe.body_bytecode_len = @intCast(encoded.items.len);
    const words = [_]Word{ wordRow("w", 0, 0), probe };
    const modules = [_]Module{
        .{ .name = owner_name.ptr, .name_len = owner_name.len, .word_start_idx = 0, .word_count = 1 },
        .{ .name = source_name.ptr, .name_len = source_name.len, .word_start_idx = 1, .word_count = 1 },
    };
    const deps = [_]ModuleDep{.{
        .module_idx = 0,
        .name = dep_name.ptr,
        .name_len = dep_name.len,
        .source_module_name = source_name.ptr,
        .source_module_name_len = source_name.len,
    }};

    var header = emptyHeader();
    header.module_count = 2;
    header.word_count = 2;
    header.modules = &modules;
    header.words = &words;
    header.module_dep_count = 1;
    header.module_deps = &deps;

    try loadIntoContext(&ctx, &header, .{}, null);

    const owner = (ctx.module_cache_value.map.get(owner_name) orelse return error.TestExpectedModule).module;
    const source = (ctx.module_cache_value.map.get(source_name) orelse return error.TestExpectedModule).module;
    const dep = owner.deps.get(dep_name) orelse return error.TestExpectedDep;
    try testing.expectEqual(@as(?*const value_mod.Module, source), dep.source_module);
    try testing.expectEqual(@as(usize, 1), dep.action.compound.len);
    try testing.expectEqual(@as(i64, 7), dep.action.compound[0].op.push_literal.fixnum);
}

test "call-target slots: a decoded baked call carries the target module's own definition" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // `caller`'s body is one baked call at slot 0, which the row points at `target`'s word index.
    const target_body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0, .column = 0 },
    };
    var target_enc: std.ArrayListUnmanaged(u8) = .{};
    defer target_enc.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&target_enc, &target_body, null, testing.allocator, null, null);

    var caller_enc: std.ArrayListUnmanaged(u8) = .{};
    defer caller_enc.deinit(testing.allocator);
    try caller_enc.append(testing.allocator, 0); // has_effect
    const one: u32 = 1;
    try caller_enc.appendSlice(testing.allocator, std.mem.asBytes(&one));
    const line: u32 = 3;
    const col: u32 = 5;
    try caller_enc.appendSlice(testing.allocator, std.mem.asBytes(&line));
    try caller_enc.appendSlice(testing.allocator, std.mem.asBytes(&col));
    try caller_enc.append(testing.allocator, 2); // op_tag_call_word_module
    const slot_index: u32 = 0;
    try caller_enc.appendSlice(testing.allocator, std.mem.asBytes(&slot_index));

    const m_name = "demo";
    var caller = wordRow("caller", 0, 0);
    caller.flags = aot_image_emit.flag_bit_image_decode;
    caller.body_bytecode = caller_enc.items.ptr;
    caller.body_bytecode_len = @intCast(caller_enc.items.len);
    var target = wordRow("target", 1, 0);
    target.body_bytecode = target_enc.items.ptr;
    target.body_bytecode_len = @intCast(target_enc.items.len);

    const words = [_]Word{ caller, target };
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 2 },
    };
    const call_targets = [_]u32{1};

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 2;
    header.modules = &modules;
    header.words = &words;
    header.call_target_count = 1;
    header.call_targets = &call_targets;

    try loadIntoContext(&ctx, &header, .{}, null);

    const module = (ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule).module;
    const decoded = (module.words.get("caller") orelse return error.TestExpectedWord).action.compound;
    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expect(decoded[0].op == .call_word_module);

    const slot = decoded[0].op.call_word_module;
    try testing.expectEqualStrings("target", slot.name);
    const def = dictionary_mod.loadSlot(slot).*;
    try testing.expectEqual(@as(?*const value_mod.Module, module), def.source_module);
    try testing.expectEqual(@as(?u32, 1), def.word_id);
    try testing.expectEqual(@as(usize, 1), def.action.compound.len);
    try testing.expectEqual(@as(i64, 7), def.action.compound[0].op.push_literal.fixnum);
}

test "call-target slots: an out-of-range row is rejected" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const m_name = "demo";
    const words = [_]Word{wordRow("only", 0, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const call_targets = [_]u32{7};

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.call_target_count = 1;
    header.call_targets = &call_targets;

    try testing.expectError(LoaderError.BadWordIndex, loadIntoContext(&ctx, &header, .{}, null));
}

test "populateModuleDeps: unresolvable rows are skipped, bad owner index errors" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const m_name = "demo";
    const stub_name = "stub";
    const words = [_]Word{wordRow(stub_name, 0, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const unknown_module = "nowhere";
    const unknown_word = "ghost";
    const deps = [_]ModuleDep{
        .{
            .module_idx = 0,
            .name = stub_name.ptr,
            .name_len = stub_name.len,
            .source_module_name = unknown_module.ptr,
            .source_module_name_len = unknown_module.len,
        },
        .{
            .module_idx = 0,
            .name = unknown_word.ptr,
            .name_len = unknown_word.len,
            .source_module_name = m_name.ptr,
            .source_module_name_len = m_name.len,
        },
    };

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.module_dep_count = 2;
    header.module_deps = &deps;

    try loadIntoContext(&ctx, &header, .{}, null);

    const cached = (ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule).module;
    try testing.expectEqual(@as(usize, 0), cached.deps.count());

    var bad_ctx = Context.init(testing.allocator);
    defer bad_ctx.deinit();
    const bad_deps = [_]ModuleDep{.{
        .module_idx = 5,
        .name = unknown_word.ptr,
        .name_len = unknown_word.len,
        .source_module_name = m_name.ptr,
        .source_module_name_len = m_name.len,
    }};
    var bad_header = emptyHeader();
    bad_header.module_count = 1;
    bad_header.word_count = 1;
    bad_header.modules = &modules;
    bad_header.words = &words;
    bad_header.module_dep_count = 1;
    bad_header.module_deps = &bad_deps;
    try testing.expectError(
        LoaderError.BadWordIndex,
        loadIntoContext(&bad_ctx, &bad_header, .{}, null),
    );
}

test "populateEntryImports: writes imports into the durable entry frame the binary pushed" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Stand in for the prelude frame `loadPrelude` would have pushed, then the entry frame
    // `onez_push_entry_frame` builds at boot, before any image load.
    try ctx.pushLocalFrame();
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 1;
    ctx.durable_frame_floor = 1;
    ctx.image_entry_import_frame = 1;

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const source_name = "modc";
    const import_name = "probe";
    var probe = wordRow(import_name, 9, 0);
    probe.body_bytecode = encoded.items.ptr;
    probe.body_bytecode_len = @intCast(encoded.items.len);
    const words = [_]Word{probe};
    const modules = [_]Module{
        .{ .name = source_name.ptr, .name_len = source_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const unknown_module = "nowhere";
    const unknown_word = "ghost";
    const imports = [_]EntryImport{
        .{
            .name = import_name.ptr,
            .name_len = import_name.len,
            .source_module_name = source_name.ptr,
            .source_module_name_len = source_name.len,
        },
        .{
            .name = unknown_word.ptr,
            .name_len = unknown_word.len,
            .source_module_name = source_name.ptr,
            .source_module_name_len = source_name.len,
        },
        .{
            .name = import_name.ptr,
            .name_len = import_name.len,
            .source_module_name = unknown_module.ptr,
            .source_module_name_len = unknown_module.len,
        },
    };

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.entry_import_count = 3;
    header.entry_imports = &imports;

    try loadIntoContext(&ctx, &header, .{}, null);

    // The loader pushes nothing of its own.
    try testing.expectEqual(@as(usize, 2), ctx.local_frames.items.len);
    try testing.expectEqual(@as(?usize, 1), ctx.import_frame_index);
    try testing.expectEqual(@as(?usize, 1), ctx.image_entry_import_frame);

    const source = (ctx.module_cache_value.map.get(source_name) orelse return error.TestExpectedModule).module;
    const frame = &ctx.local_frames.items[1];
    try testing.expectEqual(@as(usize, 1), frame.count());
    const def = frame.get(import_name) orelse return error.TestExpectedImport;
    try testing.expect(def.imported);
    try testing.expectEqual(@as(?*const value_mod.Module, source), def.source_module);
    try testing.expectEqual(@as(?u32, 9), def.word_id);
    try testing.expectEqual(@as(usize, 1), def.action.compound.len);
    try testing.expectEqual(@as(i64, 7), def.action.compound[0].op.push_literal.fixnum);
}

test "populateEntryImports: skipped when no durable frame exists" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const source_name = "modc";
    const import_name = "probe";
    const words = [_]Word{wordRow(import_name, 0, 0)};
    const modules = [_]Module{
        .{ .name = source_name.ptr, .name_len = source_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const imports = [_]EntryImport{.{
        .name = import_name.ptr,
        .name_len = import_name.len,
        .source_module_name = source_name.ptr,
        .source_module_name_len = source_name.len,
    }};

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.entry_import_count = 1;
    header.entry_imports = &imports;

    try loadIntoContext(&ctx, &header, .{}, null);

    try testing.expectEqual(@as(usize, 0), ctx.local_frames.items.len);
    try testing.expectEqual(@as(?usize, null), ctx.image_entry_import_frame);
}

test "populateEntryImports: skipped when the boot never pushed the entry frame" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // An embedder's shape: a prelude frame names `import_frame_index`, but nothing set
    // `image_entry_import_frame`. The pass must skip rather than plant the import in the prelude
    // frame, which sits in the base scope the shadow probe reads.
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    const source_name = "modc";
    const import_name = "probe";
    const words = [_]Word{wordRow(import_name, 0, 0)};
    const modules = [_]Module{
        .{ .name = source_name.ptr, .name_len = source_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const imports = [_]EntryImport{.{
        .name = import_name.ptr,
        .name_len = import_name.len,
        .source_module_name = source_name.ptr,
        .source_module_name_len = source_name.len,
    }};

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.entry_import_count = 1;
    header.entry_imports = &imports;

    try loadIntoContext(&ctx, &header, .{}, null);

    try testing.expectEqual(@as(usize, 1), ctx.local_frames.items.len);
    try testing.expectEqual(@as(usize, 0), ctx.local_frames.items[0].count());
    try testing.expectEqual(@as(?usize, null), ctx.image_entry_import_frame);
}

test "replayMethodDispatch: patches an entry-import frame def's dispatch_id" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // The interpreter-free boot shape: the entry frame is frame 0, with no prelude frame below it.
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    ctx.image_entry_import_frame = 0;

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const source_name = "modc";
    const generic_name = "gword";
    const words = [_]Word{wordRow(generic_name, 0, 0)};
    const modules = [_]Module{
        .{ .name = source_name.ptr, .name_len = source_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    const imports = [_]EntryImport{.{
        .name = generic_name.ptr,
        .name_len = generic_name.len,
        .source_module_name = source_name.ptr,
        .source_module_name_len = source_name.len,
    }};
    const rows = [_]DispatchEntryDescription{.{
        .dispatch_id = 7,
        .type_a_slot = dispatch_type_any,
        .type_b_slot = dispatch_type_unary,
        .quotation_id = populate_core.dispatch_interp_quotation_id_sentinel,
        .module_name = source_name.ptr,
        .module_name_len = source_name.len,
        .generic_name = generic_name.ptr,
        .generic_name_len = generic_name.len,
        .body_bytecode = encoded.items.ptr,
        .body_bytecode_len = @intCast(encoded.items.len),
    }};

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.entry_import_count = 1;
    header.entry_imports = &imports;
    header.dispatch_entry_slot_count = 1;
    header.dispatch_entry_descriptions = &rows;

    try loadIntoContext(&ctx, &header, .{}, null);
    try replayMethodDispatch(&ctx);

    const frame_idx = ctx.image_entry_import_frame orelse return error.TestExpectedFrame;
    const def = ctx.local_frames.items[frame_idx].get(generic_name) orelse return error.TestExpectedImport;
    try testing.expectEqual(@as(u32, 7), def.dispatch_id);
}

test "replayMethodDispatch: advances the mint counter past the replayed ids" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const generic_name = "gword";
    const rows = [_]DispatchEntryDescription{.{
        .dispatch_id = 5000,
        .type_a_slot = dispatch_type_any,
        .type_b_slot = dispatch_type_unary,
        .quotation_id = populate_core.dispatch_interp_quotation_id_sentinel,
        .module_name = null,
        .module_name_len = 0,
        .generic_name = generic_name.ptr,
        .generic_name_len = generic_name.len,
        .body_bytecode = encoded.items.ptr,
        .body_bytecode_len = @intCast(encoded.items.len),
    }};

    var header = emptyHeader();
    header.dispatch_entry_slot_count = 1;
    header.dispatch_entry_descriptions = &rows;

    try loadIntoContext(&ctx, &header, .{}, null);
    try replayMethodDispatch(&ctx);

    try testing.expect(ctx.next_dispatch_id.load(.monotonic) > 5000);
}

test "replayMethodDispatch: patches a dep entry's dispatch_id like a word entry" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const owner_name = "moda";
    const source_name = "modc";
    const generic_name = "gword";
    const words = [_]Word{ wordRow("w", 0, 0), wordRow(generic_name, 1, 1) };
    const modules = [_]Module{
        .{ .name = owner_name.ptr, .name_len = owner_name.len, .word_start_idx = 0, .word_count = 1 },
        .{ .name = source_name.ptr, .name_len = source_name.len, .word_start_idx = 1, .word_count = 1 },
    };
    const deps = [_]ModuleDep{.{
        .module_idx = 0,
        .name = generic_name.ptr,
        .name_len = generic_name.len,
        .source_module_name = source_name.ptr,
        .source_module_name_len = source_name.len,
    }};
    const rows = [_]DispatchEntryDescription{.{
        .dispatch_id = 7,
        .type_a_slot = dispatch_type_any,
        .type_b_slot = dispatch_type_unary,
        .quotation_id = populate_core.dispatch_interp_quotation_id_sentinel,
        .module_name = source_name.ptr,
        .module_name_len = source_name.len,
        .generic_name = generic_name.ptr,
        .generic_name_len = generic_name.len,
        .body_bytecode = encoded.items.ptr,
        .body_bytecode_len = @intCast(encoded.items.len),
    }};

    var header = emptyHeader();
    header.module_count = 2;
    header.word_count = 2;
    header.modules = &modules;
    header.words = &words;
    header.module_dep_count = 1;
    header.module_deps = &deps;
    header.dispatch_entry_slot_count = 1;
    header.dispatch_entry_descriptions = &rows;

    try loadIntoContext(&ctx, &header, .{}, null);
    try replayMethodDispatch(&ctx);

    const owner = (ctx.module_cache_value.map.get(owner_name) orelse return error.TestExpectedModule).module;
    const source = (ctx.module_cache_value.map.get(source_name) orelse return error.TestExpectedModule).module;
    const word = source.words.get(generic_name) orelse return error.TestExpectedWord;
    try testing.expectEqual(@as(u32, 7), word.dispatch_id);
    const dep = owner.deps.get(generic_name) orelse return error.TestExpectedDep;
    try testing.expectEqual(@as(u32, 7), dep.dispatch_id);
}

test "populateModulesAndWords: private-flagged rows land in deps, coexisting with a same-named word" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const pub_body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    };
    const priv_body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0, .column = 0 },
    };
    const helper_body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 0, .column = 0 },
    };
    var pub_encoded: std.ArrayListUnmanaged(u8) = .{};
    defer pub_encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&pub_encoded, &pub_body, null, testing.allocator, null, null);
    var priv_encoded: std.ArrayListUnmanaged(u8) = .{};
    defer priv_encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&priv_encoded, &priv_body, null, testing.allocator, null, null);
    var helper_encoded: std.ArrayListUnmanaged(u8) = .{};
    defer helper_encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&helper_encoded, &helper_body, null, testing.allocator, null, null);

    const m_name = "demo";
    var pub_row = wordRow("dup", 0, 0);
    pub_row.body_bytecode = pub_encoded.items.ptr;
    pub_row.body_bytecode_len = @intCast(pub_encoded.items.len);
    var priv_row = wordRow("dup", 1, 0);
    priv_row.flags = aot_image_emit.flag_bit_module_private;
    priv_row.body_bytecode = priv_encoded.items.ptr;
    priv_row.body_bytecode_len = @intCast(priv_encoded.items.len);
    var helper_row = wordRow("helper", 2, 0);
    helper_row.flags = aot_image_emit.flag_bit_module_private;
    helper_row.body_bytecode = helper_encoded.items.ptr;
    helper_row.body_bytecode_len = @intCast(helper_encoded.items.len);

    const words = [_]Word{ pub_row, priv_row, helper_row };
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 3 },
    };
    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 3;
    header.modules = &modules;
    header.words = &words;

    try loadIntoContext(&ctx, &header, .{}, null);

    const module_ptr = (ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule).module;

    // The public row is the only entry in `words`; both flagged rows are in `deps`, each with its
    // own decoded body.
    try testing.expectEqual(@as(usize, 1), module_ptr.words.count());
    try testing.expectEqual(@as(usize, 2), module_ptr.deps.count());
    const pub_dup = module_ptr.words.get("dup") orelse return error.TestExpectedWord;
    try testing.expectEqual(@as(i64, 1), pub_dup.action.compound[0].op.push_literal.fixnum);
    const priv_dup = module_ptr.deps.get("dup") orelse return error.TestExpectedDep;
    try testing.expectEqual(@as(i64, 2), priv_dup.action.compound[0].op.push_literal.fixnum);
    const helper = module_ptr.deps.get("helper") orelse return error.TestExpectedDep;
    try testing.expectEqual(@as(i64, 3), helper.action.compound[0].op.push_literal.fixnum);
    try testing.expectEqual(@as(?*const value_mod.Module, module_ptr), helper.source_module);
    try testing.expect(module_ptr.words.get("helper") == null);

    // End-to-end resolution: the own-module probe reaches the helper and prefers the public
    // `dup`, while resolution without the owning module never sees the helper -- the module-cache
    // scan reads `words` only.
    ctx.runtime_image_loaded = true;
    const probed = ctx.lookupWordForExecutionOwnScope("helper", null, module_ptr, &.{}, 0) orelse
        return error.TestExpectedProbeHit;
    try testing.expectEqual(@as(i64, 3), probed.action.compound[0].op.push_literal.fixnum);
    const probed_dup = ctx.lookupWordForExecutionOwnScope("dup", null, module_ptr, &.{}, 0) orelse
        return error.TestExpectedProbeHit;
    try testing.expectEqual(@as(i64, 1), probed_dup.action.compound[0].op.push_literal.fixnum);
    try testing.expect(ctx.lookupWordForExecutionOwnScope("helper", null, null, &.{}, 0) == null);
}

test "loadIntoContext: stamps a private helper's decoded body with the owning module" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const inner = [_]value_mod.Instruction{
        .{ .op = .{ .call_word = "probe" }, .line = 0, .column = 0 },
    };
    const outer = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner } } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &outer, null, testing.allocator, null, null);

    const m_name = "demo";
    var w = wordRow("helper", 1, 0);
    w.flags = aot_image_emit.flag_bit_module_private;
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

    const module_ptr = (ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule).module;
    const mw = module_ptr.deps.get("helper") orelse return error.TestExpectedDep;
    const decoded = mw.action.compound;

    try testing.expectEqual(
        @as(?*const value_mod.Module, module_ptr),
        ctx.quotation_stamp_store.lookup(@intFromPtr(decoded.ptr)),
    );
    const nested = decoded[0].op.push_literal.quotation.instructions;
    try testing.expectEqual(
        @as(?*const value_mod.Module, module_ptr),
        ctx.quotation_stamp_store.lookup(@intFromPtr(nested.ptr)),
    );
}

test "decodeWordBodies: provenanced private row decodes into the deps entry" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 9 } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const m_name = "demo";
    const gen = "struct{";
    const parent = "point";
    const role = "getter";
    var w = wordRow("x>>", 1, 0);
    w.flags = aot_image_emit.flag_bit_module_private | aot_image_emit.flag_bit_image_decode;
    w.body_bytecode = encoded.items.ptr;
    w.body_bytecode_len = @intCast(encoded.items.len);
    w.provenance_generator = gen.ptr;
    w.provenance_generator_len = gen.len;
    w.provenance_parent = parent.ptr;
    w.provenance_parent_len = parent.len;
    w.provenance_role = role.ptr;
    w.provenance_role_len = role.len;
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

    // A row flagged for image decode skips the inline pass, so a body here proves the deferred
    // image pass resolved the deps entry by its private flag.
    const module_ptr = (ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule).module;
    const mw = module_ptr.deps.get("x>>") orelse return error.TestExpectedDep;
    try testing.expectEqual(@as(usize, 1), mw.action.compound.len);
    try testing.expectEqual(@as(i64, 9), mw.action.compound[0].op.push_literal.fixnum);
    try testing.expect(module_ptr.words.get("x>>") == null);
}

test "populateModulesAndWords: blob private row loads as an empty deps body" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const m_name = "demo";
    var w = wordRow("blob-helper", 1, 0);
    w.flags = aot_image_emit.flag_bit_module_private;
    w.classification = 1;
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

    // The empty compound body is the empty-compound backfill's precondition: a compiled helper
    // still dispatches by bare name.
    const module_ptr = (ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule).module;
    const mw = module_ptr.deps.get("blob-helper") orelse return error.TestExpectedDep;
    try testing.expectEqual(@as(usize, 0), mw.action.compound.len);
    try testing.expectEqual(@as(?*const value_mod.Module, module_ptr), mw.source_module);
}

test "replayMethodDispatch: patches a private deps entry and templates the helper" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const m_name = "demo";
    const generic_name = "gword";
    var priv_row = wordRow(generic_name, 1, 0);
    priv_row.flags = aot_image_emit.flag_bit_module_private;
    priv_row.body_bytecode = encoded.items.ptr;
    priv_row.body_bytecode_len = @intCast(encoded.items.len);
    const words = [_]Word{ wordRow("w", 0, 0), priv_row };
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 2 },
    };
    const rows = [_]DispatchEntryDescription{.{
        .dispatch_id = 7,
        .type_a_slot = dispatch_type_any,
        .type_b_slot = dispatch_type_unary,
        .quotation_id = populate_core.dispatch_interp_quotation_id_sentinel,
        .module_name = m_name.ptr,
        .module_name_len = m_name.len,
        .generic_name = generic_name.ptr,
        .generic_name_len = generic_name.len,
        .body_bytecode = encoded.items.ptr,
        .body_bytecode_len = @intCast(encoded.items.len),
    }};

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 2;
    header.modules = &modules;
    header.words = &words;
    header.dispatch_entry_slot_count = 1;
    header.dispatch_entry_descriptions = &rows;

    try loadIntoContext(&ctx, &header, .{}, null);
    try replayMethodDispatch(&ctx);

    const module_ptr = (ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule).module;
    const dep = module_ptr.deps.get(generic_name) orelse return error.TestExpectedDep;
    try testing.expectEqual(@as(u32, 7), dep.dispatch_id);

    // The warmed deps template merges `deps` under `words`, so the private helper is present and
    // the template fast path admits probes for it.
    const tmpl = module_ptr.deps_template orelse return error.TestExpectedTemplate;
    try testing.expect(tmpl.frame.get(generic_name) != null);
    try testing.expect(tmpl.frame.get("w") != null);
}

test "loadIntoContext: truncated body bytecode surfaces TruncatedBytecode" {
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
        LoaderError.TruncatedBytecode,
        loadIntoContext(&ctx, &header, .{}, null),
    );

    // The decoder's diagnostic reaches the detail row: the count read fails one byte in.
    try testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    const row = ctx.error_details.items[0];
    try testing.expectEqualStrings("runtime-image-load-failed", row.error_type);
    try testing.expectEqualStrings("truncated bytecode at offset 1", row.message);
}

test "loadIntoContext: an image-decode flag defers a by-value-decodable body to the image pass" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 4 } }, .line = 0, .column = 0 },
    };
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try instruction_bytecode.serializeInstructionsInto(&encoded, &body, null, testing.allocator, null, null);

    const m_name = "demo";
    var w = wordRow("deferred", 1, 0);
    w.flags = aot_image_emit.flag_bit_image_decode;
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

    // The flag alone routes the body to `decodeWordBodies`, so a populated compound proves the
    // deferred pass decoded it rather than the inline pass.
    const module_ptr = (ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule).module;
    const mw = module_ptr.words.get("deferred") orelse return error.TestExpectedWord;
    try testing.expectEqual(@as(usize, 1), mw.action.compound.len);
    try testing.expectEqual(@as(i64, 4), mw.action.compound[0].op.push_literal.fixnum);
}

test "loadIntoContext: an unflagged body carrying an image-only tag fails instead of loading empty" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // One baked call, hand-encoded: `has_effect 0 | count 1 | line | column | tag 2 | slot 0`.
    // The row's flag is clear, so the inline by-value decoder reads it and rejects the tag. An
    // emitter that bakes a target but drops the flag is the drift this pins as a hard error.
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try encoded.append(testing.allocator, 0);
    const one: u32 = 1;
    try encoded.appendSlice(testing.allocator, std.mem.asBytes(&one));
    const line: u32 = 1;
    const col: u32 = 1;
    try encoded.appendSlice(testing.allocator, std.mem.asBytes(&line));
    try encoded.appendSlice(testing.allocator, std.mem.asBytes(&col));
    try encoded.append(testing.allocator, 2);
    const slot_index: u32 = 0;
    try encoded.appendSlice(testing.allocator, std.mem.asBytes(&slot_index));

    const m_name = "demo";
    var w = wordRow("drifted", 1, 0);
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

    try testing.expectError(
        LoaderError.UnknownTag,
        loadIntoContext(&ctx, &header, .{}, null),
    );

    // The detail row distinguishes an image-only tag from a byte that is no tag at all.
    try testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    const row = ctx.error_details.items[0];
    try testing.expectEqualStrings("runtime-image-load-failed", row.error_type);
    try testing.expectEqualStrings("image-only tag 2 at offset 13 reached the by-value decoder", row.message);
}

test "loadIntoContext: an unresolved value slot surfaces UnresolvedSlot with an image-slot-miss row" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Flagged body, hand-encoded: `has_effect 0 | count 1 | line | column | op tag push_literal |
    // value tag type_val_slot | u32 slot 5`. The header carries no typevalue storage, so the
    // decoder cannot resolve the slot.
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    try encoded.append(testing.allocator, 0);
    const one: u32 = 1;
    try encoded.appendSlice(testing.allocator, std.mem.asBytes(&one));
    const line: u32 = 1;
    const col: u32 = 1;
    try encoded.appendSlice(testing.allocator, std.mem.asBytes(&line));
    try encoded.appendSlice(testing.allocator, std.mem.asBytes(&col));
    try encoded.append(testing.allocator, 0);
    try encoded.append(testing.allocator, 10);
    const slot_index: u32 = 5;
    try encoded.appendSlice(testing.allocator, std.mem.asBytes(&slot_index));

    const m_name = "demo";
    var w = wordRow("dangling", 1, 0);
    w.flags = aot_image_emit.flag_bit_image_decode;
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

    try testing.expectError(
        LoaderError.UnresolvedSlot,
        loadIntoContext(&ctx, &header, .{}, null),
    );

    // The miss reports through the same helper the jitPush*Slot callbacks use, so the row
    // carries the shared shape.
    try testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    const row = ctx.error_details.items[0];
    try testing.expectEqualStrings("image-slot-miss", row.error_type);
    try testing.expectEqualStrings("typevalue slot 5", row.message);
}

test "loadIntoContext: a truncated mutable-map entries blob surfaces TruncatedBytecode" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Framing claims one entry, then the blob ends before the key length.
    var encoded: std.ArrayListUnmanaged(u8) = .{};
    defer encoded.deinit(testing.allocator);
    const one: u32 = 1;
    try encoded.appendSlice(testing.allocator, std.mem.asBytes(&one));

    const descs = [_]MutableMapDescription{
        .{ .slot = 0, .entries_bytecode = encoded.items.ptr, .entries_bytecode_len = @intCast(encoded.items.len) },
    };
    var mm_storage: [1]?*value_mod.MutableMap = .{null};

    var header = emptyHeader();
    header.mutable_map_slot_count = 1;
    header.mutable_map_descriptions = &descs;

    try testing.expectError(
        LoaderError.TruncatedBytecode,
        loadIntoContext(&ctx, &header, .{ .mutable_maps = &mm_storage }, null),
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

fn paramRow(name: []const u8) StackEffectParam {
    return .{
        .name = name.ptr,
        .name_len = @intCast(name.len),
        .is_row_variable = 0,
        .annotation_kind = StackEffectParam.annotation_none,
        .has_quotation_effect = 0,
        ._reserved = 0,
        .annotation_slot = 0,
        .quotation_effect_idx = 0,
    };
}

fn protocolParamRow(name: []const u8, slot: u32) StackEffectParam {
    var row = paramRow(name);
    row.annotation_kind = StackEffectParam.annotation_protocol;
    row.annotation_slot = slot;
    return row;
}

test "loadIntoContext: protocol descriptor slot reconstructs from description row" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Effect index 1 for the cmp method: ( a b -- r ).
    const cmp_inputs = [_]StackEffectParam{ paramRow("a"), paramRow("b") };
    const cmp_outputs = [_]StackEffectParam{paramRow("r")};
    const effects = [_]StackEffect{
        .{ .inputs = null, .input_count = 0, .outputs = null, .output_count = 0 },
        .{ .inputs = &cmp_inputs, .input_count = 2, .outputs = &cmp_outputs, .output_count = 1 },
    };

    const pd_name = "orderly";
    const method_rows = [_]ProtocolMethod{
        .{ .name = "cmp", .name_len = 3, .stack_effect_idx = 1 },
        .{ .name = "show", .name_len = 4, .stack_effect_idx = 0 },
    };
    const descs = [_]ProtocolDescriptorDescription{.{
        .name = pd_name.ptr,
        .name_len = pd_name.len,
        .slot = 0,
        .protocol_id = 7,
        .method_count = 2,
        .methods = &method_rows,
    }};

    var header = emptyHeader();
    header.stack_effect_count = 2;
    header.stack_effects = &effects;
    header.protocoldescriptor_slot_count = 1;
    header.protocoldescriptor_descriptions = &descs;

    var slots = [_]?*const value_mod.ProtocolDescriptor{null};
    try loadIntoContext(&ctx, &header, .{ .protocol_descriptors = &slots }, null);

    const pd = slots[0] orelse return error.TestExpectedDescriptor;
    try testing.expectEqualStrings("orderly", pd.name);
    try testing.expectEqual(@as(u32, 7), pd.protocol_id);

    // Flat symbol/effect sequence: cmp + its effect, then bare show.
    try testing.expectEqual(@as(usize, 3), pd.methods.len);
    try testing.expectEqualStrings("cmp", pd.methods[0].symbol.bytes);
    try testing.expect(pd.methods[1] == .stack_effect);
    try testing.expectEqual(@as(usize, 2), pd.methods[1].stack_effect.inputs.len);
    try testing.expectEqual(@as(usize, 1), pd.methods[1].stack_effect.outputs.len);
    try testing.expectEqualStrings("show", pd.methods[2].symbol.bytes);

    // The slot pointer is the registered descriptor: identity is
    // single-sourced for the satisfies-memo and introspection.
    try testing.expectEqual(@as(usize, 1), ctx.protocol_descriptors.items.len);
    try testing.expectEqual(@as(*const value_mod.ProtocolDescriptor, ctx.protocol_descriptors.items[0]), pd);

    // next_protocol_id advanced past the serialized id.
    try testing.expect(ctx.next_protocol_id.load(.monotonic) >= 8);
}

test "loadIntoContext: protocol descriptor slot reuses same-named runtime descriptor" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const existing = try ctx.createProtocolDescriptor("orderly", &.{value_mod.symbolValue("cmp")});

    const pd_name = "orderly";
    const descs = [_]ProtocolDescriptorDescription{.{
        .name = pd_name.ptr,
        .name_len = pd_name.len,
        .slot = 0,
        .protocol_id = 9,
        .method_count = 0,
        .methods = null,
    }};

    var header = emptyHeader();
    header.protocoldescriptor_slot_count = 1;
    header.protocoldescriptor_descriptions = &descs;

    var slots = [_]?*const value_mod.ProtocolDescriptor{null};
    try loadIntoContext(&ctx, &header, .{ .protocol_descriptors = &slots }, null);

    // The slot points at the pre-existing descriptor; nothing new was
    // registered and the serialized fields were ignored.
    try testing.expectEqual(@as(?*const value_mod.ProtocolDescriptor, existing), slots[0]);
    try testing.expectEqual(@as(usize, 1), ctx.protocol_descriptors.items.len);
    try testing.expect(existing.protocol_id != 9);
}

test "loadIntoContext: protocol method with out-of-range effect index errors" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const pd_name = "orderly";
    const method_rows = [_]ProtocolMethod{
        .{ .name = "cmp", .name_len = 3, .stack_effect_idx = 9 },
    };
    const descs = [_]ProtocolDescriptorDescription{.{
        .name = pd_name.ptr,
        .name_len = pd_name.len,
        .slot = 0,
        .protocol_id = 1,
        .method_count = 1,
        .methods = &method_rows,
    }};

    var header = emptyHeader();
    header.protocoldescriptor_slot_count = 1;
    header.protocoldescriptor_descriptions = &descs;

    var slots = [_]?*const value_mod.ProtocolDescriptor{null};
    try testing.expectError(
        LoaderError.BadStackEffectIndex,
        loadIntoContext(&ctx, &header, .{ .protocol_descriptors = &slots }, null),
    );
}

test "loadIntoContext: word effect param restores protocol annotation through slot table" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Effect index 1: ( x: orderly -- ) referencing protocol slot 0.
    const bounded_inputs = [_]StackEffectParam{protocolParamRow("x", 0)};
    const effects = [_]StackEffect{
        .{ .inputs = null, .input_count = 0, .outputs = null, .output_count = 0 },
        .{ .inputs = &bounded_inputs, .input_count = 1, .outputs = null, .output_count = 0 },
    };

    const pd_name = "orderly";
    const descs = [_]ProtocolDescriptorDescription{.{
        .name = pd_name.ptr,
        .name_len = pd_name.len,
        .slot = 0,
        .protocol_id = 3,
        .method_count = 0,
        .methods = null,
    }};

    const w_name = "bounded";
    const m_name = "demo";
    var w = wordRow(w_name, 1, 0);
    w.stack_effect_idx = 1;
    const words = [_]Word{w};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.stack_effect_count = 2;
    header.stack_effects = &effects;
    header.protocoldescriptor_slot_count = 1;
    header.protocoldescriptor_descriptions = &descs;

    var slots = [_]?*const value_mod.ProtocolDescriptor{null};
    try loadIntoContext(&ctx, &header, .{ .protocol_descriptors = &slots }, null);

    const pd = slots[0] orelse return error.TestExpectedDescriptor;
    const entry = ctx.module_cache_value.map.get(m_name) orelse return error.TestExpectedModule;
    const mw = entry.module.words.get(w_name) orelse return error.TestExpectedWord;
    const effect = mw.stack_effect orelse return error.TestExpectedEffect;
    try testing.expectEqual(@as(usize, 1), effect.inputs.len);
    const annotation = effect.inputs[0].type_annotation orelse return error.TestExpectedAnnotation;
    // Pointer identity into the slot table: the annotation is the same
    // descriptor the satisfies-memo and the dispatch helper see.
    try testing.expect(annotation == .protocol);
    try testing.expectEqual(pd, annotation.protocol);
}

test "loadIntoContext: protocol method effect referencing its own slot loads" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Effect index 1: ( a: orderly -- ) where slot 0 is the protocol
    // being reconstructed -- a self-reference read while the slot is
    // still unpatched.
    const cmp_inputs = [_]StackEffectParam{protocolParamRow("a", 0)};
    const effects = [_]StackEffect{
        .{ .inputs = null, .input_count = 0, .outputs = null, .output_count = 0 },
        .{ .inputs = &cmp_inputs, .input_count = 1, .outputs = null, .output_count = 0 },
    };

    const pd_name = "orderly";
    const method_rows = [_]ProtocolMethod{
        .{ .name = "cmp", .name_len = 3, .stack_effect_idx = 1 },
    };
    const descs = [_]ProtocolDescriptorDescription{.{
        .name = pd_name.ptr,
        .name_len = pd_name.len,
        .slot = 0,
        .protocol_id = 4,
        .method_count = 1,
        .methods = &method_rows,
    }};

    var header = emptyHeader();
    header.stack_effect_count = 2;
    header.stack_effects = &effects;
    header.protocoldescriptor_slot_count = 1;
    header.protocoldescriptor_descriptions = &descs;

    var slots = [_]?*const value_mod.ProtocolDescriptor{null};
    try loadIntoContext(&ctx, &header, .{ .protocol_descriptors = &slots }, null);

    const pd = slots[0] orelse return error.TestExpectedDescriptor;
    try testing.expectEqualStrings("orderly", pd.name);
    // The self-referencing method param stays unrestored.
    try testing.expectEqual(@as(usize, 2), pd.methods.len);
    try testing.expect(pd.methods[1] == .stack_effect);
    try testing.expect(pd.methods[1].stack_effect.inputs[0].type_annotation == null);
}

test "loadIntoContext: word effect param with out-of-range protocol slot errors" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const bounded_inputs = [_]StackEffectParam{protocolParamRow("x", 5)};
    const effects = [_]StackEffect{
        .{ .inputs = null, .input_count = 0, .outputs = null, .output_count = 0 },
        .{ .inputs = &bounded_inputs, .input_count = 1, .outputs = null, .output_count = 0 },
    };

    const pd_name = "orderly";
    const descs = [_]ProtocolDescriptorDescription{.{
        .name = pd_name.ptr,
        .name_len = pd_name.len,
        .slot = 0,
        .protocol_id = 5,
        .method_count = 0,
        .methods = null,
    }};

    const w_name = "bounded";
    const m_name = "demo";
    var w = wordRow(w_name, 1, 0);
    w.stack_effect_idx = 1;
    const words = [_]Word{w};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };

    var header = emptyHeader();
    header.module_count = 1;
    header.word_count = 1;
    header.modules = &modules;
    header.words = &words;
    header.stack_effect_count = 2;
    header.stack_effects = &effects;
    header.protocoldescriptor_slot_count = 1;
    header.protocoldescriptor_descriptions = &descs;

    var slots = [_]?*const value_mod.ProtocolDescriptor{null};
    try testing.expectError(
        LoaderError.BadSlotIndex,
        loadIntoContext(&ctx, &header, .{ .protocol_descriptors = &slots }, null),
    );
}

test "loadIntoContext: combinator slot reconstructs across all three element kinds" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // A TypeValue pre-filled into the typevalue slot table at slot 1. With
    // zero typevalue rows, `populateTypeValueSlots` leaves the table untouched,
    // so the combinator's `.type` element resolves to this pointer.
    const tv_desc = try value_mod.createBuiltinTypeDescriptor(arena, .{});
    const tv = try arena.create(value_mod.TypeValue);
    tv.* = .{ .name = "smallint", .descriptor = tv_desc };
    var typevalue_slots = [_]?*const value_mod.TypeValue{ null, tv };

    // Two protocols reconstructed into protocol slots 0 and 1.
    const pd_name = "cmp-able";
    const pd2_name = "show-able";
    const pd_descs = [_]ProtocolDescriptorDescription{
        .{ .name = pd_name.ptr, .name_len = pd_name.len, .slot = 0, .protocol_id = 1, .method_count = 0, .methods = null },
        .{ .name = pd2_name.ptr, .name_len = pd2_name.len, .slot = 1, .protocol_id = 2, .method_count = 0, .methods = null },
    };
    var protocol_slots = [_]?*const value_mod.ProtocolDescriptor{ null, null };

    // Inner intersection of one protocol (pd2 at slot 1); outer union of a
    // type leaf, a protocol leaf (pd at slot 0), and the inner combinator.
    const inner_elements = [_]CombinatorElement{
        .{ .kind = 2, .slot = 1 },
    };
    const outer_elements = [_]CombinatorElement{
        .{ .kind = 1, .slot = 1 },
        .{ .kind = 2, .slot = 0 },
        .{ .kind = 3, .slot = 0 },
    };
    const cc_descs = [_]ConstraintCombinatorDescription{
        .{ .slot = 0, .combinator_id = 5, .kind = 0, .element_count = 1, .elements = &inner_elements },
        .{ .slot = 1, .combinator_id = 6, .kind = 1, .element_count = 3, .elements = &outer_elements },
    };
    var combinator_slots = [_]?*const value_mod.ConstraintCombinator{ null, null };

    var header = emptyHeader();
    header.typevalue_slot_count = 2;
    header.protocoldescriptor_slot_count = 2;
    header.protocoldescriptor_descriptions = &pd_descs;
    header.constraintcombinator_slot_count = 2;
    header.constraintcombinator_descriptions = &cc_descs;

    try loadIntoContext(&ctx, &header, .{
        .typevalues = &typevalue_slots,
        .protocol_descriptors = &protocol_slots,
        .constraint_combinators = &combinator_slots,
    }, null);

    const inner = combinator_slots[0] orelse return error.TestExpectedCombinator;
    const outer = combinator_slots[1] orelse return error.TestExpectedCombinator;

    // Inner: an intersection of the single protocol leaf at protocol slot 1.
    try testing.expect(inner.kind == .intersection);
    try testing.expectEqual(@as(usize, 1), inner.elements.len);
    try testing.expect(inner.elements[0] == .protocol);
    try testing.expectEqual(protocol_slots[1].?, inner.elements[0].protocol);
    try testing.expectEqual(@as(u32, 5), inner.combinator_id);

    // Outer: a union whose three elements span all leaf kinds and whose nested
    // combinator points back at the reconstructed inner.
    try testing.expect(outer.kind == .@"union");
    try testing.expectEqual(@as(usize, 3), outer.elements.len);
    try testing.expect(outer.elements[0] == .type);
    try testing.expectEqual(@as(*const value_mod.TypeValue, tv), outer.elements[0].type);
    try testing.expect(outer.elements[1] == .protocol);
    try testing.expectEqual(protocol_slots[0].?, outer.elements[1].protocol);
    try testing.expect(outer.elements[2] == .combinator);
    try testing.expectEqual(inner, outer.elements[2].combinator);
    try testing.expectEqual(@as(u32, 6), outer.combinator_id);

    // Both descriptors registered on the context, cached on the slot table,
    // and next_combinator_id advanced past the serialized ids.
    try testing.expectEqual(@as(usize, 2), ctx.constraint_combinators.items.len);
    try testing.expectEqual(@as(u32, 2), ctx.image_constraintcombinator_slot_count);
    try testing.expect(ctx.next_combinator_id.load(.monotonic) >= 7);
}

test "loadIntoContext: combinator element with out-of-range type slot errors" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const elements = [_]CombinatorElement{
        .{ .kind = 1, .slot = 4 },
    };
    const cc_descs = [_]ConstraintCombinatorDescription{
        .{ .slot = 0, .combinator_id = 1, .kind = 0, .element_count = 1, .elements = &elements },
    };
    var combinator_slots = [_]?*const value_mod.ConstraintCombinator{null};
    var typevalue_slots = [_]?*const value_mod.TypeValue{null};

    var header = emptyHeader();
    header.typevalue_slot_count = 1;
    header.constraintcombinator_slot_count = 1;
    header.constraintcombinator_descriptions = &cc_descs;

    try testing.expectError(
        LoaderError.BadSlotIndex,
        loadIntoContext(&ctx, &header, .{
            .typevalues = &typevalue_slots,
            .constraint_combinators = &combinator_slots,
        }, null),
    );
}

test "findEnumVariantTypeValueByName: colliding variant names resolve to the first-registered enum" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const arena = ctx.quotationAllocator();

    const first_variant_tv = try arena.create(value_mod.TypeValue);
    first_variant_tv.* = .{ .name = "collide-shared", .descriptor = null };
    const first_vt = try arena.create(value_mod.VirtualType);
    first_vt.* = .{ .name = "collide-shared", .inner_type = "symbol", .type_val = first_variant_tv };
    const enum_a = try arena.create(value_mod.TypeValue);
    enum_a.* = .{ .name = "collide-a:", .descriptor = null };
    const variants_a: []const *const value_mod.VirtualType = &.{first_vt};
    try ctx.registerEnumVariants(enum_a, variants_a);

    const second_variant_tv = try arena.create(value_mod.TypeValue);
    second_variant_tv.* = .{ .name = "collide-shared", .descriptor = null };
    const second_vt = try arena.create(value_mod.VirtualType);
    second_vt.* = .{ .name = "collide-shared", .inner_type = "symbol", .type_val = second_variant_tv };
    const enum_b = try arena.create(value_mod.TypeValue);
    enum_b.* = .{ .name = "collide-b:", .descriptor = null };
    const variants_b: []const *const value_mod.VirtualType = &.{second_vt};
    try ctx.registerEnumVariants(enum_b, variants_b);

    const found = findEnumVariantTypeValueByName(&ctx, "collide-shared");
    try testing.expectEqual(@as(?*value_mod.TypeValue, first_variant_tv), found);
}
