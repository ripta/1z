const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Marker = value_mod.Marker;
const MutableMap = value_mod.MutableMap;
const Value = value_mod.Value;

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const helpers = @import("helpers.zig");
const markers_mod = @import("markers.zig");
const container_backing = @import("../container_backing.zig");

pub const primitives = [_]Primitive{
    .{ .name = "define-builtin-type", .stack_effect = "name: descriptor markers --", .doc = "Define a built-in type word from a descriptor map.", .func = nativeDefineBuiltinType },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "type-has-property?", .func = nativeTypeHasProperty, .stack_effect = "type property -- ?" },
    .{ .name = "type-members", .func = nativeTypeMembers, .stack_effect = "type -- array/f" },
    .{ .name = "type-name", .func = nativeTypeName, .stack_effect = "type -- string" },

    .{ .name = "descriptor-numeric?", .func = nativeDescriptorNumeric, .stack_effect = "descriptor -- ?" },
    .{ .name = "descriptor-exact?", .func = nativeDescriptorExact, .stack_effect = "descriptor -- ?" },
    .{ .name = "descriptor-integer?", .func = nativeDescriptorInteger, .stack_effect = "descriptor -- ?" },
    .{ .name = "descriptor-mutable?", .func = nativeDescriptorMutable, .stack_effect = "descriptor -- ?" },
    .{ .name = "descriptor-kind", .func = nativeDescriptorKind, .stack_effect = "descriptor -- symbol" },

    .{ .name = "descriptor-fields-raw", .func = nativeDescriptorFieldsRaw, .stack_effect = "descriptor -- array" },
    .{ .name = "descriptor-field-types-raw", .func = nativeDescriptorFieldTypesRaw, .stack_effect = "descriptor -- array" },
    .{ .name = "descriptor-inner-type-raw", .func = nativeDescriptorInnerTypeRaw, .stack_effect = "descriptor -- type" },
    .{ .name = "descriptor-parent-raw", .func = nativeDescriptorParentRaw, .stack_effect = "descriptor -- type" },
    .{ .name = "descriptor-variants-raw", .func = nativeDescriptorVariantsRaw, .stack_effect = "descriptor -- array" },
    .{ .name = "descriptor-type-params-raw", .func = nativeDescriptorTypeParamsRaw, .stack_effect = "descriptor -- array" },
    .{ .name = "descriptor-resource-kind-raw", .func = nativeDescriptorResourceKindRaw, .stack_effect = "descriptor -- string" },
    .{ .name = "descriptor-ffi-layout-raw", .func = nativeDescriptorFfiLayoutRaw, .stack_effect = "descriptor -- fixnum" },
};

/// define-builtin-type ( name: descriptor markers -- )
///
/// Invoked through the descriptor-driven `;` protocol: the descriptor's `define:` quotation
/// calls this native after `;` has pushed name, descriptor, and the collected markers array.
///
/// If a TypeValue for this name was pre-created by Context.initBuiltinTypeValues(), the existing
/// object is augmented with the descriptor, preserving pointer identity. Otherwise a new TypeValue
/// is allocated and registered. The resulting word is defined as a parse-time, const, typed
/// compound that pushes the TypeValue literal.
fn nativeDefineBuiltinType(ctx: *Context) anyerror!void {
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
    const source_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };

    const name_val = try ctx.stack.pop();
    defer container_backing.releaseValue(name_val);
    // The name escapes into the long-lived TypeValue and word definition.
    const name = switch (name_val) {
        .symbol => |s| try alloc.dupe(u8, s.bytes),
        else => {
            helpers.setTypeMismatchError(ctx, "symbol (word name)", name_val);
            return error.TypeMismatch;
        },
    };

    const tv = if (ctx.lookupBuiltinTypeValue(name)) |existing| blk: {
        if (existing.descriptor) |existing_desc| {
            applyDescriptorMerge(existing_desc, source_map);
            break :blk existing;
        }
        const new_desc = try value_mod.createBuiltinTypeDescriptor(alloc, .{});
        applyDescriptorMerge(new_desc, source_map);
        existing.descriptor = new_desc;
        break :blk existing;
    } else blk: {
        const new_desc = try value_mod.createBuiltinTypeDescriptor(alloc, .{});
        applyDescriptorMerge(new_desc, source_map);
        const new_tv = try alloc.create(value_mod.TypeValue);
        new_tv.* = .{ .name = name, .descriptor = new_desc };
        try ctx.registerBuiltinTypeValue(name, new_tv);
        break :blk new_tv;
    };

    try ctx.registerTypeDescriptor(name, tv.descriptor.?);

    var markers_list = std.ArrayListUnmanaged(*Marker){};
    var has_parse_time = false;
    var has_const = false;
    var has_typed = false;
    for (markers_array) |m| {
        switch (m) {
            .marker => |mk| {
                try markers_list.append(alloc, mk);
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
    if (!has_parse_time) try markers_list.append(alloc, @constCast(&markers_mod.parse_time_marker));
    if (!has_const) try markers_list.append(alloc, @constCast(&markers_mod.const_marker));
    if (!has_typed) try markers_list.append(alloc, @constCast(&markers_mod.typed_marker));
    const type_markers = try markers_list.toOwnedSlice(alloc);

    const type_instrs = try alloc.alloc(Instruction, 1);
    type_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .parse_time = true,
        .stack_effect = try helpers.makeBoxedEffect(alloc, "-- type"),
        .markers = type_markers,
        .provenance = .{ .generator = "builtin-type", .parent = name, .role = "type" },
        .action = .{ .compound = type_instrs },
    });
}

/// Only the universal boolean keys are recognized; the legacy `type` key was the kind
/// discriminator and is no longer stored as a string. Unknown keys are silently ignored,
/// mirroring the previous put-everything behavior, since no reader consumed keys beyond the
/// bools.
fn applyDescriptorMerge(desc: *value_mod.TypeDescriptor, source: *const value_mod.MutableMap) void {
    var iter = source.map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (val != .boolean) continue;
        const b = val.boolean;
        const std_mem = @import("std").mem;
        if (std_mem.eql(u8, key, "numeric")) desc.numeric = b;
        if (std_mem.eql(u8, key, "exact")) desc.exact = b;
        if (std_mem.eql(u8, key, "integer")) desc.integer = b;
        if (std_mem.eql(u8, key, "mutable")) desc.mutable = b;
    }
}

/// native.type-has-property? ( type property -- bool ) - Check whether a type's descriptor
/// reports the given property. Always true for `type` (the kind discriminator is always
/// present), the four universal boolean flags when set, and the kind-specific scalar
/// fields when they carry a non-default payload. Other property names return false.
fn nativeTypeHasProperty(ctx: *Context) anyerror!void {
    const prop_val = try ctx.stack.pop();
    defer container_backing.releaseValue(prop_val);
    const prop_str = switch (prop_val) {
        .symbol, .string => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or string", prop_val);
            return error.TypeMismatch;
        },
    };

    const type_val = try ctx.stack.pop();
    defer container_backing.releaseValue(type_val);
    switch (type_val) {
        .type_val => |tv| {
            const desc = tv.descriptor orelse unreachable;
            const std_mem = @import("std").mem;
            const result = blk: {
                if (std_mem.eql(u8, prop_str, "type")) break :blk true;
                if (std_mem.eql(u8, prop_str, "numeric")) break :blk desc.numeric;
                if (std_mem.eql(u8, prop_str, "exact")) break :blk desc.exact;
                if (std_mem.eql(u8, prop_str, "integer")) break :blk desc.integer;
                if (std_mem.eql(u8, prop_str, "mutable")) break :blk desc.mutable;
                switch (desc.kind) {
                    .resource => |rd| {
                        if (std_mem.eql(u8, prop_str, "resource-kind")) break :blk rd.resource_kind.len != 0;
                    },
                    .ffi_struct => |fsd| {
                        if (std_mem.eql(u8, prop_str, "fields")) break :blk fsd.fields.len != 0;
                        if (std_mem.eql(u8, prop_str, "ffi-layout")) break :blk fsd.ffi_layout != 0;
                    },
                    .struct_ => |sd| {
                        if (std_mem.eql(u8, prop_str, "fields")) break :blk sd.fields.len != 0;
                        if (std_mem.eql(u8, prop_str, "field-types")) break :blk sd.field_types.len != 0;
                    },
                    .virtual => |vd| {
                        if (std_mem.eql(u8, prop_str, "inner-type")) break :blk vd.inner_type != null or vd.anon_struct != null;
                        if (std_mem.eql(u8, prop_str, "element-type")) break :blk vd.type_params.len != 0;
                    },
                    .enum_ => |ed| {
                        if (std_mem.eql(u8, prop_str, "variants")) break :blk ed.variants.len != 0;
                    },
                    .enum_variant => |evd| {
                        if (std_mem.eql(u8, prop_str, "parent")) break :blk evd.parent != null;
                        if (std_mem.eql(u8, prop_str, "inner-type")) break :blk evd.inner_type != null;
                    },
                    else => {},
                }
                break :blk false;
            };
            try ctx.stack.push(.{ .boolean = result });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "type", type_val);
            return error.TypeMismatch;
        },
    }
}

/// native.type-name ( type -- string )
///
/// Accepting both a type value and a protocol descriptor keeps stack-effect display uniform
/// across concrete-type and protocol-bound annotations.
fn nativeTypeName(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .type_val => |tv| {
            try ctx.stack.push(value_mod.stringValue(tv.name));
        },
        .protocol_descriptor => |pd| {
            try ctx.stack.push(value_mod.stringValue(pd.name));
        },
        else => {
            helpers.setTypeMismatchError(ctx, "type", val);
            return error.TypeMismatch;
        },
    }
}

/// native.type-members ( type -- array/f ) - Return member type values for a union type, or f otherwise.
fn nativeTypeMembers(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .type_val => |tv| {
            if (tv.member_types) |members| {
                const arr = try ctx.quotationAllocator().alloc(value_mod.Value, members.len);
                for (members, 0..) |member, i| {
                    arr[i] = .{ .type_val = @constCast(member) };
                }
                try helpers.pushAdoptedArray(ctx, ctx.quotationAllocator(), arr);
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            helpers.setTypeMismatchError(ctx, "type", val);
            return error.TypeMismatch;
        },
    }
}

/// Used by the twelve descriptor accessors below.
fn popDescriptor(ctx: *Context) anyerror!*const value_mod.TypeDescriptor {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    return switch (val) {
        .type_descriptor => |desc| desc,
        else => {
            helpers.setTypeMismatchError(ctx, "type-descriptor", val);
            return error.TypeMismatch;
        },
    };
}

fn setKindMismatch(ctx: *Context, expected: []const u8, desc: *const value_mod.TypeDescriptor) void {
    helpers.setErrorContext(
        ctx,
        "expected {s} descriptor, got {s}",
        .{ expected, value_mod.typeKindSymbol(desc.kind) },
    );
}

fn nativeDescriptorNumeric(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    try ctx.stack.push(.{ .boolean = desc.numeric });
}

fn nativeDescriptorExact(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    try ctx.stack.push(.{ .boolean = desc.exact });
}

fn nativeDescriptorInteger(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    try ctx.stack.push(.{ .boolean = desc.integer });
}

fn nativeDescriptorMutable(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    try ctx.stack.push(.{ .boolean = desc.mutable });
}

fn nativeDescriptorKind(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    try ctx.stack.push(value_mod.symbolValue(value_mod.typeKindSymbol(desc.kind)));
}

/// descriptor-fields-raw ( descriptor -- array )
/// struct: field names; ffi_struct: field names; virtual with anon_struct:
/// anon_struct's field names. Throws TypeMismatch on any other kind.
fn nativeDescriptorFieldsRaw(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    const alloc = ctx.quotationAllocator();
    const fields: []const []const u8 = switch (desc.kind) {
        .struct_ => |sd| sd.fields,
        .ffi_struct => |fsd| fsd.fields,
        .virtual => |vd| if (vd.anon_struct) |st| st.fields else {
            setKindMismatch(ctx, "struct, ffi-struct, or struct-backed virtual", desc);
            return error.TypeMismatch;
        },
        else => {
            setKindMismatch(ctx, "struct, ffi-struct, or struct-backed virtual", desc);
            return error.TypeMismatch;
        },
    };
    const arr = try alloc.alloc(value_mod.Value, fields.len);
    for (fields, 0..) |name, i| arr[i] = value_mod.stringValue(name);
    try helpers.pushAdoptedArray(ctx, alloc, arr);
}

/// descriptor-field-types-raw ( descriptor -- array )
/// Returns an array of type values for the descriptor's field-type
/// annotations. Throws on kind mismatch and on descriptors that carry no
/// annotations (e.g., untyped struct).
fn nativeDescriptorFieldTypesRaw(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    const alloc = ctx.quotationAllocator();

    // Struct and struct-backed virtual field types carry full constraint
    // elements; FFI struct fields are concrete C types.
    const element_types: ?[]const ?value_mod.ConstraintCombinator.Element = switch (desc.kind) {
        .struct_ => |sd| sd.field_types,
        .virtual => |vd| if (vd.anon_struct) |st| st.field_types else null,
        else => null,
    };

    const arr: []value_mod.Value = blk: {
        if (element_types) |elements| {
            if (elements.len == 0) {
                helpers.setErrorContext(ctx, "descriptor has no field-type annotations", .{});
                return error.TypeMismatch;
            }
            const out = try alloc.alloc(value_mod.Value, elements.len);
            for (elements, 0..) |element, i| {
                out[i] = if (element) |e| switch (e) {
                    .type => |tv| .{ .type_val = @constCast(tv) },
                    .protocol => |pd| .{ .protocol_descriptor = pd },
                    .combinator => |cc| .{ .constraint_combinator = cc },
                } else .{ .boolean = false };
            }
            break :blk out;
        }

        const fsd = switch (desc.kind) {
            .ffi_struct => |f| f,
            else => {
                setKindMismatch(ctx, "struct, ffi-struct, or struct-backed virtual", desc);
                return error.TypeMismatch;
            },
        };
        if (fsd.field_types.len == 0) {
            helpers.setErrorContext(ctx, "descriptor has no field-type annotations", .{});
            return error.TypeMismatch;
        }
        const out = try alloc.alloc(value_mod.Value, fsd.field_types.len);
        for (fsd.field_types, 0..) |t, i| {
            out[i] = if (t) |tv| .{ .type_val = @constCast(tv) } else .{ .boolean = false };
        }
        break :blk out;
    };

    try helpers.pushAdoptedArray(ctx, alloc, arr);
}

/// descriptor-inner-type-raw ( descriptor -- type )
/// virtual with inner_type or enum_variant with inner_type: returns that
/// TypeValue. Struct-backed virtual (anon_struct without inner_type) throws.
fn nativeDescriptorInnerTypeRaw(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    const tv: *const value_mod.TypeValue = switch (desc.kind) {
        .virtual => |vd| vd.inner_type orelse {
            setKindMismatch(ctx, "virtual with inner-type or enum-variant", desc);
            return error.TypeMismatch;
        },
        .enum_variant => |evd| evd.inner_type orelse {
            setKindMismatch(ctx, "virtual with inner-type or enum-variant", desc);
            return error.TypeMismatch;
        },
        else => {
            setKindMismatch(ctx, "virtual with inner-type or enum-variant", desc);
            return error.TypeMismatch;
        },
    };
    try ctx.stack.push(.{ .type_val = @constCast(tv) });
}

/// descriptor-parent-raw ( descriptor -- type )
/// enum_variant with parent: returns that TypeValue. Else throws.
fn nativeDescriptorParentRaw(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    const tv: *const value_mod.TypeValue = switch (desc.kind) {
        .enum_variant => |evd| evd.parent orelse {
            setKindMismatch(ctx, "enum-variant", desc);
            return error.TypeMismatch;
        },
        else => {
            setKindMismatch(ctx, "enum-variant", desc);
            return error.TypeMismatch;
        },
    };
    try ctx.stack.push(.{ .type_val = @constCast(tv) });
}

/// descriptor-type-params-raw ( descriptor -- array )
/// struct_: returns the declared parameter holes. virtual: returns the bound
/// `type_params` tuple (concrete types and still-open parameter holes). enum_:
/// returns the enum's declared parameter holes. Throws on a descriptor with no
/// parameters or an unsupported kind.
fn nativeDescriptorTypeParamsRaw(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    const alloc = ctx.quotationAllocator();

    const params: []const *const value_mod.TypeValue = switch (desc.kind) {
        .struct_ => |sd| sd.type_params,
        .virtual => |vd| vd.type_params,
        .enum_ => |ed| ed.type_params,
        else => {
            setKindMismatch(ctx, "struct, parameterized virtual, or enum", desc);
            return error.TypeMismatch;
        },
    };
    if (params.len == 0) {
        helpers.setErrorContext(ctx, "descriptor has no type parameters", .{});
        return error.TypeMismatch;
    }

    const out = try alloc.alloc(value_mod.Value, params.len);
    for (params, 0..) |p, i| out[i] = .{ .type_val = @constCast(p) };
    try helpers.pushAdoptedArray(ctx, alloc, out);
}

/// descriptor-variants-raw ( descriptor -- array )
/// enum_: returns an array of 2-element arrays { name-symbol type-val }.
/// Variants whose type_val is null get the `unit` TypeValue as the type slot.
fn nativeDescriptorVariantsRaw(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    const variants = switch (desc.kind) {
        .enum_ => |ed| ed.variants,
        else => {
            setKindMismatch(ctx, "enum", desc);
            return error.TypeMismatch;
        },
    };
    const alloc = ctx.quotationAllocator();
    const unit_tv = ctx.lookupBuiltinTypeValueByTag(.unit) orelse unreachable;
    const arr = try alloc.alloc(value_mod.Value, variants.len);
    for (variants, 0..) |v, i| {
        const pair = try alloc.alloc(value_mod.Value, 2);
        pair[0] = value_mod.symbolValue(v.name);
        pair[1] = .{ .type_val = if (v.type_val) |tv| @constCast(tv) else unit_tv };
        arr[i] = .{ .array = try value_mod.Array.fromOwnedSlice(alloc, pair) };
    }
    try helpers.pushAdoptedArray(ctx, alloc, arr);
}

/// descriptor-resource-kind-raw ( descriptor -- string )
/// resource kind with a non-empty resource_kind: returns the string. Else throws.
fn nativeDescriptorResourceKindRaw(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    const kind_name: []const u8 = switch (desc.kind) {
        .resource => |rd| rd.resource_kind,
        else => {
            setKindMismatch(ctx, "resource", desc);
            return error.TypeMismatch;
        },
    };
    if (kind_name.len == 0) {
        setKindMismatch(ctx, "resource with non-empty resource-kind", desc);
        return error.TypeMismatch;
    }
    try ctx.stack.push(value_mod.stringValue(kind_name));
}

/// descriptor-ffi-layout-raw ( descriptor -- fixnum )
/// ffi_struct with non-zero ffi_layout: returns the layout pointer as fixnum.
fn nativeDescriptorFfiLayoutRaw(ctx: *Context) anyerror!void {
    const desc = try popDescriptor(ctx);
    const layout: usize = switch (desc.kind) {
        .ffi_struct => |fsd| fsd.ffi_layout,
        else => {
            setKindMismatch(ctx, "ffi-struct", desc);
            return error.TypeMismatch;
        },
    };
    if (layout == 0) {
        setKindMismatch(ctx, "ffi-struct with non-zero layout", desc);
        return error.TypeMismatch;
    }
    try ctx.stack.push(.{ .fixnum = @intCast(layout) });
}

const testing = std.testing;

test "native type-members returns members for union types" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const union_tv = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ fixnum_tv, string_tv });

    try ctx.stack.push(.{ .type_val = union_tv });
    try nativeTypeMembers(&ctx);

    const result = try ctx.stack.pop();
    try testing.expect(result == .array);
    try testing.expectEqual(@as(usize, 2), result.array.items.len);
    try testing.expect(result.array.items[0] == .type_val);
    try testing.expect(result.array.items[1] == .type_val);
}

fn fixnumDescriptor(ctx: *Context) *const value_mod.TypeDescriptor {
    return ctx.lookupBuiltinTypeValue("fixnum").?.descriptor.?;
}

test "descriptor-numeric? returns the descriptor's numeric flag" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(.{ .type_descriptor = fixnumDescriptor(&ctx) });
    try nativeDescriptorNumeric(&ctx);
    try testing.expectEqual(true, (try ctx.stack.pop()).boolean);

    const string_desc = ctx.lookupBuiltinTypeValue("string").?.descriptor.?;
    try ctx.stack.push(.{ .type_descriptor = string_desc });
    try nativeDescriptorNumeric(&ctx);
    try testing.expectEqual(false, (try ctx.stack.pop()).boolean);
}

test "descriptor-numeric? type-mismatches non-descriptors" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 42 });
    try testing.expectError(error.TypeMismatch, nativeDescriptorNumeric(&ctx));
}

test "descriptor-kind returns the kind symbol" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(.{ .type_descriptor = fixnumDescriptor(&ctx) });
    try nativeDescriptorKind(&ctx);
    const result = try ctx.stack.pop();
    try testing.expectEqualStrings("builtin-type", result.symbol.bytes);
}

test "descriptor-fields-raw returns struct field names" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    const fields = [_][]const u8{ "x", "y" };
    const no_ft: []const ?value_mod.ConstraintCombinator.Element = &.{};
    const desc = try ctx.getOrCreateStructDescriptor(&fields, no_ft, false);

    try ctx.stack.push(.{ .type_descriptor = desc });
    try nativeDescriptorFieldsRaw(&ctx);

    const result = try ctx.stack.pop();
    try testing.expect(result == .array);
    try testing.expectEqual(@as(usize, 2), result.array.items.len);
    try testing.expectEqualStrings("x", result.array.items[0].string.bytes);
    try testing.expectEqualStrings("y", result.array.items[1].string.bytes);
}

test "descriptor-fields-raw throws on builtin descriptor" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(.{ .type_descriptor = fixnumDescriptor(&ctx) });
    try testing.expectError(error.TypeMismatch, nativeDescriptorFieldsRaw(&ctx));
}

test "descriptor-field-types-raw throws on untyped struct" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    const fields = [_][]const u8{ "x", "y" };
    const no_ft: []const ?value_mod.ConstraintCombinator.Element = &.{};
    const desc = try ctx.getOrCreateStructDescriptor(&fields, no_ft, false);

    try ctx.stack.push(.{ .type_descriptor = desc });
    try testing.expectError(error.TypeMismatch, nativeDescriptorFieldTypesRaw(&ctx));
}

test "descriptor-field-types-raw returns typed struct field types" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const fields = [_][]const u8{ "x", "y" };
    const ft = [_]?value_mod.ConstraintCombinator.Element{ .{ .type = fixnum_tv }, .{ .type = string_tv } };
    const desc = try ctx.getOrCreateStructDescriptor(&fields, &ft, false);

    try ctx.stack.push(.{ .type_descriptor = desc });
    try nativeDescriptorFieldTypesRaw(&ctx);

    const result = try ctx.stack.pop();
    try testing.expect(result == .array);
    try testing.expectEqual(@as(usize, 2), result.array.items.len);
    try testing.expect(result.array.items[0] == .type_val);
    try testing.expect(result.array.items[1] == .type_val);
    try testing.expectEqualStrings("fixnum", result.array.items[0].type_val.name);
    try testing.expectEqualStrings("string", result.array.items[1].type_val.name);
}

test "descriptor-inner-type-raw throws on builtin and on struct" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(.{ .type_descriptor = fixnumDescriptor(&ctx) });
    try testing.expectError(error.TypeMismatch, nativeDescriptorInnerTypeRaw(&ctx));

    const fields = [_][]const u8{"x"};
    const no_ft: []const ?value_mod.ConstraintCombinator.Element = &.{};
    const struct_desc = try ctx.getOrCreateStructDescriptor(&fields, no_ft, false);
    try ctx.stack.push(.{ .type_descriptor = struct_desc });
    try testing.expectError(error.TypeMismatch, nativeDescriptorInnerTypeRaw(&ctx));
}

test "descriptor-parent-raw throws on non-enum-variant kinds" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(.{ .type_descriptor = fixnumDescriptor(&ctx) });
    try testing.expectError(error.TypeMismatch, nativeDescriptorParentRaw(&ctx));
}

test "descriptor-variants-raw throws on non-enum kinds" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(.{ .type_descriptor = fixnumDescriptor(&ctx) });
    try testing.expectError(error.TypeMismatch, nativeDescriptorVariantsRaw(&ctx));
}

test "descriptor-resource-kind-raw throws on non-resource kinds" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(.{ .type_descriptor = fixnumDescriptor(&ctx) });
    try testing.expectError(error.TypeMismatch, nativeDescriptorResourceKindRaw(&ctx));
}

test "descriptor-ffi-layout-raw throws on non-ffi-struct kinds" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(.{ .type_descriptor = fixnumDescriptor(&ctx) });
    try testing.expectError(error.TypeMismatch, nativeDescriptorFfiLayoutRaw(&ctx));
}

test "descriptor-variants-raw returns name/type pair arrays for enums" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const unit_tv = ctx.lookupBuiltinTypeValueByTag(.unit).?;
    const alloc = ctx.quotationAllocator();
    const variants = try alloc.alloc(value_mod.Variant, 2);
    variants[0] = .{ .name = "red", .type_val = fixnum_tv };
    variants[1] = .{ .name = "blue", .type_val = null };
    const desc = try value_mod.createTypeDescriptor(
        alloc,
        .{ .enum_ = .{ .variants = variants } },
        .{},
    );

    try ctx.stack.push(.{ .type_descriptor = desc });
    try nativeDescriptorVariantsRaw(&ctx);

    const result = try ctx.stack.pop();
    try testing.expect(result == .array);
    try testing.expectEqual(@as(usize, 2), result.array.items.len);
    const first = result.array.items[0];
    try testing.expect(first == .array);
    try testing.expectEqual(@as(usize, 2), first.array.items.len);
    try testing.expectEqualStrings("red", first.array.items[0].symbol.bytes);
    try testing.expectEqualStrings("fixnum", first.array.items[1].type_val.name);
    const second = result.array.items[1];
    try testing.expectEqualStrings("blue", second.array.items[0].symbol.bytes);
    try testing.expect(second.array.items[1].type_val == unit_tv);
}
