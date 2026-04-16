const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Stream = value_mod.Stream;
const StructInstance = value_mod.StructInstance;
const VirtualType = value_mod.VirtualType;

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");

const popFixnum = helpers.popFixnum;

pub const primitives = [_]Primitive{
    .{ .name = "resolve", .stack_effect = "addr -- addrs", .doc = "DNS resolution; returns array of resolved addr values with IP addresses.", .func = nativeResolve },
    .{ .name = "socket", .stack_effect = "addr -- fd", .doc = "Create socket; infers address family and type from addr variant.", .func = nativeSocket },
    .{ .name = "bind", .stack_effect = "fd addr --", .doc = "Bind socket fd to resolved address.", .func = nativeBind },
    .{ .name = "listen", .stack_effect = "fd backlog --", .doc = "Mark socket as listening with given backlog.", .func = nativeListen },
    .{ .name = "accept", .stack_effect = "fd -- fd addr", .doc = "Accept connection; returns client fd and peer addr.", .func = nativeAccept },
    .{ .name = "connect", .stack_effect = "fd addr --", .doc = "Connect socket to resolved address.", .func = nativeConnect },
    .{ .name = "fd-close", .stack_effect = "fd --", .doc = "Close a raw file descriptor.", .func = nativeFdClose },
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

/// accept ( fd -- fd addr )
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
        const peer_val = try sockaddrToAddrValue(alloc, net_addr, ctx);
        try ctx.stack.push(peer_val);
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

/// Convert a peer sockaddr to an addr:tcp tagged value.
fn sockaddrToAddrValue(alloc: std.mem.Allocator, addr: std.net.Address, ctx: *Context) !Value {
    var ip_buf: [46]u8 = undefined;
    const ip_str = formatAddress(addr, &ip_buf);
    const host_copy = try alloc.dupe(u8, ip_str);
    const port: i64 = @intCast(addr.getPort());

    const tag = findAddrTcpType(ctx) orelse {
        helpers.setErrorContext(ctx, "addr:tcp type not found in dictionary", .{});
        return error.IOFailed;
    };

    return makeInetAddr(ctx, alloc, tag, host_copy, port);
}

/// Find the addr:tcp VirtualType by inspecting the >addr:tcp word definition.
fn findAddrTcpType(ctx: *const Context) ?*const VirtualType {
    const word_def = ctx.lookupWord(">addr:tcp") orelse return null;
    switch (word_def.action) {
        .compound => |instructions| {
            if (instructions.len >= 1) {
                switch (instructions[0].op) {
                    .push_literal => |lit| {
                        switch (lit) {
                            .fixnum => |ptr_val| {
                                return @ptrFromInt(@as(usize, @intCast(ptr_val)));
                            },
                            else => return null,
                        }
                    },
                    else => return null,
                }
            }
            return null;
        },
        else => return null,
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
