const std = @import("std");
const builtin = @import("builtin");

pub const IoEvent = enum { read, write };

pub const ProcessWaitHandle = union(enum) {
    pid: std.posix.pid_t,
    pidfd: std.posix.fd_t,
};

pub fn processWaitHandleKey(handle: ProcessWaitHandle) u64 {
    return switch (handle) {
        .pid => |pid| (@as(u64, 1) << 63) | @as(u64, @intCast(pid)),
        .pidfd => |fd| (@as(u64, 1) << 63) | @as(u64, @intCast(fd)),
    };
}

pub const ReadyEvent = union(enum) {
    io: struct {
        fd: std.posix.fd_t,
        event: IoEvent,
    },
    process_exit: struct {
        handle: ProcessWaitHandle,
        pid: std.posix.pid_t,
    },
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
            const events: u32 = (if (event == .read) @as(u32, std.os.linux.EPOLL.IN) else @as(u32, std.os.linux.EPOLL.OUT)) | std.os.linux.EPOLL.ONESHOT;
            var ev = std.os.linux.epoll_event{
                .events = events,
                .data = .{ .fd = fd },
            };
            std.posix.epoll_ctl(self.mux_fd, std.os.linux.EPOLL.CTL_ADD, fd, &ev) catch |err| switch (err) {
                // EPOLLONESHOT fds remain in the interest set after firing and has to be reärmed with CTL_MOD before the next wait.
                error.FileDescriptorAlreadyPresentInSet => try std.posix.epoll_ctl(self.mux_fd, std.os.linux.EPOLL.CTL_MOD, fd, &ev),
                else => return err,
            };
        }
    }

    pub fn registerProcessExit(self: *Multiplexer, pid: std.posix.pid_t) !ProcessWaitHandle {
        if (is_kqueue) {
            const ev = std.posix.Kevent{
                .ident = @intCast(pid),
                .filter = std.c.EVFILT.PROC,
                .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                .fflags = std.c.NOTE.EXIT,
                .data = 0,
                .udata = @intCast(pid),
            };

            _ = try std.posix.kevent(self.mux_fd, &.{ev}, &.{}, null);
            return .{ .pid = pid };
        } else if (is_epoll) {
            const pidfd = try openPidFd(pid);
            errdefer std.posix.close(pidfd);

            var ev = std.os.linux.epoll_event{
                .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ONESHOT,
                .data = .{ .u64 = processWaitHandleKey(.{ .pidfd = pidfd }) },
            };

            try std.posix.epoll_ctl(self.mux_fd, std.os.linux.EPOLL.CTL_ADD, pidfd, &ev);
            return .{ .pidfd = pidfd };
        } else {
            @compileError("Multiplexer: unsupported platform");
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

    pub fn unregisterProcessExit(self: *Multiplexer, handle: ProcessWaitHandle) !void {
        switch (handle) {
            .pid => |pid| {
                if (!is_kqueue) unreachable;

                const ev = std.posix.Kevent{
                    .ident = @intCast(pid),
                    .filter = std.c.EVFILT.PROC,
                    .flags = std.c.EV.DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                };

                _ = std.posix.kevent(self.mux_fd, &.{ev}, &.{}, null) catch |err| switch (err) {
                    error.EventNotFound => {},
                    else => return err,
                };
            },
            .pidfd => |pidfd| {
                if (!is_epoll) unreachable;
                defer std.posix.close(pidfd);

                std.posix.epoll_ctl(self.mux_fd, std.os.linux.EPOLL.CTL_DEL, pidfd, null) catch |err| switch (err) {
                    error.FileDescriptorNotRegistered => {},
                    else => return err,
                };
            },
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
                self.ready_buf[i] = if (ev.filter == std.c.EVFILT.PROC)
                    .{
                        .process_exit = .{
                            .handle = .{ .pid = @intCast(ev.ident) },
                            .pid = @intCast(ev.ident),
                        },
                    }
                else
                    .{
                        .io = .{
                            .fd = @intCast(ev.ident),
                            .event = if (ev.filter == std.c.EVFILT.READ) .read else .write,
                        },
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
                const raw_key = ev.data.u64;
                self.ready_buf[i] = if ((raw_key >> 63) != 0)
                    .{
                        .process_exit = .{
                            .handle = .{ .pidfd = @intCast(raw_key & ~(@as(u64, 1) << 63)) },
                            .pid = 0,
                        },
                    }
                else
                    .{
                        .io = .{
                            .fd = @intCast(raw_key),
                            .event = if (ev.events & std.os.linux.EPOLL.IN != 0) .read else .write,
                        },
                    };
            }
            return self.ready_buf[0..n];
        } else {
            @compileError("Multiplexer: unsupported platform");
        }
    }
};

fn openPidFd(pid: std.posix.pid_t) !std.posix.fd_t {
    if (!is_epoll) unreachable;

    const rc = std.os.linux.pidfd_open(pid, 0);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INVAL => return error.InvalidArgument,
        .MFILE, .NFILE => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .NOSYS => return error.Unsupported,
        .SRCH => return error.ProcessNotFound,
        else => return error.Unexpected,
    }
}

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
    switch (events[0]) {
        .io => |ready| {
            try std.testing.expectEqual(fds[0], ready.fd);
            try std.testing.expectEqual(IoEvent.read, ready.event);
        },
        else => return error.TestUnexpectedResult,
    }
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
    switch (events[0]) {
        .io => |ready| {
            try std.testing.expectEqual(fds[1], ready.fd);
            try std.testing.expectEqual(IoEvent.write, ready.event);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "register and poll process exit" {
    var mux = try Multiplexer.init();
    defer mux.deinit();

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", "exit 0" }, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const handle = try mux.registerProcessExit(child.id);
    defer mux.unregisterProcessExit(handle) catch {};

    const events = try mux.poll(1 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    switch (events[0]) {
        .process_exit => |ready| {
            if (is_kqueue) {
                try std.testing.expectEqual(child.id, ready.pid);
            } else if (is_epoll) {
                switch (ready.handle) {
                    .pidfd => |pidfd| try std.testing.expect(pidfd >= 0),
                    else => return error.TestUnexpectedResult,
                }
            }
        },
        else => return error.TestUnexpectedResult,
    }

    const wait_result = std.posix.waitpid(child.id, 0);
    try std.testing.expectEqual(child.id, wait_result.pid);
}

test "epoll can reärm oneshot fd" {
    if (!is_epoll) return;

    var mux = try Multiplexer.init();
    defer mux.deinit();

    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    try mux.register(fds[0], .read);
    _ = try std.posix.write(fds[1], "x");

    var events = try mux.poll(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(fds[0], events[0].fd);

    var drain_buf: [1]u8 = undefined;
    _ = try std.posix.read(fds[0], &drain_buf);

    try mux.register(fds[0], .read);
    _ = try std.posix.write(fds[1], "y");

    events = try mux.poll(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(fds[0], events[0].fd);
}
