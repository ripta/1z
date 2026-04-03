const std = @import("std");
const builtin = @import("builtin");

const Context = @import("../context.zig").Context;

const value_mod = @import("../value.zig");
const Resource = value_mod.Resource;
const HashTable = value_mod.HashTable;

const Primitive = @import("types.zig").Primitive;

const helpers = @import("helpers.zig");

const error_mapping = @import("error_mapping.zig");

const streams = @import("streams.zig");

const Scheduler = @import("../scheduler.zig").Scheduler;

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const supports_event_watch = is_macos or is_linux;
const default_polling_interval_ns: u64 = 20 * std.time.ns_per_ms;

pub const primitives = [_]Primitive{
    .{ .name = "watcher-create", .stack_effect = "mode -- watcher", .doc = "Create a watcher resource for event: mode.", .func = nativeWatcherCreate, .capability = .io_fs },
    .{ .name = "watcher-add", .stack_effect = "watcher path flags -- watch-id", .doc = "Register a path for watching. Flags is an array of symbols or f for defaults.", .func = nativeWatcherAdd, .capability = .io_fs },
    .{ .name = "watcher-remove", .stack_effect = "watcher watch-id --", .doc = "Remove a previously registered watch.", .func = nativeWatcherRemove, .capability = .io_fs },
    .{ .name = "watcher-read", .stack_effect = "watcher -- event", .doc = "Read the next raw watcher event as a hash.", .func = nativeWatcherRead, .capability = .io_fs },
    .{ .name = "watcher-probe", .stack_effect = "path -- bool", .doc = "Return t when OS-native event watching works for the path.", .func = nativeWatcherProbe, .capability = .io_fs },
};

const WatchEventMask = packed struct(u8) {
    created: bool = false,
    modified: bool = false,
    deleted: bool = false,
    renamed: bool = false,
    _: u4 = 0,

    fn all() WatchEventMask {
        return .{ .created = true, .modified = true, .deleted = true, .renamed = true };
    }

    fn empty(self: WatchEventMask) bool {
        return !self.created and !self.modified and !self.deleted and !self.renamed;
    }
};

const PendingEvent = struct {
    watch_id: i64,
    kind: []const u8,
    path: []u8,
    new_path: ?[]u8 = null,
};

const PendingRename = struct {
    watch_id: i64,
    path: []u8,
};

const WatchEntry = struct {
    backend_handle: i32,
    path: []u8,
    mask: WatchEventMask,
};

const WatcherVTable = struct {
    addWatch: *const fn (ptr: *anyopaque, path: []const u8, mask: WatchEventMask) anyerror!i64,
    removeWatch: *const fn (ptr: *anyopaque, watch_id: i64) anyerror!void,
    readEvent: *const fn (ptr: *anyopaque, scheduler: ?*Scheduler) anyerror!PendingEvent,
    deinit: *const fn (ptr: *anyopaque) void,
};

const WatcherHandle = struct {
    allocator: std.mem.Allocator,
    ptr: *anyopaque,
    vtable: *const WatcherVTable,
};

const NativeWatcher = struct {
    allocator: std.mem.Allocator,
    backend_fd: std.posix.fd_t,
    next_watch_id: i64 = 1,
    watches: std.AutoHashMapUnmanaged(i64, WatchEntry) = .{},
    watch_ids_by_backend_handle: std.AutoHashMapUnmanaged(i32, i64) = .{},
    pending: std.ArrayListUnmanaged(PendingEvent) = .{},
    pending_renames: std.AutoHashMapUnmanaged(u32, PendingRename) = .{},

    fn init(allocator: std.mem.Allocator) !*NativeWatcher {
        const watcher = try allocator.create(NativeWatcher);
        errdefer allocator.destroy(watcher);

        watcher.* = .{
            .allocator = allocator,
            .backend_fd = if (is_macos)
                try std.posix.kqueue()
            else if (is_linux)
                try std.posix.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK)
            else
                return error.Unsupported,
        };

        return watcher;
    }

    fn deinit(self: *NativeWatcher) void {
        var pending_index: usize = 0;
        while (pending_index < self.pending.items.len) : (pending_index += 1) {
            const item = self.pending.items[pending_index];
            self.allocator.free(item.path);
            if (item.new_path) |new_path| self.allocator.free(new_path);
        }

        self.pending.deinit(self.allocator);

        var rename_it = self.pending_renames.iterator();
        while (rename_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
        }
        self.pending_renames.deinit(self.allocator);

        self.watch_ids_by_backend_handle.deinit(self.allocator);

        var it = self.watches.iterator();
        while (it.next()) |entry| {
            self.destroyWatchEntry(entry.value_ptr.*);
        }
        self.watches.deinit(self.allocator);

        std.posix.close(self.backend_fd);
        self.allocator.destroy(self);
    }

    fn addWatch(self: *NativeWatcher, path: []const u8, mask: WatchEventMask) !i64 {
        const watch_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(watch_path);

        const watch_id = self.next_watch_id;
        self.next_watch_id += 1;

        const backend_handle = if (is_macos) blk: {
            const path_z = try self.allocator.dupeZ(u8, path);
            defer self.allocator.free(path_z);

            const watch_fd = try openWatchFd(path_z);
            errdefer std.posix.close(watch_fd);

            try registerWatchFd(self.backend_fd, watch_fd, watch_id, mask);
            break :blk watch_fd;
        } else if (is_linux) blk: {
            const wd = try std.posix.inotify_add_watch(self.backend_fd, path, inotifyMask(mask));
            break :blk wd;
        } else return error.Unsupported;

        try self.watches.put(self.allocator, watch_id, .{
            .backend_handle = backend_handle,
            .path = watch_path,
            .mask = mask,
        });
        errdefer _ = self.watches.remove(watch_id);

        if (is_linux) {
            try self.watch_ids_by_backend_handle.put(self.allocator, backend_handle, watch_id);
        }

        return watch_id;
    }

    fn removeWatch(self: *NativeWatcher, watch_id: i64) !void {
        const removed = self.watches.fetchRemove(watch_id) orelse return error.KeyNotFound;

        if (is_macos) {
            unregisterWatchFd(self.backend_fd, removed.value.backend_handle) catch {};
        } else if (is_linux) {
            _ = self.watch_ids_by_backend_handle.remove(removed.value.backend_handle);
            removeInotifyWatch(self.backend_fd, removed.value.backend_handle);
        }

        self.destroyWatchEntry(removed.value);
    }

    fn readEvent(self: *NativeWatcher, scheduler: ?*Scheduler) !PendingEvent {
        while (true) {
            if (self.pending.items.len > 0) {
                return self.pending.orderedRemove(0);
            }

            try self.drainBackend(false);
            if (self.pending.items.len > 0) {
                return self.pending.orderedRemove(0);
            }

            if (scheduler) |sched| {
                if (is_macos) streams.setNonBlockingFd(self.backend_fd);
                sched.ioSuspendCurrentTask(self.backend_fd, .read);
            } else {
                try self.drainBackend(true);
            }
        }
    }

    fn destroyWatchEntry(self: *NativeWatcher, watch: WatchEntry) void {
        if (is_macos) {
            std.posix.close(watch.backend_handle);
        }
        self.allocator.free(watch.path);
    }

    fn drainBackend(self: *NativeWatcher, blocking: bool) !void {
        if (is_macos) {
            try self.drainKqueue(blocking);
        } else if (is_linux) {
            try self.drainInotify(blocking);
        } else {
            return error.Unsupported;
        }
    }

    fn drainKqueue(self: *NativeWatcher, blocking: bool) !void {
        var events: [8]std.posix.Kevent = undefined;
        const timeout_ptr: ?*const std.posix.timespec = if (blocking) null else &.{ .sec = 0, .nsec = 0 };
        const count = try std.posix.kevent(self.backend_fd, &.{}, &events, timeout_ptr);
        for (events[0..count]) |event| {
            try self.translateEvent(event);
        }
    }

    fn translateEvent(self: *NativeWatcher, event: std.posix.Kevent) !void {
        if (event.filter != std.c.EVFILT.VNODE) return;

        const watch_id: i64 = @intCast(event.udata);
        const watch = self.watches.get(watch_id) orelse return;
        const notes: u32 = @intCast(event.fflags);

        if (notes & std.c.NOTE.DELETE != 0 and watch.mask.deleted) {
            try self.enqueueEvent(watch_id, "deleted", watch.path, null);
        }
        if (notes & std.c.NOTE.RENAME != 0 and watch.mask.renamed) {
            try self.enqueueEvent(watch_id, "renamed", watch.path, null);
        }
        if ((notes & (std.c.NOTE.WRITE | std.c.NOTE.EXTEND | std.c.NOTE.ATTRIB)) != 0 and watch.mask.modified) {
            try self.enqueueEvent(watch_id, "modified", watch.path, null);
        }
    }

    fn enqueueEvent(self: *NativeWatcher, watch_id: i64, kind: []const u8, path: []const u8, new_path: ?[]const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        const owned_new_path = if (new_path) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (owned_new_path) |p| self.allocator.free(p);

        try self.pending.append(self.allocator, .{
            .watch_id = watch_id,
            .kind = kind,
            .path = owned_path,
            .new_path = owned_new_path,
        });
    }

    fn drainInotify(self: *NativeWatcher, blocking: bool) !void {
        if (blocking and self.pending.items.len == 0) {
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = self.backend_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            _ = try std.posix.poll(&poll_fds, -1);
        }

        var buf: [4096]u8 = undefined;
        while (true) {
            const len = std.posix.read(self.backend_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (len == 0) break;
            try self.translateInotifyBuffer(buf[0..len]);
        }

        try self.flushPendingRenames();
    }

    fn translateInotifyBuffer(self: *NativeWatcher, buf: []const u8) !void {
        var offset: usize = 0;
        while (offset + @sizeOf(std.os.linux.inotify_event) <= buf.len) {
            const raw: *align(1) const std.os.linux.inotify_event = @ptrCast(buf[offset..].ptr);
            const event = raw.*;
            const event_len = @sizeOf(std.os.linux.inotify_event) + event.len;
            if (offset + event_len > buf.len) break;

            try self.translateInotifyEvent(event, buf[offset + @sizeOf(std.os.linux.inotify_event) .. offset + event_len]);
            offset += event_len;
        }
    }

    fn translateInotifyEvent(self: *NativeWatcher, event: std.os.linux.inotify_event, name_bytes: []const u8) !void {
        const watch_id = self.watch_ids_by_backend_handle.get(event.wd) orelse return;
        const watch = self.watches.get(watch_id) orelse return;
        const event_path = try self.inotifyEventPath(watch.path, name_bytes);
        defer self.allocator.free(event_path);

        if (event.mask & std.os.linux.IN.IGNORED != 0) {
            self.cleanupIgnoredWatch(event.wd);
            return;
        }

        if (event.mask & std.os.linux.IN.Q_OVERFLOW != 0) return;

        if ((event.mask & std.os.linux.IN.MOVED_FROM) != 0 and watch.mask.renamed) {
            try self.storePendingRename(watch_id, event.cookie, event_path);
        }
        if ((event.mask & std.os.linux.IN.MOVED_TO) != 0) {
            if (watch.mask.renamed) {
                if (self.pending_renames.fetchRemove(event.cookie)) |entry| {
                    defer self.allocator.free(entry.value.path);
                    try self.enqueueEvent(entry.value.watch_id, "renamed", entry.value.path, event_path);
                } else if (watch.mask.created) {
                    try self.enqueueEvent(watch_id, "created", event_path, null);
                }
            } else if (watch.mask.created) {
                try self.enqueueEvent(watch_id, "created", event_path, null);
            }
        }
        if ((event.mask & std.os.linux.IN.CREATE) != 0 and watch.mask.created) {
            try self.enqueueEvent(watch_id, "created", event_path, null);
        }
        if ((event.mask & (std.os.linux.IN.MODIFY | std.os.linux.IN.ATTRIB | std.os.linux.IN.CLOSE_WRITE)) != 0 and watch.mask.modified) {
            try self.enqueueEvent(watch_id, "modified", event_path, null);
        }
        if ((event.mask & (std.os.linux.IN.DELETE | std.os.linux.IN.DELETE_SELF)) != 0 and watch.mask.deleted) {
            try self.enqueueEvent(watch_id, "deleted", event_path, null);
        }
        if ((event.mask & std.os.linux.IN.MOVE_SELF) != 0 and watch.mask.renamed) {
            try self.enqueueEvent(watch_id, "renamed", event_path, null);
        }
    }

    fn inotifyEventPath(self: *NativeWatcher, watch_path: []const u8, name_bytes: []const u8) ![]u8 {
        const name = trimInotifyName(name_bytes);
        if (name.len == 0) return try self.allocator.dupe(u8, watch_path);
        return try std.fs.path.join(self.allocator, &.{ watch_path, name });
    }

    fn storePendingRename(self: *NativeWatcher, watch_id: i64, cookie: u32, path: []const u8) !void {
        if (cookie == 0) {
            try self.enqueueEvent(watch_id, "renamed", path, null);
            return;
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        if (self.pending_renames.fetchRemove(cookie)) |entry| {
            self.allocator.free(entry.value.path);
        }
        try self.pending_renames.put(self.allocator, cookie, .{
            .watch_id = watch_id,
            .path = owned_path,
        });
    }

    fn flushPendingRenames(self: *NativeWatcher) !void {
        if (self.pending_renames.count() == 0) return;

        var it = self.pending_renames.iterator();
        while (it.next()) |entry| {
            const pending = entry.value_ptr.*;
            defer self.allocator.free(pending.path);
            try self.enqueueEvent(pending.watch_id, "renamed", pending.path, null);
        }
        self.pending_renames.clearRetainingCapacity();
    }

    fn cleanupIgnoredWatch(self: *NativeWatcher, wd: i32) void {
        const watch_id = self.watch_ids_by_backend_handle.fetchRemove(wd) orelse return;
        const watch = self.watches.fetchRemove(watch_id.value) orelse return;
        self.destroyWatchEntry(watch.value);
    }
};

const PollingSnapshot = struct {
    exists: bool,
    modified: ?i128,
    size: u64,
};

const PollingWatchEntry = struct {
    path: []u8,
    exists: bool,
    modified: ?i128,
    size: u64,
};

const PollingWatcher = struct {
    allocator: std.mem.Allocator,
    next_watch_id: i64 = 1,
    interval_ns: u64 = default_polling_interval_ns,
    watches: std.AutoHashMapUnmanaged(i64, PollingWatchEntry) = .{},

    fn init(allocator: std.mem.Allocator) !*PollingWatcher {
        const watcher = try allocator.create(PollingWatcher);
        errdefer allocator.destroy(watcher);
        watcher.* = .{ .allocator = allocator };
        return watcher;
    }

    fn deinit(self: *PollingWatcher) void {
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
        }
        self.watches.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn addWatch(self: *PollingWatcher, path: []const u8, _: WatchEventMask) !i64 {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        const snapshot = try pollSnapshot(path);
        const watch_id = self.next_watch_id;
        self.next_watch_id += 1;

        try self.watches.put(self.allocator, watch_id, .{
            .path = owned_path,
            .exists = snapshot.exists,
            .modified = snapshot.modified,
            .size = snapshot.size,
        });

        return watch_id;
    }

    fn removeWatch(self: *PollingWatcher, watch_id: i64) !void {
        const removed = self.watches.fetchRemove(watch_id) orelse return error.KeyNotFound;
        self.allocator.free(removed.value.path);
    }

    fn readEvent(self: *PollingWatcher, scheduler: ?*Scheduler) !PendingEvent {
        while (true) {
            var it = self.watches.iterator();
            while (it.next()) |entry| {
                const watch_id = entry.key_ptr.*;
                const watch = entry.value_ptr;
                const snapshot = try pollSnapshot(watch.path);

                const event_kind: ?[]const u8 = if (!watch.exists and snapshot.exists)
                    "created"
                else if (watch.exists and !snapshot.exists)
                    "deleted"
                else if (watch.exists and snapshot.exists and
                    (watch.modified != snapshot.modified or watch.size != snapshot.size))
                    "modified"
                else
                    null;

                watch.exists = snapshot.exists;
                watch.modified = snapshot.modified;
                watch.size = snapshot.size;

                if (event_kind) |kind| {
                    return .{
                        .watch_id = watch_id,
                        .kind = kind,
                        .path = try self.allocator.dupe(u8, watch.path),
                        .new_path = null,
                    };
                }
            }

            if (scheduler) |sched| {
                sched.sleepCurrentTask(@intCast(self.interval_ns));
                return error.WouldBlock;
            }

            std.Thread.sleep(self.interval_ns);
        }
    }
};

fn nativeWatcherCreate(ctx: *Context) anyerror!void {
    const mode = try helpers.popSymbol(ctx);
    const handle = try ctx.quotationAllocator().create(WatcherHandle);
    errdefer ctx.quotationAllocator().destroy(handle);

    if (std.mem.eql(u8, mode, "event")) {
        if (!supports_event_watch) {
            helpers.setErrorContext(ctx, "watcher-create: event watchers are only implemented on macOS and Linux", .{});
            return error.IOFailed;
        }

        const watcher = try NativeWatcher.init(ctx.quotationAllocator());
        handle.* = .{
            .allocator = ctx.quotationAllocator(),
            .ptr = watcher,
            .vtable = &native_watcher_vtable,
        };
    } else if (std.mem.eql(u8, mode, "polling")) {
        const watcher = try PollingWatcher.init(ctx.quotationAllocator());
        handle.* = .{
            .allocator = ctx.quotationAllocator(),
            .ptr = watcher,
            .vtable = &polling_watcher_vtable,
        };
    } else {
        helpers.setErrorContext(ctx, "watcher-create: unsupported mode {s}:", .{mode});
        return error.IOFailed;
    }

    const resource = try ctx.quotationAllocator().create(Resource);
    resource.* = .{
        .type_name = "watcher",
        .ptr = @ptrCast(handle),
        .close_fn = .{ .native = watcherCloseFn },
    };
    try ctx.stack.push(.{ .resource = resource });
}

fn nativeWatcherAdd(ctx: *Context) anyerror!void {
    const flags_val = try ctx.stack.pop();
    const path = try helpers.popString(ctx);
    const watcher_resource = try popWatcherResource(ctx, "watcher-add");
    const watcher = watcherFromResource(watcher_resource);
    const mask = try parseMask(ctx, flags_val);

    const watch_id = watcher.vtable.addWatch(watcher.ptr, path, if (mask.empty()) WatchEventMask.all() else mask) catch |err| {
        helpers.setErrorContext(ctx, "watcher-add: {s}", .{@errorName(err)});
        return switch (err) {
            error.AccessDenied => error.PermissionDenied,
            error.FileNotFound => error.FileNotFound,
            else => error.IOFailed,
        };
    };

    try ctx.stack.push(.{ .fixnum = watch_id });
}

fn nativeWatcherRemove(ctx: *Context) anyerror!void {
    const watch_id = try helpers.popFixnum(ctx);
    const watcher_resource = try popWatcherResource(ctx, "watcher-remove");
    const watcher = watcherFromResource(watcher_resource);

    watcher.vtable.removeWatch(watcher.ptr, watch_id) catch {
        helpers.setErrorContext(ctx, "watcher-remove: unknown watch id {d}", .{watch_id});
        return error.KeyNotFound;
    };
}

fn nativeWatcherRead(ctx: *Context) anyerror!void {
    const watcher_resource = try popWatcherResource(ctx, "watcher-read");
    const watcher = watcherFromResource(watcher_resource);

    while (true) {
        const event = watcher.vtable.readEvent(watcher.ptr, ctx.scheduler) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler != null) {
                    try helpers.checkCancellation(ctx);
                }
                continue;
            }

            helpers.setErrorContext(ctx, "watcher-read: {s}", .{@errorName(err)});
            return error.IOFailed;
        };
        defer {
            watcher.allocator.free(event.path);
            if (event.new_path) |new_path| watcher.allocator.free(new_path);
        }

        if (ctx.scheduler != null) {
            try helpers.checkCancellation(ctx);
        }

        const alloc = ctx.quotationAllocator();
        const hash = try alloc.create(HashTable);
        hash.* = HashTable{};

        try hash.put(alloc, try alloc.dupe(u8, "watch-id"), .{ .fixnum = event.watch_id });
        try hash.put(alloc, try alloc.dupe(u8, "kind"), .{ .symbol = event.kind });
        try hash.put(alloc, try alloc.dupe(u8, "path"), .{ .string = try alloc.dupe(u8, event.path) });
        if (event.new_path) |new_path| {
            try hash.put(alloc, try alloc.dupe(u8, "new-path"), .{ .string = try alloc.dupe(u8, new_path) });
        } else {
            try hash.put(alloc, try alloc.dupe(u8, "new-path"), .{ .boolean = false });
        }

        try ctx.stack.push(.{ .hash = hash });
        return;
    }
}

fn nativeWatcherProbe(ctx: *Context) anyerror!void {
    const path = try helpers.popString(ctx);
    if (!supports_event_watch) {
        try ctx.stack.push(.{ .boolean = false });
        return;
    }

    const alloc = ctx.quotationAllocator();
    const watcher = NativeWatcher.init(alloc) catch {
        try ctx.stack.push(.{ .boolean = false });
        return;
    };
    defer watcher.deinit();

    const watch_id = watcher.addWatch(path, WatchEventMask.all()) catch {
        try ctx.stack.push(.{ .boolean = false });
        return;
    };
    watcher.removeWatch(watch_id) catch {};
    try ctx.stack.push(.{ .boolean = true });
}

fn popWatcherResource(ctx: *Context, op_name: []const u8) !*Resource {
    const resource = try helpers.popResource(ctx);
    try error_mapping.ensureResourceOpen(resource);
    if (!std.mem.eql(u8, resource.type_name, "watcher")) {
        helpers.setErrorContext(ctx, "{s}: expected watcher resource, got {s}", .{ op_name, resource.type_name });
        return error.TypeMismatch;
    }
    if (resource.ptr == null) {
        helpers.setErrorContext(ctx, "{s}: watcher resource is closed", .{op_name});
        return error.UseAfterClose;
    }
    return resource;
}

fn watcherFromResource(resource: *Resource) *WatcherHandle {
    return @ptrCast(@alignCast(resource.ptr.?));
}

fn watcherCloseFn(ptr: *anyopaque) void {
    const watcher: *WatcherHandle = @ptrCast(@alignCast(ptr));
    watcher.vtable.deinit(watcher.ptr);
    watcher.allocator.destroy(watcher);
}

fn nativeWatcherAddImpl(ptr: *anyopaque, path: []const u8, mask: WatchEventMask) anyerror!i64 {
    const watcher: *NativeWatcher = @ptrCast(@alignCast(ptr));
    return watcher.addWatch(path, mask);
}

fn nativeWatcherRemoveImpl(ptr: *anyopaque, watch_id: i64) anyerror!void {
    const watcher: *NativeWatcher = @ptrCast(@alignCast(ptr));
    return watcher.removeWatch(watch_id);
}

fn nativeWatcherReadImpl(ptr: *anyopaque, scheduler: ?*Scheduler) anyerror!PendingEvent {
    const watcher: *NativeWatcher = @ptrCast(@alignCast(ptr));
    return watcher.readEvent(scheduler);
}

fn nativeWatcherDeinitImpl(ptr: *anyopaque) void {
    const watcher: *NativeWatcher = @ptrCast(@alignCast(ptr));
    watcher.deinit();
}

fn pollingWatcherAddImpl(ptr: *anyopaque, path: []const u8, mask: WatchEventMask) anyerror!i64 {
    const watcher: *PollingWatcher = @ptrCast(@alignCast(ptr));
    return watcher.addWatch(path, mask);
}

fn pollingWatcherRemoveImpl(ptr: *anyopaque, watch_id: i64) anyerror!void {
    const watcher: *PollingWatcher = @ptrCast(@alignCast(ptr));
    return watcher.removeWatch(watch_id);
}

fn pollingWatcherReadImpl(ptr: *anyopaque, scheduler: ?*Scheduler) anyerror!PendingEvent {
    const watcher: *PollingWatcher = @ptrCast(@alignCast(ptr));
    return watcher.readEvent(scheduler);
}

fn pollingWatcherDeinitImpl(ptr: *anyopaque) void {
    const watcher: *PollingWatcher = @ptrCast(@alignCast(ptr));
    watcher.deinit();
}

const native_watcher_vtable = WatcherVTable{
    .addWatch = nativeWatcherAddImpl,
    .removeWatch = nativeWatcherRemoveImpl,
    .readEvent = nativeWatcherReadImpl,
    .deinit = nativeWatcherDeinitImpl,
};

const polling_watcher_vtable = WatcherVTable{
    .addWatch = pollingWatcherAddImpl,
    .removeWatch = pollingWatcherRemoveImpl,
    .readEvent = pollingWatcherReadImpl,
    .deinit = pollingWatcherDeinitImpl,
};

fn parseMask(ctx: *Context, val: value_mod.Value) !WatchEventMask {
    return switch (val) {
        .boolean => |b| if (!b) WatchEventMask.all() else {
            helpers.setTypeMismatchError(ctx, "array, symbol, or f", val);
            return error.TypeMismatch;
        },
        .symbol => |sym| try parseMaskSymbol(ctx, sym),
        .array => |items| blk: {
            var mask = WatchEventMask{};
            for (items) |item| {
                const sym = switch (item) {
                    .symbol => |s| s,
                    else => {
                        helpers.setTypeMismatchError(ctx, "symbol", item);
                        return error.TypeMismatch;
                    },
                };
                const item_mask = try parseMaskSymbol(ctx, sym);
                mask.created = mask.created or item_mask.created;
                mask.modified = mask.modified or item_mask.modified;
                mask.deleted = mask.deleted or item_mask.deleted;
                mask.renamed = mask.renamed or item_mask.renamed;
            }
            break :blk if (mask.empty()) WatchEventMask.all() else mask;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "array, symbol, or f", val);
            return error.TypeMismatch;
        },
    };
}

fn parseMaskSymbol(ctx: *Context, sym: []const u8) !WatchEventMask {
    if (std.mem.eql(u8, sym, "all")) return WatchEventMask.all();
    if (std.mem.eql(u8, sym, "created")) return .{ .created = true };
    if (std.mem.eql(u8, sym, "modified")) return .{ .modified = true };
    if (std.mem.eql(u8, sym, "deleted")) return .{ .deleted = true };
    if (std.mem.eql(u8, sym, "renamed")) return .{ .renamed = true };

    helpers.setErrorContext(ctx, "watcher-add: unknown watch flag {s}:", .{sym});
    return error.TypeMismatch;
}

fn openWatchFd(path_z: [:0]const u8) !std.posix.fd_t {
    if (!is_macos) return error.Unsupported;

    const flags: std.c.O = if (@hasField(std.c.O, "EVTONLY"))
        .{ .EVTONLY = true }
    else
        .{ .ACCMODE = .RDONLY };

    const fd = std.c.open(path_z.ptr, flags);
    switch (std.posix.errno(fd)) {
        .SUCCESS => return @intCast(fd),
        .NOENT => return error.FileNotFound,
        .ACCES => return error.AccessDenied,
        else => return error.Unexpected,
    }
}

fn inotifyMask(mask: WatchEventMask) u32 {
    var result: u32 = 0;
    if (mask.created) {
        result |= std.os.linux.IN.CREATE;
    }
    if (mask.modified) {
        result |= std.os.linux.IN.MODIFY | std.os.linux.IN.ATTRIB | std.os.linux.IN.CLOSE_WRITE;
    }
    if (mask.deleted) {
        result |= std.os.linux.IN.DELETE | std.os.linux.IN.DELETE_SELF;
    }
    if (mask.renamed) {
        result |= std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO | std.os.linux.IN.MOVE_SELF;
    }
    if (result == 0) {
        result = std.os.linux.IN.ALL_EVENTS;
    }
    return result;
}

fn trimInotifyName(name_bytes: []const u8) []const u8 {
    const nul_index = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
    return name_bytes[0..nul_index];
}

fn removeInotifyWatch(fd: std.posix.fd_t, wd: i32) void {
    const rc = std.c.inotify_rm_watch(fd, wd);
    switch (std.posix.errno(rc)) {
        .SUCCESS, .INVAL => return,
        else => return,
    }
}

fn pollSnapshot(path: []const u8) !PollingSnapshot {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return .{ .exists = false, .modified = null, .size = 0 },
        else => return err,
    };

    return .{
        .exists = true,
        .modified = stat.mtime,
        .size = stat.size,
    };
}

fn registerWatchFd(kq_fd: std.posix.fd_t, watch_fd: std.posix.fd_t, watch_id: i64, mask: WatchEventMask) !void {
    if (!is_macos) return error.Unsupported;

    var fflags: u32 = 0;
    if (mask.created or mask.modified) {
        fflags |= std.c.NOTE.WRITE | std.c.NOTE.EXTEND | std.c.NOTE.ATTRIB;
    }
    if (mask.deleted) {
        fflags |= std.c.NOTE.DELETE;
    }
    if (mask.renamed) {
        fflags |= std.c.NOTE.RENAME;
    }
    if (fflags == 0) {
        fflags = std.c.NOTE.WRITE | std.c.NOTE.EXTEND | std.c.NOTE.ATTRIB | std.c.NOTE.DELETE | std.c.NOTE.RENAME;
    }

    const ev = std.posix.Kevent{
        .ident = @intCast(watch_fd),
        .filter = std.c.EVFILT.VNODE,
        .flags = std.c.EV.ADD | std.c.EV.CLEAR,
        .fflags = fflags,
        .data = 0,
        .udata = @intCast(watch_id),
    };
    _ = try std.posix.kevent(kq_fd, &.{ev}, &.{}, null);
}

fn unregisterWatchFd(kq_fd: std.posix.fd_t, watch_fd: std.posix.fd_t) !void {
    if (!is_macos) return error.Unsupported;

    const ev = std.posix.Kevent{
        .ident = @intCast(watch_fd),
        .filter = std.c.EVFILT.VNODE,
        .flags = std.c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    _ = std.posix.kevent(kq_fd, &.{ev}, &.{}, null) catch |err| switch (err) {
        error.EventNotFound => return,
        else => return err,
    };
}

test "watcher-create creates watcher resource" {
    if (!supports_event_watch) return;

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .symbol = "event" });
    try nativeWatcherCreate(&ctx);

    const resource = try helpers.popResource(&ctx);
    defer watcherCloseFn(resource.ptr.?);

    try std.testing.expectEqualStrings("watcher", resource.type_name);
    try std.testing.expect(resource.ptr != null);
}

test "watcher-add and watcher-read observe file modification" {
    if (!supports_event_watch) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "watched.txt", .data = "hello" });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "watched.txt");
    defer std.testing.allocator.free(path);

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .symbol = "event" });
    try nativeWatcherCreate(&ctx);
    const resource = try helpers.popResource(&ctx);
    defer {
        if (!resource.closed) watcherCloseFn(resource.ptr.?);
    }

    const flag_items = try ctx.quotationAllocator().alloc(value_mod.Value, 1);
    flag_items[0] = .{ .symbol = "modified" };
    try ctx.stack.push(.{ .resource = resource });
    try ctx.stack.push(.{ .string = try ctx.quotationAllocator().dupe(u8, path) });
    try ctx.stack.push(.{ .array = flag_items });
    try nativeWatcherAdd(&ctx);
    const watch_id = try helpers.popFixnum(&ctx);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "world" });

    try ctx.stack.push(.{ .resource = resource });
    try nativeWatcherRead(&ctx);
    const hash = (try ctx.stack.pop()).hash;

    try std.testing.expectEqual(watch_id, hash.get("watch-id").?.fixnum);
    try std.testing.expectEqualStrings("modified", hash.get("kind").?.symbol);
    try std.testing.expectEqualStrings(path, hash.get("path").?.string);

    try ctx.stack.push(.{ .resource = resource });
    try ctx.stack.push(.{ .fixnum = watch_id });
    try nativeWatcherRemove(&ctx);
}

test "watcher-probe reports true for existing file" {
    if (!supports_event_watch) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "probe.txt", .data = "x" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "probe.txt");
    defer std.testing.allocator.free(path);

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .string = try ctx.quotationAllocator().dupe(u8, path) });
    try nativeWatcherProbe(&ctx);
    const result = try helpers.popBoolean(&ctx);
    try std.testing.expect(result);
}
