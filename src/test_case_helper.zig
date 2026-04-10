const std = @import("std");

const Status = enum {
    ok,
    fail,
    timeout,
};

const RelayTarget = enum {
    stdout,
    stderr,
};

const RelayContext = struct {
    source: std.fs.File,
    target: RelayTarget,
};

const RunOptions = struct {
    label: []const u8,
    timeout_secs: u32,
    slow_ms: u64,
    print_slow: bool,
    status_file: []const u8,
    stdin_file: ?[]const u8,
    argv_start: usize,
};

const SummaryEntry = struct {
    label: []const u8,
    status: Status,
    duration_ms: u64,
};

const WaitState = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?std.process.Child.Term = null,
    err: ?anyerror = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) return error.InvalidArguments;

    if (std.mem.eql(u8, args[1], "run")) {
        const opts = try parseRunArgs(args);
        try runCase(allocator, args, opts);
        return;
    }
    if (std.mem.eql(u8, args[1], "summarize")) {
        try summarize(allocator, args[2..]);
        return;
    }

    return error.InvalidArguments;
}

fn parseRunArgs(args: []const []const u8) !RunOptions {
    var label: ?[]const u8 = null;
    var timeout_secs: ?u32 = null;
    var slow_ms: u64 = 1000;
    var print_slow = false;
    var status_file: ?[]const u8 = null;
    var stdin_file: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--print-slow")) {
            print_slow = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--label")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            label = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout-secs")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            timeout_secs = try std.fmt.parseInt(u32, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--slow-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            slow_ms = try std.fmt.parseInt(u64, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--status-file")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            status_file = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--stdin-file")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            stdin_file = args[i];
            continue;
        }
        return error.InvalidArguments;
    }
    if (i >= args.len or label == null or timeout_secs == null or status_file == null) {
        return error.InvalidArguments;
    }
    return .{
        .label = label.?,
        .timeout_secs = timeout_secs.?,
        .slow_ms = slow_ms,
        .print_slow = print_slow,
        .status_file = status_file.?,
        .stdin_file = stdin_file,
        .argv_start = i,
    };
}

fn runCase(allocator: std.mem.Allocator, args: []const []const u8, opts: RunOptions) !void {
    var child = std.process.Child.init(args[opts.argv_start..], allocator);
    child.stdin_behavior = if (opts.stdin_file != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const started_ns = std.time.nanoTimestamp();
    try child.spawn();

    const child_stdout = child.stdout.?;
    child.stdout = null;
    const child_stderr = child.stderr.?;
    child.stderr = null;

    var stdin_thread: ?std.Thread = null;
    if (opts.stdin_file) |stdin_file| {
        const child_stdin = child.stdin.?;
        child.stdin = null;
        stdin_thread = try std.Thread.spawn(.{}, writeInput, .{ child_stdin, stdin_file });
    }

    const stdout_thread = try std.Thread.spawn(.{}, relayOutput, .{RelayContext{ .source = child_stdout, .target = .stdout }});
    const stderr_thread = try std.Thread.spawn(.{}, relayOutput, .{RelayContext{ .source = child_stderr, .target = .stderr }});

    var wait_state = WaitState{};
    const wait_thread = try std.Thread.spawn(.{}, waitForChild, .{ &child, &wait_state });

    const timeout_ns: u64 = @as(u64, opts.timeout_secs) * std.time.ns_per_s;
    const sleep_ns = 10 * std.time.ns_per_ms;

    var timed_out = false;
    while (!wait_state.done.load(.acquire)) {
        const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - started_ns));
        if (elapsed >= timeout_ns) {
            timed_out = true;
            std.posix.kill(child.id, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => return err,
            };
            break;
        }
        std.Thread.sleep(sleep_ns);
    }

    wait_thread.join();
    stdout_thread.join();
    stderr_thread.join();
    if (stdin_thread) |thread| thread.join();

    if (wait_state.err) |err| return err;
    const term = wait_state.result orelse return error.Unexpected;
    const ended_ns = std.time.nanoTimestamp();
    const duration_ms = @as(u64, @intCast(@divTrunc(ended_ns - started_ns, std.time.ns_per_ms)));

    if (timed_out) {
        try writeStatusFile(opts.status_file, opts.label, .timeout, duration_ms);
        std.debug.print("TIMEOUT: {s} exceeded {d}s\n", .{ opts.label, opts.timeout_secs });
        std.process.exit(1);
    }

    const exit_code = switch (term) {
        .Exited => |code| code,
        else => 1,
    };
    const status: Status = if (exit_code == 0) .ok else .fail;
    try writeStatusFile(opts.status_file, opts.label, status, duration_ms);

    if (opts.print_slow and status == .ok and duration_ms >= opts.slow_ms) {
        printToTty("SLOW: {s} {d}ms\n", .{ opts.label, duration_ms });
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

fn summarize(allocator: std.mem.Allocator, files: []const []const u8) !void {
    var total: usize = 0;
    var slow: usize = 0;
    var failed: usize = 0;
    var timed_out: usize = 0;
    var slow_entries: std.ArrayList(SummaryEntry) = .empty;
    defer {
        for (slow_entries.items) |entry| allocator.free(entry.label);
        slow_entries.deinit(allocator);
    }

    for (files) |file_path| {
        const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024);
        defer allocator.free(content);
        if (content.len == 0) continue;

        var iter = std.mem.splitScalar(u8, std.mem.trimRight(u8, content, "\n"), '\t');
        const label = iter.next() orelse continue;
        const status_str = iter.next() orelse continue;
        const duration_str = iter.next() orelse continue;

        const status = std.meta.stringToEnum(Status, status_str) orelse continue;
        const duration_ms = std.fmt.parseInt(u64, duration_str, 10) catch continue;

        total += 1;
        switch (status) {
            .ok => {
                if (duration_ms >= 1000) {
                    slow += 1;
                    try slow_entries.append(allocator, .{
                        .label = try allocator.dupe(u8, label),
                        .status = status,
                        .duration_ms = duration_ms,
                    });
                }
            },
            .fail => failed += 1,
            .timeout => timed_out += 1,
        }
    }

    if (slow_entries.items.len > 0) {
        for (slow_entries.items) |entry| {
            std.debug.print("SLOW: {s} {d}ms\n", .{ entry.label, entry.duration_ms });
        }
    }
    std.debug.print(
        "Test summary: total={d} slow={d} failed={d} timed_out={d}\n",
        .{ total, slow, failed, timed_out },
    );
}

fn writeStatusFile(path: []const u8, label: []const u8, status: Status, duration_ms: u64) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [256]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.print("{s}\t{s}\t{d}\n", .{ label, @tagName(status), duration_ms });
    try writer.interface.flush();
}

fn writeInput(child_stdin: std.fs.File, stdin_file: []const u8) !void {
    defer child_stdin.close();
    const file = try std.fs.cwd().openFile(stdin_file, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        try child_stdin.writeAll(buf[0..n]);
    }
}

fn relayOutput(ctx: RelayContext) !void {
    defer ctx.source.close();
    var buf: [4096]u8 = undefined;
    const out_file = switch (ctx.target) {
        .stdout => std.fs.File.stdout(),
        .stderr => std.fs.File.stderr(),
    };
    var out_buffer: [4096]u8 = undefined;
    var out = out_file.writer(&out_buffer);
    while (true) {
        const n = try ctx.source.read(&buf);
        if (n == 0) break;
        try out.interface.writeAll(buf[0..n]);
    }
    try out.interface.flush();
}

fn waitForChild(child: *std.process.Child, state: *WaitState) void {
    state.result = child.wait() catch |err| {
        state.err = err;
        state.done.store(true, .release);
        return;
    };
    state.done.store(true, .release);
}

fn printToTty(comptime fmt: []const u8, args: anytype) void {
    const file = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .write_only }) catch return;
    defer file.close();
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    writer.interface.print(fmt, args) catch return;
    writer.interface.flush() catch {};
}
