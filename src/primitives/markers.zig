const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Marker = value_mod.Marker;

const Primitive = @import("types.zig").Primitive;

/// Well-known marker for parse-time word definitions.
/// This is a compile-time constant with identity semantics.
pub const parse_time_marker: Marker = .{ .name = "parse-time" };

pub const primitives = [_]Primitive{
    .{ .name = "marker", .stack_effect = "-- marker", .func = nativeMarker },
    .{ .name = "parse-time", .stack_effect = "-- marker", .func = nativeParseTimeMarker, .parse_time = true },
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
