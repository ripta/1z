const std = @import("std");
const Allocator = std.mem.Allocator;
const Scheduler = @import("scheduler.zig").Scheduler;

/// A single OS thread with its own scheduler instance.
pub const Worker = struct {
    id: usize,
    scheduler: Scheduler,
    thread: ?std.Thread = null,

    pub fn init(allocator: Allocator, id: usize) !Worker {
        return .{ .id = id, .scheduler = try Scheduler.init(allocator) };
    }

    pub fn deinit(self: *Worker) void {
        self.scheduler.deinit();
    }

    fn runThread(self: *Worker) void {
        self.scheduler.runLoop();
    }
};

/// A pool of Workers, one per OS thread. Worker[0] runs on the calling thread.
pub const WorkerPool = struct {
    workers: []Worker,
    allocator: Allocator,

    pub fn init(allocator: Allocator, count: usize) !WorkerPool {
        std.debug.assert(count >= 1);
        const workers = try allocator.alloc(Worker, count);
        errdefer allocator.free(workers);
        var initialized: usize = 0;
        errdefer for (workers[0..initialized]) |*w| w.deinit();
        for (workers, 0..) |*w, i| {
            w.* = try Worker.init(allocator, i);
            initialized += 1;
        }
        return .{ .workers = workers, .allocator = allocator };
    }

    pub fn deinit(self: *WorkerPool) void {
        for (self.workers) |*w| w.deinit();
        self.allocator.free(self.workers);
    }

    /// Spawn OS threads for workers[1..]. Worker[0] runs on the calling thread.
    pub fn startBackgroundWorkers(self: *WorkerPool) !void {
        for (self.workers[1..]) |*w| {
            w.thread = try std.Thread.spawn(.{}, Worker.runThread, .{w});
        }
    }

    pub fn join(self: *WorkerPool) void {
        for (self.workers[1..]) |*w| {
            if (w.thread) |t| t.join();
            w.thread = null;
        }
    }

    pub fn primary(self: *WorkerPool) *Worker {
        return &self.workers[0];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "WorkerPool init and deinit with n=1" {
    var pool = try WorkerPool.init(std.testing.allocator, 1);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 1), pool.workers.len);
    try std.testing.expectEqual(@as(usize, 0), pool.primary().id);
}

test "WorkerPool init and deinit with n=4" {
    var pool = try WorkerPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 4), pool.workers.len);
    for (pool.workers, 0..) |*w, i| {
        try std.testing.expectEqual(i, w.id);
    }
}

test "WorkerPool startBackgroundWorkers and join" {
    var pool = try WorkerPool.init(std.testing.allocator, 3);
    defer pool.deinit();

    try pool.startBackgroundWorkers();
    pool.join();

    for (pool.workers[1..]) |*w| {
        try std.testing.expect(w.thread == null);
    }
}
