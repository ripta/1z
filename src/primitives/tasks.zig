const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const task_mod = @import("../task.zig");
const Task = task_mod.Task;
const TaskScope = task_mod.TaskScope;
const Scheduler = @import("../scheduler.zig").Scheduler;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const ErrorObject = value_mod.ErrorObject;
const StackEffect = @import("../stack_effect.zig").StackEffect;
const StackEffectParam = @import("../stack_effect.zig").StackEffectParam;

const task_stack_size: usize = 64 * 1024;

pub const primitives = [_]Primitive{
    .{ .name = "task-scope", .stack_effect = "quot --", .func = nativeTaskScope },
    .{ .name = "spawn", .stack_effect = "quot -- task", .func = nativeSpawn },
    .{ .name = "yield", .stack_effect = "--", .func = nativeYield },
    .{ .name = "await", .stack_effect = "task -- value", .func = nativeAwait },
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

/// await ( task -- value )
///
/// Wait for a task to complete and push its result. If the task has no result,
/// pushes `f`. If the task failed, re-throws its error. If the task is still
/// running, suspends the caller until the task finishes.
fn nativeAwait(ctx: *Context) anyerror!void {
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

    return handleAwaitResult(ctx, task);
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

fn deepCopyValue(val: Value, alloc: Allocator) DeepCopyError!Value {
    return switch (val) {
        .integer, .boolean => val,

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

        // NOTE(ripta): Reference types not owned by the task arena so it's safe to share without copying
        .stream, .parameter, .module, .marker, .struct_type, .benchmark_report, .task => val,
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
