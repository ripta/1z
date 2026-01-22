const Context = @import("../context.zig").Context;

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");

const popVector = helpers.popVector;

pub const primitives = [_]Primitive{
    .{ .name = "#push!", .stack_effect = "vec elem -- vec", .func = nativePushMut },
    .{ .name = "#pop!", .stack_effect = "vec -- elem", .func = nativePopMut },
};

/// #push! ( vec elem -- vec ) - Append element to vector, mutate in place
pub fn nativePushMut(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const vec = try popVector(ctx);

    vec.append(ctx.quotationAllocator(), elem) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .vector = vec });
}

/// #pop! ( vec -- elem ) - Remove and return last element from vector
pub fn nativePopMut(ctx: *Context) anyerror!void {
    const vec = try popVector(ctx);

    if (vec.items.len == 0) {
        return error.EmptySequence;
    }

    const elem = vec.pop().?; // Safe: we checked len > 0
    try ctx.stack.push(elem);
}
