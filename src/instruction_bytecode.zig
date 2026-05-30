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
//! u32 instruction_count
//! instruction[]
//! ```
//!
//! Per instruction:
//!
//! ```
//! u32 line | u32 column | u8 op_tag | payload
//! ```
//!
//! Op tags: `0 = push_literal`, `1 = call_word`.
//!
//! `call_word` payload: `u32 name_len | name_bytes`.
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
//! - `5 = quotation`: recursive (instruction_count + instructions)
//! - `6 = array`: `u32 elem_count | values[]`
//! - `7 = hash`: `u32 entry_count | entries[]` where each entry is
//!   `u32 key_len | key_bytes | value`
//! - `8 = stack_effect`: `u32 input_count | params[] | u32 output_count |
//!   params[]` where each param is `u8 is_row_variable | u32 name_len |
//!   name_bytes`
//! - `9 = unit`: empty payload
//! - `15 = mutable_map`: same wire shape as hash, but the loader
//!   allocates a fresh `MutableMap` so mutations persist across pushes.
//!   Image-mode encoding prefers `16 = mutable_map_slot` so freeze-time
//!   identity is preserved; the non-image form is used by JIT
//!   round-tripping where no slot map is available.
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
//! The `stack_effect` encoding preserves param `name` and `is_row_variable`
//! flags. It does not encode `type_annotation` (which holds a TypeValue
//! pointer) or `quotation_effect` (which is recursive). A future revision
//! can extend the wire format with a TypeValue slot resolver and recursive
//! effects without renumbering the existing tags.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const HashTable = value_mod.HashTable;
const TypeValue = value_mod.TypeValue;
const VirtualType = value_mod.VirtualType;
const StructType = value_mod.StructType;
const Marker = value_mod.Marker;
const Parameter = value_mod.Parameter;
const MutableMap = value_mod.MutableMap;

const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;

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
};

/// Op tags. Stored in the bytecode stream.
const op_tag_push_literal: u8 = 0;
const op_tag_call_word: u8 = 1;

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

/// Serialize an instruction slice into a freshly allocated byte buffer.
/// Caller owns the returned slice.
pub fn serializeQuotationInstructions(instructions: []const Instruction, allocator: Allocator) SerializeError![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    try serializeInstructionsInto(&buf, instructions, allocator);
    return buf.toOwnedSlice(allocator);
}

/// Append a serialized instruction slice to an existing buffer.
pub fn serializeInstructionsInto(buf: *std.ArrayListUnmanaged(u8), instructions: []const Instruction, allocator: Allocator) SerializeError!void {
    const count: u32 = @intCast(instructions.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&count));
    for (instructions) |instr| {
        const line: u32 = @intCast(instr.line);
        const col: u32 = @intCast(instr.column);
        try buf.appendSlice(allocator, std.mem.asBytes(&line));
        try buf.appendSlice(allocator, std.mem.asBytes(&col));
        switch (instr.op) {
            .push_literal => |val| {
                if (lowerableName(val)) |name| {
                    try writeCallWord(buf, allocator, name);
                } else {
                    try buf.append(allocator, op_tag_push_literal);
                    try serializeValueInto(buf, val, allocator);
                }
            },
            .call_word => |name| {
                try writeCallWord(buf, allocator, name);
            },
            .call_word_direct => |slot| {
                try writeCallWord(buf, allocator, slot.name);
            },
        }
    }
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

/// Serialize a single Value payload (without the op_tag prefix).
pub fn serializeValueInto(buf: *std.ArrayListUnmanaged(u8), val: Value, allocator: Allocator) SerializeError!void {
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
            try serializeInstructionsInto(buf, q.instructions, allocator);
        },
        .array => |elems| {
            try buf.append(allocator, value_tag_array);
            const elem_count: u32 = @intCast(elems.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&elem_count));
            for (elems) |elem| {
                try serializeValueInto(buf, elem, allocator);
            }
        },
        .hash => |h| {
            try buf.append(allocator, value_tag_hash);
            const entry_count: u32 = @intCast(h.count());
            try buf.appendSlice(allocator, std.mem.asBytes(&entry_count));
            var iter = h.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const key_len: u32 = @intCast(key.len);
                try buf.appendSlice(allocator, std.mem.asBytes(&key_len));
                try buf.appendSlice(allocator, key);
                try serializeValueInto(buf, entry.value_ptr.*, allocator);
            }
        },
        .mutable_map => |m| {
            try buf.append(allocator, value_tag_mutable_map);
            const entry_count: u32 = @intCast(m.map.count());
            try buf.appendSlice(allocator, std.mem.asBytes(&entry_count));
            var iter = m.map.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const key_len: u32 = @intCast(key.len);
                try buf.appendSlice(allocator, std.mem.asBytes(&key_len));
                try buf.appendSlice(allocator, key);
                try serializeValueInto(buf, entry.value_ptr.*, allocator);
            }
        },
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
) SerializeError!void {
    const maps = slot_maps orelse return serializeValueInto(buf, val, allocator);
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
        .array => |elems| {
            try buf.append(allocator, value_tag_array);
            const elem_count: u32 = @intCast(elems.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&elem_count));
            for (elems) |elem| {
                try serializeValueIntoForImage(buf, elem, allocator, slot_maps);
            }
        },
        .hash => |h| {
            try buf.append(allocator, value_tag_hash);
            const entry_count: u32 = @intCast(h.count());
            try buf.appendSlice(allocator, std.mem.asBytes(&entry_count));
            var iter = h.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const key_len: u32 = @intCast(key.len);
                try buf.appendSlice(allocator, std.mem.asBytes(&key_len));
                try buf.appendSlice(allocator, key);
                try serializeValueIntoForImage(buf, entry.value_ptr.*, allocator, slot_maps);
            }
        },
        .quotation => |q| {
            try buf.append(allocator, value_tag_quotation);
            try serializeInstructionsInto(buf, q.instructions, allocator);
        },
        else => try serializeValueInto(buf, val, allocator),
    }
}

fn writeParamArray(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, params: []const StackEffectParam) SerializeError!void {
    const count: u32 = @intCast(params.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&count));
    for (params) |param| {
        try buf.append(allocator, @intFromBool(param.is_row_variable));
        const name_len: u32 = @intCast(param.name.len);
        try buf.appendSlice(allocator, std.mem.asBytes(&name_len));
        try buf.appendSlice(allocator, param.name);
    }
}

/// Decode an instruction slice from a serialized byte buffer. Caller owns
/// the returned slice and any string/symbol/array/hash payloads that were
/// allocated through `allocator`.
pub fn deserializeQuotationInstructions(data: []const u8, allocator: Allocator) Allocator.Error![]Instruction {
    var offset: usize = 0;
    return deserializeInstructionsAt(data, &offset, allocator);
}

/// Decode an instruction slice starting at `offset`, advancing it past the
/// consumed bytes.
pub fn deserializeInstructionsAt(data: []const u8, offset: *usize, allocator: Allocator) Allocator.Error![]Instruction {
    if (offset.* + 4 > data.len) return error.OutOfMemory;
    const count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    const instructions = try allocator.alloc(Instruction, count);
    for (instructions) |*instr| {
        if (offset.* + 9 > data.len) return error.OutOfMemory; // line(4)+col(4)+op_tag(1)
        const line = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        const col = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        const op_tag = data[offset.*];
        offset.* += 1;
        if (op_tag == op_tag_push_literal) {
            const val = try deserializeValueAt(data, offset, allocator);
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
    return instructions;
}

/// Decode a single value payload starting at `offset`, advancing it past
/// the consumed bytes. The returned `Value` may transitively own
/// allocations from `allocator`.
pub fn deserializeValueAt(data: []const u8, offset: *usize, allocator: Allocator) Allocator.Error!Value {
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
            const nested = try deserializeInstructionsAt(data, offset, allocator);
            break :blk .{ .quotation = .{ .instructions = nested } };
        },
        value_tag_array => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const elem_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const elems = try allocator.alloc(Value, elem_count);
            for (elems) |*elem| {
                elem.* = try deserializeValueAt(data, offset, allocator);
            }
            break :blk .{ .array = elems };
        },
        value_tag_hash => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const entry_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            var h = HashTable{};
            try h.ensureTotalCapacity(allocator, entry_count);
            for (0..entry_count) |_| {
                if (offset.* + 4 > data.len) return error.OutOfMemory;
                const klen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
                offset.* += 4;
                if (offset.* + klen > data.len) return error.OutOfMemory;
                const key = try allocator.dupe(u8, data[offset.*..][0..klen]);
                offset.* += klen;
                const value = try deserializeValueAt(data, offset, allocator);
                h.putAssumeCapacity(key, value);
            }
            const h_ptr = try allocator.create(HashTable);
            h_ptr.* = h;
            break :blk .{ .hash = h_ptr };
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
                const value = try deserializeValueAt(data, offset, allocator);
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
/// When `slot_tables` is null, behave identically to `deserializeValueAt`.
pub fn deserializeValueAtForImage(
    data: []const u8,
    offset: *usize,
    allocator: Allocator,
    slot_tables: ?*const SlotResolutionTables,
) Allocator.Error!Value {
    if (offset.* >= data.len) return error.OutOfMemory;
    const val_tag = data[offset.*];
    const tables = slot_tables orelse return deserializeValueAt(data, offset, allocator);
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
            break :blk tv.*;
        },
        value_tag_mutable_map_slot => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slot = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (slot >= tables.mutable_map_slot_count) return error.OutOfMemory;
            const table = tables.mutable_map_slots orelse return error.OutOfMemory;
            const m = table[slot] orelse return error.OutOfMemory;
            break :blk .{ .mutable_map = m };
        },
        value_tag_array => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const elem_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const elems = try allocator.alloc(Value, elem_count);
            for (elems) |*elem| {
                elem.* = try deserializeValueAtForImage(data, offset, allocator, slot_tables);
            }
            break :blk .{ .array = elems };
        },
        value_tag_hash => blk: {
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const entry_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            var h = HashTable{};
            try h.ensureTotalCapacity(allocator, entry_count);
            for (0..entry_count) |_| {
                if (offset.* + 4 > data.len) return error.OutOfMemory;
                const klen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
                offset.* += 4;
                if (offset.* + klen > data.len) return error.OutOfMemory;
                const key = try allocator.dupe(u8, data[offset.*..][0..klen]);
                offset.* += klen;
                const value = try deserializeValueAtForImage(data, offset, allocator, slot_tables);
                h.putAssumeCapacity(key, value);
            }
            const h_ptr = try allocator.create(HashTable);
            h_ptr.* = h;
            break :blk .{ .hash = h_ptr };
        },
        else => blk: {
            // Rewind one byte so the legacy decoder re-reads the tag.
            offset.* -= 1;
            break :blk deserializeValueAt(data, offset, allocator);
        },
    };
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
        param.* = .{ .name = name, .is_row_variable = is_row };
    }
    return params;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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
        // Direct-call instructions reference a heap-stable `WordSlot` owned
        // by the dictionary; nothing here to free, and direct-call ops are
        // not produced by the bytecode decoder in the first place.
        .call_word_direct => {},
    }
}

fn freeDecodedValue(v: Value) void {
    switch (v) {
        .string => |s| testing.allocator.free(s),
        .symbol => |s| testing.allocator.free(s),
        .array => |elems| {
            for (elems) |elem| freeDecodedValue(elem);
            testing.allocator.free(elems);
        },
        .quotation => |q| {
            for (q.instructions) |instr| freeDecodedOp(instr.op);
            testing.allocator.free(q.instructions);
        },
        .hash => |h| {
            var iter = h.iterator();
            while (iter.next()) |entry| {
                testing.allocator.free(entry.key_ptr.*);
                freeDecodedValue(entry.value_ptr.*);
            }
            h.deinit(testing.allocator);
            testing.allocator.destroy(h);
        },
        .stack_effect => |effect| {
            for (effect.inputs) |p| testing.allocator.free(p.name);
            testing.allocator.free(effect.inputs);
            for (effect.outputs) |p| testing.allocator.free(p.name);
            testing.allocator.free(effect.outputs);
        },
        else => {},
    }
}

test "roundtrip: fixnum push + call" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expect(decoded[0].op == .push_literal);
    try testing.expectEqual(@as(i64, 1), decoded[0].op.push_literal.fixnum);
    try testing.expect(decoded[1].op == .call_word);
    try testing.expectEqualStrings("+", decoded[1].op.call_word);
}

test "roundtrip: string literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expect(decoded[0].op.push_literal == .string);
    try testing.expectEqualStrings("hello", decoded[0].op.push_literal.string);
}

test "roundtrip: empty body" {
    const instrs: [0]Instruction = .{};
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 0), decoded.len);
}

test "roundtrip: bool and float" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 3.14 } }, .line = 2 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expectEqual(true, decoded[0].op.push_literal.boolean);
    try testing.expectEqual(@as(f64, 3.14), decoded[1].op.push_literal.float);
}

test "preserves line and column" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 5, .column = 10 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);
    try testing.expectEqual(@as(usize, 5), decoded[0].line);
    try testing.expectEqual(@as(usize, 10), decoded[0].column);
}

test "roundtrip: symbol literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .symbol = "foo" } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    try testing.expect(decoded[0].op.push_literal == .symbol);
    try testing.expectEqualStrings("foo", decoded[0].op.push_literal.symbol);
}

test "roundtrip: empty array" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &.{} } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    try testing.expect(decoded[0].op.push_literal == .array);
    try testing.expectEqual(@as(usize, 0), decoded[0].op.push_literal.array.len);
}

test "roundtrip: array with elements" {
    const elems = [_]Value{
        .{ .fixnum = 42 },
        .{ .string = "hello" },
        .{ .boolean = true },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &elems } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    const arr = decoded[0].op.push_literal.array;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqual(@as(i64, 42), arr[0].fixnum);
    try testing.expectEqualStrings("hello", arr[1].string);
    try testing.expectEqual(true, arr[2].boolean);
}

test "roundtrip: nested array" {
    const inner1 = [_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } };
    const inner2 = [_]Value{.{ .fixnum = 3 }};
    const outer = [_]Value{
        .{ .array = &inner1 },
        .{ .array = &inner2 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &outer } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    const arr = decoded[0].op.push_literal.array;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqual(@as(usize, 2), arr[0].array.len);
    try testing.expectEqual(@as(i64, 1), arr[0].array[0].fixnum);
    try testing.expectEqual(@as(i64, 2), arr[0].array[1].fixnum);
    try testing.expectEqual(@as(usize, 1), arr[1].array.len);
    try testing.expectEqual(@as(i64, 3), arr[1].array[0].fixnum);
}

test "roundtrip: empty hash" {
    const h_ptr = try testing.allocator.create(HashTable);
    h_ptr.* = HashTable{};
    defer testing.allocator.destroy(h_ptr);
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = h_ptr } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    try testing.expect(decoded[0].op.push_literal == .hash);
    try testing.expectEqual(@as(u32, 0), decoded[0].op.push_literal.hash.count());
}

test "roundtrip: hash with entries" {
    var h = HashTable{};
    try h.put(testing.allocator, "x", .{ .fixnum = 10 });
    try h.put(testing.allocator, "y", .{ .boolean = false });
    defer h.deinit(testing.allocator);
    const h_ptr = try testing.allocator.create(HashTable);
    h_ptr.* = h;
    defer testing.allocator.destroy(h_ptr);
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = h_ptr } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    const dh = decoded[0].op.push_literal.hash;
    try testing.expectEqual(@as(u32, 2), dh.count());
    try testing.expectEqual(@as(i64, 10), dh.get("x").?.fixnum);
    try testing.expectEqual(false, dh.get("y").?.boolean);
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
    const data = try serializeQuotationInstructions(&outer_instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

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
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &elems } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    const arr = decoded[0].op.push_literal.array;
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
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

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
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

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
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    const dec_eff = decoded[0].op.push_literal.stack_effect;
    try testing.expectEqual(@as(usize, 0), dec_eff.inputs.len);
    try testing.expectEqual(@as(usize, 0), dec_eff.outputs.len);
}

test "roundtrip: unit literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .unit = {} } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    try testing.expect(decoded[0].op.push_literal == .unit);
}

test "lowering: type_val push_literal becomes call_word" {
    var tv = TypeValue{
        .name = "fixnum",
        .descriptor = null,
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .type_val = &tv } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

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
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

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
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    try testing.expect(decoded[0].op == .call_word);
    try testing.expectEqualStrings("current-stdout", decoded[0].op.call_word);
}

test "lowering: marker push_literal becomes call_word" {
    var marker = Marker{ .name = "const" };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .marker = &marker } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer freeDecodedInstructions(decoded);

    try testing.expect(decoded[0].op == .call_word);
    try testing.expectEqualStrings("const", decoded[0].op.call_word);
}
