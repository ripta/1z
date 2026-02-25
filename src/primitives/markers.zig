const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Marker = value_mod.Marker;

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "marker", .stack_effect = "-- marker", .func = nativeMarker },
};

/// marker ( -- marker ) - Create an anonymous marker value
/// The marker gets its name when defined with ;
pub fn nativeMarker(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const marker = try alloc.create(Marker);
    marker.* = .{ .name = "" }; // Anonymous until defined
    try ctx.stack.push(.{ .marker = marker });
}
