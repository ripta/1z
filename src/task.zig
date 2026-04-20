const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const ErrorObject = value_mod.ErrorObject;

/// C library functions for ucontext coroutine support.
const c = struct {
    extern "c" fn getcontext(ucp: *std.c.ucontext_t) c_int;
    extern "c" fn makecontext(
        ucp: *std.c.ucontext_t,
        func: *const fn () callconv(.c) void,
        argc: c_int,
    ) void;
    extern "c" fn swapcontext(
        oucp: *std.c.ucontext_t,
        ucp: *const std.c.ucontext_t,
    ) c_int;
};

pub const makecontext = c.makecontext;
pub const swapcontext = c.swapcontext;

/// Module-level variable to pass the task pointer to `taskEntryPoint`.
/// Safe because scheduling is single-threaded cooperative: the scheduler
/// sets this immediately before swapcontext, and the entry function reads
/// and clears it before any yield point.
pub var pending_entry_task: ?*Task = null;

/// Entry function for task coroutines. Called via makecontext with no
/// arguments; reads the task pointer from `pending_entry_task`.
pub fn taskEntryPoint() callconv(.c) void {
    const task = pending_entry_task.?;
    pending_entry_task = null;

    task.ctx.executeQuotation(task.quotation) catch {
        if (task.ctx.thrown_error) |thrown| {
            task.error_obj = thrown;
            if (task.cancellation_phase != .none and std.mem.eql(u8, thrown.error_type, "task-cancelled")) {
                task.status = .cancelled;
            } else {
                task.status = .failed;
            }
        } else if (task.ctx.error_details.items.len > 0) {
            const detail = task.ctx.error_details.items[0];
            task.error_obj = .{
                .error_type = detail.error_type,
                .message = detail.message,
            };
            task.status = .failed;
        } else {
            task.status = .failed;
        }
        return;
    };

    if (task.ctx.stack.depth() > 0) {
        task.result = task.ctx.stack.pop() catch null;
    }
    task.status = .completed;
}

/// Status of a green thread task.
pub const TaskStatus = enum {
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
pub const CancellationPhase = enum {
    none,
    pending,
    unwinding,
    shielded,
};

/// Task represents a green thread with its own execution context.
pub const Task = struct {
    id: u64,
    name: ?[]const u8,
    status: TaskStatus,
    result: ?Value = null,
    error_obj: ?ErrorObject = null,
    uctx: std.c.ucontext_t = undefined,
    stack_mem: ?[]align(std.heap.page_size_min) u8 = null,
    ctx: *@import("context.zig").Context,
    scope: *TaskScope,
    cancellation_phase: CancellationPhase = .none,
    blocked_on_channel: ?*anyopaque = null,
    blocked_on_io_fd: ?std.posix.fd_t = null,
    blocked_on_scope: ?*TaskScope = null,
    /// Set by a sender when it delivers a value directly to this receiver's
    /// stack. The receiver checks and clears this on resume so it can
    /// distinguish a value handoff from a close-channel wake.
    value_delivered: bool = false,
    quotation: Quotation,
    /// Task that is waiting for this task to complete (via await).
    awaiting_task: ?*Task = null,
};

/// TaskScope tracks children and completion for structured concurrency.
pub const TaskScope = struct {
    children: std.ArrayListUnmanaged(*Task),
    /// The coordinator task that runs the task-scope body. Excluded from
    /// sibling cancellation so it can observe child failures via await.
    scope_task: ?*Task = null,
    /// Task that is waiting for the entire scope to complete.
    waiting_task: ?*Task = null,
    /// First child error, propagated to parent on scope exit.
    failed_error: ?ErrorObject = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) TaskScope {
        return .{
            .children = .{},
            .scope_task = null,
            .waiting_task = null,
            .failed_error = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TaskScope) void {
        self.children.deinit(self.allocator);
    }

    pub fn addChild(self: *TaskScope, task: *Task) !void {
        try self.children.append(self.allocator, task);
    }

    /// Check if all children have finished (completed, failed, or cancelled).
    pub fn allChildrenDone(self: *const TaskScope) bool {
        for (self.children.items) |child| {
            switch (child.status) {
                .completed, .failed, .cancelled => continue,
                .pending, .running => return false,
            }
        }
        return true;
    }
};

/// Allocate a native stack for a task using mmap with a guard page.
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

/// Free a task stack allocated by allocateTaskStack.
pub fn freeTaskStack(mem: []align(std.heap.page_size_min) u8) void {
    std.posix.munmap(mem);
}

/// Initialize a ucontext_t for a task, setting up the stack and entry function.
/// The entry function receives no arguments. The task pointer is passed via
/// a module-level variable, which should be safe because scheduling is single-
/// threaded cooperative.
pub fn initTaskContext(task: *Task, entry_fn: *const fn () callconv(.c) void, scheduler_uctx: *std.c.ucontext_t) void {
    const stack_mem = task.stack_mem.?;
    const page_size = std.heap.page_size_min;

    _ = c.getcontext(&task.uctx);
    task.uctx.stack.sp = @ptrCast(stack_mem.ptr + page_size);
    task.uctx.stack.size = @intCast(stack_mem.len - page_size);
    task.uctx.stack.flags = 0;
    task.uctx.link = scheduler_uctx;

    c.makecontext(&task.uctx, entry_fn, 0);
}
