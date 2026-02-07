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
const Marker = value_mod.Marker;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;
const Task = @import("../task.zig").Task;

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
// Type utilities
// =============================================================================

/// Get the type name of a value as a string
pub fn valueTypeName(val: Value) []const u8 {
    return switch (val) {
        .integer => "integer",
        .boolean => "boolean",
        .string => "string",
        .symbol => "symbol",
        .array => "array",
        .quotation => "quotation",
        .hash => "hash",
        .vector => "vector",
        .byte_array => "byte-array",
        .set => "set",
        .mutable_map => "mutable-map",
        .stream => "stream",
        .parameter => "parameter",
        .module => "module",
        .marker => "marker",
        .struct_type => "struct-type",
        .struct_instance => "struct-instance",
        .tagged => |t| t.tag.name,
        .template => "template",
        .benchmark_report => "benchmark-report",
        .stack_effect => "stack-effect",
        .error_value => "error",
        .task => "task",
    };
}

/// Format a value briefly for error messages.
/// Returns a short representation suitable for inclusion in error text.
/// Strings and symbols are truncated to max_len characters.
pub fn formatValueBrief(allocator: Allocator, val: Value, max_len: usize) ![]const u8 {
    return switch (val) {
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .boolean => |b| allocator.dupe(u8, if (b) "t" else "f"),
        .string => |s| blk: {
            if (s.len <= max_len) {
                break :blk std.fmt.allocPrint(allocator, "\"{s}\"", .{s});
            } else {
                break :blk std.fmt.allocPrint(allocator, "\"{s}...\"", .{s[0..max_len]});
            }
        },
        .symbol => |s| blk: {
            if (s.len <= max_len) {
                break :blk std.fmt.allocPrint(allocator, "{s}:", .{s});
            } else {
                break :blk std.fmt.allocPrint(allocator, "{s}...:", .{s[0..max_len]});
            }
        },
        .array => |items| std.fmt.allocPrint(allocator, "array[{d}]", .{items.len}),
        .quotation => |q| std.fmt.allocPrint(allocator, "quotation[{d}]", .{q.instructions.len}),
        .hash => |h| std.fmt.allocPrint(allocator, "hash[{d}]", .{h.count()}),
        .vector => |v| std.fmt.allocPrint(allocator, "vector[{d}]", .{v.items.len}),
        .byte_array => |b| std.fmt.allocPrint(allocator, "byte-array[{d}]", .{b.items.len}),
        .set => |s| std.fmt.allocPrint(allocator, "set[{d}]", .{s.count()}),
        .mutable_map => |m| std.fmt.allocPrint(allocator, "mutable-map[{d}]", .{m.count()}),
        .stream => allocator.dupe(u8, "<stream>"),
        .parameter => |p| std.fmt.allocPrint(allocator, "<parameter {s}>", .{p.name}),
        .module => |m| std.fmt.allocPrint(allocator, "<module {s}>", .{m.name}),
        .marker => |m| std.fmt.allocPrint(allocator, "<marker {s}>", .{m.name}),
        .struct_type => |st| std.fmt.allocPrint(allocator, "<struct-type {s}>", .{st.name}),
        .struct_instance => |si| std.fmt.allocPrint(allocator, "<{s} instance>", .{si.struct_type.name}),
        .tagged => |t| std.fmt.allocPrint(allocator, "<{s}>", .{t.tag.name}),
        .template => allocator.dupe(u8, "<template>"),
        .benchmark_report => allocator.dupe(u8, "<benchmark-report>"),
        .stack_effect => allocator.dupe(u8, "<stack-effect>"),
        .error_value => |e| std.fmt.allocPrint(allocator, "<error {s}>", .{e.error_type}),
        .task => |t| std.fmt.allocPrint(allocator, "<task #{d}>", .{t.id}),
    };
}

// =============================================================================
// Error context helpers
// =============================================================================

/// Set a pending error message on the context for richer error reporting.
/// The message is arena-allocated and will be used by captureCallStackOnError
/// for the innermost call frame's message field.
pub fn setErrorContext(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    ctx.pending_error_message = std.fmt.allocPrint(ctx.arena.allocator(), fmt, args) catch null;
}

/// Set a pending error message, special case for type mismatch errors,
/// so we can include the actual value.
pub fn setTypeMismatchError(ctx: *Context, expected: []const u8, val: Value) void {
    const allocator = ctx.arena.allocator();
    const val_brief = formatValueBrief(allocator, val, 20) catch valueTypeName(val);
    ctx.pending_error_message = std.fmt.allocPrint(
        allocator,
        "expected {s}, got {s} {s}",
        .{ expected, valueTypeName(val), val_brief },
    ) catch null;
}

// =============================================================================
// Type-safe poppers
// =============================================================================

pub fn popInteger(ctx: *Context) !i64 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .integer => |i| i,
        else => {
            setTypeMismatchError(ctx, "integer", val);
            return error.TypeMismatch;
        },
    };
}

/// Pop a boolean value.
/// Only the explicit false value is false. All other values are true.
pub fn popBoolean(ctx: *Context) !bool {
    const val = try ctx.stack.pop();
    return switch (val) {
        .boolean => |b| b,
        else => true,
    };
}

pub fn popQuotation(ctx: *Context) !Quotation {
    const val = try ctx.stack.pop();
    return switch (val) {
        .quotation => |q| q,
        else => {
            setTypeMismatchError(ctx, "quotation", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popSymbol(ctx: *Context) ![]const u8 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .symbol => |s| s,
        else => {
            setTypeMismatchError(ctx, "symbol", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popString(ctx: *Context) ![]const u8 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .string => |s| s,
        else => {
            setTypeMismatchError(ctx, "string", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popStackEffect(ctx: *Context) !StackEffect {
    const val = try ctx.stack.pop();
    return switch (val) {
        .stack_effect => |se| se,
        else => {
            setTypeMismatchError(ctx, "stack-effect", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popVector(ctx: *Context) !*Vector {
    const val = try ctx.stack.pop();
    return switch (val) {
        .vector => |v| v,
        else => {
            setTypeMismatchError(ctx, "vector", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popByteArray(ctx: *Context) !*ByteArray {
    const val = try ctx.stack.pop();
    return switch (val) {
        .byte_array => |b| b,
        else => {
            setTypeMismatchError(ctx, "byte-array", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popStream(ctx: *Context) !*Stream {
    const val = try ctx.stack.pop();
    return switch (val) {
        .stream => |s| s,
        else => {
            setTypeMismatchError(ctx, "stream", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popModule(ctx: *Context) !*Module {
    const val = try ctx.stack.pop();
    return switch (val) {
        .module => |m| m,
        else => {
            setTypeMismatchError(ctx, "module", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popMarker(ctx: *Context) !*Marker {
    const val = try ctx.stack.pop();
    return switch (val) {
        .marker => |m| m,
        else => {
            setTypeMismatchError(ctx, "marker", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popStructType(ctx: *Context) !*StructType {
    const val = try ctx.stack.pop();
    return switch (val) {
        .struct_type => |st| st,
        else => {
            setTypeMismatchError(ctx, "struct-type", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popStructInstance(ctx: *Context) !*StructInstance {
    const val = try ctx.stack.pop();
    return switch (val) {
        .struct_instance => |si| si,
        else => {
            setTypeMismatchError(ctx, "struct-instance", val);
            return error.TypeMismatch;
        },
    };
}

pub fn popTask(ctx: *Context) !*Task {
    const val = try ctx.stack.pop();
    return switch (val) {
        .task => |t| t,
        else => {
            setTypeMismatchError(ctx, "task", val);
            return error.TypeMismatch;
        },
    };
}
