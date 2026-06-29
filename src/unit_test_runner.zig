const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;

const TestState = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn main() void {
    @disableInstrumentation();

    const tests = builtin.test_functions;
    const name_filter = std.posix.getenv("ONEZ_TEST_FILTER");
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var slow_count: usize = 0;
    var leak_count: usize = 0;
    var total_log_err_count: usize = 0;

    var ran_count: usize = 0;
    for (tests) |test_fn| {
        if (name_filter) |needle| {
            if (!matchesFilter(test_fn.name, needle)) continue;
        }
        ran_count += 1;
        testing.allocator_instance = .{};
        testing.log_level = .warn;
        log_err_count = 0;

        var state = TestState{};
        const watchdog = std.Thread.spawn(.{}, watchdogThread, .{ test_fn.name, &state }) catch null;
        const started_ns = std.time.nanoTimestamp();

        const result = test_fn.func();
        state.done.store(true, .release);
        if (watchdog) |thread| thread.join();

        const elapsed_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp() - started_ns, std.time.ns_per_ms)));
        const leak = testing.allocator_instance.deinit() == .leak;
        if (leak) leak_count += 1;
        total_log_err_count += log_err_count;

        if (result) |_| {
            ok_count += 1;
            if (elapsed_ms >= build_options.slow_test_threshold_ms) {
                slow_count += 1;
                if (build_options.verbose_test_reporting) {
                    std.debug.print("SLOW: {s} {d}ms\n", .{ test_fn.name, elapsed_ms });
                }
            }
        } else |err| switch (err) {
            error.SkipZigTest => skip_count += 1,
            else => {
                fail_count += 1;
                std.debug.print("FAIL: {s} ({s})\n", .{ test_fn.name, @errorName(err) });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            },
        }
    }

    std.debug.print(
        "Unit test summary: ran={d} total={d} slow={d} failed={d} skipped={d} leaked={d}\n",
        .{ ran_count, tests.len, slow_count, fail_count, skip_count, leak_count },
    );
    if (total_log_err_count != 0) {
        std.debug.print("Unit test logs: err_count={d}\n", .{total_log_err_count});
    }
    if (fail_count != 0 or leak_count != 0 or total_log_err_count != 0) {
        std.process.exit(1);
    }
}

/// Comma-separated substring filter: a test runs when its name contains any of
/// the trimmed, non-empty comma-separated patterns. Mirrors `matchesFilter` in
/// build.zig so -Dtest-filter behaves identically for unit and integration tests.
fn matchesFilter(name: []const u8, filter: []const u8) bool {
    var iter = std.mem.splitScalar(u8, filter, ',');
    while (iter.next()) |pattern| {
        const trimmed = std.mem.trim(u8, pattern, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, name, trimmed) != null) return true;
    }
    return false;
}

fn watchdogThread(name: []const u8, state: *TestState) void {
    const timeout_ns = @as(u64, build_options.test_case_timeout_secs) * std.time.ns_per_s;
    const sleep_ns = 10 * std.time.ns_per_ms;
    var waited: u64 = 0;
    while (waited < timeout_ns) : (waited += sleep_ns) {
        if (state.done.load(.acquire)) return;
        std.Thread.sleep(sleep_ns);
    }
    if (!state.done.load(.acquire)) {
        std.debug.print(
            "TIMEOUT: unit test '{s}' exceeded {d}s\n",
            .{ name, build_options.test_case_timeout_secs },
        );
        std.process.exit(1);
    }
}

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
