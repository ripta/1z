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
const MAX_SIGNALS = 32;

/// Per-signal atomic pending flags. Index 0 is unused.
var signal_pending: [MAX_SIGNALS]std.atomic.Value(bool) = blk: {
    var arr: [MAX_SIGNALS]std.atomic.Value(bool) = undefined;
    for (&arr) |*slot| slot.* = std.atomic.Value(bool).init(false);
    break :blk arr;
};

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

/// Generic async-signal-safe handler. Sets the pending flag for the
/// received signal. For SIGINT, a second signal while the first is
/// still pending force-terminates (exit 130).
fn handleSignal(signum: c_int) callconv(.c) void {
    const idx: usize = if (signum >= 0 and signum < MAX_SIGNALS)
        @intCast(signum)
    else
        return;

    if (signum == SIG.INT and signal_pending[idx].load(.acquire)) {
        posix.exit(130);
    }
    signal_pending[idx].store(true, .release);
}

/// Install OS signal handlers. Call once at startup.
///
/// - SIGINT: sets atomic flag, checked at interpreter safe points.
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
    signal_pending[signum].store(false, .release);
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

/// Check all pending signal flags and dispatch handlers.
///
/// Called at interpreter safe points (executeInstructions, jitSafepoint).
/// For each pending signal:
/// - If a user handler is registered: push signal number, execute handler.
/// - If no handler and signal is SIGINT: raise "interrupted" error.
/// - If no handler and not SIGINT: consume and ignore.
pub fn checkPendingSignals(ctx: *Context) error{UserThrown}!void {
    // No OS signal delivery on freestanding targets, and signal.install() (the only thing that
    // could ever mark a signal pending) is wired up only from main.zig, not built for this
    // target -- signal_pending stays all-false forever there, so this is a no-op. Comptime-gated
    // so posix.SIG (undefined on the non-libc posix stub) need not compile for that target.
    if (comptime is_freestanding) return;

    for (1..MAX_SIGNALS) |i| {
        if (signal_pending[i].load(.acquire)) {
            signal_pending[i].store(false, .release);

            if (retainUserHandler(@intCast(i))) |handler| {
                defer handler.release();
                ctx.stack.push(.{ .fixnum = @intCast(i) }) catch return;

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
            } else if (i == @as(usize, @intCast(SIG.INT))) {
                ctx.thrown_error = value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                    .error_type = "interrupted",
                    .message = "interrupted by signal",
                }) catch return error.UserThrown;
                return error.UserThrown;
            }
            // Other signals with no handler: consume and ignore.
        }
    }
}

/// Clear all pending signal state. Called after the REPL catches an
/// error so the next iteration starts clean.
pub fn reset() void {
    for (1..MAX_SIGNALS) |i| {
        signal_pending[i].store(false, .release);
    }
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

    signal_pending[@intCast(SIG.INT)].store(true, .release);
    defer signal_pending[@intCast(SIG.INT)].store(false, .release);

    const result = checkPendingSignals(&ctx);
    try testing.expectError(error.UserThrown, result);
    try testing.expect(ctx.thrown_error != null);
    try testing.expectEqualStrings("interrupted", ctx.thrown_error.?.error_type);
    try testing.expectEqualStrings("interrupted by signal", ctx.thrown_error.?.message);
    // Flag should be cleared after consumption
    try testing.expect(!signal_pending[@intCast(SIG.INT)].load(.acquire));
}

test "checkPendingSignals ignores non-SIGINT with no user handler" {
    var ctx = testContext();
    defer ctx.deinit();

    signal_pending[@intCast(SIG.TERM)].store(true, .release);
    defer signal_pending[@intCast(SIG.TERM)].store(false, .release);

    try checkPendingSignals(&ctx);
    try testing.expect(ctx.thrown_error == null);
    // Flag should be cleared
    try testing.expect(!signal_pending[@intCast(SIG.TERM)].load(.acquire));
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

    signal_pending[signum].store(true, .release);
    defer signal_pending[signum].store(false, .release);

    try checkPendingSignals(&ctx);

    try testing.expectEqualStrings("body failed", ctx.pending_error_message.?);
    try testing.expectEqual(@as(usize, 1), ctx.jit_pending_trace_frames.items.len);
    try testing.expectEqualStrings("boom", ctx.jit_pending_trace_frames.items[0].word_name);
}

test "reset clears all pending flags" {
    signal_pending[@intCast(SIG.INT)].store(true, .release);
    signal_pending[@intCast(SIG.TERM)].store(true, .release);
    reset();
    try testing.expect(!signal_pending[@intCast(SIG.INT)].load(.acquire));
    try testing.expect(!signal_pending[@intCast(SIG.TERM)].load(.acquire));
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
