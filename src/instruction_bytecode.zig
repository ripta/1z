//! Bytecode encoder/decoder for `Instruction` slices.
//!
//! Compact, position-independent serialization of compound word bodies and
//! quotation literals. Used by:
//!
//! - The AOT IR codegen, when the `jitPushQuotation` callback materializes
//!   a quotation literal pushed by compiled code.
//! - The AOT runtime image, where compound word bodies travel from
//!   freeze-time codegen into the runtime Context's dictionary at startup.
//!
//! ## Wire format
//!
//! Per quotation:
//!
//! ```
//! u8 has_effect | [effect]
//! u32 instruction_count
//! instruction[]
//! ```
//!
//! The leading effect slot carries the quotation's declared stack effect (the
//! `( ... )` the parser attached to the literal), so `Quotation.effect`
//! round-trips the wire. A word body serializes with no effect: its declared
//! effect travels in the image header's stack-effect table, not here.
//!
//! Per effect:
//!
//! ```
//! param_array(inputs) | param_array(outputs)
//! param_array := u32 count | param[]
//! param       := u8 is_row_variable | u32 name_len | name_bytes
//!              | u8 has_quotation_effect | [effect]
//! ```
//!
//! Per instruction:
//!
//! ```
//! u32 line | u32 column | u8 op_tag | payload
//! ```
//!
//! Op tags: `0 = push_literal`, `1 = call_word`, `2 = call_word_module`.
//!
//! `call_word` payload: `u32 name_len | name_bytes`.
//!
//! `call_word_module` payload: `u32 call_target_slot_index`. Image-mode only.
//! The index resolves through `SlotResolutionTables.call_target_slots` to a
//! loader-owned `WordSlot`, which carries the name, so none is stored. Emitted
//! only when the serializer is given a `CallTargetResolver`, i.e. for a module
//! word body whose owning module scope resolved the name to an image word row.
//!
//! `push_literal` payload: `u8 value_tag | value_payload`.
//!
//! Value tags:
//!
//! - `0 = fixnum`: `i64`
//! - `1 = float`: `f64`
//! - `2 = boolean`: `u8`
//! - `3 = string`: `u32 len | bytes`
//! - `4 = symbol`: `u32 len | bytes`
//! - `5 = quotation`: `u32 quotation_id | <quotation stream>`. The embedded
//!   stream begins with the effect slot, so a nested literal's declared effect
//!   rides the same encoding as a top-level one. `quotation_id` is the
//!   build-time global ID under which the AOT compiler emitted this
//!   quotation's compiled body; the runtime deserialize attaches
//!   `onez_quotation_table[id]` as the reconstructed quotation's `code_ptr`. A
//!   sentinel ID (`0xFFFFFFFF`) marks "no compiled function" -- written by every
//!   path that has no quotation-ID map, and decoded as a null `code_ptr`.
//! - `6 = array`: `u32 elem_count | values[]`
//! - `7 = hash`: `u32 entry_count | entries[]` where each entry is
//!   `u32 key_len | key_bytes | value`
//! - `8 = stack_effect`: `param_array(inputs) | param_array(outputs)`, the
//!   same param codec the effect slot uses, so a param's nested
//!   `quotation_effect` recurses here too
//! - `9 = unit`: empty payload
//! - `15 = mutable_map`: same wire shape as hash, but the loader
//!   allocates a fresh `MutableMap` so mutations persist across pushes.
//!   Image-mode encoding prefers `16 = mutable_map_slot` so freeze-time
//!   identity is preserved; the non-image form is used by JIT
//!   round-tripping where no slot map is available.
//! - `17 = struct_instance_slot`: image-mode only. `u32 slot_index`
//!   resolved through `SlotResolutionTables.struct_instance_slots`, so a
//!   freeze-time struct instance is reconstructed once and shared by every
//!   reference.
//!
//! All multi-byte integers are little-endian.
//!
//! ## Lowering of non-simple literals
//!
//! `push_literal` of `type_val`, `tagged`, `parameter`, or `marker` is
//! rewritten as `call_word` carrying the value's `name`. The runtime
//! resolves the name through the rehydrated dictionary. This keeps the
//! encoder bounded to the ten "simple" Value variants without losing
//! reachability for type values, enum variants, parameter definitions,
//! and markers.
//!
//! ## stack_effect fidelity
//!
//! The param codec preserves `name`, `is_row_variable`, and a recursive
//! `quotation_effect`. It does not encode `type_annotation`: the annotation is
//! a pointer to a `TypeValue`, `ProtocolDescriptor`, or `ConstraintCombinator`
//! identity, and name-based re-resolution at decode would bind in decode-time
//! scope rather than parse-time scope. Encoding it needs an identity-correct
//! type-reference design of its own, and slots in without renumbering.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const word_slot_mod = @import("word_slot.zig");
const WordSlot = word_slot_mod.WordSlot;
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const HashTable = value_mod.HashTable;
const TypeValue = value_mod.TypeValue;
const VirtualType = value_mod.VirtualType;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;
const Marker = value_mod.Marker;
const Parameter = value_mod.Parameter;
const MutableMap = value_mod.MutableMap;
const Vector = value_mod.Vector;

const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;

const container_backing = @import("container_backing.zig");

/// Errors that can arise from the encoder.
pub const SerializeError = Allocator.Error || error{NotEncodable};

/// Image-mode slot maps. When `serializeValueIntoForImage` receives a
/// non-null `*const SlotEncodingMaps`, type-carrier Value variants
/// (`.type_val`, `.struct_type`, `.tagged`, `.parameter`, `.marker`) are
/// emitted as slot-reference value tags rather than failing with
/// `error.NotEncodable`. The slot indices are written into the bytecode
/// and resolved by `deserializeValueAtForImage` through the matching
/// `SlotResolutionTables`. Pointer-identity is preserved across the
/// freeze→runtime boundary.
pub const SlotEncodingMaps = struct {
    typevalue_slot_index: *const std.AutoHashMapUnmanaged(*const TypeValue, u32),
    struct_type_slot_index: *const std.AutoHashMapUnmanaged(*const StructType, u32),
    marker_slot_index: *const std.AutoHashMapUnmanaged(*const Marker, u32),
    parameter_slot_index: *const std.AutoHashMapUnmanaged(*const Parameter, u32),
    tagged_slot_index: *const std.AutoHashMapUnmanaged(TaggedKey, u32),
    mutable_map_slot_index: *const std.AutoHashMapUnmanaged(*const MutableMap, u32),
    struct_instance_slot_index: *const std.AutoHashMapUnmanaged(*const StructInstance, u32),
    vector_slot_index: *const std.AutoHashMapUnmanaged(*const Vector, u32),
    /// Build-time map from a quotation body's instruction pointer to its global
    /// `quotation_id`. When supplied, `serializeValueIntoForImage` stamps each
    /// nested `.quotation` with its ID so the loader can attach a compiled
    /// `code_ptr` (the lint registry's `check` quotations rely on this); when
    /// null, every quotation serializes with the sentinel.
    quotation_id_map: ?*const QuotationIdMap = null,
};

/// Build-time resolution of a call site against the executing body's own module scope.
///
/// Supplied only where the owning module is known, which today is the AOT image emitter
/// serializing a module word body. `resolve` returns the call-target slot index for a name that
/// module's scope resolves to an image word row, or null to keep the bare-name lowering. It
/// allocates when it interns a new target, so it can fail.
///
/// The indirection through `state` keeps the emitter's manifest and `Context` out of this module.
pub const CallTargetResolver = struct {
    state: *anyopaque,
    resolve: *const fn (state: *anyopaque, name: []const u8) Allocator.Error!?u32,
};

/// Key for the tagged slot map, mirrored from `aot_image_emit.TaggedSlotKey`
/// to avoid a cyclic module dependency. Identity is `(tag, inner_ptr)`.
pub const TaggedKey = struct {
    tag: *const VirtualType,
    inner_ptr: *const Value,
};

/// Image-mode slot resolution tables, mirrored from the Context fields the
/// loader caches at startup. `deserializeValueAtForImage` uses these to
/// resolve slot indices back to live runtime pointers when decoding
/// type-carrier inner values inside tagged-slot description bytecode.
pub const SlotResolutionTables = struct {
    typevalue_slots: ?[*]?*const TypeValue,
    typevalue_slot_count: u32,
    struct_type_slots: ?[*]?*StructType,
    struct_type_slot_count: u32,
    marker_slots: ?[*]?*Marker,
    marker_slot_count: u32,
    parameter_slots: ?[*]?*Parameter,
    parameter_slot_count: u32,
    tagged_slots: ?[*]?*const Value,
    tagged_slot_count: u32,
    mutable_map_slots: ?[*]?*MutableMap,
    mutable_map_slot_count: u32,
    struct_instance_slots: ?[*]?*StructInstance,
    struct_instance_slot_count: u32,
    vector_slots: ?[*]?*Vector,
    vector_slot_count: u32,
    /// Loader-owned `WordSlot`s for build-time-resolved call targets, indexed by the slot index a
    /// `call_word_module` instruction carries. Null leaves the tag undecodable, which is a
    /// malformed stream rather than a degradation: an emitter that wrote the tag must supply the
    /// table.
    call_target_slots: ?[*]?*WordSlot = null,
    call_target_slot_count: u32 = 0,
    /// Runtime quotation-function table (`ctx.aot_quotation_fns.table[0..size]`).
    /// When supplied, `deserializeValueAtForImage` attaches `table[id]` as the
    /// `code_ptr` of each decoded nested `.quotation`, so a runtime-selected
    /// dispatch of an image-decoded quotation runs compiled. Null leaves
    /// `code_ptr` null, matching the pre-attachment behavior.
    quotation_fns: ?[]const ?*const anyopaque = null,

    /// When supplied, every instruction slice materialized for a nested
    /// `.quotation` value whose operands carry a container literal is
    /// appended here. The loader registers these on the context's container
    /// release list, mirroring the parser-side registration of quotation
    /// literals, so the owning references the slot arms take are released
    /// at teardown.
    decoded_streams: ?*std.ArrayListUnmanaged([]const Instruction) = null,
    decoded_streams_allocator: ?Allocator = null,
};

/// Op tags. Stored in the bytecode stream.
const op_tag_push_literal: u8 = 0;
const op_tag_call_word: u8 = 1;
const op_tag_call_word_module: u8 = 2;

/// Value tags. Stored in the bytecode stream after `op_tag_push_literal`.
const value_tag_fixnum: u8 = 0;
const value_tag_float: u8 = 1;
const value_tag_boolean: u8 = 2;
const value_tag_string: u8 = 3;
const value_tag_symbol: u8 = 4;
const value_tag_quotation: u8 = 5;
const value_tag_array: u8 = 6;
const value_tag_hash: u8 = 7;
const value_tag_stack_effect: u8 = 8;
const value_tag_unit: u8 = 9;

/// Image-mode-only value tags. Emitted by `serializeValueIntoForImage`
/// when slot maps are provided; decoded by `deserializeValueAtForImage`
/// against the loader's slot tables. Each carries a `u32 slot_index`.
const value_tag_type_val_slot: u8 = 10;
const value_tag_struct_type_slot: u8 = 11;
const value_tag_marker_slot: u8 = 12;
const value_tag_parameter_slot: u8 = 13;
const value_tag_tagged_slot: u8 = 14;

/// Bare `mutable_map` literal in non-image bytecode. Image-mode
/// encoding prefers `value_tag_mutable_map_slot` so freeze-time
/// identity is preserved; the bare form is used by JIT round-tripping
/// where no slot map is available, in which case each decode allocates
/// a fresh `MutableMap`.
const value_tag_mutable_map: u8 = 15;

/// Slot-indexed `mutable_map` literal used in image-mode bytecode.
/// Carries a `u32 slot_index` resolved through
/// `SlotResolutionTables.mutable_map_slots`. Preserves the identity of
/// a parse-time-materialized mutable map across an AOT freeze boundary.
const value_tag_mutable_map_slot: u8 = 16;

/// Slot-indexed `struct_instance` literal used in image-mode bytecode.
/// Carries a `u32 slot_index` resolved through
/// `SlotResolutionTables.struct_instance_slots`. Preserves the identity of
/// a freeze-time struct instance (instance fields are mutable, so an alias
/// shared at freeze time must stay shared at runtime) across an AOT freeze
/// boundary.
const value_tag_struct_instance_slot: u8 = 17;

/// Slot-indexed `vector` literal used in image-mode bytecode. Carries a
/// `u32 slot_index` resolved through `SlotResolutionTables.vector_slots`.
/// Preserves the identity of a freeze-time mutable vector (vectors are
/// mutable, so an alias shared at freeze time must stay shared at runtime)
/// across an AOT freeze boundary. The loader allocates one `Vector` per slot
/// and decodes its elements from the slot's description.
const value_tag_vector_slot: u8 = 18;

/// Sentinel `quotation_id` meaning "no compiled function". Written for every
/// serialized quotation when no build-time quotation-ID map is supplied (or the
/// body is absent from it), and decoded as a null `code_ptr`. Matches the
/// sentinel `ir_codegen.materializeQuotations` uses for the same purpose.
pub const quotation_id_sentinel: u32 = std.math.maxInt(u32);

/// Build-time map from a quotation body's instruction pointer
/// (`@intFromPtr(q.instructions.ptr)`) to its global `quotation_id`. Supplied to
/// the serializer by the AOT composite-literal path so nested quotations carry
/// the ID their compiled body was emitted under.
pub const QuotationIdMap = std.AutoHashMapUnmanaged(usize, u32);

/// Serialize an instruction slice into a freshly allocated byte buffer.
/// Caller owns the returned slice. `effect` is the quotation's declared stack
/// effect, written into the stream's effect slot; pass `null` for a word body
/// or an undeclared literal. `qid_map` stamps each nested quotation with
/// its global ID; pass `null` to write the sentinel for every quotation.
/// `call_targets` bakes call sites the body's own module scope resolves; pass
/// `null` to keep every call a bare name.
pub fn serializeQuotationInstructions(
    instructions: []const Instruction,
    effect: ?*const StackEffect,
    allocator: Allocator,
    qid_map: ?*const QuotationIdMap,
    call_targets: ?CallTargetResolver,
) SerializeError![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    try serializeInstructionsInto(&buf, instructions, effect, allocator, qid_map, call_targets);
    return buf.toOwnedSlice(allocator);
}

/// Append a serialized instruction slice to an existing buffer. `qid_map`
/// stamps each nested quotation with its global ID; pass `null` for the sentinel.
/// See `serializeQuotationInstructions` for `effect` and `call_targets`.
pub fn serializeInstructionsInto(
    buf: *std.ArrayListUnmanaged(u8),
    instructions: []const Instruction,
    effect: ?*const StackEffect,
    allocator: Allocator,
    qid_map: ?*const QuotationIdMap,
    call_targets: ?CallTargetResolver,
) SerializeError!void {
    try buf.append(allocator, @intFromBool(effect != null));
    if (effect) |e| try writeEffect(buf, allocator, e);
    const count: u32 = @intCast(instructions.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&count));
    for (instructions) |instr| {
        const line: u32 = @intCast(instr.line);
        const col: u32 = @intCast(instr.column);
        try buf.appendSlice(allocator, std.mem.asBytes(&line));
        try buf.appendSlice(allocator, std.mem.asBytes(&col));
        switch (instr.op) {
            .push_literal => |val| {
                // A lowered literal is a value-recovery call, not a call to the word the resolver
                // would bake, so it keeps the bare name whatever the resolver says.
                if (lowerableName(val)) |name| {
                    try writeCallWord(buf, allocator, name);
                } else {
                    try buf.append(allocator, op_tag_push_literal);
                    try serializeValueInto(buf, val, allocator, qid_map, call_targets);
                }
            },
            .call_word => |name| {
                try writeCall(buf, allocator, name, call_targets);
            },
            .call_word_direct, .call_word_module => |slot| {
                try writeCall(buf, allocator, slot.name, call_targets);
            },
        }
    }
}

/// Image-mode variant of `serializeInstructionsInto`. Every `push_literal`
/// operand routes through `serializeValueIntoForImage`, so type-carrier
/// values -- notably `.struct_type`, which the by-value path rejects with
/// `NotEncodable` -- are emitted as slot references the loader resolves to
/// live runtime pointers. Used for generator-emitted word bodies (struct
/// constructors, getters, predicates, ...) whose `push_literal` operands are
/// runtime type pointers. Unlike the by-value path, type-carrier literals
/// are not lowered to `call_word`; they slot-encode directly.
pub fn serializeInstructionsIntoForImage(
    buf: *std.ArrayListUnmanaged(u8),
    instructions: []const Instruction,
    effect: ?*const StackEffect,
    allocator: Allocator,
    slot_maps: *const SlotEncodingMaps,
    call_targets: ?CallTargetResolver,
) SerializeError!void {
    try buf.append(allocator, @intFromBool(effect != null));
    if (effect) |e| try writeEffect(buf, allocator, e);
    const count: u32 = @intCast(instructions.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&count));
    for (instructions) |instr| {
        const line: u32 = @intCast(instr.line);
        const col: u32 = @intCast(instr.column);
        try buf.appendSlice(allocator, std.mem.asBytes(&line));
        try buf.appendSlice(allocator, std.mem.asBytes(&col));
        switch (instr.op) {
            .push_literal => |val| {
                try buf.append(allocator, op_tag_push_literal);
                try serializeValueIntoForImage(buf, val, allocator, slot_maps, call_targets);
            },
            .call_word => |name| try writeCall(buf, allocator, name, call_targets),
            .call_word_direct, .call_word_module => |slot| try writeCall(buf, allocator, slot.name, call_targets),
        }
    }
}

/// Image-mode variant of `serializeQuotationInstructions`. See
/// `serializeInstructionsIntoForImage`.
pub fn serializeQuotationInstructionsForImage(
    instructions: []const Instruction,
    effect: ?*const StackEffect,
    allocator: Allocator,
    slot_maps: *const SlotEncodingMaps,
    call_targets: ?CallTargetResolver,
) SerializeError![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    try serializeInstructionsIntoForImage(&buf, instructions, effect, allocator, slot_maps, call_targets);
    return buf.toOwnedSlice(allocator);
}

/// If `val` is a non-simple literal that should be lowered to `call_word`,
/// return its name. Otherwise return null.
fn lowerableName(val: Value) ?[]const u8 {
    return switch (val) {
        .type_val => |tv| tv.name,
        .tagged => |t| t.tag.name,
        .parameter => |p| p.name,
        .marker => |m| m.name,
        else => null,
    };
}

fn writeCallWord(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, name: []const u8) SerializeError!void {
    try buf.append(allocator, op_tag_call_word);
    const len: u32 = @intCast(name.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&len));
    try buf.appendSlice(allocator, name);
}

/// Write a call instruction, baking the target when `call_targets` resolves the name in the
/// body's own module scope and falling back to the bare name otherwise.
fn writeCall(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    name: []const u8,
    call_targets: ?CallTargetResolver,
) SerializeError!void {
    if (call_targets) |resolver| {
        if (try resolver.resolve(resolver.state, name)) |slot_index| {
            try buf.append(allocator, op_tag_call_word_module);
            try buf.appendSlice(allocator, std.mem.asBytes(&slot_index));
            return;
        }
    }
    try writeCallWord(buf, allocator, name);
}

/// Serialize a single Value payload (without the op_tag prefix). `qid_map`
/// stamps each nested quotation with its global ID; pass `null` for the sentinel.
/// `call_targets` bakes call sites inside nested quotation bodies, which share the enclosing
/// body's module scope; pass `null` to keep them bare names.
pub fn serializeValueInto(
    buf: *std.ArrayListUnmanaged(u8),
    val: Value,
    allocator: Allocator,
    qid_map: ?*const QuotationIdMap,
    call_targets: ?CallTargetResolver,
) SerializeError!void {
    switch (val) {
        .fixnum => |v| {
            try buf.append(allocator, value_tag_fixnum);
            try buf.appendSlice(allocator, std.mem.asBytes(&v));
        },
        .float => |v| {
            try buf.append(allocator, value_tag_float);
            try buf.appendSlice(allocator, std.mem.asBytes(&v));
        },
        .boolean => |v| {
            try buf.append(allocator, value_tag_boolean);
            try buf.append(allocator, @intFromBool(v));
        },
        .string => |v| {
            try buf.append(allocator, value_tag_string);
            const len: u32 = @intCast(v.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&len));
            try buf.appendSlice(allocator, v);
        },
        .symbol => |v| {
            try buf.append(allocator, value_tag_symbol);
            const len: u32 = @intCast(v.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&len));
            try buf.appendSlice(allocator, v);
        },
        .quotation => |q| {
            try buf.append(allocator, value_tag_quotation);
            const q_id: u32 = if (qid_map) |m| (m.get(@intFromPtr(q.instructions.ptr)) orelse quotation_id_sentinel) else quotation_id_sentinel;
            try buf.appendSlice(allocator, std.mem.asBytes(&q_id));
            try serializeInstructionsInto(buf, q.instructions, q.effect, allocator, qid_map, call_targets);
        },
        .closure => |cl| {
            // A closure (a runtime curry/compose result) serializes as its plain
            // instruction body: the captures are already encoded as leading
            // push_literals and nested compiled bodies reattach their code_ptr on
            // deserialize. Runtime-image fidelity for closures is deferred; this
            // arm keeps a stray closure from breaking serialization.
            try buf.append(allocator, value_tag_quotation);
            try buf.appendSlice(allocator, std.mem.asBytes(&quotation_id_sentinel));
            try serializeInstructionsInto(buf, cl.instructions, cl.effect, allocator, qid_map, call_targets);
        },
        .array => |arr| {
            try buf.append(allocator, value_tag_array);
            const elem_count: u32 = @intCast(arr.items.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&elem_count));
            for (arr.items) |elem| {
                try serializeValueInto(buf, elem, allocator, qid_map, call_targets);
            }
        },
        .hash => |h| {
            try buf.append(allocator, value_tag_hash);
            const entry_count: u32 = @intCast(h.map.count());
            try buf.appendSlice(allocator, std.mem.asBytes(&entry_count));
            var iter = h.map.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const key_len: u32 = @intCast(key.len);
                try buf.appendSlice(allocator, std.mem.asBytes(&key_len));
                try buf.appendSlice(allocator, key);
                try serializeValueInto(buf, entry.value_ptr.*, allocator, qid_map, call_targets);
            }
        },
        // A mutable_map is an identity-bearing, runtime-mutable object: encoding
        // it by value would deserialize to an independent copy that does not
        // share later mutations, so a word body that pushes a parse-time-folded
        // mutable_map literal (e.g. the lint run-state map) would have its
        // compiled slot-encoded instance and its interpreted image-bytecode
        // instance diverge. Reject by-value here -- mirroring `struct_instance`,
        // which also falls through to `NotEncodable` -- so the word-body emitter
        // defers to the slot-aware image serializer and both paths reference the
        // single loader-built instance.
        .mutable_map => return error.NotEncodable,
        .stack_effect => |effect| {
            try buf.append(allocator, value_tag_stack_effect);
            try writeParamArray(buf, allocator, effect.inputs);
            try writeParamArray(buf, allocator, effect.outputs);
        },
        .unit => {
            try buf.append(allocator, value_tag_unit);
        },
        else => return error.NotEncodable,
    }
}

/// Image-mode variant of `serializeValueInto`. When `slot_maps` is
/// non-null and `val` is a type-carrier variant, emit a slot-reference
/// value tag (`type_val_slot`, `struct_type_slot`, `marker_slot`,
/// `parameter_slot`, or `tagged_slot`) carrying the `u32` slot index;
/// non-type-carrier variants delegate to `serializeValueInto` and array
/// /hash recurse through this function so transitively-reachable
/// type-carriers route through their slot tables.
///
/// When `slot_maps` is null, fall back to `serializeValueInto` directly.
/// Callers that need the legacy behavior keep working unchanged.
pub fn serializeValueIntoForImage(
    buf: *std.ArrayListUnmanaged(u8),
    val: Value,
    allocator: Allocator,
    slot_maps: ?*const SlotEncodingMaps,
    call_targets: ?CallTargetResolver,
) SerializeError!void {
    const maps = slot_maps orelse return serializeValueInto(buf, val, allocator, null, call_targets);
    switch (val) {
        .type_val => |tv| {
            const slot = maps.typevalue_slot_index.get(tv) orelse return error.NotEncodable;
            try buf.append(allocator, value_tag_type_val_slot);
            try buf.appendSlice(allocator, std.mem.asBytes(&slot));
        },
        .struct_type => |st| {
            const slot = maps.struct_type_slot_index.get(st) orelse return error.NotEncodable;
            try buf.append(allocator, value_tag_struct_type_slot);
            try buf.appendSlice(allocator, std.mem.asBytes(&slot));
        },
        .marker => |m| {
            const slot = maps.marker_slot_index.get(m) orelse return error.NotEncodable;
            try buf.append(allocator, value_tag_marker_slot);
            try buf.appendSlice(allocator, std.mem.asBytes(&slot));
        },
        .parameter => |p| {
            const slot = maps.parameter_slot_index.get(p) orelse return error.NotEncodable;
            try buf.append(allocator, value_tag_parameter_slot);
            try buf.appendSlice(allocator, std.mem.asBytes(&slot));
        },
        .tagged => |t| {
            const key: TaggedKey = .{ .tag = t.tag, .inner_ptr = t.inner };
            const slot = maps.tagged_slot_index.get(key) orelse return error.NotEncodable;
            try buf.append(allocator, value_tag_tagged_slot);
            try buf.appendSlice(allocator, std.mem.asBytes(&slot));
        },
        .mutable_map => |m| {
            const slot = maps.mutable_map_slot_index.get(m) orelse return error.NotEncodable;
            try buf.append(allocator, value_tag_mutable_map_slot);
            try buf.appendSlice(allocator, std.mem.asBytes(&slot));
        },
        .struct_instance => |si| {
            const slot = maps.struct_instance_slot_index.get(si) orelse return error.NotEncodable;
            try buf.append(allocator, value_tag_struct_instance_slot);
            try buf.appendSlice(allocator, std.mem.asBytes(&slot));
        },
        .vector => |v| {
            const slot = maps.vector_slot_index.get(v) orelse return error.NotEncodable;
            try buf.append(allocator, value_tag_vector_slot);
            try buf.appendSlice(allocator, std.mem.asBytes(&slot));
        },
        .array => |arr| {
            try buf.append(allocator, value_tag_array);
            const elem_count: u32 = @intCast(arr.items.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&elem_count));
            for (arr.items) |elem| {
                try serializeValueIntoForImage(buf, elem, allocator, slot_maps, call_targets);
            }
        },
        .hash => |h| {
            try buf.append(allocator, value_tag_hash);
            const entry_count: u32 = @intCast(h.map.count());
            try buf.appendSlice(allocator, std.mem.asBytes(&entry_count));
            var iter = h.map.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const key_len: u32 = @intCast(key.len);
                try buf.appendSlice(allocator, std.mem.asBytes(&key_len));
                try buf.appendSlice(allocator, key);
                try serializeValueIntoForImage(buf, entry.value_ptr.*, allocator, slot_maps, call_targets);
            }
        },
        .quotation => |q| {
            // Stamp the quotation's global ID when a build-time map is supplied
            // (so the loader can attach a compiled code_ptr), else the sentinel.
            // The u32 keeps tag 5's layout identical to the by-value path so a
            // by-value-serialized body decoded by the image loader stays aligned.
            try buf.append(allocator, value_tag_quotation);
            const q_id: u32 = if (maps.quotation_id_map) |m| (m.get(@intFromPtr(q.instructions.ptr)) orelse quotation_id_sentinel) else quotation_id_sentinel;
            try buf.appendSlice(allocator, std.mem.asBytes(&q_id));
            try serializeInstructionsIntoForImage(buf, q.instructions, q.effect, allocator, maps, call_targets);
        },
        else => try serializeValueInto(buf, val, allocator, null, call_targets),
    }
}

/// Write an effect payload: the two param arrays, no tag byte. Shared by the
/// stream effect slot and the tag-8 stack_effect value encoding.
fn writeEffect(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, effect: *const StackEffect) SerializeError!void {
    try writeParamArray(buf, allocator, effect.inputs);
    try writeParamArray(buf, allocator, effect.outputs);
}

fn writeParamArray(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, params: []const StackEffectParam) SerializeError!void {
    const count: u32 = @intCast(params.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&count));
    for (params) |param| {
        try buf.append(allocator, @intFromBool(param.is_row_variable));
        const name_len: u32 = @intCast(param.name.len);
        try buf.appendSlice(allocator, std.mem.asBytes(&name_len));
        try buf.appendSlice(allocator, param.name);
        try buf.append(allocator, @intFromBool(param.quotation_effect != null));
        if (param.quotation_effect) |qe| try writeEffect(buf, allocator, qe);
    }
}

/// A decoded quotation stream: the instruction slice plus the declared stack
/// effect recovered from the stream's effect slot, null when none was
/// serialized. Both are allocated through the decode allocator.
pub const DecodedQuotation = struct {
    instructions: []Instruction,
    effect: ?*const StackEffect,
};

/// Decode a quotation stream from a serialized byte buffer. Caller owns
/// the returned instructions, effect, and any string/symbol/array/hash
/// payloads that were allocated through `allocator`.
pub fn deserializeQuotationInstructions(data: []const u8, allocator: Allocator, qfns: ?[]const ?*const anyopaque) Allocator.Error!DecodedQuotation {
    var offset: usize = 0;
    return deserializeInstructionsAt(data, &offset, allocator, qfns);
}

/// Decode a quotation stream starting at `offset`, advancing it past the
/// consumed bytes. When `qfns` is non-null, a nested quotation's decoded
/// `quotation_id` indexes it to attach a compiled `code_ptr`; pass `null` to
/// leave every reconstructed quotation's `code_ptr` null.
pub fn deserializeInstructionsAt(data: []const u8, offset: *usize, allocator: Allocator, qfns: ?[]const ?*const anyopaque) Allocator.Error!DecodedQuotation {
    const effect = try readStreamEffect(data, offset, allocator);
    errdefer if (effect) |e| freeEffectTree(allocator, e);
    if (offset.* + 4 > data.len) return error.OutOfMemory;
    const count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    const instructions = try allocator.alloc(Instruction, count);
    errdefer allocator.free(instructions);
    for (instructions) |*instr| {
        if (offset.* + 9 > data.len) return error.OutOfMemory; // line(4)+col(4)+op_tag(1)
        const line = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        const col = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        const op_tag = data[offset.*];
        offset.* += 1;
        if (op_tag == op_tag_push_literal) {
            const val = try deserializeValueAt(data, offset, allocator, qfns);
            instr.* = .{ .op = .{ .push_literal = val }, .line = line, .column = col };
        } else if (op_tag == op_tag_call_word) {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const nlen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (offset.* + nlen > data.len) return error.OutOfMemory;
            const name_copy = try allocator.dupe(u8, data[offset.*..][0..nlen]);
            offset.* += nlen;
            instr.* = .{ .op = .{ .call_word = name_copy }, .line = line, .column = col };
        } else {
            return error.OutOfMemory;
        }
    }
    return .{ .instructions = instructions, .effect = effect };
}

/// Image-mode variant of `deserializeQuotationInstructions`. `push_literal`
/// operands decode through `deserializeValueAtForImage`, which resolves
/// slot-encoded type-carrier values against the loader's slot tables and
/// falls back to the by-value decoder for plain literals. Backward
/// compatible with bodies serialized by the non-image path, since those
/// carry no slot tags.
pub fn deserializeQuotationInstructionsForImage(
    data: []const u8,
    allocator: Allocator,
    slot_tables: *const SlotResolutionTables,
) Allocator.Error!DecodedQuotation {
    var offset: usize = 0;
    return deserializeInstructionsAtForImage(data, &offset, allocator, slot_tables);
}

/// Image-mode variant of `deserializeInstructionsAt`. See
/// `deserializeQuotationInstructionsForImage`.
pub fn deserializeInstructionsAtForImage(
    data: []const u8,
    offset: *usize,
    allocator: Allocator,
    slot_tables: *const SlotResolutionTables,
) Allocator.Error!DecodedQuotation {
    const effect = try readStreamEffect(data, offset, allocator);
    errdefer if (effect) |e| freeEffectTree(allocator, e);
    if (offset.* + 4 > data.len) return error.OutOfMemory;
    const count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    const instructions = try allocator.alloc(Instruction, count);
    errdefer allocator.free(instructions);
    for (instructions) |*instr| {
        if (offset.* + 9 > data.len) return error.OutOfMemory; // line(4)+col(4)+op_tag(1)
        const line = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        const col = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        const op_tag = data[offset.*];
        offset.* += 1;
        if (op_tag == op_tag_push_literal) {
            const val = try deserializeValueAtForImage(data, offset, allocator, slot_tables);
            instr.* = .{ .op = .{ .push_literal = val }, .line = line, .column = col };
        } else if (op_tag == op_tag_call_word) {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const nlen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (offset.* + nlen > data.len) return error.OutOfMemory;
            const name_copy = try allocator.dupe(u8, data[offset.*..][0..nlen]);
            offset.* += nlen;
            instr.* = .{ .op = .{ .call_word = name_copy }, .line = line, .column = col };
        } else if (op_tag == op_tag_call_word_module) {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot_index = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const slots = slot_tables.call_target_slots orelse return error.OutOfMemory;
            if (slot_index >= slot_tables.call_target_slot_count) return error.OutOfMemory;
            const slot = slots[slot_index] orelse return error.OutOfMemory;
            instr.* = .{ .op = .{ .call_word_module = slot }, .line = line, .column = col };
        } else {
            return error.OutOfMemory;
        }
    }
    return .{ .instructions = instructions, .effect = effect };
}

/// Decode a single value payload starting at `offset`, advancing it past
/// the consumed bytes. The returned `Value` may transitively own
/// allocations from `allocator`.
pub fn deserializeValueAt(data: []const u8, offset: *usize, allocator: Allocator, qfns: ?[]const ?*const anyopaque) Allocator.Error!Value {
    if (offset.* >= data.len) return error.OutOfMemory;
    const val_tag = data[offset.*];
    offset.* += 1;
    return switch (val_tag) {
        value_tag_fixnum => blk: {
            if (offset.* + 8 > data.len) return error.OutOfMemory;
            const v = std.mem.readInt(i64, data[offset.*..][0..8], .little);
            offset.* += 8;
            break :blk .{ .fixnum = v };
        },
        value_tag_float => blk: {
            if (offset.* + 8 > data.len) return error.OutOfMemory;
            const v = @as(f64, @bitCast(std.mem.readInt(u64, data[offset.*..][0..8], .little)));
            offset.* += 8;
            break :blk .{ .float = v };
        },
        value_tag_boolean => blk: {
            if (offset.* >= data.len) return error.OutOfMemory;
            const v = data[offset.*] != 0;
            offset.* += 1;
            break :blk .{ .boolean = v };
        },
        value_tag_string => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (offset.* + slen > data.len) return error.OutOfMemory;
            const copy = try allocator.dupe(u8, data[offset.*..][0..slen]);
            offset.* += slen;
            break :blk .{ .string = copy };
        },
        value_tag_symbol => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (offset.* + slen > data.len) return error.OutOfMemory;
            const copy = try allocator.dupe(u8, data[offset.*..][0..slen]);
            offset.* += slen;
            break :blk .{ .symbol = copy };
        },
        value_tag_quotation => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const q_id = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const nested = try deserializeInstructionsAt(data, offset, allocator, qfns);
            const code_ptr: ?*const anyopaque = if (qfns) |t|
                (if (q_id != quotation_id_sentinel and q_id < t.len) t[q_id] else null)
            else
                null;
            break :blk .{ .quotation = .{ .instructions = nested.instructions, .effect = nested.effect, .code_ptr = code_ptr } };
        },
        value_tag_array => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const elem_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const elems = try allocator.alloc(Value, elem_count);
            for (elems) |*elem| {
                elem.* = try deserializeValueAt(data, offset, allocator, qfns);
            }
            // Decoded literals mirror parse-time literals: static storage,
            // struct and backing owned by the decode allocator.
            const arr = value_mod.Array.createStatic(allocator, elems) catch return error.OutOfMemory;
            break :blk .{ .array = arr };
        },
        value_tag_hash => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const entry_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const h = HashTable.create(allocator) catch return error.OutOfMemory;
            try h.map.ensureTotalCapacity(allocator, entry_count);
            for (0..entry_count) |_| {
                if (offset.* + 4 > data.len) return error.OutOfMemory;
                const klen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
                offset.* += 4;
                if (offset.* + klen > data.len) return error.OutOfMemory;
                const key = try allocator.dupe(u8, data[offset.*..][0..klen]);
                offset.* += klen;
                const value = try deserializeValueAt(data, offset, allocator, qfns);
                h.map.putAssumeCapacity(key, value);
            }
            break :blk .{ .hash = h };
        },
        value_tag_mutable_map => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const entry_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const m = MutableMap.create(allocator) catch return error.OutOfMemory;
            try m.map.ensureTotalCapacity(allocator, entry_count);
            for (0..entry_count) |_| {
                if (offset.* + 4 > data.len) return error.OutOfMemory;
                const klen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
                offset.* += 4;
                if (offset.* + klen > data.len) return error.OutOfMemory;
                const key = try allocator.dupe(u8, data[offset.*..][0..klen]);
                offset.* += klen;
                const value = try deserializeValueAt(data, offset, allocator, qfns);
                m.map.putAssumeCapacity(key, value);
            }
            break :blk .{ .mutable_map = m };
        },
        value_tag_stack_effect => blk: {
            const inputs = try readParamArray(data, offset, allocator);
            const outputs = try readParamArray(data, offset, allocator);
            break :blk .{ .stack_effect = .{ .inputs = inputs, .outputs = outputs } };
        },
        value_tag_unit => .{ .unit = {} },
        else => return error.OutOfMemory,
    };
}

/// Image-mode variant of `deserializeValueAt`. When the encoded value
/// uses one of the slot-reference tags emitted by
/// `serializeValueIntoForImage`, resolve the slot index through
/// `slot_tables` and reconstruct the runtime Value. Slot indices that
/// fall outside their table return `error.OutOfMemory` (the shared
/// deserialize error channel, kept narrow to avoid a separate decoder
/// error set).
///
/// Every decoded value lands in a stored position (a map entry, vector
/// element, struct field, tagged inner, or push_literal operand), and a
/// stored reference is an owning reference. The header-backed slot arms
/// therefore retain what they hand out; the struct-instance arm counts the
/// edge instead, because its fields may still be placeholders mid-load.
/// The context's image-slot teardown walk releases these references.
///
/// When `slot_tables` is null, behave identically to `deserializeValueAt`.
pub fn deserializeValueAtForImage(
    data: []const u8,
    offset: *usize,
    allocator: Allocator,
    slot_tables: ?*const SlotResolutionTables,
) Allocator.Error!Value {
    if (offset.* >= data.len) return error.OutOfMemory;
    const val_tag = data[offset.*];
    const tables = slot_tables orelse return deserializeValueAt(data, offset, allocator, null);
    offset.* += 1;
    return switch (val_tag) {
        value_tag_type_val_slot => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (slot >= tables.typevalue_slot_count) return error.OutOfMemory;
            const table = tables.typevalue_slots orelse return error.OutOfMemory;
            const tv = table[slot] orelse return error.OutOfMemory;
            break :blk .{ .type_val = @constCast(tv) };
        },
        value_tag_struct_type_slot => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (slot >= tables.struct_type_slot_count) return error.OutOfMemory;
            const table = tables.struct_type_slots orelse return error.OutOfMemory;
            const st = table[slot] orelse return error.OutOfMemory;
            break :blk .{ .struct_type = st };
        },
        value_tag_marker_slot => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (slot >= tables.marker_slot_count) return error.OutOfMemory;
            const table = tables.marker_slots orelse return error.OutOfMemory;
            const m = table[slot] orelse return error.OutOfMemory;
            break :blk .{ .marker = m };
        },
        value_tag_parameter_slot => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (slot >= tables.parameter_slot_count) return error.OutOfMemory;
            const table = tables.parameter_slots orelse return error.OutOfMemory;
            const p = table[slot] orelse return error.OutOfMemory;
            break :blk .{ .parameter = p };
        },
        value_tag_tagged_slot => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (slot >= tables.tagged_slot_count) return error.OutOfMemory;
            const table = tables.tagged_slots orelse return error.OutOfMemory;
            const tv = table[slot] orelse return error.OutOfMemory;
            // The copy is a second reference to the boxed inner value; retain
            // its transitive backings so the stored copy owns its edge like
            // every other storage boundary.
            container_backing.retainValue(tv.*);
            break :blk tv.*;
        },
        value_tag_mutable_map_slot => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (slot >= tables.mutable_map_slot_count) return error.OutOfMemory;
            const table = tables.mutable_map_slots orelse return error.OutOfMemory;
            const m = table[slot] orelse return error.OutOfMemory;
            // The decoded value is stored (map entry, vector element, struct
            // field, or push_literal operand), and a stored reference is an
            // owning reference. The slot table keeps its own donated
            // refcount, released by the context's image-slot teardown walk.
            m.header.retain();
            break :blk .{ .mutable_map = m };
        },
        value_tag_struct_instance_slot => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (slot >= tables.struct_instance_slot_count) return error.OutOfMemory;
            const table = tables.struct_instance_slots orelse return error.OutOfMemory;
            const si = table[slot] orelse return error.OutOfMemory;
            // The stored copy owns its edge through the instance header, which
            // never touches the fields, so retaining here is safe even while
            // the field pass has not filled them yet. Loader-created slot
            // instances always carry a header.
            si.header.?.retain();
            break :blk .{ .struct_instance = si };
        },
        value_tag_vector_slot => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (slot >= tables.vector_slot_count) return error.OutOfMemory;
            const table = tables.vector_slots orelse return error.OutOfMemory;
            const v = table[slot] orelse return error.OutOfMemory;
            v.header.retain();
            break :blk .{ .vector = v };
        },
        value_tag_array => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const elem_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const elems = try allocator.alloc(Value, elem_count);
            for (elems) |*elem| {
                elem.* = try deserializeValueAtForImage(data, offset, allocator, slot_tables);
            }
            // Decoded literals mirror parse-time literals: static storage,
            // struct and backing owned by the decode allocator.
            const arr = value_mod.Array.createStatic(allocator, elems) catch return error.OutOfMemory;
            break :blk .{ .array = arr };
        },
        value_tag_hash => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const entry_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const h = HashTable.create(allocator) catch return error.OutOfMemory;
            try h.map.ensureTotalCapacity(allocator, entry_count);
            for (0..entry_count) |_| {
                if (offset.* + 4 > data.len) return error.OutOfMemory;
                const klen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
                offset.* += 4;
                if (offset.* + klen > data.len) return error.OutOfMemory;
                const key = try allocator.dupe(u8, data[offset.*..][0..klen]);
                offset.* += klen;
                const value = try deserializeValueAtForImage(data, offset, allocator, slot_tables);
                h.map.putAssumeCapacity(key, value);
            }
            break :blk .{ .hash = h };
        },
        value_tag_quotation => blk: {
            // Read the quotation_id and attach the compiled code_ptr from the
            // quotation-fn table when supplied (id != sentinel, in bounds), so a
            // runtime-selected dispatch of an image-decoded quotation runs
            // compiled; otherwise leave it null (the pre-attachment behavior).
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const q_id = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const nested = try deserializeInstructionsAtForImage(data, offset, allocator, tables);
            if (tables.decoded_streams) |streams| {
                if (container_backing.instructionsHaveContainerLiteral(nested.instructions)) {
                    try streams.append(tables.decoded_streams_allocator.?, nested.instructions);
                }
            }
            const code_ptr: ?*const anyopaque = if (tables.quotation_fns) |t|
                (if (q_id != quotation_id_sentinel and q_id < t.len) t[q_id] else null)
            else
                null;
            break :blk .{ .quotation = .{ .instructions = nested.instructions, .effect = nested.effect, .code_ptr = code_ptr } };
        },
        else => blk: {
            // Rewind one byte so the legacy decoder re-reads the tag.
            offset.* -= 1;
            break :blk deserializeValueAt(data, offset, allocator, null);
        },
    };
}

fn readStreamEffect(data: []const u8, offset: *usize, allocator: Allocator) Allocator.Error!?*const StackEffect {
    if (offset.* >= data.len) return error.OutOfMemory;
    const has_effect = data[offset.*] != 0;
    offset.* += 1;
    if (!has_effect) return null;
    return try readEffect(data, offset, allocator);
}

/// Free a decoded effect tree: the param arrays, their duped names, nested effects, and the box.
/// Error-path cleanup for a decoder whose caller is not an arena; a partial read inside
/// `readEffect` itself keeps the shallow-cleanup convention instruction payloads follow.
fn freeEffectTree(allocator: Allocator, effect: *const StackEffect) void {
    freeParamTree(allocator, effect.inputs);
    freeParamTree(allocator, effect.outputs);
    allocator.destroy(effect);
}

fn freeParamTree(allocator: Allocator, params: []const StackEffectParam) void {
    for (params) |p| {
        allocator.free(p.name);
        if (p.quotation_effect) |qe| freeEffectTree(allocator, qe);
    }
    allocator.free(params);
}

/// Read an effect payload into a boxed `StackEffect`, the shape
/// `Quotation.effect` and `StackEffectParam.quotation_effect` point at.
fn readEffect(data: []const u8, offset: *usize, allocator: Allocator) Allocator.Error!*const StackEffect {
    const inputs = try readParamArray(data, offset, allocator);
    const outputs = try readParamArray(data, offset, allocator);
    const effect = try allocator.create(StackEffect);
    effect.* = .{ .inputs = inputs, .outputs = outputs };
    return effect;
}

fn readParamArray(data: []const u8, offset: *usize, allocator: Allocator) Allocator.Error![]StackEffectParam {
    if (offset.* + 4 > data.len) return error.OutOfMemory;
    const count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    const params = try allocator.alloc(StackEffectParam, count);
    for (params) |*param| {
        if (offset.* + 5 > data.len) return error.OutOfMemory; // is_row_variable(1)+name_len(4)
        const is_row = data[offset.*] != 0;
        offset.* += 1;
        const nlen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        if (offset.* + nlen > data.len) return error.OutOfMemory;
        const name = try allocator.dupe(u8, data[offset.*..][0..nlen]);
        offset.* += nlen;
        if (offset.* >= data.len) return error.OutOfMemory;
        const has_nested = data[offset.*] != 0;
        offset.* += 1;
        const nested: ?*const StackEffect = if (has_nested) try readEffect(data, offset, allocator) else null;
        param.* = .{ .name = name, .is_row_variable = is_row, .quotation_effect = nested };
    }
    return params;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn freeDecodedQuotation(decoded: DecodedQuotation) void {
    freeDecodedInstructions(decoded.instructions);
    if (decoded.effect) |e| freeEffectTree(testing.allocator, e);
}

fn freeDecodedInstructions(decoded: []Instruction) void {
    for (decoded) |instr| {
        freeDecodedOp(instr.op);
    }
    testing.allocator.free(decoded);
}

fn freeDecodedOp(op: Instruction.Op) void {
    switch (op) {
        .push_literal => |v| freeDecodedValue(v),
        .call_word => |n| testing.allocator.free(n),
        // Both slot-carrying call forms reference a heap-stable `WordSlot` owned elsewhere -- the
        // dictionary for a direct call, the runtime-image loader for a module call -- so there is
        // nothing here to free. A direct call is never produced by the decoder at all.
        .call_word_direct, .call_word_module => {},
    }
}

fn freeDecodedValue(v: Value) void {
    switch (v) {
        .string => |s| testing.allocator.free(s),
        .symbol => |s| testing.allocator.free(s),
        .array => |arr| {
            // Decoded arrays are static-storage, so the header release is a
            // no-op; free the raw allocations directly.
            for (arr.items) |elem| freeDecodedValue(elem);
            testing.allocator.free(arr.items);
            testing.allocator.destroy(arr);
        },
        .quotation => |q| {
            for (q.instructions) |instr| freeDecodedOp(instr.op);
            testing.allocator.free(q.instructions);
            if (q.effect) |e| freeEffectTree(testing.allocator, e);
        },
        .hash => |h| {
            // Raw string/array allocations inside the decoded values are not
            // refcounted, so free them here and blank the slots; the header
            // release then frees the dup'd keys and the struct itself.
            var iter = h.map.iterator();
            while (iter.next()) |entry| {
                freeDecodedValue(entry.value_ptr.*);
                entry.value_ptr.* = .unit;
            }
            h.header.release();
        },
        .stack_effect => |effect| {
            freeParamTree(testing.allocator, effect.inputs);
            freeParamTree(testing.allocator, effect.outputs);
        },
        else => {},
    }
}

test "roundtrip: fixnum push + call" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expect(decoded[0].op == .push_literal);
    try testing.expectEqual(@as(i64, 1), decoded[0].op.push_literal.fixnum);
    try testing.expect(decoded[1].op == .call_word);
    try testing.expectEqualStrings("+", decoded[1].op.call_word);
}

/// A resolver that bakes exactly one name, so a test can cover both arms of `writeCall`.
const OneNameResolver = struct {
    name: []const u8,
    slot_index: u32,

    fn resolve(state_raw: *anyopaque, name: []const u8) Allocator.Error!?u32 {
        const self: *OneNameResolver = @ptrCast(@alignCast(state_raw));
        if (!std.mem.eql(u8, name, self.name)) return null;
        return self.slot_index;
    }

    fn resolver(self: *OneNameResolver) CallTargetResolver {
        return .{ .state = self, .resolve = resolve };
    }
};

test "call target: a resolved name bakes a slot index, an unresolved one stays a bare name" {
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = "own-word" }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    };
    var state: OneNameResolver = .{ .name = "own-word", .slot_index = 0 };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, state.resolver());
    defer testing.allocator.free(data);

    // The decoder only stores the slot address; nothing here dereferences the definition, so a
    // stand-in pointer is enough to keep this test free of the dictionary's type graph.
    var definition_placeholder: u8 = 0;
    var slot: WordSlot = .{
        .name = "own-word",
        .definition = std.atomic.Value(*word_slot_mod.WordDefinition).init(@ptrCast(&definition_placeholder)),
    };
    var slots = [_]?*WordSlot{&slot};
    const tables: SlotResolutionTables = .{
        .typevalue_slots = null,
        .typevalue_slot_count = 0,
        .struct_type_slots = null,
        .struct_type_slot_count = 0,
        .marker_slots = null,
        .marker_slot_count = 0,
        .parameter_slots = null,
        .parameter_slot_count = 0,
        .tagged_slots = null,
        .tagged_slot_count = 0,
        .mutable_map_slots = null,
        .mutable_map_slot_count = 0,
        .struct_instance_slots = null,
        .struct_instance_slot_count = 0,
        .vector_slots = null,
        .vector_slot_count = 0,
        .call_target_slots = &slots,
        .call_target_slot_count = 1,
    };

    const decoded_q = try deserializeQuotationInstructionsForImage(data, testing.allocator, &tables);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expect(decoded[0].op == .call_word_module);
    try testing.expectEqual(&slot, decoded[0].op.call_word_module);
    try testing.expect(decoded[1].op == .call_word);
    try testing.expectEqualStrings("+", decoded[1].op.call_word);
}

test "call target: the by-value decoder rejects a baked call, deferring to the image decoder" {
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = "own-word" }, .line = 1 },
    };
    var state: OneNameResolver = .{ .name = "own-word", .slot_index = 0 };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, state.resolver());
    defer testing.allocator.free(data);

    try testing.expectError(
        error.OutOfMemory,
        deserializeQuotationInstructions(data, testing.allocator, null),
    );
}

test "roundtrip: string literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expect(decoded[0].op.push_literal == .string);
    try testing.expectEqualStrings("hello", decoded[0].op.push_literal.string);
}

test "roundtrip: empty body" {
    const instrs: [0]Instruction = .{};
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer testing.allocator.free(decoded.instructions);
    try testing.expectEqual(@as(usize, 0), decoded.instructions.len);
    try testing.expect(decoded.effect == null);
}

test "roundtrip: bool and float" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 3.14 } }, .line = 2 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expectEqual(true, decoded[0].op.push_literal.boolean);
    try testing.expectEqual(@as(f64, 3.14), decoded[1].op.push_literal.float);
}

test "preserves line and column" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 5, .column = 10 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;
    try testing.expectEqual(@as(usize, 5), decoded[0].line);
    try testing.expectEqual(@as(usize, 10), decoded[0].column);
}

test "roundtrip: symbol literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .symbol = "foo" } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expect(decoded[0].op.push_literal == .symbol);
    try testing.expectEqualStrings("foo", decoded[0].op.push_literal.symbol);
}

test "roundtrip: empty array" {
    var empty = value_mod.Array{ .header = undefined, .items = &.{}, .storage = .static };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &empty } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expect(decoded[0].op.push_literal == .array);
    try testing.expectEqual(@as(usize, 0), decoded[0].op.push_literal.array.items.len);
    try testing.expectEqual(.static, decoded[0].op.push_literal.array.storage);
}

test "roundtrip: array with elements" {
    const elems = [_]Value{
        .{ .fixnum = 42 },
        .{ .string = "hello" },
        .{ .boolean = true },
    };
    var arr_lit = value_mod.Array{ .header = undefined, .items = &elems, .storage = .static };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &arr_lit } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    const arr = decoded[0].op.push_literal.array.items;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqual(@as(i64, 42), arr[0].fixnum);
    try testing.expectEqualStrings("hello", arr[1].string);
    try testing.expectEqual(true, arr[2].boolean);
}

test "roundtrip: nested array" {
    const inner1 = [_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } };
    const inner2 = [_]Value{.{ .fixnum = 3 }};
    var inner1_arr = value_mod.Array{ .header = undefined, .items = &inner1, .storage = .static };
    var inner2_arr = value_mod.Array{ .header = undefined, .items = &inner2, .storage = .static };
    const outer = [_]Value{
        .{ .array = &inner1_arr },
        .{ .array = &inner2_arr },
    };
    var outer_arr = value_mod.Array{ .header = undefined, .items = &outer, .storage = .static };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &outer_arr } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    const arr = decoded[0].op.push_literal.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqual(@as(usize, 2), arr[0].array.items.len);
    try testing.expectEqual(@as(i64, 1), arr[0].array.items[0].fixnum);
    try testing.expectEqual(@as(i64, 2), arr[0].array.items[1].fixnum);
    try testing.expectEqual(@as(usize, 1), arr[1].array.items.len);
    try testing.expectEqual(@as(i64, 3), arr[1].array.items[0].fixnum);
}

test "roundtrip: empty hash" {
    const h_ptr = try HashTable.create(testing.allocator);
    defer h_ptr.header.release();
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = h_ptr } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expect(decoded[0].op.push_literal == .hash);
    try testing.expectEqual(@as(u32, 0), decoded[0].op.push_literal.hash.map.count());
}

test "roundtrip: hash with entries" {
    const h_ptr = try HashTable.create(testing.allocator);
    defer h_ptr.header.release();
    try h_ptr.map.put(testing.allocator, try testing.allocator.dupe(u8, "x"), .{ .fixnum = 10 });
    try h_ptr.map.put(testing.allocator, try testing.allocator.dupe(u8, "y"), .{ .boolean = false });
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = h_ptr } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    const dh = decoded[0].op.push_literal.hash;
    try testing.expectEqual(@as(u32, 2), dh.map.count());
    try testing.expectEqual(@as(i64, 10), dh.map.get("x").?.fixnum);
    try testing.expectEqual(false, dh.map.get("y").?.boolean);
}

test "roundtrip: nested quotation" {
    const inner_instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    };
    const outer_instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner_instrs } } }, .line = 1 },
        .{ .op = .{ .call_word = "call" }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&outer_instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expect(decoded[0].op.push_literal == .quotation);
    const nested = decoded[0].op.push_literal.quotation.instructions;
    try testing.expectEqual(@as(usize, 2), nested.len);
    try testing.expectEqual(@as(i64, 7), nested[0].op.push_literal.fixnum);
    try testing.expect(nested[1].op == .call_word);
    try testing.expectEqualStrings("*", nested[1].op.call_word);
    try testing.expectEqualStrings("call", decoded[1].op.call_word);
}

test "roundtrip: array containing symbol" {
    const elems = [_]Value{.{ .symbol = "cond" }};
    var arr_lit = value_mod.Array{ .header = undefined, .items = &elems, .storage = .static };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &arr_lit } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    const arr = decoded[0].op.push_literal.array.items;
    try testing.expectEqual(@as(usize, 1), arr.len);
    try testing.expectEqualStrings("cond", arr[0].symbol);
}

test "roundtrip: stack_effect literal" {
    const inputs = [_]StackEffectParam{
        .{ .name = "a" },
        .{ .name = "b" },
    };
    const outputs = [_]StackEffectParam{
        .{ .name = "sum" },
    };
    const effect = StackEffect{ .inputs = &inputs, .outputs = &outputs };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .stack_effect = effect } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expect(decoded[0].op.push_literal == .stack_effect);
    const dec_eff = decoded[0].op.push_literal.stack_effect;
    try testing.expectEqual(@as(usize, 2), dec_eff.inputs.len);
    try testing.expectEqualStrings("a", dec_eff.inputs[0].name);
    try testing.expectEqualStrings("b", dec_eff.inputs[1].name);
    try testing.expectEqual(@as(usize, 1), dec_eff.outputs.len);
    try testing.expectEqualStrings("sum", dec_eff.outputs[0].name);
}

test "roundtrip: stack_effect preserves is_row_variable" {
    const inputs = [_]StackEffectParam{
        .{ .name = "..a", .is_row_variable = true },
        .{ .name = "x" },
    };
    const outputs = [_]StackEffectParam{
        .{ .name = "..a", .is_row_variable = true },
        .{ .name = "y" },
    };
    const effect = StackEffect{ .inputs = &inputs, .outputs = &outputs };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .stack_effect = effect } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    const dec_eff = decoded[0].op.push_literal.stack_effect;
    try testing.expect(dec_eff.inputs[0].is_row_variable);
    try testing.expect(!dec_eff.inputs[1].is_row_variable);
    try testing.expect(dec_eff.outputs[0].is_row_variable);
    try testing.expect(!dec_eff.outputs[1].is_row_variable);
}

test "roundtrip: stack_effect with empty params" {
    const effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .stack_effect = effect } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    const dec_eff = decoded[0].op.push_literal.stack_effect;
    try testing.expectEqual(@as(usize, 0), dec_eff.inputs.len);
    try testing.expectEqual(@as(usize, 0), dec_eff.outputs.len);
}

test "roundtrip: unit literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .unit = {} } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expect(decoded[0].op.push_literal == .unit);
}

test "image roundtrip: struct_instance encodes as a slot and decodes to the same pointer" {
    const alloc = testing.allocator;

    var st = StructType{ .name = "rec", .fields = &.{ "a", "b" } };
    const fields = try alloc.alloc(Value, 2);
    fields[0] = .{ .fixnum = 10 };
    fields[1] = .{ .fixnum = 20 };
    // The decode arm retains the instance header, so the fixture must be a
    // headered instance, matching what the loader puts in a real slot table.
    const si = try value_mod.createStructInstance(alloc, &st, fields);
    defer si.header.?.release();

    // Encode side: only the struct_instance index is populated; the other
    // index maps are empty but must be present.
    var tv_idx: std.AutoHashMapUnmanaged(*const TypeValue, u32) = .{};
    defer tv_idx.deinit(alloc);
    var st_idx: std.AutoHashMapUnmanaged(*const StructType, u32) = .{};
    defer st_idx.deinit(alloc);
    var mk_idx: std.AutoHashMapUnmanaged(*const Marker, u32) = .{};
    defer mk_idx.deinit(alloc);
    var pm_idx: std.AutoHashMapUnmanaged(*const Parameter, u32) = .{};
    defer pm_idx.deinit(alloc);
    var tg_idx: std.AutoHashMapUnmanaged(TaggedKey, u32) = .{};
    defer tg_idx.deinit(alloc);
    var mm_idx: std.AutoHashMapUnmanaged(*const MutableMap, u32) = .{};
    defer mm_idx.deinit(alloc);
    var sx_idx: std.AutoHashMapUnmanaged(*const StructInstance, u32) = .{};
    defer sx_idx.deinit(alloc);
    var vx_idx: std.AutoHashMapUnmanaged(*const Vector, u32) = .{};
    defer vx_idx.deinit(alloc);
    try sx_idx.put(alloc, si, 0);

    const enc = SlotEncodingMaps{
        .typevalue_slot_index = &tv_idx,
        .struct_type_slot_index = &st_idx,
        .marker_slot_index = &mk_idx,
        .parameter_slot_index = &pm_idx,
        .tagged_slot_index = &tg_idx,
        .mutable_map_slot_index = &mm_idx,
        .struct_instance_slot_index = &sx_idx,
        .vector_slot_index = &vx_idx,
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try serializeValueIntoForImage(&buf, .{ .struct_instance = si }, alloc, &enc, null);

    // Decode side: a slot table whose only entry resolves back to `si`.
    var si_slots = [_]?*StructInstance{si};
    const tables = SlotResolutionTables{
        .typevalue_slots = null,
        .typevalue_slot_count = 0,
        .struct_type_slots = null,
        .struct_type_slot_count = 0,
        .marker_slots = null,
        .marker_slot_count = 0,
        .parameter_slots = null,
        .parameter_slot_count = 0,
        .tagged_slots = null,
        .tagged_slot_count = 0,
        .mutable_map_slots = null,
        .mutable_map_slot_count = 0,
        .struct_instance_slots = &si_slots,
        .struct_instance_slot_count = 1,
        .vector_slots = null,
        .vector_slot_count = 0,
    };

    var offset: usize = 0;
    const decoded = try deserializeValueAtForImage(buf.items, &offset, alloc, &tables);
    defer container_backing.releaseValue(decoded);
    try testing.expect(decoded == .struct_instance);
    try testing.expectEqual(@as(*StructInstance, si), decoded.struct_instance);
    try testing.expectEqual(buf.items.len, offset);
}

test "image roundtrip: quotation carrying a struct_type literal slot-encodes" {
    const alloc = testing.allocator;

    // A quotation whose body pushes a struct_type literal -- the shape a
    // struct instance's `check`/`fix` field holds when the lint registry is
    // serialized into the runtime image. The by-value path rejects a
    // struct_type, so before routing the `.quotation` case through the image
    // serializer this raised `error.NotEncodable`.
    var st = StructType{ .name = "rec", .fields = &.{"a"} };
    const quot_instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 1 },
    };
    const q = Value{ .quotation = .{ .instructions = &quot_instrs } };

    var tv_idx: std.AutoHashMapUnmanaged(*const TypeValue, u32) = .{};
    defer tv_idx.deinit(alloc);
    var st_idx: std.AutoHashMapUnmanaged(*const StructType, u32) = .{};
    defer st_idx.deinit(alloc);
    try st_idx.put(alloc, &st, 0);
    var mk_idx: std.AutoHashMapUnmanaged(*const Marker, u32) = .{};
    defer mk_idx.deinit(alloc);
    var pm_idx: std.AutoHashMapUnmanaged(*const Parameter, u32) = .{};
    defer pm_idx.deinit(alloc);
    var tg_idx: std.AutoHashMapUnmanaged(TaggedKey, u32) = .{};
    defer tg_idx.deinit(alloc);
    var mm_idx: std.AutoHashMapUnmanaged(*const MutableMap, u32) = .{};
    defer mm_idx.deinit(alloc);
    var sx_idx: std.AutoHashMapUnmanaged(*const StructInstance, u32) = .{};
    defer sx_idx.deinit(alloc);
    var vx_idx: std.AutoHashMapUnmanaged(*const Vector, u32) = .{};
    defer vx_idx.deinit(alloc);

    const enc = SlotEncodingMaps{
        .typevalue_slot_index = &tv_idx,
        .struct_type_slot_index = &st_idx,
        .marker_slot_index = &mk_idx,
        .parameter_slot_index = &pm_idx,
        .tagged_slot_index = &tg_idx,
        .mutable_map_slot_index = &mm_idx,
        .struct_instance_slot_index = &sx_idx,
        .vector_slot_index = &vx_idx,
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try serializeValueIntoForImage(&buf, q, alloc, &enc, null);

    var st_slots = [_]?*StructType{&st};
    const tables = SlotResolutionTables{
        .typevalue_slots = null,
        .typevalue_slot_count = 0,
        .struct_type_slots = &st_slots,
        .struct_type_slot_count = 1,
        .marker_slots = null,
        .marker_slot_count = 0,
        .parameter_slots = null,
        .parameter_slot_count = 0,
        .tagged_slots = null,
        .tagged_slot_count = 0,
        .mutable_map_slots = null,
        .mutable_map_slot_count = 0,
        .struct_instance_slots = null,
        .struct_instance_slot_count = 0,
        .vector_slots = null,
        .vector_slot_count = 0,
    };

    var offset: usize = 0;
    const decoded = try deserializeValueAtForImage(buf.items, &offset, alloc, &tables);
    defer alloc.free(decoded.quotation.instructions);
    try testing.expect(decoded == .quotation);
    const di = decoded.quotation.instructions;
    try testing.expectEqual(@as(usize, 1), di.len);
    try testing.expect(di[0].op == .push_literal);
    try testing.expect(di[0].op.push_literal == .struct_type);
    try testing.expectEqual(&st, di[0].op.push_literal.struct_type);
    try testing.expectEqual(buf.items.len, offset);
}

test "image roundtrip: nested quotation carries id and compiled code_ptr" {
    // The lint registry's `check` quotation is serialized through the image
    // path inside a mutable_map / struct_instance slot. With a quotation-ID map
    // at serialize and a quotation-fn table at deserialize, the decoded
    // quotation carries the matching compiled function pointer.
    const alloc = testing.allocator;
    const inner = [_]Instruction{
        .{ .op = .{ .call_word = "noop" }, .line = 1 },
    };
    const inner_slice: []const Instruction = &inner;
    const q = Value{ .quotation = .{ .instructions = inner_slice } };

    var tv_idx: std.AutoHashMapUnmanaged(*const TypeValue, u32) = .{};
    defer tv_idx.deinit(alloc);
    var st_idx: std.AutoHashMapUnmanaged(*const StructType, u32) = .{};
    defer st_idx.deinit(alloc);
    var mk_idx: std.AutoHashMapUnmanaged(*const Marker, u32) = .{};
    defer mk_idx.deinit(alloc);
    var pm_idx: std.AutoHashMapUnmanaged(*const Parameter, u32) = .{};
    defer pm_idx.deinit(alloc);
    var tg_idx: std.AutoHashMapUnmanaged(TaggedKey, u32) = .{};
    defer tg_idx.deinit(alloc);
    var mm_idx: std.AutoHashMapUnmanaged(*const MutableMap, u32) = .{};
    defer mm_idx.deinit(alloc);
    var sx_idx: std.AutoHashMapUnmanaged(*const StructInstance, u32) = .{};
    defer sx_idx.deinit(alloc);
    var vx_idx: std.AutoHashMapUnmanaged(*const Vector, u32) = .{};
    defer vx_idx.deinit(alloc);

    var qid_map = QuotationIdMap{};
    defer qid_map.deinit(alloc);
    try qid_map.put(alloc, @intFromPtr(inner_slice.ptr), 2);

    const enc = SlotEncodingMaps{
        .typevalue_slot_index = &tv_idx,
        .struct_type_slot_index = &st_idx,
        .marker_slot_index = &mk_idx,
        .parameter_slot_index = &pm_idx,
        .tagged_slot_index = &tg_idx,
        .mutable_map_slot_index = &mm_idx,
        .struct_instance_slot_index = &sx_idx,
        .vector_slot_index = &vx_idx,
        .quotation_id_map = &qid_map,
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try serializeValueIntoForImage(&buf, q, alloc, &enc, null);

    // The encoded u32 immediately after the tag byte is the stamped id.
    try testing.expectEqual(value_tag_quotation, buf.items[0]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf.items[1..5], .little));

    const dummy_fn: *const anyopaque = @ptrFromInt(0x9abc);
    const table = [_]?*const anyopaque{ null, null, dummy_fn };
    const tables = SlotResolutionTables{
        .typevalue_slots = null,
        .typevalue_slot_count = 0,
        .struct_type_slots = null,
        .struct_type_slot_count = 0,
        .marker_slots = null,
        .marker_slot_count = 0,
        .parameter_slots = null,
        .parameter_slot_count = 0,
        .tagged_slots = null,
        .tagged_slot_count = 0,
        .mutable_map_slots = null,
        .mutable_map_slot_count = 0,
        .struct_instance_slots = null,
        .struct_instance_slot_count = 0,
        .vector_slots = null,
        .vector_slot_count = 0,
        .quotation_fns = &table,
    };

    var offset: usize = 0;
    const decoded = try deserializeValueAtForImage(buf.items, &offset, alloc, &tables);
    defer freeDecodedValue(decoded);
    try testing.expect(decoded == .quotation);
    try testing.expectEqual(dummy_fn, decoded.quotation.code_ptr.?);
    try testing.expectEqual(buf.items.len, offset);
}

test "image roundtrip: nested quotation decodes null code_ptr without a map or table" {
    // Without a quotation-ID map at serialize and no fn table at deserialize,
    // the image path stamps the sentinel and leaves code_ptr null -- the
    // pre-attachment behavior every non-lint image fixture relies on.
    const alloc = testing.allocator;
    const inner = [_]Instruction{
        .{ .op = .{ .call_word = "noop" }, .line = 1 },
    };
    const q = Value{ .quotation = .{ .instructions = &inner } };

    var tv_idx: std.AutoHashMapUnmanaged(*const TypeValue, u32) = .{};
    defer tv_idx.deinit(alloc);
    var st_idx: std.AutoHashMapUnmanaged(*const StructType, u32) = .{};
    defer st_idx.deinit(alloc);
    var mk_idx: std.AutoHashMapUnmanaged(*const Marker, u32) = .{};
    defer mk_idx.deinit(alloc);
    var pm_idx: std.AutoHashMapUnmanaged(*const Parameter, u32) = .{};
    defer pm_idx.deinit(alloc);
    var tg_idx: std.AutoHashMapUnmanaged(TaggedKey, u32) = .{};
    defer tg_idx.deinit(alloc);
    var mm_idx: std.AutoHashMapUnmanaged(*const MutableMap, u32) = .{};
    defer mm_idx.deinit(alloc);
    var sx_idx: std.AutoHashMapUnmanaged(*const StructInstance, u32) = .{};
    defer sx_idx.deinit(alloc);
    var vx_idx: std.AutoHashMapUnmanaged(*const Vector, u32) = .{};
    defer vx_idx.deinit(alloc);

    const enc = SlotEncodingMaps{
        .typevalue_slot_index = &tv_idx,
        .struct_type_slot_index = &st_idx,
        .marker_slot_index = &mk_idx,
        .parameter_slot_index = &pm_idx,
        .tagged_slot_index = &tg_idx,
        .mutable_map_slot_index = &mm_idx,
        .struct_instance_slot_index = &sx_idx,
        .vector_slot_index = &vx_idx,
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try serializeValueIntoForImage(&buf, q, alloc, &enc, null);
    try testing.expectEqual(quotation_id_sentinel, std.mem.readInt(u32, buf.items[1..5], .little));

    const tables = SlotResolutionTables{
        .typevalue_slots = null,
        .typevalue_slot_count = 0,
        .struct_type_slots = null,
        .struct_type_slot_count = 0,
        .marker_slots = null,
        .marker_slot_count = 0,
        .parameter_slots = null,
        .parameter_slot_count = 0,
        .tagged_slots = null,
        .tagged_slot_count = 0,
        .mutable_map_slots = null,
        .mutable_map_slot_count = 0,
        .struct_instance_slots = null,
        .struct_instance_slot_count = 0,
        .vector_slots = null,
        .vector_slot_count = 0,
    };

    var offset: usize = 0;
    const decoded = try deserializeValueAtForImage(buf.items, &offset, alloc, &tables);
    defer freeDecodedValue(decoded);
    try testing.expect(decoded == .quotation);
    try testing.expect(decoded.quotation.code_ptr == null);
}

test "lowering: type_val push_literal becomes call_word" {
    var tv = TypeValue{
        .name = "fixnum",
        .descriptor = null,
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .type_val = &tv } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expect(decoded[0].op == .call_word);
    try testing.expectEqualStrings("fixnum", decoded[0].op.call_word);
}

test "lowering: tagged push_literal becomes call_word using tag name" {
    var virtual = VirtualType{
        .name = "stdio-mode:inherit",
        .inner_type = "unit",
    };
    const inner_val = Value{ .unit = {} };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .tagged = .{ .tag = &virtual, .inner = &inner_val } } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expect(decoded[0].op == .call_word);
    try testing.expectEqualStrings("stdio-mode:inherit", decoded[0].op.call_word);
}

test "lowering: parameter push_literal becomes call_word" {
    var param = Parameter{
        .name = "current-stdout",
        .default_quotation = .{ .instructions = &.{} },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .parameter = &param } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expect(decoded[0].op == .call_word);
    try testing.expectEqualStrings("current-stdout", decoded[0].op.call_word);
}

test "lowering: marker push_literal becomes call_word" {
    var marker = Marker{ .name = "const" };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .marker = &marker } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    try testing.expect(decoded[0].op == .call_word);
    try testing.expectEqualStrings("const", decoded[0].op.call_word);
}

test "nested quotation in array literal carries compiled code_ptr" {
    // A `case` / `cond` branch table is a single `.array` push_literal whose
    // branch quotation is buried inside. The composite serializer stamps the
    // quotation with its global ID; the runtime deserialize attaches the
    // matching compiled function pointer from the quotation table.
    const inner = [_]Instruction{
        .{ .op = .{ .call_word = "noop" }, .line = 1 },
    };
    const inner_slice: []const Instruction = &inner;
    const elems = [_]Value{
        .{ .quotation = .{ .instructions = inner_slice } },
    };
    var arr_lit = value_mod.Array{ .header = undefined, .items = &elems, .storage = .static };
    const arr: Value = .{ .array = &arr_lit };

    var qid_map = QuotationIdMap{};
    defer qid_map.deinit(testing.allocator);
    try qid_map.put(testing.allocator, @intFromPtr(inner_slice.ptr), 3);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);
    try serializeValueInto(&buf, arr, testing.allocator, &qid_map, null);

    // Quotation table: slot 3 holds a dummy compiled function pointer.
    const dummy_fn: *const anyopaque = @ptrFromInt(0x1234);
    var table = [_]?*const anyopaque{ null, null, null, dummy_fn };

    var offset: usize = 0;
    const decoded = try deserializeValueAt(buf.items, &offset, testing.allocator, &table);
    defer freeDecodedValue(decoded);

    try testing.expect(decoded == .array);
    try testing.expectEqual(@as(usize, 1), decoded.array.items.len);
    try testing.expect(decoded.array.items[0] == .quotation);
    try testing.expectEqual(dummy_fn, decoded.array.items[0].quotation.code_ptr.?);
}

test "nested quotation in hash literal carries compiled code_ptr" {
    // The lexer's `H{ ... match: [ ... ] }` rules are a single `.hash`; the
    // dispatched quotation is stored under a symbol key.
    const inner = [_]Instruction{
        .{ .op = .{ .call_word = "noop" }, .line = 1 },
    };
    const inner_slice: []const Instruction = &inner;
    const h = try HashTable.create(testing.allocator);
    defer h.header.release();
    try h.map.put(testing.allocator, try testing.allocator.dupe(u8, "match"), .{ .quotation = .{ .instructions = inner_slice } });
    const hash_val: Value = .{ .hash = h };

    var qid_map = QuotationIdMap{};
    defer qid_map.deinit(testing.allocator);
    try qid_map.put(testing.allocator, @intFromPtr(inner_slice.ptr), 1);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);
    try serializeValueInto(&buf, hash_val, testing.allocator, &qid_map, null);

    const dummy_fn: *const anyopaque = @ptrFromInt(0x5678);
    var table = [_]?*const anyopaque{ null, dummy_fn };

    var offset: usize = 0;
    const decoded = try deserializeValueAt(buf.items, &offset, testing.allocator, &table);
    defer freeDecodedValue(decoded);

    try testing.expect(decoded == .hash);
    const got = decoded.hash.map.get("match").?;
    try testing.expect(got == .quotation);
    try testing.expectEqual(dummy_fn, got.quotation.code_ptr.?);
}

test "nested quotation decodes to null code_ptr without a map or table" {
    // The sentinel path: no quotation-ID map at serialize and no table at
    // deserialize leaves the reconstructed quotation's code_ptr null, the
    // behavior every non-AOT caller relies on.
    const inner = [_]Instruction{
        .{ .op = .{ .call_word = "noop" }, .line = 1 },
    };
    const elems = [_]Value{
        .{ .quotation = .{ .instructions = &inner } },
    };
    var arr_lit = value_mod.Array{ .header = undefined, .items = &elems, .storage = .static };
    const arr: Value = .{ .array = &arr_lit };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);
    try serializeValueInto(&buf, arr, testing.allocator, null, null);

    var offset: usize = 0;
    const decoded = try deserializeValueAt(buf.items, &offset, testing.allocator, null);
    defer freeDecodedValue(decoded);

    try testing.expect(decoded == .array);
    try testing.expect(decoded.array.items[0] == .quotation);
    try testing.expect(decoded.array.items[0].quotation.code_ptr == null);
}

test "roundtrip: stream carries a declared effect" {
    const inputs = [_]StackEffectParam{
        .{ .name = "..a", .is_row_variable = true },
        .{ .name = "x" },
    };
    const outputs = [_]StackEffectParam{
        .{ .name = "y" },
    };
    const effect = StackEffect{ .inputs = &inputs, .outputs = &outputs };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, &effect, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded);

    try testing.expectEqual(@as(usize, 1), decoded.instructions.len);
    const dec_eff = decoded.effect.?;
    try testing.expectEqual(@as(usize, 2), dec_eff.inputs.len);
    try testing.expectEqualStrings("..a", dec_eff.inputs[0].name);
    try testing.expect(dec_eff.inputs[0].is_row_variable);
    try testing.expectEqualStrings("x", dec_eff.inputs[1].name);
    try testing.expect(!dec_eff.inputs[1].is_row_variable);
    try testing.expectEqual(@as(usize, 1), dec_eff.outputs.len);
    try testing.expectEqualStrings("y", dec_eff.outputs[0].name);
}

test "roundtrip: nested quotation carries its declared effect" {
    const declared_inputs = [_]StackEffectParam{ .{ .name = "a" }, .{ .name = "b" } };
    const declared_outputs = [_]StackEffectParam{.{ .name = "c" }};
    const declared = StackEffect{ .inputs = &declared_inputs, .outputs = &declared_outputs };
    const inner_instrs = [_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const outer_instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner_instrs, .effect = &declared } } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&outer_instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded);

    try testing.expect(decoded.effect == null);
    const q = decoded.instructions[0].op.push_literal.quotation;
    const dec_eff = q.effect.?;
    try testing.expectEqual(@as(usize, 2), dec_eff.inputs.len);
    try testing.expectEqualStrings("a", dec_eff.inputs[0].name);
    try testing.expectEqualStrings("b", dec_eff.inputs[1].name);
    try testing.expectEqual(@as(usize, 1), dec_eff.outputs.len);
    try testing.expectEqualStrings("c", dec_eff.outputs[0].name);
}

test "roundtrip: recursive quotation_effect on a param" {
    const nested_inputs = [_]StackEffectParam{.{ .name = "x" }};
    const nested_outputs = [_]StackEffectParam{.{ .name = "y" }};
    const nested = StackEffect{ .inputs = &nested_inputs, .outputs = &nested_outputs };
    const inputs = [_]StackEffectParam{
        .{ .name = "quot", .quotation_effect = &nested },
    };
    const effect = StackEffect{ .inputs = &inputs, .outputs = &.{} };
    const instrs: [0]Instruction = .{};
    const data = try serializeQuotationInstructions(&instrs, &effect, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded);

    const dec_eff = decoded.effect.?;
    try testing.expectEqual(@as(usize, 1), dec_eff.inputs.len);
    try testing.expectEqualStrings("quot", dec_eff.inputs[0].name);
    const dec_nested = dec_eff.inputs[0].quotation_effect.?;
    try testing.expectEqual(@as(usize, 1), dec_nested.inputs.len);
    try testing.expectEqualStrings("x", dec_nested.inputs[0].name);
    try testing.expectEqual(@as(usize, 1), dec_nested.outputs.len);
    try testing.expectEqualStrings("y", dec_nested.outputs[0].name);
}

test "roundtrip: stack_effect value carries a param's nested quotation_effect" {
    const nested_inputs = [_]StackEffectParam{.{ .name = "n" }};
    const nested = StackEffect{ .inputs = &nested_inputs, .outputs = &.{} };
    const inputs = [_]StackEffectParam{
        .{ .name = "quot", .quotation_effect = &nested },
    };
    const effect = StackEffect{ .inputs = &inputs, .outputs = &.{} };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .stack_effect = effect } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, null, testing.allocator, null, null);
    defer testing.allocator.free(data);
    const decoded_q = try deserializeQuotationInstructions(data, testing.allocator, null);
    defer freeDecodedQuotation(decoded_q);
    const decoded = decoded_q.instructions;

    const dec_eff = decoded[0].op.push_literal.stack_effect;
    const dec_nested = dec_eff.inputs[0].quotation_effect.?;
    try testing.expectEqual(@as(usize, 1), dec_nested.inputs.len);
    try testing.expectEqualStrings("n", dec_nested.inputs[0].name);
}

test "image roundtrip: nested quotation carries its declared effect" {
    const alloc = testing.allocator;
    const declared_outputs = [_]StackEffectParam{.{ .name = "n" }};
    const declared = StackEffect{ .inputs = &.{}, .outputs = &declared_outputs };
    const inner = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 1 },
    };
    const q = Value{ .quotation = .{ .instructions = &inner, .effect = &declared } };

    var tv_idx: std.AutoHashMapUnmanaged(*const TypeValue, u32) = .{};
    defer tv_idx.deinit(alloc);
    var st_idx: std.AutoHashMapUnmanaged(*const StructType, u32) = .{};
    defer st_idx.deinit(alloc);
    var mk_idx: std.AutoHashMapUnmanaged(*const Marker, u32) = .{};
    defer mk_idx.deinit(alloc);
    var pm_idx: std.AutoHashMapUnmanaged(*const Parameter, u32) = .{};
    defer pm_idx.deinit(alloc);
    var tg_idx: std.AutoHashMapUnmanaged(TaggedKey, u32) = .{};
    defer tg_idx.deinit(alloc);
    var mm_idx: std.AutoHashMapUnmanaged(*const MutableMap, u32) = .{};
    defer mm_idx.deinit(alloc);
    var sx_idx: std.AutoHashMapUnmanaged(*const StructInstance, u32) = .{};
    defer sx_idx.deinit(alloc);
    var vx_idx: std.AutoHashMapUnmanaged(*const Vector, u32) = .{};
    defer vx_idx.deinit(alloc);

    const enc = SlotEncodingMaps{
        .typevalue_slot_index = &tv_idx,
        .struct_type_slot_index = &st_idx,
        .marker_slot_index = &mk_idx,
        .parameter_slot_index = &pm_idx,
        .tagged_slot_index = &tg_idx,
        .mutable_map_slot_index = &mm_idx,
        .struct_instance_slot_index = &sx_idx,
        .vector_slot_index = &vx_idx,
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try serializeValueIntoForImage(&buf, q, alloc, &enc, null);

    const tables = SlotResolutionTables{
        .typevalue_slots = null,
        .typevalue_slot_count = 0,
        .struct_type_slots = null,
        .struct_type_slot_count = 0,
        .marker_slots = null,
        .marker_slot_count = 0,
        .parameter_slots = null,
        .parameter_slot_count = 0,
        .tagged_slots = null,
        .tagged_slot_count = 0,
        .mutable_map_slots = null,
        .mutable_map_slot_count = 0,
        .struct_instance_slots = null,
        .struct_instance_slot_count = 0,
        .vector_slots = null,
        .vector_slot_count = 0,
    };

    var offset: usize = 0;
    const decoded = try deserializeValueAtForImage(buf.items, &offset, alloc, &tables);
    defer freeDecodedValue(decoded);
    try testing.expect(decoded == .quotation);
    const dec_eff = decoded.quotation.effect.?;
    try testing.expectEqual(@as(usize, 0), dec_eff.inputs.len);
    try testing.expectEqual(@as(usize, 1), dec_eff.outputs.len);
    try testing.expectEqualStrings("n", dec_eff.outputs[0].name);
    try testing.expectEqual(buf.items.len, offset);
}
