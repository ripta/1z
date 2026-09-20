const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const ValueMap = value_mod.ValueMap;
const MutableValueMap = value_mod.MutableValueMap;

const container_backing = @import("../container_backing.zig");
const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "<value-map>", .stack_effect = " -- value-map", .doc = "Create an empty immutable value-keyed map.\n\nExample: <value-map> value-map? => t", .func = nativeMakeValueMap },
    .{ .name = "<mutable-value-map>", .stack_effect = " -- mutable-value-map", .doc = "Create an empty mutable value-keyed map.\n\nExample: <mutable-value-map> freeze type-of => value-map", .func = nativeMakeMutableValueMap },
};

/// <value-map> ( -- value-map )
fn nativeMakeValueMap(ctx: *Context) anyerror!void {
    const map = ValueMap.create(ctx.allocator) catch return error.OutOfMemory;
    ctx.stack.pushMoved(.{ .value_map = map }) catch |err| {
        container_backing.releaseValue(.{ .value_map = map });
        return err;
    };
}

/// <mutable-value-map> ( -- mutable-value-map )
fn nativeMakeMutableValueMap(ctx: *Context) anyerror!void {
    const map = MutableValueMap.create(ctx.allocator) catch return error.OutOfMemory;
    ctx.stack.pushMoved(.{ .mutable_value_map = map }) catch |err| {
        container_backing.releaseValue(.{ .mutable_value_map = map });
        return err;
    };
}
