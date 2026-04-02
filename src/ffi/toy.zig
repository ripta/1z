const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../primitives/helpers.zig");
const error_mapping = @import("../primitives/error_mapping.zig");
const RegistryEntry = @import("../primitives/types.zig").RegistryEntry;
const Resource = @import("../value.zig").Resource;

const c = @cImport({
    @cInclude("toy.h");
});

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
    const b = try helpers.popFixnum(ctx);
    const a = try helpers.popFixnum(ctx);
    const result = c.toy_add(@intCast(a), @intCast(b));
    try ctx.stack.push(.{ .fixnum = @intCast(result) });
}

fn nativeToyStrlen(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();
    const s = try helpers.popString(ctx);
    const cstr = try alloc.dupeZ(u8, s);
    const result = c.toy_strlen(cstr);
    try ctx.stack.push(.{ .fixnum = @intCast(result) });
}

fn nativeToyGreeting(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();
    const s = try helpers.popString(ctx);
    const cstr = try alloc.dupeZ(u8, s);
    const cresult = c.toy_greeting(cstr) orelse return error.OutOfMemory;
    defer std.c.free(cresult);
    const span = std.mem.span(cresult);
    const result = try alloc.dupe(u8, span);
    try ctx.stack.push(.{ .string = result });
}

fn nativeToyChecksum(ctx: *Context) anyerror!void {
    const ba = try helpers.popByteArray(ctx);
    const bytes = ba.slice();
    const result = c.toy_checksum(bytes.ptr, @intCast(bytes.len));
    try ctx.stack.push(.{ .fixnum = @intCast(result) });
}

fn nativeToyFill(ctx: *Context) anyerror!void {
    const val = try helpers.popFixnum(ctx);
    const ba = try helpers.popByteArray(ctx);
    const bytes = ba.slice();
    c.toy_fill(bytes.ptr, @intCast(bytes.len), @intCast(val));
}

fn toyCloseFn(ptr: *anyopaque) void {
    c.toy_close(@ptrCast(@alignCast(ptr)));
}

fn nativeToyOpen(ctx: *Context) anyerror!void {
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
    const r = try helpers.popResource(ctx);
    try error_mapping.ensureResourceOpen(r);
    c.toy_increment(@ptrCast(@alignCast(r.ptr.?)));
}

fn nativeToyRead(ctx: *Context) anyerror!void {
    const r = try helpers.popResource(ctx);
    try error_mapping.ensureResourceOpen(r);
    const result = c.toy_read(@ptrCast(@alignCast(r.ptr.?)));
    try ctx.stack.push(.{ .fixnum = @intCast(result) });
}
