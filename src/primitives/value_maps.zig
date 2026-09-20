const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const ValueEntries = value_mod.ValueEntries;
const ValueMap = value_mod.ValueMap;
const MutableValueMap = value_mod.MutableValueMap;

const container_backing = @import("../container_backing.zig");
const ContainerHeader = container_backing.ContainerHeader;
const freeze = @import("freeze.zig");
const helpers = @import("helpers.zig");
const sequences = @import("sequences.zig");
const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "<value-map>", .stack_effect = " -- value-map", .doc = "Create an empty immutable value-keyed map.\n\nExample: <value-map> value-map? => t", .func = nativeMakeValueMap },
    .{ .name = "<mutable-value-map>", .stack_effect = " -- mutable-value-map", .doc = "Create an empty mutable value-keyed map.\n\nExample: <mutable-value-map> freeze type-of => value-map", .func = nativeMakeMutableValueMap },
    .{ .name = ">value-map", .stack_effect = "seq -- value-map", .doc = "Build an immutable value-keyed map from a sequence of two-element entries. A repeated key keeps the last value. Inverse of >array on a value-map.\n\nExample: { { 1 \"a\" } { 2 \"b\" } } >value-map #len => 2", .func = nativeToValueMap },
    .{ .name = ">mutable-value-map", .stack_effect = "seq -- mutable-value-map", .doc = "Build a mutable value-keyed map from a sequence of two-element entries. A repeated key keeps the last value. A value-map is itself such a sequence, so this is the way back from the immutable half, as freeze is the way to it.\n\nExample: { { 1 \"a\" } } >mutable-value-map 1 vmap-get => \"a\"", .func = nativeToMutableValueMap },
    .{ .name = "vmap-get", .stack_effect = "vmap key -- value", .doc = "Value stored under key, in either half. Throws key-not-found when the key is absent. A key is matched by its frozen form, so V{ 1 2 } and { 1 2 } find the same entry.\n\nExample: { { 1 \"a\" } } >value-map 1 vmap-get => \"a\"", .func = nativeVmapGet },
    .{ .name = "vmap-has?", .stack_effect = "vmap key -- ?", .doc = "Whether either half holds an entry under key. The key is matched by its frozen form, as in vmap-get.\n\nExample: { { 1 \"a\" } } >value-map 2 vmap-has? => f", .func = nativeVmapHas },
    .{ .name = "vmap-set", .stack_effect = "value-map key value -- value-map'", .doc = "Store value under key in the immutable half, returning a new map. O(n): the whole table is copied. A key holding a mutable container is stored frozen, so a later mutation through the caller's handle does not reach it. Use vmap-set! on the mutable half.\n\nExample: <value-map> 1 \"a\" vmap-set 1 vmap-get => \"a\"", .func = nativeVmapSet },
    .{ .name = "vmap-set!", .stack_effect = "mutable-value-map key value -- mutable-value-map", .doc = "Store value under key in the mutable half, mutating in place and returning the same map. Keys follow the frozen-form rule of vmap-set. Use vmap-set on the immutable half.\n\nExample: <mutable-value-map> 1 \"a\" vmap-set! 1 vmap-get => \"a\"", .func = nativeVmapSetMut },
    .{ .name = "vmap-delete", .stack_effect = "value-map key -- value-map'", .doc = "Remove key from the immutable half, returning a new map. A key that is not present yields an equal map rather than throwing. The remaining entries keep their order. Use vmap-delete! on the mutable half.\n\nExample: { { 1 \"a\" } } >value-map 1 vmap-delete #len => 0", .func = nativeVmapDelete },
    .{ .name = "vmap-delete!", .stack_effect = "mutable-value-map key -- mutable-value-map", .doc = "Remove key from the mutable half in place, returning the same map. A key that is not present is a no-op. The last entry moves into the hole, so iteration order changes; vmap-delete on the immutable half is the order-preserving one.\n\nExample: { { 1 \"a\" } } >mutable-value-map 1 vmap-delete! #len => 0", .func = nativeVmapDeleteMut },
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
///
/// `header` guards a map another thread can already reach, and is null for one still under
/// construction.
///
/// The freeze runs ahead of that lock deliberately. A tagged container is normalized through its
/// generated wrap word, so freezing a key can re-enter the interpreter, and the container mutex is
/// not reentrant.
pub fn putEntry(ctx: *Context, map: *ValueEntries, alloc: Allocator, header: ?*ContainerHeader, key: Value, value: Value) anyerror!void {
    const stored_key = freeze.frozenKeyConsume(ctx, key) catch |e| {
        container_backing.releaseValue(key);
        container_backing.releaseValue(value);
        return e;
    };

    if (header) |h| h.lock();

    const gop = map.getOrPut(alloc, stored_key) catch {
        if (header) |h| h.unlock();
        container_backing.releaseValue(stored_key);
        container_backing.releaseValue(value);
        return error.OutOfMemory;
    };

    const displaced: ?Value = if (gop.found_existing) gop.value_ptr.* else null;
    gop.value_ptr.* = value;

    if (header) |h| h.unlock();

    if (displaced) |old| {
        container_backing.releaseValue(stored_key);
        container_backing.releaseValue(old);
    }
}

/// The value stored under `key`, or null. Borrows `key`, and the result is borrowed from the map.
pub fn getEntry(ctx: *Context, map: *const ValueEntries, key: Value) anyerror!?Value {
    const probe = try freeze.frozenKey(ctx, key);
    defer probe.release();

    return map.get(probe.value);
}

/// The entry storage behind either half, or null when `val` is neither.
///
/// This is the one tag switch the shared reads run on, and it is what lets `vmap-get` and
/// `vmap-has?` serve the immutable and the mutable map from a single native.
fn entriesOf(val: Value) ?*ValueEntries {
    return switch (val) {
        .value_map => |m| &m.map,
        .mutable_value_map => |m| &m.map,
        else => null,
    };
}

/// Copy every entry of `source` into `dest`, retaining both halves: a slot is an owning reference
/// balanced by the release in destroy.
///
/// A source key is already in frozen form, so retaining carries it forward without a second freeze.
fn copyRetainedEntries(dest: *ValueEntries, alloc: Allocator, source: *const ValueEntries) error{OutOfMemory}!void {
    try dest.ensureTotalCapacity(alloc, source.count());
    for (source.keys(), source.values()) |key, val| {
        container_backing.retainValue(key);
        container_backing.retainValue(val);
        dest.putAssumeCapacity(key, val);
    }
}

/// The key and value of a two-element entry, or null when `entry` is not one.
fn entryPair(entry: Value) ?[2]Value {
    const items = switch (entry) {
        .array => |a| a.items,
        .vector => |v| v.list.items,
        else => return null,
    };
    if (items.len != 2) return null;
    return .{ items[0], items[1] };
}

/// Pop a sequence of two-element entries and write each one into `map`.
///
/// The operand is routed the way `#collect` routes its own, so an array, a vector, a set, or an
/// iterator all arrive as one iterator whose yields are owning references.
fn fillFromEntrySequence(ctx: *Context, map: *ValueEntries, alloc: Allocator) anyerror!void {
    const raw = try ctx.stack.pop();
    defer container_backing.releaseValue(raw);

    const coerced = (try sequences.coerceSequenceOperand(ctx, raw, .iterator_only)) orelse {
        sequences.setSequenceOperandMismatch(ctx, raw);
        return error.TypeMismatch;
    };
    defer container_backing.releaseValue(coerced);
    const iter = coerced.iterator;

    while (try iter.next(ctx)) |entry| {
        defer container_backing.releaseValue(entry);

        const pair = entryPair(entry) orelse {
            helpers.setTypeMismatchError(ctx, "a two-element entry", entry);
            helpers.setErrorHint(ctx, "a value-map is built from entries, each one { key value }");
            return error.TypeMismatch;
        };

        container_backing.retainValue(pair[0]);
        container_backing.retainValue(pair[1]);
        // Nothing else can reach a map still being built, so the insert needs no lock.
        try putEntry(ctx, map, alloc, null, pair[0], pair[1]);
    }
}

/// >value-map ( seq -- value-map )
fn nativeToValueMap(ctx: *Context) anyerror!void {
    const map = ValueMap.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .value_map = map });

    try fillFromEntrySequence(ctx, &map.map, map.header.allocator);
    try ctx.stack.pushMoved(.{ .value_map = map });
}

/// >mutable-value-map ( seq -- mutable-value-map )
fn nativeToMutableValueMap(ctx: *Context) anyerror!void {
    const map = MutableValueMap.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .mutable_value_map = map });

    try fillFromEntrySequence(ctx, &map.map, map.header.allocator);
    try ctx.stack.pushMoved(.{ .mutable_value_map = map });
}

/// vmap-get ( vmap key -- value )
fn nativeVmapGet(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const map_val = try ctx.stack.pop();
    defer container_backing.releaseValue(map_val);

    const entries = entriesOf(map_val) orelse {
        helpers.setTypeMismatchError(ctx, "value-map or mutable-value-map", map_val);
        return error.TypeMismatch;
    };

    if (try getEntry(ctx, entries, key)) |val| {
        try ctx.stack.push(val);
        return;
    }

    const arena = ctx.arena.allocator();
    const brief = helpers.formatValueBrief(arena, key, 20) catch helpers.valueTypeName(key);
    helpers.setErrorContext(ctx, "key {s} not found in {s}", .{ brief, helpers.valueTypeName(map_val) });
    return error.KeyNotFound;
}

/// vmap-has? ( vmap key -- ? )
fn nativeVmapHas(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const map_val = try ctx.stack.pop();
    defer container_backing.releaseValue(map_val);

    const entries = entriesOf(map_val) orelse {
        helpers.setTypeMismatchError(ctx, "value-map or mutable-value-map", map_val);
        return error.TypeMismatch;
    };

    const probe = try freeze.frozenKey(ctx, key);
    defer probe.release();

    try ctx.stack.push(.{ .boolean = entries.contains(probe.value) });
}

/// vmap-set ( value-map key value -- value-map' )
fn nativeVmapSet(ctx: *Context) anyerror!void {
    // `new_value` and `key` flow into the new map's slots through `putEntry`, which consumes both
    // on every path, so neither carries a defer release.
    const new_value = try ctx.stack.pop();
    const key = ctx.stack.pop() catch |e| {
        container_backing.releaseValue(new_value);
        return e;
    };
    const map_val = ctx.stack.pop() catch |e| {
        container_backing.releaseValue(new_value);
        container_backing.releaseValue(key);
        return e;
    };
    defer container_backing.releaseValue(map_val);

    const old = switch (map_val) {
        .value_map => |m| m,
        else => {
            container_backing.releaseValue(new_value);
            container_backing.releaseValue(key);
            helpers.setTypeMismatchError(ctx, "value-map", map_val);
            helpers.setErrorHint(ctx, "the mutable half is written with vmap-set!");
            return error.TypeMismatch;
        },
    };

    const new_map = ValueMap.create(ctx.allocator) catch {
        container_backing.releaseValue(new_value);
        container_backing.releaseValue(key);
        return error.OutOfMemory;
    };
    errdefer container_backing.releaseValue(.{ .value_map = new_map });
    const alloc = new_map.header.allocator;

    copyRetainedEntries(&new_map.map, alloc, &old.map) catch {
        container_backing.releaseValue(new_value);
        container_backing.releaseValue(key);
        return error.OutOfMemory;
    };

    try putEntry(ctx, &new_map.map, alloc, null, key, new_value);
    try ctx.stack.pushMoved(.{ .value_map = new_map });
}

/// vmap-set! ( mutable-value-map key value -- mutable-value-map )
fn nativeVmapSetMut(ctx: *Context) anyerror!void {
    const new_value = try ctx.stack.pop();
    const key = ctx.stack.pop() catch |e| {
        container_backing.releaseValue(new_value);
        return e;
    };
    // `map_val` flows into the result slot via `pushMoved`, so it has no defer release either.
    const map_val = ctx.stack.pop() catch |e| {
        container_backing.releaseValue(new_value);
        container_backing.releaseValue(key);
        return e;
    };

    const m = switch (map_val) {
        .mutable_value_map => |m| m,
        else => {
            // The message renders the operand's contents, so it has to be built while the popped
            // reference is still the map's last one.
            helpers.setTypeMismatchError(ctx, "mutable-value-map", map_val);
            helpers.setErrorHint(ctx, "the immutable half is written with vmap-set");
            container_backing.releaseValue(new_value);
            container_backing.releaseValue(key);
            container_backing.releaseValue(map_val);
            return error.TypeMismatch;
        },
    };

    putEntry(ctx, &m.map, m.header.allocator, &m.header, key, new_value) catch |e| {
        container_backing.releaseValue(map_val);
        return e;
    };

    ctx.stack.pushMoved(map_val) catch |e| {
        container_backing.releaseValue(map_val);
        return e;
    };
}

/// vmap-delete ( value-map key -- value-map' )
fn nativeVmapDelete(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const map_val = try ctx.stack.pop();
    defer container_backing.releaseValue(map_val);

    const old = switch (map_val) {
        .value_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "value-map", map_val);
            helpers.setErrorHint(ctx, "the mutable half is deleted from with vmap-delete!");
            return error.TypeMismatch;
        },
    };

    const probe = try freeze.frozenKey(ctx, key);
    defer probe.release();

    const new_map = ValueMap.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .value_map = new_map });
    const alloc = new_map.header.allocator;

    // Rebuilding in source order is what keeps the surviving entries where they were.
    for (old.map.keys(), old.map.values()) |k, v| {
        if (k.eql(probe.value)) continue;
        container_backing.retainValue(k);
        container_backing.retainValue(v);
        new_map.map.put(alloc, k, v) catch {
            container_backing.releaseValue(k);
            container_backing.releaseValue(v);
            return error.OutOfMemory;
        };
    }

    try ctx.stack.pushMoved(.{ .value_map = new_map });
}

/// vmap-delete! ( mutable-value-map key -- mutable-value-map )
fn nativeVmapDeleteMut(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const map_val = try ctx.stack.pop();

    const m = switch (map_val) {
        .mutable_value_map => |m| m,
        else => {
            // Message first, for the reason vmap-set! gives.
            helpers.setTypeMismatchError(ctx, "mutable-value-map", map_val);
            helpers.setErrorHint(ctx, "the immutable half is deleted from with vmap-delete");
            container_backing.releaseValue(map_val);
            return error.TypeMismatch;
        },
    };

    const probe = freeze.frozenKey(ctx, key) catch |e| {
        container_backing.releaseValue(map_val);
        return e;
    };
    defer probe.release();

    m.header.lock();
    const removed = m.map.fetchSwapRemove(probe.value);
    m.header.unlock();

    if (removed) |kv| {
        container_backing.releaseValue(kv.key);
        container_backing.releaseValue(kv.value);
    }

    ctx.stack.pushMoved(map_val) catch |e| {
        container_backing.releaseValue(map_val);
        return e;
    };
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

    try putEntry(&ctx, &m.map, m.header.allocator, null, .{ .vector = key }, .{ .fixnum = 9 });

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

    try putEntry(&ctx, &m.map, m.header.allocator, &m.header, .{ .vector = key }, .{ .fixnum = 8 });
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
    try putEntry(&ctx, &m.map, alloc, &m.header, .{ .vector = vec }, .{ .fixnum = 1 });

    try putEntry(&ctx, &m.map, alloc, &m.header, try testArrayOf(&ctx, .{ .fixnum = 7 }), .{ .fixnum = 2 });

    // A write is last-one-wins on the value, and the entry keeps the key it was built around.
    try testing.expectEqual(@as(usize, 1), m.map.count());
    try testing.expectEqual(@as(i64, 2), m.map.values()[0].fixnum);
    try testing.expect(m.map.keys()[0] == .array);
}

test "a write to the wrong half reports the map it refused" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Each writer's stack slot holds the map's last reference, so the refusal destroys it. The
    // message renders the operand's entry count, which would come off freed memory if the release
    // ran first.
    const target = try ValueMap.create(ctx.allocator);
    try putEntry(&ctx, &target.map, target.header.allocator, null, .{ .fixnum = 1 }, .{ .fixnum = 2 });
    try putEntry(&ctx, &target.map, target.header.allocator, null, .{ .fixnum = 3 }, .{ .fixnum = 4 });

    try ctx.stack.pushMoved(.{ .value_map = target });
    try ctx.stack.push(.{ .fixnum = 9 });
    try ctx.stack.push(.{ .fixnum = 9 });
    try testing.expectError(error.TypeMismatch, nativeVmapSetMut(&ctx));
    try testing.expect(std.mem.indexOf(u8, ctx.pending_error_message.?, "value-map[2]") != null);

    const doomed = try ValueMap.create(ctx.allocator);
    try putEntry(&ctx, &doomed.map, doomed.header.allocator, null, .{ .fixnum = 5 }, .{ .fixnum = 6 });

    try ctx.stack.pushMoved(.{ .value_map = doomed });
    try ctx.stack.push(.{ .fixnum = 9 });
    try testing.expectError(error.TypeMismatch, nativeVmapDeleteMut(&ctx));
    try testing.expect(std.mem.indexOf(u8, ctx.pending_error_message.?, "value-map[1]") != null);
}

test "a copied entry survives the map it was copied from" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const source = try ValueMap.create(ctx.allocator);
    const key = try testArrayOf(&ctx, .{ .fixnum = 1 });
    try putEntry(&ctx, &source.map, source.header.allocator, null, key, .{ .fixnum = 2 });

    const copy = try ValueMap.create(ctx.allocator);
    defer container_backing.releaseValue(.{ .value_map = copy });
    try copyRetainedEntries(&copy.map, copy.header.allocator, &source.map);

    // The source held the only other reference to the key backing, so a missing retain in the copy
    // would leave the surviving entry pointing at freed storage.
    container_backing.releaseValue(.{ .value_map = source });

    try testing.expectEqual(@as(usize, 1), copy.map.count());
    try testing.expectEqual(@as(i64, 1), copy.map.keys()[0].array.items[0].fixnum);
    try testing.expectEqual(@as(i64, 2), copy.map.values()[0].fixnum);
}
