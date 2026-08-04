const std = @import("std");
const builtin = @import("builtin");

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const container_backing = @import("../container_backing.zig");
const Stream = value_mod.Stream;
const StreamVTable = value_mod.StreamVTable;
const Resource = value_mod.Resource;
const Primitive = @import("types.zig").Primitive;
const RegistryEntry = @import("types.zig").RegistryEntry;
const helpers = @import("helpers.zig");
const streams_mod = @import("streams.zig");

const is_freestanding = builtin.os.tag == .freestanding;

pub const primitives = [_]Primitive{};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "tls-config", .func = nativeTlsConfig, .capability = .io_net },
    .{ .name = "tls-config-add-ca-pem", .func = nativeTlsConfigAddCaPem, .capability = .io_net },
    .{ .name = "tls-config-no-verify", .func = nativeTlsConfigNoVerify, .capability = .io_net },
    .{ .name = "tls-upgrade", .func = nativeTlsUpgrade, .capability = .io_net },
};

/// Heap-allocated TLS configuration holding an optional CA bundle.
const TlsConfig = struct {
    bundle: ?std.crypto.Certificate.Bundle,
    verify: bool,
    allocator: std.mem.Allocator,
};

/// TLS session state, stored as `impl` on the wrapper stream.
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

// =============================================================================
// TLS stream vtable
// =============================================================================

const tls_vtable = StreamVTable{
    .read = tlsRead,
    .write = tlsWrite,
    .close = tlsClose,
    .flush = tlsFlush,
};

fn tlsRead(stream: *Stream, buffer: []u8, ctx: *Context) anyerror!usize {
    const tls_state: *TlsState = @ptrCast(@alignCast(stream.impl.?));
    while (true) {
        return tls_state.client.reader.readSliceShort(buffer) catch {
            if (ctx.scheduler) |sched| {
                sched.ioSuspendCurrentTask(tls_state.fd, .read);
                try helpers.checkCancellation(ctx);
                continue;
            }
            return error.IOFailed;
        };
    }
}

fn tlsWrite(stream: *Stream, bytes: []const u8, ctx: *Context) anyerror!usize {
    const tls_state: *TlsState = @ptrCast(@alignCast(stream.impl.?));
    while (true) {
        const n = tls_state.client.writer.write(bytes) catch |err| switch (err) {
            error.WriteFailed => {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(tls_state.fd, .write);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                return error.IOFailed;
            },
        };
        tls_state.client.writer.flush() catch |err| switch (err) {
            error.WriteFailed => {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(tls_state.fd, .write);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                return error.IOFailed;
            },
        };
        tls_state.transport_writer.interface.flush() catch |err| switch (err) {
            error.WriteFailed => {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(tls_state.fd, .write);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                return error.IOFailed;
            },
        };
        return n;
    }
}

fn tlsClose(stream: *Stream) void {
    if (stream.impl) |impl_ptr| {
        const tls_state: *TlsState = @ptrCast(@alignCast(impl_ptr));
        tlsFlushState(tls_state) catch {};
        stream.impl = null;
    }
    if (stream.inner) |inner| {
        inner.vtable.close(inner);
    }
}

fn tlsFlush(stream: *Stream) anyerror!void {
    if (stream.impl) |impl_ptr| {
        const tls_state: *TlsState = @ptrCast(@alignCast(impl_ptr));
        try tlsFlushState(tls_state);
    }
    if (stream.inner) |inner| {
        try inner.vtable.flush(inner);
    }
}

/// Flush TLS writer, sending any buffered encrypted data to the transport.
fn tlsFlushState(tls_state: *TlsState) !void {
    tls_state.client.writer.flush() catch {
        return error.IOFailed;
    };
    tls_state.transport_writer.interface.flush() catch {
        return error.IOFailed;
    };
}

// =============================================================================
// Helpers
// =============================================================================

/// Extract a TlsConfig pointer from a value that is either a bare resource or
/// a tagged (virtual-type-wrapped) resource with type_name "tls-config".
fn extractTlsConfig(ctx: *Context, val: Value) !*TlsConfig {
    const resource = switch (val) {
        .tagged => |t| switch (t.inner.*) {
            .resource => |r| r,
            else => {
                helpers.setTypeMismatchError(ctx, "tls-config", val);
                return error.TypeMismatch;
            },
        },
        .resource => |r| r,
        else => {
            helpers.setTypeMismatchError(ctx, "tls-config", val);
            return error.TypeMismatch;
        },
    };

    if (!std.mem.eql(u8, resource.type_name, "tls-config")) {
        helpers.setTypeMismatchError(ctx, "tls-config", val);
        return error.TypeMismatch;
    }

    return @ptrCast(@alignCast(resource.ptr orelse {
        helpers.setErrorContext(ctx, "tls-config resource is closed", .{});
        return error.IOFailed;
    }));
}

// =============================================================================
// TLS config and upgrade primitives
// =============================================================================

/// tls-config ( -- resource )
fn nativeTlsConfig(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "tls-config");
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
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "tls-config-no-verify");
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

/// tls-config-add-ca-pem ( resource pem-data -- resource )
///
/// pem-data may contain multiple concatenated PEM certificates. Works on a no-verify
/// config, initializing its (null) bundle first.
fn nativeTlsConfigAddCaPem(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "tls-config-add-ca-pem");
    const pem_val = try ctx.stack.pop();
    defer container_backing.releaseValue(pem_val);
    const pem_data: []const u8 = switch (pem_val) {
        .string => |s| s.bytes,
        .byte_array => |ba| ba.slice(),
        else => {
            helpers.setTypeMismatchError(ctx, "string or byte-array", pem_val);
            return error.TypeMismatch;
        },
    };
    const config_val = try ctx.stack.pop();
    const config = try extractTlsConfig(ctx, config_val);
    const alloc = config.allocator;

    if (config.bundle == null) {
        config.bundle = .{};
    }

    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const now_sec = std.time.timestamp();
    const base64_decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");

    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, pem_data, start_index, begin_marker)) |begin_marker_start| {
        const cert_start = begin_marker_start + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem_data, cert_start, end_marker) orelse {
            helpers.setErrorContext(ctx, "PEM data has BEGIN marker without matching END marker", .{});
            return error.InvalidArgument;
        };
        start_index = cert_end + end_marker.len;
        const encoded_cert = std.mem.trim(u8, pem_data[cert_start..cert_end], " \t\r\n");

        const decoded_start: u32 = @intCast(config.bundle.?.bytes.items.len);
        const decoded_size_upper = encoded_cert.len / 4 * 3 + 4;
        try config.bundle.?.bytes.ensureUnusedCapacity(alloc, decoded_size_upper);
        const dest_buf = config.bundle.?.bytes.allocatedSlice()[decoded_start..];
        config.bundle.?.bytes.items.len += base64_decoder.decode(dest_buf, encoded_cert) catch {
            helpers.setErrorContext(ctx, "PEM certificate contains invalid base64 data", .{});
            return error.InvalidArgument;
        };
        config.bundle.?.parseCert(alloc, decoded_start, now_sec) catch {
            config.bundle.?.bytes.items.len = decoded_start;
        };
    }

    try ctx.stack.push(config_val);
}

/// tls-upgrade ( stream config hostname -- stream )
///
/// The stream must not already be a TLS wrapper. The resulting stream delegates I/O
/// through the TLS vtable and chains to the original stream via the `inner` pointer.
fn nativeTlsUpgrade(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "tls-upgrade");
    const hostname_pay = try helpers.popString(ctx);
    defer container_backing.releaseValue(.{ .string = hostname_pay });
    const config_val = try ctx.stack.pop();
    const stream = try helpers.popStream(ctx);

    const config = try extractTlsConfig(ctx, config_val);

    if (stream.closed) {
        helpers.setErrorContext(ctx, "stream is closed", .{});
        return error.IOFailed;
    }

    if (stream.vtable == &tls_vtable) {
        helpers.setErrorContext(ctx, "stream already has TLS", .{});
        return error.IOFailed;
    }

    const alloc = ctx.arena.allocator();
    const fd = stream.fd;

    // The TLS client retains the verification hostname for the connection's lifetime.
    const hostname = try alloc.dupe(u8, hostname_pay.bytes);

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
        streams_mod.clearNonBlockingFd(fd);
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
            streams_mod.setNonBlockingFd(fd);
        }
        helpers.setErrorContext(ctx, "TLS handshake failed: {s}", .{@errorName(err)});
        return error.IOFailed;
    };

    if (was_nonblocking) {
        streams_mod.setNonBlockingFd(fd);
    }

    const new_stream = try alloc.create(Stream);
    new_stream.* = .{
        .vtable = &tls_vtable,
        .fd = fd,
        .mode = stream.mode,
        .name = "tls",
        .nonblocking_set = was_nonblocking,
        .impl = @ptrCast(tls_state),
        .inner = stream,
    };

    try ctx.stack.push(.{ .stream = new_stream });
}
