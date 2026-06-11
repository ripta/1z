const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;

const is_freestanding = builtin.os.tag == .freestanding;
const task_mod = @import("../task.zig");
const Task = task_mod.Task;
const TaskScope = task_mod.TaskScope;
const scheduler_mod = @import("../scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const worker_mod = @import("../worker.zig");
const Worker = worker_mod.Worker;
const WorkerPool = worker_mod.WorkerPool;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const ErrorObject = value_mod.ErrorObject;
const Quotation = value_mod.Quotation;
const stack_effect_mod = @import("../stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;
const container_limits = @import("../container_limits.zig");

// Keep extra headroom so overflow handling can still unwind and materialize an
// error object after detecting that a task exhausted its native stack.
// The reserve must exceed the largest single Zig frame in the recursive
// execution path (executeInstructions + executeQuotationWithPic) so the 1z
// overflow check always fires before the OS guard page is reached. Debug
// builds have larger frames, so we use 1/8 of the total stack as the reserve
// rather than a fixed byte count.
const task_stack_size: usize = 768 * 1024;
const task_stack_reserve: usize = task_stack_size / 8;

const RegistryEntry = @import("types.zig").RegistryEntry;

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "fake-clock", .func = nativeFakeClock },
    .{ .name = "advance-clock", .func = nativeAdvanceClock },
};

pub const primitives = [_]Primitive{
    .{ .name = "task-scope", .stack_effect = "quot --", .doc = "Run quotation in a structured concurrency scope. Waits for every child task to reach a terminal status regardless of which worker each child ran on. When task-scope returns, normally or by re-throwing a child's error, every child has reached terminal status and its registered cleanup handler has run to completion.", .func = nativeTaskScope },
    .{ .name = "spawn", .stack_effect = "quot -- task", .doc = "Spawn a new task from a quotation. The task is pinned to the worker with the fewest active tasks at spawn time for its entire lifetime.", .func = nativeSpawn },
    .{ .name = "spawn-named", .stack_effect = "quot name -- task", .doc = "Spawn a named task from a quotation.", .func = nativeSpawnNamed },
    .{ .name = "task-self", .stack_effect = "-- task", .doc = "Push the current task handle.", .func = nativeTaskSelf },
    .{ .name = "yield", .stack_effect = "--", .doc = "Voluntarily yield the current task.", .func = nativeYield },
    .{ .name = "await", .stack_effect = "task -- value", .doc = "Wait for a task to complete and push its result.", .func = nativeAwait },
    .{ .name = "await-terminal", .stack_effect = "task --", .doc = "Wait for a task to reach a terminal status without pushing its result. Swallows cancellation, re-throws failure. Pairs with cancel-task to wait for cross-worker cleanup.", .func = nativeAwaitTerminal },
    .{ .name = "await-all", .stack_effect = "array -- array", .doc = "Wait for all tasks in array and return array of results.", .func = nativeAwaitAll },
    .{ .name = "sleep", .stack_effect = "duration --", .doc = "Suspend the current task for a duration.", .func = nativeSleep },
    .{ .name = "cancel-task", .stack_effect = "task --", .doc = "Cancel a task.", .func = nativeCancelTask },
    .{ .name = "with-timeout", .stack_effect = "quot duration -- value", .doc = "Run a quotation with a timeout duration. The main task and the timer task may run on different workers; cancellation crosses workers via the scheduler's cross-thread cancel path.", .func = nativeWithTimeout },
    .{ .name = "multiplexer-stats", .stack_effect = "-- hash", .doc = "Return a hash of I/O multiplexer statistics. Requires an active task-scope.", .func = nativeMultiplexerStats },
    .{ .name = "container-limits", .stack_effect = "-- hash", .doc = "Return a hash of detected container CPU and memory limits: cpu-count, cpu-source, cpu-raw, memory-cap, memory-source, memory-raw.", .func = nativeContainerLimits },
    .{ .name = "cancelled?", .stack_effect = "-- bool", .doc = "Push t if the current task has a pending cancellation, f otherwise.", .func = nativeCancelledQuery },
    .{ .name = "task-stack-peak", .stack_effect = "-- n", .doc = "Return the current task's peak native stack usage in bytes.", .func = nativeTaskStackPeak },
};

/// Allocate a Task and its Context on the heap, wire up the ucontext, and
/// return the task pointer. Caller is responsible for adding the task to a
/// scope and enqueueing it.
fn allocateTask(
    ctx: *Context,
    scheduler: *Scheduler,
    scope: *TaskScope,
    quotation: Quotation,
) !*Task {
    return allocateTaskWithEntry(ctx, scheduler, scope, quotation, &task_mod.taskEntryPoint);
}

fn allocateTaskWithEntry(
    ctx: *Context,
    scheduler: *Scheduler,
    scope: *TaskScope,
    quotation: Quotation,
    entry_fn: task_mod.CoroEntryFn,
) !*Task {
    const task = try ctx.allocator.create(Task);
    errdefer ctx.allocator.destroy(task);

    const task_ctx = try ctx.allocator.create(Context);
    errdefer ctx.allocator.destroy(task_ctx);
    task_ctx.* = try Context.initForTask(ctx.allocator, ctx, scheduler);

    task.* = .{
        .id = scheduler.nextId(),
        .name = null,
        .status = std.atomic.Value(task_mod.TaskStatus).init(.pending),
        .ctx = task_ctx,
        .scope = scope,
        .quotation = quotation,
    };

    try task_mod.initCoroContext(task, entry_fn, task_stack_size);
    errdefer task_mod.coroDestroy(task);

    const coro = task.coro.?;
    task_ctx.stack_high = @intFromPtr(coro.stack_base) + coro.stack_size;
    task_ctx.stack_limit = @intFromPtr(coro.stack_base) + task_stack_reserve;

    try scheduler.trackTask(task);
    return task;
}

/// task-scope ( quot -- )
///
/// Two code paths depending on whether a scheduler is already running.
///
/// 1. Top-level: called from the main context where `ctx.scheduler` is null.
/// Builds the worker pool, wraps the quotation in a scope task, runs the
/// scheduling loop to completion across all workers, then propagates any
/// child error.
///
/// 2. Nested: called from within a running task where `ctx.scheduler` is
/// non-null. Creates a TaskScope on the current task's native stack frame,
/// spawns a scope task, suspends the current task until the scope drains,
/// then propagates any child error.
///
/// In both cases the scope waits for every child to reach a terminal
/// status regardless of which worker each child ran on. Cross-worker child
/// completion is signalled via the `active_children` atomic counter; the
/// worker that drives the counter to zero wakes the scope's owner task via
/// its home worker's external queue.
///
/// When this returns, which happens either normally or by re-throwing a child's error, every
/// task spawned within the scope has reached a terminal status, which means each child's
/// registered cleanup handler has already run to completion. The guarantee covers tasks
/// spawned within the scope, not arbitrary task handles referenced inside it.
fn nativeTaskScope(ctx: *Context) anyerror!void {
    const quot = try helpers.popQuotation(ctx);

    // Case: nested
    if (ctx.scheduler) |scheduler| {
        var scope = TaskScope.init(ctx.allocator);
        defer scope.deinit();

        const scope_task = try allocateTask(ctx, scheduler, &scope, quot);
        scope.scope_task = scope_task;

        try scope.addChild(scope_task);
        try scheduler.enqueue(scope_task);

        const current = scheduler.current_task.?;
        scope.waiting_task = current;
        current.blocked_on_scope = &scope;
        scheduler.suspendCurrentTask();
        current.blocked_on_scope = null;

        try helpers.checkCancellation(ctx);

        if (scope.firstFailedChildError()) |err_obj| {
            ctx.thrown_error = try deepCopyErrorObject(err_obj, ctx.quotationAllocator(), ctx.quotationAllocator());
            return error.UserThrown;
        }

        return;
    }

    // Case: Top-level. Build the worker pool, run the primary worker on
    // this thread, and let background workers handle tasks dispatched
    // there by `spawn`'s least-loaded selection.
    const n: usize = blk: {
        if (is_freestanding) break :blk 1;
        if (ctx.worker_count > 0) break :blk ctx.worker_count;
        break :blk container_limits.detectCpus(ctx.trace.trace_container_detect).count;
    };

    var pool: WorkerPool = undefined;
    try pool.init(ctx.allocator, n);
    defer pool.deinit();
    // Stall detection is pool-wide: every worker reads the shared
    // threshold and timestamp so a busy background worker correctly
    // suppresses a false stall warning on an idle primary.
    pool.deadlock_threshold_ns = ctx.deadlock_detect_ns;

    const primary = pool.primary();

    ctx.scheduler = &primary.scheduler;
    ctx.worker_pool = &pool;
    ctx.active_scheduler.store(&primary.scheduler, .release);
    ctx.active_worker_pool.store(&pool, .release);
    defer {
        ctx.scheduler = null;
        ctx.worker_pool = null;
        ctx.active_scheduler.store(null, .release);
        ctx.active_worker_pool.store(null, .release);
    }

    var scope = TaskScope.init(ctx.allocator);
    defer scope.deinit();

    const scope_task = try allocateTask(ctx, &primary.scheduler, &scope, quot);
    scope.scope_task = scope_task;

    try scope.addChild(scope_task);
    try primary.scheduler.enqueue(scope_task);
    _ = primary.active_tasks.fetchAdd(1, .release);

    try pool.startBackgroundWorkers();
    primary.scheduler.runLoop();

    // Tell background workers to drain their queues and exit, then join.
    // Their runLoop now exits only after `signalShutdown` plus empty
    // local queues, so this is the cooperative shutdown path.
    for (pool.workers[1..]) |*w| w.signalShutdown();
    pool.join();

    if (ctx.benchmark) |bench| {
        // TODO(ripta): aggregate peak_task_stack_usage across all workers.
        if (primary.scheduler.peak_task_stack_usage > bench.peak_task_stack_usage) {
            bench.peak_task_stack_usage = primary.scheduler.peak_task_stack_usage;
        }
    }

    if (scope.firstFailedChildError()) |err_obj| {
        ctx.thrown_error = try deepCopyErrorObject(err_obj, ctx.quotationAllocator(), ctx.quotationAllocator());
        return error.UserThrown;
    }
}

/// spawn ( quot -- task )
///
/// Must be called within a `task-scope`. Picks the worker with the fewest
/// active tasks, allocates the new task on its scheduler, adds it to the
/// caller's scope, and dispatches it via local or cross-thread enqueue.
/// The spawned task is pinned to its assigned worker for its entire
/// lifetime; it does not migrate between workers.
fn nativeSpawn(ctx: *Context) anyerror!void {
    const quot = try helpers.popQuotation(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "spawn must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "spawn must be called from a running task";
        return error.InvalidState;
    };

    const scope = current.scope;
    const task = try spawnTaskOnPool(ctx, scheduler, scope, quot);
    try ctx.stack.push(.{ .task = task });
}

/// spawn-named ( quot name -- task )
///
/// Like `spawn`, but assigns a string name to the task. The name is stored
/// on the Task struct and displayed in task value representations.
fn nativeSpawnNamed(ctx: *Context) anyerror!void {
    const name = try helpers.popString(ctx);
    const quot = try helpers.popQuotation(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "spawn-named must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "spawn-named must be called from a running task";
        return error.InvalidState;
    };

    const scope = current.scope;
    const task = try spawnTaskOnPool(ctx, scheduler, scope, quot);
    task.name = name;
    try ctx.stack.push(.{ .task = task });
}

/// Allocate a child task on the least-loaded worker, attach it to the
/// given scope, and either enqueue locally or push to the target worker's
/// cross-thread external queue. The active-tasks counter on the target is
/// incremented before allocation so racing spawners observe the new load
/// even if allocation is still in progress. Falls back to the legacy
/// single-scheduler enqueue when there is no `worker_pool` (standalone
/// schedulers in tests).
fn spawnTaskOnPool(ctx: *Context, scheduler: *Scheduler, scope: *TaskScope, quot: Quotation) !*Task {
    if (ctx.worker_pool) |pool| {
        const target = pool.pickLeastLoaded();
        _ = target.active_tasks.fetchAdd(1, .release);
        errdefer _ = target.active_tasks.fetchSub(1, .release);

        const task = try allocateTask(ctx, &target.scheduler, scope, quot);
        try scope.addChild(task);
        if (&target.scheduler == scheduler) {
            try target.scheduler.enqueue(task);
        } else {
            try target.enqueueExternal(task);
        }
        return task;
    }

    // Legacy single-scheduler path (used by standalone schedulers in tests).
    const task = try allocateTask(ctx, scheduler, scope, quot);
    try scope.addChild(task);
    try scheduler.enqueue(task);
    return task;
}

/// task-self ( -- task )
///
/// Push the current task handle onto the stack. Must be called from within
/// a running task inside a `task-scope`.
fn nativeTaskSelf(ctx: *Context) anyerror!void {
    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "task-self must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "task-self must be called from a running task";
        return error.InvalidState;
    };

    try ctx.stack.push(.{ .task = current });
}

/// yield ( -- )
///
/// Voluntarily yields the current task, allowing other tasks to run.
fn nativeYield(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "yield cannot be called during module loading";
        return error.InvalidState;
    }

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "yield must be called within a task-scope";
        return error.InvalidState;
    };

    scheduler.yieldCurrentTask();

    try helpers.checkCancellation(ctx);
}

/// sleep ( duration -- )
///
/// Suspend the current task for the given duration. Must be called within a
/// `task-scope`. Rejects negative values.
fn nativeSleep(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "sleep cannot be called during module loading";
        return error.InvalidState;
    }

    const dur = try helpers.popDuration(ctx);

    if (dur.ns < 0) {
        ctx.pending_error_message = "sleep duration must be non-negative";
        return error.InvalidArgument;
    }

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "sleep must be called within a task-scope";
        return error.InvalidState;
    };

    scheduler.sleepCurrentTask(dur.ns);

    try helpers.checkCancellation(ctx);
}

/// with-timeout ( quot duration -- value )
///
/// Run a quotation with a timeout. Creates an isolated nested scope with two
/// tasks: the main task running the user's quotation and a timer task that
/// sleeps for the given duration then triggers a timeout failure. Each
/// task is assigned to a worker by the usual least-loaded rule, so the
/// main task and the timer task may run on different workers.
///
/// If the main task completes first, its result is pushed and the timer is cancelled.
/// If the timer fires first, the main task is cancelled and a `timeout` error is thrown.
/// Cross-worker cancellation routes through the scheduler's cross-thread
/// cancel queue with home-worker cleanup, so neither outcome depends on
/// the two tasks sharing a worker.
fn nativeWithTimeout(ctx: *Context) anyerror!void {
    const dur = try helpers.popDuration(ctx);
    const quot = try helpers.popQuotation(ctx);

    if (dur.ns < 0) {
        ctx.pending_error_message = "timeout duration must be non-negative";
        return error.InvalidArgument;
    }

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "with-timeout must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "with-timeout must be called from a running task";
        return error.InvalidState;
    };

    // NOTE(ripta): Nest a hidden scope so the timer's sibling cancellation doesn't affect
    //              the caller's other tasks. Spawn the main task with the user's quotation.
    var scope = TaskScope.init(ctx.allocator);
    defer scope.deinit();

    // NOTE(ripta): Do NOT set the task as the scope task so that sibling cancellation from the timer can reach it.
    const main_task = try allocateTask(ctx, scheduler, &scope, quot);
    try scope.addChild(main_task);
    try scheduler.enqueue(main_task);

    const alloc = ctx.arena.allocator();
    const timer_instrs = try alloc.alloc(Instruction, 2);
    timer_instrs[0] = .{ .op = .{ .push_literal = dur.val }, .line = 0 };
    timer_instrs[1] = .{ .op = .{ .call_word = "sleep" }, .line = 0 };
    const timer_quot: Quotation = .{ .instructions = timer_instrs };

    // spawn the timer task with a custom entry point that marks as failed with a timeout error after the sleep completes
    const timer_task = try allocateTaskWithEntry(ctx, scheduler, &scope, timer_quot, &timerTaskEntryPoint);
    try scope.addChild(timer_task);
    try scheduler.enqueue(timer_task);

    // suspend the current task until the scope drains
    scope.waiting_task = current;
    current.blocked_on_scope = &scope;
    scheduler.suspendCurrentTask();
    current.blocked_on_scope = null;

    try helpers.checkCancellation(ctx);

    // inspect main task status to determine outcome
    switch (main_task.getStatus()) {
        .completed => {
            if (main_task.result) |result| {
                const copied = try deepCopyValue(result, ctx.arena.allocator());
                try ctx.stack.push(copied);
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        .failed => {
            if (main_task.error_obj) |err_obj| {
                ctx.thrown_error = try deepCopyErrorObject(err_obj, ctx.quotationAllocator(), ctx.quotationAllocator());
            } else {
                ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                    .error_type = "task-error",
                    .message = "task failed without error details",
                });
            }
            return error.UserThrown;
        },
        .cancelled => {
            ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                .error_type = "timeout",
                .message = "operation timed out",
            });
            return error.UserThrown;
        },
        .pending, .running => unreachable,
    }
}

/// Entry function for the timer task coroutine used by `with-timeout`.
/// Runs the timer quotation (which sleeps), then marks the task as failed
/// with a timeout error. This failure triggers sibling cancellation of the
/// main task in the isolated scope.
fn timerTaskEntryPoint(co: task_mod.CoroPtr) callconv(.c) void {
    const task: *Task = @ptrCast(@alignCast(task_mod.getCoroUserData(co)));

    task.ctx.executeQuotation(task.quotation) catch {
        if (task.getCancellationPhase() != .none) {
            task.setStatus(.cancelled);
        } else {
            task.setStatus(.failed);
        }
        if (task.ctx.thrown_error) |thrown| {
            task.error_obj = thrown;
            task.ctx.thrown_error = null;
        }
        return;
    };

    // Sleep completed normally, meaning the timeout fired before the main task
    // finished. Mark the timer as failed with a timeout error to trigger sibling
    // cancellation of the main task.
    task.setStatus(.failed);
    task.error_obj = value_mod.boxErrorObject(task.ctx.quotationAllocator(), .{
        .error_type = "timeout",
        .message = "operation timed out",
    }) catch null;
}

/// cancel-task ( task -- )
///
/// Cancel a task. Sets the cancelled flag so the scheduler will skip or
/// abort it on the next scheduling pass. Must be called within a `task-scope`.
fn nativeCancelTask(ctx: *Context) anyerror!void {
    const task = try helpers.popTask(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "cancel-task must be called within a task-scope";
        return error.InvalidState;
    };

    scheduler.cancelTask(task);
}

/// await ( task -- value )
///
/// Wait for a task to complete and push its result. If the task has no result,
/// pushes `f`. If the task failed, re-throws its error. If the task is still
/// running, suspends the caller until the task finishes.
fn nativeAwait(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "await cannot be called during module loading";
        return error.InvalidState;
    }

    const task = try helpers.popTask(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "await must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "await must be called from a running task";
        return error.InvalidState;
    };

    switch (task.getStatus()) {
        .pending, .running => {
            task.awaiting_task = current;
            scheduler.suspendCurrentTask();
        },
        .completed, .failed, .cancelled => {},
    }

    try helpers.checkCancellation(ctx);

    return handleAwaitResult(ctx, task);
}

/// await-terminal ( task -- )
///
/// Wait for a task to reach a terminal status (completed, failed, or
/// cancelled) without pushing the task's result. On a completed task it
/// returns normally; on a failed task it re-throws the task's error, matching
/// `await`; on a cancelled task it returns normally and does not throw
/// `task-cancelled:`. The target may live on a different worker, in which case
/// the caller blocks until the target reaches terminal status on whichever
/// worker ran it.
///
/// This is the building block for cancel-and-wait, where the caller cancels a
/// task and then waits for the task's registered cleanup handler to finish:
///
///     dup cancel-task await-terminal
fn nativeAwaitTerminal(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "await-terminal cannot be called during module loading";
        return error.InvalidState;
    }

    const task = try helpers.popTask(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "await-terminal must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "await-terminal must be called from a running task";
        return error.InvalidState;
    };

    switch (task.getStatus()) {
        .pending, .running => {
            task.awaiting_task = current;
            scheduler.suspendCurrentTask();
        },
        .completed, .failed, .cancelled => {},
    }

    try helpers.checkCancellation(ctx);

    switch (task.getStatus()) {
        .completed, .cancelled => {},
        .failed => {
            if (task.error_obj) |err_obj| {
                ctx.thrown_error = try deepCopyErrorObject(err_obj, ctx.quotationAllocator(), ctx.quotationAllocator());
            } else {
                ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                    .error_type = "task-error",
                    .message = "task failed without error details",
                });
            }
            return error.UserThrown;
        },
        .pending, .running => unreachable,
    }
}

/// await-all ( array -- array )
///
/// Wait for all tasks in the array to complete and return an array of results
/// in the same order. If any task failed or was cancelled, re-throw the first
/// error, in array order, after all tasks have finished.
fn nativeAwaitAll(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "await-all cannot be called during module loading";
        return error.InvalidState;
    }

    const val = try ctx.stack.pop();
    const tasks = switch (val) {
        .array => |items| items,
        else => {
            helpers.setTypeMismatchError(ctx, "array", val);
            return error.TypeMismatch;
        },
    };

    for (tasks) |item| {
        switch (item) {
            .task => {},
            else => {
                helpers.setTypeMismatchError(ctx, "task", item);
                return error.TypeMismatch;
            },
        }
    }

    if (tasks.len == 0) {
        try ctx.stack.push(.{ .array = &.{} });
        return;
    }

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "await-all must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "await-all must be called from a running task";
        return error.InvalidState;
    };

    // Wait for each task to finish. Suspend the current task whenever a task
    // is still pending or running; the scheduler's handleTaskDone will
    // reënqueue when the awaited task completes.
    for (tasks) |item| {
        const task = item.task;
        switch (task.getStatus()) {
            .pending, .running => {
                task.awaiting_task = current;
                scheduler.suspendCurrentTask();
            },
            .completed, .failed, .cancelled => {},
        }
    }

    try helpers.checkCancellation(ctx);

    for (tasks) |item| {
        const task = item.task;
        switch (task.getStatus()) {
            .failed => {
                if (task.error_obj) |err_obj| {
                    ctx.thrown_error = try deepCopyErrorObject(err_obj, ctx.quotationAllocator(), ctx.quotationAllocator());
                } else {
                    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                        .error_type = "task-error",
                        .message = "task failed without error details",
                    });
                }
                return error.UserThrown;
            },
            .cancelled => {
                ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                    .error_type = "task-cancelled",
                    .message = "awaited task was cancelled",
                });
                return error.UserThrown;
            },
            .completed => {},
            .pending, .running => unreachable,
        }
    }

    const alloc = ctx.arena.allocator();
    const results = try alloc.alloc(Value, tasks.len);
    for (tasks, 0..) |item, i| {
        const task = item.task;
        if (task.result) |result| {
            // XXX(ripta): Potentially expensive deep copy of each result. We have to do this
            //             before checking for errors/cancellations in order to preserve the
            //             correct error precedence. Unsure if there's a better way.
            results[i] = try deepCopyValue(result, alloc);
        } else {
            results[i] = .{ .boolean = false };
        }
    }

    try ctx.stack.push(.{ .array = results });
}

/// Extract the result from a finished task: deep-copy completed results into the
/// caller's allocator, re-throw failures, and report cancellations.
fn handleAwaitResult(ctx: *Context, task: *Task) anyerror!void {
    switch (task.getStatus()) {
        .completed => {
            if (task.result) |result| {
                const copied = try deepCopyValue(result, ctx.arena.allocator());
                try ctx.stack.push(copied);
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        .failed => {
            if (task.error_obj) |err_obj| {
                ctx.thrown_error = try deepCopyErrorObject(err_obj, ctx.quotationAllocator(), ctx.quotationAllocator());
            } else {
                ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                    .error_type = "task-error",
                    .message = "task failed without error details",
                });
            }
            return error.UserThrown;
        },
        .cancelled => {
            ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                .error_type = "task-cancelled",
                .message = "awaited task was cancelled",
            });
            return error.UserThrown;
        },
        .pending, .running => unreachable,
    }
}

/// Deep-copy a Value into a destination allocator. Recursive for compound types.
/// Reference types (stream, parameter, module, marker, struct_type, benchmark_report,
/// task) are returned as-is since they are not owned by the task arena.
const DeepCopyError = Allocator.Error;

pub fn deepCopyValue(val: Value, alloc: Allocator) DeepCopyError!Value {
    return switch (val) {
        .fixnum, .float, .boolean, .unit => val,
        .bignum => |b| blk: {
            const cloned = b.cloneWithDifferentAllocator(alloc) catch return error.OutOfMemory;
            break :blk .{ .bignum = try value_mod.boxBigInt(alloc, cloned) };
        },

        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .symbol => |s| .{ .symbol = try alloc.dupe(u8, s) },

        .array => |items| blk: {
            const new_items = try alloc.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                new_items[i] = try deepCopyValue(item, alloc);
            }
            break :blk .{ .array = new_items };
        },

        .quotation => |quot| .{ .quotation = try deepCopyQuotation(quot, alloc) },

        .hash => |h| blk: {
            const new_h = try alloc.create(value_mod.HashTable);
            new_h.* = .{};
            try new_h.ensureTotalCapacity(alloc, @intCast(h.count()));
            var iter = h.iterator();
            while (iter.next()) |entry| {
                const key = try alloc.dupe(u8, entry.key_ptr.*);
                const v = try deepCopyValue(entry.value_ptr.*, alloc);
                new_h.putAssumeCapacityNoClobber(key, v);
            }
            break :blk .{ .hash = new_h };
        },

        .vector => |v| blk: {
            const new_v = try value_mod.Vector.create(alloc);
            try new_v.list.ensureTotalCapacity(alloc, v.list.items.len);
            for (v.list.items) |item| {
                new_v.list.appendAssumeCapacity(try deepCopyValue(item, alloc));
            }
            break :blk .{ .vector = new_v };
        },

        .byte_array => |b| blk: {
            const new_b = try value_mod.ByteArray.create(alloc);
            const bytes = b.slice();
            try new_b.ensureTotalCapacity(alloc, bytes.len);
            new_b.appendSliceAssumeCapacity(bytes);
            break :blk .{ .byte_array = new_b };
        },

        .set => |s| blk: {
            const new_s = try alloc.create(value_mod.Set);
            new_s.* = .{};
            try new_s.ensureTotalCapacity(alloc, @intCast(s.count()));
            for (s.keys()) |key| {
                new_s.putAssumeCapacity(try deepCopyValue(key, alloc), {});
            }
            break :blk .{ .set = new_s };
        },

        .mutable_map => |m| blk: {
            const new_m = try value_mod.MutableMap.create(alloc);
            try new_m.map.ensureTotalCapacity(alloc, @intCast(m.map.count()));
            var iter = m.map.iterator();
            while (iter.next()) |entry| {
                const key = try alloc.dupe(u8, entry.key_ptr.*);
                const v = try deepCopyValue(entry.value_ptr.*, alloc);
                new_m.map.putAssumeCapacityNoClobber(key, v);
            }
            break :blk .{ .mutable_map = new_m };
        },

        .struct_instance => |si| blk: {
            const new_si = try alloc.create(value_mod.StructInstance);
            const new_fields = try alloc.alloc(Value, si.fields.len);
            for (si.fields, 0..) |field, i| {
                new_fields[i] = try deepCopyValue(field, alloc);
            }
            new_si.* = .{
                .struct_type = si.struct_type,
                .fields = new_fields,
            };
            break :blk .{ .struct_instance = new_si };
        },

        .tagged => |t| blk: {
            const new_inner = try alloc.create(Value);
            new_inner.* = try deepCopyValue(t.inner.*, alloc);
            break :blk .{ .tagged = .{ .tag = t.tag, .inner = new_inner } };
        },

        .template => |segments| blk: {
            const new_segs = try alloc.alloc(value_mod.TemplateSegment, segments.len);
            for (segments, 0..) |seg, i| {
                new_segs[i] = try deepCopyTemplateSegment(seg, alloc);
            }
            break :blk .{ .template = new_segs };
        },

        .stack_effect => |effect| .{ .stack_effect = try deepCopyStackEffect(effect, alloc) },
        .error_value => |err| .{ .error_value = try deepCopyErrorObject(err, alloc, alloc) },

        .doc_string => |s| .{ .doc_string = try alloc.dupe(u8, s) },

        // NOTE(ripta): Reference types not owned by the task arena so it's safe to share without copying
        .stream, .parameter, .module, .marker, .struct_type, .benchmark_report, .task, .channel, .iterator, .resource, .type_val, .type_descriptor, .protocol_descriptor, .constraint_combinator, .sandbox_spec => val,
    };
}

fn deepCopyQuotation(quot: value_mod.Quotation, alloc: Allocator) DeepCopyError!value_mod.Quotation {
    const new_instrs = try alloc.alloc(Instruction, quot.instructions.len);
    for (quot.instructions, 0..) |instr, i| {
        new_instrs[i] = .{
            .op = switch (instr.op) {
                .push_literal => |v| .{ .push_literal = try deepCopyValue(v, alloc) },
                .call_word => |name| .{ .call_word = try alloc.dupe(u8, name) },
                .call_word_direct => |slot| .{ .call_word_direct = slot },
            },
            .line = instr.line,
        };
    }

    return .{
        .instructions = new_instrs,
        .effect = quot.effect,
    };
}

fn deepCopyStackEffect(effect: StackEffect, alloc: Allocator) DeepCopyError!StackEffect {
    return .{
        .inputs = try deepCopyStackEffectParams(effect.inputs, alloc),
        .outputs = try deepCopyStackEffectParams(effect.outputs, alloc),
    };
}

fn deepCopyStackEffectParams(params: []const StackEffectParam, alloc: Allocator) DeepCopyError![]const StackEffectParam {
    const new_params = try alloc.alloc(StackEffectParam, params.len);
    for (params, 0..) |param, i| {
        const new_name = try alloc.dupe(u8, param.name);
        if (param.quotation_effect) |qe| {
            const new_qe = try alloc.create(StackEffect);
            new_qe.* = try deepCopyStackEffect(qe.*, alloc);
            new_params[i] = .{ .name = new_name, .quotation_effect = new_qe };
        } else {
            new_params[i] = .{ .name = new_name };
        }
    }
    return new_params;
}

fn deepCopyTemplateSegment(seg: value_mod.TemplateSegment, alloc: Allocator) DeepCopyError!value_mod.TemplateSegment {
    return switch (seg) {
        .literal => |text| .{ .literal = try alloc.dupe(u8, text) },
        .identity => |spec| .{ .identity = spec },
        .named => |n| .{ .named = .{ .name = try alloc.dupe(u8, n.name), .spec = n.spec } },
        .indexed => |idx| .{ .indexed = idx },
    };
}

fn deepCopyErrorObjectValue(err: ErrorObject, alloc: Allocator) DeepCopyError!ErrorObject {
    const new_data: ?*const Value = if (err.data) |data| blk: {
        const new_d = try alloc.create(Value);
        new_d.* = try deepCopyValue(data.*, alloc);
        break :blk new_d;
    } else null;

    const new_trace: ?[]const value_mod.StackFrame = if (err.stack_trace) |trace| blk: {
        const new_frames = try alloc.alloc(value_mod.StackFrame, trace.len);
        for (trace, 0..) |frame, i| {
            new_frames[i] = .{
                .word_name = try alloc.dupe(u8, frame.word_name),
                .source = try alloc.dupe(u8, frame.source),
                .line = frame.line,
            };
        }
        break :blk new_frames;
    } else null;

    return .{
        .error_type = try alloc.dupe(u8, err.error_type),
        .message = try alloc.dupe(u8, err.message),
        .data = new_data,
        .stack_trace = new_trace,
    };
}

/// Deep-copy an `ErrorObject` and box it. The box is allocated on
/// `box_alloc` (typically GPA); the inner strings, data, and stack-trace
/// frames are allocated on `inner_alloc` (typically the per-context arena).
fn deepCopyErrorObject(err: *const ErrorObject, box_alloc: Allocator, inner_alloc: Allocator) DeepCopyError!*ErrorObject {
    const inner = try deepCopyErrorObjectValue(err.*, inner_alloc);
    const ptr = try box_alloc.create(ErrorObject);
    ptr.* = inner;
    return ptr;
}

/// cancelled? ( -- bool )
///
/// Push `t` if the current task has a pending cancellation, `f` otherwise.
/// Returns `f` outside a task-scope. Useful for compute-bound loops that
/// need to poll for cancellation.
fn nativeCancelledQuery(ctx: *Context) anyerror!void {
    const cancelled = if (ctx.scheduler) |sched|
        if (sched.current_task) |task| task.getCancellationPhase() != .none else false
    else
        false;
    try ctx.stack.push(.{ .boolean = cancelled });
}

fn nativeTaskStackPeak(ctx: *Context) anyerror!void {
    const sched = ctx.scheduler orelse {
        ctx.pending_error_message = "task-stack-peak requires a task context";
        return error.InvalidState;
    };
    const task = sched.current_task orelse {
        ctx.pending_error_message = "task-stack-peak requires a task context";
        return error.InvalidState;
    };
    try ctx.stack.push(.{ .fixnum = @intCast(task.peak_stack_usage) });
}

/// fake-clock ( -- )
///
/// Switch the scheduler's clock to fake mode, starting at time 0.
/// Must be called within a task-scope.
fn nativeFakeClock(ctx: *Context) anyerror!void {
    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "fake-clock requires task-scope";
        return error.InvalidState;
    };
    scheduler.clock = .{ .fake = 0 };
}

/// advance-clock ( duration -- )
///
/// Advance the fake clock by the given duration. Errors if the clock
/// is not in fake mode.
fn nativeAdvanceClock(ctx: *Context) anyerror!void {
    const dur = try helpers.popDuration(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "advance-clock requires task-scope";
        return error.InvalidState;
    };

    switch (scheduler.clock) {
        .fake => scheduler.advanceClock(dur.ns),
        .real => {
            ctx.pending_error_message = "clock is not in fake mode";
            return error.InvalidState;
        },
    }
}

/// multiplexer-stats ( -- hash )
fn nativeMultiplexerStats(ctx: *Context) anyerror!void {
    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "multiplexer-stats requires an active task-scope";
        return error.InvalidState;
    };

    const alloc = ctx.quotationAllocator();
    const hash = alloc.create(value_mod.HashTable) catch return error.OutOfMemory;
    hash.* = value_mod.HashTable{};

    hash.put(alloc, try alloc.dupe(u8, "io-waiting"), .{
        .fixnum = @intCast(scheduler.io_wait_map.count()),
    }) catch return error.OutOfMemory;
    hash.put(alloc, try alloc.dupe(u8, "sleeping"), .{
        .fixnum = @intCast(scheduler.sleep_queue.count()),
    }) catch return error.OutOfMemory;
    hash.put(alloc, try alloc.dupe(u8, "run-queue"), .{
        .fixnum = @intCast(scheduler.run_queue.items.len),
    }) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .hash = hash });
}

fn cpuSourceSymbol(s: container_limits.CpuSource) []const u8 {
    return switch (s) {
        .cgroup_v2 => "cgroup-v2",
        .cgroup_v1 => "cgroup-v1",
        .affinity => "affinity",
        .fallback => "fallback",
    };
}

fn memSourceSymbol(s: container_limits.MemorySource) []const u8 {
    return switch (s) {
        .cgroup_v2 => "cgroup-v2",
        .cgroup_v1 => "cgroup-v1",
        .fallback => "fallback",
    };
}

/// container-limits ( -- hash )
fn nativeContainerLimits(ctx: *Context) anyerror!void {
    const trace_enabled = ctx.trace.trace_container_detect;
    const cpu = container_limits.detectCpus(trace_enabled);
    const mem = container_limits.detectMemory(trace_enabled);

    const alloc = ctx.quotationAllocator();
    const hash = alloc.create(value_mod.HashTable) catch return error.OutOfMemory;
    hash.* = value_mod.HashTable{};

    hash.put(alloc, try alloc.dupe(u8, "cpu-count"), .{ .fixnum = @intCast(cpu.count) }) catch return error.OutOfMemory;
    hash.put(alloc, try alloc.dupe(u8, "cpu-source"), .{ .symbol = cpuSourceSymbol(cpu.source) }) catch return error.OutOfMemory;
    const cpu_raw: Value = if (cpu.raw_quota != null and cpu.raw_period != null) blk: {
        const inner = alloc.create(value_mod.HashTable) catch return error.OutOfMemory;
        inner.* = value_mod.HashTable{};
        inner.put(alloc, try alloc.dupe(u8, "quota"), .{ .fixnum = cpu.raw_quota.? }) catch return error.OutOfMemory;
        inner.put(alloc, try alloc.dupe(u8, "period"), .{ .fixnum = cpu.raw_period.? }) catch return error.OutOfMemory;
        break :blk .{ .hash = inner };
    } else .{ .unit = {} };
    hash.put(alloc, try alloc.dupe(u8, "cpu-raw"), cpu_raw) catch return error.OutOfMemory;

    hash.put(alloc, try alloc.dupe(u8, "memory-cap"), .{ .fixnum = @intCast(mem.cap) }) catch return error.OutOfMemory;
    hash.put(alloc, try alloc.dupe(u8, "memory-source"), .{ .symbol = memSourceSymbol(mem.source) }) catch return error.OutOfMemory;
    const mem_raw: Value = if (mem.raw) |r| .{ .fixnum = @intCast(r) } else .{ .unit = {} };
    hash.put(alloc, try alloc.dupe(u8, "memory-raw"), mem_raw) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .hash = hash });
}

test "handleAwaitResult rethrows borrowed buffer escape" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var scope = TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var err_obj = value_mod.ErrorObject{
        .error_type = "borrowed-buffer-escape",
        .message = "borrowed buffer cannot cross task boundary via task result; call >byte-array first",
    };
    var task = Task{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(task_mod.TaskStatus).init(.failed),
        .error_obj = &err_obj,
        .ctx = &ctx,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };

    try std.testing.expectError(error.UserThrown, handleAwaitResult(&ctx, &task));
    try std.testing.expect(ctx.thrown_error != null);
    try std.testing.expectEqualStrings("borrowed-buffer-escape", ctx.thrown_error.?.error_type);
}

test "await-all propagates borrowed buffer escape from failed child" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var scheduler = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    ctx.scheduler = &scheduler;

    var parent_scope = TaskScope.init(std.testing.allocator);
    defer parent_scope.deinit();
    var child_scope = TaskScope.init(std.testing.allocator);
    defer child_scope.deinit();

    var parent_task = Task{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(task_mod.TaskStatus).init(.running),
        .ctx = &ctx,
        .scope = &parent_scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    scheduler.current_task = &parent_task;

    var err_obj = value_mod.ErrorObject{
        .error_type = "borrowed-buffer-escape",
        .message = "borrowed buffer cannot cross task boundary via task result; call >byte-array first",
    };
    var failed_child = Task{
        .id = 2,
        .name = null,
        .status = std.atomic.Value(task_mod.TaskStatus).init(.failed),
        .error_obj = &err_obj,
        .ctx = &ctx,
        .scope = &child_scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    var completed_child = Task{
        .id = 3,
        .name = null,
        .status = std.atomic.Value(task_mod.TaskStatus).init(.completed),
        .result = .{ .fixnum = 42 },
        .ctx = &ctx,
        .scope = &child_scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };

    var task_values = [_]Value{
        .{ .task = &failed_child },
        .{ .task = &completed_child },
    };
    try ctx.stack.push(.{ .array = task_values[0..] });

    try std.testing.expectError(error.UserThrown, nativeAwaitAll(&ctx));
    try std.testing.expect(ctx.thrown_error != null);
    try std.testing.expectEqualStrings("borrowed-buffer-escape", ctx.thrown_error.?.error_type);
}
