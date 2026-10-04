const std = @import("std");
const builtin = @import("builtin");
const container_backing = @import("container_backing.zig");
const memory_limit = @import("memory_limit.zig");
const Allocator = std.mem.Allocator;
const Callable = @import("callable.zig").Callable;
const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const ErrorObject = value_mod.ErrorObject;

const is_freestanding = builtin.os.tag == .freestanding;

// Freestanding builds have no libc and no minicoro header to import; the
// freestanding scheduler is single-worker with no live coroutines, so this
// stub keeps the surrounding type references well-formed without ever
// being called.
const mc = if (is_freestanding) struct {
    // Not opaque: tasks.zig reads .stack_base/.stack_size off a real (if never-populated, since
    // mco_create below never actually allocates a coroutine) coro pointer to size the task's
    // native-stack bounds. Field names/types mirror the real struct in ext/minicoro/minicoro.h.
    pub const mco_coro = extern struct {
        stack_base: ?*anyopaque = null,
        stack_size: usize = 0,
    };
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
    pub fn mco_desc_init(func: ?*const fn (?*mco_coro) callconv(.c) void, stack_size: usize) callconv(.c) mco_desc {
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

/// The task whose coroutine this OS thread is currently resumed into, or null when the
/// thread is running outside any task.
///
/// A `Context` cannot answer this. One context is reachable from several worker threads at
/// once, since the C embedding API hands every host callback the same handle context
/// whichever worker it fires on. Its scheduler names whatever that scheduler is running,
/// not what this thread is. Only thread-local state can.
pub threadlocal var resumed_task: ?*Task = null;

/// Resume a task's coroutine from the calling (scheduler) context.
pub fn coroResume(task: *Task) void {
    const prev = resumed_task;
    resumed_task = task;
    defer resumed_task = prev;

    _ = mc.mco_resume(task.coro.?);
}

/// Yield the current coroutine back to its caller (the scheduler).
/// Must be called from within a running task coroutine.
pub fn coroYield() void {
    _ = mc.mco_yield(mc.mco_running());
}

/// Whether the calling code is running on `task`'s own coroutine stack, so a yield from here
/// actually switches.
///
/// `mco_yield` refuses a yield whose stack pointer lies outside the running coroutine's bounds,
/// and `coroYield` discards the refusal. The parser coroutine is the stack that trips this today:
/// parse-time execution inside a task runs on it. A task with no coroutine answers false.
pub fn runningOnOwnStack(task: *const Task) bool {
    const co = task.coro orelse return false;
    const sp = @frameAddress();
    const base = @intFromPtr(co.stack_base);
    return sp >= base and sp < base + co.stack_size;
}

/// Destroy a task's coroutine and clear the pointer.
pub fn coroDestroy(task: *Task) void {
    if (task.coro) |co| {
        _ = mc.mco_destroy(co);
        task.coro = null;
    }
}

/// Fold the pending unwind into `error_details` and box the failure for `task.error_obj`.
///
/// The fold must run on the worker that owns `ctx`, while the task's frames and arena are
/// still alive, which is the task's own teardown. The boxed object is the only thing that
/// crosses workers; the scope's collection deep-copies it and never reads this context.
///
/// Boxes from the folded innermost row when the fold produced one, else transfers the
/// thrown stash, else returns null for the caller's no-details fallback.
pub fn foldAndBoxTaskError(ctx: *Context, err: anyerror) ?*ErrorObject {
    ctx.finalizeErrorDetails(err);

    if (ctx.error_details.items.len > 0) {
        const detail = ctx.error_details.items[0];
        return value_mod.boxErrorObject(ctx.quotationAllocator(), .{
            .error_type = detail.error_type,
            .message = detail.message,
        }) catch null;
    }

    if (ctx.thrown_error) |thrown| {
        ctx.thrown_error = null;
        return thrown;
    }

    return null;
}

/// Entry function for task coroutines. Called by minicoro with the coroutine
/// pointer as the sole argument; reads the task pointer from user_data.
pub fn taskEntryPoint(co: CoroPtr) callconv(.c) void {
    const task: *Task = @ptrCast(@alignCast(mc.mco_get_user_data(co)));

    task.callable.executeWithFrame(task.ctx) catch |err| {
        task.error_obj = foldAndBoxTaskError(task.ctx, err);

        // The status reads the folded row rather than the boxed object, so an allocation
        // failure in the boxing cannot reclassify a genuine cancellation as a failure the
        // scope would propagate.
        const details = task.ctx.error_details.items;
        const error_type: []const u8 = if (details.len > 0)
            details[0].error_type
        else if (task.error_obj) |obj|
            obj.error_type
        else
            "";
        const cancelled = task.getCancellationPhase() != .none and
            std.mem.eql(u8, error_type, "task-cancelled");
        task.setStatus(if (cancelled) .cancelled else .failed);
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

/// A one-shot handshake between a waiter that suspends on some completion and the worker
/// (possibly a different one) that observes and delivers that completion.
///
/// Registering and completing are a check-then-store on both sides, run from different workers
/// with nothing else serializing them: a waiter checks a status, then stores itself so it can be
/// found and woken; the completer stores the terminal status, then reads the same slot to find
/// who to wake. Either order is possible, so one plain field cannot tell "nobody has registered
/// yet" apart from "someone already completed and there was nothing to wake." This type folds
/// both cases into one atomic word so a single CAS settles, for whichever side asks first,
/// whether it beat the other.
pub const WaiterSlot = struct {
    const empty: usize = 0;
    const done: usize = 1;

    state: std.atomic.Value(usize) = std.atomic.Value(usize).init(empty),

    /// Try to register `waiter` to be woken on completion. Returns `false` when completion has
    /// already been claimed, in which case the caller must not suspend: there is nothing left to
    /// wake it.
    pub fn tryRegister(self: *WaiterSlot, waiter: *Task) bool {
        return self.state.cmpxchgStrong(empty, @intFromPtr(waiter), .acq_rel, .acquire) == null;
    }

    /// Claim completion, returning the registered waiter if one beat completion to the slot.
    /// Idempotent: a second claim (from a racing completion source) always reads back `done`
    /// and returns null, so at most one caller ever receives the waiter.
    pub fn claim(self: *WaiterSlot) ?*Task {
        const prev = self.state.swap(done, .acq_rel);
        if (prev == empty or prev == done) return null;
        return @ptrFromInt(prev);
    }

    /// Read the currently registered waiter without claiming completion. For introspection only
    /// (deadlock-chain walks); a caller that intends to wake the waiter must use `claim` instead,
    /// since two readers of `peek` could otherwise both act on the same waiter.
    pub fn peek(self: *const WaiterSlot) ?*Task {
        const v = self.state.load(.acquire);
        if (v == empty or v == done) return null;
        return @ptrFromInt(v);
    }
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
    // Plain i32, not std.posix.fd_t/pid_t: see the comment on Scheduler.drainCancelledIOWaiters.
    blocked_on_io_fd: ?i32 = null,
    blocked_on_process_pid: ?i32 = null,
    blocked_on_process_key: ?u64 = null,
    blocked_on_scope: ?*TaskScope = null,
    // *LoadLock as anyopaque, matching blocked_on_channel's import-cycle avoidance.
    blocked_on_load_lock: ?*anyopaque = null,
    // *OnceCell as anyopaque, for the same reason as the two above.
    blocked_on_once_cell: ?*anyopaque = null,
    /// The task this one is suspended in `await` on.
    ///
    /// The reverse edge of `awaiting_slot`, which the awaited task carries. Only the forward
    /// edge is needed to deliver the wake; this one exists so a parked awaiter is visible as
    /// blocked rather than reading as runnable.
    blocked_on_await: ?*Task = null,
    /// Set by a sender when it delivers a value directly to this receiver's
    /// stack. The receiver checks and clears this on resume so it can
    /// distinguish a value handoff from a close-channel wake.
    value_delivered: bool = false,
    /// The body this task runs, with the reference behind it. Transferred from
    /// the spawner's popped slot and released at reap: a closure body must
    /// outlive the task that runs it.
    callable: Callable,
    peak_stack_usage: usize = 0,
    /// Task that is waiting for this task to complete (via await), registered through the
    /// register-vs-complete handshake described on `WaiterSlot`.
    awaiting_slot: WaiterSlot = .{},
    /// Set for a fire-and-forget task spawned with `spawn-detached`. A
    /// detached task is tracked in its scope's `detached` list, isolated
    /// from sibling cancellation, and reaped at its own completion.
    detached: bool = false,

    /// Whether this task is parked on a waitable only another task can satisfy.
    ///
    /// An io fd, a child process exit, and a timer are all driven from outside the scheduler,
    /// so a pool holding one of those is waiting rather than dead. A signal is not such a
    /// source: `checkPendingSignals` is reached from the interpreter execution loop and from
    /// compiled safepoints, never from the idle poll.
    ///
    /// Reads the markers directly instead of deriving a `Scheduler.TaskState`, so it never
    /// walks the home scheduler's sleep queue from a foreign worker. A sleeping task carries no
    /// marker, so skipping that walk cannot change the answer. The io and process early returns
    /// reproduce `taskState`'s precedence for a task carrying two markers at once.
    ///
    /// The caller still has to exclude the home scheduler's `current_task`: a sender sets
    /// `blocked_on_channel` before it suspends, so a running task can carry a marker.
    pub fn inProcessBlocked(self: *const Task) bool {
        if (self.blocked_on_io_fd != null) return false;
        if (self.blocked_on_process_pid != null) return false;
        return self.blocked_on_channel != null or
            self.blocked_on_scope != null or
            self.blocked_on_load_lock != null or
            self.blocked_on_once_cell != null or
            self.blocked_on_await != null;
    }

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
    /// Task that is waiting for the entire scope to complete, registered through the
    /// register-vs-complete handshake described on `WaiterSlot`.
    waiting_slot: WaiterSlot = .{},
    allocator: Allocator,
    /// Atomic count of children that have not yet finished.
    active_children: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Atomic flag set when a child fails and sibling cancellation triggers.
    cancellation_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// When true, the first child to finish with any status fires the
    /// sibling-cancellation cascade, not only a failing child. `with-timeout`
    /// sets this so its winner cancels the loser: the main task cancels the
    /// timer when it completes, and the timer cancels the main task when it
    /// fires.
    race_first_finisher: bool = false,
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

    pub fn init(allocator: Allocator) TaskScope {
        return .{
            .children = .{},
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
/// The entry function receives the mco_coro pointer and reads the task from user_data. The
/// coroutine's stack is `cfg.cap` bytes of reserved address space, of which only the top `cfg.base`
/// is committed. `co.stack_size` reports the whole reservation.
///
/// `cfg` is read only during creation, so it may live on the caller's stack.
pub fn initCoroContext(
    task: *Task,
    entry_fn: CoroEntryFn,
    cfg: *const TaskStackConfig,
) !void {
    var desc = mc.mco_desc_init(entry_fn, cfg.cap);
    desc.user_data = task;
    if (comptime !is_freestanding) {
        desc.alloc_cb = &reservingAlloc;
        desc.dealloc_cb = &reservingDealloc;
        desc.allocator_data = @constCast(cfg);
    }

    const result = mc.mco_create(&task.coro, &desc);
    if (result != mc.MCO_SUCCESS) return error.CoroCreationFailed;

    if (comptime !is_freestanding) assertMetadataCommitted(task.coro.?, desc.coro_size, cfg);
}

/// The geometry of a task's native stack: how much address space to reserve, and how much of it
/// to commit up front.
pub const TaskStackConfig = struct {
    /// Bytes reserved as minicoro's stack. A task can never run deeper than this.
    cap: usize,
    /// Bytes committed at the top of the reservation when the task is created.
    base: usize,
};

/// Bytes every task commits at creation, whatever its cap.
pub const task_stack_base: usize = 768 * 1024;

/// The cap when neither `--task-stack-cap` nor `ONEZ_TASK_STACK_CAP` sets one. It is the main
/// thread's own stack, so a task can go as deep as the main task can.
pub const default_task_stack_cap: usize = 16 * 1024 * 1024;

/// The smallest cap a user may ask for.
///
/// Invariant: a grown task holds an eighth of its cap back as the guard's reserve, and that reserve
/// has to clear the metadata page and the permanent guard page while staying below the committed
/// base. `taskStackGrowth` debug-asserts the same two inequalities for every task it arms.
pub const min_task_stack_cap: usize = 1024 * 1024;

// Freestanding keeps a fixed allocation and has no page size to check against.
comptime {
    if (!is_freestanding) {
        const page = std.heap.page_size_max;
        std.debug.assert(min_task_stack_cap / 8 >= 2 * page);
        std.debug.assert(page + min_task_stack_cap / 8 < min_task_stack_cap - task_stack_base);
    }
}

/// Turn a requested cap into the one a task reserves: rounded up to `page`, or null when it is below
/// `min_task_stack_cap` or rounding would overflow.
pub fn resolveTaskStackCap(requested: usize, page: usize) ?usize {
    if (requested < min_task_stack_cap) return null;
    if (requested > std.math.maxInt(usize) - (page - 1)) return null;

    return std.mem.alignForward(usize, requested, page);
}

/// What a rejected `--task-stack-cap` or `ONEZ_TASK_STACK_CAP` value should have been.
pub const task_stack_cap_expectation = "expected a size of at least 1M";

/// Parse a user-supplied cap such as `4M` and resolve it against this process's page size.
pub fn parseTaskStackCap(text: []const u8) ?usize {
    const requested = memory_limit.parseSize(text) orelse return null;
    return resolveTaskStackCap(requested, std.heap.pageSize());
}

/// Where the protection boundaries fall inside one reserved coroutine block.
///
/// Addresses ascend left to right:
///
///     [coro][ctx][storage] |guard| ...... PROT_NONE ...... | committed base |
///     ^ block      meta_end ^     ^ guard_end   base_low ^      block_end ^
///
/// `[block, meta_end)` and `[base_low, block_end)` are read-write. Everything between them is
/// `PROT_NONE`. The single page at `[meta_end, guard_end)` stays `PROT_NONE` for the task's life,
/// so a frame that leaps past the software guard faults instead of overwriting the coroutine
/// struct.
pub const TaskStackLayout = struct {
    meta_end: usize,
    guard_end: usize,
    base_low: usize,
    block_end: usize,
};

/// Compute the protection boundaries for a block of `coro_size` bytes at `block`, as minicoro
/// requested it for a stack of `cfg.cap` bytes. Returns null when the metadata, the guard page,
/// and the committed base cannot all fit.
///
/// The callback has to commit minicoro's metadata before minicoro has said where it ends.
/// `coro_size - cap` is minicoro's own allowance for everything that is not stack, so it bounds the
/// metadata from above without restating minicoro's layout.
///
/// The stack starts at or above `block`, so its top `base` bytes start at or above
/// `block + cap - base`. Committing down to there covers them wherever minicoro places the stack
/// within its allowance, at the cost of at most the metadata size plus a page.
pub fn taskStackLayout(block: usize, coro_size: usize, cfg: TaskStackConfig, page: usize) ?TaskStackLayout {
    if (coro_size < cfg.cap or cfg.cap < cfg.base) return null;

    const meta_end = std.mem.alignForward(usize, block + (coro_size - cfg.cap), page);
    const guard_end = meta_end + page;
    const base_low = std.mem.alignBackward(usize, block + cfg.cap - cfg.base, page);
    const block_end = block + std.mem.alignForward(usize, coro_size, page);

    if (guard_end > base_low) return null;

    return .{
        .meta_end = meta_end,
        .guard_end = guard_end,
        .base_low = base_low,
        .block_end = block_end,
    };
}

/// minicoro `alloc_cb` for task coroutines. Reserves the whole block `PROT_NONE`, then commits the
/// metadata at the low end and the base stack at the high end.
///
/// Returning null makes `mco_create` report `MCO_OUT_OF_MEMORY`.
fn reservingAlloc(size: usize, allocator_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const cfg: *const TaskStackConfig = @ptrCast(@alignCast(allocator_data orelse return null));
    const page = std.heap.pageSize();

    const mem = std.posix.mmap(
        null,
        std.mem.alignForward(usize, size, page),
        std.posix.PROT.NONE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return null;

    const block = @intFromPtr(mem.ptr);
    const layout = taskStackLayout(block, size, cfg.*, page) orelse {
        std.posix.munmap(mem);
        return null;
    };

    const rw = std.posix.PROT.READ | std.posix.PROT.WRITE;
    std.posix.mprotect(mem[0 .. layout.meta_end - block], rw) catch {
        std.posix.munmap(mem);
        return null;
    };
    std.posix.mprotect(@alignCast(mem[layout.base_low - block ..]), rw) catch {
        std.posix.munmap(mem);
        return null;
    };

    return mem.ptr;
}

/// minicoro `dealloc_cb` paired with `reservingAlloc`. Unmaps the whole reservation whatever its
/// protection.
///
/// `allocator_data` is the creation-time config, which no longer exists by now, so it must not be
/// read here.
fn reservingDealloc(ptr: ?*anyopaque, size: usize, allocator_data: ?*anyopaque) callconv(.c) void {
    _ = allocator_data;
    const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(ptr orelse return));
    std.posix.munmap(base[0..std.mem.alignForward(usize, size, std.heap.pageSize())]);
}

/// Debug-only check that minicoro laid the coroutine out inside the spans `reservingAlloc`
/// committed.
///
/// Invariant: the coroutine struct, its context, and its storage end at or below `meta_end`, and the
/// top `cfg.base` bytes of the stack lie inside the committed base. `taskStackLayout` derives both
/// spans from `coro_size` alone, before minicoro has placed anything. A minicoro whose metadata
/// outgrew `coro_size - cap`, or that placed the stack elsewhere, would fault on first touch rather
/// than here.
fn assertMetadataCommitted(co: *mc.mco_coro, coro_size: usize, cfg: *const TaskStackConfig) void {
    if (comptime builtin.mode != .Debug) return;

    const block = @intFromPtr(co);
    const layout = taskStackLayout(block, coro_size, cfg.*, std.heap.pageSize()).?;
    const stack_base = @intFromPtr(co.stack_base);
    const stack_top = stack_base + co.stack_size;

    std.debug.assert(stack_base <= layout.meta_end);
    std.debug.assert(co.stack_size == cfg.cap);
    std.debug.assert(stack_top - cfg.base >= layout.base_low);
    std.debug.assert(stack_top <= layout.block_end);
}

/// What a task's stack becomes when it grows: the span to commit, and the bounds the guard is
/// re-armed over afterward.
///
/// `[commit_low, commit_high)` is everything between the permanent guard page and the committed
/// base. `stack_low` is the bottom of the whole reservation, so the grown stack's size is the cap.
pub const TaskStackGrowth = struct {
    commit_low: usize,
    commit_high: usize,
    stack_low: usize,
    stack_limit: usize,
};

/// The growth for a coroutine `reservingAlloc` laid out under `cfg`, holding `reserve` bytes back
/// above the bottom of the reservation as the grown guard's reserve.
pub fn taskStackGrowth(co: *mc.mco_coro, cfg: *const TaskStackConfig, reserve: usize) TaskStackGrowth {
    const layout = taskStackLayout(@intFromPtr(co), co.coro_size, cfg.*, std.heap.pageSize()).?;
    const stack_low = @intFromPtr(co.stack_base);

    const growth = TaskStackGrowth{
        .commit_low = layout.guard_end,
        .commit_high = layout.base_low,
        .stack_low = stack_low,
        .stack_limit = stack_low + reserve,
    };

    // The grown guard has to fire while the frame is still inside the span this growth commits,
    // or the reserve would sit over the permanent guard page.
    std.debug.assert(growth.commit_low < growth.stack_limit);
    std.debug.assert(growth.stack_limit < growth.commit_high);
    return growth;
}

/// Commit the span `growth` names read-write. Residency is untouched: the pages still fault in on
/// first touch.
pub fn commitTaskStackGrowth(growth: TaskStackGrowth) !void {
    if (comptime is_freestanding) return error.Unsupported;

    const low: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(growth.commit_low);
    try std.posix.mprotect(low[0 .. growth.commit_high - growth.commit_low], std.posix.PROT.READ | std.posix.PROT.WRITE);
}

/// Allocate a native stack for a parser coroutine using mmap with a guard page.
/// Returns the full allocation of guard plus usable.
///
/// Layout: [guard page (PROT_NONE)] [usable stack space]
///
/// Never called on freestanding targets: the parser coroutine that owns this stack is unusable
/// there (no ucontext), and StatementProcessor's freestanding path never allocates one.
pub fn allocateTaskStack(size: usize) ![]align(std.heap.page_size_min) u8 {
    if (comptime is_freestanding) unreachable;

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

/// Free a stack allocated by allocateTaskStack. Never called on freestanding targets; see
/// allocateTaskStack.
pub fn freeTaskStack(mem: []align(std.heap.page_size_min) u8) void {
    if (comptime is_freestanding) unreachable;

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
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
    };
    var t1 = Task{
        .id = 2,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.pending),
        .ctx = undefined,
        .scope = &scope,
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
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
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
    };
    var t1 = Task{
        .id = 2,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.failed),
        .error_obj = &first,
        .ctx = undefined,
        .scope = &scope,
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
    };
    var t2 = Task{
        .id = 3,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.failed),
        .error_obj = &second,
        .ctx = undefined,
        .scope = &scope,
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
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
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
    };
    var t1 = Task{
        .id = 2,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.cancelled),
        .ctx = undefined,
        .scope = &scope,
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
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
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
    };
    var t1 = Task{
        .id = 2,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.completed),
        .ctx = undefined,
        .scope = &scope,
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
    };
    var t2 = Task{
        .id = 3,
        .name = null,
        .status = std.atomic.Value(TaskStatus).init(.failed),
        .error_obj = &err,
        .ctx = undefined,
        .scope = &scope,
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
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
        .callable = .{ .quot = .{ .instructions = &.{}, .effect = null }, .owner = .unit },
    };

    publishTaskResult(&task);

    try std.testing.expectEqual(TaskStatus.failed, task.getStatus());
    try std.testing.expect(task.result == null);
    try std.testing.expect(task.error_obj != null);
    try std.testing.expectEqualStrings("borrowed-buffer-escape", task.error_obj.?.error_type);
}

test "foldAndBoxTaskError folds the pended unwind before boxing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.appendPendingSyntheticErrorFrame("boom", "<test>", 7, null);
    ctx.pending_error_message = "boom went wrong";

    const boxed = foldAndBoxTaskError(&ctx, error.TypeMismatch);

    try std.testing.expect(boxed != null);
    try std.testing.expectEqualStrings("type-mismatch", boxed.?.error_type);
    try std.testing.expectEqualStrings("boom went wrong", boxed.?.message);
    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
}

test "foldAndBoxTaskError transfers the thrown box when nothing folds" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const thrown = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "task-cancelled",
        .message = "task was cancelled",
    });
    ctx.thrown_error = thrown;

    const boxed = foldAndBoxTaskError(&ctx, error.UserThrown);

    try std.testing.expectEqual(thrown, boxed.?);
    try std.testing.expect(ctx.thrown_error == null);
}

test "foldAndBoxTaskError returns null with nothing to box" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expect(foldAndBoxTaskError(&ctx, error.TypeMismatch) == null);
}

test "taskStackLayout commits the metadata and the base around a one-page guard" {
    const cfg = TaskStackConfig{ .cap = 16 * 1024 * 1024, .base = 768 * 1024 };
    const metadata = 1536;
    const coro_size = metadata + cfg.cap;

    for ([_]usize{ 4096, 16384 }) |page| {
        const block: usize = 64 * page;
        const layout = taskStackLayout(block, coro_size, cfg, page).?;

        try std.testing.expect(layout.meta_end >= block + metadata);
        try std.testing.expectEqual(@as(usize, 0), layout.meta_end % page);
        try std.testing.expectEqual(layout.meta_end + page, layout.guard_end);
        try std.testing.expect(layout.guard_end <= layout.base_low);

        // The stack's top `base` bytes are committed wherever minicoro starts the stack within
        // its metadata allowance.
        try std.testing.expect(layout.base_low <= block + cfg.cap - cfg.base);
        try std.testing.expect(layout.block_end >= block + coro_size);
        try std.testing.expectEqual(@as(usize, 0), layout.block_end % page);
    }
}

test "resolveTaskStackCap accepts the floor and refuses anything below it" {
    try std.testing.expectEqual(@as(?usize, min_task_stack_cap), resolveTaskStackCap(min_task_stack_cap, 4096));
    try std.testing.expectEqual(@as(?usize, null), resolveTaskStackCap(min_task_stack_cap - 1, 4096));
    try std.testing.expectEqual(@as(?usize, null), resolveTaskStackCap(0, 4096));
}

test "resolveTaskStackCap rounds a cap up to the page size" {
    try std.testing.expectEqual(@as(?usize, 2_015_232), resolveTaskStackCap(2_000_000, 16384));
    try std.testing.expectEqual(@as(?usize, default_task_stack_cap), resolveTaskStackCap(default_task_stack_cap, 16384));
}

test "resolveTaskStackCap refuses a cap whose rounding would overflow" {
    try std.testing.expectEqual(@as(?usize, null), resolveTaskStackCap(std.math.maxInt(usize) - 1, 4096));
}

test "taskStackLayout refuses a cap too small for the metadata, guard, and base" {
    const page = 16384;
    const cfg = TaskStackConfig{ .cap = 768 * 1024, .base = 768 * 1024 };

    try std.testing.expect(taskStackLayout(64 * page, 1536 + cfg.cap, cfg, page) == null);
    try std.testing.expect(taskStackLayout(64 * page, cfg.cap - 1, cfg, page) == null);
}

fn noopCoroEntry(co: CoroPtr) callconv(.c) void {
    _ = co;
}

test "reserving allocator sizes the coroutine stack to the cap and commits its base" {
    if (comptime is_freestanding) return error.SkipZigTest;

    const cfg = TaskStackConfig{ .cap = 16 * 1024 * 1024, .base = 768 * 1024 };
    var desc = mc.mco_desc_init(&noopCoroEntry, cfg.cap);
    desc.alloc_cb = &reservingAlloc;
    desc.dealloc_cb = &reservingDealloc;
    desc.allocator_data = @constCast(&cfg);

    var co: ?*mc.mco_coro = null;
    try std.testing.expectEqual(@as(c_uint, mc.MCO_SUCCESS), mc.mco_create(&co, &desc));
    assertMetadataCommitted(co.?, desc.coro_size, &cfg);

    try std.testing.expectEqual(cfg.cap, co.?.stack_size);

    const stack_top = @intFromPtr(co.?.stack_base) + co.?.stack_size;
    const top: *volatile u8 = @ptrFromInt(stack_top - 1);
    const base_low: *volatile u8 = @ptrFromInt(stack_top - cfg.base);
    top.* = 0xa5;
    base_low.* = 0x5a;
    try std.testing.expectEqual(@as(u8, 0xa5), top.*);
    try std.testing.expectEqual(@as(u8, 0x5a), base_low.*);

    try std.testing.expectEqual(@as(c_uint, mc.MCO_SUCCESS), mc.mco_destroy(co));
}

test "a task's guard grows its stack once, then raises only at or below the grown limit" {
    if (comptime is_freestanding) return error.SkipZigTest;

    const cfg = TaskStackConfig{ .cap = 16 * 1024 * 1024, .base = 768 * 1024 };
    var desc = mc.mco_desc_init(&noopCoroEntry, cfg.cap);
    desc.alloc_cb = &reservingAlloc;
    desc.dealloc_cb = &reservingDealloc;
    desc.allocator_data = @constCast(&cfg);

    var co: ?*mc.mco_coro = null;
    try std.testing.expectEqual(@as(c_uint, mc.MCO_SUCCESS), mc.mco_create(&co, &desc));
    defer _ = mc.mco_destroy(co);

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const growth = taskStackGrowth(co.?, &cfg, cfg.cap / 8);
    ctx.stack_high = @intFromPtr(co.?.stack_base) + co.?.stack_size;
    ctx.stack_low = ctx.stack_high - cfg.base;
    ctx.stack_limit = ctx.stack_low + cfg.base / 8;
    ctx.stack_floor = growth.stack_limit;
    ctx.stack_growth = growth;

    const base_limit = ctx.stack_limit;
    try std.testing.expect(!ctx.stackExhausted(base_limit + 1));
    try std.testing.expectEqual(base_limit, ctx.stack_limit);

    try std.testing.expect(!ctx.stackExhausted(base_limit));
    try std.testing.expectEqual(growth.stack_limit, ctx.stack_limit);
    try std.testing.expectEqual(growth.stack_limit, ctx.stack_floor);
    try std.testing.expectEqual(growth.stack_low, ctx.stack_low);
    try std.testing.expectEqual(@as(?TaskStackGrowth, null), ctx.stack_growth);
    try std.testing.expectEqual(cfg.cap - cfg.cap / 8, ctx.stack_high - ctx.stack_limit);

    const low: *volatile u8 = @ptrFromInt(growth.commit_low);
    const high: *volatile u8 = @ptrFromInt(growth.commit_high - 1);
    low.* = 0xa5;
    high.* = 0x5a;
    try std.testing.expectEqual(@as(u8, 0xa5), low.*);
    try std.testing.expectEqual(@as(u8, 0x5a), high.*);

    try std.testing.expect(ctx.stackExhausted(growth.stack_limit));
    try std.testing.expectEqual(growth.stack_limit, ctx.stack_limit);
}
