const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");

const types_mod = @import("types.zig");
const RegistryEntry = types_mod.RegistryEntry;

const helpers = @import("helpers.zig");
const markers_mod = @import("markers.zig");

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "define-builtin-type", .func = nativeDefineBuiltinType },
};

/// define-builtin-type ( descriptor -- marker marker type ) - Create a type value from a descriptor,
/// deriving the name from the word-name symbol already on the stack. Pushes parse-time and const
/// markers so `;` sees them automatically.
fn nativeDefineBuiltinType(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const desc_val = try ctx.stack.pop();
    const descriptor = switch (desc_val) {
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

    const tv = try alloc.create(value_mod.TypeValue);
    tv.* = .{ .name = name, .descriptor = descriptor };

    try ctx.type_descriptors.put(ctx.allocator, name, descriptor);

    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.parse_time_marker) });
    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.const_marker) });
    try ctx.stack.push(.{ .type_val = tv });
}
