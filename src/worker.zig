const std = @import("std");
const builtin = @import("builtin");
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
const MemoryLimitAllocator = @import("memory_limit.zig").MemoryLimitAllocator;
const portable_atomic = @import("portable_atomic.zig");

/// Static `WorkerOps` table used by every `Worker` so the scheduler can
/// call back into the worker through type-erased pointers without forming
/// an import cycle.
const worker_ops: WorkerOps = .{
    .drainExternal = drainExternalCb,
    .onTaskSpawned = onTaskSpawnedCb,
    .onTaskDone = onTaskDoneCb,
    .shutdownRequested = shutdownRequestedCb,
    .drainWake = drainWakeCb,
    .isPrimary = isPrimaryCb,
    .enqueueExternal = enqueueExternalCb,
    .requestCancellation = requestCancellationCb,
    .drainCancellations = drainCancellationsCb,
    .requestReap = requestReapCb,
    .drainReaps = drainReapsCb,
    .nextTaskId = nextTaskIdCb,
    .recordPoolProgress = recordPoolProgressCb,
    .poolLastProgressNs = poolLastProgressNsCb,
    .poolDeadlockThresholdNs = poolDeadlockThresholdNsCb,
    .poolStallVerdictEnabled = poolStallVerdictEnabledCb,
    .poolBlockedCounts = poolBlockedCountsCb,
    .claimStallReport = claimStallReportCb,
    .emitPoolStallDetect = emitPoolStallDetectCb,
    .dumpAllPoolTasks = dumpAllPoolTasksCb,
    .poolHasAliveTasks = poolHasAliveTasksCb,
    .wakePrimary = wakePrimaryCb,
    .poolSampleDeadlineNs = poolSampleDeadlineNsCb,
    .claimSampleTick = claimSampleTickCb,
    .emitPoolSample = emitPoolSampleCb,
    .onDetachedTaskDone = onDetachedTaskDoneCb,
};

fn drainExternalCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.drainExternal();
}

fn onTaskSpawnedCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    _ = w.active_tasks.fetchAdd(1, .acq_rel);
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

fn requestReapCb(owner: *anyopaque, task: *Task) !void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    try w.requestReap(task);
}

fn drainReapsCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.drainReaps();
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

fn poolStallVerdictEnabledCb(owner: *anyopaque) bool {
    const w: *Worker = @ptrCast(@alignCast(owner));
    return w.pool.?.report_stall_verdict;
}

fn poolBlockedCountsCb(owner: *anyopaque) Scheduler.BlockedCounts {
    const w: *Worker = @ptrCast(@alignCast(owner));
    return w.pool.?.blockedCounts();
}

fn claimStallReportCb(owner: *anyopaque) bool {
    const w: *Worker = @ptrCast(@alignCast(owner));
    // CAS-elect a single reporter so only one worker dumps and exits even
    // when several workers cross the threshold in the same poll cycle.
    return w.pool.?.stall_reported.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
}

fn emitPoolStallDetectCb(owner: *anyopaque, threshold_ns: i128, deadlocked: bool) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.pool.?.emitStallDetect(threshold_ns, deadlocked);
}

fn dumpAllPoolTasksCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.pool.?.dumpAllTasks();
}

fn poolHasAliveTasksCb(owner: *anyopaque) bool {
    const w: *Worker = @ptrCast(@alignCast(owner));
    return w.pool.?.anyAliveTasks();
}

fn wakePrimaryCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.pool.?.workers[0].wake.signal();
}

fn poolSampleDeadlineNsCb(owner: *anyopaque) ?i128 {
    const w: *Worker = @ptrCast(@alignCast(owner));
    const pool = w.pool.?;
    if (pool.sampling_tick_ns == null) return null;
    return pool.next_sample_ns.load(.acquire);
}

fn claimSampleTickCb(owner: *anyopaque, now_ns: i128) bool {
    const w: *Worker = @ptrCast(@alignCast(owner));
    return w.pool.?.claimSampleTick(now_ns);
}

fn emitPoolSampleCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    w.pool.?.emitSample();
}

fn onDetachedTaskDoneCb(owner: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(owner));
    _ = w.pool.?.detached_in_flight.fetchSub(1, .acq_rel);
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
    /// Cross-thread reap request buffer.
    ///
    /// When a scope exits on another worker, that worker appends each of this worker's terminal
    /// children here under `reap_queue_mu` and signals `wake`. This worker's scheduler drains it
    /// at the top of every loop iteration and frees each task on its own thread.
    ///
    /// Routing reaping through the home worker keeps task destruction on the owning worker.
    reap_queue: std.ArrayListUnmanaged(*Task) = .{},
    reap_queue_mu: std.Thread.Mutex = .{},
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
        self.reap_queue.deinit(self.allocator);
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

    /// Append a terminal task to this worker's cross-thread reap queue and wake the worker.
    ///
    /// Safe to call from any thread.
    ///
    /// The task is already terminal and enqueued exactly once by the exiting scope, so the home
    /// worker frees it exactly once when it drains.
    pub fn requestReap(self: *Worker, task: *Task) !void {
        {
            self.reap_queue_mu.lock();
            defer self.reap_queue_mu.unlock();
            try self.reap_queue.append(self.allocator, task);
        }
        self.wake.signal();
    }

    /// Drain the reap queue, freeing each terminal task on the owning thread.
    ///
    /// Owning thread only.
    ///
    /// Snapshots the queue under the lock so the frees happen without holding the reap-queue mutex.
    pub fn drainReaps(self: *Worker) void {
        var snapshot: std.ArrayListUnmanaged(*Task) = .{};
        defer snapshot.deinit(self.allocator);
        {
            self.reap_queue_mu.lock();
            defer self.reap_queue_mu.unlock();
            if (self.reap_queue.items.len == 0) return;
            snapshot.appendSlice(self.allocator, self.reap_queue.items) catch {};
            self.reap_queue.clearRetainingCapacity();
        }
        for (snapshot.items) |t| {
            self.scheduler.reapTrackedTask(t);
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

/// Pool-wide task counts for one sample tick.
pub const SampleCounts = struct { live: usize, retained: usize, detached: u32 };

/// Current and peak live bytes for one sample tick.
pub const MemSample = struct { bytes: usize, peak: usize };

/// Build one `SAMPLE:` line into `buf`. `t=` is always present. The task
/// fields appear only when `sample_tasks`; the memory fields only when `mem`
/// is set. Returns the written slice.
pub fn formatSample(buf: []u8, elapsed_ns: i128, sample_tasks: bool, counts: SampleCounts, mem: ?MemSample) []const u8 {
    const secs = @as(f64, @floatFromInt(@as(i64, @intCast(@min(elapsed_ns, std.math.maxInt(i64)))))) / @as(f64, @floatFromInt(@as(i64, std.time.ns_per_s)));
    var len: usize = 0;
    len += (std.fmt.bufPrint(buf[len..], "SAMPLE: t={d:.1}s", .{secs}) catch return buf[0..len]).len;
    if (sample_tasks) {
        len += (std.fmt.bufPrint(buf[len..], " live={d} retained={d} detached={d}", .{ counts.live, counts.retained, counts.detached }) catch return buf[0..len]).len;
    }
    if (mem) |m| {
        len += (std.fmt.bufPrint(buf[len..], " bytes={d} peak={d}", .{ m.bytes, m.peak }) catch return buf[0..len]).len;
    }
    len += (std.fmt.bufPrint(buf[len..], "\n", .{}) catch return buf[0..len]).len;
    return buf[0..len];
}

/// A pool of Workers, one per OS thread. Worker[0] runs on the calling thread.
pub const WorkerPool = struct {
    workers: []Worker,
    allocator: Allocator,
    /// Globally-unique task ID counter. Every `Scheduler.nextId` call
    /// invoked through a worker draws from here so a single integer
    /// unambiguously identifies a task across the whole program. Drives
    /// deterministic ordering in aggregated diagnostic dumps.
    next_task_id: portable_atomic.WideCounter(u64) = portable_atomic.WideCounter(u64).init(1),
    /// Monotonic timestamp (nanoseconds) of the most recent progress event
    /// observed by any worker -- task completion, sleeper wake, or I/O
    /// readiness. Updated by every worker through `Scheduler.recordProgress`.
    /// Read by every worker's stall-detect computation so a busy
    /// background worker correctly suppresses a stall warning on an idle
    /// primary.
    last_progress_ns: portable_atomic.WideCounter(i128) = portable_atomic.WideCounter(i128).init(0),
    /// No-progress threshold, propagated from `ctx.deadlock_detect_ns` by
    /// `task-scope`. Null disables both verdicts. Read by every worker;
    /// never mutated after `task-scope` writes it.
    deadlock_threshold_ns: ?i128 = null,
    /// Whether the bare no-progress stall is reported when the deadlock
    /// gate refuses, propagated alongside the threshold. Opt-in, because a
    /// pool running one long non-yielding task satisfies the threshold.
    report_stall_verdict: bool = false,
    /// CAS guard ensuring only one worker emits the stall dump and calls
    /// `std.process.exit(124)` when multiple workers simultaneously detect
    /// the threshold has been exceeded.
    stall_reported: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Periodic task/memory sampler state, set by `task-scope` from
    // `ctx.trace` when an axis is enabled. All fields are read by every
    // worker's run loop; the tick interval and axis flags are written once
    // before background workers start and never mutated after.
    //
    // `sampling_tick_ns` null disables the sampler entirely.
    sample_tasks: bool = false,
    sample_memory: bool = false,
    sampling_tick_ns: ?i128 = null,
    /// The memory-cap allocator, read for the `bytes=`/`peak=` figures.
    mem_limit: ?*MemoryLimitAllocator = null,
    /// Count of in-flight detached tasks across the pool, the `detached=`
    /// field. Per-scope `detached_active` is not summable pool-wide because
    /// there is no scope registry, so this pool-level atomic mirrors it.
    detached_in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Monotonic deadline of the next sample. The worker that advances it past
    /// `now` via CAS is the sole emitter for that tick, re-arming it to
    /// `now + interval` for a steady cadence.
    next_sample_ns: portable_atomic.WideCounter(i128) = portable_atomic.WideCounter(i128).init(0),
    /// Monotonic timestamp when sampling started, for the `t=` elapsed field.
    sampler_started_ns: i128 = 0,

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
    /// No-op under single_threaded builds: `std.Thread.spawn` is a hard compile
    /// error under `single_threaded = true`, regardless of whether this loop
    /// ever iterates, since Zig analyzes the call site, not the runtime bound.
    /// Every target that sets `single_threaded = true` today also forces the
    /// worker count to 1 in `primitives/tasks.zig`, via a separate
    /// `is_freestanding` check -- not because of this guard.
    pub fn startBackgroundWorkers(self: *WorkerPool) !void {
        if (builtin.single_threaded) return;
        for (self.workers[1..]) |*w| {
            w.thread = try std.Thread.spawn(.{}, Worker.runThread, .{w});
        }
    }

    pub fn join(self: *WorkerPool) void {
        if (builtin.single_threaded) return;
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

    /// Try to take every worker's `all_tasks_mu` in ascending id order. On any unavailable
    /// lock, release what was acquired and report false.
    ///
    /// Lets the allocation-path sampler back off instead of deadlocking: the allocating thread
    /// may already hold one of these locks, since `trackTask`, `handleTaskDone`, and
    /// `dumpAllTasks` all allocate inside their critical sections.
    fn tryLockAllTasksMu(self: *WorkerPool) bool {
        for (self.workers, 0..) |*w, acquired| {
            if (!w.scheduler.all_tasks_mu.tryLock()) {
                var i = acquired;
                while (i > 0) {
                    i -= 1;
                    self.workers[i].scheduler.all_tasks_mu.unlock();
                }
                return false;
            }
        }
        return true;
    }

    /// Return true if any worker in the pool owns a non-terminal task.
    /// Locks every worker's `all_tasks_mu` in ascending id order so the
    /// answer is consistent against concurrent spawns; the spawner has to
    /// take the target worker's `all_tasks_mu` inside `trackTask` before
    /// the new task is observable, so if a spawn is in progress this call
    /// either sees the task or blocks until the spawner finishes.
    fn anyAliveTasks(self: *WorkerPool) bool {
        self.lockAllTasksMu();
        defer self.unlockAllTasksMu();
        for (self.workers) |*w| {
            for (w.scheduler.all_tasks.items) |task| {
                switch (task.getStatus()) {
                    .completed, .failed, .cancelled => continue,
                    .pending, .running => return true,
                }
            }
        }
        return false;
    }

    /// Count live tasks across every worker for a header. Each task is classified by its home
    /// scheduler, so `current_task` and the sleep queue resolve against the right worker. The
    /// caller holds every `all_tasks_mu`.
    fn countActive(self: *WorkerPool) Scheduler.ActiveCounts {
        var counts: Scheduler.ActiveCounts = .{};
        for (self.workers) |*w| {
            const sched = &w.scheduler;
            for (sched.all_tasks.items) |task| {
                switch (task.getStatus()) {
                    .completed, .failed, .cancelled => continue,
                    .pending, .running => {},
                }
                counts.active += 1;
                const home = task.ctx.scheduler orelse sched;
                if (home.taskState(task) == .runnable) counts.runnable += 1;
            }
        }
        return counts;
    }

    /// Take the pool-wide snapshot the deadlock gate reads.
    pub fn blockedCounts(self: *WorkerPool) Scheduler.BlockedCounts {
        self.lockAllTasksMu();
        defer self.unlockAllTasksMu();

        var counts: Scheduler.BlockedCounts = .{};
        for (self.workers) |*w| {
            const sched = &w.scheduler;
            for (sched.all_tasks.items) |task| {
                switch (task.getStatus()) {
                    .completed, .failed, .cancelled => continue,
                    .pending, .running => {},
                }
                counts.active += 1;
                const home = task.ctx.scheduler orelse sched;
                if (home.taskInProcessBlocked(task)) counts.blocked += 1;
            }
        }
        return counts;
    }

    /// Emit the verdict header counting active and runnable tasks across
    /// every worker. Holds all `all_tasks_mu` locks for the duration of
    /// the count.
    pub fn emitStallDetect(self: *WorkerPool, threshold_ns: i128, deadlocked: bool) void {
        var tw = trace.TraceWriter.init();

        self.lockAllTasksMu();
        defer self.unlockAllTasksMu();

        scheduler_mod.writeVerdictHeader(&tw, threshold_ns, self.countActive(), deadlocked);
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

    /// Re-arm the sample deadline and report whether this worker won the
    /// tick. Returns false when the sampler is off, the tick is not yet due,
    /// or another worker advanced the deadline first. The winner re-arms to
    /// `now + interval` so the cadence stays steady rather than catching up
    /// after a long idle poll.
    pub fn claimSampleTick(self: *WorkerPool, now_ns: i128) bool {
        const interval = self.sampling_tick_ns orelse return false;
        const observed = self.next_sample_ns.load(.acquire);
        if (now_ns < observed) return false;
        return self.next_sample_ns.cmpxchgStrong(observed, now_ns + interval, .acq_rel, .acquire) == null;
    }

    /// Snapshot the pool-wide task counts. `live` and `detached` are lock-free
    /// atomic sums. `retained` is read under the ordered `all_tasks_mu` lock,
    /// which also guards each scheduler's `finished_tasks` mutations, so the
    /// summed length is well-defined across workers.
    pub fn sampleCounts(self: *WorkerPool) SampleCounts {
        self.lockAllTasksMu();
        defer self.unlockAllTasksMu();
        return self.sampleCountsLocked();
    }

    /// The count-gathering half of `sampleCounts`, with every `all_tasks_mu`
    /// already held by the caller.
    fn sampleCountsLocked(self: *WorkerPool) SampleCounts {
        var live: usize = 0;
        for (self.workers) |*w| live += w.active_tasks.load(.acquire);
        const detached = self.detached_in_flight.load(.acquire);

        var retained: usize = 0;
        for (self.workers) |*w| retained += w.scheduler.finished_tasks.items.len;

        return .{ .live = live, .retained = retained, .detached = detached };
    }

    /// Emit one `SAMPLE:` line to stderr for the current tick. Called only by
    /// the worker that won `claimSampleTick`.
    pub fn emitSample(self: *WorkerPool) void {
        self.emitSampleWithCounts(self.sampleCounts());
    }

    fn emitSampleWithCounts(self: *WorkerPool, counts: SampleCounts) void {
        const mem: ?MemSample = if (self.sample_memory) blk: {
            const ml = self.mem_limit orelse break :blk null;
            break :blk .{ .bytes = ml.currentBytes(), .peak = ml.peakBytes() };
        } else null;
        const elapsed = monotonicNowNs() - self.sampler_started_ns;

        var buf: [256]u8 = undefined;
        const line = formatSample(&buf, elapsed, self.sample_tasks, counts, mem);
        var tw = trace.TraceWriter.init();
        tw.print("{s}", .{line});
    }

    /// Allocation-path sampling entry: emit a due sample without risking a deadlock against
    /// the allocating thread's own locks. Runs inside an allocator callback, so nothing here
    /// may allocate.
    pub fn trySampleFromAlloc(self: *WorkerPool) void {
        if (self.trySampleClaim()) |counts| self.emitSampleWithCounts(counts);
    }

    /// The decide half of `trySampleFromAlloc`: back off on any unavailable lock, gather
    /// counts, and claim the tick, returning the counts to emit.
    ///
    /// The tick is claimed only after the counts are safely readable, so a skipped attempt
    /// loses nothing and the next threshold crossing retries.
    fn trySampleClaim(self: *WorkerPool) ?SampleCounts {
        if (self.sampling_tick_ns == null) return null;
        if (monotonicNowNs() < self.next_sample_ns.load(.acquire)) return null;

        if (!self.tryLockAllTasksMu()) return null;
        const counts = self.sampleCountsLocked();
        self.unlockAllTasksMu();

        if (!self.claimSampleTick(monotonicNowNs())) return null;
        return counts;
    }
};

/// Sample hook installed on the memory-cap allocator by `task-scope`, fired when cumulative
/// allocation crosses the due-check threshold.
///
/// Covers the workload the run-loop tick cannot: a task in a tight loop that never yields back
/// to the scheduler.
pub fn allocSampleHook(owner: *anyopaque) void {
    const pool: *WorkerPool = @ptrCast(@alignCast(owner));
    pool.trySampleFromAlloc();
}

fn taskIdLessThan(_: void, a: *Task, b: *Task) bool {
    return a.id < b.id;
}

// =============================================================================
// Tests
// =============================================================================

test "formatSample: both axes" {
    var buf: [256]u8 = undefined;
    const line = formatSample(&buf, 12_500_000_000, true, .{ .live = 3, .retained = 2, .detached = 1 }, .{ .bytes = 23457600, .peak = 24117248 });
    try std.testing.expectEqualStrings("SAMPLE: t=12.5s live=3 retained=2 detached=1 bytes=23457600 peak=24117248\n", line);
}

test "formatSample: tasks axis only" {
    var buf: [256]u8 = undefined;
    const line = formatSample(&buf, 12_500_000_000, true, .{ .live = 3, .retained = 2, .detached = 1 }, null);
    try std.testing.expectEqualStrings("SAMPLE: t=12.5s live=3 retained=2 detached=1\n", line);
}

test "formatSample: memory axis only" {
    var buf: [256]u8 = undefined;
    const line = formatSample(&buf, 12_500_000_000, false, .{ .live = 0, .retained = 0, .detached = 0 }, .{ .bytes = 23457600, .peak = 24117248 });
    try std.testing.expectEqualStrings("SAMPLE: t=12.5s bytes=23457600 peak=24117248\n", line);
}

test "sampleCounts: sums live, retained, and detached across workers" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 2);
    defer pool.deinit();

    pool.workers[0].active_tasks.store(2, .release);
    pool.workers[1].active_tasks.store(1, .release);
    pool.detached_in_flight.store(1, .release);

    // Two retained tasks on worker 0, none on worker 1. The pointers are only
    // counted by length, never dereferenced, so dummy aligned addresses are
    // safe; they are cleared before deinit so the reap loop never touches them.
    const dummy_a: *Task = @ptrFromInt(0x1000);
    const dummy_b: *Task = @ptrFromInt(0x2000);
    try pool.workers[0].scheduler.finished_tasks.append(std.testing.allocator, dummy_a);
    try pool.workers[0].scheduler.finished_tasks.append(std.testing.allocator, dummy_b);
    defer pool.workers[0].scheduler.finished_tasks.clearRetainingCapacity();

    const counts = pool.sampleCounts();
    try std.testing.expectEqual(@as(usize, 3), counts.live);
    try std.testing.expectEqual(@as(usize, 2), counts.retained);
    try std.testing.expectEqual(@as(u32, 1), counts.detached);

    // Re-reading the unchanged state returns identical counts: a bounded
    // workload at rest shows flat counters.
    const again = pool.sampleCounts();
    try std.testing.expectEqual(counts.live, again.live);
    try std.testing.expectEqual(counts.retained, again.retained);
    try std.testing.expectEqual(counts.detached, again.detached);
}

test "sampler snapshot: a retaining workload climbs monotonically" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
    defer pool.deinit();

    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    mem_limit.setPeakTracking(true);
    pool.mem_limit = &mem_limit;
    pool.sample_tasks = true;
    pool.sample_memory = true;
    const mem_alloc = mem_limit.allocator();

    // A long-lived scope that keeps spawning tracked children which complete but
    // are never reaped: each completed child stays in finished_tasks and its
    // allocation stays live, so retained and live bytes climb every tick.
    var live_chunks = std.ArrayListUnmanaged([]u8){};
    defer {
        for (live_chunks.items) |chunk| mem_alloc.free(chunk);
        live_chunks.deinit(std.testing.allocator);
    }
    const sched = &pool.workers[0].scheduler;
    // finished_tasks holds dummy pointers counted only by length; clear before
    // deinit so the reap loop never dereferences them.
    defer sched.finished_tasks.clearRetainingCapacity();

    var prev = pool.sampleCounts();
    var prev_bytes: usize = mem_limit.currentBytes();
    const first_retained = prev.retained;
    const first_bytes = prev_bytes;

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const dummy: *Task = @ptrFromInt(0x1000 * (i + 1));
        try sched.finished_tasks.append(std.testing.allocator, dummy);
        try live_chunks.append(std.testing.allocator, try mem_alloc.alloc(u8, 4096));

        const counts = pool.sampleCounts();
        const bytes = mem_limit.currentBytes();
        try std.testing.expect(counts.retained > prev.retained);
        try std.testing.expect(bytes > prev_bytes);
        try std.testing.expect(mem_limit.peakBytes() >= bytes);
        prev = counts;
        prev_bytes = bytes;
    }

    // The leak signal: the last sample is strictly larger than the first.
    try std.testing.expect(prev.retained > first_retained);
    try std.testing.expect(prev_bytes > first_bytes);
}

test "sampler snapshot: a bounded workload stays flat" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
    defer pool.deinit();

    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    mem_limit.setPeakTracking(true);
    pool.mem_limit = &mem_limit;
    pool.sample_tasks = true;
    pool.sample_memory = true;
    const mem_alloc = mem_limit.allocator();

    // One retained task and one persistent buffer stand in for a bounded
    // workload at rest.
    const sched = &pool.workers[0].scheduler;
    const persistent: *Task = @ptrFromInt(0x1000);
    try sched.finished_tasks.append(std.testing.allocator, persistent);
    defer sched.finished_tasks.clearRetainingCapacity();
    const persistent_buf = try mem_alloc.alloc(u8, 4096);
    defer mem_alloc.free(persistent_buf);

    const base = pool.sampleCounts();
    const base_bytes = mem_limit.currentBytes();

    // Each tick spawns and reaps: transient work that nets to zero, so every
    // sample reads the same steady state instead of accumulating.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const transient: *Task = @ptrFromInt(0x2000);
        try sched.finished_tasks.append(std.testing.allocator, transient);
        _ = sched.finished_tasks.swapRemove(sched.finished_tasks.items.len - 1);
        const chunk = try mem_alloc.alloc(u8, 8192);
        mem_alloc.free(chunk);

        const counts = pool.sampleCounts();
        try std.testing.expectEqual(base.retained, counts.retained);
        try std.testing.expectEqual(base_bytes, mem_limit.currentBytes());
    }
}

test "trySampleClaim: claims a due tick and returns counts when the locks are free" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 2);
    defer pool.deinit();

    pool.sampling_tick_ns = 100;
    pool.next_sample_ns.store(0, .release);
    pool.workers[0].active_tasks.store(3, .release);

    // Long past due with every lock free: the claim succeeds, returns the gathered counts,
    // and re-arms the deadline to now + interval, far past the epoch.
    const counts = pool.trySampleClaim() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), counts.live);
    try std.testing.expect(pool.next_sample_ns.load(.acquire) > 0);
}

test "allocSampleHook: backs off without claiming when a lock is held" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 2);
    defer pool.deinit();

    pool.sampling_tick_ns = 100;
    pool.next_sample_ns.store(0, .release);

    // Simulate the allocating thread already holding one of the ordered
    // locks, the shape `trackTask` and `handleTaskDone` produce.
    pool.workers[1].scheduler.all_tasks_mu.lock();
    defer pool.workers[1].scheduler.all_tasks_mu.unlock();

    allocSampleHook(@ptrCast(&pool));

    // No claim: the deadline is untouched, so a later crossing retries.
    try std.testing.expectEqual(@as(i128, 0), pool.next_sample_ns.load(.acquire));
}

test "tryLockAllTasksMu: releases partial acquisitions on failure" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 3);
    defer pool.deinit();

    pool.workers[2].scheduler.all_tasks_mu.lock();
    try std.testing.expect(!pool.tryLockAllTasksMu());
    pool.workers[2].scheduler.all_tasks_mu.unlock();

    // Workers 0 and 1 were released on the failed attempt and worker 2 is
    // free again, so a clean attempt takes all three.
    try std.testing.expect(pool.tryLockAllTasksMu());
    pool.unlockAllTasksMu();
}

test "claimSampleTick: elects one winner and re-arms past now" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
    defer pool.deinit();

    // Sampler off: never claims.
    try std.testing.expect(!pool.claimSampleTick(1_000));

    pool.sampling_tick_ns = 100;
    pool.next_sample_ns.store(1_000, .release);

    // Not yet due.
    try std.testing.expect(!pool.claimSampleTick(999));

    // Due: the first caller wins and re-arms to now + interval.
    try std.testing.expect(pool.claimSampleTick(1_000));
    try std.testing.expectEqual(@as(i128, 1_100), pool.next_sample_ns.load(.acquire));

    // A second claim at the same instant loses: the deadline already moved.
    try std.testing.expect(!pool.claimSampleTick(1_000));
}

test "sampler callbacks dispatch through the worker_ops table" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
    defer pool.deinit();

    // Reach the scheduler's ops table the same way the run loop does, so a
    // mis-wired callback (pointing at the wrong pool method) is caught.
    const sched = &pool.primary().scheduler;
    const ops = sched.ops.?;
    const owner = sched.owner.?;

    // Sampler off: no deadline is reported and no tick is claimed.
    try std.testing.expect(ops.poolSampleDeadlineNs(owner) == null);
    try std.testing.expect(!ops.claimSampleTick(owner, 1_000));

    pool.sample_tasks = true;
    pool.sampling_tick_ns = 100;
    pool.next_sample_ns.store(1_000, .release);

    try std.testing.expectEqual(@as(?i128, 1_000), ops.poolSampleDeadlineNs(owner));
    try std.testing.expect(ops.claimSampleTick(owner, 1_000));
    try std.testing.expectEqual(@as(i128, 1_100), pool.next_sample_ns.load(.acquire));

    // The detached-done callback drops the pool's in-flight count.
    pool.detached_in_flight.store(2, .release);
    ops.onDetachedTaskDone(owner);
    try std.testing.expectEqual(@as(u32, 1), pool.detached_in_flight.load(.acquire));
}

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

test "startBackgroundWorkers spawns no threads with a single worker" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
    defer pool.deinit();

    try pool.startBackgroundWorkers();
    pool.join();

    try std.testing.expectEqual(@as(usize, 1), pool.workers.len);
    try std.testing.expect(pool.workers[0].thread == null);
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

test "Worker.requestReap appends to reap queue" {
    var pool: WorkerPool = undefined;
    try pool.init(std.testing.allocator, 1);
    defer pool.deinit();

    // Only the enqueue is exercised here. Draining the reap queue would call
    // reapTask, which frees the task's coroutine, context, and structs; a
    // stack-allocated dummy cannot survive that. The drain path is covered
    // end-to-end by the task_scope_cross_worker_reap integration test.
    var dummy_task: Task = undefined;
    try pool.workers[0].requestReap(&dummy_task);

    try std.testing.expectEqual(@as(usize, 1), pool.workers[0].reap_queue.items.len);
    try std.testing.expectEqual(&dummy_task, pool.workers[0].reap_queue.items[0]);
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
