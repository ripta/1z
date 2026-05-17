const std = @import("std");
const Allocator = std.mem.Allocator;
const task_mod = @import("task.zig");
const Task = task_mod.Task;
const Channel = @import("channel.zig").Channel;
const TaskStatus = task_mod.TaskStatus;
const TaskScope = task_mod.TaskScope;
const Multiplexer = @import("multiplexer.zig").Multiplexer;
const IoEvent = @import("multiplexer.zig").IoEvent;
const ProcessWaitHandle = @import("multiplexer.zig").ProcessWaitHandle;
const processWaitHandleKey = @import("multiplexer.zig").processWaitHandleKey;
const trace = @import("trace.zig");
const value_mod = @import("value.zig");

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
    pid: std.posix.pid_t,
    handle: ProcessWaitHandle,
};

/// Read the monotonic clock and return the current time as a single i128 nanosecond value.
pub fn monotonicNowNs() i128 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch unreachable;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
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
    next_task_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
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
    /// Maps file descriptors to tasks suspended waiting on I/O readiness.
    io_wait_map: std.AutoHashMapUnmanaged(std.posix.fd_t, IoWaitEntry) = .{},
    /// Maps child-process wait handles to tasks suspended waiting on exit.
    process_wait_map: std.AutoHashMapUnmanaged(u64, ProcessWaitEntry) = .{},
    /// Wall-clock stall detection threshold in nanoseconds.
    deadlock_detect_ns: ?i128 = null,
    /// Monotonic timestamp of the last progress event (task done, sleeper woken, I/O ready).
    last_progress_ns: i128 = 0,
    /// Clock mode.
    clock: ClockMode = .real,
    peak_task_stack_usage: usize = 0,
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
            task_mod.coroDestroy(t);
            t.ctx.deinit();
            self.allocator.destroy(t.ctx);
            self.allocator.destroy(t);
        }
        self.finished_tasks.deinit(self.allocator);
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
    pub fn nextId(self: *Scheduler) u64 {
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

    fn drainOwnedWake(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        ops.drainWake(owner);
    }

    fn notifyOwnerTaskDone(self: *Scheduler) void {
        const owner = self.owner orelse return;
        const ops = self.ops orelse return;
        ops.onTaskDone(owner);
    }

    fn isBackgroundWorker(self: *Scheduler) bool {
        const owner = self.owner orelse return false;
        const ops = self.ops orelse return false;
        return !ops.isPrimary(owner);
    }

    fn shutdownObserved(self: *Scheduler) bool {
        const owner = self.owner orelse return true;
        const ops = self.ops orelse return true;
        return ops.shutdownRequested(owner);
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
    pub fn ioSuspendCurrentTask(self: *Scheduler, fd: std.posix.fd_t, event: IoEvent) void {
        if (self.current_task) |task| {
            self.multiplexer.register(fd, event) catch {};
            self.io_wait_map.put(self.allocator, fd, .{ .task = task, .event = event }) catch {};
            task.blocked_on_io_fd = fd;
            task_mod.coroYield();
        }
    }

    /// Suspend the current task until the child process exits.
    pub fn processSuspendCurrentTask(self: *Scheduler, pid: std.posix.pid_t) !void {
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
        var removals = std.ArrayListUnmanaged(std.posix.fd_t){};
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
        self.last_progress_ns = monotonicNowNs();

        while (true) {
            // Move any tasks pushed onto the owning worker's external queue
            // into the local run queue before we make scheduling decisions.
            self.drainOwnedExternal();
            // Process cross-thread cancellation requests next so the local
            // logic can route blocked tasks (IO/sleep/process/scope/channel)
            // back into the run queue before the scheduling pass picks one.
            self.drainOwnedCancellations();

            if (self.wakeExpiredSleepers()) {
                self.last_progress_ns = monotonicNowNs();
            }

            if (self.run_queue.items.len > 0) {
                const task = self.run_queue.orderedRemove(0);
                self.current_task = task;

                task.setStatus(.running);
                task_mod.coroResume(task);
                self.current_task = null;
                switch (task.getStatus()) {
                    .completed, .failed, .cancelled => {
                        self.handleTaskDone(task);
                        self.last_progress_ns = monotonicNowNs();
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
                if (!has_sleepers and !has_io_waiters and !has_process_waiters and !has_blocked_tasks) break;
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

            if (self.deadlock_detect_ns) |threshold| {
                const now = monotonicNowNs();
                const stall_remaining = threshold - (now - self.last_progress_ns);
                const stall_timeout: i128 = if (stall_remaining > 0) stall_remaining else 0;
                timeout = if (timeout) |t| @min(t, stall_timeout) else stall_timeout;
            }

            if (self.clock == .fake) {
                timeout = 0;
            }

            const ready = self.multiplexer.poll(timeout) catch &.{};
            if (ready.len > 0) {
                self.last_progress_ns = monotonicNowNs();
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

            if (self.deadlock_detect_ns) |threshold| {
                const elapsed = monotonicNowNs() - self.last_progress_ns;
                if (elapsed >= threshold) {
                    self.emitStallDetect(threshold);
                    self.dumpAllTasks();
                    std.process.exit(124);
                }
            }
        }
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

    const TaskState = enum {
        running,
        blocked_fd,
        blocked_process,
        blocked_channel,
        blocked_scope,
        sleeping,
        runnable,
    };

    fn taskState(self: *const Scheduler, task: *const Task) TaskState {
        if (self.current_task == task) return .running;
        if (task.blocked_on_io_fd != null) return .blocked_fd;
        if (task.blocked_on_process_pid != null) return .blocked_process;
        if (task.blocked_on_channel != null) return .blocked_channel;
        if (task.blocked_on_scope != null) return .blocked_scope;
        for (self.sleep_queue.items[0..self.sleep_queue.count()]) |entry| {
            if (entry.task == task) return .sleeping;
        }
        return .runnable;
    }

    fn dumpOneTask(self: *const Scheduler, tw: *trace.TraceWriter, task: *const Task) void {
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

        task.setCancellationPhase(.pending);

        if (task.blocked_on_channel != null) {
            self.run_queue.append(self.allocator, task) catch {};
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
        } else if (task.blocked_on_scope) |scope| {
            scope.children_mu.lock();
            defer scope.children_mu.unlock();
            for (scope.children.items) |child| {
                self.cancelTask(child);
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
        const prev_children = task.scope.active_children.fetchSub(1, .acq_rel);

        if (task.awaiting_task) |awaiter| {
            self.wakeTask(awaiter) catch {};
        }

        if (task.getStatus() == .failed and task.scope.failed_error == null) {
            if (task.error_obj == null) {
                task.error_obj = value_mod.boxErrorObject(task.ctx.quotationAllocator(), .{
                    .error_type = "task-error",
                    .message = "task failed without error details",
                }) catch null;
            }
            task.scope.failed_error = task.error_obj;

            // NOTE(ripta): When a task fails, convey the cancellation to siblings in the same scope.
            //              This is a best-effort attempt to prevent siblings from doing more work after
            //              a failure, but it doesn't guarantee that they won't do any more work since
            //              they may have already been resumed and be running concurrently. The cancelled
            //              flag is checked in the scheduler loop before resuming a task, but if a sibling
            //              is already running then it may not observe the cancellation until it yields
            //              back to the scheduler.
            task.scope.cancellation_requested.store(true, .release);

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

        // Only the worker that decremented `active_children` to zero is
        // allowed to wake the scope waiter. Reading `waiting_task` here is
        // race-free because under M:N two completing children could both
        // observe `allChildrenDone()` true if both checked after both
        // decrements; the unique-winner guard prevents a double-wake.
        if (prev_children == 1) {
            if (task.scope.waiting_task) |scope_waiter| {
                task.scope.waiting_task = null;
                self.wakeTask(scope_waiter) catch {};
            }
        }

        if (task.peak_stack_usage > self.peak_task_stack_usage) {
            self.peak_task_stack_usage = task.peak_stack_usage;
        }
        self.finished_tasks.append(self.allocator, task) catch {};

        // Drop the owning worker's active-task counter so future
        // `pickLeastLoaded` decisions reflect the freed slot. No-op when
        // the scheduler is standalone or unowned.
        self.notifyOwnerTaskDone();
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
