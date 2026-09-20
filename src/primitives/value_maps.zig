const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const ValueEntries = value_mod.ValueEntries;
const ValueMap = value_mod.ValueMap;
const MutableValueMap = value_mod.MutableValueMap;

const container_backing = @import("../container_backing.zig");
const freeze = @import("freeze.zig");
const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "<value-map>", .stack_effect = " -- value-map", .doc = "Create an empty immutable value-keyed map.\n\nExample: <value-map> value-map? => t", .func = nativeMakeValueMap },
    .{ .name = "<mutable-value-map>", .stack_effect = " -- mutable-value-map", .doc = "Create an empty mutable value-keyed map.\n\nExample: <mutable-value-map> freeze type-of => value-map", .func = nativeMakeMutableValueMap },
};

/// <value-map> ( -- value-map )
fn nativeMakeValueMap(ctx: *Context) anyerror!void {
    const map = ValueMap.create(ctx.allocator) catch return error.OutOfMemory;
    ctx.stack.pushMoved(.{ .value_map = map }) catch |err| {
        container_backing.releaseValue(.{ .value_map = map });
        return err;
    };
}

/// <mutable-value-map> ( -- mutable-value-map )
fn nativeMakeMutableValueMap(ctx: *Context) anyerror!void {
    const map = MutableValueMap.create(ctx.allocator) catch return error.OutOfMemory;
    ctx.stack.pushMoved(.{ .mutable_value_map = map }) catch |err| {
        container_backing.releaseValue(.{ .mutable_value_map = map });
        return err;
    };
}

/// Store `value` under `key`, keyed by the key's frozen form.
///
/// Consumes both halves. An existing entry keeps the key it was stored under and releases the
/// value it held, so the stored key stays the one whose hash the table was built around.
///
/// Both halves write through here, so a key in storage is in frozen form whichever half holds it.
pub fn putEntry(ctx: *Context, map: *ValueEntries, alloc: Allocator, key: Value, value: Value) anyerror!void {
    const stored_key = freeze.frozenKeyConsume(ctx, key) catch |e| {
        container_backing.releaseValue(key);
        container_backing.releaseValue(value);
        return e;
    };

    const gop = map.getOrPut(alloc, stored_key) catch {
        container_backing.releaseValue(stored_key);
        container_backing.releaseValue(value);
        return error.OutOfMemory;
    };

    if (gop.found_existing) {
        container_backing.releaseValue(stored_key);
        container_backing.releaseValue(gop.value_ptr.*);
    }
    gop.value_ptr.* = value;
}

/// The value stored under `key`, or null. Borrows `key`, and the result is borrowed from the map.
pub fn getEntry(ctx: *Context, map: *const ValueEntries, key: Value) anyerror!?Value {
    const probe = try freeze.frozenKey(ctx, key);
    defer probe.release();

    return map.get(probe.value);
}

const testing = std.testing;

/// A one-element array, which is the frozen form of a one-element vector holding the same thing.
fn testArrayOf(ctx: *Context, elem: Value) !Value {
    const items = try ctx.allocator.alloc(Value, 1);
    items[0] = elem;
    return .{ .array = try value_mod.Array.fromOwnedSlice(ctx.allocator, items) };
}

test "a value-map entry stays reachable after the caller mutates its key handle" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const m = try ValueMap.create(ctx.allocator);
    defer container_backing.releaseValue(.{ .value_map = m });

    const key = try value_mod.Vector.create(ctx.allocator);
    try key.list.append(ctx.allocator, .{ .fixnum = 1 });
    // A second reference stands in for the caller's own handle, which outlives the insert.
    key.header.retain();
    defer key.header.release();

    try putEntry(&ctx, &m.map, m.header.allocator, .{ .vector = key }, .{ .fixnum = 9 });

    // The stored key is an independent frozen copy, so moving the handle's hash leaves the entry
    // where the insert put it.
    try key.list.append(ctx.allocator, .{ .fixnum = 2 });

    const probe = try testArrayOf(&ctx, .{ .fixnum = 1 });
    defer container_backing.releaseValue(probe);

    const got = try getEntry(&ctx, &m.map, probe);
    try testing.expectEqual(@as(i64, 9), got.?.fixnum);
}

test "the mutable half stores a key by its frozen form too" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const m = try MutableValueMap.create(ctx.allocator);
    defer container_backing.releaseValue(.{ .mutable_value_map = m });

    const key = try value_mod.Vector.create(ctx.allocator);
    try key.list.append(ctx.allocator, .{ .fixnum = 4 });
    key.header.retain();
    defer key.header.release();

    try putEntry(&ctx, &m.map, m.header.allocator, .{ .vector = key }, .{ .fixnum = 8 });
    try key.list.append(ctx.allocator, .{ .fixnum = 5 });

    const probe = try testArrayOf(&ctx, .{ .fixnum = 4 });
    defer container_backing.releaseValue(probe);

    const got = try getEntry(&ctx, &m.map, probe);
    try testing.expectEqual(@as(i64, 8), got.?.fixnum);
    try testing.expectEqual(@as(usize, 1), m.map.count());
}

test "a vector key and an array key of the same contents write to one entry" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const m = try MutableValueMap.create(ctx.allocator);
    defer container_backing.releaseValue(.{ .mutable_value_map = m });
    const alloc = m.header.allocator;

    const vec = try value_mod.Vector.create(ctx.allocator);
    try vec.list.append(ctx.allocator, .{ .fixnum = 7 });
    try putEntry(&ctx, &m.map, alloc, .{ .vector = vec }, .{ .fixnum = 1 });

    try putEntry(&ctx, &m.map, alloc, try testArrayOf(&ctx, .{ .fixnum = 7 }), .{ .fixnum = 2 });

    // A write is last-one-wins on the value, and the entry keeps the key it was built around.
    try testing.expectEqual(@as(usize, 1), m.map.count());
    try testing.expectEqual(@as(i64, 2), m.map.values()[0].fixnum);
    try testing.expect(m.map.keys()[0] == .array);
}
