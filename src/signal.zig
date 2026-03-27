const std = @import("std");
const posix = std.posix;

const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");

var sigint_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn handleSigint(_: c_int) callconv(.c) void {
    if (sigint_pending.load(.acquire)) {
        posix.exit(130);
    }
    sigint_pending.store(true, .release);
}

/// Install OS signal handlers. Call once at startup.
///
/// - SIGINT: sets atomic flag, checked at interpreter safe points.
///   Second SIGINT while first is pending force-terminates (exit 130).
/// - SIGPIPE: ignored (SIG_IGN) to prevent crashes on broken pipes.
pub fn install() void {
    const SIG = posix.SIG;

    const sigint_act: posix.Sigaction = .{
        .handler = .{ .handler = handleSigint },
        .mask = 0,
        .flags = 0,
    };
    posix.sigaction(SIG.INT, &sigint_act, null);

    const sigpipe_act: posix.Sigaction = .{
        .handler = .{ .handler = SIG.IGN },
        .mask = 0,
        .flags = 0,
    };
    posix.sigaction(SIG.PIPE, &sigpipe_act, null);
}

/// Check for a pending SIGINT and convert it to a catchable error.
/// Called at interpreter safe points (executeInstructions, jitSafepoint).
pub fn checkInterrupt(ctx: *Context) error{UserThrown}!void {
    if (sigint_pending.load(.acquire)) {
        sigint_pending.store(false, .release);
        ctx.thrown_error = .{
            .error_type = "interrupted",
            .message = "interrupted by signal",
        };
        return error.UserThrown;
    }
}

/// Clear pending signal state. Called after the REPL catches an error
/// so the next iteration starts clean.
pub fn reset() void {
    sigint_pending.store(false, .release);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "checkInterrupt returns cleanly when no signal pending" {
    var ctx = testContext();
    defer ctx.deinit();

    try checkInterrupt(&ctx);
    try testing.expect(ctx.thrown_error == null);
}

test "checkInterrupt fires when sigint_pending is set" {
    var ctx = testContext();
    defer ctx.deinit();

    sigint_pending.store(true, .release);
    defer sigint_pending.store(false, .release);

    const result = checkInterrupt(&ctx);
    try testing.expectError(error.UserThrown, result);
    try testing.expect(ctx.thrown_error != null);
    try testing.expectEqualStrings("interrupted", ctx.thrown_error.?.error_type);
    try testing.expectEqualStrings("interrupted by signal", ctx.thrown_error.?.message);
    // Flag should be cleared after consumption
    try testing.expect(!sigint_pending.load(.acquire));
}

test "reset clears pending flag" {
    sigint_pending.store(true, .release);
    reset();
    try testing.expect(!sigint_pending.load(.acquire));
}

test "install does not crash" {
    install();
}

fn testContext() Context {
    return Context.init(testing.allocator);
}
