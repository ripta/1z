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
const container_backing = @import("../container_backing.zig");

// =============================================================================
// Native dispatch entry functions
// =============================================================================

fn nativeInspectGeneric(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(ctx.allocator);
    try val.write(buffer.writer(ctx.allocator));
    try helpers.pushOwnedString(ctx, try buffer.toOwnedSlice(ctx.allocator));
}

fn nativeAsStringGeneric(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(ctx.allocator);
    try val.write(buffer.writer(ctx.allocator));
    try helpers.pushOwnedString(ctx, try buffer.toOwnedSlice(ctx.allocator));
}

fn nativeAsStringPassthrough(ctx: *Context) anyerror!void {
    _ = ctx;
}

fn nativeAsStringSymbol(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    // The popped symbol's owning reference transfers into the pushed string, backing and all.
    try ctx.stack.pushMoved(.{ .string = val.symbol });
}

fn nativeAsStringMarker(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(value_mod.stringValue(val.marker.name));
}

// =============================================================================
// Registration of all native dispatch entries
// =============================================================================

pub fn registerNativeDispatch(dispatch: *DispatchTable, ctx: *Context) !void {
    const unary = ctx.getDispatchUnarySentinel();

    const inspect_type_names = [_][]const u8{
        "fixnum",      "float",        "bignum",
        "boolean",     "string",       "symbol",
        "array",       "quotation",    "hash",
        "vector",      "byte-array",   "set",
        "mutable-map", "stream",       "parameter",
        "module",      "marker",       "struct-type",
        "template",    "stack-effect", "error",
        "task",        "channel",      "iterator",
        "doc-string",  "type",         "unit",
    };

    const inspect_id = ctx.nativeDispatchId(.inspect);
    for (inspect_type_names) |name| {
        const tv = ctx.lookupBuiltinTypeValue(name).?;
        try dispatch.registerNative(inspect_id, tv, unary, nativeInspectGeneric);
    }

    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const symbol_tv = ctx.lookupBuiltinTypeValue("symbol").?;
    const marker_tv = ctx.lookupBuiltinTypeValue("marker").?;

    const to_string_id = ctx.nativeDispatchId(.to_string);
    for (inspect_type_names) |name| {
        const tv = ctx.lookupBuiltinTypeValue(name).?;
        if (tv == string_tv) {
            try dispatch.registerNative(to_string_id, tv, unary, nativeAsStringPassthrough);
        } else if (tv == symbol_tv) {
            try dispatch.registerNative(to_string_id, tv, unary, nativeAsStringSymbol);
        } else if (tv == marker_tv) {
            try dispatch.registerNative(to_string_id, tv, unary, nativeAsStringMarker);
        } else {
            try dispatch.registerNative(to_string_id, tv, unary, nativeAsStringGeneric);
        }
    }
}

pub const primitives = [_]Primitive{
    .{ .name = "inspect", .stack_effect = "value -- string", .doc = "Convert any value to its debug string representation, including quotes for strings.", .func = nativeInspect, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = ">string", .stack_effect = "value -- string", .doc = "Convert value to string, strings and symbols pass through as plain strings.", .func = nativeAsString, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = ">symbol", .stack_effect = "value -- symbol", .doc = "Convert a string to a symbol. Flat enum variants may define custom conversions; data-carrying variants are rejected.", .func = nativeToSymbol, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = ">quotation", .stack_effect = "name -- quotation", .doc = "Convert a string or symbol name to a quotation that calls that word. Does not check if the word exists.", .func = nativeToQuotation, .markers = &.{ @constCast(&markers_mod.interpreter_dependent_marker), @constCast(&markers_mod.dynamic_quotation_construction_marker) } },
    .{ .name = ">bytes", .stack_effect = "string -- byte-array", .doc = "Convert string to byte array (UTF-8 encoded bytes).", .func = nativeToBytes },
    .{ .name = "bytes>", .stack_effect = "byte-array -- string", .doc = "Convert byte array to string (interprets as UTF-8).", .func = nativeBytesToString },
    .{ .name = "uppercase", .stack_effect = "str -- str", .doc = "Convert ASCII letters to uppercase, non-ASCII bytes pass through.", .func = nativeUppercase },
    .{ .name = "lowercase", .stack_effect = "str -- str", .doc = "Convert ASCII letters to lowercase, non-ASCII bytes pass through.", .func = nativeLowercase },
    .{ .name = ">string-base", .stack_effect = "n base -- str", .doc = "Convert fixnum or bignum to string in the given base (2-36). Uses lowercase letters for digits above 9.", .func = nativeToStringBase },
};

/// inspect ( value -- string )
fn nativeInspect(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ctx.nativeDispatchId(.inspect))) return;

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(ctx.allocator);
    try val.write(buffer.writer(ctx.allocator));
    try helpers.pushOwnedString(ctx, try buffer.toOwnedSlice(ctx.allocator));
}

/// >string ( value -- string )
fn nativeAsString(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ctx.nativeDispatchId(.to_string))) return;

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(ctx.allocator);
    try val.write(buffer.writer(ctx.allocator));
    try helpers.pushOwnedString(ctx, try buffer.toOwnedSlice(ctx.allocator));
}

/// >symbol ( string -- symbol )
fn nativeToSymbol(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ctx.nativeDispatchId(.to_symbol))) return;

    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            // The popped string's owning reference transfers into the pushed symbol on
            // success; the error paths drop it instead.
            errdefer container_backing.releaseValue(val);
            if (s.bytes.len == 0) return error.InvalidArgument;
            if (s.bytes[0] == '"') return error.InvalidArgument;
            for (s.bytes) |c| {
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return error.InvalidArgument;
            }
            try ctx.stack.pushMoved(.{ .symbol = s });
        },
        else => {
            defer container_backing.releaseValue(val);
            helpers.setErrorHint(ctx, "use >string to convert a symbol to a string first");
            helpers.setTypeMismatchError(ctx, "string", val);
            return error.TypeMismatch;
        },
    }
}

/// >quotation ( name -- quotation )
///
/// The resulting quotation can be executed with `call`.
fn nativeToQuotation(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const name = switch (val) {
        .string, .symbol => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "string or symbol", val);
            return error.TypeMismatch;
        },
    };

    // The instruction outlives the popped value.
    const instrs = try alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = try alloc.dupe(u8, name) }, .line = 0 };

    try ctx.stack.push(.{ .quotation = .{ .instructions = instrs } });
}

/// >bytes ( string -- byte-array )
fn nativeToBytes(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .string => |s| {
            const alloc = ctx.quotationAllocator();
            const ba = ByteArray.create(alloc) catch return error.OutOfMemory;
            ba.ensureTotalCapacity(alloc, s.bytes.len) catch return error.OutOfMemory;
            for (s.bytes) |byte| {
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

/// bytes> ( byte-array -- string )
fn nativeBytesToString(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .byte_array => |b| {
            const result = ctx.allocator.dupe(u8, b.slice()) catch return error.OutOfMemory;
            try helpers.pushOwnedString(ctx, result);
        },
        else => {
            helpers.setTypeMismatchError(ctx, "byte-array", val);
            return error.TypeMismatch;
        },
    }
}

/// uppercase ( str -- str )
fn nativeUppercase(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .string => |s| {
            const result = ctx.allocator.alloc(u8, s.bytes.len) catch return error.OutOfMemory;
            @memcpy(result, s.bytes);
            simd.uppercaseAscii(result);
            try helpers.pushOwnedString(ctx, result);
        },
        else => {
            helpers.setErrorHint(ctx, "use >string to convert to a string first");
            helpers.setTypeMismatchError(ctx, "string", val);
            return error.TypeMismatch;
        },
    }
}

/// lowercase ( str -- str )
fn nativeLowercase(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .string => |s| {
            const result = ctx.allocator.alloc(u8, s.bytes.len) catch return error.OutOfMemory;
            @memcpy(result, s.bytes);
            simd.lowercaseAscii(result);
            try helpers.pushOwnedString(ctx, result);
        },
        else => {
            helpers.setErrorHint(ctx, "use >string to convert to a string first");
            helpers.setTypeMismatchError(ctx, "string", val);
            return error.TypeMismatch;
        },
    }
}

/// >string-base ( n base -- str )
fn nativeToStringBase(ctx: *Context) anyerror!void {
    const base_val = try helpers.popFixnum(ctx);
    if (base_val < 2 or base_val > 36) {
        helpers.setErrorContext(ctx, ">string-base: base must be 2-36, got {d}", .{base_val});
        return error.InvalidArgument;
    }
    const base: u8 = @intCast(base_val);

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);

    switch (val) {
        .fixnum => |i| {
            var big = try BigIntManaged.initSet(ctx.allocator, i);
            defer big.deinit();
            const str = try big.toConst().toStringAlloc(ctx.allocator, base, .lower);
            try helpers.pushOwnedString(ctx, str);
        },
        .bignum => |b| {
            const str = try b.big.toConst().toStringAlloc(ctx.allocator, base, .lower);
            try helpers.pushOwnedString(ctx, str);
        },
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum or bignum", val);
            return error.TypeMismatch;
        },
    }
}

test ">symbol transfers the popped string's backing to the symbol" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const bytes = try ctx.allocator.dupe(u8, "transfer");
    try helpers.pushOwnedString(&ctx, bytes);
    try nativeToSymbol(&ctx);

    const sym = try ctx.stack.pop();
    defer container_backing.releaseValue(sym);
    try std.testing.expect(sym == .symbol);
    try std.testing.expect(sym.symbol.backing != null);
    try std.testing.expectEqualStrings("transfer", sym.symbol.bytes);
}

test "pushOwnedString hands the stack the only reference" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const bytes = try ctx.allocator.dupe(u8, "owned");
    try helpers.pushOwnedString(&ctx, bytes);
    const pay = try helpers.popString(&ctx);
    defer container_backing.releaseValue(.{ .string = pay });
    try std.testing.expectEqualStrings("owned", pay.bytes);
}
