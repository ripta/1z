const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const ByteArray = value_mod.ByteArray;
const Instruction = value_mod.Instruction;

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "to-string", .stack_effect = "value -- string", .doc = "Convert any value to its string representation, including quotes for strings.", .func = nativeToString },
    .{ .name = ">string", .stack_effect = "value -- string", .doc = "Convert value to string, strings and symbols pass through as plain strings.", .func = nativeAsString },
    .{ .name = ">symbol", .stack_effect = "string -- symbol", .doc = "Convert string to symbol. The string must be a valid token: non-empty, no whitespace, no leading quote.", .func = nativeToSymbol },
    .{ .name = ">word", .stack_effect = "name -- quotation", .doc = "Convert a string or symbol name to a quotation that calls that word. Does not check if the word exists.", .func = nativeToWord },
    .{ .name = ">bytes", .stack_effect = "string -- byte-array", .doc = "Convert string to byte array (UTF-8 encoded bytes).", .func = nativeToBytes },
    .{ .name = "bytes>", .stack_effect = "byte-array -- string", .doc = "Convert byte array to string (interprets as UTF-8).", .func = nativeBytesToString },
    .{ .name = "uppercase", .stack_effect = "str -- str", .doc = "Convert ASCII letters to uppercase, non-ASCII bytes pass through.", .func = nativeUppercase },
    .{ .name = "lowercase", .stack_effect = "str -- str", .doc = "Convert ASCII letters to lowercase, non-ASCII bytes pass through.", .func = nativeLowercase },
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
        .symbol => |s| {
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

/// >symbol ( string -- symbol ) - Convert string to symbol
fn nativeToSymbol(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            if (s.len == 0) return error.InvalidArgument;
            if (s[0] == '"') return error.InvalidArgument;
            for (s) |c| {
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return error.InvalidArgument;
            }
            try ctx.stack.push(.{ .symbol = s });
        },
        else => return error.TypeMismatch,
    }
}

/// >word ( name -- quotation ) - Convert a string or symbol name to a quotation that calls that word
fn nativeToWord(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const val = try ctx.stack.pop();
    const name = switch (val) {
        .string => |s| s,
        .symbol => |s| s,
        else => return error.TypeMismatch,
    };

    const instrs = try alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = name }, .line = 0 };

    try ctx.stack.push(.{ .quotation = .{ .instructions = instrs } });
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

/// uppercase ( str -- str ) - Convert ASCII letters to uppercase, non-ASCII bytes pass through
fn nativeUppercase(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            const alloc = ctx.quotationAllocator();
            const result = alloc.alloc(u8, s.len) catch return error.OutOfMemory;
            for (s, 0..) |c, i| {
                result[i] = std.ascii.toUpper(c);
            }
            try ctx.stack.push(.{ .string = result });
        },
        else => return error.TypeMismatch,
    }
}

/// lowercase ( str -- str ) - Convert ASCII letters to lowercase, non-ASCII bytes pass through
fn nativeLowercase(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            const alloc = ctx.quotationAllocator();
            const result = alloc.alloc(u8, s.len) catch return error.OutOfMemory;
            for (s, 0..) |c, i| {
                result[i] = std.ascii.toLower(c);
            }
            try ctx.stack.push(.{ .string = result });
        },
        else => return error.TypeMismatch,
    }
}
