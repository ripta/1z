const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("helpers.zig");
const popInteger = helpers.popInteger;
const popString = helpers.popString;
const setErrorContext = helpers.setErrorContext;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const HashTable = value_mod.HashTable;

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "clock-realtime", .stack_effect = "-- sec nsec", .func = nativeClockRealtime },
    .{ .name = "clock-monotonic", .stack_effect = "-- sec nsec", .func = nativeClockMonotonic },
    .{ .name = "tz-decompose", .stack_effect = "sec tz-name -- hash", .func = nativeTzDecompose },
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

const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};
const month_short = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};
const weekday_names = [_][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};
const weekday_short = [_][]const u8{
    "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
};

/// Format a gmtoff (seconds east of UTC) as "+HHMM" or "-HHMM".
fn formatTzOffset(alloc: std.mem.Allocator, gmtoff: c_long) ![]const u8 {
    const sign: u8 = if (gmtoff < 0) '-' else '+';
    const abs: u64 = if (gmtoff < 0) @intCast(-gmtoff) else @intCast(gmtoff);
    const total_min = abs / 60;
    const hh = total_min / 60;
    const mm = total_min % 60;
    var buf: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{c}{d:0>2}{d:0>2}", .{ sign, hh, mm }) catch unreachable;
    return alloc.dupe(u8, buf[0..5]);
}

/// Compute ISO week number from yearday (1-based) and iso-weekday (1=Mon..7=Sun).
fn computeIsoWeek(yearday: i64, iso_wday: i64) i64 {
    const w = @divFloor(yearday - iso_wday + 10, 7);
    if (w < 1) return 1;
    if (w > 53) return 53;
    return w;
}

/// tz-decompose ( sec tz-name -- hash )
/// Decompose epoch seconds in a named timezone via libc localtime_r.
/// If tz-name is empty, uses the system's local timezone.
fn nativeTzDecompose(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const tz_name = try popString(ctx);
    const sec = try popInteger(ctx);

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

    const year: i64 = @as(i64, result.tm_year) + 1900;
    const month_num: i64 = @as(i64, result.tm_mon) + 1;
    const day: i64 = @intCast(result.tm_mday);
    const hour: i64 = @intCast(result.tm_hour);
    const min: i64 = @intCast(result.tm_min);
    const sec_val: i64 = @intCast(result.tm_sec);
    const posix_wday: i64 = @intCast(result.tm_wday);
    const yearday: i64 = @as(i64, result.tm_yday) + 1;

    const year_short: i64 = @mod(year, 100);
    const hour12: i64 = blk: {
        const h = @mod(hour, 12);
        break :blk if (h == 0) 12 else h;
    };
    const iso_wday: i64 = if (posix_wday == 0) 7 else posix_wday;
    const iso_week = computeIsoWeek(yearday, iso_wday);

    const tz_offset_str = try formatTzOffset(alloc, result.tm_gmtoff);

    const mon_idx: usize = @intCast(result.tm_mon);
    const wday_idx: usize = @intCast(result.tm_wday);

    const hash = alloc.create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    const fields = .{
        .{ "year", Value{ .integer = year } },
        .{ "year-short", Value{ .integer = year_short } },
        .{ "month-num", Value{ .integer = month_num } },
        .{ "month", Value{ .string = try alloc.dupe(u8, month_names[mon_idx]) } },
        .{ "month-name", Value{ .string = try alloc.dupe(u8, month_names[mon_idx]) } },
        .{ "month-short", Value{ .string = try alloc.dupe(u8, month_short[mon_idx]) } },
        .{ "day", Value{ .integer = day } },
        .{ "yearday", Value{ .integer = yearday } },
        .{ "weekday", Value{ .string = try alloc.dupe(u8, weekday_names[wday_idx]) } },
        .{ "weekday-name", Value{ .string = try alloc.dupe(u8, weekday_names[wday_idx]) } },
        .{ "weekday-short", Value{ .string = try alloc.dupe(u8, weekday_short[wday_idx]) } },
        .{ "posix-weekday", Value{ .integer = posix_wday } },
        .{ "iso-weekday", Value{ .integer = iso_wday } },
        .{ "iso-week", Value{ .integer = iso_week } },
        .{ "hour", Value{ .integer = hour } },
        .{ "hour24", Value{ .integer = hour } },
        .{ "hour12", Value{ .integer = hour12 } },
        .{ "min", Value{ .integer = min } },
        .{ "sec", Value{ .integer = sec_val } },
        .{ "nsec", Value{ .integer = 0 } },
        .{ "usec", Value{ .integer = 0 } },
        .{ "msec", Value{ .integer = 0 } },
        .{ "ampm", Value{ .string = try alloc.dupe(u8, if (hour < 12) "AM" else "PM") } },
        .{ "tz", Value{ .string = tz_offset_str } },
        .{ "tz-offset", Value{ .string = tz_offset_str } },
        .{ "tz-name", Value{ .string = tz_zone_str } },
    };

    inline for (fields) |field| {
        const key = try alloc.dupe(u8, field[0]);
        hash.put(alloc, key, field[1]) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .hash = hash });
}
