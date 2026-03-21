const std = @import("std");

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Stream = value_mod.Stream;
const Resource = value_mod.Resource;
const Primitive = @import("types.zig").Primitive;
const RegistryEntry = @import("types.zig").RegistryEntry;
const helpers = @import("helpers.zig");

pub const primitives = [_]Primitive{};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "tls-config", .func = nativeTlsConfig },
    .{ .name = "tls-config-no-verify", .func = nativeTlsConfigNoVerify },
    .{ .name = "tls-upgrade", .func = nativeTlsUpgrade },
};

/// Heap-allocated TLS configuration holding an optional CA bundle.
const TlsConfig = struct {
    bundle: ?std.crypto.Certificate.Bundle,
    verify: bool,
    allocator: std.mem.Allocator,
};

/// TLS session state, stored as an opaque pointer on the Stream.
pub const TlsState = struct {
    client: std.crypto.tls.Client,
    transport_reader: std.fs.File.Reader,
    transport_writer: std.fs.File.Writer,
    fd: std.posix.fd_t,
    read_buf: []u8,
    write_buf: []u8,
    transport_read_buf: []u8,
    transport_write_buf: []u8,
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

/// tls-upgrade ( stream config hostname -- stream )
///
/// Upgrades a stream to TLS using the provided configuration and hostname for
/// verification. The stream must not already have TLS enabled. The TLS state
/// is stored as an opaque pointer on the Stream struct.
///
/// The TLS handshake is performed synchronously, so the stream's fd is temporarily
/// set to blocking mode if it was non-blocking. After the handshake, the original
/// non-blocking mode is restored. This allows the handshake to complete without
/// needing to be resumable, while still supporting non-blocking streams in general.
///
/// If the handshake fails, an error is returned and the original stream is left unchanged.
/// On success, a new stream with the same underlying file and TLS enabled is pushed
/// onto the stack. The original stream remains unchanged.
fn nativeTlsUpgrade(ctx: *Context) anyerror!void {
    const hostname = try helpers.popString(ctx);
    const config_val = try ctx.stack.pop();
    const stream = try helpers.popStream(ctx);

    const resource = switch (config_val) {
        .tagged => |t| switch (t.inner.*) {
            .resource => |r| r,
            else => {
                helpers.setTypeMismatchError(ctx, "tls-config", config_val);
                return error.TypeMismatch;
            },
        },
        .resource => |r| r,
        else => {
            helpers.setTypeMismatchError(ctx, "tls-config", config_val);
            return error.TypeMismatch;
        },
    };

    if (!std.mem.eql(u8, resource.type_name, "tls-config")) {
        helpers.setTypeMismatchError(ctx, "tls-config", config_val);
        return error.TypeMismatch;
    }

    const config: *TlsConfig = @ptrCast(@alignCast(resource.ptr orelse {
        helpers.setErrorContext(ctx, "tls-config resource is closed", .{});
        return error.IOFailed;
    }));

    if (stream.closed) {
        helpers.setErrorContext(ctx, "stream is closed", .{});
        return error.IOFailed;
    }

    if (stream.tls != null) {
        helpers.setErrorContext(ctx, "stream already has TLS", .{});
        return error.IOFailed;
    }

    const alloc = ctx.arena.allocator();
    const fd = stream.file.handle;

    const tls_state = try alloc.create(TlsState);
    const read_buf = try alloc.alloc(u8, std.crypto.tls.max_ciphertext_record_len);
    const write_buf = try alloc.alloc(u8, std.crypto.tls.max_ciphertext_record_len);
    const transport_read_buf = try alloc.alloc(u8, std.crypto.tls.max_ciphertext_record_len);
    const transport_write_buf = try alloc.alloc(u8, std.crypto.tls.max_ciphertext_record_len);

    const file = std.fs.File{ .handle = fd };

    tls_state.fd = fd;
    tls_state.read_buf = read_buf;
    tls_state.write_buf = write_buf;
    tls_state.transport_read_buf = transport_read_buf;
    tls_state.transport_write_buf = transport_write_buf;
    tls_state.transport_reader = file.readerStreaming(transport_read_buf);
    tls_state.transport_writer = file.writerStreaming(transport_write_buf);

    // If the fd is nonblocking (scheduler active), temporarily restore blocking
    // for the handshake since Client.init is not resumable mid-handshake.
    const was_nonblocking = stream.nonblocking_set;
    if (was_nonblocking) {
        clearNonBlocking(fd);
    }

    tls_state.client = std.crypto.tls.Client.init(
        &tls_state.transport_reader.interface,
        &tls_state.transport_writer.interface,
        .{
            .host = if (config.verify) .{ .explicit = hostname } else .no_verification,
            .ca = if (config.verify)
                .{ .bundle = config.bundle.? }
            else
                .no_verification,
            .read_buffer = read_buf,
            .write_buffer = write_buf,
            .allow_truncation_attacks = true,
        },
    ) catch |err| {
        if (was_nonblocking) {
            setNonBlocking(fd);
        }
        helpers.setErrorContext(ctx, "TLS handshake failed: {s}", .{@errorName(err)});
        return error.IOFailed;
    };

    if (was_nonblocking) {
        setNonBlocking(fd);
    }

    const new_stream = try alloc.create(Stream);
    new_stream.* = .{
        .file = file,
        .mode = stream.mode,
        .name = stream.name,
        .nonblocking_set = was_nonblocking,
        .tls = @ptrCast(tls_state),
    };

    try ctx.stack.push(.{ .stream = new_stream });
}

/// Flush TLS writer, sending any buffered encrypted data to the transport.
pub fn tlsFlush(tls_state: *TlsState) !void {
    tls_state.client.writer.flush() catch {
        return error.IOFailed;
    };
    tls_state.transport_writer.interface.flush() catch {
        return error.IOFailed;
    };
}

fn setNonBlocking(fd: std.posix.fd_t) void {
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
}

fn clearNonBlocking(fd: std.posix.fd_t) void {
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = false;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
}
