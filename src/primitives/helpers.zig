const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const Vector = value_mod.Vector;
const ByteArray = value_mod.ByteArray;
const Stream = value_mod.Stream;
const BigIntManaged = value_mod.BigIntManaged;
const Module = value_mod.Module;
const Marker = value_mod.Marker;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;
const Task = @import("../task.zig").Task;
const Channel = @import("../channel.zig").Channel;
const dispatch_mod = @import("../dispatch.zig");
const container_backing = @import("../container_backing.zig");

const stack_effect_mod = @import("../stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;
const TypeValue = value_mod.TypeValue;

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
                try current_list.append(allocator, .{ .name = name, .is_row_variable = stack_effect_mod.isRowVariable(name) });
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
                    .is_row_variable = stack_effect_mod.isRowVariable(name),
                });
                pending_name = null;
            }
            continue;
        }

        // Flush previous pending parameter
        if (pending_name) |name| {
            try current_list.append(allocator, .{ .name = name, .is_row_variable = stack_effect_mod.isRowVariable(name) });
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
        try current_list.append(allocator, .{ .name = name, .is_row_variable = stack_effect_mod.isRowVariable(name) });
    }

    return StackEffect{
        .inputs = try inputs.toOwnedSlice(allocator),
        .outputs = try outputs.toOwnedSlice(allocator),
    };
}

/// Resolve the runtime TypeValue for an arbitrary value using the same rules as
/// dispatch and `type-of`.
pub fn resolveValueTypeValue(ctx: *Context, val: Value) ?*const TypeValue {
    return dispatch_mod.dispatchTypeValue(val, ctx);
}

/// Check whether an actual type satisfies an expected type constraint. Supports anonymous union constraints
/// on the expected type.
pub fn typeMatchesConstraint(actual_tv: *const TypeValue, expected_tv: *const TypeValue) bool {
    if (actual_tv == expected_tv) return true;

    if (expected_tv.member_types) |members| {
        for (members) |member_tv| {
            if (typeMatchesConstraint(actual_tv, member_tv)) return true;
        }
        return false;
    }

    return false;
}

/// Check whether a value satisfies an expected type annotation.
/// Supports `any`, enum parent types, and tagged base types.
pub fn valueMatchesType(ctx: *Context, val: Value, expected_tv: *const TypeValue) bool {
    if (ctx.any_type_sentinel) |any_tv| {
        if (expected_tv == any_tv) return true;
    }

    const actual_tv = resolveValueTypeValue(ctx, val) orelse return false;
    if (typeMatchesConstraint(actual_tv, expected_tv)) return true;

    if (val == .tagged) {
        if (val.tagged.tag.parent_type) |pt| {
            if (typeMatchesConstraint(pt, expected_tv)) return true;
        }
        if (val.tagged.tag.base_type) |bt| {
            if (typeMatchesConstraint(bt, expected_tv)) return true;
        }
    }

    return false;
}

const testing = std.testing;

test "valueMatchesType accepts values matching anonymous union members" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const union_tv = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ string_tv, fixnum_tv });

    try testing.expect(valueMatchesType(&ctx, .{ .fixnum = 42 }, union_tv));
    try testing.expect(valueMatchesType(&ctx, .{ .string = "ok" }, union_tv));
    try testing.expect(!valueMatchesType(&ctx, .{ .boolean = true }, union_tv));
}

test "typeMatchesConstraint accepts exact and anonymous union matches" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const boolean_tv = ctx.lookupBuiltinTypeValue("boolean").?;
    const union_tv = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ string_tv, fixnum_tv });

    try testing.expect(typeMatchesConstraint(fixnum_tv, fixnum_tv));
    try testing.expect(typeMatchesConstraint(fixnum_tv, union_tv));
    try testing.expect(typeMatchesConstraint(string_tv, union_tv));
    try testing.expect(!typeMatchesConstraint(boolean_tv, union_tv));
}

test "valueMatchesType preserves tagged parent and base type checks" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const array_tv = ctx.lookupBuiltinTypeValue("array").?;

    var parent_tv = TypeValue{ .name = "color", .descriptor = null };
    var base_tv = TypeValue{ .name = "array(fixnum)", .descriptor = null };
    const variant_virtual = try testing.allocator.create(value_mod.VirtualType);
    defer testing.allocator.destroy(variant_virtual);
    variant_virtual.* = .{
        .name = "color:red",
        .inner_type = "symbol",
        .parent_type = &parent_tv,
        .base_type = array_tv,
    };

    const tagged_inner = try testing.allocator.create(Value);
    defer testing.allocator.destroy(tagged_inner);
    tagged_inner.* = .{ .symbol = "red" };

    const tagged = Value{ .tagged = .{
        .tag = variant_virtual,
        .inner = tagged_inner,
    } };

    try testing.expect(valueMatchesType(&ctx, tagged, &parent_tv));
    try testing.expect(valueMatchesType(&ctx, tagged, array_tv));
    try testing.expect(!valueMatchesType(&ctx, tagged, &base_tv));
}

// =============================================================================
// Type utilities
// =============================================================================

/// Get the type name of a value as a string
pub fn valueTypeName(val: Value) []const u8 {
    return switch (val) {
        .fixnum => "fixnum",
        .float => "float",
        .bignum => "bignum",
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
        .resource => "resource",
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
        .channel => "channel",
        .iterator => "iterator",
        .doc_string => "doc-string",
        .type_val => "type",
        .type_descriptor => "type-descriptor",
        .protocol_descriptor => "constraint",
        .constraint_combinator => "constraint",
        .sandbox_spec => "sandbox-spec",
        .unit => "unit",
    };
}

/// Format a value briefly for error messages.
/// Returns a short representation suitable for inclusion in error text.
/// Strings and symbols are truncated to max_len characters.
pub fn formatValueBrief(allocator: Allocator, val: Value, max_len: usize) ![]const u8 {
    return switch (val) {
        .fixnum => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .bignum => |b| b.toConst().toStringAlloc(allocator, 10, .lower) catch
            allocator.dupe(u8, "<bignum>"),
        .float => |f| blk: {
            if (std.math.isNan(f)) break :blk allocator.dupe(u8, "nan");
            if (std.math.isInf(f)) {
                break :blk allocator.dupe(u8, if (f < 0) "-inf" else "inf");
            }
            var buf: [64]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "{d}", .{f}) catch break :blk allocator.dupe(u8, "?");
            if (std.mem.indexOfScalar(u8, formatted, '.') == null) {
                break :blk std.fmt.allocPrint(allocator, "{s}.0", .{formatted});
            }
            break :blk allocator.dupe(u8, formatted);
        },
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
        .vector => |v| std.fmt.allocPrint(allocator, "vector[{d}]", .{v.list.items.len}),
        .byte_array => |b| std.fmt.allocPrint(allocator, "byte-array[{d}]", .{b.slice().len}),
        .set => |s| std.fmt.allocPrint(allocator, "set[{d}]", .{s.count()}),
        .mutable_map => |m| std.fmt.allocPrint(allocator, "mutable-map[{d}]", .{m.map.count()}),
        .stream => allocator.dupe(u8, "<stream>"),
        .resource => |r| std.fmt.allocPrint(allocator, "<resource:{s}>", .{r.type_name}),
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
        .channel => allocator.dupe(u8, "<channel>"),
        .iterator => allocator.dupe(u8, "<iterator>"),
        .doc_string => |s| std.fmt.allocPrint(allocator, "<doc-string \"{s}\">", .{s}),
        .type_val => |tv| std.fmt.allocPrint(allocator, "<type:{s}>", .{tv.name}),
        .type_descriptor => |desc| std.fmt.allocPrint(
            allocator,
            "<type-descriptor:{s}>",
            .{value_mod.typeKindSymbol(desc.kind)},
        ),
        .protocol_descriptor => |desc| std.fmt.allocPrint(
            allocator,
            "<protocol-descriptor:{s}>",
            .{desc.name},
        ),
        .constraint_combinator => |cc| std.fmt.allocPrint(
            allocator,
            "<constraint-combinator:{d}>",
            .{cc.combinator_id},
        ),
        .sandbox_spec => allocator.dupe(u8, "<sandbox-spec>"),
        .unit => allocator.dupe(u8, "unit"),
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

/// Set a pending error hint to be displayed alongside the error message.
/// The hint string should be a comptime literal or arena-allocated.
pub fn setErrorHint(ctx: *Context, hint: []const u8) void {
    ctx.pending_error_hint = hint;
}

/// Report that a word is not available on the current build target.
/// Used by capability-gated primitives in freestanding builds where the
/// underlying OS surface is unavailable. The dispatch-time sandbox check
/// produces a similar error for hosted builds when a sandbox denies the
/// capability; this helper signals a structurally different condition --
/// the OS surface itself does not exist in this build.
pub fn throwBuildUnsupported(ctx: *Context, word_name: []const u8) error{BuildUnsupported} {
    setErrorContext(ctx, "'{s}' is not available on this build", .{word_name});
    return error.BuildUnsupported;
}

// =============================================================================
// Type-safe poppers
// =============================================================================

/// Generic type-safe pop: extract a single union variant or report a type mismatch.
pub fn popAs(comptime tag: std.meta.Tag(Value), ctx: *Context) !std.meta.TagPayload(Value, tag) {
    const val = try ctx.stack.pop();
    switch (val) {
        tag => |payload| return payload,
        else => {
            setTypeMismatchError(ctx, comptime tagDisplayName(tag), val);
            container_backing.releaseValue(val);
            return error.TypeMismatch;
        },
    }
}

fn tagDisplayName(comptime tag: std.meta.Tag(Value)) []const u8 {
    comptime {
        const name = @tagName(tag);
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| {
            buf[i] = if (c == '_') '-' else c;
        }
        const final = buf;
        return &final;
    }
}

pub fn popFixnum(ctx: *Context) !i64 {
    return popAs(.fixnum, ctx);
}

/// Pop a boolean value.
/// Only the explicit false value is false. All other values are true.
pub fn popBoolean(ctx: *Context) !bool {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    return switch (val) {
        .boolean => |b| b,
        else => true,
    };
}

pub fn popQuotation(ctx: *Context) !Quotation {
    return popAs(.quotation, ctx);
}

pub fn popSymbol(ctx: *Context) ![]const u8 {
    return popAs(.symbol, ctx);
}

pub fn popString(ctx: *Context) ![]const u8 {
    return popAs(.string, ctx);
}

pub fn popStackEffect(ctx: *Context) !StackEffect {
    return popAs(.stack_effect, ctx);
}

pub fn popVector(ctx: *Context) !*Vector {
    return popAs(.vector, ctx);
}

pub fn popByteArray(ctx: *Context) !*ByteArray {
    return popAs(.byte_array, ctx);
}

pub fn popStream(ctx: *Context) !*Stream {
    return popAs(.stream, ctx);
}

pub fn popResource(ctx: *Context) !*value_mod.Resource {
    return popAs(.resource, ctx);
}

pub fn popModule(ctx: *Context) !*Module {
    return popAs(.module, ctx);
}

pub fn popMarker(ctx: *Context) !*Marker {
    return popAs(.marker, ctx);
}

pub fn popTypeVal(ctx: *Context) !*value_mod.TypeValue {
    return popAs(.type_val, ctx);
}

pub fn popStructType(ctx: *Context) !*StructType {
    return popAs(.struct_type, ctx);
}

pub fn popStructInstance(ctx: *Context) !*StructInstance {
    return popAs(.struct_instance, ctx);
}

pub fn popTask(ctx: *Context) !*Task {
    return popAs(.task, ctx);
}

pub fn popChannel(ctx: *Context) !*Channel {
    return popAs(.channel, ctx);
}

// =============================================================================
// Number helpers (fixnum/float promotion)
// =============================================================================

pub const Number = union(enum) {
    fixnum: i64,
    float: f64,
};

pub fn popNumber(ctx: *Context) !Number {
    const val = try ctx.stack.pop();
    return switch (val) {
        .fixnum => |i| .{ .fixnum = i },
        .float => |f| .{ .float = f },
        else => {
            setTypeMismatchError(ctx, "number", val);
            return error.TypeMismatch;
        },
    };
}

pub fn toFloats(a: Number, b: Number) [2]f64 {
    return .{
        switch (a) {
            .fixnum => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
        },
        switch (b) {
            .fixnum => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
        },
    };
}

/// Pop a duration value (tagged fixnum with inner_type "fixnum") and return
/// the raw nanosecond count plus the original Value for re-use.
pub fn popDuration(ctx: *Context) !struct { ns: i128, val: Value } {
    const val = try ctx.stack.pop();
    return switch (val) {
        .tagged => |t| {
            if (!std.mem.eql(u8, t.tag.inner_type, "fixnum")) {
                setTypeMismatchError(ctx, "duration", val);
                return error.TypeMismatch;
            }
            return switch (t.inner.*) {
                .fixnum => |i| .{ .ns = @as(i128, i), .val = val },
                else => {
                    setTypeMismatchError(ctx, "duration", val);
                    return error.TypeMismatch;
                },
            };
        },
        else => {
            setTypeMismatchError(ctx, "duration", val);
            return error.TypeMismatch;
        },
    };
}

/// Return fixnum if the bignum fits in i64, otherwise box the bignum on
/// `alloc` and wrap it as a `bignum` Value. The boxed `BigIntManaged`
/// header lives on `alloc`; its limb array continues to be owned by
/// `big.allocator`. Both are typically `ctx.arena.allocator()`.
pub fn demoteBignum(alloc: Allocator, big: BigIntManaged) !Value {
    if (big.fits(i64)) {
        return .{ .fixnum = big.toInt(i64) catch unreachable };
    }
    return .{ .bignum = try value_mod.boxBigInt(alloc, big) };
}

/// Promote a fixnum to a Managed bignum. Bignums are cloned so the result
/// always owns its own memory.
pub fn ensureBignum(alloc: Allocator, val: Value) !BigIntManaged {
    return if (val == .bignum) try val.bignum.clone() else try BigIntManaged.initSet(alloc, val.fixnum);
}

/// Build a stack effect string for a constructor: "field1 field2 ... -- output_name"
pub fn buildConstructorEffectStr(allocator: Allocator, fields: []const []const u8, output_name: []const u8) ![]const u8 {
    var parts = std.ArrayListUnmanaged([]const u8){};
    defer parts.deinit(allocator);
    for (fields) |f| {
        try parts.append(allocator, f);
    }
    try parts.append(allocator, "--");
    try parts.append(allocator, output_name);
    return std.mem.join(allocator, " ", parts.items);
}

/// Build a stack effect string for a destructor: "input_name -- field1 field2 ..."
pub fn buildDestructorEffectStr(allocator: Allocator, fields: []const []const u8, input_name: []const u8) ![]const u8 {
    var parts = std.ArrayListUnmanaged([]const u8){};
    defer parts.deinit(allocator);
    try parts.append(allocator, input_name);
    try parts.append(allocator, "--");
    for (fields) |f| {
        try parts.append(allocator, f);
    }
    return std.mem.join(allocator, " ", parts.items);
}

/// Check if the current task has a pending cancellation and inject the
/// `task-cancelled` error. Called at resume points: after yield, sleep,
/// channel ops, I/O suspend, scope suspend. Cancelled tasks should unwind
/// coöperatively through their cleanup handlers.
pub fn checkCancellation(ctx: *Context) error{UserThrown}!void {
    const scheduler = ctx.scheduler orelse return;
    const current = scheduler.current_task orelse return;

    // Task-level cancellation: if this task was individually cancelled,
    // it should observe said cancellation as soon as it reaches a yield
    // point and unwind immediately.
    if (current.getCancellationPhase() == .pending) {
        current.setCancellationPhase(.unwinding);
        ctx.thrown_error = value_mod.boxErrorObject(ctx.quotationAllocator(), .{
            .error_type = "task-cancelled",
            .message = "task was cancelled",
        }) catch return error.UserThrown;
        return error.UserThrown;
    }

    // Scope-level cancellation: if a sibling failed and the scope flagged
    // cancellation, tasks that yield can observe it without waiting for the
    // scheduler to individually cancelTask each sibling.
    if (current.getCancellationPhase() == .none and
        current.scope.cancellation_requested.load(.acquire) and
        current != (current.scope.scope_task orelse current))
    {
        current.setCancellationPhase(.unwinding);
        ctx.thrown_error = value_mod.boxErrorObject(ctx.quotationAllocator(), .{
            .error_type = "task-cancelled",
            .message = "task was cancelled",
        }) catch return error.UserThrown;
        return error.UserThrown;
    }
}
