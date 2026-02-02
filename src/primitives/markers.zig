const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Marker = value_mod.Marker;
const Value = value_mod.Value;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

/// Well-known marker for parse-time word definitions.
/// This is a compile-time constant with identity semantics.
pub const parse_time_marker: Marker = .{ .name = "parse-time" };

/// Well-known marker for mutable struct definitions.
/// When present on a struct, setters (>>field) are generated in addition to getters.
pub const mutable_marker: Marker = .{ .name = "mutable" };

pub const primitives = [_]Primitive{
    .{ .name = "marker", .stack_effect = "-- marker", .func = nativeMarker },
    .{ .name = "parse-time", .stack_effect = "-- marker", .func = nativeParseTimeMarker, .parse_time = true },
    .{ .name = "mutable", .stack_effect = "-- marker", .func = nativeMutableMarker, .parse_time = true },
    .{ .name = "word-markers", .stack_effect = "name -- markers", .func = nativeWordMarkers },
    .{ .name = "native?", .stack_effect = "name -- ?", .func = nativeIsNative },
};

/// marker ( -- marker ) - Create an anonymous marker value
/// The marker gets its name when defined with ;
pub fn nativeMarker(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const marker = try alloc.create(Marker);
    marker.* = .{ .name = "" }; // Anonymous until defined
    try ctx.stack.push(.{ .marker = marker });
}

/// parse-time ( -- marker ) - Push the well-known parse-time marker
/// This marker indicates that a word should be executed at parse time.
pub fn nativeParseTimeMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&parse_time_marker) });
}

/// mutable ( -- marker ) - Push the well-known mutable marker
/// This marker indicates that a struct should generate setters in addition to getters.
pub fn nativeMutableMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&mutable_marker) });
}

/// Check if a marker is the well-known mutable marker
pub fn isMutableMarker(mk: *const Marker) bool {
    return mk == &mutable_marker;
}

/// Check if a marker is the well-known parse-time marker
pub fn isParseTimeMarker(mk: *const Marker) bool {
    return mk == &parse_time_marker;
}

/// word-markers ( name -- markers ) - Get the markers attached to a word definition
///
/// Returns an array of marker values. Returns empty array if word has no markers.
/// Raises WordNotFound if the word doesn't exist.
fn nativeWordMarkers(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol, .string => |s| s,
        else => {
            const type_name = helpers.valueTypeName(name_val);
            const msg = std.fmt.allocPrint(alloc, "expected symbol or string, got {s}", .{type_name}) catch "expected symbol or string";
            ctx.error_details.append(ctx.allocator, .{
                .error_type = "type-mismatch",
                .message = msg,
                .source = ctx.current_source,
                .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
                .word_name = "word-markers",
            }) catch {};
            return error.TypeMismatch;
        },
    };

    const word_def = ctx.lookupWord(name) orelse {
        const msg = std.fmt.allocPrint(alloc, "word '{s}'", .{name}) catch "word '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "word-not-found",
            .message = msg,
            .source = ctx.current_source,
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "word-markers",
        }) catch {};
        return error.WordNotFound;
    };

    const markers = word_def.markers;
    const result = try alloc.alloc(Value, markers.len);
    for (markers, 0..) |mk, i| {
        result[i] = .{ .marker = @constCast(mk) };
    }

    try ctx.stack.push(.{ .array = result });
}

/// native? ( name -- ? ) - Check if a word is implemented as a native primitive
///
/// Returns true if the word exists and is a native implementation, false if
/// it exists but is a compound (user-defined) word.
/// Raises WordNotFound if the word doesn't exist.
fn nativeIsNative(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol, .string => |s| s,
        else => {
            const type_name = helpers.valueTypeName(name_val);
            const msg = std.fmt.allocPrint(alloc, "expected symbol or string, got {s}", .{type_name}) catch "expected symbol or string";
            ctx.error_details.append(ctx.allocator, .{
                .error_type = "type-mismatch",
                .message = msg,
                .source = ctx.current_source,
                .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
                .word_name = "native?",
            }) catch {};
            return error.TypeMismatch;
        },
    };

    const word_def = ctx.lookupWord(name) orelse {
        const msg = std.fmt.allocPrint(alloc, "word '{s}'", .{name}) catch "word '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "word-not-found",
            .message = msg,
            .source = ctx.current_source,
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "native?",
        }) catch {};
        return error.WordNotFound;
    };

    const is_native = switch (word_def.action) {
        .native => true,
        .compound => false,
    };
    try ctx.stack.push(.{ .boolean = is_native });
}
