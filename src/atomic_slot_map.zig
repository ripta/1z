const std = @import("std");

/// An open-addressed map from a nonzero `usize` key to a nullable pointer value, readable
/// without a lock while a serialized writer inserts in place.
///
/// Entries are write-once and never removed, which is what lets a writer insert into a table
/// readers are concurrently probing. A key lands in one slot and stays there for the table's
/// life, and every slot on its probe path was already occupied when it was inserted. So a later
/// insert of a different key can never make a reader stop at an empty slot before reaching a key
/// published before the reader could obtain it.
///
/// The map holds no mutex of its own: callers must serialize all inserts with each other.
/// Readers take no lock at all -- one acquire load of the published table plus a linear probe.
/// `V` must be a nullable pointer type; `null` is the absent value.
///
/// A map may be layered over a parent map. A lookup probes its own table and then the parent's,
/// so a reader pays one probe per layer. An insert checks the whole chain before writing, so the
/// first insert still wins across layers. Each table stays write-once: a layer is destroyed whole
/// with its owner and never has an entry removed. The parent must outlive every layer above it.
pub fn AtomicSlotMap(comptime V: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        published: std.atomic.Value(*Table),

        /// The layer this one reads through on a miss. Fixed at construction.
        parent: ?*const Self = null,

        /// Tables displaced by growth. A reader may still be probing one through a pointer it
        /// loaded before the swap, so a displaced table stays allocated until `deinit`.
        /// Writer-serialized.
        retired: std.ArrayListUnmanaged(*Table) = .{},

        /// Occupied slots in the published table. Writer-serialized.
        live: usize = 0,

        /// An open-addressed table with linear probing, sized to a power of two.
        ///
        /// A slot is written value-first then key-second, both `.release`. A reader that
        /// acquires a key therefore also sees that key's value.
        const Table = struct {
            /// `0` marks an empty slot. Never a real key: callers must assert their keys are
            /// nonzero.
            keys: []std.atomic.Value(usize),
            vals: []std.atomic.Value(V),
            mask: usize,
        };

        pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) error{OutOfMemory}!Self {
            return initLayered(allocator, initial_capacity, null);
        }

        /// A map that reads through `parent` on a miss and refuses to insert a key `parent`
        /// already holds.
        pub fn initLayered(
            allocator: std.mem.Allocator,
            initial_capacity: usize,
            parent: ?*const Self,
        ) error{OutOfMemory}!Self {
            const table = try allocTable(allocator, initial_capacity);
            return .{
                .allocator = allocator,
                .published = std.atomic.Value(*Table).init(table),
                .parent = parent,
            };
        }

        pub fn deinit(self: *Self) void {
            freeTable(self.allocator, self.published.load(.monotonic));
            for (self.retired.items) |t| freeTable(self.allocator, t);
            self.retired.deinit(self.allocator);
        }

        /// The value at `key`, or null when absent. One acquire load plus one probe per layer, no
        /// lock.
        pub fn lookup(self: *const Self, key: usize) V {
            if (key == 0) return null;

            if (self.lookupOwn(key)) |found| return found;

            const parent = self.parent orelse return null;
            return parent.lookup(key);
        }

        /// The value at `key` in this layer alone.
        fn lookupOwn(self: *const Self, key: usize) V {
            const table = self.published.load(.acquire);
            var i = slotIndex(key, table.mask);
            while (true) {
                const found = table.keys[i].load(.acquire);
                if (found == 0) return null;
                if (found == key) return table.vals[i].load(.acquire);
                i = (i + 1) & table.mask;
            }
        }

        /// Insert `val` at `key` unless the key is already present in this layer or any parent,
        /// and report whether this call inserted. First-insert-wins: a present key keeps its
        /// original value.
        pub fn insert(self: *Self, key: usize, val: V) error{OutOfMemory}!bool {
            std.debug.assert(key != 0);

            if (self.parent) |parent| {
                if (parent.lookup(key) != null) return false;
            }

            var table = self.published.load(.monotonic);
            var i = slotIndex(key, table.mask);
            while (true) {
                const found = table.keys[i].load(.monotonic);
                if (found == 0) break;
                if (found == key) return false;
                i = (i + 1) & table.mask;
            }

            // Grow at 3/4 load. Keeping one slot empty is what terminates a missing key's probe.
            if ((self.live + 1) * 4 > (table.mask + 1) * 3) {
                table = try self.grow();
                i = slotIndex(key, table.mask);
                while (table.keys[i].load(.monotonic) != 0) i = (i + 1) & table.mask;
            }

            table.vals[i].store(val, .release);
            table.keys[i].store(key, .release);
            self.live += 1;
            return true;
        }

        /// Whether `pred` holds for any key in this layer, parents excluded. Diagnostics and tests.
        pub fn anyKey(self: *const Self, ctx: anytype, comptime pred: fn (@TypeOf(ctx), usize) bool) bool {
            const table = self.published.load(.acquire);
            for (table.keys) |*slot| {
                const key = slot.load(.acquire);
                if (key != 0 and pred(ctx, key)) return true;
            }
            return false;
        }

        /// Occupied slot count. `live` is a plain field the serialized writer mutates, so this
        /// takes `*Self` to keep non-writer threads out. Diagnostics and tests.
        pub fn count(self: *Self) usize {
            return self.live;
        }

        /// Published table capacity. Racy against a concurrent growth; diagnostics and tests.
        pub fn capacity(self: *const Self) usize {
            return self.published.load(.acquire).mask + 1;
        }

        /// Double the table, republish it, and retire the old one.
        ///
        /// The caller is the serialized writer, so this is the only thread writing either table.
        /// The retire slot is reserved before the new table exists, so a successful swap can
        /// never be followed by a failing append that would strand the displaced table with no
        /// owner.
        fn grow(self: *Self) error{OutOfMemory}!*Table {
            const old = self.published.load(.monotonic);

            try self.retired.ensureUnusedCapacity(self.allocator, 1);

            const next = try allocTable(self.allocator, (old.mask + 1) * 2);

            for (old.keys, old.vals) |*k, *v| {
                const key = k.load(.monotonic);
                if (key == 0) continue;
                var i = slotIndex(key, next.mask);
                while (next.keys[i].load(.monotonic) != 0) i = (i + 1) & next.mask;
                next.vals[i].store(v.load(.monotonic), .monotonic);
                next.keys[i].store(key, .monotonic);
            }

            self.published.store(next, .release);
            self.retired.appendAssumeCapacity(old);
            return next;
        }

        /// A key is a pointer, so its low bits are alignment zeros. Mix before masking.
        fn slotIndex(key: usize, mask: usize) usize {
            return std.hash.int(key) & mask;
        }

        fn allocTable(allocator: std.mem.Allocator, cap: usize) error{OutOfMemory}!*Table {
            std.debug.assert(std.math.isPowerOfTwo(cap));

            const keys = try allocator.alloc(std.atomic.Value(usize), cap);
            errdefer allocator.free(keys);
            for (keys) |*k| k.* = std.atomic.Value(usize).init(0);

            const vals = try allocator.alloc(std.atomic.Value(V), cap);
            errdefer allocator.free(vals);
            for (vals) |*v| v.* = std.atomic.Value(V).init(null);

            const table = try allocator.create(Table);
            table.* = .{ .keys = keys, .vals = vals, .mask = cap - 1 };
            return table;
        }

        fn freeTable(allocator: std.mem.Allocator, table: *Table) void {
            allocator.free(table.keys);
            allocator.free(table.vals);
            allocator.destroy(table);
        }
    };
}

const testing = std.testing;

const TestMap = AtomicSlotMap(?*const u32);

test "AtomicSlotMap: insert then lookup" {
    var map = try TestMap.init(testing.allocator, 8);
    defer map.deinit();

    const a: u32 = 1;
    try testing.expect(try map.insert(0x1000, &a));

    try testing.expectEqual(@as(?*const u32, &a), map.lookup(0x1000));
    try testing.expectEqual(@as(?*const u32, null), map.lookup(0x2000));
    try testing.expectEqual(@as(?*const u32, null), map.lookup(0));
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "AtomicSlotMap: the first insert wins and repeats report not-inserted" {
    var map = try TestMap.init(testing.allocator, 8);
    defer map.deinit();

    const a: u32 = 1;
    const b: u32 = 2;
    try testing.expect(try map.insert(0x1000, &a));
    try testing.expect(!try map.insert(0x1000, &b));

    try testing.expectEqual(@as(?*const u32, &a), map.lookup(0x1000));
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "AtomicSlotMap: a layer reads through its parent and leaves it untouched" {
    var base = try TestMap.init(testing.allocator, 8);
    defer base.deinit();

    var layer = try TestMap.initLayered(testing.allocator, 8, &base);
    defer layer.deinit();

    const a: u32 = 1;
    const b: u32 = 2;
    try testing.expect(try base.insert(0x1000, &a));
    try testing.expect(try layer.insert(0x2000, &b));

    try testing.expectEqual(@as(?*const u32, &a), layer.lookup(0x1000));
    try testing.expectEqual(@as(?*const u32, &b), layer.lookup(0x2000));
    try testing.expectEqual(@as(?*const u32, null), layer.lookup(0x3000));

    try testing.expectEqual(@as(?*const u32, null), base.lookup(0x2000));
    try testing.expectEqual(@as(usize, 1), base.count());
    try testing.expectEqual(@as(usize, 1), layer.count());
}

test "AtomicSlotMap: the first insert wins across layers" {
    var base = try TestMap.init(testing.allocator, 8);
    defer base.deinit();

    var layer = try TestMap.initLayered(testing.allocator, 8, &base);
    defer layer.deinit();

    const a: u32 = 1;
    const b: u32 = 2;
    try testing.expect(try base.insert(0x1000, &a));
    try testing.expect(!try layer.insert(0x1000, &b));

    try testing.expectEqual(@as(?*const u32, &a), layer.lookup(0x1000));
    try testing.expectEqual(@as(usize, 0), layer.count());
}

test "AtomicSlotMap: a lookup walks a chain of three layers" {
    var root = try TestMap.init(testing.allocator, 8);
    defer root.deinit();

    var middle = try TestMap.initLayered(testing.allocator, 8, &root);
    defer middle.deinit();

    var leaf = try TestMap.initLayered(testing.allocator, 8, &middle);
    defer leaf.deinit();

    const a: u32 = 1;
    const b: u32 = 2;
    try testing.expect(try root.insert(0x1000, &a));
    try testing.expect(try middle.insert(0x2000, &b));

    try testing.expectEqual(@as(?*const u32, &a), leaf.lookup(0x1000));
    try testing.expectEqual(@as(?*const u32, &b), leaf.lookup(0x2000));
    try testing.expect(!try leaf.insert(0x2000, &a));
}

test "AtomicSlotMap: growth preserves every entry and a missing probe terminates" {
    var map = try TestMap.init(testing.allocator, 8);
    defer map.deinit();

    const a: u32 = 1;
    const b: u32 = 2;

    const entries: usize = 500;
    var key: usize = 1;
    while (key <= entries) : (key += 1) {
        try testing.expect(try map.insert(key * 8, if (key % 2 == 0) &a else &b));
    }

    key = 1;
    while (key <= entries) : (key += 1) {
        const expected: *const u32 = if (key % 2 == 0) &a else &b;
        try testing.expectEqual(@as(?*const u32, expected), map.lookup(key * 8));
    }

    try testing.expectEqual(entries, map.count());
    try testing.expect(map.capacity() > 8);
    try testing.expect(map.retired.items.len > 0);
    try testing.expectEqual(@as(?*const u32, null), map.lookup(0x7fff_ffff));
}
