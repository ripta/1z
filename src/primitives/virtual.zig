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
const struct_field_spec = @import("struct_field_spec.zig");
const dispatch_mod = @import("../dispatch.zig");
const container_backing = @import("../container_backing.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const dictionary_mod = @import("../dictionary.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const WordDefinition = dictionary_mod.WordDefinition;

pub const primitives = [_]Primitive{
    .{ .name = "define-virtual", .stack_effect = "name: descriptor markers --", .doc = "Define a virtual type and its accessor words.", .func = nativeDefineVirtual },
    .{ .name = "define-parameterized-type", .stack_effect = "name: descriptor markers --", .doc = "Define a parameterized virtual type from a descriptor map carrying inner-type, element-type, and define fields.", .func = nativeDefineParameterizedType },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "virtual-wrap", .func = virtualWrapHelper, .stack_effect = "value tv -- tagged" },
    .{ .name = "virtual-unwrap", .func = virtualUnwrapHelper, .stack_effect = "tagged tv -- value" },
    .{ .name = "virtual-type-predicate", .func = virtualTypePredicateHelper, .stack_effect = "value tv -- ?" },
    .{ .name = "virtual-struct-wrap", .func = virtualStructWrapHelper, .polymorphic = true },
    .{ .name = "virtual-struct-unwrap", .func = virtualStructUnwrapHelper, .polymorphic = true },
    .{ .name = "virtual-struct-to-hash", .func = virtualStructToHashHelper, .stack_effect = "tagged tv -- hash" },
    .{ .name = "virtual-struct-hash-wrap", .func = virtualStructHashWrapHelper, .stack_effect = "hash tv -- tagged" },
    .{ .name = "virtual-parameterized-wrap", .func = virtualParameterizedWrapHelper, .stack_effect = "value tv -- tagged" },
    .{ .name = "typed-validate-and-promote", .func = typedValidateAndPromote, .stack_effect = "value tv -- promoted-value" },
    .{ .name = "typed-validate-seq-elements", .func = typedValidateSeqElements, .stack_effect = "seq tv -- seq" },
    .{ .name = "typed-nth-mut-dispatch", .func = typedNthMutDispatch, .stack_effect = "typed-vec n elem tv -- typed-vec" },
    .{ .name = "typed-at-set-mut-dispatch", .func = typedAtSetMutDispatch, .stack_effect = "typed-mmap key value tv -- typed-mmap" },
    .{ .name = "typed-at-remove-mut-dispatch", .func = typedAtRemoveMutDispatch, .stack_effect = "typed-mmap key tv -- typed-mmap" },
    .{ .name = "typed-freeze-dispatch", .func = typedFreezeDispatch, .stack_effect = "typed-vec tv -- typed-array" },
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
    defer container_backing.releaseValue(desc_val);
    const src_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable_map", desc_val);
            return error.TypeMismatch;
        },
    };
    const descriptor_flags = value_mod.DescriptorFlags{
        .numeric = if (src_map.map.get("numeric")) |v| switch (v) {
            .boolean => |b| b,
            else => true,
        } else false,
        .exact = if (src_map.map.get("exact")) |v| switch (v) {
            .boolean => |b| b,
            else => true,
        } else false,
        .integer = if (src_map.map.get("integer")) |v| switch (v) {
            .boolean => |b| b,
            else => true,
        } else false,
        .mutable = if (src_map.map.get("mutable")) |v| switch (v) {
            .boolean => |b| b,
            else => true,
        } else false,
    };
    // Allocate the descriptor with an empty virtual payload now; the
    // type_val branch below populates `inner_type` and the struct-
    // backed branch populates `anon_struct`.
    const desc_map = try value_mod.createTypeDescriptor(
        alloc,
        .{ .virtual = .{} },
        descriptor_flags,
    );
    const inner_type_raw = src_map.map.get("inner-type") orelse return error.MissingField;
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
            ctx.virtual_type_count += 1;

            desc_map.kind = .{ .virtual = .{ .inner_type = inner_tv } };

            // Create a TypeValue for type-of lookups
            const tv = try alloc.create(value_mod.TypeValue);
            tv.* = .{ .name = name, .descriptor = desc_map };
            vtype.type_val = tv;
            tv.virtual_type = vtype;

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
            tv.generated_words = gw_slice;
            try ctx.registerTypeDescriptor(name, desc_map);
        },
        .mutable_map => |struct_desc| {
            const fields_val = struct_desc.map.get("fields") orelse return error.MissingField;
            const fields_array = switch (fields_val) {
                .array => |arr| arr,
                else => {
                    helpers.setErrorContext(ctx, "virtual{{ struct descriptor 'fields' must be an array, got {s}", .{helpers.valueTypeName(fields_val)});
                    return error.TypeMismatch;
                },
            };
            const parsed_fields = try struct_field_spec.parse(alloc, ctx, fields_array, "virtual{");
            const fields_slice = parsed_fields.names;
            const field_types_slice = parsed_fields.types;
            const inner_mutable = if (struct_desc.map.get("mutable")) |v| switch (v) {
                .boolean => |b| b,
                else => false,
            } else false;
            // Intern the struct descriptor so downstream readers can
            // reach it via `desc.kind.virtual.anon_struct`'s type_val.
            _ = try ctx.getOrCreateStructDescriptor(fields_slice, field_types_slice, inner_mutable);

            const anon_struct = try alloc.create(StructType);
            anon_struct.* = .{
                .name = name,
                .fields = fields_slice,
                .field_types = field_types_slice,
            };
            ctx.struct_type_count += 1;

            const vtype = try alloc.create(VirtualType);
            vtype.* = .{
                .name = name,
                .inner_type = name,
                .anon_struct = anon_struct,
            };
            ctx.virtual_type_count += 1;

            desc_map.kind = .{ .virtual = .{ .anon_struct = anon_struct } };

            // Create a TypeValue for type-of lookups
            const tv = try alloc.create(value_mod.TypeValue);
            tv.* = .{ .name = name, .descriptor = desc_map };
            vtype.type_val = tv;
            tv.virtual_type = vtype;

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
            hash_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
            hash_instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-to-hash" }, .line = 0 };
            try registerHashDispatch(ctx, vtype.type_val.?, hash_instrs);

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
            tv.generated_words = gw_slice;
            try ctx.registerTypeDescriptor(name, desc_map);
        },
        else => {
            helpers.setErrorContext(ctx, "virtual{{ inner type must be a type value or struct descriptor, got {s}", .{helpers.valueTypeName(inner_type_val)});
            return error.TypeMismatch;
        },
    }
}

/// Trampoline helper ( value tv -- tagged )
///
/// Given a value, wraps it as a tagged virtual type instance.
fn virtualWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

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

    // `val` was popped (ownership transferred); wrapping it in the tagged
    // makes the tagged its owner. pushMoved transfers that baseline to the
    // slot without an extra retain.
    try ctx.stack.pushMoved(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Trampoline helper ( tagged tv -- value )
///
/// Given a tagged virtual type instance, unwraps and validates its type.
fn virtualUnwrapHelper(ctx: *Context) anyerror!void {
    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            if (t.tag == vt) {
                // The consumed wrapper owns its inner value; unwrapping
                // transfers that ownership to the new stack slot, so move
                // the inner out rather than taking a second reference.
                try ctx.stack.pushMoved(t.inner.*);
            } else {
                container_backing.releaseValue(val);
                helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, t.tag.name });
                return error.TypeMismatch;
            }
        },
        else => {
            container_backing.releaseValue(val);
            helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    }
}

/// Trampoline helper ( value tv -- ? )
///
/// Given a value, checks if it is a tagged instance of the given virtual type.
fn virtualTypePredicateHelper(ctx: *Context) anyerror!void {
    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
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

/// >NAME: ( value -- tagged ) - wrap a value as this virtual type (generic, extensible via method{)
pub fn defineWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-wrap" }, .line = 0 };

    const generic_markers = try alloc.alloc(*Marker, markers.len + 1);
    for (markers, 0..) |mk, i| generic_markers[i] = mk;
    generic_markers[markers.len] = @constCast(&markers_mod.generic_marker);

    const effect_str = try std.fmt.allocPrint(alloc, "value -- {s}", .{vtype.name});
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = generic_markers,
        .provenance = vtypeProvenance(vtype, "wrap"),
        .action = .{ .compound = instrs },
    });

    if (ctx.lookupTypeValueByName(vtype.inner_type)) |inner_tv| {
        if (inner_tv.descriptor) |desc| {
            try ctx.registerDispatch(.{
                .dispatch_id = ctx.lookupWord(name).?.dispatch_id,
                .type_a = desc,
                .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
            }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, false);
        }
    }
}

/// NAME>: ( tagged -- value ) - unwrap a tagged value, validating the type
pub fn defineUnwrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
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
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-type-predicate" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, "val -- ?"),
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "predicate"),
        .action = .{ .compound = instrs },
    });
}

/// Trampoline helper ( field1..fieldN tv -- tagged )
fn virtualStructWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

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

    // Fields were popped (ownership transferred); the tagged value inherits
    // that ownership, so move it onto the stack without an extra retain.
    try ctx.stack.pushMoved(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Trampoline helper ( tagged tv -- field1..fieldN )
fn virtualStructUnwrapHelper(ctx: *Context) anyerror!void {
    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const val = try ctx.stack.pop();
    // The popped tagged value is consumed; release it on every path. The
    // pushed fields take their own owning reference via push.
    defer container_backing.releaseValue(val);
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

/// Trampoline helper ( tagged tv -- hash )
///
/// Validates the tag, unwraps to struct instance, converts fields to a hash.
fn virtualStructToHashHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };

    const val = try ctx.stack.pop();
    // The popped tagged value is consumed; release it on every path. Pushing
    // the resulting hash retains every field value it stores.
    defer container_backing.releaseValue(val);
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

/// Trampoline helper ( hash tv -- tagged )
///
/// Takes a hash and a TypeValue for a virtual type, validates that the hash
/// has every field required by the anonymous struct (and no extras), reads
/// field values from the hash in field order, and constructs a tagged struct
/// instance.
fn virtualStructHashWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };

    const val = try ctx.stack.pop();
    // The popped hash is consumed by this word; release it on every path.
    defer container_backing.releaseValue(val);
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

    // Fields are borrowed from the source hash; retain each so the tagged
    // instance becomes an independent owner before the hash is released above.
    container_backing.retainValues(field_values);

    const instance = try alloc.create(StructInstance);
    instance.* = .{
        .struct_type = st,
        .fields = field_values,
    };

    const inner = try alloc.create(Value);
    inner.* = .{ .struct_instance = instance };

    try ctx.stack.pushMoved(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// >NAME: ( hash -- tagged ) - hash-based wrap for struct-backed virtuals
pub fn defineStructHashWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-hash-wrap" }, .line = 0 };

    const generic_markers = try alloc.alloc(*Marker, markers.len + 1);
    for (markers, 0..) |mk, i| generic_markers[i] = mk;
    generic_markers[markers.len] = @constCast(&markers_mod.generic_marker);

    const effect_str = try std.fmt.allocPrint(alloc, "hash -- {s}", .{vtype.name});
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = generic_markers,
        .provenance = vtypeProvenance(vtype, "hash-wrap"),
        .action = .{ .compound = instrs },
    });

    const hash_tv = ctx.lookupBuiltinTypeValue("hash") orelse return;
    try ctx.registerDispatch(.{
        .dispatch_id = ctx.lookupWord(name).?.dispatch_id,
        .type_a = hash_tv.descriptor.?,
        .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
    }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);
}

/// >NAME: ( field1..fieldN -- tagged ) - struct-aware positional wrap
pub fn defineStructWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
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
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
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
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
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
            .fixnum => |i| blk: {
                const big = BigIntManaged.initSet(alloc, i) catch return null;
                const ptr = value_mod.boxBigInt(alloc, big) catch return null;
                break :blk .{ .bignum = ptr };
            },
            else => null,
        };
    }
    return null;
}

/// Validate a single value against a parameterized type's element type,
/// with numeric tower promotion. ( value tv -- promoted-value )
fn typedValidateAndPromote(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const val = try ctx.stack.pop();

    // Each branch re-stores the popped value (or a freshly promoted
    // replacement) into the slot it came from, so transfer ownership via
    // pushMoved rather than taking a second owning reference.
    const params = vt.type_params orelse {
        try ctx.stack.pushMoved(val);
        return;
    };
    if (params.len == 0) {
        try ctx.stack.pushMoved(val);
        return;
    }

    const expected_tv = params[0];
    const actual_tv = dispatch_mod.dispatchTypeValue(val, ctx);
    if (actual_tv == expected_tv) {
        try ctx.stack.pushMoved(val);
        return;
    }

    if (tryPromoteElement(alloc, val, expected_tv.name)) |promoted| {
        container_backing.releaseValue(val);
        try ctx.stack.pushMoved(promoted);
        return;
    }

    container_backing.releaseValue(val);
    helpers.setErrorContext(ctx, "{s} element has type {s}, expected {s}", .{ vt.name, actual_tv.name, expected_tv.name });
    return error.TypeMismatch;
}

/// Validate all elements of a sequence against a parameterized type's
/// element type, with numeric tower promotion. ( seq tv -- seq )
fn typedValidateSeqElements(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const seq = try ctx.stack.pop();

    // Like typedValidateAndPromote, every branch re-stores the popped
    // sequence (or an in-place-promoted version of it) into its slot, so
    // transfer ownership via pushMoved instead of retaining again.
    const params = vt.type_params orelse {
        try ctx.stack.pushMoved(seq);
        return;
    };
    if (params.len == 0) {
        try ctx.stack.pushMoved(seq);
        return;
    }

    const expected_tv = params[0];
    const items: []const Value = switch (seq) {
        .array => |arr| arr,
        .vector => |v| v.list.items,
        else => {
            try ctx.stack.pushMoved(seq);
            return;
        },
    };

    var promoted_items: ?std.ArrayListUnmanaged(Value) = null;
    for (items, 0..) |elem, i| {
        const actual_tv = dispatch_mod.dispatchTypeValue(elem, ctx);
        if (actual_tv != expected_tv) {
            if (tryPromoteElement(alloc, elem, expected_tv.name)) |promoted| {
                if (promoted_items == null) {
                    promoted_items = std.ArrayListUnmanaged(Value){};
                    promoted_items.?.ensureTotalCapacity(alloc, items.len) catch return error.OutOfMemory;
                    promoted_items.?.appendSlice(alloc, items[0..i]) catch return error.OutOfMemory;
                }
                promoted_items.?.append(alloc, promoted) catch return error.OutOfMemory;
            } else {
                helpers.setErrorContext(ctx, "{s} element at index {d} has type {s}, expected {s}", .{ vt.name, i, actual_tv.name, expected_tv.name });
                return error.TypeMismatch;
            }
        } else if (promoted_items) |*pi| {
            pi.append(alloc, elem) catch return error.OutOfMemory;
        }
    }

    if (promoted_items) |pi| {
        switch (seq) {
            .array => try ctx.stack.pushMoved(.{ .array = pi.items }),
            .vector => |v| {
                v.list.items = pi.items;
                v.list.capacity = pi.capacity;
                try ctx.stack.pushMoved(.{ .vector = v });
            },
            else => try ctx.stack.pushMoved(seq),
        }
    } else {
        try ctx.stack.pushMoved(seq);
    }
}

/// Native dispatch helper for #nth! on typed vectors.
/// Stack: typed-vec n elem tv -- typed-vec
///
/// Validates and promotes elem, unwraps the typed vector, delegates to
/// the raw #nth!, then rewraps.
fn typedNthMutDispatch(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    var elem = try ctx.stack.pop();
    const n = try ctx.stack.pop();
    const typed_vec = try ctx.stack.pop();
    // The consumed typed vector still owns its inner backing. The rewrap
    // below reuses the same mutated backing and takes a fresh owning
    // reference, so release this slot's reference when the helper returns.
    defer container_backing.releaseValue(typed_vec);

    // Validate and promote element
    if (vt.type_params) |params| {
        if (params.len > 0) {
            const expected_tv = params[0];
            const actual_tv = dispatch_mod.dispatchTypeValue(elem, ctx);
            if (actual_tv != expected_tv) {
                if (tryPromoteElement(alloc, elem, expected_tv.name)) |promoted| {
                    elem = promoted;
                } else {
                    helpers.setErrorContext(ctx, "{s} element has type {s}, expected {s}", .{ vt.name, actual_tv.name, expected_tv.name });
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
        .native, .host_callback => try nth_mut_word.invoke(ctx),
        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
    }

    // Rewrap: pop raw vec, wrap as tagged, push
    const result_vec = try ctx.stack.pop();
    const inner = try alloc.create(Value);
    inner.* = result_vec;
    try ctx.stack.pushMoved(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Native dispatch helper for @set! on typed mutable maps.
/// Validates+promotes the value, unwraps the typed mmap, delegates to base @set!, rewraps.
fn typedAtSetMutDispatch(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    var new_value = try ctx.stack.pop();
    const key = try ctx.stack.pop();
    const typed_mmap = try ctx.stack.pop();
    // The rewrap reuses the same mutated backing and takes a fresh owning
    // reference, so release this consumed slot's reference on return.
    defer container_backing.releaseValue(typed_mmap);

    // Validate and promote value
    if (vt.type_params) |params| {
        if (params.len > 0) {
            const expected_tv = params[0];
            const actual_tv = dispatch_mod.dispatchTypeValue(new_value, ctx);
            if (actual_tv != expected_tv) {
                if (tryPromoteElement(alloc, new_value, expected_tv.name)) |promoted| {
                    new_value = promoted;
                } else {
                    helpers.setErrorContext(ctx, "{s} element has type {s}, expected {s}", .{ vt.name, actual_tv.name, expected_tv.name });
                    return error.TypeMismatch;
                }
            }
        }
    }

    // Unwrap typed mmap to raw mmap, push raw-mmap key value for @set!
    try ctx.stack.push(typed_mmap.tagged.inner.*);
    try ctx.stack.push(key);
    try ctx.stack.push(new_value);

    // Delegate to the raw @set!
    const at_set_word = ctx.lookupWord("@set!") orelse return error.WordNotFound;
    switch (at_set_word.action) {
        .native, .host_callback => try at_set_word.invoke(ctx),
        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
    }

    // Rewrap: pop raw mmap, wrap as tagged, push
    const result_mmap = try ctx.stack.pop();
    const inner = try alloc.create(Value);
    inner.* = result_mmap;
    try ctx.stack.pushMoved(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Native dispatch helper for @remove! on typed mutable maps.
/// Unwraps the typed mmap, delegates to base @remove!, rewraps.
fn typedAtRemoveMutDispatch(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const key = try ctx.stack.pop();
    const typed_mmap = try ctx.stack.pop();
    // The rewrap reuses the same mutated backing and takes a fresh owning
    // reference, so release this consumed slot's reference on return.
    defer container_backing.releaseValue(typed_mmap);

    // Unwrap typed mmap to raw mmap, push raw-mmap key for @remove!
    try ctx.stack.push(typed_mmap.tagged.inner.*);
    try ctx.stack.push(key);

    // Delegate to the raw @remove!
    const at_remove_word = ctx.lookupWord("@remove!") orelse return error.WordNotFound;
    switch (at_remove_word.action) {
        .native, .host_callback => try at_remove_word.invoke(ctx),
        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
    }

    // Rewrap: pop raw mmap, wrap as tagged, push
    const result_mmap = try ctx.stack.pop();
    const inner = try alloc.create(Value);
    inner.* = result_mmap;
    try ctx.stack.pushMoved(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Native dispatch helper for freeze on typed vectors.
/// Unwraps the typed vector, dupes items to create a raw array, then wraps
/// as the corresponding typed array.
fn typedFreezeDispatch(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const typed_vec = try ctx.stack.pop();
    // freeze consumes the typed vector and produces a fresh typed array;
    // release the consumed wrapper's owning reference on return.
    defer container_backing.releaseValue(typed_vec);

    // Unwrap tagged vec to raw vec
    const raw_vec = typed_vec.tagged.inner.*;
    const vec = switch (raw_vec) {
        .vector => |v| v,
        else => {
            helpers.setErrorContext(ctx, "freeze expected vector inside {s}, got {s}", .{ vt.name, helpers.valueTypeName(raw_vec) });
            return error.TypeMismatch;
        },
    };

    // Dupe items to create raw array
    const items = try alloc.dupe(Value, vec.list.items);

    // Construct target type name: "array(" ++ elem_type ++ ")"
    const params = vt.type_params orelse {
        helpers.setErrorContext(ctx, "freeze: {s} has no type parameters", .{vt.name});
        return error.TypeMismatch;
    };
    const elem_type_name = params[0].name;
    const target_wrap_name = try std.fmt.allocPrint(alloc, ">array({s})", .{elem_type_name});

    const wrap_word = ctx.lookupWord(target_wrap_name) orelse {
        helpers.setErrorContext(ctx, "freeze: no typed array defined for element type {s} (need to define array({s}))", .{ elem_type_name, elem_type_name });
        return error.WordNotFound;
    };

    // Push raw array and execute the wrap word
    try ctx.stack.push(.{ .array = items });
    switch (wrap_word.action) {
        .native, .host_callback => try wrap_word.invoke(ctx),
        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
    }
}

/// Trampoline helper ( value tv -- tagged )
///
/// Like virtualWrapHelper but additionally validates that array elements
/// match the parameterized type's type_params[0].
fn virtualParameterizedWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    var val = try ctx.stack.pop();

    // A parameterized enum base (`result(fixnum,string)`) wraps a tagged variant,
    // not a bare value, so its payload validation substitutes the enum's bound
    // tuple through each variant's own binding. Handle it separately.
    if (vt.base_type) |base_tv| {
        if (base_tv.descriptor) |bd| {
            if (bd.kind == .enum_) {
                try wrapParameterizedEnumVariant(ctx, vt, base_tv, val);
                return;
            }
        }
    }

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
            const expected_tv = params[0];
            switch (val) {
                .array => |arr| {
                    var promoted_arr: ?[]Value = null;
                    for (arr, 0..) |elem, i| {
                        const elem_tv = dispatch_mod.dispatchTypeValue(elem, ctx);
                        if (elem_tv != expected_tv) {
                            if (tryPromoteElement(alloc, elem, expected_tv.name)) |promoted| {
                                if (promoted_arr == null) {
                                    promoted_arr = try alloc.alloc(Value, arr.len);
                                    @memcpy(promoted_arr.?[0..i], arr[0..i]);
                                }
                                promoted_arr.?[i] = promoted;
                            } else {
                                helpers.setErrorContext(ctx, ">{s} element at index {d} has type {s}, expected {s}", .{ vt.name, i, elem_tv.name, expected_tv.name });
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
                .struct_instance => |si| {
                    // Validate each field bound to a type parameter against its
                    // bound concrete type. The base struct's field-type slots
                    // hold the parameter TypeValues, whose position indexes the
                    // bound `type_params` tuple.
                    const field_types: []const ?value_mod.ConstraintCombinator.Element = blk: {
                        const base = vt.base_type orelse break :blk &.{};
                        const root = ctx.rootStructTypeValue(base) orelse break :blk &.{};
                        break :blk switch (root.descriptor.?.kind) {
                            .struct_ => |sd| sd.field_types,
                            else => &.{},
                        };
                    };
                    for (si.fields, 0..) |field_val, i| {
                        if (i >= field_types.len) continue;
                        const element = field_types[i] orelse continue;
                        const slot_tv = switch (element) {
                            .type => |t| t,
                            else => continue,
                        };
                        if (!value_mod.isTypeParameter(slot_tv)) continue;
                        const pos = value_mod.typeParameterPosition(slot_tv) orelse continue;
                        if (pos >= params.len) continue;
                        const bound = params[pos];
                        if (!helpers.valueMatchesType(ctx, field_val, bound)) {
                            helpers.setErrorContext(ctx, ">{s} field '{s}' expects {s}, got {s}", .{ vt.name, si.struct_type.fields[i], bound.name, helpers.valueTypeName(field_val) });
                            return error.TypeMismatch;
                        }
                    }
                },
                else => {},
            }
        }
    }

    const inner = try alloc.create(Value);
    inner.* = val;

    // `val` was popped (ownership transferred); the tagged becomes its
    // owner via pushMoved without an extra retain.
    try ctx.stack.pushMoved(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Validate and re-tag a variant payload for a parameterized enum instantiation.
///
/// `vt` is the `result(fixnum,string)` wrapper (its `type_params` are the enum's
/// bound tuple); `enum_tv` is the base enum. `val` must be a tagged variant of
/// that enum. For each variant payload field slotted with a type parameter, the
/// field type resolves through two levels: the variant's own binding tuple maps
/// the variant base's parameter position to an enum-level parameter (or a
/// concrete type), then the enum-level parameter's position indexes `vt`'s bound
/// tuple. The field value is validated against the resolved concrete type. On
/// success the whole variant is re-tagged with the parameterized enum type.
fn wrapParameterizedEnumVariant(
    ctx: *Context,
    vt: *const VirtualType,
    enum_tv: *const value_mod.TypeValue,
    val: Value,
) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const variant: *const VirtualType = switch (val) {
        .tagged => |t| if (t.tag.parent_type == enum_tv)
            t.tag
        else {
            helpers.setErrorContext(ctx, ">{s} expects a {s} variant, got {s}", .{ vt.name, enum_tv.name, t.tag.name });
            return error.TypeMismatch;
        },
        else => {
            helpers.setErrorContext(ctx, ">{s} expects a {s} variant, got {s}", .{ vt.name, enum_tv.name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    };

    const enum_params: []const *const value_mod.TypeValue = vt.type_params orelse &.{};

    if (variant.type_params) |variant_binding| {
        const field_types: []const ?value_mod.ConstraintCombinator.Element =
            if (variant.anon_struct) |st| st.field_types else &.{};
        const inst: ?*const value_mod.StructInstance = switch (val.tagged.inner.*) {
            .struct_instance => |si| si,
            else => null,
        };
        if (inst) |si| {
            for (si.fields, 0..) |field_val, i| {
                if (i >= field_types.len) continue;
                const element = field_types[i] orelse continue;
                const slot_tv = switch (element) {
                    .type => |t| t,
                    else => continue,
                };
                if (!value_mod.isTypeParameter(slot_tv)) continue;
                const p = value_mod.typeParameterPosition(slot_tv) orelse continue;
                if (p >= variant_binding.len) continue;
                const mapped = variant_binding[p];
                const bound = if (value_mod.isTypeParameter(mapped)) blk: {
                    const q = value_mod.typeParameterPosition(mapped) orelse continue;
                    if (q >= enum_params.len) continue;
                    break :blk enum_params[q];
                } else mapped;
                if (!helpers.valueMatchesType(ctx, field_val, bound)) {
                    helpers.setErrorContext(ctx, ">{s} field '{s}' expects {s}, got {s}", .{ vt.name, si.struct_type.fields[i], bound.name, helpers.valueTypeName(field_val) });
                    return error.TypeMismatch;
                }
            }
        }
    }

    const inner = try alloc.create(Value);
    inner.* = val;
    // `val` was popped (ownership transferred); the tagged inherits it via
    // pushMoved without an extra retain.
    try ctx.stack.pushMoved(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// >NAME: ( value -- tagged ) - validating wrap for parameterized types
pub fn defineParameterizedWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
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

// `rootStructTypeValue` and `resolveBaseParams` moved to `Context` so
// `struct_field_spec.parse` can share the same base-parameter resolution.

/// Bind a base type's type parameters from a `type-params:` hash, producing the
/// positional `type_params` tuple. The hash maps parameter names to concrete
/// TypeValues and may cover any subset of the base's still-unbound parameters
/// (partial binding). Bound slots on the base are carried through unchanged;
/// unbound slots not named in the hash stay unbound. Unknown keys, keys naming
/// an already-bound parameter (monotonic narrowing), and non-TypeValue values
/// are parse-time errors.
fn bindTypeParams(
    ctx: *Context,
    base_tv: *const value_mod.TypeValue,
    tp_val: Value,
) anyerror![]*const value_mod.TypeValue {
    const alloc = ctx.quotationAllocator();

    const tp_hash = switch (tp_val) {
        .hash => |h| h,
        else => {
            helpers.setTypeMismatchError(ctx, "hash", tp_val);
            return error.TypeMismatch;
        },
    };

    const base = ctx.resolveBaseParams(base_tv);

    // Every hash key must name a declared parameter that is still unbound.
    var it = tp_hash.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const idx = for (base.declared, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, key)) break i;
        } else {
            helpers.setErrorContext(ctx, "define-parameterized-type: unknown type parameter '{s}' for base {s}", .{ key, base_tv.name });
            return error.MissingField;
        };
        if (!value_mod.isTypeParameter(base.current[idx])) {
            helpers.setErrorContext(ctx, "define-parameterized-type: type parameter '{s}' is already bound on base {s}", .{ key, base_tv.name });
            return error.MissingField;
        }
    }

    // Copy the base's current tuple, binding any unbound slot named in the hash.
    const params = try alloc.alloc(*const value_mod.TypeValue, base.current.len);
    for (base.current, 0..) |cur, i| {
        if (value_mod.isTypeParameter(cur)) {
            if (tp_hash.get(cur.name)) |bound_val| {
                params[i] = switch (bound_val) {
                    .type_val => |tv| tv,
                    else => {
                        helpers.setTypeMismatchError(ctx, "type", bound_val);
                        return error.TypeMismatch;
                    },
                };
            } else {
                params[i] = cur;
            }
        } else {
            params[i] = cur;
        }
    }
    return params;
}

/// define-parameterized-type ( name: descriptor markers -- ) - Define a parameterized
/// virtual type from a descriptor carrying `inner-type`, `element-type`, and `define`
/// fields. Invoked through the descriptor-driven `;` protocol after `;` has pushed
/// name, descriptor, and the collected markers array.
///
/// The `>name` word validates that all elements of the inner value match the element
/// type. The `make-name` word skips element validation. The resulting type word is a
/// parse-time, const, typed compound that pushes the `TypeValue` literal.
fn nativeDefineParameterizedType(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    const markers_array = switch (markers_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", markers_val);
            return error.TypeMismatch;
        },
    };

    const desc_val = try ctx.stack.pop();
    defer container_backing.releaseValue(desc_val);
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };

    const base_type_val = desc_map.map.get("inner-type") orelse {
        helpers.setErrorContext(ctx, "define-parameterized-type descriptor missing 'inner-type' field", .{});
        return error.MissingField;
    };
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

    // A `type-params:` hash selects the generics branch (bind declared parameter
    // slots on the base positionally); an `element-type:` TypeValue keeps the
    // refinement branch (one constraint applied uniformly across a container).
    const type_params: []*const value_mod.TypeValue = if (desc_map.map.get("type-params")) |tp_val|
        try bindTypeParams(ctx, base_tv, tp_val)
    else if (desc_map.map.get("element-type")) |elem_type_val| blk: {
        const elem_tv = switch (elem_type_val) {
            .type_val => |tv| tv,
            else => {
                helpers.setTypeMismatchError(ctx, "type", elem_type_val);
                return error.TypeMismatch;
            },
        };
        const params = try alloc.alloc(*const value_mod.TypeValue, 1);
        params[0] = elem_tv;
        break :blk params;
    } else {
        helpers.setErrorContext(ctx, "define-parameterized-type descriptor missing 'element-type' or 'type-params' field", .{});
        return error.MissingField;
    };

    const vtype = try alloc.create(VirtualType);
    vtype.* = .{
        .name = name,
        // A struct-backed virtual base wraps values of the root struct, not the
        // wrapper, so the wrap type-check compares against the root struct name.
        .inner_type = if (ctx.rootStructTypeValue(base_tv)) |root| root.name else base_tv.name,
        .base_type = base_tv,
        .type_params = type_params,
    };
    ctx.virtual_type_count += 1;

    const desc = try ctx.getOrCreateParameterizedTypeDescriptor(base_tv, type_params);

    const tv = try alloc.create(value_mod.TypeValue);
    tv.* = .{ .name = name, .descriptor = desc };
    vtype.type_val = tv;
    tv.virtual_type = vtype;

    // NAME: ( -- type ) - parse-time const pushing TypeValue
    var type_markers_list = std.ArrayListUnmanaged(*Marker){};
    var has_parse_time = false;
    var has_const = false;
    var has_typed = false;
    for (markers_array) |m| {
        switch (m) {
            .marker => |mk| {
                try type_markers_list.append(alloc, mk);
                if (mk == @as(*const Marker, &markers_mod.parse_time_marker)) has_parse_time = true;
                if (mk == @as(*const Marker, &markers_mod.const_marker)) has_const = true;
                if (mk == @as(*const Marker, &markers_mod.typed_marker)) has_typed = true;
            },
            else => {
                helpers.setTypeMismatchError(ctx, "marker", m);
                return error.TypeMismatch;
            },
        }
    }
    if (!has_parse_time) try type_markers_list.append(alloc, @constCast(&markers_mod.parse_time_marker));
    if (!has_const) try type_markers_list.append(alloc, @constCast(&markers_mod.const_marker));
    if (!has_typed) try type_markers_list.append(alloc, @constCast(&markers_mod.typed_marker));
    const type_markers = try type_markers_list.toOwnedSlice(alloc);

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

    if (std.mem.eql(u8, base_tv.name, "mutable-map")) {
        try registerMutableMapMutationDispatches(ctx, alloc, name, vtype, &generated_words);
    }

    const gw_slice = try generated_words.toOwnedSlice(alloc);
    tv.generated_words = gw_slice;

    try ctx.registerTypeDescriptor(name, desc);
}

/// Register dispatch entries for vector mutation ops on a parameterized vector type.
/// Each entry validates/promotes elements before delegating to the base vector op.
fn registerVectorMutationDispatches(
    ctx: *Context,
    alloc: Allocator,
    _: []const u8,
    vtype: *const VirtualType,
    generated_words: *std.ArrayListUnmanaged(Value),
) !void {
    const type_tv = vtype.type_val.?;
    const vtype_ptr: Value = .{ .type_val = vtype.type_val.? };

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

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.lookupWord(op_name).?.dispatch_id,
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

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

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.lookupWord(op_name).?.dispatch_id,
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, .{ .string = op_name });
    }

    // #nth! -- Stack: typed-vec n elem
    // Body: push vtype-ptr, call native helper that handles the full
    // validate+unwrap+delegate+rewrap sequence
    {
        const instrs = try alloc.alloc(Instruction, 2);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-nth-mut-dispatch" }, .line = 0 };

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.lookupWord("#nth!").?.dispatch_id,
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

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

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.lookupWord("#append!").?.dispatch_id,
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, .{ .string = "#append!" });
    }

    // freeze ( typed-vec -- typed-array )
    {
        const instrs = try alloc.alloc(Instruction, 2);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-freeze-dispatch" }, .line = 0 };

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.lookupWord("freeze").?.dispatch_id,
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, .{ .string = "freeze" });
    }
}

/// Register dispatch entries for mutable-map mutation ops on a parameterized mutable-map type.
/// Each entry delegates to a native helper that handles validate+unwrap+delegate+rewrap.
fn registerMutableMapMutationDispatches(
    ctx: *Context,
    alloc: Allocator,
    _: []const u8,
    vtype: *const VirtualType,
    generated_words: *std.ArrayListUnmanaged(Value),
) !void {
    const type_tv = vtype.type_val.?;
    const vtype_ptr: Value = .{ .type_val = vtype.type_val.? };

    // @set! ( typed-mmap key value -- typed-mmap )
    {
        const instrs = try alloc.alloc(Instruction, 2);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-at-set-mut-dispatch" }, .line = 0 };

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.lookupWord("@set!").?.dispatch_id,
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, .{ .string = "@set!" });
    }

    // @remove! ( typed-mmap key -- typed-mmap )
    {
        const instrs = try alloc.alloc(Instruction, 2);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-at-remove-mut-dispatch" }, .line = 0 };

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.lookupWord("@remove!").?.dispatch_id,
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, .{ .string = "@remove!" });
    }
}

/// Register a >hash dispatch entry for a type, creating the generic `>hash` word if it doesn't exist yet.
pub fn registerHashDispatch(ctx: *Context, type_tv: *const value_mod.TypeValue, instrs: []const Instruction) !void {
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

    try ctx.registerDispatch(.{
        .dispatch_id = ctx.lookupWord(">hash").?.dispatch_id,
        .type_a = type_tv.descriptor.?,
        .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
    }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);
}
