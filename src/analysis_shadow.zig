const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const container_backing = @import("container_backing.zig");
const ContainerHeader = container_backing.ContainerHeader;
const LockOrderTracker = @import("lock_order.zig").LockOrderTracker;
const once_cell_mod = @import("once_cell.zig");
const OnceCell = once_cell_mod.OnceCell;
const value_mod = @import("value.zig");
const Value = value_mod.Value;

/// The header of a container kind a write can mutate in place, or null for every other value.
///
/// A struct instance without a header is the legacy form that is never field-mutated, so it has
/// nothing to shadow.
pub fn mutableHeader(v: Value) ?*ContainerHeader {
    return switch (v) {
        .vector => |vec| &vec.header,
        .mutable_map => |map| &map.header,
        .byte_array => |ba| &ba.header,
        .mutable_value_map => |map| &map.header,
        .struct_instance => |inst| inst.header,
        else => null,
    };
}

/// The copies an analysis load owner keeps of state its ancestors own.
///
/// A write from analysis into a container or once cell that an ancestor made lands in a shallow copy
/// owned by the load owner. A read from analysis swaps the original for its copy at the stack pop and
/// peek, so analysis sees its own writes and nothing it writes reaches the ancestor. The table lives
/// with the load owner, and every task under that owner shares it.
///
/// A copy is shallow. A nested container is copied on its own first write, and the outer copy keeps
/// pointing at the nested original until a read swaps it.
///
/// The table holds a reference to each original container, so an original's address cannot be reused
/// while its entry exists. The key of an entry is therefore never a stale address.
///
/// A once cell is keyed with no hold. An ancestor's cell sits on the ancestor's arena, which lives as
/// long as the ancestor, and an ancestor outlives every analysis child under it. The cell's address is
/// therefore never reused while the table lives.
///
/// The table lock is a leaf. It is held only around a map probe or insert, never while a container
/// lock is held and never while a copy is made. Reads share it, so tasks that pop ancestor containers
/// do not serialize.
///
/// Debug builds assert, on every redirect, that a copy carries the owner's tag and is never itself a
/// key of the table. A reader that skips the redirect is not detected.
pub const ShadowTable = struct {
    allocator: Allocator,
    owner_tag: u32,

    lock: std.Thread.RwLock = .{},

    /// Whether any copy exists. It lets a pop skip the lock until the first write.
    populated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    containers: std.AutoHashMapUnmanaged(*ContainerHeader, ContainerPair) = .{},
    cells: std.AutoHashMapUnmanaged(*const OnceCell, *OnceCell) = .{},

    /// Backing bytes of the copies of borrowed byte arrays. A copy keeps its original's borrowed
    /// storage kind, so it cannot be resized, and the table owns the bytes it points at.
    buffers: std.ArrayListUnmanaged([]u8) = .{},

    /// Both halves hold a reference the table releases when it dies.
    const ContainerPair = struct {
        original: Value,
        shadow: Value,
    };

    pub fn create(allocator: Allocator, owner_tag: u32) error{OutOfMemory}!*ShadowTable {
        const table = try allocator.create(ShadowTable);
        table.* = .{ .allocator = allocator, .owner_tag = owner_tag };
        return table;
    }

    /// Release every copy and every reference to an original, then free the table.
    pub fn destroy(self: *ShadowTable) void {
        var pairs = self.containers.valueIterator();
        while (pairs.next()) |pair| {
            container_backing.releaseValue(pair.shadow);
            container_backing.releaseValue(pair.original);
        }
        self.containers.deinit(self.allocator);

        for (self.buffers.items) |buffer| self.allocator.free(buffer);
        self.buffers.deinit(self.allocator);

        var copies = self.cells.valueIterator();
        while (copies.next()) |copy| {
            if (copy.*.value) |forced| container_backing.releaseValue(forced);
            copy.*.deinit();
            self.allocator.destroy(copy.*);
        }
        self.cells.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// The copy standing in for `v`, or null when `v` has none. Borrowed from the table.
    ///
    /// A container this owner made never has a copy, so it answers without taking the lock.
    pub noinline fn lookup(self: *ShadowTable, v: Value) ?Value {
        const header = mutableHeader(v) orelse return null;
        if (header.ownerTag() == self.owner_tag) return null;
        if (!self.populated.load(.acquire)) return null;

        var tracker = LockOrderTracker{};
        tracker.acquire(.shadow_table);
        self.lock.lockShared();
        defer {
            self.lock.unlockShared();
            tracker.release(.shadow_table);
        }

        const pair = self.containers.get(header) orelse return null;
        self.assertRedirected(pair.shadow);
        return pair.shadow;
    }

    /// Redirect a value just popped off a stack. The slot's reference to an original moves to the
    /// copy, which the caller now owns.
    pub noinline fn redirectPopped(self: *ShadowTable, v: Value) Value {
        const shadow = self.lookup(v) orelse return v;
        container_backing.retainValue(shadow);
        container_backing.releaseValue(v);
        return shadow;
    }

    /// The copy of `original`, made on first use. Borrowed from the table.
    ///
    /// The copy is made outside the table lock. Two threads that race on one original each build a
    /// copy, and the loser drops its own.
    pub fn ensure(self: *ShadowTable, original: Value) error{OutOfMemory}!Value {
        const header = mutableHeader(original) orelse return original;
        if (header.ownerTag() == self.owner_tag) return original;

        if (self.lookup(original)) |existing| return existing;

        const shadow = try copyContainer(self, original);
        errdefer container_backing.releaseValue(shadow);

        var tracker = LockOrderTracker{};
        tracker.acquire(.shadow_table);
        self.lock.lock();
        defer {
            self.lock.unlock();
            tracker.release(.shadow_table);
        }

        if (self.containers.get(header)) |pair| {
            container_backing.releaseValue(shadow);
            return pair.shadow;
        }

        try self.containers.put(self.allocator, header, .{ .original = original, .shadow = shadow });

        container_backing.retainValue(original);
        self.populated.store(true, .release);

        self.assertRedirected(shadow);
        return shadow;
    }

    /// The cell that stands in for `original` when analysis forces it, made on first use.
    ///
    /// The copy starts cold, even when the original is already running. It is owned by this
    /// table's owner, so forcing it publishes a value nothing outside the analysis can see.
    pub fn ensureCell(self: *ShadowTable, original: *OnceCell) error{OutOfMemory}!*OnceCell {
        var tracker = LockOrderTracker{};
        tracker.acquire(.shadow_table);
        self.lock.lock();
        defer {
            self.lock.unlock();
            tracker.release(.shadow_table);
        }

        if (self.cells.get(original)) |copy| return copy;

        const copy = try self.allocator.create(OnceCell);
        errdefer self.allocator.destroy(copy);

        copy.* = .{
            .body = original.body,
            .owner = original.owner,
            .may_define = original.may_define,
            .name = original.name,
            .owner_tag = self.owner_tag,
            .allocator = self.allocator,
        };

        try self.cells.put(self.allocator, original, copy);
        return copy;
    }

    /// The copy of `original`, or null when analysis has not forced it.
    pub fn lookupCell(self: *ShadowTable, original: *const OnceCell) ?*OnceCell {
        var tracker = LockOrderTracker{};
        tracker.acquire(.shadow_table);
        self.lock.lockShared();
        defer {
            self.lock.unlockShared();
            tracker.release(.shadow_table);
        }

        return self.cells.get(original);
    }

    /// Debug only. Check that `shadow` carries this owner's tag and is not itself a key of the table,
    /// so a redirected container is never redirected again. The caller holds the table lock.
    fn assertRedirected(self: *ShadowTable, shadow: Value) void {
        if (builtin.mode != .Debug) return;

        const header = mutableHeader(shadow) orelse unreachable;
        std.debug.assert(header.ownerTag() == self.owner_tag);
        std.debug.assert(!self.containers.contains(header));
    }

    /// Keep `bytes` alive for as long as the table, for a copy that borrows them.
    fn adoptBuffer(self: *ShadowTable, bytes: []u8) error{OutOfMemory}!void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.buffers.append(self.allocator, bytes);
    }
};

/// A shallow copy of `original` on the table's allocator, tagged with its owner. Every element is
/// retained.
fn copyContainer(table: *ShadowTable, original: Value) error{OutOfMemory}!Value {
    const allocator = table.allocator;
    const owner = table.owner_tag;

    return switch (original) {
        .vector => |src| .{ .vector = try copyVector(allocator, owner, src) },
        .mutable_map => |src| .{ .mutable_map = try copyMutableMap(allocator, owner, src) },
        .byte_array => |src| .{ .byte_array = try copyByteArray(table, src) },
        .mutable_value_map => |src| .{ .mutable_value_map = try copyMutableValueMap(allocator, owner, src) },
        .struct_instance => |src| .{ .struct_instance = try copyStructInstance(allocator, owner, src) },
        else => unreachable,
    };
}

fn copyVector(allocator: Allocator, owner: u32, src: *value_mod.Vector) error{OutOfMemory}!*value_mod.Vector {
    const copy = try value_mod.Vector.create(allocator, owner);
    errdefer container_backing.releaseValue(.{ .vector = copy });

    src.header.lock();
    defer src.header.unlock();

    try copy.list.appendSlice(allocator, src.list.items);
    container_backing.retainValues(copy.list.items);

    return copy;
}

fn copyMutableMap(allocator: Allocator, owner: u32, src: *value_mod.MutableMap) error{OutOfMemory}!*value_mod.MutableMap {
    const copy = try value_mod.MutableMap.create(allocator, owner);
    errdefer container_backing.releaseValue(.{ .mutable_map = copy });

    src.header.lock();
    defer src.header.unlock();

    try copy.map.ensureTotalCapacity(allocator, src.map.count());

    var entries = src.map.iterator();
    while (entries.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        copy.map.putAssumeCapacity(key, entry.value_ptr.*);
        container_backing.retainValue(entry.value_ptr.*);
    }

    return copy;
}

/// A copy of a borrowed byte array stays borrowed, so a length change is refused on it as on the
/// original, and its bytes are a private duplicate the table frees.
fn copyByteArray(table: *ShadowTable, src: *value_mod.ByteArray) error{OutOfMemory}!*value_mod.ByteArray {
    const allocator = table.allocator;

    if (src.isBorrowed()) {
        src.header.lock();
        const bytes = allocator.dupe(u8, src.slice()) catch |err| {
            src.header.unlock();
            return err;
        };
        src.header.unlock();
        errdefer allocator.free(bytes);

        const copy = try value_mod.makeBorrowedByteArray(allocator, bytes, table.owner_tag);
        errdefer container_backing.releaseValue(.{ .byte_array = copy });

        try table.adoptBuffer(bytes);
        return copy;
    }

    const copy = try value_mod.ByteArray.create(allocator, table.owner_tag);
    errdefer container_backing.releaseValue(.{ .byte_array = copy });

    src.header.lock();
    defer src.header.unlock();

    copy.syncOwnedView();
    try copy.owned_items.appendSlice(allocator, src.slice());
    copy.refreshOwnedView();

    return copy;
}

fn copyMutableValueMap(allocator: Allocator, owner: u32, src: *value_mod.MutableValueMap) error{OutOfMemory}!*value_mod.MutableValueMap {
    const copy = try value_mod.MutableValueMap.create(allocator, owner);
    errdefer container_backing.releaseValue(.{ .mutable_value_map = copy });

    src.header.lock();
    defer src.header.unlock();

    copy.map = try src.map.clone(allocator);
    container_backing.retainValues(copy.map.keys());
    container_backing.retainValues(copy.map.values());

    return copy;
}

fn copyStructInstance(allocator: Allocator, owner: u32, src: *value_mod.StructInstance) error{OutOfMemory}!*value_mod.StructInstance {
    const header = src.header.?;

    header.lock();
    defer header.unlock();

    const fields = try allocator.dupe(Value, src.fields);
    errdefer allocator.free(fields);

    const copy = try value_mod.createStructInstance(allocator, src.struct_type, fields, owner);
    container_backing.retainValues(fields);

    return copy;
}

const testing = std.testing;

test "a copy is made once and answers every lookup of its original" {
    const table = try ShadowTable.create(testing.allocator, 7);
    defer table.destroy();

    const original = try value_mod.Vector.create(testing.allocator, 0);
    defer container_backing.releaseValue(.{ .vector = original });
    try original.list.append(testing.allocator, .{ .fixnum = 1 });

    const first = try table.ensure(.{ .vector = original });
    const second = try table.ensure(.{ .vector = original });
    try testing.expectEqual(first.vector, second.vector);
    try testing.expect(first.vector != original);
    try testing.expectEqual(@as(u32, 7), first.vector.header.ownerTag());

    try first.vector.list.append(testing.allocator, .{ .fixnum = 2 });
    try testing.expectEqual(@as(usize, 1), original.list.items.len);
    try testing.expectEqual(@as(usize, 2), first.vector.list.items.len);

    const found = table.lookup(.{ .vector = original }).?;
    try testing.expectEqual(first.vector, found.vector);
    try testing.expect(table.lookup(first) == null);
}

test "a container the owner made is never copied" {
    const table = try ShadowTable.create(testing.allocator, 7);
    defer table.destroy();

    const mine = try value_mod.Vector.create(testing.allocator, 7);
    defer container_backing.releaseValue(.{ .vector = mine });

    const same = try table.ensure(.{ .vector = mine });
    try testing.expectEqual(mine, same.vector);
    try testing.expect(table.lookup(.{ .vector = mine }) == null);
}

test "a copy holds its nested originals and outlives the original's other holders" {
    const table = try ShadowTable.create(testing.allocator, 7);
    defer table.destroy();

    const nested = try value_mod.Vector.create(testing.allocator, 0);
    const outer = try value_mod.Vector.create(testing.allocator, 0);
    try outer.list.append(testing.allocator, .{ .vector = nested });

    const copy = try table.ensure(.{ .vector = outer });
    try testing.expectEqual(@as(u32, 2), nested.header.refcountValue());

    container_backing.releaseValue(.{ .vector = outer });
    try testing.expectEqual(@as(usize, 1), copy.vector.list.items.len);
}

test "a copy of a borrowed byte array stays borrowed over bytes of its own" {
    const table = try ShadowTable.create(testing.allocator, 7);
    defer table.destroy();

    var bytes = [_]u8{ 1, 2, 3 };
    const original = try value_mod.makeBorrowedByteArray(testing.allocator, &bytes, 0);
    defer container_backing.releaseValue(.{ .byte_array = original });

    const copy = (try table.ensure(.{ .byte_array = original })).byte_array;
    try testing.expect(copy.isBorrowed());
    try testing.expectEqualSlices(u8, &bytes, copy.slice());

    copy.slice()[0] = 9;
    try testing.expectEqual(@as(u8, 1), bytes[0]);
}

test "a redirected pop moves the slot's reference to the copy" {
    const table = try ShadowTable.create(testing.allocator, 7);
    defer table.destroy();

    const original = try value_mod.Vector.create(testing.allocator, 0);
    defer container_backing.releaseValue(.{ .vector = original });

    const copy = try table.ensure(.{ .vector = original });
    container_backing.retainValue(.{ .vector = original });

    const popped = table.redirectPopped(.{ .vector = original });
    defer container_backing.releaseValue(popped);

    try testing.expectEqual(copy.vector, popped.vector);
    try testing.expectEqual(@as(u32, 2), original.header.refcountValue());
    try testing.expectEqual(@as(u32, 2), copy.vector.header.refcountValue());
}

const AllKinds = struct {
    vec: *value_mod.Vector,
    inst_type: value_mod.StructType,
    inst: *value_mod.StructInstance,
    map: *value_mod.MutableMap,
    owned: *value_mod.ByteArray,
    borrowed: *value_mod.ByteArray,
    values: *value_mod.MutableValueMap,
    bytes: [3]u8 = .{ 1, 2, 3 },

    fn init(self: *AllKinds) !void {
        self.bytes = .{ 1, 2, 3 };

        self.vec = try value_mod.Vector.create(testing.allocator, 0);
        try self.vec.list.append(testing.allocator, .{ .fixnum = 1 });

        self.inst_type = .{ .name = "p", .fields = &.{"x"} };
        const fields = try testing.allocator.alloc(Value, 1);
        fields[0] = .{ .fixnum = 3 };
        self.inst = try value_mod.createStructInstance(testing.allocator, &self.inst_type, fields, 0);

        self.map = try value_mod.MutableMap.create(testing.allocator, 0);
        try self.map.map.put(testing.allocator, try testing.allocator.dupe(u8, "k"), .{ .fixnum = 2 });

        self.owned = try value_mod.ByteArray.create(testing.allocator, 0);
        try self.owned.owned_items.appendSlice(testing.allocator, &self.bytes);
        self.owned.refreshOwnedView();

        self.borrowed = try value_mod.makeBorrowedByteArray(testing.allocator, &self.bytes, 0);

        self.values = try value_mod.MutableValueMap.create(testing.allocator, 0);
        try self.values.map.put(testing.allocator, .{ .fixnum = 1 }, .{ .fixnum = 2 });
    }

    fn deinit(self: *AllKinds) void {
        container_backing.releaseValue(.{ .vector = self.vec });
        container_backing.releaseValue(.{ .struct_instance = self.inst });
        container_backing.releaseValue(.{ .mutable_map = self.map });
        container_backing.releaseValue(.{ .byte_array = self.owned });
        container_backing.releaseValue(.{ .byte_array = self.borrowed });
        container_backing.releaseValue(.{ .mutable_value_map = self.values });
    }
};

fn ensureEveryKind(allocator: Allocator, kinds: *const AllKinds) !void {
    const table = try ShadowTable.create(allocator, 7);
    defer table.destroy();

    var cell = OnceCell{ .body = .{ .instructions = &.{} }, .allocator = testing.allocator };
    defer cell.deinit();

    _ = try table.ensure(.{ .vector = kinds.vec });
    _ = try table.ensure(.{ .struct_instance = kinds.inst });
    _ = try table.ensure(.{ .mutable_map = kinds.map });
    _ = try table.ensure(.{ .byte_array = kinds.owned });
    _ = try table.ensure(.{ .byte_array = kinds.borrowed });
    _ = try table.ensure(.{ .mutable_value_map = kinds.values });
    _ = try table.ensureCell(&cell);
}

test "an allocation failure while copying leaves no entry and leaks nothing" {
    var kinds: AllKinds = undefined;
    try kinds.init();
    defer kinds.deinit();

    try testing.checkAllAllocationFailures(testing.allocator, ensureEveryKind, .{&kinds});
}

test "a failed copy leaves the original uncopied" {
    var kinds: AllKinds = undefined;
    try kinds.init();
    defer kinds.deinit();

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const table = try ShadowTable.create(failing.allocator(), 7);
    defer table.destroy();

    try testing.expectError(error.OutOfMemory, table.ensure(.{ .vector = kinds.vec }));
    try testing.expect(table.lookup(.{ .vector = kinds.vec }) == null);
    try testing.expectEqual(@as(u32, 1), kinds.vec.header.refcountValue());
}
