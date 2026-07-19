const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../context.zig").Context;
const helpers = @import("helpers.zig");
const popFixnum = helpers.popFixnum;
const popString = helpers.popString;
const setErrorContext = helpers.setErrorContext;

const Primitive = @import("types.zig").Primitive;
const scheduler_mod = @import("../scheduler.zig");
const monotonicNowNs = scheduler_mod.monotonicNowNs;

const is_freestanding = builtin.os.tag == .freestanding;
const is_wasm = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;

// The `is_wasm` bodies below are not yet compile-checked against wasm32-freestanding: this
// file takes `*Context`, and even the `ctx.stack.push` on the wasm path resolves `Value`,
// whose `@sizeOf(Value) == 40` assertion does not hold on wasm32's 32-bit pointers. That is
// interpreter no-libc porting work, not this file's.

pub const primitives = [_]Primitive{
    .{ .name = "clock-realtime", .stack_effect = "-- sec nsec", .doc = "Current wall-clock time (UTC) since Unix epoch.", .func = nativeClockRealtime },
    .{ .name = "clock-monotonic", .stack_effect = "-- sec nsec", .doc = "Monotonic clock for measuring durations.", .func = nativeClockMonotonic },
    .{ .name = "tz-decompose", .stack_effect = "sec tz-name -- year month-num day hour min sec wday yday gmtoff tz-abbrev", .doc = "Decompose epoch seconds in a named timezone via libc localtime_r.", .func = nativeTzDecompose },
};

/// Host-provided wall clock, resolved by the browser's `WebAssembly.instantiate()`
/// import object. Backed by `Date.now()`, which is natively millisecond-precision.
extern "env" fn onez_host_realtime_now_ms() i64;

/// clock-realtime ( -- sec nsec ) - Current wall-clock time (UTC) since Unix epoch
fn nativeClockRealtime(ctx: *Context) anyerror!void {
    if (is_wasm) {
        const ms = onez_host_realtime_now_ms();
        try ctx.stack.push(.{ .fixnum = @divFloor(ms, 1000) });
        try ctx.stack.push(.{ .fixnum = @mod(ms, 1000) * std.time.ns_per_ms });
        return;
    }
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "clock-realtime");

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
    if (ctx.scheduler) |sched| {
        switch (sched.clock) {
            .fake => |ns| {
                const sec = @divFloor(ns, std.time.ns_per_s);
                const nsec = @mod(ns, std.time.ns_per_s);
                try ctx.stack.push(.{ .fixnum = @intCast(sec) });
                try ctx.stack.push(.{ .fixnum = @intCast(nsec) });
                return;
            },
            .real => {},
        }
    }

    if (is_wasm) {
        const ns = monotonicNowNs();
        try ctx.stack.push(.{ .fixnum = @intCast(@divFloor(ns, std.time.ns_per_s)) });
        try ctx.stack.push(.{ .fixnum = @intCast(@mod(ns, std.time.ns_per_s)) });
        return;
    }
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "clock-monotonic");

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
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "tz-decompose");

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
        ctx.lock_order_tracker.acquire(.tz);
        tz_mutex.lock();
        defer {
            tz_mutex.unlock();
            ctx.lock_order_tracker.release(.tz);
        }

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
