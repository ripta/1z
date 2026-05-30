const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const StructInstance = value_mod.StructInstance;
const VirtualType = value_mod.VirtualType;
const Primitive = @import("types.zig").Primitive;
const RegistryEntry = @import("types.zig").RegistryEntry;
const helpers = @import("helpers.zig");

const popFixnum = helpers.popFixnum;

pub const primitives = [_]Primitive{
    .{ .name = "resolve", .stack_effect = "addr -- addrs", .doc = "DNS resolution; returns array of resolved addr values with IP addresses.", .func = nativeResolve, .capability = .io_net },
    .{ .name = "socket", .stack_effect = "addr -- fd", .doc = "Create socket; infers address family and type from addr variant.", .func = nativeSocket, .capability = .io_net },
    .{ .name = "bind", .stack_effect = "fd addr --", .doc = "Bind socket fd to resolved address.", .func = nativeBind, .capability = .io_net },
    .{ .name = "fd-close", .stack_effect = "fd --", .doc = "Close a raw file descriptor.", .func = nativeFdClose, .capability = .io_net },
    .{ .name = "udp-sendto", .stack_effect = "fd data addr -- n", .doc = "Send datagram to address; data is string or byte-array; returns bytes sent.", .func = nativeUdpSendto, .capability = .io_net },
    .{ .name = "udp-recvfrom", .stack_effect = "fd maxlen -- data host port", .doc = "Receive datagram; returns byte-array data, sender host string, and port.", .func = nativeUdpRecvfrom, .capability = .io_net },
    .{ .name = "udp-send", .stack_effect = "fd data -- n", .doc = "Send datagram on connected socket; data is string or byte-array; returns bytes sent.", .func = nativeUdpSend, .capability = .io_net },
    .{ .name = "udp-recv", .stack_effect = "fd maxlen -- data", .doc = "Receive datagram on connected socket; returns byte-array.", .func = nativeUdpRecv, .capability = .io_net },
    .{ .name = "inet-pton", .stack_effect = "family str -- bytes", .doc = "Parse IP address string to raw bytes; family is AF_INET (2) or AF_INET6 (30).", .func = nativeInetPton, .capability = .io_net },
    .{ .name = "sock-const", .stack_effect = "str -- n", .doc = "Look up a platform-correct socket constant by name.", .func = nativeSockConst, .capability = .io_net },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "listen", .func = nativeListen, .stack_effect = "fd backlog --", .capability = .io_net },
    .{ .name = "accept", .func = nativeAccept, .stack_effect = "fd -- fd host port", .capability = .io_net },
    .{ .name = "connect", .func = nativeConnect, .stack_effect = "fd addr --", .capability = .io_net },
    .{ .name = "setsockopt", .func = nativeSetsockopt, .stack_effect = "fd level optname value --", .capability = .io_net },
};

/// Addr variant info extracted from a tagged addr enum value.
const AddrInfo = struct {
    tag: *const VirtualType,
    host: []const u8 = "",
    port: i64 = 0,
    path: []const u8 = "",
    kind: AddrKind,
};

const AddrKind = enum { tcp, udp, unix };

/// Extract addr variant info from a tagged value on the stack.
fn extractAddr(ctx: *Context) !AddrInfo {
    const val = try ctx.stack.pop();
    return extractAddrFromValue(ctx, val);
}

fn extractAddrFromValue(ctx: *Context, val: Value) !AddrInfo {
    switch (val) {
        .tagged => |t| {
            const is_tcp = std.mem.eql(u8, t.tag.name, "addr:tcp");
            const is_udp = std.mem.eql(u8, t.tag.name, "addr:udp");
            const is_unix = std.mem.eql(u8, t.tag.name, "addr:unix");

            if (!is_tcp and !is_udp and !is_unix) {
                helpers.setErrorContext(ctx, "expected addr variant, got {s}", .{t.tag.name});
                return error.TypeMismatch;
            }

            switch (t.inner.*) {
                .struct_instance => |si| {
                    if (is_tcp or is_udp) {
                        if (si.fields.len < 2) {
                            helpers.setErrorContext(ctx, "addr struct has too few fields", .{});
                            return error.TypeMismatch;
                        }
                        const host = switch (si.fields[0]) {
                            .string => |s| s,
                            else => {
                                helpers.setErrorContext(ctx, "addr host field must be a string", .{});
                                return error.TypeMismatch;
                            },
                        };
                        const port = switch (si.fields[1]) {
                            .fixnum => |i| i,
                            else => {
                                helpers.setErrorContext(ctx, "addr port field must be a fixnum", .{});
                                return error.TypeMismatch;
                            },
                        };
                        return .{
                            .tag = t.tag,
                            .host = host,
                            .port = port,
                            .kind = if (is_tcp) .tcp else .udp,
                        };
                    } else {
                        if (si.fields.len < 1) {
                            helpers.setErrorContext(ctx, "addr:unix struct has too few fields", .{});
                            return error.TypeMismatch;
                        }
                        const path = switch (si.fields[0]) {
                            .string => |s| s,
                            else => {
                                helpers.setErrorContext(ctx, "addr:unix path field must be a string", .{});
                                return error.TypeMismatch;
                            },
                        };
                        return .{
                            .tag = t.tag,
                            .path = path,
                            .kind = .unix,
                        };
                    }
                },
                else => {
                    helpers.setErrorContext(ctx, "addr inner value must be a struct instance", .{});
                    return error.TypeMismatch;
                },
            }
        },
        else => {
            helpers.setTypeMismatchError(ctx, "addr", val);
            return error.TypeMismatch;
        },
    }
}

/// Build a std.net.Address from host string and port.
fn resolveHostPort(host: []const u8, port: u16) !std.net.Address {
    return std.net.Address.resolveIp(host, port) catch {
        return error.InvalidArgument;
    };
}

/// Build an addr:tcp or addr:udp tagged value with the given host string and port.
fn makeInetAddr(ctx: *Context, alloc: std.mem.Allocator, tag: *const VirtualType, host: []const u8, port: i64) !Value {
    const struct_type = tag.anon_struct orelse {
        helpers.setErrorContext(ctx, "addr tag '{s}' has no anonymous struct descriptor", .{tag.name});
        return error.TypeMismatch;
    };

    const fields = try alloc.alloc(Value, 2);
    fields[0] = .{ .string = host };
    fields[1] = .{ .fixnum = port };

    const instance = try alloc.create(StructInstance);
    instance.* = .{ .struct_type = struct_type, .fields = fields };

    const inner = try alloc.create(Value);
    inner.* = .{ .struct_instance = instance };

    return .{ .tagged = .{ .tag = tag, .inner = inner } };
}

/// resolve ( addr -- addrs )
///
/// Resolves an addr:tcp or addr:udp value to an array of addr:tcp/udp values with IP addresses.
/// For addr:unix, returns the same value in a single-element array.
fn nativeResolve(ctx: *Context) anyerror!void {
    const addr_info = try extractAddr(ctx);
    const alloc = ctx.quotationAllocator();

    switch (addr_info.kind) {
        .tcp, .udp => {
            if (addr_info.port < 0 or addr_info.port > 65535) {
                helpers.setErrorContext(ctx, "port must be 0-65535, got {d}", .{addr_info.port});
                return error.InvalidArgument;
            }
            const port: u16 = @intCast(addr_info.port);

            if (std.net.Address.resolveIp(addr_info.host, port)) |net_addr| {
                var ip_buf: [46]u8 = undefined;
                const ip_str = formatAddress(net_addr, &ip_buf);
                const host_copy = try alloc.dupe(u8, ip_str);
                const addr_val = try makeInetAddr(ctx, alloc, addr_info.tag, host_copy, addr_info.port);
                const arr = try alloc.alloc(Value, 1);
                arr[0] = addr_val;
                try ctx.stack.push(.{ .array = arr });
                return;
            } else |_| {}

            var results: std.ArrayListUnmanaged(Value) = .{};
            defer results.deinit(alloc);

            const list = std.net.getAddressList(alloc, addr_info.host, port) catch {
                helpers.setErrorContext(ctx, "DNS resolution failed for {s}", .{addr_info.host});
                return error.IOFailed;
            };
            defer list.deinit();

            for (list.addrs) |net_addr| {
                var ip_buf: [46]u8 = undefined;
                const ip_str = formatAddress(net_addr, &ip_buf);
                const host_copy = try alloc.dupe(u8, ip_str);
                const addr_val = try makeInetAddr(ctx, alloc, addr_info.tag, host_copy, addr_info.port);
                try results.append(alloc, addr_val);
            }

            if (results.items.len == 0) {
                helpers.setErrorContext(ctx, "no addresses found for {s}", .{addr_info.host});
                return error.IOFailed;
            }

            const arr = try alloc.dupe(Value, results.items);
            try ctx.stack.push(.{ .array = arr });
        },
        .unix => {
            const struct_type = addr_info.tag.anon_struct orelse {
                helpers.setErrorContext(ctx, "addr:unix tag has no anonymous struct descriptor", .{});
                return error.TypeMismatch;
            };

            const fields = try alloc.alloc(Value, 1);
            fields[0] = .{ .string = addr_info.path };

            const instance = try alloc.create(StructInstance);
            instance.* = .{ .struct_type = struct_type, .fields = fields };

            const inner = try alloc.create(Value);
            inner.* = .{ .struct_instance = instance };

            const addr_val = Value{ .tagged = .{ .tag = addr_info.tag, .inner = inner } };
            const arr = try alloc.alloc(Value, 1);
            arr[0] = addr_val;
            try ctx.stack.push(.{ .array = arr });
        },
    }
}

/// Format a std.net.Address as an IP string.
fn formatAddress(addr: std.net.Address, buf: *[46]u8) []const u8 {
    switch (addr.any.family) {
        std.posix.AF.INET => {
            const bytes = @as(*const [4]u8, @ptrCast(&addr.in.sa.addr));
            const result = std.fmt.bufPrint(buf, "{}.{}.{}.{}", .{
                bytes[0], bytes[1], bytes[2], bytes[3],
            }) catch return "0.0.0.0";
            return result;
        },
        std.posix.AF.INET6 => {
            const bytes = @as(*const [16]u8, @ptrCast(&addr.in6.sa.addr));
            const result = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
                bytes[0],  bytes[1],  bytes[2],  bytes[3],
                bytes[4],  bytes[5],  bytes[6],  bytes[7],
                bytes[8],  bytes[9],  bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15],
            }) catch return "::";
            return result;
        },
        else => return "0.0.0.0",
    }
}

/// socket ( addr -- fd )
fn nativeSocket(ctx: *Context) anyerror!void {
    const addr_info = try extractAddr(ctx);

    const family: u32 = switch (addr_info.kind) {
        .tcp, .udp => blk: {
            if (std.mem.indexOfScalar(u8, addr_info.host, ':') != null) {
                break :blk std.posix.AF.INET6;
            }
            break :blk std.posix.AF.INET;
        },
        .unix => std.posix.AF.UNIX,
    };

    const sock_type: u32 = switch (addr_info.kind) {
        .tcp => std.posix.SOCK.STREAM,
        .udp => std.posix.SOCK.DGRAM,
        .unix => std.posix.SOCK.STREAM,
    };

    const fd = std.posix.socket(family, sock_type | std.posix.SOCK.CLOEXEC, 0) catch {
        helpers.setErrorContext(ctx, "failed to create socket", .{});
        return error.IOFailed;
    };
    errdefer std.posix.close(fd);

    // quick server restart, babes
    if (addr_info.kind == .tcp or addr_info.kind == .udp) {
        const one = std.mem.toBytes(@as(c_int, 1));
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &one) catch {};
    }

    try ctx.stack.push(.{ .fixnum = @intCast(fd) });
}

/// bind ( fd addr -- )
fn nativeBind(ctx: *Context) anyerror!void {
    const addr_info = try extractAddr(ctx);
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;
    const fd: std.posix.fd_t = @intCast(fd_val);

    const sock_addr = try addrToSockaddr(ctx, addr_info);

    std.posix.bind(fd, &sock_addr.any, sock_addr.getOsSockLen()) catch |err| {
        switch (err) {
            error.AddressInUse => {
                helpers.setErrorContext(ctx, "address already in use", .{});
                return error.IOFailed;
            },
            error.AccessDenied => return error.PermissionDenied,
            else => {
                helpers.setErrorContext(ctx, "bind failed", .{});
                return error.IOFailed;
            },
        }
    };
}

/// listen ( fd backlog -- )
fn nativeListen(ctx: *Context) anyerror!void {
    const backlog_val = try popFixnum(ctx);
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;
    if (backlog_val < 0) return error.InvalidArgument;

    const fd: std.posix.fd_t = @intCast(fd_val);
    const backlog: u31 = @intCast(@min(backlog_val, std.math.maxInt(u31)));

    std.posix.listen(fd, backlog) catch {
        helpers.setErrorContext(ctx, "listen failed", .{});
        return error.IOFailed;
    };
}

/// accept ( fd -- fd host port )
fn nativeAccept(ctx: *Context) anyerror!void {
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;
    const fd: std.posix.fd_t = @intCast(fd_val);

    if (ctx.scheduler != null) {
        setNonBlocking(fd);
    }

    while (true) {
        var peer_addr: std.posix.sockaddr.storage = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);

        const client_fd = std.posix.accept(fd, @ptrCast(&peer_addr), &addr_len, std.posix.SOCK.CLOEXEC) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(fd, .read);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                clearNonBlocking(fd);
                continue;
            }
            helpers.setErrorContext(ctx, "accept failed", .{});
            return error.IOFailed;
        };

        try ctx.stack.push(.{ .fixnum = @intCast(client_fd) });

        const alloc = ctx.quotationAllocator();
        const net_addr = std.net.Address{ .any = @as(*const std.posix.sockaddr, @ptrCast(&peer_addr)).* };
        var ip_buf: [46]u8 = undefined;
        const ip_str = formatAddress(net_addr, &ip_buf);
        const host_copy = try alloc.dupe(u8, ip_str);
        try ctx.stack.push(.{ .string = host_copy });
        try ctx.stack.push(.{ .fixnum = @intCast(net_addr.getPort()) });
        return;
    }
}

/// connect ( fd addr -- )
fn nativeConnect(ctx: *Context) anyerror!void {
    const addr_info = try extractAddr(ctx);
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;
    const fd: std.posix.fd_t = @intCast(fd_val);

    const sock_addr = try addrToSockaddr(ctx, addr_info);

    if (ctx.scheduler != null) {
        setNonBlocking(fd);
    }

    std.posix.connect(fd, &sock_addr.any, sock_addr.getOsSockLen()) catch |err| {
        if (err == error.WouldBlock) {
            if (ctx.scheduler) |sched| {
                sched.ioSuspendCurrentTask(fd, .write);
                try helpers.checkCancellation(ctx);
                var err_buf: [4]u8 = undefined;
                std.posix.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, &err_buf) catch {
                    helpers.setErrorContext(ctx, "connect failed: could not check SO_ERROR", .{});
                    return error.IOFailed;
                };
                const so_err = std.mem.bytesToValue(c_int, &err_buf);
                if (so_err != 0) {
                    helpers.setErrorContext(ctx, "connect failed", .{});
                    return error.IOFailed;
                }
                return;
            }
            clearNonBlocking(fd);
            std.posix.connect(fd, &sock_addr.any, sock_addr.getOsSockLen()) catch {
                helpers.setErrorContext(ctx, "connect failed", .{});
                return error.IOFailed;
            };
            return;
        }
        switch (err) {
            error.ConnectionRefused => {
                helpers.setErrorContext(ctx, "connection refused", .{});
                return error.IOFailed;
            },
            error.AccessDenied => return error.PermissionDenied,
            else => {
                helpers.setErrorContext(ctx, "connect failed", .{});
                return error.IOFailed;
            },
        }
    };
}

/// fd-close ( fd -- )
fn nativeFdClose(ctx: *Context) anyerror!void {
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;
    const fd: std.posix.fd_t = @intCast(fd_val);
    std.posix.close(fd);
}

// =============================================================================
// UDP primitives
// =============================================================================

/// Extract data bytes from a string or byte-array value.
fn extractDataBytes(ctx: *Context, val: Value) ![]const u8 {
    return switch (val) {
        .byte_array => |ba| ba.slice(),
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string or byte-array", val);
            return error.TypeMismatch;
        },
    };
}

/// Create a ByteArray value from a slice of bytes.
fn makeBytesValue(alloc: std.mem.Allocator, data: []const u8) !Value {
    const ba = try value_mod.ByteArray.create(alloc);
    try ba.ensureTotalCapacity(alloc, data.len);
    for (data) |byte| {
        ba.appendAssumeCapacity(byte);
    }
    return .{ .byte_array = ba };
}

/// udp-sendto ( fd data addr -- n )
fn nativeUdpSendto(ctx: *Context) anyerror!void {
    const addr_info = try extractAddr(ctx);
    const data_val = try ctx.stack.pop();
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;
    const fd: std.posix.fd_t = @intCast(fd_val);

    const bytes = try extractDataBytes(ctx, data_val);
    const sock_addr = try addrToSockaddr(ctx, addr_info);

    if (ctx.scheduler != null) {
        setNonBlocking(fd);
    }

    while (true) {
        const n = std.posix.sendto(fd, bytes, 0, &sock_addr.any, sock_addr.getOsSockLen()) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(fd, .write);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                clearNonBlocking(fd);
                continue;
            }
            helpers.setErrorContext(ctx, "udp-sendto failed", .{});
            return error.IOFailed;
        };
        try ctx.stack.push(.{ .fixnum = @intCast(n) });
        return;
    }
}

/// udp-recvfrom ( fd maxlen -- data host port )
fn nativeUdpRecvfrom(ctx: *Context) anyerror!void {
    const maxlen = try popFixnum(ctx);
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;
    if (maxlen <= 0) return error.InvalidArgument;
    const fd: std.posix.fd_t = @intCast(fd_val);

    const alloc = ctx.quotationAllocator();
    const buffer = try alloc.alloc(u8, @intCast(maxlen));
    defer alloc.free(buffer);

    if (ctx.scheduler != null) {
        setNonBlocking(fd);
    }

    while (true) {
        var peer_addr: std.posix.sockaddr.storage = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);

        const n = std.posix.recvfrom(fd, buffer, 0, @ptrCast(&peer_addr), &addr_len) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(fd, .read);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                clearNonBlocking(fd);
                continue;
            }
            helpers.setErrorContext(ctx, "udp-recvfrom failed", .{});
            return error.IOFailed;
        };

        const data_val = try makeBytesValue(alloc, buffer[0..n]);
        try ctx.stack.push(data_val);

        const net_addr = std.net.Address{ .any = @as(*const std.posix.sockaddr, @ptrCast(&peer_addr)).* };
        var ip_buf: [46]u8 = undefined;
        const ip_str = formatAddress(net_addr, &ip_buf);
        const host_copy = try alloc.dupe(u8, ip_str);
        try ctx.stack.push(.{ .string = host_copy });
        try ctx.stack.push(.{ .fixnum = @intCast(net_addr.getPort()) });
        return;
    }
}

/// udp-send ( fd data -- n )
fn nativeUdpSend(ctx: *Context) anyerror!void {
    const data_val = try ctx.stack.pop();
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;
    const fd: std.posix.fd_t = @intCast(fd_val);

    const bytes = try extractDataBytes(ctx, data_val);

    if (ctx.scheduler != null) {
        setNonBlocking(fd);
    }

    while (true) {
        const n = std.posix.sendto(fd, bytes, 0, null, 0) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(fd, .write);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                clearNonBlocking(fd);
                continue;
            }
            helpers.setErrorContext(ctx, "udp-send failed", .{});
            return error.IOFailed;
        };
        try ctx.stack.push(.{ .fixnum = @intCast(n) });
        return;
    }
}

/// udp-recv ( fd maxlen -- data )
fn nativeUdpRecv(ctx: *Context) anyerror!void {
    const maxlen = try popFixnum(ctx);
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;
    if (maxlen <= 0) return error.InvalidArgument;
    const fd: std.posix.fd_t = @intCast(fd_val);

    const alloc = ctx.quotationAllocator();
    const buffer = try alloc.alloc(u8, @intCast(maxlen));
    defer alloc.free(buffer);

    if (ctx.scheduler != null) {
        setNonBlocking(fd);
    }

    while (true) {
        const n = std.posix.recvfrom(fd, buffer, 0, null, null) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(fd, .read);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                clearNonBlocking(fd);
                continue;
            }
            helpers.setErrorContext(ctx, "udp-recv failed", .{});
            return error.IOFailed;
        };
        const data_val = try makeBytesValue(alloc, buffer[0..n]);
        try ctx.stack.push(data_val);
        return;
    }
}

/// setsockopt ( fd level optname value -- )
fn nativeSetsockopt(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const optname_val = try popFixnum(ctx);
    const level_val = try popFixnum(ctx);
    const fd_val = try popFixnum(ctx);
    if (fd_val < 0) return error.InvalidArgument;

    const fd: std.posix.fd_t = @intCast(fd_val);
    const level: i32 = @intCast(level_val);
    const optname: u32 = @intCast(optname_val);

    switch (val) {
        .fixnum => |n| {
            const value_bytes = std.mem.toBytes(@as(c_int, @intCast(n)));
            std.posix.setsockopt(fd, level, optname, &value_bytes) catch {
                helpers.setErrorContext(ctx, "setsockopt failed", .{});
                return error.IOFailed;
            };
        },
        .byte_array => |ba| {
            std.posix.setsockopt(fd, level, optname, ba.slice()) catch {
                helpers.setErrorContext(ctx, "setsockopt failed", .{});
                return error.IOFailed;
            };
        },
        else => {
            helpers.setErrorContext(ctx, "setsockopt value must be fixnum or byte-array", .{});
            return error.TypeError;
        },
    }
}

/// inet-pton ( family str -- bytes )
fn nativeInetPton(ctx: *Context) anyerror!void {
    const str = try helpers.popString(ctx);
    const family = try popFixnum(ctx);
    const alloc = ctx.quotationAllocator();

    switch (family) {
        std.posix.AF.INET => {
            const addr = std.net.Address.parseIp4(str, 0) catch {
                helpers.setErrorContext(ctx, "invalid IPv4 address: {s}", .{str});
                return error.InvalidArgument;
            };
            const bytes: *const [4]u8 = @ptrCast(&addr.in.sa.addr);
            try ctx.stack.push(try makeBytesValue(alloc, bytes));
        },
        std.posix.AF.INET6 => {
            const addr = std.net.Address.parseIp6(str, 0) catch {
                helpers.setErrorContext(ctx, "invalid IPv6 address: {s}", .{str});
                return error.InvalidArgument;
            };
            const bytes: []const u8 = addr.in6.sa.addr[0..16];
            try ctx.stack.push(try makeBytesValue(alloc, bytes));
        },
        else => {
            helpers.setErrorContext(ctx, "inet-pton: unsupported address family {d}", .{family});
            return error.InvalidArgument;
        },
    }
}

/// sock-const ( str -- n )
fn nativeSockConst(ctx: *Context) anyerror!void {
    const name = try helpers.popString(ctx);

    const val: i64 = if (std.mem.eql(u8, name, "SOL_SOCKET"))
        std.posix.SOL.SOCKET
    else if (std.mem.eql(u8, name, "SO_REUSEADDR"))
        std.posix.SO.REUSEADDR
    else if (std.mem.eql(u8, name, "SO_BROADCAST"))
        std.posix.SO.BROADCAST
    else if (std.mem.eql(u8, name, "IPPROTO_IP"))
        std.c.IPPROTO.IP
    else if (std.mem.eql(u8, name, "IP_ADD_MEMBERSHIP"))
        ip_add_membership
    else if (std.mem.eql(u8, name, "IP_DROP_MEMBERSHIP"))
        ip_drop_membership
    else if (std.mem.eql(u8, name, "IP_MULTICAST_LOOP"))
        ip_multicast_loop
    else if (std.mem.eql(u8, name, "IP_MULTICAST_TTL"))
        ip_multicast_ttl
    else {
        helpers.setErrorContext(ctx, "unknown socket constant: {s}", .{name});
        return error.InvalidArgument;
    };

    try ctx.stack.push(.{ .fixnum = val });
}

const ip_add_membership: i64 = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => 12,
    .linux => 35,
    .freebsd, .netbsd, .openbsd, .dragonfly => 12,
    else => @compileError("unsupported OS for IP_ADD_MEMBERSHIP"),
};

const ip_drop_membership: i64 = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => 13,
    .linux => 36,
    .freebsd, .netbsd, .openbsd, .dragonfly => 13,
    else => @compileError("unsupported OS for IP_DROP_MEMBERSHIP"),
};

const ip_multicast_loop: i64 = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => 11,
    .linux => 34,
    .freebsd, .netbsd, .openbsd, .dragonfly => 11,
    else => @compileError("unsupported OS for IP_MULTICAST_LOOP"),
};

const ip_multicast_ttl: i64 = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => 10,
    .linux => 33,
    .freebsd, .netbsd, .openbsd, .dragonfly => 10,
    else => @compileError("unsupported OS for IP_MULTICAST_TTL"),
};

// =============================================================================
// Helpers
// =============================================================================

/// Convert an AddrInfo to a std.net.Address (sockaddr).
fn addrToSockaddr(ctx: *Context, info: AddrInfo) !std.net.Address {
    switch (info.kind) {
        .tcp, .udp => {
            if (info.port < 0 or info.port > 65535) {
                helpers.setErrorContext(ctx, "port must be 0-65535, got {d}", .{info.port});
                return error.InvalidArgument;
            }
            return resolveHostPort(info.host, @intCast(info.port));
        },
        .unix => {
            return std.net.Address.initUnix(info.path) catch {
                helpers.setErrorContext(ctx, "unix path too long", .{});
                return error.InvalidArgument;
            };
        },
    }
}

/// Set O_NONBLOCK on a raw file descriptor.
fn setNonBlocking(fd: std.posix.fd_t) void {
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
}

/// Clear O_NONBLOCK on a raw file descriptor.
fn clearNonBlocking(fd: std.posix.fd_t) void {
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = false;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
}
