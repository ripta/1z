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

const WatchEntry = struct {
    fd: std.posix.fd_t,
    path: []u8,
    mask: WatchEventMask,
};

const NativeWatcher = struct {
    allocator: std.mem.Allocator,
    kq_fd: std.posix.fd_t,
    next_watch_id: i64 = 1,
    watches: std.AutoHashMapUnmanaged(i64, WatchEntry) = .{},
    pending: std.ArrayListUnmanaged(PendingEvent) = .{},

    fn init(allocator: std.mem.Allocator) !*NativeWatcher {
        if (!is_macos) return error.Unsupported;

        const watcher = try allocator.create(NativeWatcher);
        errdefer allocator.destroy(watcher);

        watcher.* = .{
            .allocator = allocator,
            .kq_fd = try std.posix.kqueue(),
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

        var it = self.watches.iterator();
        while (it.next()) |entry| {
            std.posix.close(entry.value_ptr.fd);
            self.allocator.free(entry.value_ptr.path);
        }
        self.watches.deinit(self.allocator);

        std.posix.close(self.kq_fd);
        self.allocator.destroy(self);
    }

    fn addWatch(self: *NativeWatcher, path: []const u8, mask: WatchEventMask) !i64 {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const watch_fd = try openWatchFd(path_z);
        errdefer std.posix.close(watch_fd);

        const watch_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(watch_path);

        const watch_id = self.next_watch_id;
        self.next_watch_id += 1;

        try registerWatchFd(self.kq_fd, watch_fd, watch_id, mask);

        try self.watches.put(self.allocator, watch_id, .{
            .fd = watch_fd,
            .path = watch_path,
            .mask = mask,
        });

        return watch_id;
    }

    fn removeWatch(self: *NativeWatcher, watch_id: i64) !void {
        const removed = self.watches.fetchRemove(watch_id) orelse return error.KeyNotFound;
        unregisterWatchFd(self.kq_fd, removed.value.fd) catch {};
        std.posix.close(removed.value.fd);
        self.allocator.free(removed.value.path);
    }

    fn readEvent(self: *NativeWatcher, scheduler: ?*Scheduler) !PendingEvent {
        while (true) {
            if (self.pending.items.len > 0) {
                return self.pending.orderedRemove(0);
            }

            try self.drainKqueue(false);
            if (self.pending.items.len > 0) {
                return self.pending.orderedRemove(0);
            }

            if (scheduler) |sched| {
                streams.setNonBlockingFd(self.kq_fd);
                sched.ioSuspendCurrentTask(self.kq_fd, .read);
            } else {
                try self.drainKqueue(true);
            }
        }
    }

    fn drainKqueue(self: *NativeWatcher, blocking: bool) !void {
        var events: [8]std.posix.Kevent = undefined;
        const timeout_ptr: ?*const std.posix.timespec = if (blocking) null else &.{ .sec = 0, .nsec = 0 };
        const count = try std.posix.kevent(self.kq_fd, &.{}, &events, timeout_ptr);
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
};

fn nativeWatcherCreate(ctx: *Context) anyerror!void {
    const mode = try helpers.popSymbol(ctx);
    if (!std.mem.eql(u8, mode, "event")) {
        helpers.setErrorContext(ctx, "watcher-create: unsupported mode {s}:", .{mode});
        return error.IOFailed;
    }
    if (!is_macos) {
        helpers.setErrorContext(ctx, "watcher-create: event watchers are only implemented on macOS", .{});
        return error.IOFailed;
    }

    const watcher = try NativeWatcher.init(ctx.quotationAllocator());
    const resource = try ctx.quotationAllocator().create(Resource);
    resource.* = .{
        .type_name = "watcher",
        .ptr = @ptrCast(watcher),
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

    const watch_id = watcher.addWatch(path, if (mask.empty()) WatchEventMask.all() else mask) catch |err| {
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

    watcher.removeWatch(watch_id) catch {
        helpers.setErrorContext(ctx, "watcher-remove: unknown watch id {d}", .{watch_id});
        return error.KeyNotFound;
    };
}

fn nativeWatcherRead(ctx: *Context) anyerror!void {
    const watcher_resource = try popWatcherResource(ctx, "watcher-read");
    const watcher = watcherFromResource(watcher_resource);

    while (true) {
        const event = watcher.readEvent(ctx.scheduler) catch |err| {
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
    if (!is_macos) {
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

fn watcherFromResource(resource: *Resource) *NativeWatcher {
    return @ptrCast(@alignCast(resource.ptr.?));
}

fn watcherCloseFn(ptr: *anyopaque) void {
    const watcher: *NativeWatcher = @ptrCast(@alignCast(ptr));
    watcher.deinit();
}

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
    if (!is_macos) return;

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
    if (!is_macos) return;

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
    if (!is_macos) return;

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
