const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const task_mod = @import("task.zig");
const Task = task_mod.Task;
const Channel = @import("channel.zig").Channel;
const LoadLock = @import("load_lock.zig").LoadLock;
const TaskStatus = task_mod.TaskStatus;
const TaskScope = task_mod.TaskScope;
const Multiplexer = @import("multiplexer.zig").Multiplexer;
const IoEvent = @import("multiplexer.zig").IoEvent;
const ProcessWaitHandle = @import("multiplexer.zig").ProcessWaitHandle;
const processWaitHandleKey = @import("multiplexer.zig").processWaitHandleKey;
const trace = @import("trace.zig");
const memory_limit = @import("memory_limit.zig");
const value_mod = @import("value.zig");
const container_backing = @import("container_backing.zig");
const profile = @import("profile.zig");
const ProfileStats = profile.ProfileStats;
const portable_atomic = @import("portable_atomic.zig");

const is_freestanding = builtin.os.tag == .freestanding;
const is_wasm = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;

/// Entry in the sleep queue: a task and its absolute monotonic wake time in nanoseconds.
pub const SleepEntry = struct {
    task: *Task,
    wake_time: i128,
};

/// Min-heap ordered by wake_time so the earliest waker is dequeued first.
pub const SleepQueue = std.PriorityQueue(SleepEntry, void, sleepEntryLessThan);

fn sleepEntryLessThan(_: void, a: SleepEntry, b: SleepEntry) std.math.Order {
    return std.math.order(a.wake_time, b.wake_time);
}

pub const IoWaitEntry = struct {
    task: *Task,
    event: IoEvent,
};

pub const ProcessWaitEntry = struct {
    task: *Task,
    // Plain i32, not std.posix.pid_t: see the comment on drainCancelledIOWaiters's `removals`
    // in Scheduler, which explains why fd_t/pid_t (void on freestanding) can't carry a real
    // value there. i32 matches pid_t's real definition on every hosted target.
    pid: i32,
    handle: ProcessWaitHandle,
};

/// Read the monotonic clock and return the current time as a single i128 nanosecond value.
pub fn monotonicNowNs() i128 {
    if (is_wasm) {
        return wasmMonotonicNowNs();
    } else if (is_freestanding) {
        return baremetalNowNs();
    } else {
        const ts = std.posix.clock_gettime(.MONOTONIC) catch unreachable;
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
}

/// Nanosecond timestamp for measuring elapsed durations (benchmarking, profiling).
/// Hosted targets keep calling `std.time.nanoTimestamp()` verbatim, unchanged from before this
/// helper existed. `std.time.nanoTimestamp()` itself falls through to `posix.clock_gettime`,
/// which is undefined on the freestanding non-libc stub, so freestanding targets reuse
/// `monotonicNowNs()` instead. The two clocks differ (wall-clock REALTIME vs MONOTONIC) but
/// callers only ever use the delta between two calls, for which either is fit for purpose.
pub fn elapsedTimerNowNs() i128 {
    if (comptime is_freestanding) {
        return monotonicNowNs();
    }
    return std.time.nanoTimestamp();
}

/// Freestanding monotonic clock backed by the RISC-V `time` CSR. QEMU's
/// `virt` machine clocks `time` at 10 MHz, so each tick is 100 ns. The
/// timebase is hardcoded for now; a build option can replace it when a
/// non-QEMU board is supported.
fn baremetalNowNs() i128 {
    if (builtin.cpu.arch != .riscv64) @compileError("freestanding monotonic clock is only implemented for riscv64");
    var ticks: u64 = undefined;
    asm volatile ("rdtime %[ticks]"
        : [ticks] "=r" (ticks),
    );
    return @as(i128, ticks) * 100;
}

/// Host-provided monotonic clock, resolved by the browser's `WebAssembly.instantiate()`
/// import object. Backed by `performance.now()`, converted to nanoseconds on the JS side.
extern "env" fn onez_host_monotonic_now_ns() i64;

fn wasmMonotonicNowNs() i128 {
    return @as(i128, onez_host_monotonic_now_ns());
}

pub const ClockMode = union(enum) {
    /// Use the system monotonic clock for real timestamps.
    real,
    /// Use a manually-advanced nanosecond counter for deterministic testing.
    fake: i128,
};

/// Callbacks the owning `Worker` registers with its scheduler so the
/// scheduler can drain the worker's cross-thread external queue, decrement
/// its active-task counter, and observe shutdown requests without
/// importing `worker.zig` (which would form an import cycle).
pub const WorkerOps = struct {
    drainExternal: *const fn (owner: *anyopaque) void,
    /// Increment the owning worker's active-task counter as a task homed on
    /// this worker is enqueued. The symmetric partner of `onTaskDone`, for the
    /// enqueue sites that home a task on the current scheduler rather than a
    /// pool-selected worker (nested `task-scope` and `with-timeout`).
    onTaskSpawned: *const fn (owner: *anyopaque) void,
    onTaskDone: *const fn (owner: *anyopaque) void,
    shutdownRequested: *const fn (owner: *anyopaque) bool,
    drainWake: *const fn (owner: *anyopaque) void,
    isPrimary: *const fn (owner: *anyopaque) bool,
    enqueueExternal: *const fn (owner: *anyopaque, task: *Task) anyerror!void,
    /// Ask the owning worker to cancel a task on its own thread. The worker
    /// pushes the task pointer onto its cancellation queue and signals its
    /// wake source so a blocked `poll()` returns promptly. The home worker
    /// then drains the queue and runs the local cancellation logic.
    requestCancellation: *const fn (owner: *anyopaque, task: *Task) anyerror!void,
    /// Drain the worker's cancellation request queue, invoking the
    /// scheduler's local-cancellation logic for each entry. Owning thread
    /// only.
    drainCancellations: *const fn (owner: *anyopaque) void,
    /// Ask the owning worker to reap a terminal task on its own thread. The
    /// worker pushes the task pointer onto its reap queue and signals its
    /// wake source. The home worker then drains the queue and frees the
    /// task, keeping destruction on the owning worker.
    requestReap: *const fn (owner: *anyopaque, task: *Task) anyerror!void,
    /// Drain the worker's reap request queue, freeing each terminal task on
    /// the owning thread. Owning thread only.
    drainReaps: *const fn (owner: *anyopaque) void,
    /// Allocate the next globally-unique task ID from the worker's pool so
    /// that diagnostic output can refer to any task by a single integer
    /// regardless of which worker it lives on. Safe to call from any
    /// thread.
    nextTaskId: *const fn (owner: *anyopaque) u64,
    /// Publish a monotonic progress timestamp to the pool. Called from
    /// every worker on task completion, sleeper wake, and I/O readiness
    /// events so stall detection accounts for progress made on any worker.
    /// Safe to call from any thread; racing writers don't matter because
    /// the monotonic clock guarantees the latest writer is approximately
    /// the most recent event.
    recordPoolProgress: *const fn (owner: *anyopaque, now_ns: i128) void,
    /// Read the pool's most recent progress timestamp. Used by stall
    /// detection to compute elapsed-since-progress against a shared
    /// timeline rather than the per-worker `last_progress_ns`.
    poolLastProgressNs: *const fn (owner: *anyopaque) i128,
    /// Read the pool-level stall detection threshold (nanoseconds since
    /// last progress before a stall is declared). Null disables.
    poolDeadlockThresholdNs: *const fn (owner: *anyopaque) ?i128,
    /// CAS-elect this worker as the unique stall reporter. Returns true
    /// when the current worker has won the race to dump and exit; false
    /// when another worker has already taken responsibility.
    claimStallReport: *const fn (owner: *anyopaque) bool,
    /// Emit the `STALL-DETECT: ...` header with aggregated active and
    /// runnable counts across every worker in the pool. Paired with
    /// `dumpAllPoolTasks` on the stall path.
    emitPoolStallDetect: *const fn (owner: *anyopaque, threshold_ns: i128) void,
    /// Dump every task across every worker in the pool to stderr in
    /// task-id order, then return. Caller is responsible for
    /// `std.process.exit(124)` afterwards.
    dumpAllPoolTasks: *const fn (owner: *anyopaque) void,
    /// Return true if any worker in the pool owns a non-terminal task.
    /// Used by the primary worker's exit check: the primary cannot break
    /// out of `runLoop` while any worker still hosts live work, because a
    /// sibling worker may spawn a task back onto the primary's external
    /// queue at any time. Without a pool-wide check the primary races
    /// against cross-thread spawns and can exit before those tasks land.
    poolHasAliveTasks: *const fn (owner: *anyopaque) bool,
    /// Signal the primary worker's wake source so it returns from `poll()`
    /// and re-evaluates `poolHasAliveTasks`. Called from any worker's
    /// `handleTaskDone` so the primary observes the pool draining without
    /// needing a separate event source.
    wakePrimary: *const fn (owner: *anyopaque) void,
    /// Read the pool's next periodic-sample deadline in nanoseconds, or null
    /// when the sampler is disabled. Folded into the poll timeout so an idle
    /// worker wakes each tick.
    poolSampleDeadlineNs: *const fn (owner: *anyopaque) ?i128,
    /// CAS-elect this worker as the sole emitter for the current sample tick,
    /// re-arming the deadline. Returns true when this worker should emit.
    claimSampleTick: *const fn (owner: *anyopaque, now_ns: i128) bool,
    /// Emit one aggregated `SAMPLE:` line across the pool. Paired with a
    /// winning `claimSampleTick`.
    emitPoolSample: *const fn (owner: *anyopaque) void,
    /// Drop the pool's in-flight detached-task count. Called from
    /// `handleDetachedTaskDone` on the owning worker as a detached task is
    /// reaped, mirroring `onTaskDone` for the tracked-task count.
    onDetachedTaskDone: *const fn (owner: *anyopaque) void,
};

/// Cooperative scheduler with a FIFO run queue.
///
/// Drives green thread execution by round-robin scheduling tasks. Each task
/// runs until it yields or completes, then control returns to the scheduler
/// loop when the coroutine yields back to its caller.
pub const Scheduler = struct {
    run_queue: std.ArrayListUnmanaged(*Task),
    sleep_queue: SleepQueue,
    current_task: ?*Task = null,
    /// Monotonic task-id counter. Atomic so spawn paths on other worker
    /// threads can allocate IDs against this scheduler without locking.
    next_task_id: portable_atomic.WideCounter(u64) = portable_atomic.WideCounter(u64).init(1),
    allocator: Allocator,
    /// Finished tasks whose stacks and arenas are freed on deinit.
    finished_tasks: std.ArrayListUnmanaged(*Task),
    /// All tasks ever created, for diagnostic dumps.
    all_tasks: std.ArrayListUnmanaged(*Task) = .{},
    /// Guards `all_tasks` against concurrent appends from other worker
    /// threads (spawn dispatches a fresh task onto the target scheduler).
    all_tasks_mu: std.Thread.Mutex = .{},
    /// Channels created during this scheduler's lifetime, freed on deinit.
    channels: std.ArrayListUnmanaged(*Channel) = .{},
    /// Platform I/O multiplexer for async-aware stream operations.
    multiplexer: Multiplexer,
    /// Maps file descriptors to tasks suspended waiting on I/O readiness. Keyed by plain i32,
    /// not std.posix.fd_t: see the comment on drainCancelledIOWaiters's `removals`.
    io_wait_map: std.AutoHashMapUnmanaged(i32, IoWaitEntry) = .{},
    /// Maps child-process wait handles to tasks suspended waiting on exit.
    process_wait_map: std.AutoHashMapUnmanaged(u64, ProcessWaitEntry) = .{},
    /// Wall-clock stall detection threshold in nanoseconds.
    deadlock_detect_ns: ?i128 = null,
    /// Monotonic timestamp of the last progress event (task done, sleeper woken, I/O ready).
    last_progress_ns: i128 = 0,
    /// Clock mode.
    clock: ClockMode = .real,
    peak_task_stack_usage: usize = 0,
    /// Profile buffers drained from this worker's reaped task Contexts, one per
    /// task. Only the owning worker appends here (in `reapTask`), so no lock is
    /// needed. Folded into `profile_sink` at teardown in `deinit`.
    drained_task_profiles: std.ArrayListUnmanaged(profile.TaskProfile) = .{},
    /// Fold target for `drained_task_profiles` at teardown, the main context's
    /// buffer. Null on standalone schedulers and when `--profile` is off; those
    /// drained buffers are freed instead of merged.
    profile_sink: ?*ProfileStats = null,
    /// Owning worker's id, captured into each drained buffer's label. Zero on
    /// the primary worker and on standalone schedulers.
    worker_id: usize = 0,
    /// Type-erased back-pointer to the owning `Worker`. Null on standalone
    /// schedulers used in tests. Erased to break a circular import between
    /// `worker.zig` and this file. Paired with `ops` for invoking worker
    /// callbacks.
    owner: ?*anyopaque = null,
    /// Callback table the owning worker fills in so the scheduler can
    /// drain the worker's external queue, observe shutdown, etc. Null
    /// for standalone schedulers.
    ops: ?*const WorkerOps = null,

    pub fn init(allocator: Allocator) !Scheduler {
        return .{
            .run_queue = .{},
            .sleep_queue = SleepQueue.init(allocator, {}),
            .current_task = null,
            .allocator = allocator,
            .finished_tasks = .{},
            .multiplexer = try Multiplexer.init(),
        };
    }

    pub fn nowNs(self: *const Scheduler) i128 {
        return switch (self.clock) {
            .real => monotonicNowNs(),
            .fake => |t| t,
        };
    }

    pub fn advanceClock(self: *Scheduler, delta_ns: i128) void {
        switch (self.clock) {
            .fake => |*t| t.* += delta_ns,
            .real => unreachable,
        }
        _ = self.wakeExpiredSleepers();
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.finished_tasks.items) |t| {
            self.reapTask(t);
        }
        self.finished_tasks.deinit(self.allocator);

        // The reap loop above has drained every remaining tracked task into
        // `drained_task_profiles`. This is the single-threaded teardown fold:
        // move each buffer into the main context's sink, or free it when there
        // is no sink. A standalone scheduler and a run with profiling off both
        // have no sink.
        for (self.drained_task_profiles.items) |*tp| {
            if (self.profile_sink) |sink| {
                sink.task_profiles.append(self.allocator, tp.*) catch {
                    tp.deinit(self.allocator);
                };
            } else {
                tp.deinit(self.allocator);
            }
        }
        self.drained_task_profiles.deinit(self.allocator);

        for (self.channels.items) |ch| {
            ch.deinit();
            self.allocator.destroy(ch);
        }
        self.channels.deinit(self.allocator);
        self.all_tasks.deinit(self.allocator);
        self.run_queue.deinit(self.allocator);
        self.sleep_queue.deinit();
        self.multiplexer.deinit();
        self.io_wait_map.deinit(self.allocator);
        self.process_wait_map.deinit(self.allocator);
    }

    /// Register a channel for cleanup when the scheduler is destroyed.
    pub fn trackChannel(self: *Scheduler, ch: *Channel) !void {
        try self.channels.append(self.allocator, ch);
    }

    /// Append a task to the end of the run queue.
    pub fn enqueue(self: *Scheduler, task: *Task) !void {
        try self.run_queue.append(self.allocator, task);
    }

    /// Route `task` to its home worker's run queue. If the home is `self`,
    /// append locally. Otherwise push to the home worker's mutex-guarded
    /// external queue, which signals the home worker's wake source so a
    /// blocked `poll()` returns promptly. Safe to call from any worker.
    pub fn wakeTask(self: *Scheduler, task: *Task) !void {
        const home = if (task.ctx.scheduler) |s| s else self;
        if (home == self) {
            try self.run_queue.append(self.allocator, task);
            return;
        }
        if (home.owner) |owner| {
            if (home.ops) |ops| {
                try ops.enqueueExternal(owner, task);
                return;
            }
        }
        // Standalone home scheduler (tests). Fall back to a direct append
        // on the home's run queue; standalone schedulers are not
        // concurrently driven by another OS thread.
        try home.run_queue.append(home.allocator, task);
    }

    /// Return the next task ID and increment the counter. Safe to call from
    /// any thread.
    ///
    /// When owned by a worker, IDs are drawn from the pool's shared counter
    /// so task IDs are globally unique across workers. Standalone
    /// schedulers (unit tests, REPL eval outside `task-scope`) keep their
    /// own counter starting at 1.
    pub fn nextId(self: *Scheduler) u64 {
        if (self.owner) |owner| {
            if (self.ops) |ops| {
                return ops.nextTaskId(owner);
            }
        }
        return self.next_task_id.fetchAdd(1, .acq_rel);
    }

    /// Append a freshly allocated task to `all_tasks` under the cross-thread
    /// mutex. Called from `spawn` paths that may target a scheduler owned by
    /// a different OS thread.
    pub fn trackTask(self: *Scheduler, task: *Task) !void {
        self.all_tasks_mu.lock();
        defer self.all_tasks_mu.unlock();
        try self.all_tasks.append(self.allocator, task);
    }

    /// Remove a task from `all_tasks` before it is freed early. Holds only
    /// this scheduler's `all_tasks_mu`, the same single-lock discipline as
    /// `trackTask`, so it respects the ascending-order lock convention the
    /// pool-wide diagnostic dumps rely on. Without this, a dump iterating
    /// `all_tasks` would dereference a freed detached task.
    fn untrackTask(self: *Scheduler, task: *Task) void {
        self.all_tasks_mu.lock();
        defer self.all_tasks_mu.unlock();
        for (self.all_tasks.items, 0..) |t, i| {
            if (t == task) {
                _ = self.all_tasks.swapRemove(i);
                return;
            }
        }
    }

    /// Free a completed task's coroutine, result, context, and struct. Run
    /// on the owning worker for a detached task at its own completion, and
    /// for tracked tasks at `deinit`.
    fn reapTask(self: *Scheduler, task: *Task) void {
        self.drainTaskProfile(task);
        task_mod.coroDestroy(task);
        task_mod.releaseTaskResult(task);
        container_backing.releaseValue(task.quot_owner);
        task.ctx.deinit();
        self.allocator.destroy(task.ctx);
        self.allocator.destroy(task);
    }

    /// Copy a reaped task's profile samples into this worker's collection before
    /// the Context is freed.
    ///
    /// A `ProfileSample.name` and `task.name` are borrowed slices into
    /// dictionary/arena bytes that `task.ctx.deinit` frees, so both are duped
    /// onto `self.allocator`, which outlives the reduction. Labels are captured
    /// here because the drain is the only point where the task's id, name, and
    /// owning worker are all still reachable. A no-op when the task carries no
    /// owned profile buffer, which is the case with profiling off, or recorded
    /// nothing.
    fn drainTaskProfile(self: *Scheduler, task: *Task) void {
        if (!task.ctx.profile_owned) return;
        const src = task.ctx.profile orelse return;
        if (src.samples.items.len == 0) return;

        var drained: profile.TaskProfile = .{
            .task_id = task.id,
            .worker_id = self.worker_id,
        };

        if (task.name) |name| {
            drained.task_name = self.allocator.dupe(u8, name) catch null;
        }

        drained.samples.ensureTotalCapacity(self.allocator, src.samples.items.len) catch {
            drained.deinit(self.allocator);
            return;
        };
        for (src.samples.items) |s| {
            const owned = self.allocator.dupe(u8, s.name) catch {
                drained.deinit(self.allocator);
                return;
            };
            drained.samples.appendAssumeCapacity(.{
                .name = owned,
                .start_ns = s.start_ns,
                .end_ns = s.end_ns,
            });
        }

        self.drained_task_profiles.append(self.allocator, drained) catch {
            drained.deinit(self.allocator);
        };
    }

    /// Remove a completed task from `finished_tasks` before it's reaped early at scope exit.
    ///
    /// This runs on the owning worker, the same thread that appends. It holds `all_tasks_mu`
    /// anyway because the periodic sampler reads `finished_tasks.items.len` cross-worker under
    /// that lock, so a concurrent read must not observe a half-completed `swapRemove`.
    fn removeFinished(self: *Scheduler, task: *Task) void {
        self.all_tasks_mu.lock();
        defer self.all_tasks_mu.unlock();
        for (self.finished_tasks.items, 0..) |t, i| {
            if (t == task) {
                _ = self.finished_tasks.swapRemove(i);
                return;
            }
        }
    }

    /// Reap a terminal tracked task early by pulling it out of the list of tasks, then freeing it.
    ///
    /// This runs on the task's owning worker.
    pub fn reapTrackedTask(self: *Scheduler, task: *Task) void {
        self.removeFinished(task);
        self.untrackTask(task);
        self.reapTask(task);
    }

    /// Reap a scope's completed tracked children at scope exit on the exiting worker.
    ///
    /// This runs only once the scope has drained, which means every child is terminal and already
    /// in the finished tasks list.
    ///
    /// A local child, i.e., whose home is this scheduler, is reaped inline. A remote child is
    /// routed to its home worker's reap queue so destruction stays on the owning worker.
    pub fn reapScopeAtExit(self: *Scheduler, scope: *TaskScope) void {
        if (scope.active_children.load(.acquire) != 0) return;
        scope.children_mu.lock();
        defer scope.children_mu.unlock();
        for (scope.children.items) |child| {
            const home = if (child.ctx.scheduler) |s| s else self;
            if (home == self) {
                self.reapTrackedTask(child);
            } else {
                self.requestReapRemote(home, child);
            }
        }
    }

    /// Hand a terminal child off to its home worker's reap queue so the home worker frees it on
    /// its own thread.
    ///
    /// This is fire-and-forget, in that the exiting worker doesn't wait. The child is already
    /// terminal and is enqueued exactly once, so that it's freed exactly once.
    fn requestReapRemote(self: *Scheduler, home: *Scheduler, task: *Task) void {
        _ = self;
        if (home.owner) |owner| {
            if (home.ops) |ops| {
                ops.requestReap(owner, task) catch {};
                return;
            }
        }

        // standalone scheduler with no concurrent runLoop gets reaped inline
        home.reapTrackedTask(task);
    }

    fn drainOwnedExternal(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        ops.drainExternal(owner);
    }

    fn drainOwnedCancellations(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        ops.drainCancellations(owner);
    }

    fn drainOwnedReaps(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        ops.drainReaps(owner);
    }

    fn drainOwnedWake(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        ops.drainWake(owner);
    }

    /// Count a task homed on this worker as it is enqueued, balancing the
    /// `notifyOwnerTaskDone` decrement that runs when it completes. No-op on a
    /// standalone scheduler, matching the decrement side.
    pub fn notifyOwnerTaskSpawned(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        ops.onTaskSpawned(owner);
    }

    fn notifyOwnerTaskDone(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        ops.onTaskDone(owner);
        // Nudge the primary worker so it re-evaluates its pool-wide exit
        // check. Without this the primary can sit in `poll()` after the
        // last background task finishes because nothing else signals its
        // wake source.
        ops.wakePrimary(owner);
    }

    pub fn isBackgroundWorker(self: *Scheduler) bool {
        const owner = self.owner orelse return false;
        const ops = self.ops orelse return false;
        return !ops.isPrimary(owner);
    }

    /// Pool-wide alive-task check used by the primary worker's exit path.
    /// Standalone schedulers (no owning worker) cannot have peers, so the
    /// answer collapses to the per-worker check the caller already did.
    fn poolHasAliveTasks(self: *Scheduler) bool {
        const owner = self.owner orelse return false;
        const ops = self.ops orelse return false;
        return ops.poolHasAliveTasks(owner);
    }

    /// Capture a progress event. Updates the scheduler-local timestamp
    /// (used by standalone schedulers) and, when owned by a worker,
    /// publishes the timestamp to the pool's shared atomic so stall
    /// detection on every worker observes global progress.
    fn recordProgress(self: *Scheduler) void {
        const now = monotonicNowNs();
        self.last_progress_ns = now;
        if (self.owner) |owner| {
            if (self.ops) |ops| {
                ops.recordPoolProgress(owner, now);
            }
        }
    }

    /// Read the elapsed-since-last-progress source of truth: the pool's
    /// shared timestamp when owned, otherwise the scheduler-local field.
    fn lastProgressNs(self: *Scheduler) i128 {
        if (self.owner) |owner| {
            if (self.ops) |ops| {
                return ops.poolLastProgressNs(owner);
            }
        }
        return self.last_progress_ns;
    }

    /// Read the effective stall threshold: pool-level when owned (set by
    /// `task-scope`), scheduler-local otherwise (set directly by tests).
    fn stallThresholdNs(self: *Scheduler) ?i128 {
        if (self.owner) |owner| {
            if (self.ops) |ops| {
                return ops.poolDeadlockThresholdNs(owner);
            }
        }
        return self.deadlock_detect_ns;
    }

    fn shutdownObserved(self: *Scheduler) bool {
        const owner = self.owner orelse return true;
        const ops = self.ops orelse return true;
        return ops.shutdownRequested(owner);
    }

    /// Read the pool's next periodic-sample deadline, or null when the
    /// sampler is off or the scheduler is standalone. Folded into the poll
    /// timeout so an idle worker wakes at each tick.
    fn sampleDeadlineNs(self: *Scheduler) ?i128 {
        const owner = self.owner orelse return null;
        const ops = self.ops orelse return null;
        return ops.poolSampleDeadlineNs(owner);
    }

    /// If a periodic sample is due, elect a single emitter across the pool
    /// and emit the aggregate line. No-op on standalone schedulers.
    fn maybeSample(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        if (ops.claimSampleTick(owner, monotonicNowNs())) ops.emitPoolSample(owner);
    }

    /// Drop the pool's in-flight detached-task count on the owning worker as
    /// a detached task is reaped. No-op on standalone schedulers.
    fn notifyOwnerDetachedDone(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        ops.onDetachedTaskDone(owner);
    }

    /// Re-enqueue the current task and yield back to the scheduler loop.
    /// Called from within a running task by the `yield` primitive.
    pub fn yieldCurrentTask(self: *Scheduler) void {
        if (self.current_task) |task| {
            self.run_queue.append(self.allocator, task) catch {};
            task_mod.coroYield();
        }
    }

    /// Yield back to the scheduler without reënqueuing the current task.
    /// Used by nested `task-scope` to block the calling task until its scope completes.
    pub fn suspendCurrentTask(self: *Scheduler) void {
        if (self.current_task != null) {
            task_mod.coroYield();
        }
    }

    /// Suspend the current task until `duration_ns` nanoseconds have elapsed.
    /// Inserts the task into the sleep queue and yields back to the scheduler.
    pub fn sleepCurrentTask(self: *Scheduler, duration_ns: i128) void {
        if (self.current_task) |task| {
            const wake_time = self.nowNs() + duration_ns;

            self.sleep_queue.add(.{ .task = task, .wake_time = wake_time }) catch {};
            task_mod.coroYield();
        }
    }

    /// Move all sleep queue entries whose wake time has passed into the run queue.
    /// Returns true when at least one sleeper was woken.
    fn wakeExpiredSleepers(self: *Scheduler) bool {
        const now = self.nowNs();
        var woke_any = false;
        while (self.sleep_queue.peek()) |entry| {
            if (entry.wake_time > now) break;

            const woken = self.sleep_queue.remove();
            self.run_queue.append(self.allocator, woken.task) catch {};
            woke_any = true;
        }
        return woke_any;
    }

    /// Move cancelled tasks from the sleep queue to the run queue so they
    /// resume and unwind cooperatively through their cleanup handlers.
    ///
    /// Uses removeIndex which swaps the last element into the removed slot,
    /// so the loop must not increment the index after removal.
    fn drainCancelledSleepers(self: *Scheduler) void {
        var i: usize = 0;
        while (i < self.sleep_queue.count()) {
            if (self.sleep_queue.items[i].task.getCancellationPhase() != .none) {
                const entry = self.sleep_queue.items[i];
                _ = self.sleep_queue.removeIndex(i);
                self.run_queue.append(self.allocator, entry.task) catch {};
            } else {
                i += 1;
            }
        }
    }

    /// Register the current task's interest in an fd and suspend it until readiness.
    /// Called from stream primitives when an I/O operation would block.
    pub fn ioSuspendCurrentTask(self: *Scheduler, fd: i32, event: IoEvent) void {
        if (self.current_task) |task| {
            self.multiplexer.register(fd, event) catch {};
            self.io_wait_map.put(self.allocator, fd, .{ .task = task, .event = event }) catch {};
            task.blocked_on_io_fd = fd;
            task_mod.coroYield();
        }
    }

    /// Suspend the current task until the child process exits.
    pub fn processSuspendCurrentTask(self: *Scheduler, pid: i32) !void {
        const task = self.current_task orelse return;
        const handle = try self.multiplexer.registerProcessExit(pid);
        errdefer self.multiplexer.unregisterProcessExit(handle) catch {};

        const key = processWaitHandleKey(handle);
        try self.process_wait_map.put(self.allocator, key, .{
            .task = task,
            .pid = pid,
            .handle = handle,
        });
        task.blocked_on_process_pid = pid;
        task.blocked_on_process_key = key;
        task_mod.coroYield();
    }

    /// Move cancelled tasks from the I/O wait map to the run queue so they
    /// resume and unwind cooperatively through their cleanup handlers.
    fn drainCancelledIOWaiters(self: *Scheduler) void {
        // Plain i32, not std.posix.fd_t: fd_t is void (zero-sized) on freestanding, and an
        // ArrayList of a zero-sized element type divides by zero in its own capacity-growth
        // arithmetic (std.atomic.cache_line / @sizeOf(T)). i32 matches fd_t's real definition on
        // every hosted target this project supports, so this is a no-op there.
        var removals = std.ArrayListUnmanaged(i32){};
        defer removals.deinit(self.allocator);

        var it = self.io_wait_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.task.getCancellationPhase() != .none) {
                removals.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (removals.items) |fd| {
            if (self.io_wait_map.fetchRemove(fd)) |kv| {
                self.multiplexer.unregister(fd, kv.value.event) catch {};
                kv.value.task.blocked_on_io_fd = null;
                self.run_queue.append(self.allocator, kv.value.task) catch {};
            }
        }
    }

    /// Move cancelled process waiters to the run queue so they can unwind.
    fn drainCancelledProcessWaiters(self: *Scheduler) void {
        var removals = std.ArrayListUnmanaged(u64){};
        defer removals.deinit(self.allocator);

        var it = self.process_wait_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.task.getCancellationPhase() != .none) {
                removals.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (removals.items) |key| {
            if (self.process_wait_map.fetchRemove(key)) |kv| {
                self.multiplexer.unregisterProcessExit(kv.value.handle) catch {};
                kv.value.task.blocked_on_process_pid = null;
                kv.value.task.blocked_on_process_key = null;
                self.run_queue.append(self.allocator, kv.value.task) catch {};
            }
        }
    }

    /// Core scheduling loop
    ///
    /// Repeats until there are no more tasks to run and no more IO waiters:
    ///
    /// 1. Wake expired sleepers into the run queue.
    /// 2. If run queue non-empty: dequeue one task, handle cancellation or
    ///    resume via mco_resume, handle completion. Loop back to step 1.
    /// 3. Run queue empty: drain cancelled sleepers and I/O waiters.
    /// 4. If sleepers or I/O waiters remain: poll multiplexer with the next
    ///    sleep deadline as timeout, re-enqueue tasks whose fds are ready.
    ///    Loop back to step 1.
    pub fn runLoop(self: *Scheduler) void {
        self.recordProgress();

        while (true) {
            // Move any tasks pushed onto the owning worker's external queue into the local runqueue
            // before making scheduling decisions
            self.drainOwnedExternal();
            // Process cross-thread cancellation requests next so the local logic can route blocked
            // tasks (IO/sleep/process/scope/channel) back into the run queue before the scheduling
            // pass picks one
            self.drainOwnedCancellations();
            // Free any terminal tasks other workers routed here for reaping at their scope's exit,
            // on this worker's own thread
            self.drainOwnedReaps();

            if (self.wakeExpiredSleepers()) {
                self.recordProgress();
            }

            if (self.run_queue.items.len > 0) {
                const task = self.run_queue.orderedRemove(0);
                self.current_task = task;

                // The task's context is this thread's current context for the duration of the
                // resume, so a memory-limit abort inside the task names its call stack.
                //
                // Restore rather than clear: the primary worker shares the main thread with
                // the root context.
                const prev_context = memory_limit.current_context;
                memory_limit.current_context = task.ctx;

                task.setStatus(.running);
                task_mod.coroResume(task);
                memory_limit.current_context = prev_context;
                self.current_task = null;
                switch (task.getStatus()) {
                    .completed, .failed, .cancelled => {
                        self.handleTaskDone(task);
                        self.recordProgress();
                    },
                    .running, .pending => {},
                }
                continue;
            }

            self.drainCancelledSleepers();
            self.drainCancelledIOWaiters();
            self.drainCancelledProcessWaiters();

            // draining coulda woken waiting tasks via handleTaskDone, so re-check before blocking
            if (self.run_queue.items.len > 0) continue;

            const has_sleepers = self.sleep_queue.count() > 0;
            const has_io_waiters = self.io_wait_map.count() > 0;
            const has_process_waiters = self.process_wait_map.count() > 0;
            // Any task pinned to this worker that has not yet reached a
            // terminal status is "blocked" for runLoop purposes -- it has
            // either yielded for sleep/IO (already counted above) or is
            // suspended awaiting a wake that will arrive on the local run
            // queue, the local sleep queue, or the cross-thread external
            // queue. The latter case is invisible to the per-state flags
            // (`blocked_on_channel`, `blocked_on_scope`, ...), so without
            // this broader check a worker can fall through `break` while a
            // task on a sibling worker is still racing to enqueue the
            // wake.
            const has_blocked_tasks = blk: {
                self.all_tasks_mu.lock();
                defer self.all_tasks_mu.unlock();
                for (self.all_tasks.items) |task| {
                    switch (task.getStatus()) {
                        .completed, .failed, .cancelled => continue,
                        .pending, .running => break :blk true,
                    }
                }
                break :blk false;
            };

            // Background workers do not exit on empty queues -- they sit in
            // a blocking poll until either a cross-thread enqueue wakes
            // them or the driver signals shutdown. Primary worker and
            // standalone schedulers retain the original drain-and-exit
            // behavior.
            const background = self.isBackgroundWorker();
            if (!background) {
                // Primary's exit must be pool-wide: a sibling worker can
                // spawn a task back onto the primary's external queue at
                // any time, and the primary's own `all_tasks` does not see
                // those cross-worker spawns until they land. Checking the
                // pool's aggregate alive count closes the race.
                const any_alive = self.poolHasAliveTasks();
                if (!has_sleepers and !has_io_waiters and !has_process_waiters and !has_blocked_tasks and !any_alive) break;
            } else {
                if (self.shutdownObserved() and !has_sleepers and !has_io_waiters and !has_process_waiters and !has_blocked_tasks) break;
            }

            // Background workers without local work block indefinitely
            // until a wake signal or registered I/O arrives; non-background
            // schedulers use the sleep queue head as the natural timeout.
            var timeout: ?i128 = if (has_sleepers) blk: {
                const next = self.sleep_queue.peek().?;
                const now = self.nowNs();
                const remaining = next.wake_time - now;
                break :blk if (remaining > 0) remaining else @as(i128, 0);
            } else null;

            if (self.stallThresholdNs()) |threshold| {
                const now = monotonicNowNs();
                const stall_remaining = threshold - (now - self.lastProgressNs());
                const stall_timeout: i128 = if (stall_remaining > 0) stall_remaining else 0;
                timeout = if (timeout) |t| @min(t, stall_timeout) else stall_timeout;
            }

            if (self.sampleDeadlineNs()) |deadline| {
                const remaining = deadline - monotonicNowNs();
                const sample_timeout: i128 = if (remaining > 0) remaining else 0;
                timeout = if (timeout) |t| @min(t, sample_timeout) else sample_timeout;
            }

            if (self.clock == .fake) {
                timeout = 0;
            }

            const ready = self.multiplexer.poll(timeout) catch &.{};
            if (ready.len > 0) {
                self.recordProgress();
            }
            for (ready) |ev| {
                switch (ev) {
                    .io => |ready_io| {
                        if (self.io_wait_map.fetchRemove(ready_io.fd)) |kv| {
                            kv.value.task.blocked_on_io_fd = null;
                            self.run_queue.append(self.allocator, kv.value.task) catch {};
                        }
                    },
                    .process_exit => |ready_process| {
                        const key = processWaitHandleKey(ready_process.handle);
                        if (self.process_wait_map.fetchRemove(key)) |kv| {
                            self.multiplexer.unregisterProcessExit(kv.value.handle) catch {};
                            kv.value.task.blocked_on_process_pid = null;
                            kv.value.task.blocked_on_process_key = null;
                            self.run_queue.append(self.allocator, kv.value.task) catch {};
                        }
                    },
                    .wake => {
                        // Drain the wake fd so a future cross-thread
                        // `signal()` can fire an edge again (edge-triggered
                        // eventfd otherwise stays asserted forever). The
                        // external queue itself is drained at the top of
                        // the next iteration.
                        self.drainOwnedWake();
                    },
                }
            }

            if (self.stallThresholdNs()) |threshold| {
                const elapsed = monotonicNowNs() - self.lastProgressNs();
                if (elapsed >= threshold) {
                    self.reportStall(threshold);
                }
            }

            self.maybeSample();
        }
    }

    /// Emit the stall diagnostic and abort. When owned by a pool, only
    /// one worker wins the CAS race and runs the aggregated dump across
    /// every worker; the losers return without dumping (their progress is
    /// moot because the winner is about to `exit(124)`). Standalone
    /// schedulers fall back to the per-scheduler dump.
    fn reportStall(self: *Scheduler, threshold_ns: i128) void {
        if (self.owner) |owner| {
            if (self.ops) |ops| {
                if (!ops.claimStallReport(owner)) return;
                ops.emitPoolStallDetect(owner, threshold_ns);
                ops.dumpAllPoolTasks(owner);
                exitOrHang(124);
            }
        }
        self.emitStallDetect(threshold_ns);
        self.dumpAllTasks();
        exitOrHang(124);
    }

    /// Terminate the process with the given exit code on hosted builds.
    /// On freestanding builds there is no process to exit, so we spin forever
    /// and leave it to the platform layer's trap handler to do something
    /// useful with the hung CPU.
    fn exitOrHang(code: u8) noreturn {
        if (is_freestanding) {
            while (true) {}
        }
        std.process.exit(code);
    }

    fn emitStallDetect(self: *Scheduler, threshold_ns: i128) void {
        var tw = trace.TraceWriter.init();

        const secs = @as(f64, @floatFromInt(@as(i64, @intCast(@min(threshold_ns, std.math.maxInt(i64)))))) / @as(f64, @floatFromInt(@as(i64, std.time.ns_per_s)));

        self.all_tasks_mu.lock();
        defer self.all_tasks_mu.unlock();

        var active_count: usize = 0;
        var runnable_count: usize = 0;
        for (self.all_tasks.items) |task| {
            switch (task.getStatus()) {
                .completed, .failed, .cancelled => continue,
                .pending, .running => {},
            }
            active_count += 1;
            if (self.taskState(task) == .runnable) {
                runnable_count += 1;
            }
        }

        tw.print("STALL-DETECT: {d:.1}s with no progress, {d} tasks, {d} runnable\n", .{ secs, active_count, runnable_count });
    }

    /// Dump the state of all tasks to stderr for diagnostic purposes.
    ///
    /// Each task is printed with its ID, name, state, top 3 stack values, and
    /// call stack. Used by stall detection and hard timeout to surface what
    /// the scheduler is stuck on.
    pub fn dumpAllTasks(self: *Scheduler) void {
        var tw = trace.TraceWriter.init();

        self.all_tasks_mu.lock();
        defer self.all_tasks_mu.unlock();

        var runnable_count: usize = 0;
        var active_count: usize = 0;
        for (self.all_tasks.items) |task| {
            switch (task.getStatus()) {
                .completed, .failed, .cancelled => continue,
                .pending, .running => {},
            }
            active_count += 1;
            if (self.taskState(task) == .runnable) {
                runnable_count += 1;
            }
        }

        tw.print("TASK-DUMP: {d} tasks, {d} runnable\n", .{ active_count, runnable_count });

        for (self.all_tasks.items) |task| {
            switch (task.getStatus()) {
                .completed, .failed, .cancelled => continue,
                .pending, .running => {},
            }
            self.dumpOneTask(&tw, task);
        }
    }

    pub const TaskState = enum {
        running,
        blocked_fd,
        blocked_process,
        blocked_channel,
        blocked_scope,
        blocked_load_lock,
        sleeping,
        runnable,
    };

    pub fn taskState(self: *const Scheduler, task: *const Task) TaskState {
        if (self.current_task == task) return .running;
        if (task.blocked_on_io_fd != null) return .blocked_fd;
        if (task.blocked_on_process_pid != null) return .blocked_process;
        if (task.blocked_on_channel != null) return .blocked_channel;
        if (task.blocked_on_scope != null) return .blocked_scope;
        if (task.blocked_on_load_lock != null) return .blocked_load_lock;
        for (self.sleep_queue.items[0..self.sleep_queue.count()]) |entry| {
            if (entry.task == task) return .sleeping;
        }
        return .runnable;
    }

    pub fn dumpOneTask(self: *const Scheduler, tw: *trace.TraceWriter, task: *const Task) void {
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        w.print("  task[{d}]", .{task.id}) catch return;
        if (task.name) |name| {
            w.print(" \"{s}\"", .{name}) catch return;
        }

        switch (self.taskState(task)) {
            .running => w.writeAll(" running") catch return,
            .blocked_fd => w.print(" blocked_fd={d}", .{task.blocked_on_io_fd.?}) catch return,
            .blocked_process => w.print(" blocked_process={d}", .{task.blocked_on_process_pid.?}) catch return,
            .blocked_channel => w.writeAll(" blocked_channel") catch return,
            .blocked_scope => w.writeAll(" blocked_scope") catch return,
            .blocked_load_lock => w.writeAll(" blocked_load_lock") catch return,
            .sleeping => {
                const remaining = self.sleepRemaining(task);
                if (remaining) |ns| {
                    const secs = @as(f64, @floatFromInt(@as(i64, @intCast(@min(ns, std.math.maxInt(i64)))))) / @as(f64, @floatFromInt(@as(i64, std.time.ns_per_s)));
                    w.print(" sleeping(+{d:.1}s)", .{secs}) catch return;
                } else {
                    w.writeAll(" sleeping") catch return;
                }
            },
            .runnable => w.writeAll(" runnable") catch return,
        }

        w.writeByte(' ') catch return;
        trace.formatStackPreview(&task.ctx.stack, w, 3);
        w.writeAll(" callstack:\n") catch return;

        tw.writeAll(fbs.getWritten());

        self.dumpCallStack(tw, task);
    }

    fn sleepRemaining(self: *const Scheduler, task: *const Task) ?i128 {
        for (self.sleep_queue.items[0..self.sleep_queue.count()]) |entry| {
            if (entry.task == task) {
                const now = self.nowNs();
                const remaining = entry.wake_time - now;

                return if (remaining > 0) remaining else 0;
            }
        }

        return null;
    }

    fn dumpCallStack(_: *const Scheduler, tw: *trace.TraceWriter, task: *const Task) void {
        const items = task.ctx.call_stack.items;
        if (items.len == 0) {
            tw.print("    (empty)\n", .{});
            return;
        }

        var i = items.len;
        while (i > 0) {
            i -= 1;
            const frame = items[i];
            tw.print("    {s}:{d} {s}\n", .{ task.ctx.current_source, frame.line, frame.word_name });
        }
    }

    /// Cancel a task cooperatively. Routes the request to the task's home
    /// worker so all per-state cleanup (IO/sleep/process/scope/channel)
    /// runs on the thread that owns the relevant queues.
    ///
    /// - Local target: process inline via `cancelTaskLocal`.
    /// - Remote target: publish `cancellation_phase = .pending`, push the
    ///   task onto the home worker's cancellation queue, and signal its
    ///   wake source. The home worker drains the queue at the top of its
    ///   next loop iteration and runs `cancelTaskLocal` itself.
    ///
    /// Safe to call from any worker. Idempotent: re-cancelling a task
    /// that has already observed cancellation is a no-op.
    pub fn cancelTask(self: *Scheduler, task: *Task) void {
        const home = if (task.ctx.scheduler) |s| s else self;
        if (home == self) {
            self.cancelTaskLocal(task);
        } else {
            self.cancelTaskRemote(home, task);
        }
    }

    /// Cancel a task whose home scheduler is `self`. Sets
    /// `cancellation_phase` to `.pending` and routes the task back to the
    /// run queue, unwiring any blocked-on state it currently owns. If the
    /// task is waiting on a nested scope, the scope's children are
    /// cancelled (each child re-enters the public `cancelTask` router so
    /// children on other workers take the remote path).
    pub fn cancelTaskLocal(self: *Scheduler, task: *Task) void {
        switch (task.getStatus()) {
            .completed, .failed, .cancelled => return,
            .pending, .running => {},
        }

        // A task that has already observed the cancellation is either unwinding or shielding a cleanup handler.
        //
        // A late drain of the cross-worker cancellation queue can land here after the task advanced past
        // `.pending` on its own. This happens when a compiled loop reaches a safepoint and reads the atomically-
        // set flag before its home worker returns to the loop top to drain the queue.
        //
        // Resetting the phase here would reärm cancellation and abort a shielded cleanup handler the next time
        // it suspends. The task is already running or requeued, so it needs no rerouting.
        switch (task.getCancellationPhase()) {
            .unwinding, .shielded => return,
            .none, .pending => {},
        }

        task.setCancellationPhase(.pending);

        if (task.blocked_on_channel) |ch_ptr| {
            // Unwire the task from the channel's waiter list before enqueuing,
            // mirroring the io/process branches below. Leaving a stale entry
            // lets a later send re-wake the task, enqueuing it a second time
            // and resuming a coroutine that is no longer suspended. Enqueue
            // only if the task was still parked; a false return means a
            // concurrent send/receive already woke it.
            const ch: *Channel = @ptrCast(@alignCast(ch_ptr));
            if (ch.removeWaiter(task)) {
                self.run_queue.append(self.allocator, task) catch {};
            }
        } else if (task.blocked_on_io_fd) |fd| {
            if (self.io_wait_map.fetchRemove(fd)) |kv| {
                self.multiplexer.unregister(fd, kv.value.event) catch {};
            }
            task.blocked_on_io_fd = null;
            self.run_queue.append(self.allocator, task) catch {};
        } else if (task.blocked_on_process_key) |key| {
            if (self.process_wait_map.fetchRemove(key)) |kv| {
                self.multiplexer.unregisterProcessExit(kv.value.handle) catch {};
            }
            task.blocked_on_process_pid = null;
            task.blocked_on_process_key = null;
            self.run_queue.append(self.allocator, task) catch {};
        } else if (task.blocked_on_load_lock) |lock_ptr| {
            const lock: *LoadLock = @ptrCast(@alignCast(lock_ptr));
            if (lock.removeWaiter(task)) {
                self.run_queue.append(self.allocator, task) catch {};
            }
        } else if (task.blocked_on_scope) |scope| {
            {
                scope.children_mu.lock();
                defer scope.children_mu.unlock();
                for (scope.children.items) |child| {
                    self.cancelTask(child);
                }
            }
            // Detached tasks are not in `children`, so cancel them through
            // their own list. Two sequential locked blocks avoid holding both
            // mutexes at once. `cancelTask` reroutes a detached task by its
            // blocked state and never re-enters this scope's `detached_mu`, so
            // there is no re-entrancy; `removeDetached` at the task's own
            // completion blocks until this walk finishes.
            {
                scope.detached_mu.lock();
                defer scope.detached_mu.unlock();
                for (scope.detached.items) |detached_task| {
                    self.cancelTask(detached_task);
                }
            }
        } else {
            self.wakeSleepingTask(task);
        }
    }

    /// Cancel a task whose home scheduler is on a different worker.
    /// Publishes the flag, then hands the task off to the home worker's
    /// cancellation queue so per-state cleanup runs on the owning thread.
    fn cancelTaskRemote(self: *Scheduler, home: *Scheduler, task: *Task) void {
        _ = self;
        switch (task.getStatus()) {
            .completed, .failed, .cancelled => return,
            .pending, .running => {},
        }

        // Idempotent: skip if already cancelling.
        if (task.getCancellationPhase() != .none) return;
        task.setCancellationPhase(.pending);

        if (home.owner) |owner| {
            if (home.ops) |ops| {
                ops.requestCancellation(owner, task) catch {};
                return;
            }
        }
        // Standalone test scheduler with no concurrent runLoop: process
        // inline. Mirrors the `wakeTask` standalone fallback.
        home.cancelTaskLocal(task);
    }

    /// Remove a specific task from the sleep queue and add it to the run queue.
    /// Used to wake a sleeping task immediately when it is cancelled.
    fn wakeSleepingTask(self: *Scheduler, task: *Task) void {
        var i: usize = 0;
        while (i < self.sleep_queue.count()) {
            if (self.sleep_queue.items[i].task == task) {
                _ = self.sleep_queue.removeIndex(i);
                self.run_queue.append(self.allocator, task) catch {};
                return;
            }
            i += 1;
        }
    }

    /// Handle a completed or failed task
    ///
    /// 1. If the task is awaited by another task, re-enqueue the awaiting task.
    /// 2. If the task failed and the scope doesn't have an error yet, store the error on the scope.
    /// 3. If all children in the scope are done and the scope is being awaited, re-enqueue the scope waiter.
    /// 4. Track the finished task for resource cleanup in deinit.
    fn handleTaskDone(self: *Scheduler, task: *Task) void {
        if (task.detached) {
            self.handleDetachedTaskDone(task);
            return;
        }

        _ = task.scope.active_children.fetchSub(1, .acq_rel);

        if (task.awaiting_task) |awaiter| {
            self.wakeTask(awaiter) catch {};
        }

        if (task.getStatus() == .failed) {
            // Ensure `error_obj` is non-null so the scope-exit walk in
            // `firstFailedChildError` always has something to propagate,
            // even when the task failed without recording details.
            if (task.error_obj == null) {
                task.error_obj = value_mod.boxErrorObject(task.ctx.quotationAllocator(), .{
                    .error_type = "task-error",
                    .message = "task failed without error details",
                }) catch null;
            }
        }

        // NOTE(ripta): When a task fails, convey the cancellation to siblings in the same scope.
        //              This is a best-effort attempt to prevent siblings from doing more work after
        //              a failure, but it doesn't guarantee that they won't do any more work since
        //              they may have already been resumed and be running concurrently. The cancelled
        //              flag is checked in the scheduler loop before resuming a task, but if a sibling
        //              is already running then it may not observe the cancellation until it yields
        //              back to the scheduler.
        //
        // A `race_first_finisher` scope extends the trigger to any completion: the first child to
        // finish, failed or not, cancels the losing sibling. `with-timeout` uses this so the timer is
        // cancelled once the main task completes and the main task is cancelled once the timer fires.
        //
        // The cmpxchg ensures only the wall-clock-first finisher fires
        // the sibling-cancellation cascade; the language-visible
        // propagated error is selected in spawn order at scope exit
        // by `TaskScope.firstFailedChildError`, so the cancellation
        // trigger and the propagated error may identify different
        // tasks under M:N.
        if ((task.getStatus() == .failed or task.scope.race_first_finisher) and
            task.scope.cancellation_requested.cmpxchgStrong(false, true, .acq_rel, .acquire) == null)
        {
            // XXX(ripta): Be sure to skip the scope task since it's the coordinator and needs to observe
            //             the failure via await, but it may not be in the same scope if it's a nested scope.
            //
            // `cancelTask` routes siblings on other workers through their
            // home worker's cancellation queue, so per-state cleanup
            // happens on the owning thread.
            task.scope.children_mu.lock();
            defer task.scope.children_mu.unlock();
            for (task.scope.children.items) |sibling| {
                if (sibling == task) continue;
                if (sibling == task.scope.scope_task) continue;
                self.cancelTask(sibling);
            }
        }

        self.maybeWakeScopeWaiter(task.scope);

        if (task.peak_stack_usage > self.peak_task_stack_usage) {
            self.peak_task_stack_usage = task.peak_stack_usage;
        }
        // The `finished_tasks` length is the periodic sampler's `retained=`
        // signal, read cross-worker under `all_tasks_mu`, so the append is
        // brought under that lock too. `children_mu` above is released before
        // this point, so no nested lock ordering arises.
        {
            self.all_tasks_mu.lock();
            defer self.all_tasks_mu.unlock();
            self.finished_tasks.append(self.allocator, task) catch {};
        }

        // Drop the owning worker's active-task counter so future
        // `pickLeastLoaded` decisions reflect the freed slot. No-op when
        // the scheduler is standalone or unowned.
        self.notifyOwnerTaskDone();
    }

    /// Reap a completed detached task on its owning worker.
    ///
    /// A detached task is isolated: its failure does not fire sibling
    /// cancellation and it is not a `firstFailedChildError` candidate, so
    /// the tracked-child failure path is skipped entirely. It is removed
    /// from both the scope's `detached` list and the scheduler's `all_tasks`
    /// list while it is still counted in `detached_active`, so the scope
    /// cannot be observed drained (and freed by the woken waiter) mid-way.
    /// Only then is `detached_active` decremented; `maybeWakeScopeWaiter` is
    /// the last access to `scope`. `reapTask` and `notifyOwnerTaskDone`
    /// touch only the task and this scheduler.
    fn handleDetachedTaskDone(self: *Scheduler, task: *Task) void {
        const scope = task.scope;

        scope.removeDetached(task);
        self.untrackTask(task);
        _ = scope.detached_active.fetchSub(1, .acq_rel);

        if (task.peak_stack_usage > self.peak_task_stack_usage) {
            self.peak_task_stack_usage = task.peak_stack_usage;
        }

        // A detached failure is isolated from siblings, so it never surfaces
        // through scope-exit propagation. Log it before `reapTask` frees the
        // context arena that owns the error strings, so an unhandled crash
        // (such as a server handler bug) is not silent.
        if (task.getStatus() == .failed) logUnhandledDetachedFailure(task);

        self.maybeWakeScopeWaiter(scope);
        self.reapTask(task);
        self.notifyOwnerDetachedDone();
        self.notifyOwnerTaskDone();
    }

    /// Emit a one-line stderr diagnostic for an unhandled detached-task
    /// failure. Combines the scheduler caps-prefix convention with the
    /// `ErrorObject` `<error TYPE: MSG>` self-rendering. No task id is printed,
    /// so the line is stable across schedulings. `.cancelled` detached tasks
    /// do not reach here; that is expected shutdown, not a failure.
    fn logUnhandledDetachedFailure(task: *const Task) void {
        var tw = trace.TraceWriter.init();
        const error_type = if (task.error_obj) |eo| eo.error_type else "task-error";
        const message = if (task.error_obj) |eo| eo.message else "task failed without error details";
        if (task.name) |name| {
            tw.print("DETACHED-TASK-FAILED \"{s}\": <error {s}: {s}>\n", .{ name, error_type, message });
        } else {
            tw.print("DETACHED-TASK-FAILED: <error {s}: {s}>\n", .{ error_type, message });
        }
    }

    /// Wake the scope waiter once both tracked and detached tasks have
    /// drained. The `waiter_woken` claim guarantees a single wake even when
    /// the last tracked child and the last detached task complete
    /// concurrently on different workers. Top-level scopes have no
    /// `waiting_task`; they terminate via the pool's `active_tasks` /
    /// `poolHasAliveTasks` path, so this is a no-op for them.
    fn maybeWakeScopeWaiter(self: *Scheduler, scope: *TaskScope) void {
        if (scope.active_children.load(.acquire) != 0) return;
        if (scope.detached_active.load(.acquire) != 0) return;
        if (scope.waiter_woken.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        if (scope.waiting_task) |scope_waiter| {
            scope.waiting_task = null;
            self.wakeTask(scope_waiter) catch {};
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "init and deinit empty scheduler" {
    var sched = try Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    try std.testing.expectEqual(@as(usize, 0), sched.run_queue.items.len);
    try std.testing.expect(sched.current_task == null);
    try std.testing.expectEqual(@as(u64, 1), sched.next_task_id.load(.acquire));
}

test "nextId increments" {
    var sched = try Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    try std.testing.expectEqual(@as(u64, 1), sched.nextId());
    try std.testing.expectEqual(@as(u64, 2), sched.nextId());
    try std.testing.expectEqual(@as(u64, 3), sched.nextId());
}

test "runLoop exits immediately with empty queue and should not hang or crash" {
    var sched = try Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    sched.runLoop();
}

test "nowNs returns fake value" {
    var sched = try Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    sched.clock = .{ .fake = 42_000_000_000 };
    try std.testing.expectEqual(@as(i128, 42_000_000_000), sched.nowNs());
}

test "advanceClock advances fake time" {
    var sched = try Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    sched.clock = .{ .fake = 1_000_000_000 };
    sched.advanceClock(500_000_000);
    try std.testing.expectEqual(@as(i128, 1_500_000_000), sched.nowNs());
}

test "nextId is unique under concurrent access" {
    var sched = try Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    const Worker = struct {
        sched: *Scheduler,
        ids: []u64,

        fn run(self: @This()) void {
            for (self.ids) |*slot| {
                slot.* = self.sched.nextId();
            }
        }
    };

    const per_thread: usize = 2_000;
    const thread_count: usize = 4;
    var buf: [thread_count * per_thread]u64 = undefined;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        const slice = buf[i * per_thread .. (i + 1) * per_thread];
        t.* = try std.Thread.spawn(.{}, Worker.run, .{Worker{ .sched = &sched, .ids = slice }});
    }
    for (threads) |t| t.join();

    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    for (buf) |id| {
        const gop = try seen.getOrPut(id);
        try std.testing.expect(!gop.found_existing);
    }
    try std.testing.expectEqual(@as(usize, thread_count * per_thread), seen.count());
}

test "drainTaskProfile copies samples into the worker collection with labels" {
    const alloc = std.testing.allocator;
    const Context = @import("context.zig").Context;

    var sink: ProfileStats = .{};
    defer sink.deinit(alloc);

    var sched = try Scheduler.init(alloc);
    sched.profile_sink = &sink;
    sched.worker_id = 2;

    // A task Context that owns a profile buffer with one recorded dispatch.
    var ctx = Context.init(alloc);
    const pstats = try alloc.create(ProfileStats);
    pstats.* = .{};
    ctx.profile = pstats;
    ctx.profile_owned = true;
    pstats.recordWordStart(alloc);
    pstats.recordWordEnd(alloc, "spawned-word");

    var task: Task = .{
        .id = 42,
        .name = "job",
        .status = std.atomic.Value(TaskStatus).init(.completed),
        .ctx = &ctx,
        .scope = undefined,
        .quotation = undefined,
    };

    sched.drainTaskProfile(&task);

    try std.testing.expectEqual(@as(usize, 1), sched.drained_task_profiles.items.len);
    const dp = sched.drained_task_profiles.items[0];
    try std.testing.expectEqual(@as(u64, 42), dp.task_id);
    try std.testing.expectEqual(@as(usize, 2), dp.worker_id);
    try std.testing.expectEqualStrings("job", dp.task_name.?);
    try std.testing.expectEqual(@as(usize, 1), dp.samples.items.len);
    try std.testing.expectEqualStrings("spawned-word", dp.samples.items[0].name);
    // The drained name is a distinct allocation, not the source slice.
    try std.testing.expect(dp.samples.items[0].name.ptr != pstats.samples.items[0].name.ptr);

    // Free the source Context and its owned buffer; the drained copy stays valid.
    ctx.deinit();

    // Teardown folds the collection into the sink.
    sched.deinit();
    try std.testing.expectEqual(@as(usize, 1), sink.task_profiles.items.len);
    try std.testing.expectEqualStrings(
        "spawned-word",
        sink.task_profiles.items[0].samples.items[0].name,
    );
}

test "Scheduler.deinit frees drained task profiles when no sink is set" {
    const alloc = std.testing.allocator;
    const Context = @import("context.zig").Context;

    var sched = try Scheduler.init(alloc);

    var ctx = Context.init(alloc);
    const pstats = try alloc.create(ProfileStats);
    pstats.* = .{};
    ctx.profile = pstats;
    ctx.profile_owned = true;
    pstats.recordWordStart(alloc);
    pstats.recordWordEnd(alloc, "detached-word");

    var task: Task = .{
        .id = 7,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.completed),
        .ctx = &ctx,
        .scope = undefined,
        .quotation = undefined,
    };

    sched.drainTaskProfile(&task);
    try std.testing.expectEqual(@as(usize, 1), sched.drained_task_profiles.items.len);

    ctx.deinit();

    // No sink: teardown frees the drained buffers. The testing allocator asserts
    // no leak or double-free at test end.
    sched.deinit();
}

test "drainTaskProfile is a no-op when the task carries no owned profile" {
    const alloc = std.testing.allocator;
    const Context = @import("context.zig").Context;

    var sched = try Scheduler.init(alloc);
    defer sched.deinit();

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    var task: Task = .{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.completed),
        .ctx = &ctx,
        .scope = undefined,
        .quotation = undefined,
    };

    sched.drainTaskProfile(&task);
    try std.testing.expectEqual(@as(usize, 0), sched.drained_task_profiles.items.len);
}
