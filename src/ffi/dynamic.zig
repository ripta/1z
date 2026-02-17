const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../context.zig").Context;
const helpers = @import("../primitives/helpers.zig");
const error_mapping = @import("../primitives/error_mapping.zig");
const RegistryEntry = @import("../primitives/types.zig").RegistryEntry;
const Resource = @import("../value.zig").Resource;

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "lib-open", .func = nativeLibOpen },
    .{ .name = "lib-symbol", .func = nativeLibSymbol },
};

fn dylibCloseFn(ptr: *anyopaque) void {
    const dl: *std.DynLib = @ptrCast(@alignCast(ptr));
    dl.close();
}

fn isExplicitPath(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return true;
    if (std.mem.endsWith(u8, name, ".dylib")) return true;
    if (std.mem.endsWith(u8, name, ".so")) return true;
    if (std.mem.endsWith(u8, name, ".dll")) return true;
    return false;
}

fn allocPrintZ(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const str = try std.fmt.allocPrint(alloc, fmt, args);
    const buf = try alloc.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

fn nativeLibOpen(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();
    const name = try helpers.popString(ctx);

    const open_name: [:0]const u8 = if (isExplicitPath(name))
        try alloc.dupeZ(u8, name)
    else switch (builtin.os.tag) {
        .macos => try allocPrintZ(alloc, "lib{s}.dylib", .{name}),
        .linux => try allocPrintZ(alloc, "lib{s}.so", .{name}),
        .windows => try allocPrintZ(alloc, "{s}.dll", .{name}),
        else => try alloc.dupeZ(u8, name),
    };

    const dynlib_ptr = try alloc.create(std.DynLib);
    dynlib_ptr.* = std.DynLib.open(open_name) catch {
        helpers.setErrorContext(ctx, "library not found: {s}", .{open_name});
        return error.FFILibraryNotFound;
    };

    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "dylib",
        .ptr = @ptrCast(dynlib_ptr),
        .closed = false,
        .close_fn = dylibCloseFn,
    };
    try ctx.stack.push(.{ .resource = r });
}

fn nativeLibSymbol(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();
    const name = try helpers.popString(ctx);
    const lib_resource = try helpers.popResource(ctx);
    try error_mapping.ensureResourceOpen(lib_resource);

    if (!std.mem.eql(u8, lib_resource.type_name, "dylib")) {
        helpers.setTypeMismatchError(ctx, "dylib resource", .{ .resource = lib_resource });
        return error.TypeMismatch;
    }

    const dynlib_ptr: *std.DynLib = @ptrCast(@alignCast(lib_resource.ptr.?));
    const name_z = try alloc.dupeZ(u8, name);

    const sym = dynlib_ptr.lookup(*anyopaque, name_z) orelse {
        helpers.setErrorContext(ctx, "symbol not found: {s}", .{name});
        return error.FFISymbolNotFound;
    };

    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "ffi-fn",
        .ptr = sym,
        .closed = false,
        .close_fn = null,
    };
    try ctx.stack.push(.{ .resource = r });
}
