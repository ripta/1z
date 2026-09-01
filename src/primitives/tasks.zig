const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Callable = @import("../callable.zig").Callable;
const Context = @import("../context.zig").Context;
const CapturedScope = @import("../context.zig").CapturedScope;

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
const container_backing = @import("../container_backing.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const ErrorObject = value_mod.ErrorObject;
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
    .{ .name = "spawn", .stack_effect = "quot -- task", .doc = "Spawn a new task from a quotation. The task is pinned to the worker with the fewest active tasks at spawn time for its entire lifetime. The returned handle is valid only within the task-scope that spawned it. After that scope exits the handle must not be used, because the runtime may have destroyed the task.", .func = nativeSpawn },
    .{ .name = "spawn-detached", .stack_effect = "quot --", .doc = "Spawn a fire-and-forget task reaped at its own completion, not at scope exit, so a long-running scope stays bounded in memory. The task is isolated from sibling cancellation and pushes no handle. The scope still waits for in-flight detached tasks before returning.", .func = nativeSpawnDetached },
    .{ .name = "spawn-named", .stack_effect = "quot name -- task", .doc = "Spawn a named task from a quotation.", .func = nativeSpawnNamed },
    .{ .name = "task-self", .stack_effect = "-- task", .doc = "Push the current task handle.", .func = nativeTaskSelf },
    .{ .name = "yield", .stack_effect = "--", .doc = "Voluntarily yield the current task.", .func = nativeYield },
    .{ .name = "await", .stack_effect = "task -- value", .doc = "Wait for a task to complete and push its result. The handle must belong to an open task-scope; it is no longer valid after its scope exits.", .func = nativeAwait },
    .{ .name = "await-terminal", .stack_effect = "task --", .doc = "Wait for a task to reach a terminal status without pushing its result. Swallows cancellation, re-throws failure. Pairs with cancel-task to wait for cross-worker cleanup. The handle must belong to an open task-scope; it is no longer valid after its scope exits.", .func = nativeAwaitTerminal },
    .{ .name = "await-all", .stack_effect = "array -- array", .doc = "Wait for all tasks in array and return array of results. Each handle must belong to an open task-scope; handles are no longer valid after their scope exits.", .func = nativeAwaitAll },
    .{ .name = "sleep", .stack_effect = "duration --", .doc = "Suspend the current task for a duration.", .func = nativeSleep },
    .{ .name = "cancel-task", .stack_effect = "task --", .doc = "Cancel a task.", .func = nativeCancelTask },
    .{ .name = "with-timeout", .stack_effect = "quot duration -- value", .doc = "Run a quotation with a timeout duration. Returns the quotation's value if it finishes first, or throws a timeout error if the duration elapses first.", .func = nativeWithTimeout },
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
    callable: Callable,
    captured_scope: ?*const CapturedScope,
) !*Task {
    return allocateTaskWithEntry(ctx, scheduler, scope, callable, captured_scope, &task_mod.taskEntryPoint);
}

/// `callable` carries the owning reference behind the body, transferred onto
/// the task only on success (released at reap); on failure the caller still
/// owns it.
fn allocateTaskWithEntry(
    ctx: *Context,
    scheduler: *Scheduler,
    scope: *TaskScope,
    callable: Callable,
    captured_scope: ?*const CapturedScope,
    entry_fn: task_mod.CoroEntryFn,
) !*Task {
    const task = try ctx.allocator.create(Task);
    errdefer ctx.allocator.destroy(task);

    const task_ctx = try ctx.allocator.create(Context);
    errdefer ctx.allocator.destroy(task_ctx);
    task_ctx.* = try Context.initForTask(ctx.allocator, ctx, scheduler);

    // A spawned closure carries its creation-site scope on the value. Stamp it into the child task
    // context here, before the child can be enqueued and run, so its body resolves bare words at its
    // creation site. The copy is child-owned and freed when the task is reaped.
    //
    // A body the closure owns takes nothing from the stamp: it is refused there, and the task holds
    // the closure across the run so body entry reads the scope off the value.
    if (captured_scope) |cs| try task_ctx.stampCapturedScopeForExecution(callable.quot.instructions, cs, callable.ownerClosure());

    task.* = .{
        .id = scheduler.nextId(),
        .name = null,
        .status = std.atomic.Value(task_mod.TaskStatus).init(.pending),
        .ctx = task_ctx,
        .scope = scope,
        .callable = callable,
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
/// Top-level (`ctx.scheduler == null`) builds the worker pool and runs the scheduling loop to
/// completion; nested creates a `TaskScope` on the current task's frame and suspends until it
/// drains. Either way, cross-worker completion signals through the `active_children` counter,
/// which wakes the scope's owner via its home worker's external queue.
fn nativeTaskScope(ctx: *Context) anyerror!void {
    // Pop without stamping this context: the scope body runs in the scope task, so its carried
    // scope is stamped into that child, not the caller. Stamping the caller would leak one copy per
    // call in a long-lived context that runs `task-scope` in a loop.
    const popped = try helpers.popCallableWithScope(ctx);
    // The popped reference transfers onto the scope task, which releases it at
    // reap; until that allocation succeeds this caller still owns it.
    var owner_transferred = false;
    errdefer if (!owner_transferred) popped.release();

    // Case: nested
    if (ctx.scheduler) |scheduler| {
        var scope = TaskScope.init(ctx.allocator);
        defer scope.deinit();
        defer scheduler.reapScopeAtExit(&scope);

        const scope_task = try allocateTask(ctx, scheduler, &scope, popped.callable, popped.scope);
        owner_transferred = true;

        try scope.addChild(scope_task);
        try scheduler.enqueue(scope_task);
        // Count the scope task on its home worker so the decrement in
        // `handleTaskDone` when it completes does not underflow `active_tasks`.
        scheduler.notifyOwnerTaskSpawned();

        const current = scheduler.current_task.?;
        scope.waiting_task = current;
        current.blocked_on_scope = &scope;
        scheduler.suspendCurrentTask();
        current.blocked_on_scope = null;

        try helpers.checkCancellation(ctx);

        if (scope.firstFailedChildError()) |err_obj| {
            try adoptChildError(ctx, err_obj);
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
    // Disarm the sampler hook before `pool.deinit` runs.
    //
    // Scheduler teardown itself allocates, so a still-armed hook would sample workers
    // mid-destruction. Background workers are joined by the explicit join before these defers
    // run, so no other thread can still be inside the hook when it is cleared.
    defer if (ctx.mem_limit) |ml| {
        ml.sample_hook = null;
        ml.sample_owner = null;
    };
    // Stall detection is pool-wide: every worker reads the shared
    // threshold and timestamp so a busy background worker correctly
    // suppresses a false stall warning on an idle primary.
    pool.deadlock_threshold_ns = ctx.deadlock_detect_ns;
    pool.report_stall_verdict = ctx.report_stall_verdict;

    // Point every worker's drain at the main context's buffer and give it a
    // worker id for the drained labels. Each worker folds its collection into
    // this sink at teardown, so task-body samples reach the exported profile.
    if (ctx.profile) |sink| {
        for (pool.workers) |*w| {
            w.scheduler.profile_sink = sink;
            w.scheduler.worker_id = w.id;
        }
    }

    // Arm the periodic sampler when either axis is enabled. A tick with no
    // axis is a no-op: `sampler_on` is false and the pool keeps sampling off.
    const sampler_on = ctx.trace.sample_tasks or ctx.trace.sample_memory;
    if (sampler_on) {
        const interval = ctx.trace.sampling_tick_ns orelse (1000 * std.time.ns_per_ms);
        const now = scheduler_mod.monotonicNowNs();
        pool.sample_tasks = ctx.trace.sample_tasks;
        pool.sample_memory = ctx.trace.sample_memory;
        pool.sampling_tick_ns = interval;
        pool.mem_limit = ctx.mem_limit;
        pool.sampler_started_ns = now;
        pool.next_sample_ns.store(now + interval, .release);

        // Fire samples from the allocation path too: a task in a tight loop never returns to
        // the run loop, so the tick alone would starve.
        //
        // Installed before background workers start and removed after they are joined, so the
        // plain hook fields never race.
        if (ctx.mem_limit) |ml| {
            ml.sample_owner = &pool;
            ml.sample_hook = worker_mod.allocSampleHook;
        }
    }

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

    const scope_task = try allocateTask(ctx, &primary.scheduler, &scope, popped.callable, popped.scope);
    owner_transferred = true;

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
        try adoptChildError(ctx, err_obj);
        return error.UserThrown;
    }
}

/// spawn ( quot -- task )
///
/// Allocates on the least-loaded worker's scheduler and dispatches via local or cross-thread
/// enqueue.
fn nativeSpawn(ctx: *Context) anyerror!void {
    // The task-level coroutine (minicoro) has a freestanding stub that never actually resumes
    // (see task.zig): a spawned task body would silently never run. Fail loudly instead of
    // shipping that as a silent no-op. Real wasm coroutine support needs its own follow-up.
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "spawn");

    const popped = try helpers.popCallableWithScope(ctx);
    var owner_transferred = false;
    errdefer if (!owner_transferred) popped.release();

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "spawn must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "spawn must be called from a running task";
        return error.InvalidState;
    };

    const scope = current.scope;
    const task = try spawnTaskOnPool(ctx, scheduler, scope, popped.callable, popped.scope);
    owner_transferred = true;
    try ctx.stack.push(.{ .task = task });
}

/// spawn-named ( quot name -- task )
///
/// Like `spawn`; stores `name` on the Task struct for display in task value representations.
fn nativeSpawnNamed(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "spawn-named");

    const name_pay = try helpers.popString(ctx);
    defer container_backing.releaseValue(.{ .string = name_pay });
    // The task keeps its display name for its whole lifetime.
    const name = try ctx.quotationAllocator().dupe(u8, name_pay.bytes);
    const popped = try helpers.popCallableWithScope(ctx);
    var owner_transferred = false;
    errdefer if (!owner_transferred) popped.release();

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "spawn-named must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "spawn-named must be called from a running task";
        return error.InvalidState;
    };

    const scope = current.scope;
    const task = try spawnTaskOnPool(ctx, scheduler, scope, popped.callable, popped.scope);
    owner_transferred = true;
    task.name = name;
    try ctx.stack.push(.{ .task = task });
}

/// spawn-detached ( quot -- )
///
/// Tracked in the scope's detached list rather than its children, so failure is isolated from
/// siblings and reaping happens at the task's own completion instead of at scope exit.
fn nativeSpawnDetached(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "spawn-detached");

    const popped = try helpers.popCallableWithScope(ctx);
    var owner_transferred = false;
    errdefer if (!owner_transferred) popped.release();

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "spawn-detached must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "spawn-detached must be called from a running task";
        return error.InvalidState;
    };

    const scope = current.scope;
    _ = try spawnDetachedOnPool(ctx, scheduler, scope, popped.callable, popped.scope);
    owner_transferred = true;
}

/// Allocate a child task on the least-loaded worker, attach it to the
/// given scope, and either enqueue locally or push to the target worker's
/// cross-thread external queue. The active-tasks counter on the target is
/// incremented before allocation so racing spawners observe the new load
/// even if allocation is still in progress. Falls back to the legacy
/// single-scheduler enqueue when there is no `worker_pool` (standalone
/// schedulers in tests).
fn spawnTaskOnPool(ctx: *Context, scheduler: *Scheduler, scope: *TaskScope, callable: Callable, captured_scope: ?*const CapturedScope) !*Task {
    if (ctx.worker_pool) |pool| {
        const target = pool.pickLeastLoaded();
        _ = target.active_tasks.fetchAdd(1, .release);
        errdefer _ = target.active_tasks.fetchSub(1, .release);

        const task = try allocateTask(ctx, &target.scheduler, scope, callable, captured_scope);
        try scope.addChild(task);
        if (&target.scheduler == scheduler) {
            try target.scheduler.enqueue(task);
        } else {
            try target.enqueueExternal(task);
        }
        return task;
    }

    // Legacy single-scheduler path (used by standalone schedulers in tests).
    const task = try allocateTask(ctx, scheduler, scope, callable, captured_scope);
    try scope.addChild(task);
    try scheduler.enqueue(task);
    return task;
}

/// Like `spawnTaskOnPool`, but registers the task in the scope's detached
/// list instead of its children and marks it detached, so the scheduler
/// reaps it at its own completion. The target's active-tasks counter is
/// still incremented so the pool stays alive while the detached task runs
/// and a top-level scope waits for it. `detached` and `addDetached` are set
/// before enqueue, so the task cannot start before it is fully registered.
fn spawnDetachedOnPool(ctx: *Context, scheduler: *Scheduler, scope: *TaskScope, callable: Callable, captured_scope: ?*const CapturedScope) !*Task {
    if (ctx.worker_pool) |pool| {
        const target = pool.pickLeastLoaded();
        _ = target.active_tasks.fetchAdd(1, .release);
        errdefer _ = target.active_tasks.fetchSub(1, .release);

        _ = pool.detached_in_flight.fetchAdd(1, .acq_rel);
        errdefer _ = pool.detached_in_flight.fetchSub(1, .acq_rel);

        const task = try allocateTask(ctx, &target.scheduler, scope, callable, captured_scope);
        task.detached = true;
        try scope.addDetached(task);
        if (&target.scheduler == scheduler) {
            try target.scheduler.enqueue(task);
        } else {
            try target.enqueueExternal(task);
        }
        return task;
    }

    // Legacy single-scheduler path (used by standalone schedulers in tests).
    const task = try allocateTask(ctx, scheduler, scope, callable, captured_scope);
    task.detached = true;
    try scope.addDetached(task);
    try scheduler.enqueue(task);
    return task;
}

/// task-self ( -- task )
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
fn nativeSleep(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "sleep cannot be called during module loading";
        return error.InvalidState;
    }

    const dur = try helpers.popDuration(ctx);
    container_backing.releaseValue(dur.val);

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
fn nativeWithTimeout(ctx: *Context) anyerror!void {
    const dur = try helpers.popDuration(ctx);
    // The popped duration is embedded in the timer quotation's push_literal
    // below, whose arena-side instructions are never walked for release, so
    // the popped reference drops here once the scope has drained.
    defer container_backing.releaseValue(dur.val);
    // Pop without stamping this context: the body runs in the main child task, so its carried scope
    // is stamped there. `with-timeout` is called once per request in a long-lived serve loop, so
    // stamping the caller would leak one copy per request.
    const popped = try helpers.popCallableWithScope(ctx);
    var owner_transferred = false;
    errdefer if (!owner_transferred) popped.release();

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
    // Reap both children when the scope exits. Without this they linger in the
    // scheduler's finished list until teardown. The HTTP idle-read timeout calls
    // with-timeout once per request, so that leaks a main and a timer task stack
    // on every request.
    //
    // Deferred after `scope.deinit` so LIFO runs the reap first, while the
    // children list is still intact.
    defer scheduler.reapScopeAtExit(&scope);

    // Race semantics: whichever of the main and timer tasks finishes first cancels
    // the other. Without this the main task completing normally leaves the timer
    // sleeping, and the caller blocks for the full timeout duration.
    scope.race_first_finisher = true;

    const main_task = try allocateTask(ctx, scheduler, &scope, popped.callable, popped.scope);
    owner_transferred = true;
    try scope.addChild(main_task);
    try scheduler.enqueue(main_task);
    scheduler.notifyOwnerTaskSpawned();

    const alloc = ctx.arena.allocator();
    const timer_instrs = try alloc.alloc(Instruction, 2);
    timer_instrs[0] = .{ .op = .{ .push_literal = dur.val }, .line = 0 };
    timer_instrs[1] = .{ .op = .{ .call_word = "sleep" }, .line = 0 };
    // The body is synthesized onto the arena rather than popped, so there is no reference behind it.
    const timer_callable: Callable = .{ .quot = .{ .instructions = timer_instrs }, .owner = .unit };

    // spawn the timer task with a custom entry point that marks as failed with a timeout error after the sleep completes
    const timer_task = try allocateTaskWithEntry(ctx, scheduler, &scope, timer_callable, null, &timerTaskEntryPoint);
    try scope.addChild(timer_task);
    try scheduler.enqueue(timer_task);
    scheduler.notifyOwnerTaskSpawned();

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
                // The copy (or share) carries its own +1 owning reference, which transfers to the
                // stack slot; a retaining push would double-count it.
                const copied = try deepCopyForTransfer(ctx, result, ctx.arena.allocator(), ctx.allocator);
                try ctx.stack.pushMoved(copied);
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        .failed => {
            if (main_task.error_obj) |err_obj| {
                try adoptChildError(ctx, err_obj);
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

    task.callable.execute(task.ctx) catch |err| {
        if (task.getCancellationPhase() != .none) {
            task.setStatus(.cancelled);
        } else {
            task.setStatus(.failed);
        }
        task.error_obj = task_mod.foldAndBoxTaskError(task.ctx, err);
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
fn nativeCancelTask(ctx: *Context) anyerror!void {
    const task = try helpers.popTask(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "cancel-task must be called within a task-scope";
        return error.InvalidState;
    };

    scheduler.cancelTask(task);
}

/// await ( task -- value )
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
            current.blocked_on_await = task;
            scheduler.suspendCurrentTask();
            current.blocked_on_await = null;
        },
        .completed, .failed, .cancelled => {},
    }

    try helpers.checkCancellation(ctx);

    return handleAwaitResult(ctx, task);
}

/// await-terminal ( task -- )
///
/// The building block for cancel-and-wait:
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
            current.blocked_on_await = task;
            scheduler.suspendCurrentTask();
            current.blocked_on_await = null;
        },
        .completed, .failed, .cancelled => {},
    }

    try helpers.checkCancellation(ctx);

    switch (task.getStatus()) {
        .completed, .cancelled => {},
        .failed => {
            if (task.error_obj) |err_obj| {
                try adoptChildError(ctx, err_obj);
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
/// Results preserve array order. If multiple tasks failed or were cancelled, the first error in
/// array order is thrown only after every task has reached a terminal status.
fn nativeAwaitAll(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "await-all cannot be called during module loading";
        return error.InvalidState;
    }

    const val = try ctx.stack.pop();
    // The popped array must stay alive across the suspensions below, since
    // `tasks` borrows its backing; the deferred release runs at return.
    defer container_backing.releaseValue(val);
    const tasks = switch (val) {
        .array => |arr| arr.items,
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
        try helpers.pushAdoptedArray(ctx, ctx.allocator, try ctx.allocator.alloc(Value, 0));
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
                current.blocked_on_await = task;
                scheduler.suspendCurrentTask();
                current.blocked_on_await = null;
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
                    try adoptChildError(ctx, err_obj);
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
    // A failed copy unwinds past the loop, so the owning references already collected in
    // `results` must be released or they leak.
    var copied: usize = 0;
    errdefer container_backing.releaseValues(results[0..copied]);
    for (tasks, 0..) |item, i| {
        const task = item.task;
        if (task.result) |result| {
            // XXX(ripta): Potentially expensive deep copy of each result. We have to do this
            //             before checking for errors/cancellations in order to preserve the
            //             correct error precedence. Unsure if there's a better way.
            results[i] = try deepCopyForTransfer(ctx, result, alloc, ctx.allocator);
        } else {
            results[i] = .{ .boolean = false };
        }
        copied = i + 1;
    }

    // Each element carries its own +1 owning reference from the copy or share
    // above; the fresh array adopts them and a moved push transfers the array
    // to the slot.
    try helpers.pushAdoptedArray(ctx, alloc, results);
}

/// Extract the result from a finished task: deep-copy completed results into the caller's
/// allocator, or share them by refcount bump when provably immutable; re-throw failures, and
/// report cancellations.
fn handleAwaitResult(ctx: *Context, task: *Task) anyerror!void {
    switch (task.getStatus()) {
        .completed => {
            if (task.result) |result| {
                // The copy (or share) carries its own +1 owning reference, which transfers to the
                // stack slot; a retaining push would double-count it.
                const copied = try deepCopyForTransfer(ctx, result, ctx.arena.allocator(), ctx.allocator);
                try ctx.stack.pushMoved(copied);
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        .failed => {
            if (task.error_obj) |err_obj| {
                try adoptChildError(ctx, err_obj);
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

const DeepCopyError = Allocator.Error || value_mod.ByteArray.ResizeError || error{TaskArenaEscape};

/// Deep-copy a Value into a destination allocator. Recursive for compound types.
///
/// Reference types owned by process-lifetime memory (channel, task, module, type values,
/// and the parse-time variants) are returned as-is. Arena-owned reference types (iterator,
/// parameter, resource, stream) fail with `error.TaskArenaEscape`: they
/// die with the sending task's arena, so passing them through would hand the receiver a
/// dangling pointer. Boundary callers convert that error via `deepCopyForTransfer`.
///
/// `longlived` is the process-lifetime allocator (`ctx.allocator`); a headered container whose
/// backing lives on it and whose contents are self-contained is shared by refcount bump instead
/// of copied, as is a heap-backed string, symbol, bignum, or backed tagged wrapper that passes
/// the same check. The returned value carries a +1 owning reference either way: a fresh copy's
/// creation reference, or the share's retain.
pub fn deepCopyValue(val: Value, alloc: Allocator, longlived: Allocator) DeepCopyError!Value {
    return switch (val) {
        .fixnum, .float, .boolean, .unit => val,
        .bignum => |b| blk: {
            if (container_backing.valueShareable(val, longlived)) {
                container_backing.retainValue(val);
                break :blk val;
            }

            const cloned = b.big.cloneWithDifferentAllocator(alloc) catch return error.OutOfMemory;
            break :blk try value_mod.bignumValue(alloc, cloned);
        },

        .string => |s| blk: {
            if (container_backing.valueShareable(val, longlived)) {
                container_backing.retainValue(val);
                break :blk val;
            }
            break :blk value_mod.stringValue(try alloc.dupe(u8, s.bytes));
        },
        .symbol => |s| blk: {
            if (container_backing.valueShareable(val, longlived)) {
                container_backing.retainValue(val);
                break :blk val;
            }
            break :blk value_mod.symbolValue(try alloc.dupe(u8, s.bytes));
        },

        .array => |arr| blk: {
            if (container_backing.memoShareable(&arr.header, val, longlived)) {
                arr.header.retain();
                break :blk val;
            }

            const new_items = try alloc.alloc(Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                new_items[i] = try deepCopyValue(item, alloc, longlived);
            }
            break :blk .{ .array = try value_mod.Array.fromOwnedSlice(alloc, new_items) };
        },

        .quotation => |quot| .{ .quotation = try deepCopyQuotation(quot, alloc, longlived) },

        .closure => |c| blk: {
            const copied = try deepCopyQuotation(c.asQuotation(), alloc, longlived);
            const new_segments = try alloc.alloc(value_mod.Segment, c.segments.len);
            for (c.segments, 0..) |seg, i| {
                const new_caps = try alloc.alloc(Value, seg.captures.len);
                for (seg.captures, 0..) |cap, j| {
                    new_caps[j] = try deepCopyValue(cap, alloc, longlived);
                }
                new_segments[i] = .{ .captures = new_caps, .base_code_ptr = seg.base_code_ptr };
            }
            // Copy the carried scope self-contained onto `alloc` so it rides the deep copy across a
            // channel or task-result boundary. The source's scope does not cross the worker
            // boundary with this deep copy.
            const new_scope: ?*const CapturedScope = if (c.captured_scope) |cs|
                try Context.dupeCapturedScope(alloc, cs)
            else
                null;
            // `owns_scope` is the one flag the copy sets: the scope copy claims its own reference to
            // every refcounted value the source's bindings hold, so the destroy has to drop them.
            // The rest of the copy's pieces live on the destination task arena and ride its
            // teardown, so freeing them is a noöp.
            //
            // The defining module copies by pointer: modules are process-shared through the module
            // cache. Carrying it is what keeps the copy resolvable at all, since the body was
            // duplicated onto this arena and the shared stamp store cannot answer for the new key.
            break :blk .{ .closure = try value_mod.Closure.create(alloc, .{
                .instructions = copied.instructions,
                .effect = copied.effect,
                .segments = new_segments,
                .captured_scope = new_scope,
                .defining_module = c.defining_module,
                .header = undefined,
                .owns_scope = new_scope != null,
            }) };
        },

        .hash => |h| blk: {
            if (container_backing.memoShareable(&h.header, val, longlived)) {
                h.header.retain();
                break :blk val;
            }

            const new_h = try value_mod.HashTable.create(alloc);
            try new_h.map.ensureTotalCapacity(alloc, @intCast(h.map.count()));
            var iter = h.map.iterator();
            while (iter.next()) |entry| {
                const key = try alloc.dupe(u8, entry.key_ptr.*);
                const v = try deepCopyValue(entry.value_ptr.*, alloc, longlived);
                new_h.map.putAssumeCapacityNoClobber(key, v);
            }
            break :blk .{ .hash = new_h };
        },

        .vector => |v| blk: {
            const new_v = try value_mod.Vector.create(alloc);
            try new_v.list.ensureTotalCapacity(alloc, v.list.items.len);
            for (v.list.items) |item| {
                new_v.list.appendAssumeCapacity(try deepCopyValue(item, alloc, longlived));
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
            if (container_backing.memoShareable(&s.header, val, longlived)) {
                s.header.retain();
                break :blk val;
            }

            const new_s = try value_mod.Set.create(alloc);
            try new_s.map.ensureTotalCapacity(alloc, @intCast(s.map.count()));
            for (s.map.keys()) |key| {
                new_s.map.putAssumeCapacity(try deepCopyValue(key, alloc, longlived), {});
            }
            break :blk .{ .set = new_s };
        },

        .mutable_map => |m| blk: {
            const new_m = try value_mod.MutableMap.create(alloc);
            try new_m.map.ensureTotalCapacity(alloc, @intCast(m.map.count()));
            var iter = m.map.iterator();
            while (iter.next()) |entry| {
                const key = try alloc.dupe(u8, entry.key_ptr.*);
                const v = try deepCopyValue(entry.value_ptr.*, alloc, longlived);
                new_m.map.putAssumeCapacityNoClobber(key, v);
            }
            break :blk .{ .mutable_map = new_m };
        },

        .struct_instance => |si| blk: {
            const new_fields = try alloc.alloc(Value, si.fields.len);
            for (si.fields, 0..) |field, i| {
                new_fields[i] = try deepCopyValue(field, alloc, longlived);
            }
            // The transfer allocator is safe here despite createStructInstance's
            // process-lifetime contract, for the same reason the sibling container copies
            // above use it: every copy's last release runs before the transfer arena is
            // torn down.
            const new_si = try value_mod.createStructInstance(alloc, si.struct_type, new_fields);
            break :blk .{ .struct_instance = new_si };
        },

        // A backed wrapper whose inner value passes the share scan crosses whole by refcount
        // bump. Otherwise the tagged shell is copied; a wrapped hash/set backing still shares
        // through the recursion's scan-verified memo.
        //
        // Type parameters are not trusted as a share proof: the parameterized wrap validates
        // array and struct elements but not hash or set contents, so a tag like hash(fixnum)
        // can sit on a container holding arena-backed strings.
        .tagged => |t| blk: {
            if (t.backing) |b| {
                if (container_backing.memoShareable(&b.header, val, longlived)) {
                    b.header.retain();
                    break :blk val;
                }
            }

            const new_inner = try alloc.create(Value);
            new_inner.* = try deepCopyValue(t.inner.*, alloc, longlived);
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
        .error_value => |err| .{ .error_value = try deepCopyErrorObject(err, alloc, alloc, longlived) },

        .doc_string => |s| .{ .doc_string = try alloc.dupe(u8, s) },

        // These reference types are owned by process-lifetime memory, so sharing the pointer is
        // safe. The parse-time variants (marker, struct_type, sandbox_spec, constraint_combinator)
        // are main-context-owned in practice; `eval-string` inside a task can produce arena-owned
        // ones that this tag-based check cannot distinguish, a documented limitation.
        .module, .marker, .struct_type, .task, .channel, .type_val, .type_descriptor, .protocol_descriptor, .constraint_combinator, .sandbox_spec => val,

        // Arena-owned reference types die with the sending task's arena. A new variant must be
        // classified here deliberately; never default a reference type to pass-through.
        .stream, .parameter, .iterator, .resource => error.TaskArenaEscape,
    };
}

/// Throw `task-arena-escape:` for the arena-owned variant reachable from `val`, with a
/// per-type remedy in the message.
pub fn throwTaskArenaEscape(ctx: *Context, val: Value) anyerror {
    const message = if (value_mod.findTaskArenaOwned(val)) |tag| switch (tag) {
        .iterator => "iterator cannot cross task boundary; materialize it with #collect and send the array instead",
        .stream => "stream cannot cross task boundary; send the file descriptor and rebuild with fd>stream in the receiving task",
        .parameter => "parameter cannot cross task boundary; create it with make-parameter in the receiving task, bindings resolve by name",
        .resource => "resource cannot cross task boundary; open the resource in the task that uses it",
        else => "value cannot cross task boundary; it is owned by the sending task's arena",
    } else "value cannot cross task boundary; it is owned by the sending task's arena";

    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "task-arena-escape",
        .message = message,
    });
    return error.UserThrown;
}

/// Copy or share a value across a task boundary, converting an arena-escape failure into
/// the thrown `task-arena-escape:` error. Every boundary copy (channel transfer, await,
/// await-all, with-timeout results) goes through here rather than calling `deepCopyValue`
/// directly.
///
/// The scan runs before the copy: rejecting up front keeps a failed transfer from leaving
/// a partially built copy whose already-copied shared elements were retained and would
/// leak on unwind. The catch below is the drift backstop for a copy path the scan misses.
pub fn deepCopyForTransfer(ctx: *Context, val: Value, alloc: Allocator, longlived: Allocator) anyerror!Value {
    if (value_mod.findTaskArenaOwned(val) != null) {
        return throwTaskArenaEscape(ctx, val);
    }

    return deepCopyValue(val, alloc, longlived) catch |err| switch (err) {
        error.TaskArenaEscape => throwTaskArenaEscape(ctx, val),
        else => err,
    };
}

/// Copy a failed child's error object into this context as the thrown error. Error data
/// carrying an arena-owned value is rejected the same way result copies are, and the
/// up-front scan keeps a rejected copy from leaking partially retained elements.
fn adoptChildError(ctx: *Context, err_obj: *value_mod.ErrorObject) anyerror!void {
    if (value_mod.findTaskArenaOwned(.{ .error_value = err_obj }) != null) {
        return throwTaskArenaEscape(ctx, .{ .error_value = err_obj });
    }

    ctx.thrown_error = try deepCopyErrorObject(err_obj, ctx.quotationAllocator(), ctx.quotationAllocator(), ctx.allocator);
}

fn deepCopyQuotation(quot: value_mod.Quotation, alloc: Allocator, longlived: Allocator) DeepCopyError!value_mod.Quotation {
    const new_instrs = try alloc.alloc(Instruction, quot.instructions.len);
    for (quot.instructions, 0..) |instr, i| {
        new_instrs[i] = .{
            .op = switch (instr.op) {
                .push_literal => |v| .{ .push_literal = try deepCopyValue(v, alloc, longlived) },
                .call_word => |name| .{ .call_word = try alloc.dupe(u8, name) },
                // Both slot forms are heap-stable for the process: the dictionary owns one, the
                // runtime-image loader arena the other. The copy shares the pointer.
                .call_word_direct => |slot| .{ .call_word_direct = slot },
                .call_word_module => |slot| .{ .call_word_module = slot },
            },
            .line = instr.line,
        };
    }

    // The effect can live on the sending task's arena: a compiled push in a non-image AOT binary
    // decodes it onto the executing context's arena, and `eval-string` inside a task parses it
    // there. Copy it like the instructions rather than sharing a pointer that dies with the task.
    const new_effect: ?*const StackEffect = if (quot.effect) |e| blk: {
        const copied = try alloc.create(StackEffect);
        copied.* = try deepCopyStackEffect(e.*, alloc);
        break :blk copied;
    } else null;

    return .{
        .instructions = new_instrs,
        .effect = new_effect,
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
        const new_qe: ?*const StackEffect = if (param.quotation_effect) |qe| blk: {
            const copied = try alloc.create(StackEffect);
            copied.* = try deepCopyStackEffect(qe.*, alloc);
            break :blk copied;
        } else null;
        // The annotation is an identity pointer shared like the `.type_val` pass-through arm,
        // with the same eval-string-in-a-task limitation documented there.
        new_params[i] = .{
            .name = try alloc.dupe(u8, param.name),
            .quotation_effect = new_qe,
            .is_row_variable = param.is_row_variable,
            .type_annotation = param.type_annotation,
        };
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

fn deepCopyErrorObjectValue(err: ErrorObject, alloc: Allocator, longlived: Allocator) DeepCopyError!ErrorObject {
    const new_data: ?*const Value = if (err.data) |data| blk: {
        const new_d = try alloc.create(Value);
        new_d.* = try deepCopyValue(data.*, alloc, longlived);
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
fn deepCopyErrorObject(err: *const ErrorObject, box_alloc: Allocator, inner_alloc: Allocator, longlived: Allocator) DeepCopyError!*ErrorObject {
    const inner = try deepCopyErrorObjectValue(err.*, inner_alloc, longlived);
    const ptr = try box_alloc.create(ErrorObject);
    ptr.* = inner;
    return ptr;
}

/// cancelled? ( -- bool )
///
/// Returns `f` outside a task-scope. Useful for compute-bound loops polling for cancellation.
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
    container_backing.releaseValue(dur.val);

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

    const hash = value_mod.HashTable.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer hash.header.release();
    const hash_alloc = hash.header.allocator;

    hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "io-waiting"), .{
        .fixnum = @intCast(scheduler.io_wait_map.count()),
    }) catch return error.OutOfMemory;
    hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "sleeping"), .{
        .fixnum = @intCast(scheduler.sleep_queue.count()),
    }) catch return error.OutOfMemory;
    hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "run-queue"), .{
        .fixnum = @intCast(scheduler.run_queue.items.len),
    }) catch return error.OutOfMemory;

    try ctx.stack.pushMoved(.{ .hash = hash });
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
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "container-limits");

    const trace_enabled = ctx.trace.trace_container_detect;
    const cpu = container_limits.detectCpus(trace_enabled);
    const mem = container_limits.detectMemory(trace_enabled);

    const hash = value_mod.HashTable.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer hash.header.release();
    const hash_alloc = hash.header.allocator;

    hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "cpu-count"), .{ .fixnum = @intCast(cpu.count) }) catch return error.OutOfMemory;
    hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "cpu-source"), value_mod.symbolValue(cpuSourceSymbol(cpu.source))) catch return error.OutOfMemory;
    const cpu_raw: Value = if (cpu.raw_quota != null and cpu.raw_period != null) blk: {
        const inner = value_mod.HashTable.create(ctx.allocator) catch return error.OutOfMemory;
        errdefer inner.header.release();
        const inner_alloc = inner.header.allocator;
        inner.map.put(inner_alloc, try inner_alloc.dupe(u8, "quota"), .{ .fixnum = cpu.raw_quota.? }) catch return error.OutOfMemory;
        inner.map.put(inner_alloc, try inner_alloc.dupe(u8, "period"), .{ .fixnum = cpu.raw_period.? }) catch return error.OutOfMemory;
        break :blk .{ .hash = inner };
    } else .{ .unit = {} };
    // The outer slot takes over the inner hash's construction reference.
    hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "cpu-raw"), cpu_raw) catch {
        container_backing.releaseValue(cpu_raw);
        return error.OutOfMemory;
    };

    hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "memory-cap"), .{ .fixnum = @intCast(mem.cap) }) catch return error.OutOfMemory;
    hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "memory-source"), value_mod.symbolValue(memSourceSymbol(mem.source))) catch return error.OutOfMemory;
    const mem_raw: Value = if (mem.raw) |r| .{ .fixnum = @intCast(r) } else .{ .unit = {} };
    hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "memory-raw"), mem_raw) catch return error.OutOfMemory;

    try ctx.stack.pushMoved(.{ .hash = hash });
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
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
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
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
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
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
    };
    var completed_child = Task{
        .id = 3,
        .name = null,
        .status = std.atomic.Value(task_mod.TaskStatus).init(.completed),
        .result = .{ .fixnum = 42 },
        .ctx = &ctx,
        .scope = &child_scope,
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
    };

    var task_values = [_]Value{
        .{ .task = &failed_child },
        .{ .task = &completed_child },
    };
    // The push retains the header, so the wrapper needs an initialized one;
    // static storage keeps the stack-local items untouched by the release.
    const task_arr = try value_mod.Array.createStatic(ctx.quotationAllocator(), task_values[0..]);
    try ctx.stack.push(.{ .array = task_arr });

    try std.testing.expectError(error.UserThrown, nativeAwaitAll(&ctx));
    try std.testing.expect(ctx.thrown_error != null);
    try std.testing.expectEqualStrings("borrowed-buffer-escape", ctx.thrown_error.?.error_type);
}

test "runLoop swaps the thread-local current context around a task resume" {
    const alloc = std.testing.allocator;

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    var sched = try Scheduler.init(alloc);
    defer sched.deinit();
    ctx.scheduler = &sched;

    var scope = TaskScope.init(alloc);
    defer scope.deinit();

    const Probe = struct {
        const memory_limit = @import("../memory_limit.zig");
        var seen: ?*anyopaque = null;
        fn entry(co: task_mod.CoroPtr) callconv(.c) void {
            const task: *Task = @ptrCast(@alignCast(task_mod.getCoroUserData(co)));
            seen = memory_limit.current_context;
            task.setStatus(.completed);
        }
    };

    // A sentinel outer value the resume must save and then restore, the way
    // the primary worker's main thread carries the root context.
    var outer_sentinel: u8 = 0;
    Probe.memory_limit.current_context = &outer_sentinel;
    defer Probe.memory_limit.current_context = null;

    const task = try allocateTaskWithEntry(&ctx, &sched, &scope, .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit }, null, &Probe.entry);
    const expected: *anyopaque = @ptrCast(task.ctx);
    try scope.addChild(task);
    try sched.enqueue(task);

    sched.runLoop();

    try std.testing.expectEqual(@as(?*anyopaque, expected), Probe.seen);
    try std.testing.expectEqual(@as(?*anyopaque, @as(*anyopaque, &outer_sentinel)), Probe.memory_limit.current_context);
}

test "deepCopyValue: a quotation's declared effect is copied, not shared" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const nested = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x" }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    const declared = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "quot", .quotation_effect = &nested },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "..a", .is_row_variable = true }},
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
    };
    const quot = value_mod.Quotation{ .instructions = &instrs, .effect = &declared };

    const copied = try deepCopyValue(.{ .quotation = quot }, arena.allocator(), testing.allocator);
    const copied_effect = copied.quotation.effect.?;
    try testing.expect(copied_effect != &declared);
    try testing.expectEqual(@as(usize, 2), copied_effect.inputs.len);
    try testing.expect(copied_effect.inputs[0].is_row_variable);
    try testing.expectEqualStrings("quot", copied_effect.inputs[1].name);
    const copied_nested = copied_effect.inputs[1].quotation_effect.?;
    try testing.expect(copied_nested != &nested);
    try testing.expectEqualStrings("x", copied_nested.inputs[0].name);
    try testing.expect(copied_effect.outputs[0].is_row_variable);
}

test "deepCopyValue: a closure copy carries its defining module" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    const instrs = [_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 }};
    const cl = try value_mod.Closure.create(testing.allocator, .{
        .instructions = &instrs,
        .segments = &.{},
        .defining_module = &module,
        .header = undefined,
    });
    defer container_backing.releaseValue(.{ .closure = cl });

    // The copy's body lands on the destination task's arena, a key the shared stamp store cannot
    // answer for, so the module has to ride the value across.
    const copied = try deepCopyValue(.{ .closure = cl }, arena.allocator(), testing.allocator);
    try testing.expect(copied.closure.instructions.ptr != cl.instructions.ptr);
    try testing.expectEqual(@as(?*const value_mod.Module, &module), copied.closure.defining_module);
}

test "deepCopyValue: shares a self-contained hash by refcount bump" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const h = try value_mod.HashTable.create(testing.allocator);
    defer container_backing.releaseValue(.{ .hash = h });
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), .{ .fixnum = 1 });

    const copied = try deepCopyValue(.{ .hash = h }, arena.allocator(), testing.allocator);
    try testing.expect(copied.hash == h);
    try testing.expectEqual(@as(u32, 2), h.header.refcountValue());

    container_backing.releaseValue(copied);
    try testing.expectEqual(@as(u32, 1), h.header.refcountValue());
}

test "deepCopyValue: shares a self-contained set by refcount bump" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const s = try value_mod.Set.create(testing.allocator);
    defer container_backing.releaseValue(.{ .set = s });
    try s.map.put(s.header.allocator, .{ .fixnum = 3 }, {});

    const copied = try deepCopyValue(.{ .set = s }, arena.allocator(), testing.allocator);
    try testing.expect(copied.set == s);
    try testing.expectEqual(@as(u32, 2), s.header.refcountValue());

    container_backing.releaseValue(copied);
    try testing.expectEqual(@as(u32, 1), s.header.refcountValue());
}

test "deepCopyValue: an arena-owned reference type fails with TaskArenaEscape" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var res = value_mod.Resource{ .type_name = "test-resource" };
    try testing.expectError(error.TaskArenaEscape, deepCopyValue(.{ .resource = &res }, arena.allocator(), testing.allocator));
}

test "deepCopyValue: an arena-owned reference type nested in an array fails with TaskArenaEscape" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var res = value_mod.Resource{ .type_name = "test-resource" };
    var items = [_]Value{
        .{ .fixnum = 1 },
        .{ .resource = &res },
    };
    const arr = try value_mod.Array.createStatic(arena.allocator(), items[0..]);
    try testing.expectError(error.TaskArenaEscape, deepCopyValue(.{ .array = arr }, arena.allocator(), testing.allocator));
}

test "deepCopyForTransfer: rejects before retaining shared elements" {
    const testing = std.testing;
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const h = try value_mod.HashTable.create(testing.allocator);
    defer container_backing.releaseValue(.{ .hash = h });

    var res = value_mod.Resource{ .type_name = "test-resource" };
    var items = [_]Value{
        .{ .hash = h },
        .{ .resource = &res },
    };
    const arr = try value_mod.Array.createStatic(ctx.quotationAllocator(), items[0..]);

    try testing.expectError(error.UserThrown, deepCopyForTransfer(&ctx, .{ .array = arr }, ctx.quotationAllocator(), testing.allocator));
    try testing.expect(ctx.thrown_error != null);
    try testing.expectEqualStrings("task-arena-escape", ctx.thrown_error.?.error_type);

    // The rejection fired before the copy, so the shareable sibling was never retained.
    try testing.expectEqual(@as(u32, 1), h.header.refcountValue());
}

test "deepCopyValue: shares a self-contained array by refcount bump" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const items = try testing.allocator.alloc(Value, 2);
    items[0] = .{ .fixnum = 1 };
    items[1] = .{ .float = 2.5 };
    const arr = try value_mod.Array.fromOwnedSlice(testing.allocator, items);
    defer container_backing.releaseValue(.{ .array = arr });

    const copied = try deepCopyValue(.{ .array = arr }, arena.allocator(), testing.allocator);
    try testing.expect(copied.array == arr);
    try testing.expectEqual(@as(u32, 2), arr.header.refcountValue());

    container_backing.releaseValue(copied);
    try testing.expectEqual(@as(u32, 1), arr.header.refcountValue());
}

test "deepCopyValue: string-bearing array is copied, not shared" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const items = try testing.allocator.alloc(Value, 1);
    items[0] = value_mod.stringValue("s");
    const arr = try value_mod.Array.fromOwnedSlice(testing.allocator, items);
    defer container_backing.releaseValue(.{ .array = arr });

    const copied = try deepCopyValue(.{ .array = arr }, arena.allocator(), testing.allocator);
    try testing.expect(copied.array != arr);
    try testing.expectEqual(@as(u32, 1), arr.header.refcountValue());
    container_backing.releaseValue(copied);
}

test "deepCopyValue: a static array is copied, not shared" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const items = try arena.allocator().alloc(Value, 1);
    items[0] = .{ .fixnum = 9 };
    const arr = try value_mod.Array.createStatic(arena.allocator(), items);

    const copied = try deepCopyValue(.{ .array = arr }, arena.allocator(), testing.allocator);
    try testing.expect(copied.array != arr);
    try testing.expectEqual(container_backing.Shareable.not_shareable, arr.header.shareableState());
    container_backing.releaseValue(copied);
}

test "deepCopyValue: string-bearing hash is copied, not shared" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const h = try value_mod.HashTable.create(testing.allocator);
    defer container_backing.releaseValue(.{ .hash = h });
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), value_mod.stringValue("v"));

    const copied = try deepCopyValue(.{ .hash = h }, arena.allocator(), testing.allocator);
    try testing.expect(copied.hash != h);
    try testing.expectEqual(@as(u32, 1), h.header.refcountValue());
    container_backing.releaseValue(copied);
}

test "deepCopyValue: a backing off the long-lived allocator is copied on the next hop" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Simulates a value that was itself produced by a cross-task copy onto a
    // receiver arena: contents qualify, but the backing's provenance fails the
    // identity check, so a re-send copies again instead of sharing.
    const h = try value_mod.HashTable.create(arena.allocator());
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), .{ .fixnum = 1 });

    const copied = try deepCopyValue(.{ .hash = h }, arena.allocator(), testing.allocator);
    try testing.expect(copied.hash != h);
    container_backing.releaseValue(copied);
    container_backing.releaseValue(.{ .hash = h });
}

test "deepCopyValue: tagged hash shares the backing through the scan and copies the shell" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const h = try value_mod.HashTable.create(testing.allocator);
    defer container_backing.releaseValue(.{ .hash = h });
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), .{ .fixnum = 1 });

    var vt: value_mod.VirtualType = .{ .name = "counts", .inner_type = "hash" };
    const inner: Value = .{ .hash = h };

    const copied = try deepCopyValue(.{ .tagged = .{ .tag = &vt, .inner = &inner } }, arena.allocator(), testing.allocator);
    try testing.expect(copied.tagged.inner != &inner);
    try testing.expect(copied.tagged.inner.hash == h);
    try testing.expectEqual(@as(u32, 2), h.header.refcountValue());
    try testing.expectEqual(container_backing.Shareable.shareable, h.header.shareableState());

    container_backing.releaseValue(copied);
    try testing.expectEqual(@as(u32, 1), h.header.refcountValue());
}

test "deepCopyValue: a backed shareable tagged shares whole by refcount bump" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var vt: value_mod.VirtualType = .{ .name = "gauge", .inner_type = "fixnum" };
    const src = try value_mod.ownedTaggedValue(testing.allocator, &vt, .{ .fixnum = 9 });
    defer container_backing.releaseValue(src);

    const copied = try deepCopyValue(src, arena.allocator(), testing.allocator);
    try testing.expect(copied.tagged.backing == src.tagged.backing);
    try testing.expectEqual(@as(u32, 2), src.tagged.backing.?.header.refcountValue());

    container_backing.releaseValue(copied);
    try testing.expectEqual(@as(u32, 1), src.tagged.backing.?.header.refcountValue());
}

test "deepCopyValue: a backed non-shareable tagged copies to a null-backed arena shell" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var vt: value_mod.VirtualType = .{ .name = "label", .inner_type = "string" };
    const src = try value_mod.ownedTaggedValue(testing.allocator, &vt, value_mod.stringValue("s"));
    defer container_backing.releaseValue(src);

    // The copy rides the destination arena and is refcount-inert, so releasing
    // the backed source cannot reach into it.
    const copied = try deepCopyValue(src, arena.allocator(), testing.allocator);
    try testing.expect(copied.tagged.backing == null);
    try testing.expectEqualStrings("s", copied.tagged.inner.string.bytes);
}

test "deepCopyValue: shares a heap-backed string by refcount bump" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const src = try value_mod.ownedStringValue(testing.allocator, try testing.allocator.dupe(u8, "shared"));
    defer container_backing.releaseValue(src);

    const copied = try deepCopyValue(src, arena.allocator(), testing.allocator);
    try testing.expect(copied.string.backing == src.string.backing);
    try testing.expect(copied.string.bytes.ptr == src.string.bytes.ptr);
    try testing.expectEqual(@as(u32, 2), src.string.backing.?.header.refcountValue());

    container_backing.releaseValue(copied);
    try testing.expectEqual(@as(u32, 1), src.string.backing.?.header.refcountValue());
}

test "deepCopyValue: a null-backed string is copied, not shared" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const src = value_mod.stringValue("s");
    const copied = try deepCopyValue(src, arena.allocator(), testing.allocator);
    try testing.expect(copied.string.backing == null);
    try testing.expect(copied.string.bytes.ptr != src.string.bytes.ptr);
    try testing.expectEqualStrings("s", copied.string.bytes);
}

test "deepCopyValue: shares a heap-backed symbol and bignum by refcount bump" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const sym = try value_mod.ownedSymbolValue(testing.allocator, try testing.allocator.dupe(u8, "sym"));
    defer container_backing.releaseValue(sym);
    const sym_copy = try deepCopyValue(sym, arena.allocator(), testing.allocator);
    try testing.expect(sym_copy.symbol.backing == sym.symbol.backing);
    container_backing.releaseValue(sym_copy);

    const big = try value_mod.BigIntManaged.initSet(testing.allocator, 12345);
    const bn = try value_mod.ownedBignumValue(testing.allocator, big);
    defer container_backing.releaseValue(bn);
    const bn_copy = try deepCopyValue(bn, arena.allocator(), testing.allocator);
    try testing.expect(bn_copy.bignum.backing == bn.bignum.backing);
    try testing.expect(bn_copy.bignum.big == bn.bignum.big);
    container_backing.releaseValue(bn_copy);
}

test "deepCopyValue: heap-backed string elements share with the array" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const items = try testing.allocator.alloc(Value, 1);
    items[0] = try value_mod.ownedStringValue(testing.allocator, try testing.allocator.dupe(u8, "s"));
    const arr = try value_mod.Array.fromOwnedSlice(testing.allocator, items);
    defer container_backing.releaseValue(.{ .array = arr });

    const copied = try deepCopyValue(.{ .array = arr }, arena.allocator(), testing.allocator);
    try testing.expect(copied.array == arr);
    try testing.expectEqual(@as(u32, 2), arr.header.refcountValue());
    container_backing.releaseValue(copied);
}

test "deepCopyValue: a scalar-parameterized tag does not exempt string contents from the scan" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The parameterized wrap does not validate hash contents, so a tag
    // claiming scalar elements can sit on a string-bearing hash. The scan,
    // not the tag, decides: this must copy.
    const h = try value_mod.HashTable.create(testing.allocator);
    defer container_backing.releaseValue(.{ .hash = h });
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), value_mod.stringValue("v"));

    const fixnum_tv = value_mod.TypeValue{ .name = "fixnum", .descriptor = null };
    var params = [_]*const value_mod.TypeValue{&fixnum_tv};
    const vt = value_mod.VirtualType{
        .name = "counts",
        .inner_type = "hash",
        .type_params = params[0..],
    };
    const inner: Value = .{ .hash = h };

    const copied = try deepCopyValue(.{ .tagged = .{ .tag = &vt, .inner = &inner } }, arena.allocator(), testing.allocator);
    try testing.expect(copied.tagged.inner.hash != h);
    try testing.expectEqual(@as(u32, 1), h.header.refcountValue());
    container_backing.releaseValue(copied);
}
