const std = @import("std");
const Allocator = std.mem.Allocator;
const task_mod = @import("task.zig");
const Task = task_mod.Task;
const Channel = @import("channel.zig").Channel;
const TaskStatus = task_mod.TaskStatus;
const TaskScope = task_mod.TaskScope;
const Multiplexer = @import("multiplexer.zig").Multiplexer;
const IoEvent = @import("multiplexer.zig").IoEvent;

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
    /// Channels created during this scheduler's lifetime, freed on deinit.
    channels: std.ArrayListUnmanaged(*Channel) = .{},
    /// Platform I/O multiplexer for async-aware stream operations.
    multiplexer: Multiplexer,
    /// Maps file descriptors to tasks suspended waiting on I/O readiness.
    io_wait_map: std.AutoHashMapUnmanaged(std.posix.fd_t, IoWaitEntry) = .{},

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

    /// Free resources under the scheduler.
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
            const wake_time = monotonicNowNs() + duration_ns;

            self.sleep_queue.add(.{ .task = task, .wake_time = wake_time }) catch {};
            _ = task_mod.swapcontext(&task.uctx, &self.scheduler_uctx);
        }
    }

    /// Move all sleep queue entries whose wake time has passed into the run queue.
    fn wakeExpiredSleepers(self: *Scheduler) void {
        const now = monotonicNowNs();
        while (self.sleep_queue.peek()) |entry| {
            if (entry.wake_time > now) break;

            const woken = self.sleep_queue.remove();
            self.run_queue.append(self.allocator, woken.task) catch {};
        }
    }

    /// Remove cancelled tasks from the sleep queue so we don't idle-block
    /// waiting for a task that will be immediately discarded.
    ///
    /// Uses removeIndex which swaps the last element into the removed slot,
    /// so the loop must not increment the index after removal.
    fn drainCancelledSleepers(self: *Scheduler) void {
        var i: usize = 0;
        while (i < self.sleep_queue.count()) {
            if (self.sleep_queue.items[i].task.cancelled) {
                const entry = self.sleep_queue.items[i];
                entry.task.status = .cancelled;
                self.handleTaskDone(entry.task);
                _ = self.sleep_queue.removeIndex(i);
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

    /// Remove cancelled tasks from the io_wait_map so we don't block forever
    /// waiting on fds that will never be consumed.
    fn drainCancelledIOWaiters(self: *Scheduler) void {
        var removals = std.ArrayListUnmanaged(std.posix.fd_t){};
        defer removals.deinit(self.allocator);

        var it = self.io_wait_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.task.cancelled) {
                removals.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (removals.items) |fd| {
            if (self.io_wait_map.fetchRemove(fd)) |kv| {
                self.multiplexer.unregister(fd, kv.value.event) catch {};
                kv.value.task.blocked_on_io_fd = null;
                kv.value.task.status = .cancelled;
                self.handleTaskDone(kv.value.task);
            }
        }
    }

    /// Core scheduling loop
    ///
    /// Repeats until there are no more tasks to run and no more IO waiters:
    ///
    /// 1. Wake expired sleepers into the run queue.
    /// 2. If run queue non-empty: dequeue one task, handle cancellation or
    ///    resume via swapcontext, handle completion. Loop back to phase 1.
    /// 3. If run queue empty: drain cancelled sleepers and I/O waiters.
    /// 4. If I/O waiters non-empty: poll multiplexer, re-enqueue tasks whose
    ///    fds are ready. Loop back to step 1.
    /// 5. If only sleepers remain: nanosleep until the next wake time. Loop
    ///    back to step 1.
    pub fn runLoop(self: *Scheduler) void {
        while (true) {
            self.wakeExpiredSleepers();

            if (self.run_queue.items.len > 0) {
                const task = self.run_queue.orderedRemove(0);
                self.current_task = task;

                // NOTE(ripta): Propagate cancellation flag to the task state.
                //              A sibling's failure may have caused it, which is why
                //              it's still in the queue.
                if (task.cancelled) {
                    task.status = .cancelled;
                    self.handleTaskDone(task);
                    continue;
                }

                // NOTE(ripta): Set `pending_entry_task` before swapcontext.
                //              For new tasks, the entry function reads and clears it.
                //              For resumed tasks, the variable is ignored and overwritten on the next iteration.
                task_mod.pending_entry_task = task;
                task.status = .running;

                _ = task_mod.swapcontext(&self.scheduler_uctx, &task.uctx);
                self.current_task = null;
                switch (task.status) {
                    .completed, .failed => {
                        self.handleTaskDone(task);
                    },
                    .running, .pending, .cancelled => {},
                }
                continue;
            }

            self.drainCancelledSleepers();
            self.drainCancelledIOWaiters();

            // draining coulda woken waiting tasks via handleTaskDone, so re-check before blocking
            if (self.run_queue.items.len > 0) continue;

            const has_sleepers = self.sleep_queue.count() > 0;
            const has_io_waiters = self.io_wait_map.count() > 0;

            if (!has_sleepers and !has_io_waiters) break;

            if (has_io_waiters) {
                const timeout: ?i128 = if (has_sleepers) blk: {
                    const next = self.sleep_queue.peek().?;
                    const now = monotonicNowNs();
                    const remaining = next.wake_time - now;
                    break :blk if (remaining > 0) remaining else @as(i128, 0);
                } else null;

                const ready = self.multiplexer.poll(timeout) catch &.{};
                for (ready) |ev| {
                    if (self.io_wait_map.fetchRemove(ev.fd)) |kv| {
                        kv.value.task.blocked_on_io_fd = null;
                        self.run_queue.append(self.allocator, kv.value.task) catch {};
                    }
                }
                continue;
            }

            // only sleepers remain
            if (self.sleep_queue.peek()) |next| {
                const now = monotonicNowNs();
                const remaining_ns = next.wake_time - now;
                if (remaining_ns > 0) {
                    const ns_u: u128 = @intCast(remaining_ns);
                    const sec: u64 = @intCast(ns_u / std.time.ns_per_s);
                    const nsec: u64 = @intCast(ns_u % std.time.ns_per_s);
                    std.posix.nanosleep(sec, nsec);
                }
                continue;
            }
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

            // NOTE(ripta): When a task fails, convey the cancellation to siblings in the  same scope.
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
                switch (sibling.status) {
                    .pending, .running => {
                        sibling.cancelled = true;
                        if (sibling.blocked_on_channel != null) {
                            self.run_queue.append(self.allocator, sibling) catch {};
                        }
                    },
                    .completed, .failed, .cancelled => {},
                }
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
