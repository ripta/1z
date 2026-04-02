const std = @import("std");

const Context = @import("../context.zig").Context;

const value_mod = @import("../value.zig");
const dispatch = @import("../dispatch.zig");
const helpers = @import("helpers.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

pub const primitives = [_]Primitive{
    .{ .name = "type-of", .stack_effect = "val -- type", .doc = "Return the type of a value as a first-class type value.", .func = nativeTypeOf },
    .{ .name = "instance-of?", .stack_effect = "val type -- ?", .doc = "Check whether a value is an instance of the given type. For enum variants, also matches the parent enum type.", .func = nativeInstanceOf },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "borrowed?", .func = nativeBorrowed, .stack_effect = "val -- ?" },
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

fn nativeBorrowed(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .boolean = valueIsBorrowed(val) });
}

fn valueIsBorrowed(val: value_mod.Value) bool {
    return switch (val) {
        .byte_array => |ba| ba.isBorrowed(),
        .tagged => |tagged| blk: {
            if (!std.mem.startsWith(u8, tagged.tag.name, "packed-")) break :blk false;
            break :blk switch (tagged.inner.*) {
                .byte_array => |ba| ba.isBorrowed(),
                else => false,
            };
        },
        else => false,
    };
}

test "borrowed? reports byte-array and packed backing ownership" {
    var owned_bytes = [_]u8{ 1, 2, 3, 4 };
    var borrowed_bytes = [_]u8{ 5, 6, 7, 8 };
    var owned_ba = value_mod.ByteArray{
        .items = owned_bytes[0..],
        .owned_items = .{
            .items = owned_bytes[0..],
            .capacity = owned_bytes.len,
        },
        .storage = .owned,
    };
    var borrowed_ba = value_mod.ByteArray{
        .items = borrowed_bytes[0..],
        .storage = .{
            .borrowed = borrowed_bytes[0..],
        },
    };

    const packed_type = value_mod.VirtualType{
        .name = "packed-u8",
        .inner_type = "byte-array",
    };
    const owned_inner = value_mod.Value{ .byte_array = &owned_ba };
    const borrowed_inner = value_mod.Value{ .byte_array = &borrowed_ba };

    try std.testing.expect(!valueIsBorrowed(.{ .byte_array = &owned_ba }));
    try std.testing.expect(valueIsBorrowed(.{ .byte_array = &borrowed_ba }));
    try std.testing.expect(!valueIsBorrowed(.{ .tagged = .{ .tag = &packed_type, .inner = &owned_inner } }));
    try std.testing.expect(valueIsBorrowed(.{ .tagged = .{ .tag = &packed_type, .inner = &borrowed_inner } }));
    try std.testing.expect(!valueIsBorrowed(.{ .fixnum = 42 }));
}
