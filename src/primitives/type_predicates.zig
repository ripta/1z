const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const dispatch = @import("../dispatch.zig");
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "type-of", .stack_effect = "val -- type", .doc = "Return the type of a value as a first-class type value.", .func = nativeTypeOf },
    .{ .name = "instance-of?", .stack_effect = "val type -- ?", .doc = "Check whether a value is an instance of the given type. For enum variants, also matches the parent enum type.", .func = nativeInstanceOf },
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
        try ctx.registerResourceTypeValue(type_name, tv);
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

/// instance-of? ( val type -- ? ) - Check whether a value is an instance of the given type.
///
/// Compare the value's TypeValue pointer against the given type using pointer identity.
/// For tagged values with a `parent_type`, e.g., enum variants, also check whether the
/// parent enum type matches.
fn nativeInstanceOf(ctx: *Context) anyerror!void {
    const tv = try helpers.popAs(.type_val, ctx);
    const val = try ctx.stack.pop();

    const val_tv: ?*const value_mod.TypeValue = blk: {
        if (val == .tagged) {
            break :blk val.tagged.tag.type_val;
        }
        if (val == .struct_instance) {
            break :blk val.struct_instance.struct_type.type_val;
        }
        if (val == .resource) {
            break :blk ctx.lookupResourceTypeValue(val.resource.type_name);
        }
        break :blk ctx.lookupBuiltinTypeValue(dispatch.dispatchTypeName(val));
    };

    if (val_tv) |vt| {
        if (vt == tv) {
            try ctx.stack.push(.{ .boolean = true });
            return;
        }
    }

    if (val == .tagged) {
        if (val.tagged.tag.parent_type) |pt| {
            if (pt == tv) {
                try ctx.stack.push(.{ .boolean = true });
                return;
            }
        }
        if (val.tagged.tag.base_type) |bt| {
            if (bt == tv) {
                try ctx.stack.push(.{ .boolean = true });
                return;
            }
        }
    }

    try ctx.stack.push(.{ .boolean = false });
}
