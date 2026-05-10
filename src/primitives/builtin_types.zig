const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");

const types_mod = @import("types.zig");
const RegistryEntry = types_mod.RegistryEntry;

const helpers = @import("helpers.zig");
const markers_mod = @import("markers.zig");

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "define-builtin-type", .func = nativeDefineBuiltinType },
    .{ .name = "type-has-property?", .func = nativeTypeHasProperty, .stack_effect = "type property -- ?" },
    .{ .name = "type-members", .func = nativeTypeMembers, .stack_effect = "type -- array/f" },
    .{ .name = "type-name", .func = nativeTypeName, .stack_effect = "type -- string" },
};

/// define-builtin-type ( descriptor -- marker marker marker type ) - Create a type value from a descriptor,
/// deriving the name from the word-name symbol already on the stack. Pushes parse-time, const, and typed
/// markers so `;` sees them automatically.
///
/// If a TypeValue for this name was pre-created by Context.initBuiltinTypeValues(),
/// the existing object is augmented with the descriptor (preserving pointer identity).
/// Otherwise a new TypeValue is allocated and registered.
fn nativeDefineBuiltinType(ctx: *Context) anyerror!void {
    const desc_val = try ctx.stack.pop();
    const source_map: *value_mod.MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };

    const name_val = try ctx.stack.peek();
    const name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol (word name)", name_val);
            return error.TypeMismatch;
        },
    };

    const alloc = ctx.quotationAllocator();

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

    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.parse_time_marker) });
    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.const_marker) });
    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.typed_marker) });
    try ctx.stack.push(.{ .type_val = tv });
}

/// Merge the user-supplied mutable-map descriptor into a typed
/// TypeDescriptor. Only the universal boolean keys are recognised;
/// the legacy `type` key was the kind discriminator and is no longer
/// stored as a string. Unknown keys are silently ignored (mirroring
/// the previous put-everything behavior, since no reader consumed
/// keys beyond the bools).
fn applyDescriptorMerge(desc: *value_mod.TypeDescriptor, source: *const value_mod.MutableMap) void {
    var iter = source.iterator();
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
    const prop_str = switch (prop_val) {
        .symbol, .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or string", prop_val);
            return error.TypeMismatch;
        },
    };

    const type_val = try ctx.stack.pop();
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

/// native.type-name ( type -- string ) - Extract the name string from a type value.
fn nativeTypeName(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .type_val => |tv| {
            try ctx.stack.push(.{ .string = tv.name });
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
    switch (val) {
        .type_val => |tv| {
            if (tv.member_types) |members| {
                const arr = try ctx.quotationAllocator().alloc(value_mod.Value, members.len);
                for (members, 0..) |member, i| {
                    arr[i] = .{ .type_val = @constCast(member) };
                }
                try ctx.stack.push(.{ .array = arr });
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

const std = @import("std");
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
    try testing.expectEqual(@as(usize, 2), result.array.len);
    try testing.expect(result.array[0] == .type_val);
    try testing.expect(result.array[1] == .type_val);
}
