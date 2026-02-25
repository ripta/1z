const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Marker = value_mod.Marker;

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
