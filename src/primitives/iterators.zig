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
const sequences = @import("sequences.zig");
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
    // The created iterator owns its backing, so releasing the popped source here cannot drop the
    // elements it walks.
    defer container_backing.releaseValue(raw_val);
    const iter = try sequences.seqToArrayIter(raw_val, ctx) orelse {
        helpers.setTypeMismatchError(ctx, "sequence", raw_val);
        return error.TypeMismatch;
    };
    try helpers.pushMovedIterator(ctx, iter);
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
    const coerced = (try sequences.coerceSequenceOperand(ctx, val, .iterator_only)) orelse {
        sequences.setSequenceOperandMismatch(ctx, val);
        return error.TypeMismatch;
    };
    defer container_backing.releaseValue(coerced);
    const iter = coerced.iterator;

    const alloc = ctx.allocator;
    var list = std.ArrayListUnmanaged(Value){};
    errdefer {
        container_backing.releaseValues(list.items);
        list.deinit(alloc);
    }
    while (try iter.next(ctx)) |elem| {
        list.append(alloc, elem) catch {
            container_backing.releaseValue(elem);
            return error.OutOfMemory;
        };
    }
    // The iterator's yields are owning references; the result array
    // adopts them wholesale.
    const items = list.toOwnedSlice(alloc) catch return error.OutOfMemory;
    try helpers.pushAdoptedArray(ctx, alloc, items);
}

/// #count ( iterator -- n )
pub fn nativeCount(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const coerced = (try sequences.coerceSequenceOperand(ctx, val, .iterator_only)) orelse {
        sequences.setSequenceOperandMismatch(ctx, val);
        return error.TypeMismatch;
    };
    defer container_backing.releaseValue(coerced);
    const iter = coerced.iterator;

    var count: i64 = 0;
    while (try iter.next(ctx)) |elem| {
        container_backing.releaseValue(elem);
        count += 1;
    }
    try ctx.stack.push(.{ .fixnum = count });
}

/// make-range-iter ( start end step infinite? -- iterator )
fn nativeMakeRangeIter(ctx: *Context) anyerror!void {
    const infinite_val = try ctx.stack.pop();
    defer container_backing.releaseValue(infinite_val);
    const step_val = try ctx.stack.pop();
    defer container_backing.releaseValue(step_val);
    const end_val = try ctx.stack.pop();
    defer container_backing.releaseValue(end_val);
    const start_val = try ctx.stack.pop();
    defer container_backing.releaseValue(start_val);

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

    const iter = try Iterator.create(ctx.allocator, .{ .range = .{
        .current = start,
        .end = end,
        .step = step,
        .infinite = infinite,
    } });
    try helpers.pushMovedIterator(ctx, iter);
}

/// make-callback-iter ( quot -- iterator )
fn nativeMakeCallbackIter(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const quotation = switch (val) {
        .quotation => |q| q,
        .closure => |c| c.asQuotation(),
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", val);
            container_backing.releaseValue(val);
            return error.TypeMismatch;
        },
    };
    // The popped reference transfers into the iterator kind, released at
    // destroy, so a closure body stays alive across the lazy drain.
    const iter = Iterator.create(ctx.allocator, .{ .callback = .{
        .quotation = quotation,
        .exhausted = false,
        .cleanup_quotation = null,
        .cleanup_ran = false,
        .quot_owner = val,
    } }) catch |err| {
        container_backing.releaseValue(val);
        return err;
    };
    try helpers.pushMovedIterator(ctx, iter);
}

/// make-callback-iter-with-cleanup ( step-quot cleanup-quot -- iterator )
fn nativeMakeCallbackIterWithCleanup(ctx: *Context) anyerror!void {
    const cleanup_val = try ctx.stack.pop();
    const step_val = try ctx.stack.pop();
    const cleanup_quotation = switch (cleanup_val) {
        .quotation => |q| q,
        .closure => |c| c.asQuotation(),
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", cleanup_val);
            container_backing.releaseValue(cleanup_val);
            container_backing.releaseValue(step_val);
            return error.TypeMismatch;
        },
    };
    const step_quotation = switch (step_val) {
        .quotation => |q| q,
        .closure => |c| c.asQuotation(),
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", step_val);
            container_backing.releaseValue(step_val);
            return error.TypeMismatch;
        },
    };
    // Both popped references transfer into the iterator kind, released at
    // destroy, so closure bodies stay alive across the lazy drain.
    const iter = Iterator.create(ctx.allocator, .{ .callback = .{
        .quotation = step_quotation,
        .exhausted = false,
        .cleanup_quotation = cleanup_quotation,
        .cleanup_ran = false,
        .quot_owner = step_val,
        .cleanup_owner = cleanup_val,
    } }) catch |err| {
        container_backing.releaseValue(step_val);
        container_backing.releaseValue(cleanup_val);
        return err;
    };
    try helpers.pushMovedIterator(ctx, iter);
}

/// close-iterator ( iterator -- )
pub fn nativeCloseIterator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    // The popped slot owned the iterator; release it even when the cleanup quotation throws.
    defer container_backing.releaseValue(val);
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

test ">iterator materialized backing retains elements until destroy" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const elem = try value_mod.Vector.create(std.testing.allocator);
    const src = try value_mod.Vector.create(std.testing.allocator);
    // The source's slot takes the element's creation reference.
    try src.list.append(src.header.allocator, .{ .vector = elem });

    try ctx.stack.pushMoved(.{ .vector = src });
    try nativeToIterator(&ctx);

    // The source was released inside >iterator and destroyed; only the iterator's materialized
    // backing keeps the element alive.
    const it_val = try ctx.stack.pop();
    try std.testing.expect(it_val == .iterator);
    try std.testing.expectEqual(@as(u32, 1), elem.header.refcountValue());

    // Destroying the iterator releases the element and frees the slice.
    container_backing.releaseValue(it_val);
}

test ">iterator over an array retains the source through its header" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const items = try std.testing.allocator.alloc(Value, 1);
    items[0] = .{ .fixnum = 3 };
    const arr = try value_mod.Array.fromOwnedSlice(std.testing.allocator, items);

    try ctx.stack.pushMoved(.{ .array = arr });
    try nativeToIterator(&ctx);

    const it_val = try ctx.stack.pop();
    try std.testing.expect(it_val == .iterator);
    try std.testing.expectEqual(@as(u32, 1), arr.header.refcountValue());
    container_backing.releaseValue(it_val);
}

test "close-iterator releases the popped iterator" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 0 });
    try ctx.stack.push(.{ .fixnum = 3 });
    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .boolean = false });
    try nativeMakeRangeIter(&ctx);
    try nativeCloseIterator(&ctx);

    // The leak detector confirms the iterator was destroyed.
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}

test "#collect drains and destroys a partially shared chain" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const elem = try value_mod.Vector.create(std.testing.allocator);
    const src = try value_mod.Vector.create(std.testing.allocator);
    try src.list.append(src.header.allocator, .{ .vector = elem });

    try ctx.stack.pushMoved(.{ .vector = src });
    try nativeToIterator(&ctx);
    try nativeCollect(&ctx);

    // The iterator was destroyed when #collect released its slot, so the collected array holds
    // the element's only reference.
    const result = try ctx.stack.pop();
    try std.testing.expectEqual(@as(u32, 1), elem.header.refcountValue());
    container_backing.releaseValue(result);
}
