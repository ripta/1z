const std = @import("std");

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Resource = value_mod.Resource;
const Primitive = @import("types.zig").Primitive;
const RegistryEntry = @import("types.zig").RegistryEntry;
const helpers = @import("helpers.zig");

pub const primitives = [_]Primitive{};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "tls-config", .func = nativeTlsConfig },
    .{ .name = "tls-config-no-verify", .func = nativeTlsConfigNoVerify },
};

/// Heap-allocated TLS configuration holding an optional CA bundle.
const TlsConfig = struct {
    bundle: ?std.crypto.Certificate.Bundle,
    verify: bool,
    allocator: std.mem.Allocator,
};

fn tlsConfigCloseFn(ptr: *anyopaque) void {
    const config: *TlsConfig = @ptrCast(@alignCast(ptr));
    if (config.bundle) |*b| {
        b.deinit(config.allocator);
    }
}

/// tls-config ( -- resource )
fn nativeTlsConfig(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();

    const config = try alloc.create(TlsConfig);
    config.* = .{
        .bundle = .{},
        .verify = true,
        .allocator = alloc,
    };

    config.bundle.?.rescan(alloc) catch {
        helpers.setErrorContext(ctx, "failed to load system CA certificates", .{});
        return error.IOFailed;
    };

    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "tls-config",
        .ptr = @ptrCast(config),
        .closed = false,
        .close_fn = .{ .native = tlsConfigCloseFn },
    };
    try ctx.stack.push(.{ .resource = r });
}

/// tls-config-no-verify ( -- resource )
fn nativeTlsConfigNoVerify(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();

    const config = try alloc.create(TlsConfig);
    config.* = .{
        .bundle = null,
        .verify = false,
        .allocator = alloc,
    };

    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "tls-config",
        .ptr = @ptrCast(config),
        .closed = false,
        .close_fn = .{ .native = tlsConfigCloseFn },
    };
    try ctx.stack.push(.{ .resource = r });
}
