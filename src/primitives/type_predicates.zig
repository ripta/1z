const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const dispatch = @import("../dispatch.zig");
const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "type-of", .stack_effect = "val -- type", .doc = "Return the type of a value as a first-class type value.", .func = nativeTypeOf },
};

/// type-of ( val -- type ) - Return the type of a value as a first-class type value.
///
/// For tagged values (virtual types), returns the TypeValue stored on the VirtualType.
/// For struct instances, returns the TypeValue stored on the StructType.
/// For resources, lazily creates and caches a TypeValue by the resource's type name.
/// For all other types, looks up the TypeValue by dispatch type name, walking the
/// parent context chain to find built-in type registrations from the prelude.
fn nativeTypeOf(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();

    // Tagged values: follow VirtualType.type_val
    if (val == .tagged) {
        if (val.tagged.tag.type_val) |tv| {
            try ctx.stack.push(.{ .type_val = tv });
            return;
        }
    }

    // Struct instances: follow StructType.type_val
    if (val == .struct_instance) {
        if (val.struct_instance.struct_type.type_val) |tv| {
            try ctx.stack.push(.{ .type_val = tv });
            return;
        }
    }

    // Resources: lazily create and cache TypeValue by resource type name
    if (val == .resource) {
        const type_name = val.resource.type_name;
        if (ctx.lookupResourceTypeValue(type_name)) |tv| {
            try ctx.stack.push(.{ .type_val = tv });
            return;
        }
        const alloc = ctx.quotationAllocator();
        const tv = try alloc.create(value_mod.TypeValue);
        tv.* = .{ .name = type_name, .descriptor = null };
        try ctx.resource_type_values.put(ctx.allocator, type_name, tv);
        try ctx.stack.push(.{ .type_val = tv });
        return;
    }

    // Built-in types: lookup by dispatch type name, walking parent context chain
    const type_name = dispatch.dispatchTypeName(val);
    if (ctx.lookupBuiltinTypeValue(type_name)) |tv| {
        try ctx.stack.push(.{ .type_val = tv });
        return;
    }

    // Fallback: during early bootstrap before define-builtin-type runs,
    // return a symbol as before.
    try ctx.stack.push(.{ .symbol = type_name });
}
