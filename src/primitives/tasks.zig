const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const task_mod = @import("../task.zig");
const Task = task_mod.Task;
const TaskScope = task_mod.TaskScope;
const scheduler_mod = @import("../scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const ErrorObject = value_mod.ErrorObject;
const StackEffect = @import("../stack_effect.zig").StackEffect;
const StackEffectParam = @import("../stack_effect.zig").StackEffectParam;

const task_stack_size: usize = 512 * 1024;

pub const primitives = [_]Primitive{
    .{ .name = "task-scope", .stack_effect = "quot --", .doc = "Run quotation in a structured concurrency scope.", .func = nativeTaskScope },
    .{ .name = "spawn", .stack_effect = "quot -- task", .doc = "Spawn a new task from a quotation.", .func = nativeSpawn },
    .{ .name = "spawn-named", .stack_effect = "quot name -- task", .doc = "Spawn a named task from a quotation.", .func = nativeSpawnNamed },
    .{ .name = "task-self", .stack_effect = "-- task", .doc = "Push the current task handle.", .func = nativeTaskSelf },
    .{ .name = "yield", .stack_effect = "--", .doc = "Voluntarily yield the current task.", .func = nativeYield },
    .{ .name = "await", .stack_effect = "task -- value", .doc = "Wait for a task to complete and push its result.", .func = nativeAwait },
    .{ .name = "await-all", .stack_effect = "array -- array", .doc = "Wait for all tasks in array and return array of results.", .func = nativeAwaitAll },
    .{ .name = "sleep", .stack_effect = "duration --", .doc = "Suspend the current task for a duration.", .func = nativeSleep },
    .{ .name = "cancel-task", .stack_effect = "task --", .doc = "Cancel a task.", .func = nativeCancelTask },
    .{ .name = "with-timeout", .stack_effect = "quot duration -- value", .doc = "Run a quotation with a timeout duration.", .func = nativeWithTimeout },
    .{ .name = "multiplexer-stats", .stack_effect = "-- hash", .doc = "Return a hash of I/O multiplexer statistics. Requires an active task-scope.", .func = nativeMultiplexerStats },
    .{ .name = "cancelled?", .stack_effect = "-- bool", .doc = "Push t if the current task has a pending cancellation, f otherwise.", .func = nativeCancelledQuery },
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
    try scheduler.all_tasks.append(ctx.allocator, task);
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
        scope.scope_task = scope_task;

        try scope.addChild(scope_task);
        try scheduler.enqueue(scope_task);

        const current = scheduler.current_task.?;
        scope.waiting_task = current;
        current.blocked_on_scope = &scope;
        scheduler.suspendCurrentTask();
        current.blocked_on_scope = null;

        try helpers.checkCancellation(ctx);

        if (scope.failed_error) |err_obj| {
            ctx.thrown_error = err_obj;
            return error.UserThrown;
        }

        return;
    }

    // Case: Top-level
    var scheduler = try Scheduler.init(ctx.allocator);
    defer scheduler.deinit();

    scheduler.deadlock_detect_ns = ctx.deadlock_detect_ns;

    ctx.scheduler = &scheduler;
    scheduler_mod.active_scheduler.store(&scheduler, .release);
    defer {
        ctx.scheduler = null;
        scheduler_mod.active_scheduler.store(null, .release);
    }

    var scope = TaskScope.init(ctx.allocator);
    defer scope.deinit();

    const scope_task = try allocateTask(ctx, &scheduler, &scope, quot);
    scope.scope_task = scope_task;

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
    const task = try allocateTask(ctx, scheduler, scope, quot);
    task.name = name;
    try scope.addChild(task);
    try scheduler.enqueue(task);

    try ctx.stack.push(.{ .task = task });
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
/// sleeps for the given duration then triggers a timeout failure.
///
/// If the main task completes first, its result is pushed and the timer is cancelled.
/// If the timer fires first, the main task is cancelled and a `timeout` error is thrown.
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
    const timer_quot: @import("../value.zig").Quotation = .{ .instructions = timer_instrs };

    // spawn the timer task with a custom entry point that marks as failed with a timeout error after the sleep completes
    const timer_task = try allocateTask(ctx, scheduler, &scope, timer_quot);
    task_mod.initTaskContext(timer_task, &timerTaskEntryPoint, &scheduler.scheduler_uctx);
    try scope.addChild(timer_task);
    try scheduler.enqueue(timer_task);

    // suspend the current task until the scope drains
    scope.waiting_task = current;
    current.blocked_on_scope = &scope;
    scheduler.suspendCurrentTask();
    current.blocked_on_scope = null;

    try helpers.checkCancellation(ctx);

    // inspect main task status to determine outcome
    switch (main_task.status) {
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
                ctx.thrown_error = err_obj;
            } else {
                ctx.thrown_error = .{
                    .error_type = "task-error",
                    .message = "task failed without error details",
                };
            }
            return error.UserThrown;
        },
        .cancelled => {
            ctx.thrown_error = .{
                .error_type = "timeout",
                .message = "operation timed out",
            };
            return error.UserThrown;
        },
        .pending, .running => unreachable,
    }
}

/// Entry function for the timer task coroutine used by `with-timeout`.
/// Runs the timer quotation (which sleeps), then marks the task as failed
/// with a timeout error. This failure triggers sibling cancellation of the
/// main task in the isolated scope.
fn timerTaskEntryPoint() callconv(.c) void {
    const task = task_mod.pending_entry_task.?;
    task_mod.pending_entry_task = null;

    task.ctx.executeQuotation(task.quotation) catch {
        if (task.cancellation_phase != .none) {
            task.status = .cancelled;
        } else {
            task.status = .failed;
        }
        if (task.ctx.thrown_error) |thrown| {
            task.error_obj = thrown;
        }
        return;
    };

    // Sleep completed normally, meaning the timeout fired before the main task
    // finished. Mark the timer as failed with a timeout error to trigger sibling
    // cancellation of the main task.
    task.status = .failed;
    task.error_obj = .{
        .error_type = "timeout",
        .message = "operation timed out",
    };
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

    switch (task.status) {
        .pending, .running => {
            task.awaiting_task = current;
            scheduler.suspendCurrentTask();
        },
        .completed, .failed, .cancelled => {},
    }

    try helpers.checkCancellation(ctx);

    return handleAwaitResult(ctx, task);
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
        switch (task.status) {
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
        switch (task.status) {
            .failed => {
                if (task.error_obj) |err_obj| {
                    ctx.thrown_error = err_obj;
                } else {
                    ctx.thrown_error = .{
                        .error_type = "task-error",
                        .message = "task failed without error details",
                    };
                }
                return error.UserThrown;
            },
            .cancelled => {
                ctx.thrown_error = .{
                    .error_type = "task-cancelled",
                    .message = "awaited task was cancelled",
                };
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
    switch (task.status) {
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
                ctx.thrown_error = err_obj;
            } else {
                ctx.thrown_error = .{
                    .error_type = "task-error",
                    .message = "task failed without error details",
                };
            }
            return error.UserThrown;
        },
        .cancelled => {
            ctx.thrown_error = .{
                .error_type = "task-cancelled",
                .message = "awaited task was cancelled",
            };
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
        .bignum => |b| .{ .bignum = b.cloneWithDifferentAllocator(alloc) catch return error.OutOfMemory },

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
            const new_v = try alloc.create(value_mod.Vector);
            new_v.* = .{};
            try new_v.ensureTotalCapacity(alloc, v.items.len);
            for (v.items) |item| {
                new_v.appendAssumeCapacity(try deepCopyValue(item, alloc));
            }
            break :blk .{ .vector = new_v };
        },

        .byte_array => |b| blk: {
            const new_b = try alloc.create(value_mod.ByteArray);
            new_b.* = .{};
            try new_b.ensureTotalCapacity(alloc, b.items.len);
            new_b.appendSliceAssumeCapacity(b.items);
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
            const new_m = try alloc.create(value_mod.MutableMap);
            new_m.* = .{};
            try new_m.ensureTotalCapacity(alloc, @intCast(m.count()));
            var iter = m.iterator();
            while (iter.next()) |entry| {
                const key = try alloc.dupe(u8, entry.key_ptr.*);
                const v = try deepCopyValue(entry.value_ptr.*, alloc);
                new_m.putAssumeCapacityNoClobber(key, v);
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
        .error_value => |err| .{ .error_value = try deepCopyErrorObject(err, alloc) },

        .doc_string => |s| .{ .doc_string = try alloc.dupe(u8, s) },

        // NOTE(ripta): Reference types not owned by the task arena so it's safe to share without copying
        .stream, .parameter, .module, .marker, .struct_type, .benchmark_report, .task, .channel, .iterator, .resource, .type_val => val,
    };
}

fn deepCopyQuotation(quot: value_mod.Quotation, alloc: Allocator) DeepCopyError!value_mod.Quotation {
    const new_instrs = try alloc.alloc(Instruction, quot.instructions.len);
    for (quot.instructions, 0..) |instr, i| {
        new_instrs[i] = .{
            .op = switch (instr.op) {
                .push_literal => |v| .{ .push_literal = try deepCopyValue(v, alloc) },
                .call_word => |name| .{ .call_word = try alloc.dupe(u8, name) },
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

fn deepCopyErrorObject(err: ErrorObject, alloc: Allocator) DeepCopyError!ErrorObject {
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

/// cancelled? ( -- bool )
///
/// Push `t` if the current task has a pending cancellation, `f` otherwise.
/// Returns `f` outside a task-scope. Useful for compute-bound loops that
/// need to poll for cancellation.
fn nativeCancelledQuery(ctx: *Context) anyerror!void {
    const cancelled = if (ctx.scheduler) |sched|
        if (sched.current_task) |task| task.cancellation_phase != .none else false
    else
        false;
    try ctx.stack.push(.{ .boolean = cancelled });
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
