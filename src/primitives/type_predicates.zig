const Context = @import("../context.zig").Context;
const dispatch = @import("../dispatch.zig");
const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "type-of", .stack_effect = "val -- symbol", .doc = "Return type of value as a symbol.", .func = nativeTypeOf },
};

/// type-of ( val -- symbol ) - Return type of value as a symbol
fn nativeTypeOf(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const type_name = dispatch.dispatchTypeName(val);
    try ctx.stack.push(.{ .symbol = type_name });
}
