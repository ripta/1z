const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const HashTable = value_mod.HashTable;

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");

const is_freestanding = builtin.os.tag == .freestanding;

pub const primitives = [_]Primitive{
    .{ .name = "environ", .stack_effect = "-- hash", .doc = "Return a fresh hash of current environment variables.", .func = nativeEnviron, .capability = .system },
    .{ .name = "sys-info", .stack_effect = "-- hash", .doc = "Return a hash of system/platform information.", .func = nativeSysInfo, .capability = .system },
    .{ .name = "target-os", .stack_effect = "-- symbol", .doc = "Resolve at parse time to the build target's OS as a symbol (macos, linux).", .func = nativeTargetOs, .parse_time = true },
    .{ .name = "target-arch", .stack_effect = "-- symbol", .doc = "Resolve at parse time to the build target's architecture as a symbol (x86_64, aarch64).", .func = nativeTargetArch, .parse_time = true },
};

/// environ ( -- hash ) - Return a fresh hash of current environment variables
fn nativeEnviron(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "environ");
    const alloc = ctx.quotationAllocator();

    const hash = alloc.create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    const env_map = std.process.getEnvMap(alloc) catch return error.OutOfMemory;
    var iter = env_map.iterator();
    while (iter.next()) |entry| {
        const key = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
        const val_str = alloc.dupe(u8, entry.value_ptr.*) catch return error.OutOfMemory;
        hash.put(alloc, key, .{ .string = val_str }) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .hash = hash });
}

/// sys-info ( -- hash ) - Return a hash of system/platform information
fn nativeSysInfo(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const hash = alloc.create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    const target = builtin.target;

    // "os" - e.g. "macos", "linux", "windows"
    const os_name = @tagName(target.os.tag);
    const os_key = alloc.dupe(u8, "os") catch return error.OutOfMemory;
    const os_val = alloc.dupe(u8, os_name) catch return error.OutOfMemory;
    hash.put(alloc, os_key, .{ .string = os_val }) catch return error.OutOfMemory;

    // "arch" - e.g. "aarch64", "x86_64"
    const arch_name = @tagName(target.cpu.arch);
    const arch_key = alloc.dupe(u8, "arch") catch return error.OutOfMemory;
    const arch_val = alloc.dupe(u8, arch_name) catch return error.OutOfMemory;
    hash.put(alloc, arch_key, .{ .string = arch_val }) catch return error.OutOfMemory;

    // "abi" - e.g. "none", "gnu", "musl"
    const abi_name = @tagName(target.abi);
    const abi_key = alloc.dupe(u8, "abi") catch return error.OutOfMemory;
    const abi_val = alloc.dupe(u8, abi_name) catch return error.OutOfMemory;
    hash.put(alloc, abi_key, .{ .string = abi_val }) catch return error.OutOfMemory;

    // "endian" - "little" or "big"
    const endian_name = switch (target.cpu.arch.endian()) {
        .little => "little",
        .big => "big",
    };
    const endian_key = alloc.dupe(u8, "endian") catch return error.OutOfMemory;
    const endian_val = alloc.dupe(u8, endian_name) catch return error.OutOfMemory;
    hash.put(alloc, endian_key, .{ .string = endian_val }) catch return error.OutOfMemory;

    // "ptr-width" - 32 or 64
    const pw_key = alloc.dupe(u8, "ptr-width") catch return error.OutOfMemory;
    hash.put(alloc, pw_key, .{ .fixnum = target.ptrBitWidth() }) catch return error.OutOfMemory;

    // "os-family" - "unix", "windows", or "other"
    const os_family = if (target.os.tag == .windows) "windows" else if (target.os.tag.isDarwin() or target.os.tag == .linux or target.os.tag == .freebsd or target.os.tag == .openbsd or target.os.tag == .netbsd or target.os.tag == .dragonfly or target.os.tag == .solaris) "unix" else "other";
    const fam_key = alloc.dupe(u8, "os-family") catch return error.OutOfMemory;
    const fam_val = alloc.dupe(u8, os_family) catch return error.OutOfMemory;
    hash.put(alloc, fam_key, .{ .string = fam_val }) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .hash = hash });
}

/// Raise a parse-time error naming the unenumerated build target. Mirrors the
/// boxed-error pattern parse-time words use; `handleParseTimeError` turns the
/// thrown error into a diagnostic at the accessor's call site.
fn throwUnsupportedTarget(ctx: *Context, word: []const u8, axis: []const u8, tag: []const u8) anyerror {
    const message = std.fmt.allocPrint(
        ctx.quotationAllocator(),
        "{s}: unrecognized build target {s} '{s}'",
        .{ word, axis, tag },
    ) catch return error.OutOfMemory;
    ctx.thrown_error = value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "unsupported-target",
        .message = message,
    }) catch return error.OutOfMemory;
    return error.UserThrown;
}

/// target-os ( -- symbol ) - Resolve at parse time to the build target's OS symbol
fn nativeTargetOs(ctx: *Context) anyerror!void {
    const os_name: []const u8 = switch (ctx.target_os) {
        .macos => "macos",
        .linux => "linux",
        else => return throwUnsupportedTarget(ctx, "target-os", "OS", @tagName(ctx.target_os)),
    };
    try ctx.stack.push(.{ .symbol = os_name });
}

/// target-arch ( -- symbol ) - Resolve at parse time to the build target's architecture symbol
fn nativeTargetArch(ctx: *Context) anyerror!void {
    const arch_name: []const u8 = switch (ctx.target_arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return throwUnsupportedTarget(ctx, "target-arch", "architecture", @tagName(ctx.target_arch)),
    };
    try ctx.stack.push(.{ .symbol = arch_name });
}

const testing = std.testing;

test "target-os returns the enumerated OS symbol" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    ctx.target_os = .macos;
    try nativeTargetOs(&ctx);
    try testing.expectEqualStrings("macos", (try ctx.stack.pop()).symbol);

    ctx.target_os = .linux;
    try nativeTargetOs(&ctx);
    try testing.expectEqualStrings("linux", (try ctx.stack.pop()).symbol);
}

test "target-arch returns the enumerated architecture symbol" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    ctx.target_arch = .aarch64;
    try nativeTargetArch(&ctx);
    try testing.expectEqualStrings("aarch64", (try ctx.stack.pop()).symbol);

    ctx.target_arch = .x86_64;
    try nativeTargetArch(&ctx);
    try testing.expectEqualStrings("x86_64", (try ctx.stack.pop()).symbol);
}

test "target-os errors on an unenumerated target" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    ctx.target_os = .windows;
    try testing.expectError(error.UserThrown, nativeTargetOs(&ctx));
    try testing.expectEqualStrings("unsupported-target", ctx.thrown_error.?.error_type);
    try testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}

test "target-arch errors on an unenumerated target" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    ctx.target_arch = .riscv64;
    try testing.expectError(error.UserThrown, nativeTargetArch(&ctx));
    try testing.expectEqualStrings("unsupported-target", ctx.thrown_error.?.error_type);
    try testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}
