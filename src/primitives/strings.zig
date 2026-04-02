const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const BigIntManaged = value_mod.BigIntManaged;
const ByteArray = value_mod.ByteArray;
const Instruction = value_mod.Instruction;

const simd = @import("../simd.zig");
const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const dispatch_helpers = @import("dispatch_helpers.zig");
const dispatch_mod = @import("../dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;
const markers_mod = @import("markers.zig");

// =============================================================================
// Native dispatch entry functions
// =============================================================================

fn nativeInspectGeneric(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    try val.write(buffer.writer(alloc));
    try ctx.stack.push(.{ .string = try buffer.toOwnedSlice(alloc) });
}

fn nativeAsStringGeneric(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    try val.write(buffer.writer(alloc));
    try ctx.stack.push(.{ .string = try buffer.toOwnedSlice(alloc) });
}

fn nativeAsStringPassthrough(ctx: *Context) anyerror!void {
    _ = ctx;
}

fn nativeAsStringSymbol(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .string = val.symbol });
}

// =============================================================================
// Registration of all native dispatch entries
// =============================================================================

pub fn registerNativeDispatch(dispatch: *DispatchTable, ctx: *Context) !void {
    const unary = ctx.getDispatchUnarySentinel();

    const inspect_type_names = [_][]const u8{
        "fixnum",      "float",            "bignum",
        "boolean",     "string",           "symbol",
        "array",       "quotation",        "hash",
        "vector",      "byte-array",       "set",
        "mutable-map", "stream",           "parameter",
        "module",      "marker",           "struct-type",
        "template",    "benchmark-report", "stack-effect",
        "error",       "task",             "channel",
        "iterator",    "doc-string",       "type",
        "unit",
    };

    for (inspect_type_names) |name| {
        const tv = ctx.lookupBuiltinTypeValue(name).?;
        try dispatch.registerNative("inspect", tv, unary, nativeInspectGeneric);
    }

    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const symbol_tv = ctx.lookupBuiltinTypeValue("symbol").?;

    for (inspect_type_names) |name| {
        const tv = ctx.lookupBuiltinTypeValue(name).?;
        if (tv == string_tv) {
            try dispatch.registerNative(">string", tv, unary, nativeAsStringPassthrough);
        } else if (tv == symbol_tv) {
            try dispatch.registerNative(">string", tv, unary, nativeAsStringSymbol);
        } else {
            try dispatch.registerNative(">string", tv, unary, nativeAsStringGeneric);
        }
    }
}

pub const primitives = [_]Primitive{
    .{ .name = "inspect", .stack_effect = "value -- string", .doc = "Convert any value to its debug string representation, including quotes for strings.", .func = nativeInspect, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = ">string", .stack_effect = "value -- string", .doc = "Convert value to string, strings and symbols pass through as plain strings.", .func = nativeAsString, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = ">symbol", .stack_effect = "string -- symbol", .doc = "Convert string to symbol. The string must be a valid token: non-empty, no whitespace, no leading quote.", .func = nativeToSymbol },
    .{ .name = ">quotation", .stack_effect = "name -- quotation", .doc = "Convert a string or symbol name to a quotation that calls that word. Does not check if the word exists.", .func = nativeToQuotation },
    .{ .name = ">bytes", .stack_effect = "string -- byte-array", .doc = "Convert string to byte array (UTF-8 encoded bytes).", .func = nativeToBytes },
    .{ .name = "bytes>", .stack_effect = "byte-array -- string", .doc = "Convert byte array to string (interprets as UTF-8).", .func = nativeBytesToString },
    .{ .name = "uppercase", .stack_effect = "str -- str", .doc = "Convert ASCII letters to uppercase, non-ASCII bytes pass through.", .func = nativeUppercase },
    .{ .name = "lowercase", .stack_effect = "str -- str", .doc = "Convert ASCII letters to lowercase, non-ASCII bytes pass through.", .func = nativeLowercase },
    .{ .name = ">string-base", .stack_effect = "n base -- str", .doc = "Convert fixnum or bignum to string in the given base (2-36). Uses lowercase letters for digits above 9.", .func = nativeToStringBase },
};

/// inspect ( value -- string ) - Convert any value to its debug string representation,
/// including quotes for strings
fn nativeInspect(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "inspect")) return;

    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    try val.write(buffer.writer(alloc));
    try ctx.stack.push(.{ .string = try buffer.toOwnedSlice(alloc) });
}

/// >string ( value -- string ) - Convert value to string, strings pass through unquoted,
/// in contrast to inspect
fn nativeAsString(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ">string")) return;

    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    try val.write(buffer.writer(alloc));
    try ctx.stack.push(.{ .string = try buffer.toOwnedSlice(alloc) });
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
        else => {
            helpers.setErrorHint(ctx, "use >string to convert a symbol to a string first");
            helpers.setTypeMismatchError(ctx, "string", val);
            return error.TypeMismatch;
        },
    }
}

/// >quotation ( name -- quotation ) - Convert a string or symbol name to a quotation that calls that word
///
/// This does not check if the word exists, so it can be used to construct quotations
/// that call words that haven't been defined yet.
///
/// The resulting quotation will contain a single _instruction_: `call_word` with the given name.
/// The quotation itself can be executed using `call`.
fn nativeToQuotation(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const val = try ctx.stack.pop();
    const name = switch (val) {
        .string => |s| s,
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string or symbol", val);
            return error.TypeMismatch;
        },
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
        else => {
            helpers.setTypeMismatchError(ctx, "string", val);
            return error.TypeMismatch;
        },
    }
}

/// bytes> ( byte-array -- string ) - Convert byte array to string (interprets as UTF-8)
fn nativeBytesToString(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .byte_array => |b| {
            const alloc = ctx.quotationAllocator();
            const result = alloc.dupe(u8, b.slice()) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = result });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "byte-array", val);
            return error.TypeMismatch;
        },
    }
}

/// uppercase ( str -- str ) - Convert ASCII letters to uppercase, non-ASCII bytes pass through
fn nativeUppercase(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            const alloc = ctx.quotationAllocator();
            const result = alloc.alloc(u8, s.len) catch return error.OutOfMemory;
            @memcpy(result, s);
            simd.uppercaseAscii(result);
            try ctx.stack.push(.{ .string = result });
        },
        else => {
            helpers.setErrorHint(ctx, "use >string to convert to a string first");
            helpers.setTypeMismatchError(ctx, "string", val);
            return error.TypeMismatch;
        },
    }
}

/// lowercase ( str -- str ) - Convert ASCII letters to lowercase, non-ASCII bytes pass through
fn nativeLowercase(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            const alloc = ctx.quotationAllocator();
            const result = alloc.alloc(u8, s.len) catch return error.OutOfMemory;
            @memcpy(result, s);
            simd.lowercaseAscii(result);
            try ctx.stack.push(.{ .string = result });
        },
        else => {
            helpers.setErrorHint(ctx, "use >string to convert to a string first");
            helpers.setTypeMismatchError(ctx, "string", val);
            return error.TypeMismatch;
        },
    }
}

/// >string-base ( n base -- str ) - Convert fixnum or bignum to string in the given base (2-36)
fn nativeToStringBase(ctx: *Context) anyerror!void {
    const base_val = try helpers.popFixnum(ctx);
    if (base_val < 2 or base_val > 36) {
        helpers.setErrorContext(ctx, ">string-base: base must be 2-36, got {d}", .{base_val});
        return error.InvalidArgument;
    }
    const base: u8 = @intCast(base_val);

    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    switch (val) {
        .fixnum => |i| {
            var big = try BigIntManaged.initSet(alloc, i);
            const str = try big.toConst().toStringAlloc(alloc, base, .lower);
            try ctx.stack.push(.{ .string = str });
        },
        .bignum => |b| {
            const str = try b.toConst().toStringAlloc(alloc, base, .lower);
            try ctx.stack.push(.{ .string = str });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
            return error.TypeMismatch;
        },
    }
}
