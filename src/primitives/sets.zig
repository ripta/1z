const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Set = value_mod.Set;

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "@in?", .stack_effect = "set value -- ?", .func = nativeAtIn },
    .{ .name = "@adjoin", .stack_effect = "set value -- set'", .func = nativeAtAdjoin },
    .{ .name = "@remove", .stack_effect = "set value -- set'", .func = nativeAtRemove },
    .{ .name = "@union", .stack_effect = "set1 set2 -- set'", .func = nativeAtUnion },
    .{ .name = "@intersection", .stack_effect = "set1 set2 -- set'", .func = nativeAtIntersection },
    .{ .name = "@difference", .stack_effect = "set1 set2 -- set'", .func = nativeAtDifference },
};

/// @in? ( set value -- ? ) - Check if value is in the set
pub fn nativeAtIn(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const set_val = try ctx.stack.pop();

    const set = switch (set_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    try ctx.stack.push(.{ .boolean = set.contains(val) });
}

/// @adjoin ( set value -- set' ) - Add value to set, returning new set (immutable)
pub fn nativeAtAdjoin(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const set_val = try ctx.stack.pop();

    const old_set = switch (set_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    if (old_set.contains(val)) {
        // Value already in set, return same set
        try ctx.stack.push(.{ .set = old_set });
        return;
    }

    const alloc = ctx.quotationAllocator();

    // Create new set with the additional value
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = old_set.clone(alloc) catch return error.OutOfMemory;

    // Add new element
    new_set.put(alloc, val, {}) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .set = new_set });
}

/// @remove ( set value -- set' ) - Remove value from set, returning new set (immutable)
pub fn nativeAtRemove(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const set_val = try ctx.stack.pop();

    const old_set = switch (set_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    const alloc = ctx.quotationAllocator();

    // Create new set without the specified value
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = old_set.clone(alloc) catch return error.OutOfMemory;

    _ = new_set.swapRemove(val);
    try ctx.stack.push(.{ .set = new_set });
}

/// @union ( set1 set2 -- set' ) - Return union of two sets
pub fn nativeAtUnion(ctx: *Context) anyerror!void {
    const set2_val = try ctx.stack.pop();
    const set1_val = try ctx.stack.pop();

    const set1 = switch (set1_val) {
        .set => |s| s,
        else => return error.TypeError,
    };
    const set2 = switch (set2_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    const alloc = ctx.quotationAllocator();

    // Create new set with all elements from both sets
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = set1.clone(alloc) catch return error.OutOfMemory;

    // Add all elements from set2 (duplicates handled automatically)
    for (set2.keys()) |key| {
        new_set.put(alloc, key, {}) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .set = new_set });
}

/// @intersection ( set1 set2 -- set' ) - Return intersection of two sets
pub fn nativeAtIntersection(ctx: *Context) anyerror!void {
    const set2_val = try ctx.stack.pop();
    const set1_val = try ctx.stack.pop();

    const set1 = switch (set1_val) {
        .set => |s| s,
        else => return error.TypeError,
    };
    const set2 = switch (set2_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    const alloc = ctx.quotationAllocator();

    // Create new set with elements that are in both sets
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = Set{};

    for (set1.keys()) |key| {
        if (set2.contains(key)) {
            new_set.put(alloc, key, {}) catch return error.OutOfMemory;
        }
    }

    try ctx.stack.push(.{ .set = new_set });
}

/// @difference ( set1 set2 -- set' ) - Return elements in set1 but not in set2
pub fn nativeAtDifference(ctx: *Context) anyerror!void {
    const set2_val = try ctx.stack.pop();
    const set1_val = try ctx.stack.pop();

    const set1 = switch (set1_val) {
        .set => |s| s,
        else => return error.TypeError,
    };
    const set2 = switch (set2_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    const alloc = ctx.quotationAllocator();

    // Create new set with elements from set1 that aren't in set2
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = Set{};

    for (set1.keys()) |key| {
        if (!set2.contains(key)) {
            new_set.put(alloc, key, {}) catch return error.OutOfMemory;
        }
    }

    try ctx.stack.push(.{ .set = new_set });
}
