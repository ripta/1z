const Context = @import("../context.zig").Context;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Iterator = @import("../iterator.zig").Iterator;

pub const primitives = [_]Primitive{
    .{ .name = ">iterator", .stack_effect = "seq -- iterator", .doc = "Create an iterator over a sequence.", .func = nativeToIterator },
    .{ .name = "#next", .stack_effect = "iterator -- value", .doc = "Advance an iterator and return the next value. Throws if exhausted.", .func = nativeNext },
};

/// >iterator ( seq -- iterator )
fn nativeToIterator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .array => |items| {
            const alloc = ctx.quotationAllocator();
            const iter = try alloc.create(Iterator);
            iter.* = .{ .kind = .{ .array = .{ .items = items, .index = 0 } } };
            try ctx.stack.push(.{ .iterator = iter });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "array", val);
            return error.TypeMismatch;
        },
    }
}

/// #next ( iterator -- value )
fn nativeNext(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .iterator => |iter| {
            if (iter.next()) |elem| {
                try ctx.stack.push(elem);
            } else {
                ctx.thrown_error = .{
                    .error_type = "iterator-exhausted",
                    .message = "iterator has no more elements",
                };
                return error.UserThrown;
            }
        },
        else => {
            helpers.setTypeMismatchError(ctx, "iterator", val);
            return error.TypeMismatch;
        },
    }
}
