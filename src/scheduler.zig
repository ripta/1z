const std = @import("std");
const Allocator = std.mem.Allocator;
const task_mod = @import("task.zig");
const Task = task_mod.Task;
const Channel = @import("channel.zig").Channel;
const TaskStatus = task_mod.TaskStatus;
const TaskScope = task_mod.TaskScope;
const Multiplexer = @import("multiplexer.zig").Multiplexer;
const IoEvent = @import("multiplexer.zig").IoEvent;
const trace = @import("trace.zig");

/// Global pointer to the active top-level scheduler if any.
/// Set by `nativeTaskScope` on entry, and cleared on exit.
pub var active_scheduler: std.atomic.Value(?*Scheduler) = std.atomic.Value(?*Scheduler).init(null);

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

/// Cooperative scheduler with a FIFO run queue.
///
/// Drives green thread execution by round-robin scheduling tasks. Each task
/// runs until it yields or completes, then control returns to the scheduler
/// loop via swapcontext.
pub const Scheduler = struct {
    run_queue: std.ArrayListUnmanaged(*Task),
    sleep_queue: SleepQueue,
    current_task: ?*Task = null,
    scheduler_uctx: std.c.ucontext_t = undefined,
    next_task_id: u64 = 1,
    allocator: Allocator,
    /// Finished tasks whose stacks and arenas are freed on deinit.
    finished_tasks: std.ArrayListUnmanaged(*Task),
    /// All tasks ever created, for diagnostic dumps.
    all_tasks: std.ArrayListUnmanaged(*Task) = .{},
    /// Channels created during this scheduler's lifetime, freed on deinit.
    channels: std.ArrayListUnmanaged(*Channel) = .{},
    /// Platform I/O multiplexer for async-aware stream operations.
    multiplexer: Multiplexer,
    /// Maps file descriptors to tasks suspended waiting on I/O readiness.
    io_wait_map: std.AutoHashMapUnmanaged(std.posix.fd_t, IoWaitEntry) = .{},
    /// Wall-clock stall detection threshold in nanoseconds.
    deadlock_detect_ns: ?i128 = null,
    /// Monotonic timestamp of the last progress event (task done, sleeper woken, I/O ready).
    last_progress_ns: i128 = 0,
    /// Clock mode.
    clock: ClockMode = .real,

    pub fn init(allocator: Allocator) !Scheduler {
        return .{
            .run_queue = .{},
            .sleep_queue = SleepQueue.init(allocator, {}),
            .current_task = null,
            .next_task_id = 1,
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
            if (t.stack_mem) |mem| {
                task_mod.freeTaskStack(mem);
                t.stack_mem = null;
            }
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
    }

    /// Register a channel for cleanup when the scheduler is destroyed.
    pub fn trackChannel(self: *Scheduler, ch: *Channel) !void {
        try self.channels.append(self.allocator, ch);
    }

    /// Append a task to the end of the run queue.
    pub fn enqueue(self: *Scheduler, task: *Task) !void {
        try self.run_queue.append(self.allocator, task);
    }

    /// Return the next task ID and increment the counter.
    pub fn nextId(self: *Scheduler) u64 {
        const id = self.next_task_id;
        self.next_task_id += 1;
        return id;
    }

    /// Re-enqueue the current task and swap back to the scheduler context.
    /// Called from within a running task by the `yield` primitive.
    pub fn yieldCurrentTask(self: *Scheduler) void {
        if (self.current_task) |task| {
            self.run_queue.append(self.allocator, task) catch {};
            _ = task_mod.swapcontext(&task.uctx, &self.scheduler_uctx);
        }
    }

    /// Swap context back to the scheduler without reënqueuing the current task.
    /// Used by nested `task-scope` to block the calling task until its scope completes.
    pub fn suspendCurrentTask(self: *Scheduler) void {
        if (self.current_task) |task| {
            _ = task_mod.swapcontext(&task.uctx, &self.scheduler_uctx);
        }
    }

    /// Suspend the current task until `duration_ns` nanoseconds have elapsed.
    /// Inserts the task into the sleep queue and swaps back to the scheduler.
    pub fn sleepCurrentTask(self: *Scheduler, duration_ns: i128) void {
        if (self.current_task) |task| {
            const wake_time = self.nowNs() + duration_ns;

            self.sleep_queue.add(.{ .task = task, .wake_time = wake_time }) catch {};
            _ = task_mod.swapcontext(&task.uctx, &self.scheduler_uctx);
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
            if (self.sleep_queue.items[i].task.cancellation_phase != .none) {
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
            _ = task_mod.swapcontext(&task.uctx, &self.scheduler_uctx);
        }
    }

    /// Move cancelled tasks from the I/O wait map to the run queue so they
    /// resume and unwind cooperatively through their cleanup handlers.
    fn drainCancelledIOWaiters(self: *Scheduler) void {
        var removals = std.ArrayListUnmanaged(std.posix.fd_t){};
        defer removals.deinit(self.allocator);

        var it = self.io_wait_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.task.cancellation_phase != .none) {
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

    /// Core scheduling loop
    ///
    /// Repeats until there are no more tasks to run and no more IO waiters:
    ///
    /// 1. Wake expired sleepers into the run queue.
    /// 2. If run queue non-empty: dequeue one task, handle cancellation or
    ///    resume via swapcontext, handle completion. Loop back to step 1.
    /// 3. Run queue empty: drain cancelled sleepers and I/O waiters.
    /// 4. If sleepers or I/O waiters remain: poll multiplexer with the next
    ///    sleep deadline as timeout, re-enqueue tasks whose fds are ready.
    ///    Loop back to step 1.
    pub fn runLoop(self: *Scheduler) void {
        self.last_progress_ns = monotonicNowNs();

        while (true) {
            if (self.wakeExpiredSleepers()) {
                self.last_progress_ns = monotonicNowNs();
            }

            if (self.run_queue.items.len > 0) {
                const task = self.run_queue.orderedRemove(0);
                self.current_task = task;

                // NOTE(ripta): Set `pending_entry_task` before swapcontext.
                //              For new tasks, the entry function reads and clears it.
                //              For resumed tasks, the variable is ignored and overwritten on the next iteration.
                task_mod.pending_entry_task = task;
                task.status = .running;

                _ = task_mod.swapcontext(&self.scheduler_uctx, &task.uctx);
                self.current_task = null;
                switch (task.status) {
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

            // draining coulda woken waiting tasks via handleTaskDone, so re-check before blocking
            if (self.run_queue.items.len > 0) continue;

            const has_sleepers = self.sleep_queue.count() > 0;
            const has_io_waiters = self.io_wait_map.count() > 0;
            const has_blocked_tasks = blk: {
                for (self.all_tasks.items) |task| {
                    switch (task.status) {
                        .completed, .failed, .cancelled => continue,
                        .pending, .running => {},
                    }
                    if (task.blocked_on_channel != null or task.blocked_on_scope != null) break :blk true;
                }
                break :blk false;
            };

            if (!has_sleepers and !has_io_waiters and !has_blocked_tasks) break;

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
                if (self.io_wait_map.fetchRemove(ev.fd)) |kv| {
                    kv.value.task.blocked_on_io_fd = null;
                    self.run_queue.append(self.allocator, kv.value.task) catch {};
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

    fn emitStallDetect(self: *const Scheduler, threshold_ns: i128) void {
        var tw = trace.TraceWriter.init();

        const secs = @as(f64, @floatFromInt(@as(i64, @intCast(@min(threshold_ns, std.math.maxInt(i64)))))) / @as(f64, @floatFromInt(@as(i64, std.time.ns_per_s)));

        var active_count: usize = 0;
        var runnable_count: usize = 0;
        for (self.all_tasks.items) |task| {
            switch (task.status) {
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

        var runnable_count: usize = 0;
        var active_count: usize = 0;
        for (self.all_tasks.items) |task| {
            switch (task.status) {
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
            switch (task.status) {
                .completed, .failed, .cancelled => continue,
                .pending, .running => {},
            }
            self.dumpOneTask(&tw, task);
        }
    }

    const TaskState = enum {
        running,
        blocked_fd,
        blocked_channel,
        blocked_scope,
        sleeping,
        runnable,
    };

    fn taskState(self: *const Scheduler, task: *const Task) TaskState {
        if (self.current_task == task) return .running;
        if (task.blocked_on_io_fd != null) return .blocked_fd;
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

    /// Cancel a task cooperatively. Sets `cancellation_phase` to `.pending`
    /// and requeues the task so it resumes and unwinds through its cleanup
    /// handlers. If the task is blocked on a channel, I/O fd, or sleeping,
    /// it is moved to the run queue immediately. If the task is waiting on a
    /// nested scope, we recursively cancel all children so the scope drains
    /// and the waiting task is eventually requeued by `handleTaskDone`.
    pub fn cancelTask(self: *Scheduler, task: *Task) void {
        switch (task.status) {
            .completed, .failed, .cancelled => return,
            .pending, .running => {},
        }

        task.cancellation_phase = .pending;

        if (task.blocked_on_channel != null) {
            self.run_queue.append(self.allocator, task) catch {};
        } else if (task.blocked_on_io_fd) |fd| {
            if (self.io_wait_map.fetchRemove(fd)) |kv| {
                self.multiplexer.unregister(fd, kv.value.event) catch {};
            }
            task.blocked_on_io_fd = null;
            self.run_queue.append(self.allocator, task) catch {};
        } else if (task.blocked_on_scope) |scope| {
            for (scope.children.items) |child| {
                self.cancelTask(child);
            }
        } else {
            self.wakeSleepingTask(task);
        }
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
        if (task.awaiting_task) |awaiter| {
            self.run_queue.append(self.allocator, awaiter) catch {};
        }

        if (task.status == .failed and task.scope.failed_error == null) {
            task.scope.failed_error = task.error_obj orelse .{
                .error_type = "task-error",
                .message = "task failed without error details",
            };

            // NOTE(ripta): When a task fails, convey the cancellation to siblings in the same scope.
            //              This is a best-effort attempt to prevent siblings from doing more work after
            //              a failure, but it doesn't guarantee that they won't do any more work since
            //              they may have already been resumed and be running concurrently. The cancelled
            //              flag is checked in the scheduler loop before resuming a task, but if a sibling
            //              is already running then it may not observe the cancellation until it yields
            //              back to the scheduler.
            //
            // XXX(ripta): Be sure to skip the scope task since it's the coordinator and needs to observe
            //             the failure via await, but it may not be in the same scope if it's a nested scope.
            for (task.scope.children.items) |sibling| {
                if (sibling == task) continue;
                if (sibling == task.scope.scope_task) continue;
                self.cancelTask(sibling);
            }
        }

        if (task.scope.allChildrenDone()) {
            if (task.scope.waiting_task) |scope_waiter| {
                self.run_queue.append(self.allocator, scope_waiter) catch {};
                task.scope.waiting_task = null;
            }
        }

        self.finished_tasks.append(self.allocator, task) catch {};
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
    try std.testing.expectEqual(@as(u64, 1), sched.next_task_id);
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
