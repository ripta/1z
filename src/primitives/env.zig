const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const HashTable = value_mod.HashTable;

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "environ", .stack_effect = "-- hash", .doc = "Return a fresh hash of current environment variables.", .func = nativeEnviron },
    .{ .name = "sys-info", .stack_effect = "-- hash", .doc = "Return a hash of system/platform information.", .func = nativeSysInfo },
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

/// sys-info ( -- hash ) - Return a hash of system/platform information
fn nativeSysInfo(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const hash = alloc.create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    const target = builtin.target;

    // "os" - e.g. "macos", "linux", "windows"
    const os_name = @tagName(target.os.tag);
    const os_key = alloc.dupe(u8, "os") catch return error.OutOfMemory;
    const os_val = alloc.dupe(u8, os_name) catch return error.OutOfMemory;
    hash.put(alloc, os_key, .{ .string = os_val }) catch return error.OutOfMemory;

    // "arch" - e.g. "aarch64", "x86_64"
    const arch_name = @tagName(target.cpu.arch);
    const arch_key = alloc.dupe(u8, "arch") catch return error.OutOfMemory;
    const arch_val = alloc.dupe(u8, arch_name) catch return error.OutOfMemory;
    hash.put(alloc, arch_key, .{ .string = arch_val }) catch return error.OutOfMemory;

    // "abi" - e.g. "none", "gnu", "musl"
    const abi_name = @tagName(target.abi);
    const abi_key = alloc.dupe(u8, "abi") catch return error.OutOfMemory;
    const abi_val = alloc.dupe(u8, abi_name) catch return error.OutOfMemory;
    hash.put(alloc, abi_key, .{ .string = abi_val }) catch return error.OutOfMemory;

    // "endian" - "little" or "big"
    const endian_name = switch (target.cpu.arch.endian()) {
        .little => "little",
        .big => "big",
    };
    const endian_key = alloc.dupe(u8, "endian") catch return error.OutOfMemory;
    const endian_val = alloc.dupe(u8, endian_name) catch return error.OutOfMemory;
    hash.put(alloc, endian_key, .{ .string = endian_val }) catch return error.OutOfMemory;

    // "ptr-width" - 32 or 64
    const pw_key = alloc.dupe(u8, "ptr-width") catch return error.OutOfMemory;
    hash.put(alloc, pw_key, .{ .integer = target.ptrBitWidth() }) catch return error.OutOfMemory;

    // "os-family" - "unix", "windows", or "other"
    const os_family = if (target.os.tag == .windows) "windows" else if (target.os.tag.isDarwin() or target.os.tag == .linux or target.os.tag == .freebsd or target.os.tag == .openbsd or target.os.tag == .netbsd or target.os.tag == .dragonfly or target.os.tag == .solaris) "unix" else "other";
    const fam_key = alloc.dupe(u8, "os-family") catch return error.OutOfMemory;
    const fam_val = alloc.dupe(u8, os_family) catch return error.OutOfMemory;
    hash.put(alloc, fam_key, .{ .string = fam_val }) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .hash = hash });
}
