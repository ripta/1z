const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const VirtualType = value_mod.VirtualType;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;
const Marker = value_mod.Marker;
const MutableMap = value_mod.MutableMap;

const BigIntManaged = value_mod.BigIntManaged;
const Allocator = std.mem.Allocator;

const helpers = @import("helpers.zig");
const markers_mod = @import("markers.zig");
const dispatch_mod = @import("../dispatch.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const dictionary_mod = @import("../dictionary.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const WordDefinition = dictionary_mod.WordDefinition;

pub const primitives = [_]Primitive{
    .{ .name = "define-virtual", .stack_effect = "name: descriptor markers --", .doc = "Define a virtual type and its accessor words.", .func = nativeDefineVirtual },
    .{ .name = "define-parameterized-type", .stack_effect = "name: base-type element-type --", .doc = "Define a parameterized virtual type with element validation.", .func = nativeDefineParameterizedType },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "virtual-wrap", .func = virtualWrapHelper, .stack_effect = "value vtype-ptr -- tagged" },
    .{ .name = "virtual-unwrap", .func = virtualUnwrapHelper, .stack_effect = "tagged vtype-ptr -- value" },
    .{ .name = "virtual-type-predicate", .func = virtualTypePredicateHelper, .stack_effect = "value vtype-ptr -- ?" },
    .{ .name = "virtual-struct-wrap", .func = virtualStructWrapHelper, .polymorphic = true },
    .{ .name = "virtual-struct-unwrap", .func = virtualStructUnwrapHelper, .polymorphic = true },
    .{ .name = "virtual-struct-to-hash", .func = virtualStructToHashHelper, .stack_effect = "tagged vtype-ptr -- hash" },
    .{ .name = "virtual-struct-hash-wrap", .func = virtualStructHashWrapHelper, .stack_effect = "hash vtype-ptr -- tagged" },
    .{ .name = "virtual-parameterized-wrap", .func = virtualParameterizedWrapHelper, .stack_effect = "value vtype-ptr -- tagged" },
    .{ .name = "typed-validate-and-promote", .func = typedValidateAndPromote, .stack_effect = "value vtype-ptr -- promoted-value" },
    .{ .name = "typed-validate-seq-elements", .func = typedValidateSeqElements, .stack_effect = "seq vtype-ptr -- seq" },
    .{ .name = "typed-nth-mut-dispatch", .func = typedNthMutDispatch, .stack_effect = "typed-vec n elem vtype-ptr -- typed-vec" },
};

/// define-virtual ( name: descriptor markers -- ) - Define a virtual type and its accessor words
///
/// Generates: >NAME (wrap), NAME> (unwrap), NAME? (predicate)
///
/// When inner-type is a type value, creates a simple virtual type wrapping that type.
/// When inner-type is a mutable map (struct descriptor from `struct{`), creates a
/// struct-backed virtual type with positional wrap and destructuring unwrap.
fn nativeDefineVirtual(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    const markers_array = switch (markers_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", markers_val);
            return error.TypeMismatch;
        },
    };

    var markers_list = std.ArrayListUnmanaged(*Marker){};
    for (markers_array) |m| {
        switch (m) {
            .marker => |mk| try markers_list.append(alloc, mk),
            else => {
                helpers.setTypeMismatchError(ctx, "marker", m);
                return error.TypeMismatch;
            },
        }
    }
    const markers_slice = try markers_list.toOwnedSlice(alloc);

    // Extract inner-type from descriptor map.
    // Clone the map so each virtual type gets its own descriptor,
    // since parse-time literals like M{ } are shared across invocations.
    const desc_val = try ctx.stack.pop();
    const src_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable_map", desc_val);
            return error.TypeMismatch;
        },
    };
    const desc_map = try alloc.create(MutableMap);
    desc_map.* = MutableMap{};
    var src_iter = src_map.iterator();
    while (src_iter.next()) |entry| {
        try desc_map.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    }
    const inner_type_raw = desc_map.get("inner-type") orelse return error.MissingField;
    const inner_type_val = switch (inner_type_raw) {
        .array => |arr| blk: {
            if (arr.len != 1) {
                helpers.setErrorContext(ctx, "virtual{{ expects exactly one inner type, got {d}", .{arr.len});
                return error.ParseError;
            }
            break :blk arr[0];
        },
        else => inner_type_raw,
    };

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    switch (inner_type_val) {
        .type_val => |inner_tv| {
            const inner_type = inner_tv.name;
            // Allocate singleton VirtualType shared by all instances
            const vtype = try alloc.create(VirtualType);
            vtype.* = .{
                .name = name,
                .inner_type = inner_type,
            };

            // Create a TypeValue for type-of lookups
            const tv = try alloc.create(value_mod.TypeValue);
            tv.* = .{ .name = name, .descriptor = null };
            vtype.type_val = tv;

            // NAME: ( -- type ) - the virtual type itself pushing a TypeValue
            const type_markers = try alloc.alloc(*Marker, 3);
            type_markers[0] = @constCast(&markers_mod.parse_time_marker);
            type_markers[1] = @constCast(&markers_mod.const_marker);
            type_markers[2] = @constCast(&markers_mod.typed_marker);

            const type_instrs = try alloc.alloc(Instruction, 1);
            type_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0 };

            try ctx.defineWord(name, .{
                .name = name,
                .parse_time = true,
                .stack_effect = try helpers.makeSimpleEffect(alloc, "-- type"),
                .markers = type_markers,
                .provenance = .{ .generator = "virtual", .parent = name, .role = "type" },
                .action = .{ .compound = type_instrs },
            });

            // >NAME / make-NAME: ( value -- tagged ) - wrap
            const wrap_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
            try defineWrap(ctx, wrap_name, vtype, markers_slice);

            const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{name});
            try defineWrap(ctx, make_name, vtype, markers_slice);

            // unmake-NAME: ( tagged -- value ) - unwrap
            const unmake_name = try std.fmt.allocPrint(alloc, "unmake-{s}", .{name});
            try defineUnwrap(ctx, unmake_name, vtype, markers_slice);

            // NAME?: ( value -- bool ) - predicate
            const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
            try definePredicate(ctx, pred_name, vtype, markers_slice);

            var generated_words = std.ArrayListUnmanaged(Value){};
            try generated_words.append(alloc, .{ .string = name });
            try generated_words.append(alloc, .{ .string = wrap_name });
            try generated_words.append(alloc, .{ .string = make_name });
            try generated_words.append(alloc, .{ .string = unmake_name });
            try generated_words.append(alloc, .{ .string = pred_name });
            const gw_slice = try generated_words.toOwnedSlice(alloc);
            try desc_map.put(alloc, "generated-words", .{ .array = gw_slice });
            const frozen_desc: *value_mod.HashTable = @ptrCast(desc_map);
            try ctx.type_descriptors.put(ctx.allocator, name, frozen_desc);
            vtype.type_val.?.descriptor = frozen_desc;
        },
        .mutable_map => |struct_desc| {
            const fields_val = struct_desc.get("fields") orelse return error.MissingField;
            const fields_array = switch (fields_val) {
                .array => |arr| arr,
                else => {
                    helpers.setErrorContext(ctx, "virtual{{ struct descriptor 'fields' must be an array, got {s}", .{helpers.valueTypeName(fields_val)});
                    return error.TypeMismatch;
                },
            };

            var fields_list = std.ArrayListUnmanaged([]const u8){};
            for (fields_array) |f| {
                const raw = switch (f) {
                    .string => |s| s,
                    .symbol => |s| s,
                    else => {
                        helpers.setErrorContext(ctx, "virtual{{ struct field name must be a string or symbol, got {s}", .{helpers.valueTypeName(f)});
                        return error.TypeMismatch;
                    },
                };
                const field_name = if (raw.len > 1 and raw[raw.len - 1] == ':')
                    raw[0 .. raw.len - 1]
                else
                    raw;
                try fields_list.append(alloc, field_name);
            }
            const fields_slice = try fields_list.toOwnedSlice(alloc);

            const anon_struct = try alloc.create(StructType);
            anon_struct.* = .{
                .name = name,
                .fields = fields_slice,
            };

            const vtype = try alloc.create(VirtualType);
            vtype.* = .{
                .name = name,
                .inner_type = name,
                .anon_struct = anon_struct,
            };

            // Create a TypeValue for type-of lookups
            const tv = try alloc.create(value_mod.TypeValue);
            tv.* = .{ .name = name, .descriptor = null };
            vtype.type_val = tv;

            // NAME: ( -- type ) - the virtual type itself pushing a TypeValue
            const type_markers = try alloc.alloc(*Marker, 3);
            type_markers[0] = @constCast(&markers_mod.parse_time_marker);
            type_markers[1] = @constCast(&markers_mod.const_marker);
            type_markers[2] = @constCast(&markers_mod.typed_marker);

            const type_instrs = try alloc.alloc(Instruction, 1);
            type_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0 };

            try ctx.defineWord(name, .{
                .name = name,
                .parse_time = true,
                .stack_effect = try helpers.makeSimpleEffect(alloc, "-- type"),
                .markers = type_markers,
                .provenance = .{ .generator = "virtual", .parent = name, .role = "type" },
                .action = .{ .compound = type_instrs },
            });

            // >NAME: ( hash -- tagged ) - hash-based wrap
            const wrap_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
            try defineStructHashWrap(ctx, wrap_name, vtype, markers_slice);

            // make-NAME: ( field1..fieldN -- tagged ) - positional wrap
            const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{name});
            try defineStructWrap(ctx, make_name, vtype, markers_slice);

            // unmake-NAME: ( tagged -- field1..fieldN ) - destructuring unwrap
            const unmake_name = try std.fmt.allocPrint(alloc, "unmake-{s}", .{name});
            try defineStructUnwrap(ctx, unmake_name, vtype, markers_slice);

            const to_hash_name = try std.fmt.allocPrint(alloc, "{s}>hash", .{name});
            try defineVirtualToHash(ctx, to_hash_name, vtype, markers_slice);

            const hash_instrs = try alloc.alloc(Instruction, 2);
            hash_instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
            hash_instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-to-hash" }, .line = 0 };
            try registerHashDispatch(ctx, name, hash_instrs);

            const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
            try definePredicate(ctx, pred_name, vtype, markers_slice);

            var generated_words = std.ArrayListUnmanaged(Value){};
            try generated_words.append(alloc, .{ .string = name });
            try generated_words.append(alloc, .{ .string = wrap_name });
            try generated_words.append(alloc, .{ .string = make_name });
            try generated_words.append(alloc, .{ .string = unmake_name });
            try generated_words.append(alloc, .{ .string = to_hash_name });
            try generated_words.append(alloc, .{ .string = pred_name });
            const gw_slice = try generated_words.toOwnedSlice(alloc);
            try desc_map.put(alloc, "generated-words", .{ .array = gw_slice });
            const frozen_desc: *value_mod.HashTable = @ptrCast(desc_map);
            try ctx.type_descriptors.put(ctx.allocator, name, frozen_desc);
            vtype.type_val.?.descriptor = frozen_desc;
        },
        else => {
            helpers.setErrorContext(ctx, "virtual{{ inner type must be a type value or struct descriptor, got {s}", .{helpers.valueTypeName(inner_type_val)});
            return error.TypeMismatch;
        },
    }
}

/// Trampoline helper ( value vtype-ptr -- tagged )
///
/// Given a value, wraps it as a tagged virtual type instance.
fn virtualWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();

    const actual_type: []const u8 = switch (val) {
        .struct_instance => |si| si.struct_type.name,
        .bignum => if (std.mem.eql(u8, vt.inner_type, "fixnum")) "fixnum" else "bignum",
        else => helpers.valueTypeName(val),
    };
    if (!std.mem.eql(u8, actual_type, vt.inner_type)) {
        helpers.setErrorContext(ctx, ">{s} expects {s}, got {s}", .{ vt.name, vt.inner_type, actual_type });
        return error.TypeMismatch;
    }

    const inner = try alloc.create(Value);
    inner.* = val;

    try ctx.stack.push(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Trampoline helper ( tagged vtype-ptr -- value )
///
/// Given a tagged virtual type instance, unwraps and validates its type.
fn virtualUnwrapHelper(ctx: *Context) anyerror!void {
    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            if (t.tag == vt) {
                try ctx.stack.push(t.inner.*);
            } else {
                helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, t.tag.name });
                return error.TypeMismatch;
            }
        },
        else => {
            helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    }
}

/// Trampoline helper ( value vtype-ptr -- ? )
///
/// Given a value, checks if it is a tagged instance of the given virtual type.
fn virtualTypePredicateHelper(ctx: *Context) anyerror!void {
    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();
    const is_match = switch (val) {
        .tagged => |t| t.tag == vt,
        else => false,
    };

    try ctx.stack.push(.{ .boolean = is_match });
}

fn vtypeProvenance(vtype: *const VirtualType, role: []const u8) WordProvenance {
    return .{
        .generator = if (vtype.parent_type != null) "enum" else "virtual",
        .parent = if (vtype.parent_type) |pt| pt.name else vtype.name,
        .role = role,
    };
}

/// >NAME: ( value -- tagged ) - wrap a value as this virtual type
pub fn defineWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-wrap" }, .line = 0 };

    const effect_str = try std.fmt.allocPrint(alloc, "value -- {s}", .{vtype.name});
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "wrap"),
        .action = .{ .compound = instrs },
    });
}

/// NAME>: ( tagged -- value ) - unwrap a tagged value, validating the type
pub fn defineUnwrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 0 };

    const effect_str = try std.fmt.allocPrint(alloc, "{s} -- value", .{vtype.name});
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "unwrap"),
        .action = .{ .compound = instrs },
    });
}

/// NAME?: ( value -- bool ) - type predicate for virtual type
pub fn definePredicate(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-type-predicate" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, "val -- ?"),
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "predicate"),
        .action = .{ .compound = instrs },
    });
}

/// Trampoline helper ( field1..fieldN vtype-ptr -- tagged )
fn virtualStructWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };
    const num_fields = st.fields.len;

    const field_values = try alloc.alloc(Value, num_fields);
    var i: usize = num_fields;
    while (i > 0) {
        i -= 1;
        field_values[i] = try ctx.stack.pop();
    }

    const instance = try alloc.create(StructInstance);
    instance.* = .{
        .struct_type = st,
        .fields = field_values,
    };

    const inner = try alloc.create(Value);
    inner.* = .{ .struct_instance = instance };

    try ctx.stack.push(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Trampoline helper ( tagged vtype-ptr -- field1..fieldN )
fn virtualStructUnwrapHelper(ctx: *Context) anyerror!void {
    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            if (t.tag != vt) {
                helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, t.tag.name });
                return error.TypeMismatch;
            }
            switch (t.inner.*) {
                .struct_instance => |si| {
                    for (si.fields) |field_val| {
                        try ctx.stack.push(field_val);
                    }
                },
                else => {
                    helpers.setErrorContext(ctx, "expected struct-backed {s}", .{vt.name});
                    return error.TypeMismatch;
                },
            }
        },
        else => {
            helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    }
}

/// Trampoline helper ( tagged vtype-ptr -- hash )
///
/// Validates the tag, unwraps to struct instance, converts fields to a hash.
fn virtualStructToHashHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };

    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            if (t.tag != vt) {
                helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, t.tag.name });
                return error.TypeMismatch;
            }
            switch (t.inner.*) {
                .struct_instance => |si| {
                    const hash = try alloc.create(value_mod.HashTable);
                    hash.* = .{};
                    for (st.fields, 0..) |field, i| {
                        try hash.put(alloc, field, si.fields[i]);
                    }
                    try ctx.stack.push(.{ .hash = hash });
                },
                else => {
                    helpers.setErrorContext(ctx, "expected struct-backed {s}", .{vt.name});
                    return error.TypeMismatch;
                },
            }
        },
        else => {
            helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    }
}

/// Trampoline helper ( hash vtype-ptr -- tagged )
///
/// Takes a hash and a VirtualType pointer, validates that the hash has every
/// field required by the anonymous struct (and no extras), reads field values
/// from the hash in field order, and constructs a tagged struct instance.
fn virtualStructHashWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };

    const val = try ctx.stack.pop();
    const hash = switch (val) {
        .hash => |h| h,
        else => {
            helpers.setErrorContext(ctx, ">{s} expects a hash, got {s}", .{ vt.name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    };

    if (hash.count() != st.fields.len) {
        helpers.setErrorContext(ctx, ">{s} expects {d} fields, got {d}", .{ vt.name, st.fields.len, hash.count() });
        return error.TypeMismatch;
    }

    const field_values = try alloc.alloc(Value, st.fields.len);
    for (st.fields, 0..) |field, i| {
        field_values[i] = hash.get(field) orelse {
            helpers.setErrorContext(ctx, ">{s} missing field '{s}'", .{ vt.name, field });
            return error.MissingField;
        };
    }

    const instance = try alloc.create(StructInstance);
    instance.* = .{
        .struct_type = st,
        .fields = field_values,
    };

    const inner = try alloc.create(Value);
    inner.* = .{ .struct_instance = instance };

    try ctx.stack.push(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// >NAME: ( hash -- tagged ) - hash-based wrap for struct-backed virtuals
pub fn defineStructHashWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-hash-wrap" }, .line = 0 };

    const effect_str = try std.fmt.allocPrint(alloc, "hash -- {s}", .{vtype.name});
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "hash-wrap"),
        .action = .{ .compound = instrs },
    });
}

/// >NAME: ( field1..fieldN -- tagged ) - struct-aware positional wrap
pub fn defineStructWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-wrap" }, .line = 0 };

    const fields = if (vtype.anon_struct) |st| st.fields else &[_][]const u8{};
    const effect_str = try helpers.buildConstructorEffectStr(alloc, fields, vtype.name);
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "constructor"),
        .action = .{ .compound = instrs },
    });
}

/// NAME>: ( tagged -- field1..fieldN ) - struct-aware destructuring unwrap
pub fn defineStructUnwrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-unwrap" }, .line = 0 };

    const fields = if (vtype.anon_struct) |st| st.fields else &[_][]const u8{};
    const effect_str = try helpers.buildDestructorEffectStr(alloc, fields, vtype.name);
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "unwrap"),
        .action = .{ .compound = instrs },
    });
}

/// NAME>hash: ( tagged -- hash ) - convert struct-backed virtual to hash
pub fn defineVirtualToHash(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-to-hash" }, .line = 0 };

    const effect_str = try std.fmt.allocPrint(alloc, "{s} -- hash", .{vtype.name});
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "to-hash"),
        .action = .{ .compound = instrs },
    });
}

/// Attempt numeric tower promotion of a single element to the expected type.
/// Returns the promoted value, or null if promotion is not possible.
fn tryPromoteElement(alloc: Allocator, elem: Value, expected: []const u8) ?Value {
    if (std.mem.eql(u8, expected, "float")) {
        return switch (elem) {
            .fixnum => |i| .{ .float = @floatFromInt(i) },
            .bignum => |b| .{ .float = blk: {
                const str = b.toConst().toStringAlloc(alloc, 10, .lower) catch break :blk std.math.nan(f64);
                break :blk std.fmt.parseFloat(f64, str) catch std.math.nan(f64);
            } },
            else => null,
        };
    }
    if (std.mem.eql(u8, expected, "bignum")) {
        return switch (elem) {
            .fixnum => |i| .{ .bignum = BigIntManaged.initSet(alloc, i) catch return null },
            else => null,
        };
    }
    return null;
}

/// Validate a single value against a parameterized type's element type,
/// with numeric tower promotion. ( value vtype-ptr -- promoted-value )
fn typedValidateAndPromote(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();

    const params = vt.type_params orelse {
        try ctx.stack.push(val);
        return;
    };
    if (params.len == 0) {
        try ctx.stack.push(val);
        return;
    }

    const expected = params[0].name;
    const actual = dispatch_mod.dispatchTypeName(val);
    if (std.mem.eql(u8, actual, expected)) {
        try ctx.stack.push(val);
        return;
    }

    if (tryPromoteElement(alloc, val, expected)) |promoted| {
        try ctx.stack.push(promoted);
        return;
    }

    helpers.setErrorContext(ctx, "{s} element has type {s}, expected {s}", .{ vt.name, actual, expected });
    return error.TypeMismatch;
}

/// Validate all elements of a sequence against a parameterized type's
/// element type, with numeric tower promotion. ( seq vtype-ptr -- seq )
fn typedValidateSeqElements(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const seq = try ctx.stack.pop();

    const params = vt.type_params orelse {
        try ctx.stack.push(seq);
        return;
    };
    if (params.len == 0) {
        try ctx.stack.push(seq);
        return;
    }

    const expected = params[0].name;
    const items: []const Value = switch (seq) {
        .array => |arr| arr,
        .vector => |v| v.items,
        else => {
            try ctx.stack.push(seq);
            return;
        },
    };

    var promoted_items: ?std.ArrayListUnmanaged(Value) = null;
    for (items, 0..) |elem, i| {
        const actual = dispatch_mod.dispatchTypeName(elem);
        if (!std.mem.eql(u8, actual, expected)) {
            if (tryPromoteElement(alloc, elem, expected)) |promoted| {
                if (promoted_items == null) {
                    promoted_items = std.ArrayListUnmanaged(Value){};
                    promoted_items.?.ensureTotalCapacity(alloc, items.len) catch return error.OutOfMemory;
                    promoted_items.?.appendSlice(alloc, items[0..i]) catch return error.OutOfMemory;
                }
                promoted_items.?.append(alloc, promoted) catch return error.OutOfMemory;
            } else {
                helpers.setErrorContext(ctx, "{s} element at index {d} has type {s}, expected {s}", .{ vt.name, i, actual, expected });
                return error.TypeMismatch;
            }
        } else if (promoted_items) |*pi| {
            pi.append(alloc, elem) catch return error.OutOfMemory;
        }
    }

    if (promoted_items) |pi| {
        switch (seq) {
            .array => try ctx.stack.push(.{ .array = pi.items }),
            .vector => |v| {
                v.items = pi.items;
                try ctx.stack.push(.{ .vector = v });
            },
            else => try ctx.stack.push(seq),
        }
    } else {
        try ctx.stack.push(seq);
    }
}

/// Native dispatch helper for #nth! on typed vectors.
/// Stack: typed-vec n elem vtype-ptr -- typed-vec
///
/// Validates and promotes elem, unwraps the typed vector, delegates to
/// the raw #nth!, then rewraps.
fn typedNthMutDispatch(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    var elem = try ctx.stack.pop();
    const n = try ctx.stack.pop();
    const typed_vec = try ctx.stack.pop();

    // Validate and promote element
    if (vt.type_params) |params| {
        if (params.len > 0) {
            const expected = params[0].name;
            const actual = dispatch_mod.dispatchTypeName(elem);
            if (!std.mem.eql(u8, actual, expected)) {
                if (tryPromoteElement(alloc, elem, expected)) |promoted| {
                    elem = promoted;
                } else {
                    helpers.setErrorContext(ctx, "{s} element has type {s}, expected {s}", .{ vt.name, actual, expected });
                    return error.TypeMismatch;
                }
            }
        }
    }

    // Unwrap tagged vec to raw vec, push raw-vec n elem for #nth!
    try ctx.stack.push(typed_vec.tagged.inner.*);
    try ctx.stack.push(n);
    try ctx.stack.push(elem);

    // Delegate to the raw #nth!
    const nth_mut_word = ctx.lookupWord("#nth!") orelse return error.WordNotFound;
    switch (nth_mut_word.action) {
        .native => |func| try func(ctx),
        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
    }

    // Rewrap: pop raw vec, wrap as tagged, push
    const result_vec = try ctx.stack.pop();
    const inner = try alloc.create(Value);
    inner.* = result_vec;
    try ctx.stack.push(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Trampoline helper ( value vtype-ptr -- tagged )
///
/// Like virtualWrapHelper but additionally validates that array elements
/// match the parameterized type's type_params[0].
fn virtualParameterizedWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    var val = try ctx.stack.pop();

    const actual_type: []const u8 = switch (val) {
        .struct_instance => |si| si.struct_type.name,
        .bignum => if (std.mem.eql(u8, vt.inner_type, "fixnum")) "fixnum" else "bignum",
        else => helpers.valueTypeName(val),
    };
    if (!std.mem.eql(u8, actual_type, vt.inner_type)) {
        helpers.setErrorContext(ctx, ">{s} expects {s}, got {s}", .{ vt.name, vt.inner_type, actual_type });
        return error.TypeMismatch;
    }

    if (vt.type_params) |params| {
        if (params.len > 0) {
            const expected_elem_type = params[0].name;
            switch (val) {
                .array => |arr| {
                    var promoted_arr: ?[]Value = null;
                    for (arr, 0..) |elem, i| {
                        const elem_type = dispatch_mod.dispatchTypeName(elem);
                        if (!std.mem.eql(u8, elem_type, expected_elem_type)) {
                            if (tryPromoteElement(alloc, elem, expected_elem_type)) |promoted| {
                                if (promoted_arr == null) {
                                    promoted_arr = try alloc.alloc(Value, arr.len);
                                    @memcpy(promoted_arr.?[0..i], arr[0..i]);
                                }
                                promoted_arr.?[i] = promoted;
                            } else {
                                helpers.setErrorContext(ctx, ">{s} element at index {d} has type {s}, expected {s}", .{ vt.name, i, elem_type, expected_elem_type });
                                return error.TypeMismatch;
                            }
                        } else if (promoted_arr) |pa| {
                            pa[i] = elem;
                        }
                    }
                    if (promoted_arr) |pa| {
                        val = .{ .array = pa };
                    }
                },
                else => {},
            }
        }
    }

    const inner = try alloc.create(Value);
    inner.* = val;

    try ctx.stack.push(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// >NAME: ( value -- tagged ) - validating wrap for parameterized types
pub fn defineParameterizedWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-parameterized-wrap" }, .line = 0 };

    const effect_str = try std.fmt.allocPrint(alloc, "value -- {s}", .{vtype.name});
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "wrap"),
        .action = .{ .compound = instrs },
    });
}

/// define-parameterized-type ( name: base-type element-type -- )
///
/// Defines a parameterized virtual type. The >name word validates that all
/// elements of the inner value match the element type. The make-name word
/// skips element validation.
fn nativeDefineParameterizedType(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const elem_type_val = try ctx.stack.pop();
    const elem_tv = switch (elem_type_val) {
        .type_val => |tv| tv,
        else => {
            helpers.setTypeMismatchError(ctx, "type", elem_type_val);
            return error.TypeMismatch;
        },
    };

    const base_type_val = try ctx.stack.pop();
    const base_tv = switch (base_type_val) {
        .type_val => |tv| tv,
        else => {
            helpers.setTypeMismatchError(ctx, "type", base_type_val);
            return error.TypeMismatch;
        },
    };

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    const type_params = try alloc.alloc(*const value_mod.TypeValue, 1);
    type_params[0] = elem_tv;

    const vtype = try alloc.create(VirtualType);
    vtype.* = .{
        .name = name,
        .inner_type = base_tv.name,
        .base_type = base_tv,
        .type_params = type_params,
    };

    const tv = try alloc.create(value_mod.TypeValue);
    tv.* = .{ .name = name, .descriptor = null };
    vtype.type_val = tv;

    // NAME: ( -- type ) - parse-time const pushing TypeValue
    const type_markers = try alloc.alloc(*Marker, 3);
    type_markers[0] = @constCast(&markers_mod.parse_time_marker);
    type_markers[1] = @constCast(&markers_mod.const_marker);
    type_markers[2] = @constCast(&markers_mod.typed_marker);

    const type_instrs = try alloc.alloc(Instruction, 1);
    type_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .parse_time = true,
        .stack_effect = try helpers.makeSimpleEffect(alloc, "-- type"),
        .markers = type_markers,
        .provenance = .{ .generator = "virtual", .parent = name, .role = "type" },
        .action = .{ .compound = type_instrs },
    });

    // >NAME: ( value -- tagged ) - validating wrap with element checking
    const wrap_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
    try defineParameterizedWrap(ctx, wrap_name, vtype, &.{});

    // make-NAME: ( value -- tagged ) - raw wrap, no element validation
    const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{name});
    try defineWrap(ctx, make_name, vtype, &.{});

    // unmake-NAME: ( tagged -- value ) - unwrap
    const unmake_name = try std.fmt.allocPrint(alloc, "unmake-{s}", .{name});
    try defineUnwrap(ctx, unmake_name, vtype, &.{});

    // NAME?: ( value -- bool ) - predicate
    const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
    try definePredicate(ctx, pred_name, vtype, &.{});

    // Register type descriptor
    const desc_map = try alloc.create(MutableMap);
    desc_map.* = MutableMap{};
    try desc_map.put(alloc, "inner-type", .{ .type_val = base_tv });
    try desc_map.put(alloc, "element-type", .{ .type_val = elem_tv });

    var generated_words = std.ArrayListUnmanaged(Value){};
    try generated_words.append(alloc, .{ .string = name });
    try generated_words.append(alloc, .{ .string = wrap_name });
    try generated_words.append(alloc, .{ .string = make_name });
    try generated_words.append(alloc, .{ .string = unmake_name });
    try generated_words.append(alloc, .{ .string = pred_name });

    // Register vector mutation dispatch entries when base type is vector
    if (std.mem.eql(u8, base_tv.name, "vector")) {
        try registerVectorMutationDispatches(ctx, alloc, name, vtype, &generated_words);
    }

    const gw_slice = try generated_words.toOwnedSlice(alloc);
    try desc_map.put(alloc, "generated-words", .{ .array = gw_slice });

    const frozen_desc: *value_mod.HashTable = @ptrCast(desc_map);
    try ctx.type_descriptors.put(ctx.allocator, name, frozen_desc);
    vtype.type_val.?.descriptor = frozen_desc;
}

/// Register dispatch entries for vector mutation ops on a parameterized vector type.
/// Each entry validates/promotes elements before delegating to the base vector op.
fn registerVectorMutationDispatches(
    ctx: *Context,
    alloc: Allocator,
    type_name: []const u8,
    vtype: *const VirtualType,
    generated_words: *std.ArrayListUnmanaged(Value),
) !void {
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(vtype)) };

    // Element-adding ops: #push!, #unshift!
    // Stack: typed-vec elem
    // Body: validate+promote elem, swap, unwrap vec, swap, base-op, rewrap
    const adding_ops = [_][]const u8{ "#push!", "#unshift!" };
    for (adding_ops) |op_name| {
        const instrs = try alloc.alloc(Instruction, 9);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 0 };
        instrs[2] = .{ .op = .{ .call_word = "swap" }, .line = 0 };
        instrs[3] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[4] = .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 0 };
        instrs[5] = .{ .op = .{ .call_word = "swap" }, .line = 0 };
        instrs[6] = .{ .op = .{ .call_word = op_name }, .line = 0 };
        instrs[7] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[8] = .{ .op = .{ .call_word = "native.virtual-wrap" }, .line = 0 };

        try ctx.dispatch.register(.{
            .word_name = op_name,
            .type_a = type_name,
            .type_b = dispatch_mod.unary_sentinel,
        }, .{ .body = .{ .quotation = instrs } }, true);

        try generated_words.append(alloc, .{ .string = op_name });
    }

    // Element-removing ops: #pop!, #shift!
    // Stack: typed-vec
    // Body: unwrap vec, base-op (leaves vec elem), swap, rewrap, swap
    const removing_ops = [_][]const u8{ "#pop!", "#shift!" };
    for (removing_ops) |op_name| {
        const instrs = try alloc.alloc(Instruction, 7);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 0 };
        instrs[2] = .{ .op = .{ .call_word = op_name }, .line = 0 };
        instrs[3] = .{ .op = .{ .call_word = "swap" }, .line = 0 };
        instrs[4] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[5] = .{ .op = .{ .call_word = "native.virtual-wrap" }, .line = 0 };
        instrs[6] = .{ .op = .{ .call_word = "swap" }, .line = 0 };

        try ctx.dispatch.register(.{
            .word_name = op_name,
            .type_a = type_name,
            .type_b = dispatch_mod.unary_sentinel,
        }, .{ .body = .{ .quotation = instrs } }, true);

        try generated_words.append(alloc, .{ .string = op_name });
    }

    // #nth! -- Stack: typed-vec n elem
    // Body: push vtype-ptr, call native helper that handles the full
    // validate+unwrap+delegate+rewrap sequence
    {
        const instrs = try alloc.alloc(Instruction, 2);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-nth-mut-dispatch" }, .line = 0 };

        try ctx.dispatch.register(.{
            .word_name = "#nth!",
            .type_a = type_name,
            .type_b = dispatch_mod.unary_sentinel,
        }, .{ .body = .{ .quotation = instrs } }, true);

        try generated_words.append(alloc, .{ .string = "#nth!" });
    }

    // #append! -- Stack: typed-vec seq
    // Body: validate seq elements, swap, unwrap, swap, base-op, rewrap
    {
        const instrs = try alloc.alloc(Instruction, 9);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-validate-seq-elements" }, .line = 0 };
        instrs[2] = .{ .op = .{ .call_word = "swap" }, .line = 0 };
        instrs[3] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[4] = .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 0 };
        instrs[5] = .{ .op = .{ .call_word = "swap" }, .line = 0 };
        instrs[6] = .{ .op = .{ .call_word = "#append!" }, .line = 0 };
        instrs[7] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[8] = .{ .op = .{ .call_word = "native.virtual-wrap" }, .line = 0 };

        try ctx.dispatch.register(.{
            .word_name = "#append!",
            .type_a = type_name,
            .type_b = dispatch_mod.unary_sentinel,
        }, .{ .body = .{ .quotation = instrs } }, true);

        try generated_words.append(alloc, .{ .string = "#append!" });
    }
}

/// Register a >hash dispatch entry for a type name, creating the generic `>hash` word if it doesn't exist yet.
pub fn registerHashDispatch(ctx: *Context, type_name: []const u8, instrs: []const Instruction) !void {
    const alloc = ctx.quotationAllocator();

    const is_generic = if (ctx.lookupWord(">hash")) |existing| blk: {
        for (existing.markers) |mk| {
            if (markers_mod.isGenericMarker(mk)) break :blk true;
        }
        break :blk false;
    } else false;

    if (!is_generic) {
        const generic_markers = try alloc.alloc(*Marker, 1);
        generic_markers[0] = @constCast(&markers_mod.generic_marker);

        try ctx.defineWord(">hash", .{
            .name = ">hash",
            .stack_effect = try helpers.makeSimpleEffect(alloc, "val -- hash"),
            .markers = generic_markers,
            .action = .{ .compound = &.{} },
        });
    }

    try ctx.dispatch.register(.{
        .word_name = ">hash",
        .type_a = type_name,
        .type_b = dispatch_mod.unary_sentinel,
    }, .{ .body = .{ .quotation = instrs } }, true);
}
