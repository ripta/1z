const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const HashTable = value_mod.HashTable;

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "environ", .stack_effect = "-- hash", .func = nativeEnviron },
};

/// environ ( -- hash ) - Return a fresh hash of current environment variables
fn nativeEnviron(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const hash = alloc.create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    const env_map = std.process.getEnvMap(alloc) catch return error.OutOfMemory;
    var iter = env_map.iterator();
    while (iter.next()) |entry| {
        const key = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
        const val_str = alloc.dupe(u8, entry.value_ptr.*) catch return error.OutOfMemory;
        hash.put(alloc, key, .{ .string = val_str }) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .hash = hash });
}
