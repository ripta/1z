const std = @import("std");
const Context = @import("../context.zig").Context;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const RegistryEntry = @import("types.zig").RegistryEntry;
const iter_mod = @import("../iterator.zig");
const Iterator = iter_mod.Iterator;
const CallbackIter = iter_mod.CallbackIter;
const RangeIter = iter_mod.RangeIter;
const sequence = @import("sequence.zig");
const unwrapBaseType = @import("../dispatch.zig").unwrapBaseType;
const container_backing = @import("../container_backing.zig");

pub const registry_entries = [_]RegistryEntry{
    .{ .name = ">iterator", .func = nativeToIterator, .stack_effect = "seq -- iterator" },
    .{ .name = "make-callback-iter", .func = nativeMakeCallbackIter, .stack_effect = "quot -- iterator" },
    .{ .name = "make-callback-iter-with-cleanup", .func = nativeMakeCallbackIterWithCleanup, .stack_effect = "step-quot cleanup-quot -- iterator" },
    .{ .name = "close-iterator", .func = nativeCloseIterator, .stack_effect = "iterator --" },
};

pub const primitives = [_]Primitive{
    .{ .name = "#next", .stack_effect = "iterator -- value", .doc = "Advance an iterator and return the next value. Throws if exhausted.", .func = nativeNext },
    .{ .name = "#collect", .stack_effect = "iterator -- array", .doc = "Materialize all iterator elements into an array.", .func = nativeCollect },
    .{
        .name = "#count",
        .stack_effect = "iterator -- n",
        .doc = "Count elements by consuming the iterator. Unlike #len, this exhausts the iterator; it cannot be used afterward.",
        .func = nativeCount,
    },
    .{
        .name = "make-range-iter",
        .stack_effect = "start end step infinite? -- iterator",
        .doc = "Create a lazy range iterator from start/end/step/infinite? components.",
        .func = nativeMakeRangeIter,
    },
};

/// >iterator ( seq -- iterator )
pub fn nativeToIterator(ctx: *Context) anyerror!void {
    const raw_val = try ctx.stack.pop();
    // Releasing the source pairs with the backing ownership the pushed
    // iterator value takes on via `retainIteratorBacking`. The materialized
    // backing borrows the source's element references; the push below retains
    // them before this release drops the source's own references.
    defer container_backing.releaseValue(raw_val);
    const alloc = ctx.quotationAllocator();
    const val = unwrapBaseType(raw_val);
    const items: []const Value = switch (val) {
        .array => |arr| arr,
        .string, .vector, .byte_array, .set => sequence.sequenceToValues(val, alloc) catch return error.OutOfMemory,
        else => {
            helpers.setTypeMismatchError(ctx, "sequence", raw_val);
            return error.TypeMismatch;
        },
    };
    const iter = try alloc.create(Iterator);
    iter.* = .{ .kind = .{ .array = .{ .items = items, .index = 0 } } };
    try ctx.stack.push(.{ .iterator = iter });
}

/// #next ( iterator -- value )
pub fn nativeNext(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    // The popped slot owned the iterator backing; release it on exit.
    defer container_backing.releaseValue(val);
    switch (val) {
        .iterator => |iter| {
            if (try iter.next(ctx)) |elem| {
                try ctx.stack.push(elem);
                // push retained the result; drop the yield's owning reference.
                container_backing.releaseValue(elem);
            } else {
                ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                    .error_type = "iterator-exhausted",
                    .message = "iterator has no more elements",
                });
                return error.UserThrown;
            }
        },
        else => {
            helpers.setTypeMismatchError(ctx, "iterator", val);
            return error.TypeMismatch;
        },
    }
}

/// #collect ( iterator -- array )
pub fn nativeCollect(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .iterator => |iter| {
            const alloc = ctx.quotationAllocator();
            var list = std.ArrayListUnmanaged(Value){};
            while (try iter.next(ctx)) |elem| {
                list.append(alloc, elem) catch return error.OutOfMemory;
            }
            const items = list.toOwnedSlice(alloc) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .array = items });
            // push retained the result array's elements; drop the owning
            // references the iterator yields handed us.
            container_backing.releaseValues(items);
        },
        else => {
            helpers.setTypeMismatchError(ctx, "iterator", val);
            return error.TypeMismatch;
        },
    }
}

/// #count ( iterator -- n )
pub fn nativeCount(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .iterator => |iter| {
            var count: i64 = 0;
            while (try iter.next(ctx)) |elem| {
                container_backing.releaseValue(elem);
                count += 1;
            }
            try ctx.stack.push(.{ .fixnum = count });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "iterator", val);
            return error.TypeMismatch;
        },
    }
}

/// make-range-iter ( start end step infinite? -- iterator )
fn nativeMakeRangeIter(ctx: *Context) anyerror!void {
    const infinite_val = try ctx.stack.pop();
    const step_val = try ctx.stack.pop();
    const end_val = try ctx.stack.pop();
    const start_val = try ctx.stack.pop();

    const start = switch (start_val) {
        .fixnum => |n| n,
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum", start_val);
            return error.TypeMismatch;
        },
    };
    const end = switch (end_val) {
        .fixnum => |n| n,
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum", end_val);
            return error.TypeMismatch;
        },
    };
    const step = switch (step_val) {
        .fixnum => |n| n,
        else => {
            helpers.setTypeMismatchError(ctx, "fixnum", step_val);
            return error.TypeMismatch;
        },
    };
    const infinite = infinite_val != .boolean or infinite_val.boolean;

    const alloc = ctx.quotationAllocator();
    const iter = try alloc.create(Iterator);
    iter.* = .{ .kind = .{ .range = .{
        .current = start,
        .end = end,
        .step = step,
        .infinite = infinite,
    } } };
    try ctx.stack.push(.{ .iterator = iter });
}

/// make-callback-iter ( quot -- iterator )
fn nativeMakeCallbackIter(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const quotation = switch (val) {
        .quotation => |q| q,
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", val);
            return error.TypeMismatch;
        },
    };
    const alloc = ctx.quotationAllocator();
    const iter = try alloc.create(Iterator);
    iter.* = .{ .kind = .{ .callback = .{
        .quotation = quotation,
        .exhausted = false,
        .cleanup_quotation = null,
        .cleanup_ran = false,
    } } };
    try ctx.stack.push(.{ .iterator = iter });
}

/// make-callback-iter-with-cleanup ( step-quot cleanup-quot -- iterator )
fn nativeMakeCallbackIterWithCleanup(ctx: *Context) anyerror!void {
    const cleanup_val = try ctx.stack.pop();
    const step_val = try ctx.stack.pop();
    const cleanup_quotation = switch (cleanup_val) {
        .quotation => |q| q,
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", cleanup_val);
            return error.TypeMismatch;
        },
    };
    const step_quotation = switch (step_val) {
        .quotation => |q| q,
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", step_val);
            return error.TypeMismatch;
        },
    };
    const alloc = ctx.quotationAllocator();
    const iter = try alloc.create(Iterator);
    iter.* = .{ .kind = .{ .callback = .{
        .quotation = step_quotation,
        .exhausted = false,
        .cleanup_quotation = cleanup_quotation,
        .cleanup_ran = false,
    } } };
    try ctx.stack.push(.{ .iterator = iter });
}

/// close-iterator ( iterator -- )
pub fn nativeCloseIterator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .iterator => |iter| {
            try iter.close(ctx);
        },
        else => {
            helpers.setTypeMismatchError(ctx, "iterator", val);
            return error.TypeMismatch;
        },
    }
}
