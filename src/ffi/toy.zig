const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../context.zig").Context;
const helpers = @import("../primitives/helpers.zig");
const error_mapping = @import("../primitives/error_mapping.zig");
const RegistryEntry = @import("../primitives/types.zig").RegistryEntry;
const value_mod = @import("../value.zig");
const Resource = value_mod.Resource;
const container_backing = @import("../container_backing.zig");

// The toy demo library is a C source excluded from the link on freestanding targets (see
// build.zig's createCommonModule), so its header is not on the include path there either.
const is_freestanding = builtin.os.tag == .freestanding;

const c = if (!is_freestanding) @cImport({
    @cInclude("toy.h");
}) else struct {};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "toy-add", .func = nativeToyAdd, .capability = .ffi },
    .{ .name = "toy-strlen", .func = nativeToyStrlen, .capability = .ffi },
    .{ .name = "toy-greeting", .func = nativeToyGreeting, .capability = .ffi },
    .{ .name = "toy-checksum", .func = nativeToyChecksum, .capability = .ffi },
    .{ .name = "toy-fill", .func = nativeToyFill, .capability = .ffi },
    .{ .name = "toy-open", .func = nativeToyOpen, .capability = .ffi },
    .{ .name = "toy-increment", .func = nativeToyIncrement, .capability = .ffi },
    .{ .name = "toy-read", .func = nativeToyRead, .capability = .ffi },
};

fn nativeToyAdd(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "toy-add");

    const b = try helpers.popFixnum(ctx);
    const a = try helpers.popFixnum(ctx);
    const result = c.toy_add(@intCast(a), @intCast(b));
    try ctx.stack.push(.{ .fixnum = @intCast(result) });
}

fn nativeToyStrlen(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "toy-strlen");

    const alloc = ctx.arena.allocator();
    const s = try helpers.popString(ctx);
    defer container_backing.releaseValue(.{ .string = s });
    const cstr = try alloc.dupeZ(u8, s.bytes);
    const result = c.toy_strlen(cstr);
    try ctx.stack.push(.{ .fixnum = @intCast(result) });
}

fn nativeToyGreeting(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "toy-greeting");

    const alloc = ctx.arena.allocator();
    const s = try helpers.popString(ctx);
    defer container_backing.releaseValue(.{ .string = s });
    const cstr = try alloc.dupeZ(u8, s.bytes);
    const cresult = c.toy_greeting(cstr) orelse return error.OutOfMemory;
    defer std.c.free(cresult);
    const span = std.mem.span(cresult);
    const result = try ctx.allocator.dupe(u8, span);
    try helpers.pushOwnedString(ctx, result);
}

fn nativeToyChecksum(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "toy-checksum");

    const ba = try helpers.popByteArray(ctx);
    defer container_backing.releaseValue(.{ .byte_array = ba });
    const bytes = ba.slice();
    const result = c.toy_checksum(bytes.ptr, @intCast(bytes.len));
    try ctx.stack.push(.{ .fixnum = @intCast(result) });
}

fn nativeToyFill(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "toy-fill");

    const val = try helpers.popFixnum(ctx);
    const ba = try helpers.popByteArray(ctx);
    defer container_backing.releaseValue(.{ .byte_array = ba });
    const bytes = ba.slice();
    c.toy_fill(bytes.ptr, @intCast(bytes.len), @intCast(val));
}

fn toyCloseFn(ptr: *anyopaque) void {
    c.toy_close(@ptrCast(@alignCast(ptr)));
}

fn nativeToyOpen(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "toy-open");

    const alloc = ctx.arena.allocator();
    const cptr = c.toy_open() orelse return error.OutOfMemory;
    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "toy-counter",
        .ptr = @ptrCast(cptr),
        .closed = false,
        .close_fn = .{ .native = toyCloseFn },
    };
    try ctx.stack.push(.{ .resource = r });
}

fn nativeToyIncrement(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "toy-increment");

    const r = try helpers.popResource(ctx);
    try error_mapping.ensureResourceOpen(r);
    c.toy_increment(@ptrCast(@alignCast(r.ptr.?)));
}

fn nativeToyRead(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "toy-read");

    const r = try helpers.popResource(ctx);
    try error_mapping.ensureResourceOpen(r);
    const result = c.toy_read(@ptrCast(@alignCast(r.ptr.?)));
    try ctx.stack.push(.{ .fixnum = @intCast(result) });
}
