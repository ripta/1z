const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

const context_mod = @import("../context.zig");
const Context = context_mod.Context;

const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Stream = value_mod.Stream;
const StreamMode = value_mod.StreamMode;
const HashTable = value_mod.HashTable;

const types_mod = @import("types.zig");
const RegistryEntry = types_mod.RegistryEntry;
const Capability = types_mod.Capability;

const helpers = @import("helpers.zig");
const streams = @import("streams.zig");
const container_backing = @import("../container_backing.zig");

pub const registry_entries = [_]RegistryEntry{
    .{
        .name = "spawn-process",
        .func = nativeSpawnProcess,
        .stack_effect = "argv cwd-or-f env-or-f stdin-sym stdout-sym stderr-sym -- pid stdin-or-f stdout-or-f stderr-or-f",
        .capability = .process,
    },
    .{
        .name = "wait-pid",
        .func = nativeWaitPid,
        .stack_effect = "pid -- exit-code",
        .capability = .process,
    },
    .{
        .name = "kill-pid",
        .func = nativeKillPid,
        .stack_effect = "pid signal-num --",
        .capability = .process,
    },
};

fn nativeSpawnProcess(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "spawn-process");
    const stderr_sym = try helpers.popSymbol(ctx);
    const stdout_sym = try helpers.popSymbol(ctx);
    const stdin_sym = try helpers.popSymbol(ctx);
    const env_val = ctx.stack.pop() catch return error.StackUnderflow;
    defer container_backing.releaseValue(env_val);
    const cwd_val = ctx.stack.pop() catch return error.StackUnderflow;
    defer container_backing.releaseValue(cwd_val);
    const argv_val = ctx.stack.pop() catch return error.StackUnderflow;
    defer container_backing.releaseValue(argv_val);
    const argv = try parseArgv(ctx, argv_val);
    const cwd = try parseOptionalCwd(ctx, cwd_val);
    var env_map = try parseOptionalEnvMap(ctx, env_val);
    defer if (env_map) |*map| map.deinit();

    var child = std.process.Child.init(argv, ctx.quotationAllocator());
    child.stdin_behavior = try parseStdIoMode(ctx, stdin_sym);
    child.stdout_behavior = try parseStdIoMode(ctx, stdout_sym);
    child.stderr_behavior = try parseStdIoMode(ctx, stderr_sym);
    child.cwd = cwd;
    if (env_map) |*map| child.env_map = map;
    child.spawn() catch |err| {
        helpers.setErrorContext(ctx, "spawn-process: {s}", .{@errorName(err)});
        return mapSpawnError(err);
    };

    try ctx.stack.push(.{ .fixnum = @intCast(child.id) });
    try pushChildStream(ctx, child.stdin, .write, "process-stdin");
    try pushChildStream(ctx, child.stdout, .read, "process-stdout");
    try pushChildStream(ctx, child.stderr, .read, "process-stderr");
}

fn nativeWaitPid(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "wait-pid");
    const pid = try popPid(ctx, "wait-pid");

    if (ctx.scheduler) |scheduler| {
        while (true) {
            if (tryWaitPidNoHang(pid)) |status| {
                try ctx.stack.push(.{ .fixnum = exitCodeFromStatus(status) });
                return;
            }

            try scheduler.processSuspendCurrentTask(pid);
            try helpers.checkCancellation(ctx);
        }
    }

    const status = std.posix.waitpid(pid, 0).status;
    try ctx.stack.push(.{ .fixnum = exitCodeFromStatus(status) });
}

fn nativeKillPid(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "kill-pid");
    const signal_num = try helpers.popFixnum(ctx);
    const pid = try popPid(ctx, "kill-pid");
    if (signal_num < 0 or signal_num > std.math.maxInt(u8)) {
        helpers.setErrorContext(ctx, "kill-pid: signal must be in range 0..255, got {d}", .{signal_num});
        return error.TypeMismatch;
    }

    std.posix.kill(pid, @intCast(signal_num)) catch |err| {
        switch (err) {
            error.ProcessNotFound => helpers.setErrorContext(ctx, "kill-pid: process {d} does not exist", .{pid}),
            error.PermissionDenied => helpers.setErrorContext(ctx, "kill-pid: permission denied for process {d}", .{pid}),
            else => helpers.setErrorContext(ctx, "kill-pid: {s}", .{@errorName(err)}),
        }
        return switch (err) {
            error.PermissionDenied => error.PermissionDenied,
            else => error.IOFailed,
        };
    };
}

fn parseArgv(ctx: *Context, argv_val: Value) ![]const []const u8 {
    const items = switch (argv_val) {
        .array => |arr| arr.items,
        else => {
            helpers.setTypeMismatchError(ctx, "array", argv_val);
            return error.TypeMismatch;
        },
    };

    if (items.len == 0) {
        ctx.pending_error_message = "spawn-process expects a non-empty argv array";
        return error.TypeMismatch;
    }

    const alloc = ctx.quotationAllocator();
    const argv = try alloc.alloc([]const u8, items.len);
    for (items, 0..) |item, i| {
        argv[i] = switch (item) {
            .string => |s| s,
            else => {
                helpers.setTypeMismatchError(ctx, "string", item);
                return error.TypeMismatch;
            },
        };
    }
    return argv;
}

fn parseStdIoMode(ctx: *Context, mode_sym: []const u8) !std.process.Child.StdIo {
    if (std.mem.eql(u8, mode_sym, "inherit")) return .Inherit;
    if (std.mem.eql(u8, mode_sym, "pipe")) return .Pipe;
    if (std.mem.eql(u8, mode_sym, "close")) return .Close;
    if (std.mem.eql(u8, mode_sym, "ignore")) return .Ignore;

    helpers.setErrorContext(
        ctx,
        "spawn-process stdio mode must be inherit:, pipe:, close:, or ignore:, got {s}:",
        .{mode_sym},
    );
    return error.TypeMismatch;
}

fn parseOptionalCwd(ctx: *Context, cwd_val: Value) !?[]const u8 {
    return switch (cwd_val) {
        .boolean => |b| if (!b) null else {
            helpers.setTypeMismatchError(ctx, "string or f", cwd_val);
            return error.TypeMismatch;
        },
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string or f", cwd_val);
            return error.TypeMismatch;
        },
    };
}

fn parseOptionalEnvMap(ctx: *Context, env_val: Value) !?std.process.EnvMap {
    return switch (env_val) {
        .boolean => |b| if (!b) null else {
            helpers.setTypeMismatchError(ctx, "hash or f", env_val);
            return error.TypeMismatch;
        },
        .hash => |env_hash| try hashToEnvMap(ctx, env_hash),
        else => {
            helpers.setTypeMismatchError(ctx, "hash or f", env_val);
            return error.TypeMismatch;
        },
    };
}

fn hashToEnvMap(ctx: *Context, env_hash: *HashTable) !std.process.EnvMap {
    var env_map = std.process.EnvMap.init(ctx.quotationAllocator());
    errdefer env_map.deinit();

    var iter = env_hash.map.iterator();
    while (iter.next()) |entry| {
        const value = entry.value_ptr.*;
        const value_str = switch (value) {
            .string => |s| s,
            else => {
                helpers.setErrorContext(
                    ctx,
                    "spawn-process env values must be strings, key '{s}' had type {s}",
                    .{ entry.key_ptr.*, helpers.valueTypeName(value) },
                );
                return error.TypeMismatch;
            },
        };
        env_map.put(entry.key_ptr.*, value_str) catch return error.OutOfMemory;
    }

    return env_map;
}

fn pushChildStream(ctx: *Context, maybe_file: ?std.fs.File, mode: StreamMode, name: []const u8) !void {
    if (maybe_file) |file| {
        const alloc = ctx.quotationAllocator();
        const stream = alloc.create(Stream) catch return error.OutOfMemory;
        stream.* = streams.createFileStream(file.handle, mode, name);
        try ctx.stack.push(.{ .stream = stream });
    } else {
        try ctx.stack.push(.{ .boolean = false });
    }
}

fn popPid(ctx: *Context, opname: []const u8) !std.posix.pid_t {
    const raw = try helpers.popFixnum(ctx);
    if (raw <= 0) {
        helpers.setErrorContext(ctx, "{s}: pid must be a positive fixnum, got {d}", .{ opname, raw });
        return error.TypeMismatch;
    }
    return std.math.cast(std.posix.pid_t, raw) orelse {
        helpers.setErrorContext(ctx, "{s}: pid out of range: {d}", .{ opname, raw });
        return error.TypeMismatch;
    };
}

fn mapSpawnError(err: anyerror) anyerror {
    return switch (err) {
        error.AccessDenied => error.PermissionDenied,
        error.FileNotFound => error.FileNotFound,
        else => error.IOFailed,
    };
}

fn tryWaitPidNoHang(pid: std.posix.pid_t) ?u32 {
    const result = std.posix.waitpid(pid, std.posix.W.NOHANG);
    if (result.pid == 0) return null;
    return result.status;
}

fn exitCodeFromStatus(status: u32) i64 {
    return if (std.posix.W.IFEXITED(status))
        std.posix.W.EXITSTATUS(status)
    else if (std.posix.W.IFSIGNALED(status))
        @as(i64, 128) + @as(i64, @intCast(std.posix.W.TERMSIG(status)))
    else if (std.posix.W.IFSTOPPED(status))
        @as(i64, 128) + @as(i64, @intCast(std.posix.W.STOPSIG(status)))
    else
        @as(i64, @intCast(status & 0xff));
}
