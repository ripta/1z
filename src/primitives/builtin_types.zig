const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");

const types_mod = @import("types.zig");
const RegistryEntry = types_mod.RegistryEntry;

const helpers = @import("helpers.zig");
const markers_mod = @import("markers.zig");

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "define-builtin-type", .func = nativeDefineBuiltinType },
    .{ .name = "type-has-property?", .func = nativeTypeHasProperty },
    .{ .name = "type-name", .func = nativeTypeName },
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
    const descriptor: *value_mod.HashTable = switch (desc_val) {
        .mutable_map => |m| @ptrCast(m),
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

    const tv = if (ctx.lookupBuiltinTypeValue(name)) |existing| blk: {
        if (existing.descriptor != null) {
            helpers.setErrorContext(ctx, "builtin type '{s}' already has a descriptor attached", .{name});
            return error.InvalidArgument;
        }
        existing.descriptor = descriptor;
        break :blk existing;
    } else blk: {
        const alloc = ctx.quotationAllocator();
        const new_tv = try alloc.create(value_mod.TypeValue);
        new_tv.* = .{ .name = name, .descriptor = descriptor };
        try ctx.registerBuiltinTypeValue(name, new_tv);
        break :blk new_tv;
    };

    try ctx.registerTypeDescriptor(name, descriptor);

    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.parse_time_marker) });
    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.const_marker) });
    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.typed_marker) });
    try ctx.stack.push(.{ .type_val = tv });
}

/// native.type-has-property? ( type property -- bool ) - Check whether a type's descriptor contains a given property key.
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
            const result = if (tv.descriptor) |desc|
                desc.get(prop_str) != null
            else
                false;
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
