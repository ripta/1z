const std = @import("std");
const Allocator = std.mem.Allocator;
const scheduler_mod = @import("scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const WorkerOps = scheduler_mod.WorkerOps;
const Task = @import("task.zig").Task;
const Multiplexer = @import("multiplexer.zig").Multiplexer;
const WakeSource = @import("multiplexer.zig").WakeSource;

/// Static `WorkerOps` table used by every `Worker` so the scheduler can
/// call back into the worker through type-erased pointers without forming
/// an import cycle.
const worker_ops: WorkerOps = .{
    .drainExternal = drainExternalCb,
    .onTaskDone = onTaskDoneCb,
    .shutdownRequested = shutdownRequestedCb,
    .drainWake = drainWakeCb,
    .isPrimary = isPrimaryCb,
    .enqueueExternal = enqueueExternalCb,
    .requestCancellation = requestCancellationCb,
    .drainCancellations = drainCancellationsCb,
};

fn drainExternalCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.drainExternal();
}

fn onTaskDoneCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    _ = w.active_tasks.fetchSub(1, .acq_rel);
}

fn shutdownRequestedCb(owner: *anyopaque) bool {
    const w: *Worker = @ptrCast(@alignCast(owner));
    return w.shutdown.load(.acquire);
}

fn drainWakeCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.wake.drain();
}

fn isPrimaryCb(owner: *anyopaque) bool {
    const w: *Worker = @ptrCast(@alignCast(owner));
    return w.id == 0;
}

fn enqueueExternalCb(owner: *anyopaque, task: *Task) !void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    try w.enqueueExternal(task);
}

fn requestCancellationCb(owner: *anyopaque, task: *Task) !void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    try w.requestCancellation(task);
}

fn drainCancellationsCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.drainCancellations();
}

/// A single OS thread with its own scheduler instance.
///
/// Each worker owns a scheduler (run queue, sleep queue, multiplexer), an
/// atomic count of active tasks for spawn-time load balancing, a thread-safe
/// external queue for cross-thread enqueues, a wake source so other threads
/// can interrupt a blocking `multiplexer.poll()`, and a shutdown flag the
/// driver sets when the worker should drain and exit.
pub const Worker = struct {
    id: usize,
    scheduler: Scheduler,
    thread: ?std.Thread = null,
    /// Allocator used for the external queue. Copied from the pool's
    /// allocator at init time; matches the scheduler's allocator.
    allocator: Allocator,
    /// Atomic count of tasks currently assigned to this worker that have
    /// not yet reached a terminal state. Read by `pickLeastLoaded` at
    /// spawn time; incremented by the spawner before enqueueing the task;
    /// decremented by the worker's scheduler when the task transitions to
    /// completed/failed/cancelled.
    active_tasks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Cross-thread task enqueue buffer. Spawners on other worker threads
    /// append here under `external_queue_mu` and signal `wake`; this
    /// worker's scheduler drains it at the top of every loop iteration.
    external_queue: std.ArrayListUnmanaged(*Task) = .{},
    external_queue_mu: std.Thread.Mutex = .{},
    /// Cross-thread cancellation request buffer. Cancellers on other
    /// worker threads append a target task here under `cancel_queue_mu`
    /// and signal `wake`; this worker's scheduler drains it at the top of
    /// every loop iteration and runs the local cancellation logic for
    /// each entry. Separating cancellation from `external_queue` lets the
    /// home worker route the task through its own per-state cleanup
    /// (IO/sleep/process/scope/channel) instead of unconditionally
    /// appending to the run queue.
    cancel_queue: std.ArrayListUnmanaged(*Task) = .{},
    cancel_queue_mu: std.Thread.Mutex = .{},
    /// Wake source registered with `scheduler.multiplexer`; lets other
    /// threads interrupt a blocking `poll()` so newly enqueued external
    /// tasks are observed promptly.
    wake: WakeSource,
    /// Set by the driver (typically the primary worker at top-level
    /// `task-scope` exit) to tell this worker to drain its queues and
    /// return from `runLoop`.
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: Allocator, id: usize) !Worker {
        var sched = try Scheduler.init(allocator);
        errdefer sched.deinit();

        const wake = try sched.multiplexer.addWakeSource();

        return .{
            .id = id,
            .scheduler = sched,
            .allocator = allocator,
            .wake = wake,
        };
    }

    pub fn deinit(self: *Worker) void {
        self.wake.deinit();
        self.external_queue.deinit(self.allocator);
        self.cancel_queue.deinit(self.allocator);
        self.scheduler.deinit();
    }

    /// Append a task to this worker's cross-thread external queue and wake
    /// the worker if it is blocked in `poll()`. Safe to call from any
    /// thread. The caller is responsible for incrementing `active_tasks`
    /// before enqueueing so spawn-time load balancing sees the new load
    /// even before the worker dequeues.
    pub fn enqueueExternal(self: *Worker, task: *Task) !void {
        {
            self.external_queue_mu.lock();
            defer self.external_queue_mu.unlock();
            try self.external_queue.append(self.allocator, task);
        }
        self.wake.signal();
    }

    /// Drain the external queue into the scheduler's run queue. Owning
    /// thread only.
    pub fn drainExternal(self: *Worker) void {
        self.external_queue_mu.lock();
        defer self.external_queue_mu.unlock();
        if (self.external_queue.items.len == 0) return;
        for (self.external_queue.items) |t| {
            self.scheduler.run_queue.append(self.allocator, t) catch {};
        }
        self.external_queue.clearRetainingCapacity();
    }

    /// Append a task to this worker's cross-thread cancellation queue and
    /// wake the worker. Safe to call from any thread. The flag on the
    /// task itself is set by the caller before enqueuing so the home
    /// worker can short-circuit duplicate requests on dequeue.
    pub fn requestCancellation(self: *Worker, task: *Task) !void {
        {
            self.cancel_queue_mu.lock();
            defer self.cancel_queue_mu.unlock();
            try self.cancel_queue.append(self.allocator, task);
        }
        self.wake.signal();
    }

    /// Drain the cancellation queue, processing each entry through the
    /// scheduler's local cancellation path. Owning thread only.
    ///
    /// Snapshots the queue under the lock so per-task processing (which
    /// may touch maps owned by this worker's scheduler) happens without
    /// holding the cancellation-queue mutex.
    pub fn drainCancellations(self: *Worker) void {
        var snapshot: std.ArrayListUnmanaged(*Task) = .{};
        defer snapshot.deinit(self.allocator);
        {
            self.cancel_queue_mu.lock();
            defer self.cancel_queue_mu.unlock();
            if (self.cancel_queue.items.len == 0) return;
            snapshot.appendSlice(self.allocator, self.cancel_queue.items) catch {};
            self.cancel_queue.clearRetainingCapacity();
        }
        for (snapshot.items) |t| {
            self.scheduler.cancelTaskLocal(t);
        }
    }

    /// Signal that this worker should exit `runLoop` as soon as its local
    /// queues are empty. Wakes the worker if it is blocked in `poll()`.
    pub fn signalShutdown(self: *Worker) void {
        self.shutdown.store(true, .release);
        self.wake.signal();
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
            // Wire the scheduler's owner back-pointer to this worker after
            // the worker lives in its final slot so the pointer is stable.
            w.scheduler.owner = @ptrCast(w);
            w.scheduler.ops = &worker_ops;
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

    /// Pick the worker with the smallest active-task count. Ties are
    /// broken by lower id (deterministic). Safe to call from any thread.
    pub fn pickLeastLoaded(self: *WorkerPool) *Worker {
        var best: *Worker = &self.workers[0];
        var best_load = best.active_tasks.load(.acquire);
        for (self.workers[1..]) |*w| {
            const load = w.active_tasks.load(.acquire);
            if (load < best_load) {
                best = w;
                best_load = load;
            }
        }
        return best;
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

test "WorkerPool wires scheduler owner back-pointer" {
    var pool = try WorkerPool.init(std.testing.allocator, 3);
    defer pool.deinit();

    for (pool.workers) |*w| {
        try std.testing.expect(w.scheduler.owner != null);
        try std.testing.expectEqual(@as(*anyopaque, @ptrCast(w)), w.scheduler.owner.?);
    }
}

test "WorkerPool startBackgroundWorkers and join" {
    var pool = try WorkerPool.init(std.testing.allocator, 3);
    defer pool.deinit();

    // Signal shutdown before starting so the background workers exit promptly.
    for (pool.workers[1..]) |*w| w.signalShutdown();

    try pool.startBackgroundWorkers();
    pool.join();

    for (pool.workers[1..]) |*w| {
        try std.testing.expect(w.thread == null);
    }
}

test "pickLeastLoaded returns worker with smallest active count" {
    var pool = try WorkerPool.init(std.testing.allocator, 3);
    defer pool.deinit();

    pool.workers[0].active_tasks.store(2, .release);
    pool.workers[1].active_tasks.store(0, .release);
    pool.workers[2].active_tasks.store(1, .release);

    try std.testing.expectEqual(@as(usize, 1), pool.pickLeastLoaded().id);
}

test "pickLeastLoaded breaks ties by lower id" {
    var pool = try WorkerPool.init(std.testing.allocator, 3);
    defer pool.deinit();

    pool.workers[0].active_tasks.store(2, .release);
    pool.workers[1].active_tasks.store(2, .release);
    pool.workers[2].active_tasks.store(2, .release);

    try std.testing.expectEqual(@as(usize, 0), pool.pickLeastLoaded().id);
}

test "Worker.enqueueExternal then drainExternal returns the task" {
    var pool = try WorkerPool.init(std.testing.allocator, 1);
    defer pool.deinit();

    var dummy_task: Task = undefined;
    try pool.workers[0].enqueueExternal(&dummy_task);

    pool.workers[0].drainExternal();
    try std.testing.expectEqual(@as(usize, 1), pool.workers[0].scheduler.run_queue.items.len);
    try std.testing.expectEqual(&dummy_task, pool.workers[0].scheduler.run_queue.items[0]);
}

test "Worker.requestCancellation appends to cancel queue" {
    var pool = try WorkerPool.init(std.testing.allocator, 1);
    defer pool.deinit();

    var dummy_task: Task = undefined;
    try pool.workers[0].requestCancellation(&dummy_task);

    try std.testing.expectEqual(@as(usize, 1), pool.workers[0].cancel_queue.items.len);
    try std.testing.expectEqual(&dummy_task, pool.workers[0].cancel_queue.items[0]);
}

test "Worker.drainCancellations clears the cancel queue" {
    var pool = try WorkerPool.init(std.testing.allocator, 1);
    defer pool.deinit();

    // Use a completed-status task so drainCancellations' early-out
    // skips dereferencing the rest of the Task (avoids a synthetic
    // Context/TaskScope here; the end-to-end path is covered by the
    // task_cross_thread_cancel integration test).
    var done_task: Task = undefined;
    done_task.status = std.atomic.Value(@import("task.zig").TaskStatus).init(.completed);

    try pool.workers[0].requestCancellation(&done_task);
    try std.testing.expectEqual(@as(usize, 1), pool.workers[0].cancel_queue.items.len);

    pool.workers[0].drainCancellations();
    try std.testing.expectEqual(@as(usize, 0), pool.workers[0].cancel_queue.items.len);
}

test "Worker.signalShutdown causes runThread to return" {
    var pool = try WorkerPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    // Shutdown both so the test does not depend on the new background-blocking
    // exit predicate; the background worker observes shutdown and exits.
    for (pool.workers[1..]) |*w| w.signalShutdown();
    try pool.startBackgroundWorkers();
    pool.join();
}
