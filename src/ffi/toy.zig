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
    .{ .name = "toy-add", .func = nativeToyAdd },
    .{ .name = "toy-strlen", .func = nativeToyStrlen },
    .{ .name = "toy-greeting", .func = nativeToyGreeting },
    .{ .name = "toy-checksum", .func = nativeToyChecksum },
    .{ .name = "toy-fill", .func = nativeToyFill },
    .{ .name = "toy-open", .func = nativeToyOpen },
    .{ .name = "toy-increment", .func = nativeToyIncrement },
    .{ .name = "toy-read", .func = nativeToyRead },
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
    const result = c.toy_checksum(ba.items.ptr, @intCast(ba.items.len));
    try ctx.stack.push(.{ .fixnum = @intCast(result) });
}

fn nativeToyFill(ctx: *Context) anyerror!void {
    const val = try helpers.popFixnum(ctx);
    const ba = try helpers.popByteArray(ctx);
    c.toy_fill(ba.items.ptr, @intCast(ba.items.len), @intCast(val));
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
        .close_fn = toyCloseFn,
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
