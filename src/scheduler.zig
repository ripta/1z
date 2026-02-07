const std = @import("std");
const Allocator = std.mem.Allocator;
const task_mod = @import("task.zig");
const Task = task_mod.Task;
const TaskStatus = task_mod.TaskStatus;
const TaskScope = task_mod.TaskScope;

/// Cooperative scheduler with a FIFO run queue.
///
/// Drives green thread execution by round-robin scheduling tasks. Each task
/// runs until it yields or completes, then control returns to the scheduler
/// loop via swapcontext.
pub const Scheduler = struct {
    run_queue: std.ArrayListUnmanaged(*Task),
    current_task: ?*Task = null,
    scheduler_uctx: std.c.ucontext_t = undefined,
    next_task_id: u64 = 1,
    allocator: Allocator,
    /// Finished tasks whose stacks and arenas are freed on deinit.
    finished_tasks: std.ArrayListUnmanaged(*Task),

    pub fn init(allocator: Allocator) Scheduler {
        return .{
            .run_queue = .{},
            .current_task = null,
            .next_task_id = 1,
            .allocator = allocator,
            .finished_tasks = .{},
        };
    }

    /// Free the run queue and clean up finished task stacks and arenas.
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
        self.run_queue.deinit(self.allocator);
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
    ///
    /// TODO(ripta): This is currently only used for task scopes, but it could
    ///              also be used for a `yieldAndBlock` primitive that yields
    ///              without reënqueuing.
    pub fn suspendCurrentTask(self: *Scheduler) void {
        if (self.current_task) |task| {
            _ = task_mod.swapcontext(&task.uctx, &self.scheduler_uctx);
        }
    }

    /// Core scheduling loop. Dequeues tasks FIFO, resumes each via
    /// swapcontext, and handles completion/failure when tasks finish.
    /// Returns when the run queue is empty.
    pub fn runLoop(self: *Scheduler) void {
        while (self.run_queue.items.len > 0) {
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
                .completed, .failed => {
                    self.handleTaskDone(task);
                },
                .running, .pending, .cancelled => {},
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
            task.scope.failed_error = task.error_obj;
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
    var sched = Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    try std.testing.expectEqual(@as(usize, 0), sched.run_queue.items.len);
    try std.testing.expect(sched.current_task == null);
    try std.testing.expectEqual(@as(u64, 1), sched.next_task_id);
}

test "nextId increments" {
    var sched = Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    try std.testing.expectEqual(@as(u64, 1), sched.nextId());
    try std.testing.expectEqual(@as(u64, 2), sched.nextId());
    try std.testing.expectEqual(@as(u64, 3), sched.nextId());
}

test "runLoop exits immediately with empty queue and should not hang or crash" {
    var sched = Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    sched.runLoop();
}
