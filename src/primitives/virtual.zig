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
const NativeDispatchWord = dispatch_mod.NativeDispatchWord;
const container_backing = @import("../container_backing.zig");
const freeze_mod = @import("freeze.zig");
const sequences_mod = @import("sequences.zig");
const data_structures_mod = @import("data_structures.zig");

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

/// define-virtual ( name: descriptor markers -- )
///
/// Generates: >NAME (wrap), NAME> (unwrap), NAME? (predicate)
///
/// When inner-type is a type value, creates a simple virtual type wrapping that type.
/// When inner-type is a mutable map (struct descriptor from `struct{`), creates a
/// struct-backed virtual type with positional wrap and destructuring unwrap.
fn nativeDefineVirtual(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    defer container_backing.releaseValue(markers_val);
    const markers_array = switch (markers_val) {
        .array => |arr| arr.items,
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

    // Every word below is generated by this declaration, so the site is published on the context
    // rather than threaded through each definition call.
    const saved_src_loc = ctx.generated_src_loc;
    defer ctx.generated_src_loc = saved_src_loc;
    ctx.generated_src_loc = try helpers.genSrcLocFrom(alloc, src_map.map.get("src-loc"));

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
            if (arr.items.len != 1) {
                helpers.setErrorContext(ctx, "virtual{{ expects exactly one inner type, got {d}", .{arr.items.len});
                return error.ParseError;
            }
            break :blk arr.items[0];
        },
        else => inner_type_raw,
    };

    const name_val = try ctx.stack.pop();
    defer container_backing.releaseValue(name_val);
    // The name escapes into the long-lived VirtualType and TypeValue.
    const name = switch (name_val) {
        .symbol => |s| try alloc.dupe(u8, s.bytes),
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
            try generated_words.append(alloc, value_mod.stringValue(name));
            try generated_words.append(alloc, value_mod.stringValue(wrap_name));
            try generated_words.append(alloc, value_mod.stringValue(make_name));
            try generated_words.append(alloc, value_mod.stringValue(unmake_name));
            try generated_words.append(alloc, value_mod.stringValue(pred_name));
            const gw_slice = try generated_words.toOwnedSlice(alloc);
            tv.generated_words = gw_slice;
            try ctx.registerTypeDescriptor(name, desc_map);
        },
        .mutable_map => |struct_desc| {
            const fields_val = struct_desc.map.get("fields") orelse return error.MissingField;
            const fields_array = switch (fields_val) {
                .array => |arr| arr.items,
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
            try generated_words.append(alloc, value_mod.stringValue(name));
            try generated_words.append(alloc, value_mod.stringValue(wrap_name));
            try generated_words.append(alloc, value_mod.stringValue(make_name));
            try generated_words.append(alloc, value_mod.stringValue(unmake_name));
            try generated_words.append(alloc, value_mod.stringValue(to_hash_name));
            try generated_words.append(alloc, value_mod.stringValue(pred_name));
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
fn virtualWrapHelper(ctx: *Context) anyerror!void {
    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const val = try ctx.stack.pop();

    const actual_type: []const u8 = switch (val) {
        .struct_instance => |si| si.struct_type.name,
        .bignum => if (std.mem.eql(u8, vt.inner_type, "fixnum")) "fixnum" else "bignum",
        else => helpers.valueTypeName(val),
    };
    if (!std.mem.eql(u8, actual_type, vt.inner_type)) {
        container_backing.releaseValue(val);
        helpers.setErrorContext(ctx, ">{s} expects {s}, got {s}", .{ vt.name, vt.inner_type, actual_type });
        return error.TypeMismatch;
    }

    // The backing adopts the popped reference, so a dropped wrapper frees the
    // box and releases the inner at the drop.
    try helpers.pushOwnedTagged(ctx, vt, val);
}

/// Trampoline helper ( tagged tv -- value )
fn virtualUnwrapHelper(ctx: *Context) anyerror!void {
    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);

    switch (val) {
        .tagged => |t| {
            if (t.tag == vt) {
                // Retain the inner for the new slot; the deferred release
                // drops the popped wrapper reference. A backed wrapper at
                // zero releases the inner once in destroy; a null-backed
                // wrapper's release recurses into the inner, so the
                // transfer balances either way.
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

/// Trampoline helper ( value tv -- ? )
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
    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };
    const num_fields = st.fields.len;

    const field_values = try ctx.allocator.alloc(Value, num_fields);
    var lowest: usize = num_fields;
    var fields_owned = true;
    errdefer if (fields_owned) {
        container_backing.releaseValues(field_values[lowest..num_fields]);
        ctx.allocator.free(field_values);
    };
    var i: usize = num_fields;
    while (i > 0) {
        i -= 1;
        field_values[i] = try ctx.stack.pop();
        lowest = i;
    }

    const instance = try value_mod.createStructInstance(ctx.allocator, st, field_values);
    fields_owned = false;

    // The backing adopts the instance's creation reference, so a dropped
    // wrapper frees the box and releases the instance at the drop.
    try helpers.pushOwnedTagged(ctx, vt, .{ .struct_instance = instance });
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
fn virtualStructToHashHelper(ctx: *Context) anyerror!void {
    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };

    const val = try ctx.stack.pop();
    // The popped tagged value is consumed; release it on every path. The
    // resulting hash's slots each take their own reference to a field value.
    defer container_backing.releaseValue(val);
    switch (val) {
        .tagged => |t| {
            if (t.tag != vt) {
                helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, t.tag.name });
                return error.TypeMismatch;
            }
            switch (t.inner.*) {
                .struct_instance => |si| {
                    const hash = try value_mod.HashTable.create(ctx.allocator);
                    errdefer hash.header.release();
                    const hash_alloc = hash.header.allocator;
                    for (st.fields, 0..) |field, i| {
                        const key_copy = try hash_alloc.dupe(u8, field);
                        container_backing.retainValue(si.fields[i]);
                        hash.map.put(hash_alloc, key_copy, si.fields[i]) catch {
                            hash_alloc.free(key_copy);
                            container_backing.releaseValue(si.fields[i]);
                            return error.OutOfMemory;
                        };
                    }
                    try ctx.stack.pushMoved(.{ .hash = hash });
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
fn virtualStructHashWrapHelper(ctx: *Context) anyerror!void {
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

    if (hash.map.count() != st.fields.len) {
        helpers.setErrorContext(ctx, ">{s} expects {d} fields, got {d}", .{ vt.name, st.fields.len, hash.map.count() });
        return error.TypeMismatch;
    }

    const field_values = try ctx.allocator.alloc(Value, st.fields.len);
    var fields_owned = true;
    errdefer if (fields_owned) ctx.allocator.free(field_values);
    for (st.fields, 0..) |field, i| {
        field_values[i] = hash.map.get(field) orelse {
            helpers.setErrorContext(ctx, ">{s} missing field '{s}'", .{ vt.name, field });
            return error.MissingField;
        };
    }

    // Fields are borrowed from the source hash; retain each so the tagged
    // instance becomes an independent owner before the hash is released above.
    container_backing.retainValues(field_values);
    errdefer if (fields_owned) container_backing.releaseValues(field_values);

    const instance = try value_mod.createStructInstance(ctx.allocator, st, field_values);
    fields_owned = false;

    try helpers.pushOwnedTagged(ctx, vt, .{ .struct_instance = instance });
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
                const str = b.big.toConst().toStringAlloc(alloc, 10, .lower) catch break :blk std.math.nan(f64);
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
                break :blk .{ .bignum = .{ .big = ptr } };
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
    // transfer ownership via pushMoved instead of retaining again. Any error
    // exit must drop the popped reference instead; the promoted-array path
    // clears the flag once it hands the reference off explicitly.
    var seq_owned = true;
    errdefer if (seq_owned) container_backing.releaseValue(seq);

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
        .array => |arr| arr.items,
        .vector => |v| v.list.items,
        else => {
            try ctx.stack.pushMoved(seq);
            return;
        },
    };

    // For an array source, the promoted result becomes a fresh owned array,
    // so copied originals are retained as they enter the new backing;
    // promoted elements are fresh references either way. The retained copies
    // drop on any error exit; `toOwnedSlice` empties the list on the success
    // path, so this covers exactly the abandoned partial builds.
    const seq_is_array = seq == .array;
    var promoted_items: ?std.ArrayListUnmanaged(Value) = null;
    errdefer if (seq_is_array) {
        if (promoted_items) |*pi| container_backing.releaseValues(pi.items);
    };
    for (items, 0..) |elem, i| {
        const actual_tv = dispatch_mod.dispatchTypeValue(elem, ctx);
        if (actual_tv != expected_tv) {
            if (tryPromoteElement(alloc, elem, expected_tv.name)) |promoted| {
                if (promoted_items == null) {
                    promoted_items = std.ArrayListUnmanaged(Value){};
                    promoted_items.?.ensureTotalCapacity(alloc, items.len) catch return error.OutOfMemory;
                    promoted_items.?.appendSlice(alloc, items[0..i]) catch return error.OutOfMemory;
                    if (seq_is_array) container_backing.retainValues(promoted_items.?.items);
                }
                promoted_items.?.append(alloc, promoted) catch return error.OutOfMemory;
            } else {
                helpers.setErrorContext(ctx, "{s} element at index {d} has type {s}, expected {s}", .{ vt.name, i, actual_tv.name, expected_tv.name });
                return error.TypeMismatch;
            }
        } else if (promoted_items) |*pi| {
            if (seq_is_array) container_backing.retainValue(elem);
            pi.append(alloc, elem) catch return error.OutOfMemory;
        }
    }

    if (promoted_items) |*pi| {
        switch (seq) {
            .array => {
                const new_items = pi.toOwnedSlice(alloc) catch return error.OutOfMemory;
                const new_arr = value_mod.Array.fromOwnedSlice(alloc, new_items) catch |e| {
                    container_backing.releaseValues(new_items);
                    alloc.free(new_items);
                    return e;
                };
                // The promoted array replaces the popped original.
                seq_owned = false;
                container_backing.releaseValue(seq);
                ctx.stack.pushMoved(.{ .array = new_arr }) catch |err| {
                    container_backing.releaseValue(.{ .array = new_arr });
                    return err;
                };
            },
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
fn typedNthMutDispatch(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    var elem = try ctx.stack.pop();
    var elem_owned = true;
    errdefer if (elem_owned) container_backing.releaseValue(elem);
    const n = try ctx.stack.pop();
    var n_owned = true;
    errdefer if (n_owned) container_backing.releaseValue(n);
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
                    // The promoted replacement supersedes the popped original.
                    container_backing.releaseValue(elem);
                    elem = promoted;
                } else {
                    helpers.setErrorContext(ctx, "{s} element has type {s}, expected {s}", .{ vt.name, actual_tv.name, expected_tv.name });
                    return error.TypeMismatch;
                }
            }
        }
    }

    // Unwrap tagged vec to raw vec, push raw-vec n elem for #nth!; the popped
    // n and elem references transfer to the delegated word's operand slots.
    try ctx.stack.push(typed_vec.tagged.inner.*);
    try ctx.stack.pushMoved(n);
    n_owned = false;
    try ctx.stack.pushMoved(elem);
    elem_owned = false;

    // Delegate straight to the raw #nth! native. Resolving the name instead would walk the
    // shadowing ladder, so a caller's binding of the name would answer here.
    try sequences_mod.nativeNthMut(ctx);

    // Rewrap: pop raw vec, wrap as tagged, push
    const result_vec = try ctx.stack.pop();
    try helpers.pushOwnedTagged(ctx, vt, result_vec);
}

/// Native dispatch helper for @set! on typed mutable maps.
fn typedAtSetMutDispatch(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    var new_value = try ctx.stack.pop();
    var value_owned = true;
    errdefer if (value_owned) container_backing.releaseValue(new_value);
    const key = try ctx.stack.pop();
    var key_owned = true;
    errdefer if (key_owned) container_backing.releaseValue(key);
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
                    // The promoted replacement supersedes the popped original.
                    container_backing.releaseValue(new_value);
                    new_value = promoted;
                } else {
                    helpers.setErrorContext(ctx, "{s} element has type {s}, expected {s}", .{ vt.name, actual_tv.name, expected_tv.name });
                    return error.TypeMismatch;
                }
            }
        }
    }

    // Unwrap typed mmap to raw mmap, push raw-mmap key value for @set!; the
    // popped key and value references transfer to the delegated word's slots.
    try ctx.stack.push(typed_mmap.tagged.inner.*);
    try ctx.stack.pushMoved(key);
    key_owned = false;
    try ctx.stack.pushMoved(new_value);
    value_owned = false;

    // Delegate straight to the raw @set! native, for the reason typedNthMutDispatch gives.
    try data_structures_mod.nativeAtSetMut(ctx);

    // Rewrap: pop raw mmap, wrap as tagged, push
    const result_mmap = try ctx.stack.pop();
    try helpers.pushOwnedTagged(ctx, vt, result_mmap);
}

/// Native dispatch helper for @remove! on typed mutable maps.
fn typedAtRemoveMutDispatch(ctx: *Context) anyerror!void {
    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    const key = try ctx.stack.pop();
    var key_owned = true;
    errdefer if (key_owned) container_backing.releaseValue(key);
    const typed_mmap = try ctx.stack.pop();
    // The rewrap reuses the same mutated backing and takes a fresh owning
    // reference, so release this consumed slot's reference on return.
    defer container_backing.releaseValue(typed_mmap);

    // Unwrap typed mmap to raw mmap, push raw-mmap key for @remove!; the
    // popped key reference transfers to the delegated word's operand slot.
    try ctx.stack.push(typed_mmap.tagged.inner.*);
    try ctx.stack.pushMoved(key);
    key_owned = false;

    // Delegate straight to the raw @remove! native, for the reason typedNthMutDispatch gives.
    try data_structures_mod.nativeAtRemoveMut(ctx);

    // Rewrap: pop raw mmap, wrap as tagged, push
    const result_mmap = try ctx.stack.pop();
    try helpers.pushOwnedTagged(ctx, vt, result_mmap);
}

/// Native dispatch helper for freeze on typed vectors. Delegates to the deep-freeze walker, which
/// converts the elements and rewraps through the corresponding typed array's wrap word.
fn typedFreezeDispatch(ctx: *Context) anyerror!void {
    const tv = try helpers.popTypeVal(ctx);
    _ = tv;

    const typed_vec = try ctx.stack.pop();
    defer container_backing.releaseValue(typed_vec);

    const frozen = try freeze_mod.deepFreezeCopy(ctx, typed_vec);
    ctx.stack.pushMoved(frozen) catch |e| {
        container_backing.releaseValue(frozen);
        return e;
    };
}

/// Trampoline helper ( value tv -- tagged )
///
/// Like virtualWrapHelper but additionally validates the wrapped value's contents against the
/// parameterized type's type_params[0], promoting numeric elements where the tower allows.
fn virtualParameterizedWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tv = try helpers.popTypeVal(ctx);
    const vt = tv.virtual_type.?;

    var val = try ctx.stack.pop();

    // Popped with ownership; it flows into the wrapper's backing on success (on
    // either branch below), which consumes it on every path, so release only on
    // a throw before that handoff.
    var val_owned = true;
    errdefer if (val_owned) container_backing.releaseValue(val);

    // A parameterized enum base (`result(fixnum,string)`) wraps a tagged variant,
    // not a bare value, so its payload validation substitutes the enum's bound
    // tuple through each variant's own binding. Handle it separately.
    if (vt.base_type) |base_tv| {
        if (base_tv.descriptor) |bd| {
            if (bd.kind == .enum_) {
                val_owned = false;
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
                    for (arr.items, 0..) |elem, i| {
                        const elem_tv = dispatch_mod.dispatchTypeValue(elem, ctx);
                        if (elem_tv != expected_tv) {
                            if (tryPromoteElement(alloc, elem, expected_tv.name)) |promoted| {
                                if (promoted_arr == null) {
                                    promoted_arr = try alloc.alloc(Value, arr.items.len);
                                    @memcpy(promoted_arr.?[0..i], arr.items[0..i]);
                                    // Copied originals become new owning
                                    // references; promoted elements are fresh.
                                    container_backing.retainValues(promoted_arr.?[0..i]);
                                }
                                promoted_arr.?[i] = promoted;
                            } else {
                                if (promoted_arr) |pa| container_backing.releaseValues(pa[0..i]);
                                helpers.setErrorContext(ctx, ">{s} element at index {d} has type {s}, expected {s}", .{ vt.name, i, elem_tv.name, expected_tv.name });
                                return error.TypeMismatch;
                            }
                        } else if (promoted_arr) |pa| {
                            container_backing.retainValue(elem);
                            pa[i] = elem;
                        }
                    }
                    if (promoted_arr) |pa| {
                        const new_arr = try value_mod.Array.fromOwnedSlice(alloc, pa);
                        // Swap in the promoted array, dropping the popped
                        // original's reference.
                        container_backing.releaseValue(val);
                        val = .{ .array = new_arr };
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
                .hash => |h| {
                    // Immutable and possibly aliased: validate first, then swap in a fresh
                    // HashTable when anything promotes.
                    var needs_promotion = false;
                    var scan = h.map.iterator();
                    while (scan.next()) |entry| {
                        const elem = entry.value_ptr.*;
                        const elem_tv = dispatch_mod.dispatchTypeValue(elem, ctx);
                        if (elem_tv == expected_tv) continue;
                        if (tryPromoteElement(alloc, elem, expected_tv.name) == null) {
                            helpers.setErrorContext(ctx, ">{s} value for key '{s}' has type {s}, expected {s}", .{ vt.name, entry.key_ptr.*, elem_tv.name, expected_tv.name });
                            return error.TypeMismatch;
                        }
                        needs_promotion = true;
                    }

                    if (needs_promotion) {
                        const new_hash = try value_mod.HashTable.create(ctx.allocator);
                        errdefer container_backing.releaseValue(.{ .hash = new_hash });
                        const hash_alloc = new_hash.header.allocator;

                        var rebuild = h.map.iterator();
                        while (rebuild.next()) |entry| {
                            const key_copy = try hash_alloc.dupe(u8, entry.key_ptr.*);

                            const elem = entry.value_ptr.*;
                            const carried = dispatch_mod.dispatchTypeValue(elem, ctx) == expected_tv;
                            const stored = if (carried) elem else tryPromoteElement(alloc, elem, expected_tv.name).?;
                            if (carried) container_backing.retainValue(stored);

                            new_hash.map.put(hash_alloc, key_copy, stored) catch {
                                hash_alloc.free(key_copy);
                                if (carried) container_backing.releaseValue(stored);
                                return error.OutOfMemory;
                            };
                        }

                        container_backing.releaseValue(val);
                        val = .{ .hash = new_hash };
                    }
                },
                .set => |s| {
                    var needs_promotion = false;
                    for (s.map.keys()) |member| {
                        const member_tv = dispatch_mod.dispatchTypeValue(member, ctx);
                        if (member_tv == expected_tv) continue;
                        if (tryPromoteElement(alloc, member, expected_tv.name) == null) {
                            helpers.setErrorContext(ctx, ">{s} member has type {s}, expected {s}", .{ vt.name, member_tv.name, expected_tv.name });
                            return error.TypeMismatch;
                        }
                        needs_promotion = true;
                    }

                    if (needs_promotion) {
                        const new_set = try value_mod.Set.create(ctx.allocator);
                        errdefer container_backing.releaseValue(.{ .set = new_set });
                        const set_alloc = new_set.header.allocator;

                        for (s.map.keys()) |member| {
                            const carried = dispatch_mod.dispatchTypeValue(member, ctx) == expected_tv;
                            const stored = if (carried) member else tryPromoteElement(alloc, member, expected_tv.name).?;
                            if (carried) container_backing.retainValue(stored);

                            // A promoted member may collide with an existing one; drop the duplicate.
                            const gop = new_set.map.getOrPut(set_alloc, stored) catch {
                                container_backing.releaseValue(stored);
                                return error.OutOfMemory;
                            };
                            if (gop.found_existing) container_backing.releaseValue(stored);
                        }

                        container_backing.releaseValue(val);
                        val = .{ .set = new_set };
                    }
                },
                .vector => |v| {
                    // The wrap keeps the same mutable backing, so promote in place; validate
                    // first so a failed wrap leaves it untouched.
                    v.header.lock();
                    defer v.header.unlock();

                    for (v.list.items, 0..) |elem, i| {
                        const elem_tv = dispatch_mod.dispatchTypeValue(elem, ctx);
                        if (elem_tv == expected_tv) continue;
                        if (tryPromoteElement(alloc, elem, expected_tv.name) == null) {
                            helpers.setErrorContext(ctx, ">{s} element at index {d} has type {s}, expected {s}", .{ vt.name, i, elem_tv.name, expected_tv.name });
                            return error.TypeMismatch;
                        }
                    }

                    for (v.list.items, 0..) |elem, i| {
                        if (dispatch_mod.dispatchTypeValue(elem, ctx) != expected_tv) {
                            // Displaces only a fixnum or bignum, neither refcounted.
                            v.list.items[i] = tryPromoteElement(alloc, elem, expected_tv.name).?;
                        }
                    }
                },
                .mutable_map => |m| {
                    m.header.lock();
                    defer m.header.unlock();

                    var scan = m.map.iterator();
                    while (scan.next()) |entry| {
                        const elem = entry.value_ptr.*;
                        const elem_tv = dispatch_mod.dispatchTypeValue(elem, ctx);
                        if (elem_tv == expected_tv) continue;
                        if (tryPromoteElement(alloc, elem, expected_tv.name) == null) {
                            helpers.setErrorContext(ctx, ">{s} value for key '{s}' has type {s}, expected {s}", .{ vt.name, entry.key_ptr.*, elem_tv.name, expected_tv.name });
                            return error.TypeMismatch;
                        }
                    }

                    var rewrite = m.map.iterator();
                    while (rewrite.next()) |entry| {
                        const elem = entry.value_ptr.*;
                        if (dispatch_mod.dispatchTypeValue(elem, ctx) != expected_tv) {
                            // Displaces only a fixnum or bignum, neither refcounted.
                            entry.value_ptr.* = tryPromoteElement(alloc, elem, expected_tv.name).?;
                        }
                    }
                },
                else => {},
            }
        }
    }

    val_owned = false;
    try helpers.pushOwnedTagged(ctx, vt, val);
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
///
/// Takes ownership of the caller's reference to `val` on every path.
fn wrapParameterizedEnumVariant(
    ctx: *Context,
    vt: *const VirtualType,
    enum_tv: *const value_mod.TypeValue,
    val: Value,
) anyerror!void {
    var val_owned = true;
    errdefer if (val_owned) container_backing.releaseValue(val);

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

    val_owned = false;
    try helpers.pushOwnedTagged(ctx, vt, val);
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
/// positional `type_params` tuple. The hash may cover any subset of the base's
/// still-unbound parameters (partial binding); bound slots are carried through
/// unchanged. Unknown keys, already-bound parameter names (monotonic narrowing),
/// and non-TypeValue values are parse-time errors.
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
    var it = tp_hash.map.iterator();
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
            if (tp_hash.map.get(cur.name)) |bound_val| {
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

/// define-parameterized-type ( name: descriptor markers -- )
///
/// Invoked through the descriptor-driven `;` protocol after `;` has pushed name,
/// descriptor, and the collected markers array.
///
/// The `>name` word validates that all elements of the inner value match the element
/// type; `make-name` skips element validation. The resulting type word is a parse-time,
/// const, typed compound that pushes the `TypeValue` literal.
fn nativeDefineParameterizedType(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    defer container_backing.releaseValue(markers_val);
    const markers_array = switch (markers_val) {
        .array => |arr| arr.items,
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
    defer container_backing.releaseValue(name_val);
    // Same escape as `define-virtual-type`: the name outlives the popped value.
    const name = switch (name_val) {
        .symbol => |s| try alloc.dupe(u8, s.bytes),
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
    try generated_words.append(alloc, value_mod.stringValue(name));
    try generated_words.append(alloc, value_mod.stringValue(wrap_name));
    try generated_words.append(alloc, value_mod.stringValue(make_name));
    try generated_words.append(alloc, value_mod.stringValue(unmake_name));
    try generated_words.append(alloc, value_mod.stringValue(pred_name));

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
    const adding_ops = [_]NativeDispatchWord{ .push_mut, .unshift_mut };
    for (adding_ops) |op| {
        const op_name = op.wordName();
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
            .dispatch_id = ctx.nativeDispatchId(op),
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, value_mod.stringValue(op_name));
    }

    // Element-removing ops: #pop!, #shift!
    // Stack: typed-vec
    // Body: unwrap vec, base-op (leaves vec elem), swap, rewrap, swap
    const removing_ops = [_]NativeDispatchWord{ .pop_mut, .shift_mut };
    for (removing_ops) |op| {
        const op_name = op.wordName();
        const instrs = try alloc.alloc(Instruction, 7);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 0 };
        instrs[2] = .{ .op = .{ .call_word = op_name }, .line = 0 };
        instrs[3] = .{ .op = .{ .call_word = "swap" }, .line = 0 };
        instrs[4] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[5] = .{ .op = .{ .call_word = "native.virtual-wrap" }, .line = 0 };
        instrs[6] = .{ .op = .{ .call_word = "swap" }, .line = 0 };

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.nativeDispatchId(op),
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, value_mod.stringValue(op_name));
    }

    // #nth! -- Stack: typed-vec n elem
    // Body: push vtype-ptr, call native helper that handles the full
    // validate+unwrap+delegate+rewrap sequence
    {
        const instrs = try alloc.alloc(Instruction, 2);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-nth-mut-dispatch" }, .line = 0 };

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.nativeDispatchId(.nth_mut),
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, value_mod.stringValue("#nth!"));
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
            .dispatch_id = ctx.nativeDispatchId(.append_mut),
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, value_mod.stringValue("#append!"));
    }

    // freeze ( typed-vec -- typed-array )
    {
        const instrs = try alloc.alloc(Instruction, 2);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-freeze-dispatch" }, .line = 0 };

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.nativeDispatchId(.freeze),
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, value_mod.stringValue("freeze"));
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
            .dispatch_id = ctx.nativeDispatchId(.at_set_mut),
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, value_mod.stringValue("@set!"));
    }

    // @remove! ( typed-mmap key -- typed-mmap )
    {
        const instrs = try alloc.alloc(Instruction, 2);
        instrs[0] = .{ .op = .{ .push_literal = vtype_ptr }, .line = 0 };
        instrs[1] = .{ .op = .{ .call_word = "native.typed-at-remove-mut-dispatch" }, .line = 0 };

        try ctx.registerDispatch(.{
            .dispatch_id = ctx.nativeDispatchId(.at_remove_mut),
            .type_a = type_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);

        try generated_words.append(alloc, value_mod.stringValue("@remove!"));
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
        .dispatch_id = ctx.nativeDispatchId(.to_hash),
        .type_a = type_tv.descriptor.?,
        .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
    }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);
}
