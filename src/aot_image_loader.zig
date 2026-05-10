//! Runtime-image loader: rehydrates the AOT runtime image into a Context.
//!
//! Companion to `aot_image_emit.zig`. Walks the embedded `onez_image_v1`
//! header at startup, decodes the static-C-data tables and the narrow-C
//! blob path into runtime Module/ModuleWord/TypeValue instances, and
//! patches the shared TypeValue slot table so PIC dispatch and stack-
//! effect annotations resolve to live pointers.
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
const Context = @import("context.zig").Context;

/// Errors the loader can surface. The C-side caller maps these to
/// `ONEZ_ERR_LOAD_FAILED` and uses `ctx.error_details` for the
/// human-readable message.
pub const LoaderError = error{
    UnsupportedFormat,
    BadSlotIndex,
    BadWordIndex,
    BadStackEffectIndex,
    BadValueKind,
    OutOfMemory,
};

/// `BlobValueKind` constants. Must match the mapping documented in
/// `aot_image_emit.emitTypeDeclarations`.
const blob_value_kind_symbol: u8 = 0;
const blob_value_kind_boolean: u8 = 1;
const blob_value_kind_fixnum: u8 = 2;
const blob_value_kind_string: u8 = 3;
const blob_value_kind_unit: u8 = 4;
const blob_value_kind_unsupported: u8 = 5;

/// `classification` field values from `onez_image_word`.
const classification_structural: u8 = 0;
const classification_blob: u8 = 1;

/// Sentinel for `blob_entry_idx` meaning "no blob entry for this word".
const no_blob_entry: u32 = 0xFFFFFFFF;

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
    blob_entry_idx: u32,
    typevalue_slot: u32,
};

pub const BlobDescriptorEntry = extern struct {
    key: [*]const u8,
    key_len: u32,
    value_kind: u8,
    bool_value: u8,
    _pad: u16,
    fixnum_value: i64,
    string_value: ?[*]const u8,
    string_value_len: u32,
};

pub const BlobTypeValue = extern struct {
    name: [*]const u8,
    name_len: u32,
    typevalue_slot: u32,
    descriptor_entries: ?[*]const BlobDescriptorEntry,
    descriptor_entry_count: u32,
    member_type_slots: ?[*]const u32,
    member_type_count: u32,
};

pub const BlobEntry = extern struct {
    word_idx: u32,
    blob_kind: u8,
    _pad: [3]u8,
    typevalue: ?*const BlobTypeValue,
};

pub const Header = extern struct {
    format_version: u32,
    module_count: u32,
    word_count: u32,
    marker_pool_count: u32,
    typevalue_slot_count: u32,
    stack_effect_count: u32,
    blob_entry_count: u32,
    _pad: u32,
    modules: ?[*]const Module,
    words: ?[*]const Word,
    markers: ?[*]const Marker,
    stack_effects: ?[*]const StackEffect,
    blob_entries: ?[*]const BlobEntry,
};

/// Slot table type matching the C declaration:
///   const struct onez_typevalue *onez_image_typevalue_slots[N]
/// `const` qualifies the pointee (an opaque TypeValue), not the array
/// elements -- the elements are writable, which is what lets the loader
/// patch them at startup.
pub const SlotTable = [*]?*const value_mod.TypeValue;

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
pub fn loadIntoContext(
    ctx: *Context,
    header: *const Header,
    slots: ?SlotTable,
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

    try populateModulesAndWords(ctx, header);
    try rehydrateBlobTypeValues(ctx, header, slots);
    if (pic_relocs) |relocs| {
        try resolvePicRelocations(header, slots, relocs);
    }
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
                .word_id = word_id_opt,
                .action = .{ .compound = body },
            };
            module_ptr.words.put(arena, word_name, mw) catch return LoaderError.OutOfMemory;
        }

        ctx.module_cache_value.put(arena, name, .{ .module = module_ptr }) catch
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

// -- Blob TypeValue rehydration ----------------------------------------

fn rehydrateBlobTypeValues(
    ctx: *Context,
    header: *const Header,
    slots: ?SlotTable,
) LoaderError!void {
    if (header.blob_entry_count == 0) return;
    const entries = header.blob_entries orelse return;
    const arena = ctx.quotationAllocator();

    var i: u32 = 0;
    while (i < header.blob_entry_count) : (i += 1) {
        const entry = entries[i];
        const tv_ptr = entry.typevalue orelse continue;
        const tv = tv_ptr.*;

        if (tv.typevalue_slot == 0 or tv.typevalue_slot >= header.typevalue_slot_count) {
            return LoaderError.BadSlotIndex;
        }

        const descriptor = arena.create(value_mod.TypeDescriptor) catch
            return LoaderError.OutOfMemory;
        descriptor.* = .{ .kind = .{ .builtin = {} } };
        try populateDescriptor(ctx, descriptor, tv);

        const runtime_tv = arena.create(value_mod.TypeValue) catch
            return LoaderError.OutOfMemory;
        runtime_tv.* = .{
            .name = nameSlice(tv.name, tv.name_len),
            .descriptor = descriptor,
        };

        if (slots) |slot_table| {
            slot_table[tv.typevalue_slot] = runtime_tv;
        }

        // Replace the M1 stub for this word with a single
        // [push_literal {.type_val = runtime_tv}] instruction so
        // `lookupWordCompoundInstrs` returns the right body for the
        // existing `jitPushWordLiteral` fast path.
        try replaceWordBodyWithTypeValuePush(ctx, header, entry.word_idx, runtime_tv);
    }
}

fn populateDescriptor(
    ctx: *Context,
    desc: *value_mod.TypeDescriptor,
    tv: BlobTypeValue,
) LoaderError!void {
    if (tv.descriptor_entry_count == 0 or tv.descriptor_entries == null) return;
    const entries = tv.descriptor_entries.?;

    // First pass: discover the `type` discriminator so the kind-data
    // variant can be initialized with sensible defaults before the
    // second pass populates kind-specific fields.
    var i: u32 = 0;
    while (i < tv.descriptor_entry_count) : (i += 1) {
        const e = entries[i];
        if (e.value_kind != blob_value_kind_symbol) continue;
        if (!std.mem.eql(u8, nameSlice(e.key, e.key_len), "type")) continue;
        const sym = if (e.string_value) |p| p[0..e.string_value_len] else "";
        const kind = typeKindFromSymbol(sym) orelse {
            recordLoaderNote(
                ctx,
                "runtime-image: unrecognized type discriminator '{s}' on type '{s}'",
                .{ sym, nameSlice(tv.name, tv.name_len) },
            );
            continue;
        };
        desc.kind = emptyKindData(kind);
        break;
    }

    // Second pass: universal flags and kind-specific scalar fields.
    // Entries with `BlobValueKind.unsupported` (or unrecognized keys
    // for the kind) record a note rather than abort the load,
    // preserving the existing behavior the bug-closure test observes.
    i = 0;
    while (i < tv.descriptor_entry_count) : (i += 1) {
        const e = entries[i];
        const key = nameSlice(e.key, e.key_len);
        if (std.mem.eql(u8, key, "type")) continue;

        if (std.mem.eql(u8, key, "numeric")) {
            if (e.value_kind == blob_value_kind_boolean) desc.numeric = e.bool_value != 0;
            continue;
        }
        if (std.mem.eql(u8, key, "exact")) {
            if (e.value_kind == blob_value_kind_boolean) desc.exact = e.bool_value != 0;
            continue;
        }
        if (std.mem.eql(u8, key, "integer")) {
            if (e.value_kind == blob_value_kind_boolean) desc.integer = e.bool_value != 0;
            continue;
        }
        if (std.mem.eql(u8, key, "mutable")) {
            if (e.value_kind == blob_value_kind_boolean) desc.mutable = e.bool_value != 0;
            continue;
        }

        switch (desc.kind) {
            .resource => |*rd| {
                if (std.mem.eql(u8, key, "resource-kind") and e.value_kind == blob_value_kind_string) {
                    rd.resource_kind = if (e.string_value) |p| p[0..e.string_value_len] else "";
                    continue;
                }
            },
            .ffi_struct => |*fsd| {
                if (std.mem.eql(u8, key, "ffi-layout") and e.value_kind == blob_value_kind_fixnum) {
                    fsd.ffi_layout = @intCast(e.fixnum_value);
                    continue;
                }
            },
            else => {},
        }

        if (e.value_kind == blob_value_kind_unsupported) {
            recordLoaderNote(
                ctx,
                "runtime-image: skipping unsupported descriptor entry '{s}' on type '{s}'",
                .{ key, nameSlice(tv.name, tv.name_len) },
            );
        } else if (e.value_kind > blob_value_kind_unsupported) {
            return LoaderError.BadValueKind;
        }
    }
}

fn typeKindFromSymbol(sym: []const u8) ?value_mod.TypeKind {
    if (std.mem.eql(u8, sym, "builtin-type")) return .builtin;
    if (std.mem.eql(u8, sym, "sentinel")) return .sentinel;
    if (std.mem.eql(u8, sym, "struct-descriptor")) return .struct_;
    if (std.mem.eql(u8, sym, "virtual")) return .virtual;
    if (std.mem.eql(u8, sym, "enum-descriptor")) return .enum_;
    if (std.mem.eql(u8, sym, "enum-variant")) return .enum_variant;
    if (std.mem.eql(u8, sym, "resource-type")) return .resource;
    if (std.mem.eql(u8, sym, "ffi-struct-type")) return .ffi_struct;
    if (std.mem.eql(u8, sym, "union-type")) return .union_;
    return null;
}

fn emptyKindData(kind: value_mod.TypeKind) value_mod.TypeKindData {
    return switch (kind) {
        .builtin => .{ .builtin = {} },
        .sentinel => .{ .sentinel = {} },
        .struct_ => .{ .struct_ = .{} },
        .virtual => .{ .virtual = .{} },
        .enum_ => .{ .enum_ = .{} },
        .enum_variant => .{ .enum_variant = .{} },
        .resource => .{ .resource = .{} },
        .ffi_struct => .{ .ffi_struct = .{} },
        .union_ => .{ .union_ = {} },
    };
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

    const cache_entry = ctx.module_cache_value.getPtr(module_name) orelse return;
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

test "loadIntoContext: rejects unsupported format version" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const header: Header = .{
        .format_version = aot_image_emit.format_version + 1,
        .module_count = 0,
        .word_count = 0,
        .marker_pool_count = 0,
        .typevalue_slot_count = 1,
        .stack_effect_count = 1,
        .blob_entry_count = 0,
        ._pad = 0,
        .modules = null,
        .words = null,
        .markers = null,
        .stack_effects = null,
        .blob_entries = null,
    };

    try testing.expectError(
        LoaderError.UnsupportedFormat,
        loadIntoContext(&ctx, &header, null, null),
    );
}

test "loadIntoContext: empty header populates nothing" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 0,
        .word_count = 0,
        .marker_pool_count = 0,
        .typevalue_slot_count = 1,
        .stack_effect_count = 1,
        .blob_entry_count = 0,
        ._pad = 0,
        .modules = null,
        .words = null,
        .markers = null,
        .stack_effects = null,
        .blob_entries = null,
    };

    try loadIntoContext(&ctx, &header, null, null);

    // Only the prelude module (if any test setup populated one) plus
    // anything Context.init creates. Our empty image must add nothing.
    var iter = ctx.module_cache_value.iterator();
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
    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 1,
        .word_count = 2,
        .marker_pool_count = 0,
        .typevalue_slot_count = 1,
        .stack_effect_count = 1,
        .blob_entry_count = 0,
        ._pad = 0,
        .modules = &modules,
        .words = &words,
        .markers = null,
        .stack_effects = null,
        .blob_entries = null,
    };

    try loadIntoContext(&ctx, &header, null, null);

    const entry = ctx.module_cache_value.get(m_name) orelse {
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
        .blob_entry_idx = no_blob_entry,
        .typevalue_slot = 0,
    };
}

test "loadIntoContext: resource TypeValue rehydrates kind + universal bools + resource_kind" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const tv_name = "demo-resource";
    const w_name = "DemoResource";
    const m_name = "demo";

    // Realistic descriptor schema: `type` discriminator (symbol),
    // four universal boolean flags, the kind-specific `resource-kind`
    // string, plus one unsupported entry to verify the note path.
    const entries = [_]BlobDescriptorEntry{
        .{
            .key = "type".ptr,
            .key_len = 4,
            .value_kind = blob_value_kind_symbol,
            .bool_value = 0,
            ._pad = 0,
            .fixnum_value = 0,
            .string_value = "resource-type".ptr,
            .string_value_len = 13,
        },
        .{
            .key = "numeric".ptr,
            .key_len = 7,
            .value_kind = blob_value_kind_boolean,
            .bool_value = 1,
            ._pad = 0,
            .fixnum_value = 0,
            .string_value = null,
            .string_value_len = 0,
        },
        .{
            .key = "exact".ptr,
            .key_len = 5,
            .value_kind = blob_value_kind_boolean,
            .bool_value = 1,
            ._pad = 0,
            .fixnum_value = 0,
            .string_value = null,
            .string_value_len = 0,
        },
        .{
            .key = "integer".ptr,
            .key_len = 7,
            .value_kind = blob_value_kind_boolean,
            .bool_value = 0,
            ._pad = 0,
            .fixnum_value = 0,
            .string_value = null,
            .string_value_len = 0,
        },
        .{
            .key = "mutable".ptr,
            .key_len = 7,
            .value_kind = blob_value_kind_boolean,
            .bool_value = 1,
            ._pad = 0,
            .fixnum_value = 0,
            .string_value = null,
            .string_value_len = 0,
        },
        .{
            .key = "resource-kind".ptr,
            .key_len = 13,
            .value_kind = blob_value_kind_string,
            .bool_value = 0,
            ._pad = 0,
            .fixnum_value = 0,
            .string_value = "demo-handle".ptr,
            .string_value_len = 11,
        },
        .{
            .key = "fields".ptr,
            .key_len = 6,
            .value_kind = blob_value_kind_unsupported,
            .bool_value = 0,
            ._pad = 0,
            .fixnum_value = 0,
            .string_value = null,
            .string_value_len = 0,
        },
    };

    const blob_tv: BlobTypeValue = .{
        .name = tv_name.ptr,
        .name_len = tv_name.len,
        .typevalue_slot = 1,
        .descriptor_entries = &entries,
        .descriptor_entry_count = entries.len,
        .member_type_slots = null,
        .member_type_count = 0,
    };
    const blob_entries = [_]BlobEntry{
        .{ .word_idx = 0, .blob_kind = 1, ._pad = .{ 0, 0, 0 }, .typevalue = &blob_tv },
    };
    const words = [_]Word{
        blk: {
            var w = wordRow(w_name, 200, 0);
            w.classification = classification_blob;
            w.blob_entry_idx = 0;
            w.typevalue_slot = 1;
            break :blk w;
        },
    };
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };

    var slot_storage: [2]?*const value_mod.TypeValue = .{ null, null };
    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 1,
        .word_count = 1,
        .marker_pool_count = 0,
        .typevalue_slot_count = 2,
        .stack_effect_count = 1,
        .blob_entry_count = blob_entries.len,
        ._pad = 0,
        .modules = &modules,
        .words = &words,
        .markers = null,
        .stack_effects = null,
        .blob_entries = &blob_entries,
    };

    try loadIntoContext(&ctx, &header, &slot_storage, null);

    // Slot 1 must be patched to a freshly allocated TypeValue.
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

    // The corresponding word's compound body must now push the
    // freshly-allocated TypeValue.
    const cache_entry = ctx.module_cache_value.get(m_name) orelse return error.TestUnexpectedResult;
    const module_ptr = cache_entry.module;
    const w = module_ptr.words.get(w_name) orelse return error.TestUnexpectedResult;
    try testing.expect(w.action == .compound);
    try testing.expectEqual(@as(usize, 1), w.action.compound.len);
    try testing.expect(w.action.compound[0].op == .push_literal);
    try testing.expectEqual(tv, w.action.compound[0].op.push_literal.type_val);

    // The skipped entry recorded a note in error_details.
    var saw_note = false;
    for (ctx.error_details.items) |d| {
        if (std.mem.eql(u8, d.error_type, "runtime-image-load-note")) {
            saw_note = true;
            break;
        }
    }
    try testing.expect(saw_note);
}

test "loadIntoContext: PIC relocation rewrites snapshot slot to runtime TypeValue" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // One blob TypeValue at slot 1; the loader allocates it and
    // patches the slot table.
    const blob_tv: BlobTypeValue = .{
        .name = "color".ptr,
        .name_len = 5,
        .typevalue_slot = 1,
        .descriptor_entries = null,
        .descriptor_entry_count = 0,
        .member_type_slots = null,
        .member_type_count = 0,
    };
    const blob_entries = [_]BlobEntry{
        .{ .word_idx = 0, .blob_kind = 1, ._pad = .{ 0, 0, 0 }, .typevalue = &blob_tv },
    };
    const w_name = "color";
    const m_name = "demo";
    const words = [_]Word{wordRow(w_name, 7, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };
    var slot_storage: [2]?*const value_mod.TypeValue = .{ null, null };

    // Synthetic PIC snapshot slot pre-populated with NULL. The
    // loader writes the runtime TypeValue address here after the
    // blob path fills slot 1.
    var snapshot_slot: ?*const value_mod.TypeValue = null;
    const relocs = [_]PicRelocation{
        .{ .target = &snapshot_slot, .slot_index = 1 },
    };
    const reloc_table: PicRelocationTable = .{ .items = &relocs };

    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 1,
        .word_count = 1,
        .marker_pool_count = 0,
        .typevalue_slot_count = 2,
        .stack_effect_count = 1,
        .blob_entry_count = blob_entries.len,
        ._pad = 0,
        .modules = &modules,
        .words = &words,
        .markers = null,
        .stack_effects = null,
        .blob_entries = &blob_entries,
    };

    try loadIntoContext(&ctx, &header, &slot_storage, reloc_table);

    // Both the slot table and the snapshot must point at the same
    // runtime TypeValue.
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

    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 0,
        .word_count = 0,
        .marker_pool_count = 0,
        .typevalue_slot_count = 2,
        .stack_effect_count = 1,
        .blob_entry_count = 0,
        ._pad = 0,
        .modules = null,
        .words = null,
        .markers = null,
        .stack_effects = null,
        .blob_entries = null,
    };

    try testing.expectError(
        LoaderError.BadSlotIndex,
        loadIntoContext(&ctx, &header, &slot_storage, reloc_table),
    );
}

test "loadIntoContext: rejects out-of-range typevalue slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const blob_tv: BlobTypeValue = .{
        .name = "x".ptr,
        .name_len = 1,
        .typevalue_slot = 99, // out of range vs typevalue_slot_count below
        .descriptor_entries = null,
        .descriptor_entry_count = 0,
        .member_type_slots = null,
        .member_type_count = 0,
    };
    const blob_entries = [_]BlobEntry{
        .{ .word_idx = 0, .blob_kind = 1, ._pad = .{ 0, 0, 0 }, .typevalue = &blob_tv },
    };
    const w_name = "X";
    const m_name = "demo";
    const words = [_]Word{wordRow(w_name, 1, 0)};
    const modules = [_]Module{
        .{ .name = m_name.ptr, .name_len = m_name.len, .word_start_idx = 0, .word_count = 1 },
    };

    var slot_storage: [2]?*const value_mod.TypeValue = .{ null, null };
    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 1,
        .word_count = 1,
        .marker_pool_count = 0,
        .typevalue_slot_count = 2,
        .stack_effect_count = 1,
        .blob_entry_count = blob_entries.len,
        ._pad = 0,
        .modules = &modules,
        .words = &words,
        .markers = null,
        .stack_effects = null,
        .blob_entries = &blob_entries,
    };

    try testing.expectError(
        LoaderError.BadSlotIndex,
        loadIntoContext(&ctx, &header, &slot_storage, null),
    );
}

test "loadIntoContext: bytecode body decodes into compound action" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Hand-built bytecode for `[ push_literal fixnum 7, call_word "+" ]`.
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
    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 1,
        .word_count = 1,
        .marker_pool_count = 0,
        .typevalue_slot_count = 1,
        .stack_effect_count = 1,
        .blob_entry_count = 0,
        ._pad = 0,
        .modules = &modules,
        .words = &words,
        .markers = null,
        .stack_effects = null,
        .blob_entries = null,
    };

    try loadIntoContext(&ctx, &header, null, null);

    const entry = ctx.module_cache_value.get(m_name) orelse return error.TestExpectedModule;
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
    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 1,
        .word_count = 1,
        .marker_pool_count = 0,
        .typevalue_slot_count = 1,
        .stack_effect_count = 1,
        .blob_entry_count = 0,
        ._pad = 0,
        .modules = &modules,
        .words = &words,
        .markers = null,
        .stack_effects = null,
        .blob_entries = null,
    };

    try loadIntoContext(&ctx, &header, null, null);

    const entry = ctx.module_cache_value.get(m_name) orelse return error.TestExpectedModule;
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
    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 1,
        .word_count = 1,
        .marker_pool_count = 0,
        .typevalue_slot_count = 1,
        .stack_effect_count = 1,
        .blob_entry_count = 0,
        ._pad = 0,
        .modules = &modules,
        .words = &words,
        .markers = null,
        .stack_effects = null,
        .blob_entries = null,
    };

    try loadIntoContext(&ctx, &header, null, null);

    const entry = ctx.module_cache_value.get(m_name) orelse return error.TestExpectedModule;
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

    // A single byte is shorter than the 4-byte instruction count
    // header the decoder reads first; deserialization rejects it.
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
    const header: Header = .{
        .format_version = aot_image_emit.format_version,
        .module_count = 1,
        .word_count = 1,
        .marker_pool_count = 0,
        .typevalue_slot_count = 1,
        .stack_effect_count = 1,
        .blob_entry_count = 0,
        ._pad = 0,
        .modules = &modules,
        .words = &words,
        .markers = null,
        .stack_effects = null,
        .blob_entries = null,
    };

    try testing.expectError(
        LoaderError.OutOfMemory,
        loadIntoContext(&ctx, &header, null, null),
    );
}
