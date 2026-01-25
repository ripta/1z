const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const Vector = value_mod.Vector;
const ByteArray = value_mod.ByteArray;
const Stream = value_mod.Stream;
const Module = value_mod.Module;

const StackEffect = @import("../stack_effect.zig").StackEffect;
const StackEffectParam = @import("../stack_effect.zig").StackEffectParam;

/// Create a stack effect from a raw string at runtime.
/// Supports quotation annotations like "seq quot: ( elem -- elem' ) -- seq'"
pub fn makeSimpleEffect(allocator: Allocator, raw: []const u8) !StackEffect {
    var inputs: std.ArrayListUnmanaged(StackEffectParam) = .{};
    errdefer inputs.deinit(allocator);
    var outputs: std.ArrayListUnmanaged(StackEffectParam) = .{};
    errdefer outputs.deinit(allocator);

    var iter = std.mem.splitScalar(u8, raw, ' ');
    var current_list = &inputs;
    var pending_name: ?[]const u8 = null;

    while (iter.next()) |token| {
        if (token.len == 0) continue;

        if (std.mem.eql(u8, token, "--")) {
            // Flush pending parameter
            if (pending_name) |name| {
                try current_list.append(allocator, .{ .name = name });
                pending_name = null;
            }
            current_list = &outputs;
            continue;
        }

        if (std.mem.eql(u8, token, "(")) {
            // Start of nested effect - parse until matching )
            if (pending_name) |name| {
                var nested_tokens: std.ArrayListUnmanaged([]const u8) = .{};
                defer nested_tokens.deinit(allocator);
                var depth: usize = 1;

                while (iter.next()) |nested_token| {
                    if (std.mem.eql(u8, nested_token, "(")) {
                        depth += 1;
                        try nested_tokens.append(allocator, nested_token);
                    } else if (std.mem.eql(u8, nested_token, ")")) {
                        depth -= 1;
                        if (depth == 0) break;
                        try nested_tokens.append(allocator, nested_token);
                    } else {
                        try nested_tokens.append(allocator, nested_token);
                    }
                }

                // Join and recursively parse (don't free nested_str - arena will handle it)
                const nested_str = try std.mem.join(allocator, " ", nested_tokens.items);
                const nested_effect = try makeSimpleEffect(allocator, nested_str);
                const nested_ptr = try allocator.create(StackEffect);
                nested_ptr.* = nested_effect;

                try current_list.append(allocator, .{
                    .name = name,
                    .quotation_effect = nested_ptr,
                });
                pending_name = null;
            }
            continue;
        }

        // Flush previous pending parameter
        if (pending_name) |name| {
            try current_list.append(allocator, .{ .name = name });
        }

        // Check if this token ends with : (annotation marker)
        if (token.len > 1 and token[token.len - 1] == ':') {
            pending_name = token[0 .. token.len - 1];
        } else {
            pending_name = token;
        }
    }

    // Flush final pending parameter
    if (pending_name) |name| {
        try current_list.append(allocator, .{ .name = name });
    }

    return StackEffect{
        .inputs = try inputs.toOwnedSlice(allocator),
        .outputs = try outputs.toOwnedSlice(allocator),
    };
}

// =============================================================================
// Type-safe poppers
// =============================================================================

pub fn popInteger(ctx: *Context) !i64 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .integer => |i| i,
        .boolean, .string, .symbol, .array, .quotation, .hash, .vector, .byte_array, .set, .mutable_map, .stream, .parameter, .module => error.TypeError,
        .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

pub fn popBoolean(ctx: *Context) !bool {
    const val = try ctx.stack.pop();
    return switch (val) {
        .boolean => |b| b,
        .integer => |i| i != 0,
        .string, .symbol, .array, .quotation, .hash, .vector, .byte_array, .set, .mutable_map, .stream, .parameter, .module => error.TypeError,
        .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

pub fn popQuotation(ctx: *Context) !Quotation {
    const val = try ctx.stack.pop();
    return switch (val) {
        .quotation => |q| q,
        .integer, .boolean, .string, .symbol, .array, .hash, .vector, .byte_array, .set, .mutable_map, .stream, .parameter, .module => error.TypeError,
        .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

pub fn popSymbol(ctx: *Context) ![]const u8 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .symbol => |s| s,
        .integer, .boolean, .string, .array, .quotation, .hash, .vector, .byte_array, .set, .mutable_map, .stream, .parameter, .module => error.TypeError,
        .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

pub fn popString(ctx: *Context) ![]const u8 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .string => |s| s,
        .integer, .boolean, .symbol, .array, .quotation, .hash, .vector, .byte_array, .set, .mutable_map, .stream, .parameter, .module => error.TypeError,
        .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

pub fn popStackEffect(ctx: *Context) !StackEffect {
    const val = try ctx.stack.pop();
    return switch (val) {
        .stack_effect => |se| se,
        .integer, .boolean, .string, .symbol, .array, .quotation, .hash, .vector, .byte_array, .set, .mutable_map, .stream, .parameter, .module => error.TypeError,
        .parse_time_marker, .error_value => error.TypeError,
    };
}

pub fn popVector(ctx: *Context) !*Vector {
    const val = try ctx.stack.pop();
    return switch (val) {
        .vector => |v| v,
        .integer, .boolean, .string, .symbol, .array, .quotation, .hash, .byte_array, .set, .mutable_map, .stream, .parameter, .module => error.TypeError,
        .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

pub fn popByteArray(ctx: *Context) !*ByteArray {
    const val = try ctx.stack.pop();
    return switch (val) {
        .byte_array => |b| b,
        .integer, .boolean, .string, .symbol, .array, .quotation, .hash, .vector, .set, .mutable_map, .stream, .parameter, .module => error.TypeError,
        .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

pub fn popStream(ctx: *Context) !*Stream {
    const val = try ctx.stack.pop();
    return switch (val) {
        .stream => |s| s,
        .integer, .boolean, .string, .symbol, .array, .quotation, .hash, .vector, .byte_array, .set, .mutable_map, .parameter, .module => error.TypeError,
        .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

pub fn popModule(ctx: *Context) !*Module {
    const val = try ctx.stack.pop();
    return switch (val) {
        .module => |m| m,
        .integer, .boolean, .string, .symbol, .array, .quotation, .hash, .vector, .byte_array, .set, .mutable_map, .stream, .parameter => error.TypeError,
        .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}
