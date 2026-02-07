const std = @import("std");
const Context = @import("../context.zig").Context;
const task_mod = @import("../task.zig");
const Task = task_mod.Task;
const TaskScope = task_mod.TaskScope;
const Scheduler = @import("../scheduler.zig").Scheduler;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");

const task_stack_size: usize = 64 * 1024;

pub const primitives = [_]Primitive{
    .{ .name = "task-scope", .stack_effect = "quot --", .func = nativeTaskScope },
    .{ .name = "spawn", .stack_effect = "quot -- task", .func = nativeSpawn },
    .{ .name = "yield", .stack_effect = "--", .func = nativeYield },
};

/// Allocate a Task and its Context on the heap, wire up the ucontext, and
/// return the task pointer. Caller is responsible for adding the task to a
/// scope and enqueueing it.
fn allocateTask(
    ctx: *Context,
    scheduler: *Scheduler,
    scope: *TaskScope,
    quotation: @import("../value.zig").Quotation,
) !*Task {
    const task = try ctx.allocator.create(Task);
    errdefer ctx.allocator.destroy(task);

    const task_ctx = try ctx.allocator.create(Context);
    errdefer ctx.allocator.destroy(task_ctx);
    task_ctx.* = try Context.initForTask(ctx.allocator, ctx, scheduler);

    const stack_mem = try task_mod.allocateTaskStack(task_stack_size);
    errdefer task_mod.freeTaskStack(stack_mem);

    task.* = .{
        .id = scheduler.nextId(),
        .name = null,
        .status = .pending,
        .uctx = undefined,
        .stack_mem = stack_mem,
        .ctx = task_ctx,
        .scope = scope,
        .quotation = quotation,
    };

    task_mod.initTaskContext(task, &task_mod.taskEntryPoint, &scheduler.scheduler_uctx);
    return task;
}

/// task-scope ( quot -- )
///
/// Two code paths depending on whether a scheduler is already running.
///
/// 1. Top-level: called from the main context where `ctx.scheduler` is null.
/// Creates a Scheduler, wraps the quotation in a scope task, runs the
/// scheduling loop to completion, then propagates any child error.
///
/// 2. Nested: called from within a running task where `ctx.scheduler` is
/// non-null. Creates a TaskScope on the current task's native stack frame,
/// spawns a scope task, suspends the current task until the scope drains,
/// then propagates any child error.
fn nativeTaskScope(ctx: *Context) anyerror!void {
    const quot = try helpers.popQuotation(ctx);

    // Case: nested
    if (ctx.scheduler) |scheduler| {
        var scope = TaskScope.init(ctx.allocator);
        defer scope.deinit();

        const scope_task = try allocateTask(ctx, scheduler, &scope, quot);
        try scope.addChild(scope_task);
        try scheduler.enqueue(scope_task);

        scope.waiting_task = scheduler.current_task;
        scheduler.suspendCurrentTask();
        if (scope.failed_error) |err_obj| {
            ctx.thrown_error = err_obj;
            return error.UserThrown;
        }

        return;
    }

    // Case: Top-level
    var scheduler = Scheduler.init(ctx.allocator);
    defer scheduler.deinit();

    ctx.scheduler = &scheduler;
    defer {
        ctx.scheduler = null;
    }

    var scope = TaskScope.init(ctx.allocator);
    defer scope.deinit();

    const scope_task = try allocateTask(ctx, &scheduler, &scope, quot);
    try scope.addChild(scope_task);
    try scheduler.enqueue(scope_task);

    scheduler.runLoop();
    if (scope.failed_error) |err_obj| {
        ctx.thrown_error = err_obj;
        return error.UserThrown;
    }
}

/// spawn ( quot -- task )
///
/// Must be called within a `task-scope`. We first read the current scope from
/// `scheduler.current_task.scope`, allocate a new task, add task as a child,
/// enqueues the task, and pushes the task value onto the caller's stack.
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
    const task = try allocateTask(ctx, scheduler, scope, quot);
    try scope.addChild(task);
    try scheduler.enqueue(task);

    try ctx.stack.push(.{ .task = task });
}

/// yield ( -- )
///
/// Voluntarily yields the current task, allowing other tasks to run.
fn nativeYield(ctx: *Context) anyerror!void {
    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "yield must be called within a task-scope";
        return error.InvalidState;
    };

    scheduler.yieldCurrentTask();
}
