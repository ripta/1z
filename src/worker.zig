const std = @import("std");
const Allocator = std.mem.Allocator;
const scheduler_mod = @import("scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const WorkerOps = scheduler_mod.WorkerOps;
const monotonicNowNs = scheduler_mod.monotonicNowNs;
const Task = @import("task.zig").Task;
const TaskStatus = @import("task.zig").TaskStatus;
const Multiplexer = @import("multiplexer.zig").Multiplexer;
const WakeSource = @import("multiplexer.zig").WakeSource;
const trace = @import("trace.zig");

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
    .nextTaskId = nextTaskIdCb,
    .recordPoolProgress = recordPoolProgressCb,
    .poolLastProgressNs = poolLastProgressNsCb,
    .poolDeadlockThresholdNs = poolDeadlockThresholdNsCb,
    .claimStallReport = claimStallReportCb,
    .emitPoolStallDetect = emitPoolStallDetectCb,
    .dumpAllPoolTasks = dumpAllPoolTasksCb,
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

fn nextTaskIdCb(owner: *anyopaque) u64 {
    const w: *Worker = @ptrCast(@alignCast(owner));
    return w.pool.?.next_task_id.fetchAdd(1, .acq_rel);
}

fn recordPoolProgressCb(owner: *anyopaque, now_ns: i128) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.pool.?.last_progress_ns.store(now_ns, .release);
}

fn poolLastProgressNsCb(owner: *anyopaque) i128 {
    const w: *Worker = @ptrCast(@alignCast(owner));
    return w.pool.?.last_progress_ns.load(.acquire);
}

fn poolDeadlockThresholdNsCb(owner: *anyopaque) ?i128 {
    const w: *Worker = @ptrCast(@alignCast(owner));
    return w.pool.?.deadlock_threshold_ns;
}

fn claimStallReportCb(owner: *anyopaque) bool {
    const w: *Worker = @ptrCast(@alignCast(owner));
    // CAS-elect a single reporter so only one worker dumps and exits even
    // when several workers cross the threshold in the same poll cycle.
    return w.pool.?.stall_reported.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
}

fn emitPoolStallDetectCb(owner: *anyopaque, threshold_ns: i128) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.pool.?.emitStallDetect(threshold_ns);
}

fn dumpAllPoolTasksCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.pool.?.dumpAllTasks();
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
    /// Back-pointer to the owning `WorkerPool`. Set by `WorkerPool.init`
    /// after the worker lives in its final slot so the pointer is stable.
    /// Null for free-standing `Worker` values used in unit tests that do
    /// not exercise pool-level coordination.
    pool: ?*WorkerPool = null,

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
    /// Globally-unique task ID counter. Every `Scheduler.nextId` call
    /// invoked through a worker draws from here so a single integer
    /// unambiguously identifies a task across the whole program. Drives
    /// deterministic ordering in aggregated diagnostic dumps.
    next_task_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    /// Monotonic timestamp (nanoseconds) of the most recent progress event
    /// observed by any worker -- task completion, sleeper wake, or I/O
    /// readiness. Updated by every worker through `Scheduler.recordProgress`.
    /// Read by every worker's stall-detect computation so a busy
    /// background worker correctly suppresses a stall warning on an idle
    /// primary.
    last_progress_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),
    /// Stall detection threshold, propagated from `ctx.deadlock_detect_ns`
    /// by `task-scope`. Null disables stall detection. Read by every
    /// worker; never mutated after `task-scope` writes it.
    deadlock_threshold_ns: ?i128 = null,
    /// CAS guard ensuring only one worker emits the stall dump and calls
    /// `std.process.exit(124)` when multiple workers simultaneously detect
    /// the threshold has been exceeded.
    stall_reported: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Initialize `pool` in place. Takes a self-pointer so worker
    /// back-pointers can be set during construction; this guarantees
    /// every worker has a stable pool pointer before any callback runs
    /// and removes the per-call-site wire-up step.
    pub fn init(pool: *WorkerPool, allocator: Allocator, count: usize) !void {
        std.debug.assert(count >= 1);
        const workers = try allocator.alloc(Worker, count);
        errdefer allocator.free(workers);
        pool.* = .{ .workers = workers, .allocator = allocator };
        var initialized: usize = 0;
        errdefer for (workers[0..initialized]) |*w| w.deinit();
        for (workers, 0..) |*w, i| {
            w.* = try Worker.init(allocator, i);
            initialized += 1;
            // Wire all back-pointers after the worker lives in its final
            // slot so every pointer is stable.
            w.scheduler.owner = @ptrCast(w);
            w.scheduler.ops = &worker_ops;
            w.pool = pool;
        }
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

    /// Lock every worker's `all_tasks_mu` in ascending worker-id order so
    /// the snapshot used by diagnostic dumps is consistent across workers
    /// even while they continue running. Returns a fixed lock ordering
    /// that prevents deadlock against itself.
    fn lockAllTasksMu(self: *WorkerPool) void {
        for (self.workers) |*w| w.scheduler.all_tasks_mu.lock();
    }

    fn unlockAllTasksMu(self: *WorkerPool) void {
        var i: usize = self.workers.len;
        while (i > 0) {
            i -= 1;
            self.workers[i].scheduler.all_tasks_mu.unlock();
        }
    }

    fn countActive(self: *WorkerPool) struct { active: usize, runnable: usize } {
        var active: usize = 0;
        var runnable: usize = 0;
        for (self.workers) |*w| {
            const sched = &w.scheduler;
            for (sched.all_tasks.items) |task| {
                switch (task.getStatus()) {
                    .completed, .failed, .cancelled => continue,
                    .pending, .running => {},
                }
                active += 1;
                const home = task.ctx.scheduler orelse sched;
                if (home.taskState(task) == .runnable) runnable += 1;
            }
        }
        return .{ .active = active, .runnable = runnable };
    }

    /// Emit the `STALL-DETECT: ...` header counting active and runnable
    /// tasks across every worker. Holds all `all_tasks_mu` locks for the
    /// duration of the count.
    pub fn emitStallDetect(self: *WorkerPool, threshold_ns: i128) void {
        var tw = trace.TraceWriter.init();
        const secs = @as(f64, @floatFromInt(@as(i64, @intCast(@min(threshold_ns, std.math.maxInt(i64)))))) / @as(f64, @floatFromInt(@as(i64, std.time.ns_per_s)));

        self.lockAllTasksMu();
        defer self.unlockAllTasksMu();

        const counts = self.countActive();
        tw.print("STALL-DETECT: {d:.1}s with no progress, {d} tasks, {d} runnable\n", .{ secs, counts.active, counts.runnable });
    }

    /// Dump every active task across the pool to stderr, sorted by global
    /// task ID for deterministic output. Each task is printed via its
    /// home scheduler so per-state details (current_task, sleep_queue)
    /// resolve correctly.
    pub fn dumpAllTasks(self: *WorkerPool) void {
        var tw = trace.TraceWriter.init();

        self.lockAllTasksMu();
        defer self.unlockAllTasksMu();

        const counts = self.countActive();
        tw.print("TASK-DUMP: {d} tasks, {d} runnable\n", .{ counts.active, counts.runnable });

        // Gather all active tasks into a single slice, then sort by id so
        // output is stable regardless of which worker hosts each task.
        var collected: std.ArrayListUnmanaged(*Task) = .{};
        defer collected.deinit(self.allocator);
        for (self.workers) |*w| {
            for (w.scheduler.all_tasks.items) |task| {
                switch (task.getStatus()) {
                    .completed, .failed, .cancelled => continue,
                    .pending, .running => {},
                }
                collected.append(self.allocator, task) catch return;
            }
        }
        std.mem.sort(*Task, collected.items, {}, taskIdLessThan);

        for (collected.items) |task| {
            const home = task.ctx.scheduler orelse &self.workers[0].scheduler;
            home.dumpOneTask(&tw, task);
        }
    }
};

fn taskIdLessThan(_: void, a: *Task, b: *Task) bool {
    return a.id < b.id;
}

// =============================================================================
// Tests
// =============================================================================

test "WorkerPool init and deinit with n=1" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 1), pool.workers.len);
    try std.testing.expectEqual(@as(usize, 0), pool.primary().id);
}

test "WorkerPool init and deinit with n=4" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 4);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 4), pool.workers.len);
    for (pool.workers, 0..) |*w, i| {
        try std.testing.expectEqual(i, w.id);
    }
}

test "WorkerPool wires scheduler owner back-pointer" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 3);
    defer pool.deinit();

    for (pool.workers) |*w| {
        try std.testing.expect(w.scheduler.owner != null);
        try std.testing.expectEqual(@as(*anyopaque, @ptrCast(w)), w.scheduler.owner.?);
    }
}

test "WorkerPool startBackgroundWorkers and join" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 3);
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
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 3);
    defer pool.deinit();

    pool.workers[0].active_tasks.store(2, .release);
    pool.workers[1].active_tasks.store(0, .release);
    pool.workers[2].active_tasks.store(1, .release);

    try std.testing.expectEqual(@as(usize, 1), pool.pickLeastLoaded().id);
}

test "pickLeastLoaded breaks ties by lower id" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 3);
    defer pool.deinit();

    pool.workers[0].active_tasks.store(2, .release);
    pool.workers[1].active_tasks.store(2, .release);
    pool.workers[2].active_tasks.store(2, .release);

    try std.testing.expectEqual(@as(usize, 0), pool.pickLeastLoaded().id);
}

test "Worker.enqueueExternal then drainExternal returns the task" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
    defer pool.deinit();

    var dummy_task: Task = undefined;
    try pool.workers[0].enqueueExternal(&dummy_task);

    pool.workers[0].drainExternal();
    try std.testing.expectEqual(@as(usize, 1), pool.workers[0].scheduler.run_queue.items.len);
    try std.testing.expectEqual(&dummy_task, pool.workers[0].scheduler.run_queue.items[0]);
}

test "Worker.requestCancellation appends to cancel queue" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
    defer pool.deinit();

    var dummy_task: Task = undefined;
    try pool.workers[0].requestCancellation(&dummy_task);

    try std.testing.expectEqual(@as(usize, 1), pool.workers[0].cancel_queue.items.len);
    try std.testing.expectEqual(&dummy_task, pool.workers[0].cancel_queue.items[0]);
}

test "Worker.drainCancellations clears the cancel queue" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
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

test "WorkerPool.init wires the pool back-pointer on every worker" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 3);
    defer pool.deinit();

    for (pool.workers) |*w| {
        try std.testing.expectEqual(&pool, w.pool.?);
    }
}

test "WorkerPool.next_task_id allocates unique ids across workers" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 3);
    defer pool.deinit();

    const id0 = pool.workers[0].scheduler.nextId();
    const id1 = pool.workers[1].scheduler.nextId();
    const id2 = pool.workers[2].scheduler.nextId();
    const id3 = pool.workers[0].scheduler.nextId();

    try std.testing.expectEqual(@as(u64, 1), id0);
    try std.testing.expectEqual(@as(u64, 2), id1);
    try std.testing.expectEqual(@as(u64, 3), id2);
    try std.testing.expectEqual(@as(u64, 4), id3);
}

test "Worker.signalShutdown causes runThread to return" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 2);
    defer pool.deinit();

    // Shutdown both so the test does not depend on the new background-blocking
    // exit predicate; the background worker observes shutdown and exits.
    for (pool.workers[1..]) |*w| w.signalShutdown();
    try pool.startBackgroundWorkers();
    pool.join();
}
