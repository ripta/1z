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
/// Delegates to `dispatchTypeValue` which handles all value variants:
/// tagged (VirtualType.type_val), struct instances (StructType.type_val),
/// resources (lazy TypeValue creation), and builtins (discriminant-indexed
/// array lookup).
fn nativeTypeOf(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const tv = dispatch.dispatchTypeValue(val, ctx);
    try ctx.stack.push(.{ .type_val = tv });
}

/// instance-of? ( val type -- ? ) - Check whether a value is an instance of the given type.
///
/// Compare the value's TypeValue pointer against the given type using pointer identity.
/// For tagged values with a `parent_type`, e.g., enum variants, also check whether the
/// parent enum type matches.
fn nativeInstanceOf(ctx: *Context) anyerror!void {
    const tv = try helpers.popAs(.type_val, ctx);
    const val = try ctx.stack.pop();

    const val_tv: *const value_mod.TypeValue = dispatch.dispatchTypeValue(val, ctx);

    if (val_tv == tv) {
        try ctx.stack.push(.{ .boolean = true });
        return;
    }

    // For tagged values, also check parent (enum) and base (parameterized) types.
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
