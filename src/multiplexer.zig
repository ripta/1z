const std = @import("std");
const builtin = @import("builtin");

pub const IoEvent = enum { read, write };

pub const ReadyEvent = struct {
    fd: std.posix.fd_t,
    event: IoEvent,
};

const is_kqueue = switch (builtin.os.tag) {
    .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

const is_epoll = builtin.os.tag == .linux;

const max_events = 64;

pub const Multiplexer = struct {
    mux_fd: i32,
    ready_buf: [max_events]ReadyEvent = undefined,

    // platform-specific event buffers
    kqueue_buf: if (is_kqueue) [max_events]std.posix.Kevent else void = if (is_kqueue) undefined else {},
    epoll_buf: if (is_epoll) [max_events]std.os.linux.epoll_event else void = if (is_epoll) undefined else {},

    pub fn init() !Multiplexer {
        if (is_kqueue) {
            return .{ .mux_fd = try std.posix.kqueue() };
        } else if (is_epoll) {
            return .{ .mux_fd = try std.posix.epoll_create1(0) };
        } else {
            @compileError("Multiplexer: unsupported platform");
        }
    }

    pub fn deinit(self: *Multiplexer) void {
        std.posix.close(self.mux_fd);
    }

    pub fn register(self: *Multiplexer, fd: std.posix.fd_t, event: IoEvent) !void {
        if (is_kqueue) {
            const filter: i16 = if (event == .read) std.c.EVFILT.READ else std.c.EVFILT.WRITE;
            const ev = std.posix.Kevent{
                .ident = @intCast(fd),
                .filter = filter,
                .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = @intCast(fd),
            };
            _ = try std.posix.kevent(self.mux_fd, &.{ev}, &.{}, null);
        } else if (is_epoll) {
            const events: u32 = (if (event == .read) std.os.linux.EPOLL.IN else std.os.linux.EPOLL.OUT) | std.os.linux.EPOLL.ONESHOT;
            var ev = std.os.linux.epoll_event{
                .events = events,
                .data = .{ .fd = fd },
            };
            try std.posix.epoll_ctl(self.mux_fd, std.os.linux.EPOLL.CTL_ADD, fd, &ev);
        }
    }

    pub fn unregister(self: *Multiplexer, fd: std.posix.fd_t, event: IoEvent) !void {
        if (is_kqueue) {
            const filter: i16 = if (event == .read) std.c.EVFILT.READ else std.c.EVFILT.WRITE;
            const ev = std.posix.Kevent{
                .ident = @intCast(fd),
                .filter = filter,
                .flags = std.c.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            _ = std.posix.kevent(self.mux_fd, &.{ev}, &.{}, null) catch |err| switch (err) {
                error.EventNotFound => return,
                else => |e| return e,
            };
        } else if (is_epoll) {
            std.posix.epoll_ctl(self.mux_fd, std.os.linux.EPOLL.CTL_DEL, fd, null) catch |err| switch (err) {
                error.FileDescriptorNotRegistered => {},
                else => return err,
            };
        }
    }

    pub fn poll(self: *Multiplexer, timeout_ns: ?i128) ![]const ReadyEvent {
        if (is_kqueue) {
            const timeout: ?*const std.posix.timespec = if (timeout_ns) |ns| blk: {
                const sec: isize = @intCast(@divFloor(ns, std.time.ns_per_s));
                const nsec_remainder: isize = @intCast(@mod(ns, std.time.ns_per_s));
                break :blk &std.posix.timespec{ .sec = sec, .nsec = nsec_remainder };
            } else null;
            const n = try std.posix.kevent(self.mux_fd, &.{}, &self.kqueue_buf, timeout);
            for (self.kqueue_buf[0..n], 0..) |ev, i| {
                self.ready_buf[i] = .{
                    .fd = @intCast(ev.ident),
                    .event = if (ev.filter == std.c.EVFILT.READ) .read else .write,
                };
            }
            return self.ready_buf[0..n];
        } else if (is_epoll) {
            const timeout_ms: i32 = if (timeout_ns) |ns| blk: {
                if (ns <= 0) break :blk 0;
                const ms = @divFloor(ns, std.time.ns_per_ms);
                break :blk @intCast(@min(ms, std.math.maxInt(i32)));
            } else -1;
            const n = std.posix.epoll_wait(self.mux_fd, &self.epoll_buf, timeout_ms);
            for (self.epoll_buf[0..n], 0..) |ev, i| {
                self.ready_buf[i] = .{
                    .fd = ev.data.fd,
                    .event = if (ev.events & std.os.linux.EPOLL.IN != 0) .read else .write,
                };
            }
            return self.ready_buf[0..n];
        } else {
            @compileError("Multiplexer: unsupported platform");
        }
    }
};

test "init and deinit" {
    var mux = try Multiplexer.init();
    defer mux.deinit();
}

test "register and poll-readable pipe" {
    var mux = try Multiplexer.init();
    defer mux.deinit();

    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    try mux.register(fds[0], .read);

    _ = try std.posix.write(fds[1], "x");

    const events = try mux.poll(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(fds[0], events[0].fd);
    try std.testing.expectEqual(IoEvent.read, events[0].event);
}

test "poll timeout with no events" {
    var mux = try Multiplexer.init();
    defer mux.deinit();

    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    try mux.register(fds[0], .read);

    const events = try mux.poll(1 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "unregister prevents events" {
    var mux = try Multiplexer.init();
    defer mux.deinit();

    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    try mux.register(fds[0], .read);
    try mux.unregister(fds[0], .read);

    _ = try std.posix.write(fds[1], "x");

    const events = try mux.poll(1 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "fresh pipe is write ready" {
    var mux = try Multiplexer.init();
    defer mux.deinit();

    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    try mux.register(fds[1], .write);

    const events = try mux.poll(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(fds[1], events[0].fd);
    try std.testing.expectEqual(IoEvent.write, events[0].event);
}
