const std = @import("std");
const builtin = @import("builtin");
const container_backing = @import("container_backing.zig");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const ErrorObject = value_mod.ErrorObject;

const is_freestanding = builtin.os.tag == .freestanding;

// Freestanding builds have no libc and no minicoro header to import; the
// freestanding scheduler is single-worker with no live coroutines, so this
// stub keeps the surrounding type references well-formed without ever
// being called.
const mc = if (is_freestanding) struct {
    pub const mco_coro = opaque {};
    pub const mco_desc = extern struct {
        func: ?*const fn (?*mco_coro) callconv(.c) void = null,
        user_data: ?*anyopaque = null,
        alloc_cb: ?*anyopaque = null,
        dealloc_cb: ?*anyopaque = null,
        allocator_data: ?*anyopaque = null,
        storage_size: usize = 0,
        coro_size: usize = 0,
        stack_size: usize = 0,
    };
    pub const MCO_SUCCESS: c_int = 0;
    pub fn mco_resume(co: ?*mco_coro) callconv(.c) c_int {
        _ = co;
        return 0;
    }
    pub fn mco_yield(co: ?*mco_coro) callconv(.c) c_int {
        _ = co;
        return 0;
    }
    pub fn mco_running() callconv(.c) ?*mco_coro {
        return null;
    }
    pub fn mco_destroy(co: ?*mco_coro) callconv(.c) c_int {
        _ = co;
        return 0;
    }
    pub fn mco_get_user_data(co: ?*mco_coro) callconv(.c) ?*anyopaque {
        _ = co;
        return null;
    }
    pub fn mco_desc_init(func: anytype, stack_size: usize) callconv(.c) mco_desc {
        _ = func;
        _ = stack_size;
        return .{};
    }
    pub fn mco_create(out: *?*mco_coro, desc: *const mco_desc) callconv(.c) c_int {
        _ = out;
        _ = desc;
        return 0;
    }
} else @cImport({
    @cInclude("minicoro.h");
});

/// Resume a task's coroutine from the calling (scheduler) context.
pub fn coroResume(task: *Task) void {
    _ = mc.mco_resume(task.coro.?);
}

/// Yield the current coroutine back to its caller (the scheduler).
/// Must be called from within a running task coroutine.
pub fn coroYield() void {
    _ = mc.mco_yield(mc.mco_running());
}

/// Destroy a task's coroutine and clear the pointer.
pub fn coroDestroy(task: *Task) void {
    if (task.coro) |co| {
        _ = mc.mco_destroy(co);
        task.coro = null;
    }
}

/// Entry function for task coroutines. Called by minicoro with the coroutine
/// pointer as the sole argument; reads the task pointer from user_data.
pub fn taskEntryPoint(co: CoroPtr) callconv(.c) void {
    const task: *Task = @ptrCast(@alignCast(mc.mco_get_user_data(co)));

    task.ctx.executeQuotationWithFrame(task.quotation) catch {
        if (task.ctx.error_details.items.len > 0) {
            const detail = task.ctx.error_details.items[0];
            task.error_obj = value_mod.boxErrorObject(task.ctx.quotationAllocator(), .{
                .error_type = detail.error_type,
                .message = detail.message,
            }) catch null;
            if (task.getCancellationPhase() != .none and std.mem.eql(u8, detail.error_type, "task-cancelled")) {
                task.setStatus(.cancelled);
            } else {
                task.setStatus(.failed);
            }
        } else if (task.ctx.thrown_error) |thrown| {
            task.error_obj = thrown;
            task.ctx.thrown_error = null;
            if (task.getCancellationPhase() != .none and std.mem.eql(u8, thrown.error_type, "task-cancelled")) {
                task.setStatus(.cancelled);
            } else {
                task.setStatus(.failed);
            }
        } else {
            task.setStatus(.failed);
        }
        return;
    };

    publishTaskResult(task);
}

/// Status of a green thread task.
pub const TaskStatus = enum(u8) {
    pending,
    running,
    completed,
    failed,
    cancelled,
};

/// Cooperative cancellation state machine.
///
/// Tasks progress through these phases:
///
///   none -> pending -> unwinding -> (task exits)
///                   -> shielded -> unwinding (during cleanup handlers)
///
/// The meanings:
/// - `pending`: cancellation requested but not yet observed by the task.
/// - `unwinding`: task has observed the cancellation and is propagating the error.
/// - `shielded`: cleanup handler is executing; cancellation checks are suppressed
///               so the handler can yield, sleep, or do I/O without re-triggering.
pub const CancellationPhase = enum(u8) {
    none,
    pending,
    unwinding,
    shielded,
};

/// Task represents a green thread with its own execution context.
pub const Task = struct {
    id: u64,
    name: ?[]const u8,
    status: std.atomic.Value(TaskStatus),
    result: ?Value = null,
    error_obj: ?*ErrorObject = null,
    coro: ?*mc.mco_coro = null,
    ctx: *Context,
    scope: *TaskScope,
    cancellation_phase: std.atomic.Value(CancellationPhase) = std.atomic.Value(CancellationPhase).init(.none),
    blocked_on_channel: ?*anyopaque = null,
    blocked_on_io_fd: ?std.posix.fd_t = null,
    blocked_on_process_pid: ?std.posix.pid_t = null,
    blocked_on_process_key: ?u64 = null,
    blocked_on_scope: ?*TaskScope = null,
    /// Set by a sender when it delivers a value directly to this receiver's
    /// stack. The receiver checks and clears this on resume so it can
    /// distinguish a value handoff from a close-channel wake.
    value_delivered: bool = false,
    quotation: Quotation,
    peak_stack_usage: usize = 0,
    /// Task that is waiting for this task to complete (via await).
    awaiting_task: ?*Task = null,
    /// Set for a fire-and-forget task spawned with `spawn-detached`. A
    /// detached task is tracked in its scope's `detached` list, isolated
    /// from sibling cancellation, and reaped at its own completion.
    detached: bool = false,

    pub inline fn getStatus(self: *const Task) TaskStatus {
        return self.status.load(.acquire);
    }

    pub inline fn setStatus(self: *Task, s: TaskStatus) void {
        self.status.store(s, .release);
    }

    pub inline fn getCancellationPhase(self: *const Task) CancellationPhase {
        return self.cancellation_phase.load(.acquire);
    }

    pub inline fn setCancellationPhase(self: *Task, p: CancellationPhase) void {
        self.cancellation_phase.store(p, .release);
    }
};

pub fn publishTaskResult(task: *Task) void {
    if (task.ctx.stack.depth() > 0) {
        const result = task.ctx.stack.pop() catch null;
        if (result) |val| {
            if (value_mod.valueContainsBorrowedBuffer(val)) {
                container_backing.releaseValue(val);
                task.error_obj = value_mod.boxErrorObject(task.ctx.quotationAllocator(), .{
                    .error_type = "borrowed-buffer-escape",
                    .message = "borrowed buffer cannot cross task boundary via task result; call >byte-array first",
                }) catch null;
                task.result = null;
                task.setStatus(.failed);
                return;
            }
            // The `task.result` slot is a new owning reference. The pop
            // transferred ownership to the C local; storing here re-roots
            // ownership in the task. No extra retain needed: the original
            // stack-slot ownership transfers into `task.result`.
            task.result = val;
        }
    }
    task.setStatus(.completed);
}

/// Release the owning reference held by `task.result`. Call when
/// finalizing a task whose result was set (or could have been set) so
/// the slot is properly accounted for. Idempotent: nulls the slot
/// after releasing.
pub fn releaseTaskResult(task: *Task) void {
    if (task.result) |val| {
        container_backing.releaseValue(val);
        task.result = null;
    }
}

/// TaskScope tracks children and completion for structured concurrency.
pub const TaskScope = struct {
    children: std.ArrayListUnmanaged(*Task),
    /// Guards `children` against concurrent appends from spawns on other
    /// worker threads and reads from sibling-cancellation iteration.
    children_mu: std.Thread.Mutex = .{},
    /// The coordinator task that runs the task-scope body. Excluded from
    /// sibling cancellation so it can observe child failures via await.
    scope_task: ?*Task = null,
    /// Task that is waiting for the entire scope to complete.
    waiting_task: ?*Task = null,
    allocator: Allocator,
    /// Atomic count of children that have not yet finished.
    active_children: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Atomic flag set when a child fails and sibling cancellation triggers.
    cancellation_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Fire-and-forget detached tasks. Not in `children`, so they are never
    /// walked by sibling cancellation or `firstFailedChildError`. Reaped at
    /// their own completion, so this holds only in-flight detached tasks.
    detached: std.ArrayListUnmanaged(*Task) = .{},
    /// Guards `detached` against concurrent appends from spawns on other
    /// worker threads and the reap removal on the owning worker. Kept
    /// separate from `children_mu` so detached reaping never contends with
    /// the sibling-cancellation walk over `children`.
    detached_mu: std.Thread.Mutex = .{},
    /// Atomic count of detached tasks that have not yet finished. Drives
    /// scope-exit waiting alongside `active_children`.
    detached_active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// One-shot claim so exactly one worker wakes the scope waiter when both
    /// `active_children` and `detached_active` reach zero. Without it the
    /// last tracked child and the last detached task completing concurrently
    /// on different workers could both observe the drained state and
    /// double-wake the waiter.
    waiter_woken: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: Allocator) TaskScope {
        return .{
            .children = .{},
            .scope_task = null,
            .waiting_task = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TaskScope) void {
        self.children.deinit(self.allocator);
        self.detached.deinit(self.allocator);
    }

    pub fn addChild(self: *TaskScope, task: *Task) !void {
        self.children_mu.lock();
        defer self.children_mu.unlock();
        try self.children.append(self.allocator, task);
        _ = self.active_children.fetchAdd(1, .release);
    }

    /// Register a detached task. Mirrors `addChild` but tracks the task in
    /// the separate `detached` list and counter, so it stays out of the
    /// sibling-cancellation and first-error paths.
    pub fn addDetached(self: *TaskScope, task: *Task) !void {
        self.detached_mu.lock();
        defer self.detached_mu.unlock();
        try self.detached.append(self.allocator, task);
        _ = self.detached_active.fetchAdd(1, .release);
    }

    /// Remove a detached task from the list at its own completion. Order in
    /// `detached` is not load-bearing, so `swapRemove` is used. The scan is
    /// bounded by the in-flight detached count.
    pub fn removeDetached(self: *TaskScope, task: *Task) void {
        self.detached_mu.lock();
        defer self.detached_mu.unlock();
        for (self.detached.items, 0..) |t, i| {
            if (t == task) {
                _ = self.detached.swapRemove(i);
                return;
            }
        }
    }

    /// Check if all children have finished (completed, failed, or cancelled).
    pub fn allChildrenDone(self: *const TaskScope) bool {
        return self.active_children.load(.acquire) == 0;
    }

    /// Walk children in spawn order under `children_mu` and return the
    /// first child whose status is `.failed`, along with its
    /// `error_obj`. Returns null when no child failed. Intended to be
    /// called only after `allChildrenDone()` returns true so every
    /// child has reached a stable terminal status; the per-task status
    /// transition to `.failed` happens-before the `active_children`
    /// fetchSub that drives the scope waiter, so reads of `error_obj`
    /// observe the writer's assignment without further synchronization.
    pub fn firstFailedChildError(self: *TaskScope) ?*ErrorObject {
        self.children_mu.lock();
        defer self.children_mu.unlock();
        for (self.children.items) |child| {
            if (child.getStatus() == .failed) {
                return child.error_obj;
            }
        }
        return null;
    }
};

/// Opaque pointer type for a minicoro coroutine handle.
pub const CoroPtr = ?*mc.mco_coro;

/// Function type for coroutine entry points passed to minicoro.
pub const CoroEntryFn = *const fn (CoroPtr) callconv(.c) void;

/// Get the user_data pointer from a coroutine handle.
pub fn getCoroUserData(co: CoroPtr) ?*anyopaque {
    return mc.mco_get_user_data(co);
}

/// Initialize a minicoro coroutine for a task.
///
/// The entry function receives the mco_coro pointer and reads the task from
/// user_data. stack_size controls the OS stack for coroutine execution.
pub fn initCoroContext(
    task: *Task,
    entry_fn: CoroEntryFn,
    stack_size: usize,
) !void {
    var desc = mc.mco_desc_init(entry_fn, stack_size);
    desc.user_data = task;
    const result = mc.mco_create(&task.coro, &desc);
    if (result != mc.MCO_SUCCESS) return error.CoroCreationFailed;
}

/// Allocate a native stack for a parser coroutine using mmap with a guard page.
/// Returns the full allocation of guard plus usable.
///
/// Layout: [guard page (PROT_NONE)] [usable stack space]
pub fn allocateTaskStack(size: usize) ![]align(std.heap.page_size_min) u8 {
    const page_size = std.heap.page_size_min;
    const total_size = size + page_size;
    const mem = std.posix.mmap(
        null,
        total_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return error.OutOfMemory;

    // Set the low address guard page to PROT_NONE
    std.posix.mprotect(
        @alignCast(mem[0..page_size]),
        std.posix.PROT.NONE,
    ) catch {
        std.posix.munmap(mem);
        return error.OutOfMemory;
    };

    return @alignCast(mem);
}

/// Free a stack allocated by allocateTaskStack.
pub fn freeTaskStack(mem: []align(std.heap.page_size_min) u8) void {
    std.posix.munmap(mem);
}

// =============================================================================
// Tests
// =============================================================================

test "atomic status round-trip" {
    var status = std.atomic.Value(TaskStatus).init(.pending);
    try std.testing.expectEqual(TaskStatus.pending, status.load(.acquire));

    status.store(.running, .release);
    try std.testing.expectEqual(TaskStatus.running, status.load(.acquire));

    status.store(.completed, .release);
    try std.testing.expectEqual(TaskStatus.completed, status.load(.acquire));
}

test "active children counter and allChildrenDone" {
    var scope = TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    try std.testing.expect(scope.allChildrenDone());

    // Simulate two children added
    _ = scope.active_children.fetchAdd(1, .release);
    _ = scope.active_children.fetchAdd(1, .release);
    try std.testing.expect(!scope.allChildrenDone());

    // First child finishes
    _ = scope.active_children.fetchSub(1, .release);
    try std.testing.expect(!scope.allChildrenDone());

    // Second child finishes
    _ = scope.active_children.fetchSub(1, .release);
    try std.testing.expect(scope.allChildrenDone());
}

test "addDetached and removeDetached track the detached counter and list" {
    var scope = TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var t0 = Task{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.pending),
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    var t1 = Task{
        .id = 2,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.pending),
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };

    try std.testing.expectEqual(@as(u32, 0), scope.detached_active.load(.acquire));

    try scope.addDetached(&t0);
    try scope.addDetached(&t1);
    try std.testing.expectEqual(@as(u32, 2), scope.detached_active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), scope.detached.items.len);

    // Detached tasks stay out of the tracked-children path.
    try std.testing.expectEqual(@as(usize, 0), scope.children.items.len);
    try std.testing.expect(scope.allChildrenDone());

    // Reaping one removes it from the list; the counter is decremented
    // separately by the scheduler at reap time.
    scope.removeDetached(&t0);
    try std.testing.expectEqual(@as(usize, 1), scope.detached.items.len);
    try std.testing.expectEqual(&t1, scope.detached.items[0]);

    // Removing a task that is not present is a no-op.
    scope.removeDetached(&t0);
    try std.testing.expectEqual(@as(usize, 1), scope.detached.items.len);

    scope.removeDetached(&t1);
    try std.testing.expectEqual(@as(usize, 0), scope.detached.items.len);
}

test "cancellation requested flag" {
    var scope = TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    try std.testing.expect(!scope.cancellation_requested.load(.acquire));

    scope.cancellation_requested.store(true, .release);
    try std.testing.expect(scope.cancellation_requested.load(.acquire));
}

test "firstFailedChildError walks children in spawn order" {
    var scope = TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var first = ErrorObject{ .error_type = "first-error", .message = "first" };
    var second = ErrorObject{ .error_type = "second-error", .message = "second" };

    var t0 = Task{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.completed),
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    var t1 = Task{
        .id = 2,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.failed),
        .error_obj = &first,
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    var t2 = Task{
        .id = 3,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.failed),
        .error_obj = &second,
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };

    try scope.children.append(scope.allocator, &t0);
    try scope.children.append(scope.allocator, &t1);
    try scope.children.append(scope.allocator, &t2);

    const got = scope.firstFailedChildError();
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("first-error", got.?.error_type);
}

test "firstFailedChildError returns null when no child failed" {
    var scope = TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var t0 = Task{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.completed),
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    var t1 = Task{
        .id = 2,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.cancelled),
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };

    try scope.children.append(scope.allocator, &t0);
    try scope.children.append(scope.allocator, &t1);

    try std.testing.expect(scope.firstFailedChildError() == null);
}

test "firstFailedChildError skips completed and cancelled children" {
    var scope = TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var err = ErrorObject{ .error_type = "real-error", .message = "real" };

    var t0 = Task{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.cancelled),
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    var t1 = Task{
        .id = 2,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.completed),
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    var t2 = Task{
        .id = 3,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.failed),
        .error_obj = &err,
        .ctx = undefined,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };

    try scope.children.append(scope.allocator, &t0);
    try scope.children.append(scope.allocator, &t1);
    try scope.children.append(scope.allocator, &t2);

    const got = scope.firstFailedChildError();
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("real-error", got.?.error_type);
}

test "publishTaskResult rejects borrowed buffer results" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var scope = TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var bytes = [_]u8{ 1, 2, 3 };
    const ba = try value_mod.makeBorrowedByteArray(std.testing.allocator, bytes[0..]);
    defer container_backing.releaseValue(.{ .byte_array = ba });

    try ctx.stack.push(.{ .byte_array = ba });

    var task = Task{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.running),
        .ctx = &ctx,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };

    publishTaskResult(&task);

    try std.testing.expectEqual(TaskStatus.failed, task.getStatus());
    try std.testing.expect(task.result == null);
    try std.testing.expect(task.error_obj != null);
    try std.testing.expectEqualStrings("borrowed-buffer-escape", task.error_obj.?.error_type);
}
