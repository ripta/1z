const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Context = @import("context.zig").Context;
const container_backing = @import("container_backing.zig");
const value_mod = @import("value.zig");
const Callable = @import("callable.zig").Callable;

const is_freestanding = builtin.os.tag == .freestanding;

const SIG = posix.SIG;

/// Maximum number of signals supported. POSIX signals range from 1 to 31.
///
/// `signal_pending` is a u32, so raising this alone would not widen the pending mask; a wider
/// ceiling needs a wider word or several of them.
const MAX_SIGNALS = 32;

/// Pending signals, one bit per signal number. Bit 0 is unused.
///
/// The word is the whole of the pending state. A design that put an aggregate "any pending" flag
/// beside a per-signal table would carry two pieces of state that have to agree, and a lost
/// wake-up whenever they do not. One object makes that unrepresentable.
var signal_pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// The mask bit carrying one signal's pending state.
inline fn signalBit(signum: u6) u32 {
    return @as(u32, 1) << @as(u5, @intCast(signum));
}

/// Clear one signal's pending bit.
fn clearPending(signum: u6) void {
    _ = signal_pending.fetchAnd(~signalBit(signum), .release);
}

/// Per-signal user handlers. null means no user handler.
///
/// The table owns each entry: registration transfers the popped reference in, and replacement,
/// clearing, and root-context teardown release it. That is what keeps a handler's body alive for
/// as long as the table can dispatch it, including a handler registered inside a task that has
/// since been reaped.
///
/// Guarded by `handlers_mutex`, since registration can run on any worker and dispatch reads at
/// every worker's safe points. The mutex is a leaf: nothing that locks is called while it is
/// held, and handler bodies execute only after it is released.
var user_handlers: [MAX_SIGNALS]?Callable = .{null} ** MAX_SIGNALS;
var handlers_mutex: std.Thread.Mutex = .{};

/// Previous sigaction states for restoring defaults on removeHandler.
var prev_actions: [MAX_SIGNALS]?posix.Sigaction = .{null} ** MAX_SIGNALS;

/// Generic async-signal-safe handler. Sets the pending bit for the
/// received signal. For SIGINT, a second signal while the first is
/// still pending force-terminates (exit 130).
///
/// The second-SIGINT test reads the mask `fetchOr` returns, so the test and the set are one
/// atomic operation and a concurrent delivery cannot slip between them.
fn handleSignal(signum: c_int) callconv(.c) void {
    if (signum <= 0 or signum >= MAX_SIGNALS) return;

    const bit = signalBit(@intCast(signum));
    const before = signal_pending.fetchOr(bit, .release);

    if (signum == SIG.INT and before & bit != 0) {
        posix.exit(130);
    }
}

/// Install OS signal handlers. Call once at startup.
///
/// - SIGINT: sets its pending bit, checked at interpreter safe points.
///   Second SIGINT while first is pending force-terminates (exit 130).
/// - SIGPIPE: ignored (SIG_IGN) to prevent crashes on broken pipes.
pub fn install() void {
    installHandler(@intCast(SIG.INT));

    const sigpipe_act: posix.Sigaction = .{
        .handler = .{ .handler = SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(SIG.PIPE, &sigpipe_act, null);
}

/// Install our generic handler for the given signal number, saving
/// the previous action for later restoration.
pub fn installHandler(signum: u6) void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var old: posix.Sigaction = undefined;
    posix.sigaction(@intCast(signum), &act, &old);
    handlers_mutex.lock();
    defer handlers_mutex.unlock();
    prev_actions[signum] = old;
}

/// Restore the previous OS signal action and clear the user handler.
pub fn removeHandler(signum: u6) void {
    handlers_mutex.lock();
    if (prev_actions[signum]) |old| {
        posix.sigaction(@intCast(signum), &old, null);
        prev_actions[signum] = null;
    }
    const displaced = user_handlers[signum];
    user_handlers[signum] = null;
    handlers_mutex.unlock();
    if (displaced) |d| d.release();
    clearPending(signum);
}

/// Register a user handler for a signal, transferring ownership of `handler` into the table.
/// The displaced entry, if any, is released.
pub fn setUserHandler(signum: u6, handler: ?Callable) void {
    handlers_mutex.lock();
    const displaced = user_handlers[signum];
    user_handlers[signum] = handler;
    handlers_mutex.unlock();
    if (displaced) |d| d.release();
}

/// Retain and return the handler for a signal, or null. The caller owns the returned copy and
/// releases it after use, so a concurrent clear cannot free the body out from under a dispatch
/// or a read-back.
pub fn retainUserHandler(signum: u6) ?Callable {
    handlers_mutex.lock();
    defer handlers_mutex.unlock();
    const h = user_handlers[signum] orelse return null;
    container_backing.retainValue(h.owner);
    return h;
}

/// Release every registered handler and clear the table. Called at root-context teardown, before
/// the allocators behind the handler bodies go away.
pub fn releaseUserHandlers() void {
    for (0..MAX_SIGNALS) |i| {
        setUserHandler(@intCast(i), null);
    }
}

/// Returns true if the signal number is valid and can be caught
/// (not SIGKILL or SIGSTOP).
pub fn isHandleable(signum: i64) bool {
    if (signum < 1 or signum >= MAX_SIGNALS) return false;
    const s: u6 = @intCast(signum);
    if (s == SIG.KILL or s == SIG.STOP) return false;
    return true;
}

/// Check the pending-signal mask, and dispatch handlers when it is not empty.
///
/// Called at interpreter safe points (executeInstructions, jitSafepoint), which is once per word
/// call. Inlined so that a safe point carries the load and the test alone, with no frame and no
/// call on the common path.
///
/// The filter loads `.monotonic` because the bit carries no payload. A handler body is reached
/// through `retainUserHandler`, whose visibility comes from `handlers_mutex`. An ordered load here
/// would synchronize-with nothing and would cost an `ldapr` in place of an `ldr` on arm64.
pub inline fn checkPendingSignals(ctx: *Context) error{UserThrown}!void {
    // No OS signal delivery on freestanding targets, and signal.install() (the only thing that
    // could ever mark a signal pending) is wired up only from main.zig, not built for this
    // target -- the mask stays zero forever there, so this is a no-op. Comptime-gated so
    // posix.SIG (undefined on the non-libc posix stub) need not compile for that target.
    if (comptime is_freestanding) return;

    if (signal_pending.load(.monotonic) == 0) return;
    return dispatchPendingSignals(ctx);
}

/// Consume every pending signal and dispatch it. For each one:
/// - If a user handler is registered: push signal number, execute handler.
/// - If no handler and signal is SIGINT: raise "interrupted" error.
/// - If no handler and not SIGINT: consume and ignore.
///
/// Loads the mask for itself rather than taking the filter's relaxed value. This `.acquire` is
/// what synchronizes-with the handler's `.release` store, so a payload written beside the bit
/// would be ordered on the only path that could ever read one.
noinline fn dispatchPendingSignals(ctx: *Context) error{UserThrown}!void {
    @branchHint(.cold);

    // The walk runs over the loaded snapshot rather than re-reading, which bounds a pass at 31
    // iterations under a storm. A delivery arriving mid-pass keeps its bit for the next safe
    // point.
    //
    // @ctz yields the lowest bit first, so signals are handled in ascending order.
    //
    // Only a consumed bit is cleared, so a handler that throws leaves the rest pending.
    var mask = signal_pending.load(.acquire);
    while (mask != 0) {
        const signum: u5 = @intCast(@ctz(mask));
        mask &= ~signalBit(signum);
        clearPending(signum);

        if (retainUserHandler(signum)) |handler| {
            defer handler.release();
            ctx.stack.push(.{ .fixnum = signum }) catch return;

            // A dropped handler error must not bleed into whatever the interrupted program
            // raises next. A user throw is the exception: it propagates from here, so the
            // state that raise wrote belongs to it and is left in place.
            const saved_error_state = ctx.saveErrorState();
            const handler_failed = if (ctx.executeQuotationWithOwner(handler.quot, handler.ownerClosure())) |_|
                false
            else |err| blk: {
                if (err == error.UserThrown) return error.UserThrown;
                break :blk true;
            };
            ctx.restoreErrorState(saved_error_state);

            if (handler_failed) return;
        } else if (signum == SIG.INT) {
            ctx.thrown_error = value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                .error_type = "interrupted",
                .message = "interrupted by signal",
            }) catch return error.UserThrown;
            return error.UserThrown;
        }
        // Other signals with no handler: consume and ignore.
    }
}

/// Clear all pending signal state. Called after the REPL catches an
/// error so the next iteration starts clean.
pub fn reset() void {
    signal_pending.store(0, .release);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "checkPendingSignals returns cleanly when no signal pending" {
    var ctx = testContext();
    defer ctx.deinit();

    try checkPendingSignals(&ctx);
    try testing.expect(ctx.thrown_error == null);
}

test "checkPendingSignals fires for SIGINT when no user handler" {
    var ctx = testContext();
    defer ctx.deinit();

    markPending(@intCast(SIG.INT));
    defer clearPending(@intCast(SIG.INT));

    const result = checkPendingSignals(&ctx);
    try testing.expectError(error.UserThrown, result);
    try testing.expect(ctx.thrown_error != null);
    try testing.expectEqualStrings("interrupted", ctx.thrown_error.?.error_type);
    try testing.expectEqualStrings("interrupted by signal", ctx.thrown_error.?.message);
    try testing.expect(!isPending(@intCast(SIG.INT)));
}

test "checkPendingSignals ignores non-SIGINT with no user handler" {
    var ctx = testContext();
    defer ctx.deinit();

    markPending(@intCast(SIG.TERM));
    defer clearPending(@intCast(SIG.TERM));

    try checkPendingSignals(&ctx);
    try testing.expect(ctx.thrown_error == null);
    try testing.expect(!isPending(@intCast(SIG.TERM)));
}

test "checkPendingSignals consumes every set bit in one pass, lowest first" {
    var ctx = testContext();
    defer ctx.deinit();

    const low: u6 = @intCast(SIG.HUP);
    const high: u6 = @intCast(SIG.TERM);
    try testing.expect(low < high);

    // An empty handler body leaves the signal number the dispatch pushed for it, so the stack
    // reads back the order the two were consumed in.
    const empty = Callable{ .quot = .{ .instructions = &.{} }, .owner = .unit };
    setUserHandler(low, empty);
    defer setUserHandler(low, null);
    setUserHandler(high, empty);
    defer setUserHandler(high, null);

    markPending(low);
    defer clearPending(low);
    markPending(high);
    defer clearPending(high);

    try checkPendingSignals(&ctx);

    try testing.expect(!isPending(low));
    try testing.expect(!isPending(high));
    try testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try testing.expectEqual(@as(i64, low), (try ctx.stack.peekN(1)).fixnum);
    try testing.expectEqual(@as(i64, high), (try ctx.stack.peekN(0)).fixnum);
}

test "a swallowed handler error gives back the state it overwrote" {
    var ctx = testContext();
    defer ctx.deinit();

    const instrs = try ctx.quotationAllocator().alloc(value_mod.Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "nonexistent-word-for-signal-shield-test" }, .line = 1 };

    const signum: u6 = @intCast(SIG.TERM);
    setUserHandler(signum, .{ .quot = .{ .instructions = instrs }, .owner = .unit });
    defer setUserHandler(signum, null);

    ctx.pending_error_message = "body failed";
    ctx.appendPendingSyntheticErrorFrame("boom", "<test>", 4, null);

    markPending(signum);
    defer clearPending(signum);

    try checkPendingSignals(&ctx);

    try testing.expectEqualStrings("body failed", ctx.pending_error_message.?);
    try testing.expectEqual(@as(usize, 1), ctx.jit_pending_trace_frames.items.len);
    try testing.expectEqualStrings("boom", ctx.jit_pending_trace_frames.items[0].word_name);
}

test "reset clears every pending bit" {
    markPending(@intCast(SIG.INT));
    markPending(@intCast(SIG.TERM));
    reset();
    try testing.expectEqual(@as(u32, 0), signal_pending.load(.acquire));
}

test "isHandleable rejects invalid signals" {
    try testing.expect(!isHandleable(0));
    try testing.expect(!isHandleable(-1));
    try testing.expect(!isHandleable(32));
    try testing.expect(!isHandleable(SIG.KILL));
    try testing.expect(!isHandleable(SIG.STOP));
    try testing.expect(isHandleable(SIG.INT));
    try testing.expect(isHandleable(SIG.TERM));
    try testing.expect(isHandleable(SIG.HUP));
}

test "install does not crash" {
    install();
}

test "user handler storage round-trips" {
    const signum: u6 = @intCast(SIG.TERM);
    try testing.expect(retainUserHandler(signum) == null);

    const dummy = Callable{ .quot = .{ .instructions = &.{} }, .owner = .unit };
    setUserHandler(signum, dummy);
    const got = retainUserHandler(signum);
    try testing.expect(got != null);
    got.?.release();

    setUserHandler(signum, null);
    try testing.expect(retainUserHandler(signum) == null);
}

fn testContext() Context {
    return Context.init(testing.allocator);
}

/// Stand in for a delivery, so a test need not raise a real signal to reach the dispatch path.
fn markPending(signum: u6) void {
    _ = signal_pending.fetchOr(signalBit(signum), .release);
}

fn isPending(signum: u6) bool {
    return signal_pending.load(.acquire) & signalBit(signum) != 0;
}
