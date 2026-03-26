const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const ByteArray = value_mod.ByteArray;

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "to-string", .stack_effect = "value -- string", .func = nativeToString },
    .{ .name = ">string", .stack_effect = "value -- string", .func = nativeAsString },
    .{ .name = ">bytes", .stack_effect = "string -- byte-array", .func = nativeToBytes },
    .{ .name = "bytes>", .stack_effect = "byte-array -- string", .func = nativeBytesToString },
};

/// to-string ( value -- string ) - Convert any value to its string representation,
/// including quotes for strings
fn nativeToString(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    try val.write(buffer.writer(alloc));
    try ctx.stack.push(.{ .string = try buffer.toOwnedSlice(alloc) });
}

/// >string ( value -- string ) - Convert value to string, strings pass through unquoted,
/// in contrast to to-string
fn nativeAsString(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            try ctx.stack.push(.{ .string = s });
        },
        else => {
            const alloc = ctx.quotationAllocator();
            var buffer: std.ArrayListUnmanaged(u8) = .{};
            try val.write(buffer.writer(alloc));
            try ctx.stack.push(.{ .string = try buffer.toOwnedSlice(alloc) });
        },
    }
}

/// >bytes ( string -- byte-array ) - Convert string to byte array (UTF-8 encoded bytes)
fn nativeToBytes(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            const alloc = ctx.quotationAllocator();
            const ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            ba.* = ByteArray{};
            ba.ensureTotalCapacity(alloc, s.len) catch return error.OutOfMemory;
            for (s) |byte| {
                ba.appendAssumeCapacity(byte);
            }
            try ctx.stack.push(.{ .byte_array = ba });
        },
        else => return error.TypeMismatch,
    }
}

/// bytes> ( byte-array -- string ) - Convert byte array to string (interprets as UTF-8)
fn nativeBytesToString(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .byte_array => |b| {
            const alloc = ctx.quotationAllocator();
            const result = alloc.dupe(u8, b.items) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = result });
        },
        else => return error.TypeMismatch,
    }
}
