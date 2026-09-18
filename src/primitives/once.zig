const std = @import("std");

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const OnceCell = value_mod.OnceCell;
const Value = value_mod.Value;

const container_backing = @import("../container_backing.zig");
const Scheduler = @import("../scheduler.zig").Scheduler;
const task_mod = @import("../task.zig");
const Task = task_mod.Task;

const errors_mod = @import("errors.zig");
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "force-once", .func = nativeForceOnce, .stack_effect = "cell -- value" },
};

/// force-once ( cell -- value )
///
/// The whole body of a `once`-marked word: `;` moved the source body into the cell and left a
/// `push_literal` of the cell followed by a call to this.
///
/// A reference that hits the published value takes no lock. Everything else goes through
/// `arrive`, which decides in one critical section whether this execution runs the body, parks
/// on another that is running it, or has closed a cycle back onto itself.
///
/// The entry is deliberately not `defines_word`. That flag tells the compiled tier a body needs
/// the interpreter's transient lexical frame, and this native opens that frame itself for the
/// body it runs, from `cell.may_define`. Flagging it would make every `once` word's stored body
/// pay a frame push on every read. A `;` inside the source body still reaches `defineWordLocked`
/// with `;` as the in-flight native, so the declaration assertion is satisfied.
fn nativeForceOnce(ctx: *Context) anyerror!void {
    const cell_val = try ctx.stack.pop();
    defer container_backing.releaseValue(cell_val);
    const cell = switch (cell_val) {
        .once_cell => |c| c,
        else => {
            helpers.setTypeMismatchError(ctx, "once-cell", cell_val);
            return error.TypeMismatch;
        },
    };

    if (cell.state.load(.acquire) == .forced) {
        // `push` takes the reader's reference itself, so the cell keeps the one it published.
        try ctx.stack.push(cell.value.?);
        return;
    }

    while (true) {
        // The task this OS thread is resumed into, and nothing else. A context names whatever
        // scheduler it was pointed at, which a `task-scope` moves, so it is not a witness for
        // the thread reading it.
        const running = task_mod.resumed_task;

        switch (cell.arrive(running, ctx.forcing_once_cell)) {
            .forced => {
                try ctx.stack.push(cell.value.?);
                return;
            },
            .cycle => return raiseOnceCycle(ctx, cell),
            .begun => return runForce(ctx, cell),
            .wait => {
                const sched = parkableScheduler(running) orelse return raiseForceWait(ctx, cell);
                if (try parkOnForce(ctx, cell, running.?, sched)) return;
                // The force settled between the arrival and the enqueue, so ask again rather
                // than park on a cell nobody is forcing.
            },
        }
    }
}

/// Run the body, then publish what it produced or hand its error to every waiter.
///
/// The cell is already `forcing` and names this execution, so nothing else can enter the body.
fn runForce(ctx: *Context, cell: *OnceCell) anyerror!void {
    const saved_parent = ctx.forcing_once_cell;
    ctx.forcing_once_cell = cell;
    defer ctx.forcing_once_cell = saved_parent;

    const depth_before = ctx.stack.depth();

    const saved_source = ctx.current_source;
    defer ctx.current_source = saved_source;
    ctx.enterBodySource(cell.body.instructions);

    // The source body ran in the word's place before `;` moved it here, so it resolves bare words
    // against the word's module the way the guard standing in for it does. The guard is executing
    // right now, so its own visibility names that module; the source body carries no stamp of its
    // own, because it never reached a push site that would have given it one.
    const defining_module = if (ctx.active_deps_vis) |vis| vis.defining_module else null;

    ctx.executeQuotationWithPic(cell.body, null, defining_module, cell.owner, cell.may_define) catch |err| {
        failForce(ctx, cell, err);
        return err;
    };

    const depth_after = ctx.stack.depth();
    const delta = @as(i64, @intCast(depth_after)) - @as(i64, @intCast(depth_before));
    if (delta != 1) {
        // The cell stays cold, so the next call runs the body again rather than publishing
        // whatever this one left behind.
        helpers.setErrorContext(ctx, "a 'once' body must leave exactly one value, but left {d}", .{delta});
        failForce(ctx, cell, error.StackEffectMismatch);
        return error.StackEffectMismatch;
    }

    // `peek` borrows, so the cell takes a reference of its own beside the caller's. Teardown
    // releases that one; the caller's goes when its stack slot does.
    const produced = ctx.stack.peek() catch |err| {
        failForce(ctx, cell, err);
        return err;
    };
    container_backing.retainValue(produced);

    var woken = cell.publish(produced);
    defer woken.deinit(cell.allocator);
    wakeAll(ctx, cell, woken.items);
}

/// Return the cell to cold and give every waiter the error this force raised, so a parked reader
/// raises the same thing instead of waiting for a publish that is not coming.
///
/// A body that threw carries its own boxed type and message, and anything else is named by its
/// Zig error with whatever prose the raise site left pending.
///
/// `ctx.thrown_error` is read and not consumed: the forcing execution still propagates it.
fn failForce(ctx: *Context, cell: *OnceCell, err: anyerror) void {
    var woken = cell.fail();
    defer woken.deinit(cell.allocator);
    if (woken.items.len == 0) return;

    var kebab_buf: [128]u8 = undefined;
    var error_type: []const u8 = undefined;
    var message: []const u8 = undefined;
    if (err == error.UserThrown and ctx.thrown_error != null) {
        error_type = ctx.thrown_error.?.error_type;
        message = ctx.thrown_error.?.message;
    } else {
        error_type = errors_mod.pascalToKebabRuntime(@errorName(err), &kebab_buf);
        message = ctx.pending_error_message orelse error_type;
    }

    // The stamp copies into each waiter's own slot, so `kebab_buf` going out of scope below is
    // not something a waiter can observe.
    for (woken.items) |waiter| waiter.stamp(error_type, message);
    wakeAll(ctx, cell, woken.items);
}

/// Enqueue each drained waiter on its home worker.
fn wakeAll(ctx: *Context, cell: *OnceCell, waiters: []const *OnceCell.Waiter) void {
    if (waiters.len == 0) return;
    // `wakeTask` routes by the waiter's own home, so any scheduler serves as the caller. A
    // queued waiter implies one ran it.
    const sched = wakeScheduler(ctx) orelse
        @panic("once-cell waiter queued with no scheduler on the publishing thread");
    for (waiters) |waiter| sched.wakeTask(waiter.task) catch cell.requeueWaiter(waiter);
}

fn wakeScheduler(ctx: *Context) ?*Scheduler {
    if (task_mod.resumed_task) |task| return task.ctx.scheduler;
    return ctx.scheduler;
}

/// The scheduler this execution can park in, or null when it cannot park at all.
///
/// Null covers the non-task main thread, which has no scheduler to suspend into, and a task
/// running on the parser coroutine's stack. `mco_yield` refuses a yield whose stack pointer lies
/// outside the running coroutine's bounds, and the refusal is silent, so the test comes before
/// any scheduler state is written.
fn parkableScheduler(running: ?*Task) ?*Scheduler {
    const task = running orelse return null;
    const co = task.coro orelse return null;
    const sp = @frameAddress();
    const base = @intFromPtr(co.stack_base);
    if (sp < base or sp >= base + co.stack_size) return null;
    return task.ctx.scheduler;
}

/// Park until the force publishes or fails, returning true once the value is on the stack.
///
/// A false return means the enqueue found the cell settled, so the caller arrives again. A
/// failed force and a cancellation both raise from here.
fn parkOnForce(ctx: *Context, cell: *OnceCell, task: *Task, sched: *Scheduler) anyerror!bool {
    var waiter = OnceCell.Waiter{ .task = task };
    if (!try cell.enqueueIfForcing(&waiter)) return false;

    task.blocked_on_once_cell = @ptrCast(cell);
    while (true) {
        sched.suspendCurrentTask();

        helpers.checkCancellation(ctx) catch |err| {
            _ = cell.removeWaiter(task);
            return err;
        };

        if (waiter.failed) {
            task.blocked_on_once_cell = null;
            const alloc = ctx.quotationAllocator();
            ctx.thrown_error = try value_mod.boxErrorObject(alloc, .{
                .error_type = try alloc.dupe(u8, waiter.errorType()),
                .message = try alloc.dupe(u8, waiter.message()),
            });
            return error.UserThrown;
        }

        if (cell.state.load(.acquire) == .forced) {
            task.blocked_on_once_cell = null;
            try ctx.stack.push(cell.value.?);
            return true;
        }

        // A spurious wake: park again without re-queueing, since the entry is still listed.
    }
}

/// Raise on a body that reaches its own cell, naming the chain of `once` words that closes it.
fn raiseOnceCycle(ctx: *Context, cell: *OnceCell) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const message = formatCycleChain(alloc, ctx.forcing_once_cell, cell) catch
        "once cycle between compute-once words";
    ctx.thrown_error = try value_mod.boxErrorObject(alloc, .{
        .error_type = "once-cycle",
        .message = message,
    });
    return error.UserThrown;
}

/// Render the cycle as `a -> b -> a`: the re-entered cell, the forces nested inside it, and the
/// re-entered cell again.
///
/// The parent links run innermost-first, so the names are collected in that order and emitted in
/// reverse. A walk that never reaches `target` elides the middle rather than guessing it, which
/// is what a chain held by a nested execution context produces.
fn formatCycleChain(alloc: std.mem.Allocator, innermost: ?*OnceCell, target: *OnceCell) ![]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .{};
    defer names.deinit(alloc);

    var reached = false;
    var walk = innermost;
    while (walk) |c| {
        try names.append(alloc, c.name);
        if (c == target) {
            reached = true;
            break;
        }
        walk = c.forcing_parent;
    }

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "once cycle: ");

    if (reached) {
        var i = names.items.len;
        while (i > 0) {
            i -= 1;
            try out.appendSlice(alloc, names.items[i]);
            try out.appendSlice(alloc, " -> ");
        }
    } else {
        try out.appendSlice(alloc, target.name);
        try out.appendSlice(alloc, " -> ... -> ");
    }
    // Both arms stop one name short, so the closing name is the same one either way.
    try out.appendSlice(alloc, target.name);

    return out.toOwnedSlice(alloc);
}

/// Raise for a contended force this execution cannot wait out.
fn raiseForceWait(ctx: *Context, cell: *OnceCell) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const message = std.fmt.allocPrint(
        alloc,
        "cannot wait for a 'once' value here; '{s}' is being computed elsewhere and this execution cannot park",
        .{cell.name},
    ) catch "cannot wait for a 'once' value from an execution that cannot park";
    ctx.thrown_error = try value_mod.boxErrorObject(alloc, .{
        .error_type = "once-force-wait",
        .message = message,
    });
    return error.UserThrown;
}

const testing = std.testing;

/// Drive `force-once` over a hand-built cell, the way a `once` word's stored body would.
fn forceCell(ctx: *Context, cell: *OnceCell) anyerror!void {
    try ctx.stack.push(.{ .once_cell = cell });
    try nativeForceOnce(ctx);
}

fn testCell(body: []const value_mod.Instruction, name: []const u8) OnceCell {
    return .{
        .body = .{ .instructions = body },
        .name = name,
        .allocator = testing.allocator,
    };
}

test "force-once: publishes on the first call and reuses the value afterward" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0 },
    };
    var cell = testCell(&body, "answer");
    defer cell.deinit();

    try forceCell(&ctx, &cell);
    try testing.expectEqual(OnceCell.State.forced, cell.state.load(.acquire));
    try testing.expectEqual(@as(i64, 7), (try ctx.stack.peek()).fixnum);

    // Overwriting the published value separates a reuse from a rerun: a second call that read the
    // cell answers 9, and one that re-entered the body would answer 7 again.
    cell.value = .{ .fixnum = 9 };
    ctx.stack.clear();
    try forceCell(&ctx, &cell);
    try testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try testing.expectEqual(@as(i64, 9), (try ctx.stack.peek()).fixnum);
}

test "force-once: a reused refcounted value gains no reference per read" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const items = try testing.allocator.alloc(value_mod.Value, 1);
    items[0] = .{ .fixnum = 1 };
    const arr = try value_mod.Array.fromOwnedSlice(testing.allocator, items);
    const literal = value_mod.Value{ .array = arr };

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = literal }, .line = 0 },
    };
    var cell = testCell(&body, "items");
    defer cell.deinit();

    // Each read pushes and each pop releases, so the pairs below net out. What does not is a read
    // that retains on top of the push: `std.testing.allocator` then reports the array as leaked.
    for (0..3) |_| {
        try forceCell(&ctx, &cell);
        try ctx.stack.popAndRelease();
    }

    // Two references are outstanding by construction: the one the cold force published into the
    // cell, and the creation reference this test still holds.
    container_backing.releaseValue(cell.value.?);
    cell.value = null;
    cell.state.store(.cold, .release);
    container_backing.releaseValue(literal);
}

test "force-once: a body leaving other than one value raises and leaves the cell cold" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const two = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 },
    };
    var two_cell = testCell(&two, "two");
    defer two_cell.deinit();
    try testing.expectError(error.StackEffectMismatch, forceCell(&ctx, &two_cell));
    try testing.expectEqual(OnceCell.State.cold, two_cell.state.load(.acquire));
    try testing.expect(two_cell.value == null);

    ctx.stack.clear();

    var none_cell = testCell(&.{}, "none");
    defer none_cell.deinit();
    try testing.expectError(error.StackEffectMismatch, forceCell(&ctx, &none_cell));
    try testing.expectEqual(OnceCell.State.cold, none_cell.state.load(.acquire));
}

test "force-once: a throwing body leaves the cell cold" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const body = [_]value_mod.Instruction{
        .{ .op = .{ .call_word = "no-such-word-at-all" }, .line = 0 },
    };
    var cell = testCell(&body, "missing");
    defer cell.deinit();

    try testing.expectError(error.UnknownWord, forceCell(&ctx, &cell));
    try testing.expectEqual(OnceCell.State.cold, cell.state.load(.acquire));
    try testing.expect(cell.value == null);
}

test "force-once: a body that reads its own cell raises once-cycle" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // The body is filled in after the cell exists, since it has to push the cell itself.
    var cell = testCell(&.{}, "self");
    defer cell.deinit();
    const body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .once_cell = &cell } }, .line = 0 },
        .{ .op = .{ .call_word = "native.force-once" }, .line = 0 },
    };
    cell.body = .{ .instructions = &body };

    try testing.expectError(error.UserThrown, forceCell(&ctx, &cell));
    const thrown = ctx.thrown_error orelse return error.TestExpectedThrow;
    try testing.expectEqualStrings("once-cycle", thrown.error_type);
    try testing.expectEqualStrings("once cycle: self -> self", thrown.message);
    try testing.expectEqual(OnceCell.State.cold, cell.state.load(.acquire));
}

test "force-once: a cycle through a second cell names both words" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var outer = testCell(&.{}, "outer");
    defer outer.deinit();
    var inner = testCell(&.{}, "inner");
    defer inner.deinit();

    const outer_body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .once_cell = &inner } }, .line = 0 },
        .{ .op = .{ .call_word = "native.force-once" }, .line = 0 },
    };
    const inner_body = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .once_cell = &outer } }, .line = 0 },
        .{ .op = .{ .call_word = "native.force-once" }, .line = 0 },
    };
    outer.body = .{ .instructions = &outer_body };
    inner.body = .{ .instructions = &inner_body };

    try testing.expectError(error.UserThrown, forceCell(&ctx, &outer));
    const thrown = ctx.thrown_error orelse return error.TestExpectedThrow;
    try testing.expectEqualStrings("once-cycle", thrown.error_type);
    try testing.expectEqualStrings("once cycle: outer -> inner -> outer", thrown.message);

    // The unwind leaves both cells cold, so a later call runs each body again.
    try testing.expectEqual(OnceCell.State.cold, outer.state.load(.acquire));
    try testing.expectEqual(OnceCell.State.cold, inner.state.load(.acquire));
}

test "force-once: a contended force with nothing to park raises once-force-wait" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var cell = testCell(&.{}, "held");
    defer cell.deinit();

    // Another execution owns the force, so this one is a contender rather than a re-entry.
    var holder: Task = undefined;
    holder.blocked_on_once_cell = null;
    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&holder, null));

    try testing.expectError(error.UserThrown, forceCell(&ctx, &cell));
    const thrown = ctx.thrown_error orelse return error.TestExpectedThrow;
    try testing.expectEqualStrings("once-force-wait", thrown.error_type);
    try testing.expectEqualStrings(
        "cannot wait for a 'once' value here; 'held' is being computed elsewhere and this execution cannot park",
        thrown.message,
    );
}
