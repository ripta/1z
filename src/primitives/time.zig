const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("helpers.zig");
const popFixnum = helpers.popFixnum;
const popString = helpers.popString;
const setErrorContext = helpers.setErrorContext;

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "clock-realtime", .stack_effect = "-- sec nsec", .doc = "Current wall-clock time (UTC) since Unix epoch.", .func = nativeClockRealtime },
    .{ .name = "clock-monotonic", .stack_effect = "-- sec nsec", .doc = "Monotonic clock for measuring durations.", .func = nativeClockMonotonic },
    .{ .name = "tz-decompose", .stack_effect = "sec tz-name -- year month-num day hour min sec wday yday gmtoff tz-abbrev", .doc = "Decompose epoch seconds in a named timezone via libc localtime_r.", .func = nativeTzDecompose },
};

/// clock-realtime ( -- sec nsec ) - Current wall-clock time (UTC) since Unix epoch
fn nativeClockRealtime(ctx: *Context) anyerror!void {
    const ts = std.posix.clock_gettime(.REALTIME) catch |err| {
        return switch (err) {
            error.UnsupportedClock => error.InvalidType,
            error.Unexpected => error.IOError,
        };
    };

    try ctx.stack.push(.{ .fixnum = ts.sec });
    try ctx.stack.push(.{ .fixnum = ts.nsec });
}

/// clock-monotonic ( -- sec nsec ) - Monotonic clock for measuring durations
fn nativeClockMonotonic(ctx: *Context) anyerror!void {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch |err| {
        return switch (err) {
            error.UnsupportedClock => error.InvalidType,
            error.Unexpected => error.IOError,
        };
    };

    try ctx.stack.push(.{ .fixnum = ts.sec });
    try ctx.stack.push(.{ .fixnum = ts.nsec });
}

// =========================================================================
// libc time functions
// =========================================================================

const c = struct {
    const tm = extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
        tm_gmtoff: c_long,
        tm_zone: [*:0]const u8,
    };
    extern "c" fn localtime_r(timer: *const c_long, result: *tm) ?*tm;
    extern "c" fn tzset() void;
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
};

var tz_mutex = std.Thread.Mutex{};

/// tz-decompose ( sec tz-name -- year month-num day hour min sec wday yday gmtoff tz-abbrev )
///
/// Decompose epoch seconds in a named timezone via libc localtime_r.
/// If tz-name is empty, uses the system's local timezone.
/// Pushes 10 raw values for consumption by 1z-level struct/hash builders.
fn nativeTzDecompose(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tz_name = try popString(ctx);
    const sec = try popFixnum(ctx);

    const tz_name_z = try alloc.dupeZ(u8, tz_name);

    var result: c.tm = undefined;
    const time_val: c_long = @intCast(sec);

    // tm_zone is a pointer into libc memory that is invalidated
    // by subsequent tzset() calls, so we gotta copy it out
    var tz_zone_str: []const u8 = undefined;

    // If tz_name is empty, we can call localtime_r directly without modifying TZ env var.
    // Otherwise: set TZ, call tzset, then call localtime_r. 🤢
    if (tz_name.len == 0) {
        if (c.localtime_r(&time_val, &result) == null) {
            setErrorContext(ctx, "localtime_r failed for sec={d}", .{sec});
            return error.IOFailed;
        }

        tz_zone_str = try alloc.dupe(u8, std.mem.sliceTo(result.tm_zone, 0));
    } else {
        tz_mutex.lock();
        defer tz_mutex.unlock();

        const old_tz = c.getenv("TZ");

        _ = c.setenv("TZ", tz_name_z, 1);
        c.tzset();

        const lr_result = c.localtime_r(&time_val, &result);

        if (lr_result != null) {
            tz_zone_str = try alloc.dupe(u8, std.mem.sliceTo(result.tm_zone, 0));
        }

        if (old_tz) |old| {
            _ = c.setenv("TZ", old, 1);
        } else {
            _ = c.unsetenv("TZ");
        }
        c.tzset();

        if (lr_result == null) {
            setErrorContext(ctx, "localtime_r failed for sec={d} tz={s}", .{ sec, tz_name });
            return error.IOFailed;
        }
    }

    try ctx.stack.push(.{ .fixnum = @as(i64, result.tm_year) + 1900 });
    try ctx.stack.push(.{ .fixnum = @as(i64, result.tm_mon) + 1 });
    try ctx.stack.push(.{ .fixnum = @intCast(result.tm_mday) });
    try ctx.stack.push(.{ .fixnum = @intCast(result.tm_hour) });
    try ctx.stack.push(.{ .fixnum = @intCast(result.tm_min) });
    try ctx.stack.push(.{ .fixnum = @intCast(result.tm_sec) });
    try ctx.stack.push(.{ .fixnum = @intCast(result.tm_wday) });
    try ctx.stack.push(.{ .fixnum = @as(i64, result.tm_yday) + 1 });
    try ctx.stack.push(.{ .fixnum = @intCast(result.tm_gmtoff) });
    try ctx.stack.push(.{ .string = tz_zone_str });
}
