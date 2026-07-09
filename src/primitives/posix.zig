const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const is_freestanding = native_os == .freestanding;

const Context = @import("../context.zig").Context;
const helpers = @import("helpers.zig");

const RegistryEntry = @import("types.zig").RegistryEntry;

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "posix-const", .func = nativePosixConst, .stack_effect = "str -- n", .capability = .none },
};

/// posix-const ( str -- n )
///
/// Bridges a Zig comptime `std.posix.*` value to a 1z fixnum by name, so
/// library code (lib/posix.1z) can look up constants like flock modes,
/// memory protection flags, and resource-limit kinds without a dedicated
/// Zig primitive per constant.
fn nativePosixConst(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "posix-const");
    const name = try helpers.popString(ctx);

    const val: i64 = if (std.mem.eql(u8, name, "LOCK_SH"))
        std.posix.LOCK.SH
    else if (std.mem.eql(u8, name, "LOCK_EX"))
        std.posix.LOCK.EX
    else if (std.mem.eql(u8, name, "LOCK_NB"))
        std.posix.LOCK.NB
    else if (std.mem.eql(u8, name, "LOCK_UN"))
        std.posix.LOCK.UN
    else if (std.mem.eql(u8, name, "PROT_NONE"))
        std.posix.PROT.NONE
    else if (std.mem.eql(u8, name, "PROT_READ"))
        std.posix.PROT.READ
    else if (std.mem.eql(u8, name, "PROT_WRITE"))
        std.posix.PROT.WRITE
    else if (std.mem.eql(u8, name, "PROT_EXEC"))
        std.posix.PROT.EXEC
    else if (std.mem.eql(u8, name, "MADV_NORMAL"))
        std.posix.MADV.NORMAL
    else if (std.mem.eql(u8, name, "MADV_RANDOM"))
        std.posix.MADV.RANDOM
    else if (std.mem.eql(u8, name, "MADV_SEQUENTIAL"))
        std.posix.MADV.SEQUENTIAL
    else if (std.mem.eql(u8, name, "MADV_WILLNEED"))
        std.posix.MADV.WILLNEED
    else if (std.mem.eql(u8, name, "MADV_DONTNEED"))
        std.posix.MADV.DONTNEED
    else if (std.mem.eql(u8, name, "MADV_FREE"))
        std.posix.MADV.FREE
    else if (std.mem.eql(u8, name, "RLIMIT_CPU"))
        @intFromEnum(std.posix.rlimit_resource.CPU)
    else if (std.mem.eql(u8, name, "RLIMIT_FSIZE"))
        @intFromEnum(std.posix.rlimit_resource.FSIZE)
    else if (std.mem.eql(u8, name, "RLIMIT_DATA"))
        @intFromEnum(std.posix.rlimit_resource.DATA)
    else if (std.mem.eql(u8, name, "RLIMIT_STACK"))
        @intFromEnum(std.posix.rlimit_resource.STACK)
    else if (std.mem.eql(u8, name, "RLIMIT_CORE"))
        @intFromEnum(std.posix.rlimit_resource.CORE)
    else if (std.mem.eql(u8, name, "RLIMIT_NOFILE"))
        @intFromEnum(std.posix.rlimit_resource.NOFILE)
    else if (std.mem.eql(u8, name, "RLIMIT_AS"))
        @intFromEnum(std.posix.rlimit_resource.AS)
    else if (std.mem.eql(u8, name, "RLIMIT_MEMLOCK"))
        @intFromEnum(std.posix.rlimit_resource.MEMLOCK)
    else if (std.mem.eql(u8, name, "RLIMIT_NPROC"))
        @intFromEnum(std.posix.rlimit_resource.NPROC)
    else if (std.mem.eql(u8, name, "CLOCK_REALTIME"))
        @intFromEnum(std.posix.CLOCK.REALTIME)
    else if (std.mem.eql(u8, name, "CLOCK_MONOTONIC"))
        @intFromEnum(std.posix.CLOCK.MONOTONIC)
    else if (std.mem.eql(u8, name, "O_CLOEXEC"))
        @intCast(@as(u32, @bitCast(std.posix.O{ .CLOEXEC = true })))
    else if (std.mem.eql(u8, name, "O_NONBLOCK"))
        @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })))
    else {
        helpers.setErrorContext(ctx, "unknown posix constant: {s}", .{name});
        return error.InvalidArgument;
    };

    try ctx.stack.push(.{ .fixnum = val });
}

const testing = std.testing;

fn constOf(comptime name: []const u8) !i64 {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.stack.push(.{ .string = name });
    try nativePosixConst(&ctx);
    return (try ctx.stack.pop()).fixnum;
}

test "posix-const resolves portable flock modes" {
    if (is_freestanding) return error.SkipZigTest;

    // LOCK_SH/EX/NB/UN are defined directly in std/posix.zig (not per-OS),
    // matching sys/file.h on both Linux and macOS.
    try testing.expectEqual(@as(i64, 1), try constOf("LOCK_SH"));
    try testing.expectEqual(@as(i64, 2), try constOf("LOCK_EX"));
    try testing.expectEqual(@as(i64, 4), try constOf("LOCK_NB"));
    try testing.expectEqual(@as(i64, 8), try constOf("LOCK_UN"));
}

test "posix-const resolves memory protection flags" {
    if (is_freestanding) return error.SkipZigTest;

    // PROT_NONE/READ/WRITE/EXEC per sys/mman.h; identical bit values on
    // Linux and macOS.
    try testing.expectEqual(@as(i64, 0x0), try constOf("PROT_NONE"));
    try testing.expectEqual(@as(i64, 0x1), try constOf("PROT_READ"));
    try testing.expectEqual(@as(i64, 0x2), try constOf("PROT_WRITE"));
    try testing.expectEqual(@as(i64, 0x4), try constOf("PROT_EXEC"));
}

test "posix-const resolves memory advice per platform" {
    if (is_freestanding) return error.SkipZigTest;

    // MADV_NORMAL/RANDOM/SEQUENTIAL/WILLNEED/DONTNEED share values across
    // Linux and macOS per sys/mman.h; MADV_FREE's numeric value diverges
    // (Linux 8, macOS 5), which is exactly why this reads through
    // std.posix rather than a hardcoded table.
    try testing.expectEqual(@as(i64, 0), try constOf("MADV_NORMAL"));
    try testing.expectEqual(@as(i64, 1), try constOf("MADV_RANDOM"));
    try testing.expectEqual(@as(i64, 2), try constOf("MADV_SEQUENTIAL"));
    try testing.expectEqual(@as(i64, 3), try constOf("MADV_WILLNEED"));
    try testing.expectEqual(@as(i64, 4), try constOf("MADV_DONTNEED"));
    try testing.expectEqual(
        @as(i64, if (native_os == .linux) 8 else 5),
        try constOf("MADV_FREE"),
    );
}

test "posix-const resolves resource limit kinds" {
    if (is_freestanding) return error.SkipZigTest;

    // RLIMIT_CPU/FSIZE/DATA/STACK/CORE/NOFILE are always 0..5 per
    // sys/resource.h, but the remaining kinds are numbered differently
    // per OS (per the enum in std.posix.rlimit_resource), which is why
    // these are looked up by name rather than a fixed integer.
    try testing.expectEqual(@as(i64, 0), try constOf("RLIMIT_CPU"));
    try testing.expectEqual(@as(i64, 1), try constOf("RLIMIT_FSIZE"));
    try testing.expectEqual(@as(i64, 2), try constOf("RLIMIT_DATA"));
    try testing.expectEqual(@as(i64, 3), try constOf("RLIMIT_STACK"));
    try testing.expectEqual(@as(i64, 4), try constOf("RLIMIT_CORE"));
    try testing.expectEqual(
        @as(i64, @intFromEnum(std.posix.rlimit_resource.NOFILE)),
        try constOf("RLIMIT_NOFILE"),
    );
    try testing.expectEqual(
        @as(i64, @intFromEnum(std.posix.rlimit_resource.AS)),
        try constOf("RLIMIT_AS"),
    );
    try testing.expectEqual(
        @as(i64, @intFromEnum(std.posix.rlimit_resource.MEMLOCK)),
        try constOf("RLIMIT_MEMLOCK"),
    );
    try testing.expectEqual(
        @as(i64, @intFromEnum(std.posix.rlimit_resource.NPROC)),
        try constOf("RLIMIT_NPROC"),
    );
}

test "posix-const resolves clock ids" {
    if (is_freestanding) return error.SkipZigTest;

    try testing.expectEqual(
        @as(i64, @intFromEnum(std.posix.CLOCK.REALTIME)),
        try constOf("CLOCK_REALTIME"),
    );
    try testing.expectEqual(
        @as(i64, @intFromEnum(std.posix.CLOCK.MONOTONIC)),
        try constOf("CLOCK_MONOTONIC"),
    );
}

test "posix-const resolves open flags via bit extraction" {
    if (is_freestanding) return error.SkipZigTest;

    // O_CLOEXEC/O_NONBLOCK are individual bits in a per-OS packed struct;
    // ACCMODE (the other field) defaults to RDONLY (0), so bitcasting a
    // struct with just one bool set isolates that bit's value cleanly.
    try testing.expectEqual(
        @as(i64, @as(u32, @bitCast(std.posix.O{ .CLOEXEC = true }))),
        try constOf("O_CLOEXEC"),
    );
    try testing.expectEqual(
        @as(i64, @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }))),
        try constOf("O_NONBLOCK"),
    );
}

test "posix-const errors on an unknown name" {
    if (is_freestanding) return error.SkipZigTest;

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.stack.push(.{ .string = "NOT_A_CONSTANT" });
    try testing.expectError(error.InvalidArgument, nativePosixConst(&ctx));
    try testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}
