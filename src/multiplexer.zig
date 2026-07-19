const std = @import("std");
const builtin = @import("builtin");

pub const IoEvent = enum { read, write };

pub const ProcessWaitHandle = union(enum) {
    // Plain i32, not std.posix.pid_t/fd_t: those resolve to void on freestanding (no OS
    // process/fd concept there), while i32 matches their real definition on every hosted target
    // this project supports (Linux, macOS) -- a no-op retype for hosted, and portable everywhere.
    pid: i32,
    pidfd: i32,
};

pub fn processWaitHandleKey(handle: ProcessWaitHandle) u64 {
    return switch (handle) {
        .pid => |pid| (@as(u64, 1) << 63) | @as(u64, @intCast(pid)),
        .pidfd => |fd| (@as(u64, 1) << 63) | @as(u64, @intCast(fd)),
    };
}

pub const ReadyEvent = union(enum) {
    io: struct {
        fd: i32,
        event: IoEvent,
    },
    process_exit: struct {
        handle: ProcessWaitHandle,
        pid: i32,
    },
    wake: struct {
        ident: u64,
    },
};

/// Tag bit set in the high u64 of a wake event's epoll data so the poll
/// dispatcher can distinguish wakes from regular fd events. Bit 63 is
/// already reserved for process-exit pidfds, so wakes claim bit 62.
pub const wake_ident_tag: u64 = @as(u64, 1) << 62;

const is_kqueue = switch (builtin.os.tag) {
    .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

const is_epoll = builtin.os.tag == .linux;

// Freestanding (and any other non-supported OS) gets a no-op Multiplexer.
// The scheduler keeps holding the field and calling methods; everything
// returns the empty event list. Async I/O is silently unavailable, which
// matches the print-only capability tier of the freestanding port.
const is_noop = !is_kqueue and !is_epoll;

const max_events = 64;

pub const Multiplexer = struct {
    mux_fd: i32,
    ready_buf: [max_events]ReadyEvent = undefined,
    /// Monotonic generator for `WakeSource` idents. Bit 62 is set so the
    /// resulting value cannot collide with an fd (always small, both bits
    /// clear) or with a process-exit pidfd key (bit 63 set).
    next_wake_ident: u64 = wake_ident_tag | 1,

    // platform-specific event buffers
    kqueue_buf: if (is_kqueue) [max_events]std.posix.Kevent else void = if (is_kqueue) undefined else {},
    epoll_buf: if (is_epoll) [max_events]std.os.linux.epoll_event else void = if (is_epoll) undefined else {},

    pub fn init() !Multiplexer {
        if (is_kqueue) {
            return .{ .mux_fd = try std.posix.kqueue() };
        } else if (is_epoll) {
            return .{ .mux_fd = try std.posix.epoll_create1(0) };
        } else {
            return .{ .mux_fd = -1 };
        }
    }

    /// Allocate and register a new wake source. The caller owns it and must
    /// call `deinit` to free its resources. Wake sources let other threads
    /// interrupt a blocking `poll()` via `WakeSource.signal()`.
    pub fn addWakeSource(self: *Multiplexer) !WakeSource {
        const ident = self.next_wake_ident;
        self.next_wake_ident += 1;

        if (is_kqueue) {
            const ev = std.posix.Kevent{
                .ident = @intCast(ident),
                .filter = std.c.EVFILT.USER,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            _ = try std.posix.kevent(self.mux_fd, &.{ev}, &.{}, null);
            return .{ .mux_fd = self.mux_fd, .ident = ident, .fd = {} };
        } else if (is_epoll) {
            const fd = try std.posix.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
            errdefer std.posix.close(fd);
            var ev = std.os.linux.epoll_event{
                .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET,
                .data = .{ .u64 = ident },
            };
            try std.posix.epoll_ctl(self.mux_fd, std.os.linux.EPOLL.CTL_ADD, fd, &ev);
            return .{ .mux_fd = self.mux_fd, .ident = ident, .fd = fd };
        } else {
            return .{ .mux_fd = self.mux_fd, .ident = ident, .fd = {} };
        }
    }

    pub fn deinit(self: *Multiplexer) void {
        if (is_noop) return;
        std.posix.close(self.mux_fd);
    }

    pub fn register(self: *Multiplexer, fd: i32, event: IoEvent) !void {
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

    pub fn registerProcessExit(self: *Multiplexer, pid: i32) !ProcessWaitHandle {
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
            return .{ .pid = pid };
        }
    }

    pub fn unregister(self: *Multiplexer, fd: i32, event: IoEvent) !void {
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
                self.ready_buf[i] = if (ev.filter == std.c.EVFILT.USER)
                    .{ .wake = .{ .ident = @intCast(ev.ident) } }
                else if (ev.filter == std.c.EVFILT.PROC)
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
                else if ((raw_key & wake_ident_tag) != 0)
                    .{ .wake = .{ .ident = raw_key } }
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
            return &.{};
        }
    }
};

/// Cross-thread wake handle for a `Multiplexer`. Created via
/// `Multiplexer.addWakeSource()` and used to interrupt a `poll()` call from
/// another thread (typically a worker thread waking another worker after
/// pushing a task onto its external queue).
///
/// On Linux this wraps an eventfd registered with edge-triggered EPOLLIN.
/// On kqueue platforms it wraps an EVFILT_USER kevent with EV_CLEAR; no fd
/// is needed since the filter consumes itself on read.
///
/// The handle stores the multiplexer's fd by value so a `WakeSource` is
/// safe to move (e.g., return from a function) without invalidating any
/// back-pointer. It does not own the multiplexer fd; only the eventfd it
/// allocated on Linux is owned and closed on `deinit`.
pub const WakeSource = struct {
    mux_fd: i32,
    ident: u64,
    fd: if (is_epoll) std.posix.fd_t else void,

    /// Wake the multiplexer's `poll()`. Safe to call from any thread.
    /// Coalesces: multiple signals before a poll observation are collapsed
    /// to a single `.wake` event.
    pub fn signal(self: *WakeSource) void {
        if (is_kqueue) {
            const ev = std.posix.Kevent{
                .ident = @intCast(self.ident),
                .filter = std.c.EVFILT.USER,
                .flags = 0,
                .fflags = std.c.NOTE.TRIGGER,
                .data = 0,
                .udata = 0,
            };
            _ = std.posix.kevent(self.mux_fd, &.{ev}, &.{}, null) catch {};
        } else if (is_epoll) {
            const buf = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 };
            _ = std.posix.write(self.fd, &buf) catch {};
        }
    }

    /// Drain any pending signal so subsequent polls block again until the
    /// next `signal()`. No-op on kqueue (EV_CLEAR drains automatically).
    /// Owning-thread only.
    pub fn drain(self: *WakeSource) void {
        if (is_epoll) {
            var buf: [8]u8 = undefined;
            _ = std.posix.read(self.fd, &buf) catch {};
        }
    }

    pub fn deinit(self: *WakeSource) void {
        if (is_kqueue) {
            const ev = std.posix.Kevent{
                .ident = @intCast(self.ident),
                .filter = std.c.EVFILT.USER,
                .flags = std.c.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            _ = std.posix.kevent(self.mux_fd, &.{ev}, &.{}, null) catch {};
        } else if (is_epoll) {
            std.posix.epoll_ctl(self.mux_fd, std.os.linux.EPOLL.CTL_DEL, self.fd, null) catch {};
            std.posix.close(self.fd);
        }
    }
};

fn openPidFd(pid: i32) !i32 {
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

test "wake source signal interrupts poll" {
    var mux = try Multiplexer.init();
    defer mux.deinit();

    var wake = try mux.addWakeSource();
    defer wake.deinit();

    // No signal yet: poll with a short timeout sees nothing.
    var events = try mux.poll(1 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), events.len);

    // Signal and confirm the wake comes back.
    wake.signal();
    events = try mux.poll(100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    switch (events[0]) {
        .wake => |w| try std.testing.expectEqual(wake.ident, w.ident),
        else => return error.TestUnexpectedResult,
    }

    // After draining, the next poll blocks again.
    wake.drain();
    events = try mux.poll(1 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "wake source coalesces repeated signals" {
    var mux = try Multiplexer.init();
    defer mux.deinit();

    var wake = try mux.addWakeSource();
    defer wake.deinit();

    // Multiple signals before observation should collapse into one wake.
    wake.signal();
    wake.signal();
    wake.signal();
    const events = try mux.poll(100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    switch (events[0]) {
        .wake => {},
        else => return error.TestUnexpectedResult,
    }
}

test "wake source ident is distinct from fd events" {
    var mux = try Multiplexer.init();
    defer mux.deinit();

    var wake = try mux.addWakeSource();
    defer wake.deinit();

    // Wake idents must not collide with the small-fd range used by io events.
    try std.testing.expect(wake.ident > 100);
    try std.testing.expect((wake.ident & wake_ident_tag) != 0);
    try std.testing.expect((wake.ident & (@as(u64, 1) << 63)) == 0);
}

test "wake source from another thread" {
    var mux = try Multiplexer.init();
    defer mux.deinit();

    var wake = try mux.addWakeSource();
    defer wake.deinit();

    const Helper = struct {
        wake: *WakeSource,
        fn run(self: @This()) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            self.wake.signal();
        }
    };

    var t = try std.Thread.spawn(.{}, Helper.run, .{Helper{ .wake = &wake }});
    defer t.join();

    const events = try mux.poll(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    switch (events[0]) {
        .wake => {},
        else => return error.TestUnexpectedResult,
    }
}
