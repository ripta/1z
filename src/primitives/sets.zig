const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Set = value_mod.Set;

const container_backing = @import("../container_backing.zig");
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");

pub const primitives = [_]Primitive{
    .{ .name = "@in?", .stack_effect = "set value -- ?", .doc = "Check if value is in the set.", .func = nativeAtIn },
    .{ .name = "@adjoin", .stack_effect = "set value -- set'", .doc = "Add value to set, returning new set.", .func = nativeAtAdjoin },
    .{ .name = "@remove", .stack_effect = "set value -- set'", .doc = "Remove value from set, returning new set.", .func = nativeAtRemove },
    .{ .name = "@union", .stack_effect = "set1 set2 -- set'", .doc = "Return union of two sets.", .func = nativeAtUnion },
    .{ .name = "@intersection", .stack_effect = "set1 set2 -- set'", .doc = "Return intersection of two sets.", .func = nativeAtIntersection },
    .{ .name = "@difference", .stack_effect = "set1 set2 -- set'", .doc = "Return elements in set1 but not in set2.", .func = nativeAtDifference },
};

/// @in? ( set value -- ? ) - Check if value is in the set
pub fn nativeAtIn(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const set_val = try ctx.stack.pop();
    defer container_backing.releaseValue(set_val);

    const set = switch (set_val) {
        .set => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "set", set_val);
            return error.TypeMismatch;
        },
    };

    try ctx.stack.push(.{ .boolean = set.map.contains(val) });
}

/// Copy every member of `source` into `dest`, retaining each copied value:
/// a set slot is an owning reference, balanced by the release in destroy.
fn copyRetainedMembers(dest: *Set, source: *const Set) error{OutOfMemory}!void {
    const alloc = dest.header.allocator;
    try dest.map.ensureTotalCapacity(alloc, source.map.count());
    for (source.map.keys()) |key| {
        container_backing.retainValue(key);
        dest.map.putAssumeCapacity(key, {});
    }
}

/// @adjoin ( set value -- set' ) - Add value to set, returning new set (immutable)
pub fn nativeAtAdjoin(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const set_val = try ctx.stack.pop();
    defer container_backing.releaseValue(set_val);

    const old_set = switch (set_val) {
        .set => |s| s,
        else => {
            container_backing.releaseValue(val);
            helpers.setTypeMismatchError(ctx, "set", set_val);
            return error.TypeMismatch;
        },
    };

    if (old_set.map.contains(val)) {
        // Value already in set; the result is the same set. `push` retains
        // the header for the result slot and the defer balances the popped
        // input, so the net effect is a plain transfer.
        container_backing.releaseValue(val);
        try ctx.stack.push(.{ .set = old_set });
        return;
    }

    const new_set = Set.create(ctx.allocator) catch {
        container_backing.releaseValue(val);
        return error.OutOfMemory;
    };
    errdefer container_backing.releaseValue(.{ .set = new_set });

    copyRetainedMembers(new_set, old_set) catch {
        container_backing.releaseValue(val);
        return error.OutOfMemory;
    };

    // The popped value's reference flows into its slot; membership was
    // ruled out above, so this insert cannot displace an existing member.
    new_set.map.put(new_set.header.allocator, val, {}) catch {
        container_backing.releaseValue(val);
        return error.OutOfMemory;
    };

    try ctx.stack.pushMoved(.{ .set = new_set });
}

/// @remove ( set value -- set' ) - Remove value from set, returning new set (immutable)
pub fn nativeAtRemove(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const set_val = try ctx.stack.pop();
    defer container_backing.releaseValue(set_val);

    const old_set = switch (set_val) {
        .set => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "set", set_val);
            return error.TypeMismatch;
        },
    };

    const new_set = Set.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .set = new_set });
    const alloc = new_set.header.allocator;

    for (old_set.map.keys()) |key| {
        if (key.eql(val)) continue;
        container_backing.retainValue(key);
        new_set.map.put(alloc, key, {}) catch {
            container_backing.releaseValue(key);
            return error.OutOfMemory;
        };
    }

    try ctx.stack.pushMoved(.{ .set = new_set });
}

/// @union ( set1 set2 -- set' ) - Return union of two sets
pub fn nativeAtUnion(ctx: *Context) anyerror!void {
    const set2_val = try ctx.stack.pop();
    defer container_backing.releaseValue(set2_val);
    const set1_val = try ctx.stack.pop();
    defer container_backing.releaseValue(set1_val);

    const set1 = switch (set1_val) {
        .set => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "set", set1_val);
            return error.TypeMismatch;
        },
    };
    const set2 = switch (set2_val) {
        .set => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "set", set2_val);
            return error.TypeMismatch;
        },
    };

    const new_set = Set.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .set = new_set });
    const alloc = new_set.header.allocator;

    try copyRetainedMembers(new_set, set1);

    for (set2.map.keys()) |key| {
        const gop = new_set.map.getOrPut(alloc, key) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            container_backing.retainValue(key);
        }
    }

    try ctx.stack.pushMoved(.{ .set = new_set });
}

/// @intersection ( set1 set2 -- set' ) - Return intersection of two sets
pub fn nativeAtIntersection(ctx: *Context) anyerror!void {
    const set2_val = try ctx.stack.pop();
    defer container_backing.releaseValue(set2_val);
    const set1_val = try ctx.stack.pop();
    defer container_backing.releaseValue(set1_val);

    const set1 = switch (set1_val) {
        .set => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "set", set1_val);
            return error.TypeMismatch;
        },
    };
    const set2 = switch (set2_val) {
        .set => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "set", set2_val);
            return error.TypeMismatch;
        },
    };

    const new_set = Set.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .set = new_set });
    const alloc = new_set.header.allocator;

    for (set1.map.keys()) |key| {
        if (set2.map.contains(key)) {
            container_backing.retainValue(key);
            new_set.map.put(alloc, key, {}) catch {
                container_backing.releaseValue(key);
                return error.OutOfMemory;
            };
        }
    }

    try ctx.stack.pushMoved(.{ .set = new_set });
}

/// @difference ( set1 set2 -- set' ) - Return elements in set1 but not in set2
pub fn nativeAtDifference(ctx: *Context) anyerror!void {
    const set2_val = try ctx.stack.pop();
    defer container_backing.releaseValue(set2_val);
    const set1_val = try ctx.stack.pop();
    defer container_backing.releaseValue(set1_val);

    const set1 = switch (set1_val) {
        .set => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "set", set1_val);
            return error.TypeMismatch;
        },
    };
    const set2 = switch (set2_val) {
        .set => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "set", set2_val);
            return error.TypeMismatch;
        },
    };

    const new_set = Set.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .set = new_set });
    const alloc = new_set.header.allocator;

    for (set1.map.keys()) |key| {
        if (!set2.map.contains(key)) {
            container_backing.retainValue(key);
            new_set.map.put(alloc, key, {}) catch {
                container_backing.releaseValue(key);
                return error.OutOfMemory;
            };
        }
    }

    try ctx.stack.pushMoved(.{ .set = new_set });
}
