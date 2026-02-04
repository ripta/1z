const std = @import("std");
const Context = @import("../context.zig").Context;

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "clock-realtime", .stack_effect = "-- sec nsec", .func = nativeClockRealtime },
    .{ .name = "clock-monotonic", .stack_effect = "-- sec nsec", .func = nativeClockMonotonic },
};

/// clock-realtime ( -- sec nsec ) - Current wall-clock time (UTC) since Unix epoch
fn nativeClockRealtime(ctx: *Context) anyerror!void {
    const ts = std.posix.clock_gettime(.REALTIME) catch |err| {
        return switch (err) {
            error.UnsupportedClock => error.InvalidType,
            error.Unexpected => error.IOError,
        };
    };

    try ctx.stack.push(.{ .integer = ts.sec });
    try ctx.stack.push(.{ .integer = ts.nsec });
}

/// clock-monotonic ( -- sec nsec ) - Monotonic clock for measuring durations
fn nativeClockMonotonic(ctx: *Context) anyerror!void {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch |err| {
        return switch (err) {
            error.UnsupportedClock => error.InvalidType,
            error.Unexpected => error.IOError,
        };
    };

    try ctx.stack.push(.{ .integer = ts.sec });
    try ctx.stack.push(.{ .integer = ts.nsec });
}
