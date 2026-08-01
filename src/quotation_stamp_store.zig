const std = @import("std");

const value_mod = @import("value.zig");

/// Process-shared, write-once map from a quotation body's instruction-slice pointer to the module
/// the body was written in.
///
/// A body's defining module is metadata of the body. Bodies live as long as their module, and
/// modules are process-shared through the module cache. So the stamp cannot live in a per-context
/// map. A spawned task runs in a fresh context and would see none of them.
///
/// The store is allocated by the root context, aliased by pointer into every child, and freed only
/// by the root.
///
/// Reads take no lock. Writers serialize on `write_mu` and apply first-stamp-wins. The first module
/// to stamp a body is its original defining module. That matters because a reexporting module later
/// reprocesses the same instruction-slice pointers.
pub const QuotationStampStore = struct {
    allocator: std.mem.Allocator,
    published: std.atomic.Value(*Table),
    write_mu: std.Thread.Mutex = .{},

    /// Tables displaced by growth. A reader may still be probing one through a pointer it loaded
    /// before the swap, so a displaced table stays allocated until `destroy`. Guarded by
    /// `write_mu`.
    retired: std.ArrayListUnmanaged(*Table) = .{},

    /// Occupied slots in the published table. Guarded by `write_mu`.
    live: usize = 0,

    /// Small enough that a context which never loads a module wastes nothing worth counting.
    /// `create` allocates the table eagerly at this size, so `lookup` needs no null-table branch.
    const initial_capacity: usize = 64;

    /// An open-addressed table with linear probing, sized to a power of two.
    ///
    /// Entries are write-once and never removed, which is what lets a writer insert into a table
    /// readers are concurrently probing. A key lands in one slot and stays there for the table's
    /// life, and every slot on its probe path was already occupied when it was inserted. So a
    /// later insert of a different key can never make a reader stop at an empty slot before
    /// reaching a key that was published before the reader could reach the body.
    ///
    /// A slot is written value-first then key-second, both `.release`. A reader that acquires a
    /// key therefore also sees that key's value.
    const Table = struct {
        /// `0` marks an empty slot. Never a real key: `stampQuotationBodies` skips zero-length
        /// instruction slices, which are the only bodies whose `.ptr` could be a shared sentinel.
        keys: []std.atomic.Value(usize),
        vals: []std.atomic.Value(?*const value_mod.Module),
        mask: usize,
    };

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*QuotationStampStore {
        const table = try allocTable(allocator, initial_capacity);
        errdefer freeTable(allocator, table);

        const self = try allocator.create(QuotationStampStore);
        self.* = .{
            .allocator = allocator,
            .published = std.atomic.Value(*Table).init(table),
        };
        return self;
    }

    pub fn destroy(self: *QuotationStampStore) void {
        const allocator = self.allocator;
        freeTable(allocator, self.published.load(.monotonic));
        for (self.retired.items) |t| freeTable(allocator, t);
        self.retired.deinit(allocator);
        allocator.destroy(self);
    }

    /// The module `key`'s body was written in, or null if the body was never stamped.
    ///
    /// One acquire load plus one probe, no lock. A stampless body is the common case -- every
    /// entry-file, REPL, and `eval-string` body -- so this must stay cheap.
    pub fn lookup(self: *const QuotationStampStore, key: usize) ?*const value_mod.Module {
        if (key == 0) return null;

        const table = self.published.load(.acquire);
        var i = slotIndex(key, table.mask);
        while (true) {
            const found = table.keys[i].load(.acquire);
            if (found == 0) return null;
            if (found == key) return table.vals[i].load(.acquire);
            i = (i + 1) & table.mask;
        }
    }

    /// Record `module` as the defining module of the body at `key`, unless the body already
    /// carries a stamp.
    pub fn stamp(self: *QuotationStampStore, key: usize, module: *const value_mod.Module) error{OutOfMemory}!void {
        std.debug.assert(key != 0);

        self.write_mu.lock();
        defer self.write_mu.unlock();

        var table = self.published.load(.monotonic);
        var i = slotIndex(key, table.mask);
        while (true) {
            const found = table.keys[i].load(.monotonic);
            if (found == 0) break;
            if (found == key) return;
            i = (i + 1) & table.mask;
        }

        // Grow at 3/4 load. Keeping one slot empty is what terminates a missing key's probe.
        if ((self.live + 1) * 4 > (table.mask + 1) * 3) {
            table = try self.grow();
            i = slotIndex(key, table.mask);
            while (table.keys[i].load(.monotonic) != 0) i = (i + 1) & table.mask;
        }

        table.vals[i].store(module, .release);
        table.keys[i].store(key, .release);
        self.live += 1;
    }

    /// Occupied slot count. Diagnostics and tests.
    pub fn count(self: *QuotationStampStore) usize {
        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.live;
    }

    /// Published table capacity. Diagnostics and tests; racy against a concurrent growth.
    pub fn capacity(self: *const QuotationStampStore) usize {
        return self.published.load(.acquire).mask + 1;
    }

    /// Double the table, republish it, and retire the old one.
    ///
    /// The caller holds `write_mu`, so this is the only thread writing either table. The retire
    /// slot is reserved before the new table exists, so a successful swap can never be followed by
    /// a failing append that would strand the displaced table with no owner.
    fn grow(self: *QuotationStampStore) error{OutOfMemory}!*Table {
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

        const vals = try allocator.alloc(std.atomic.Value(?*const value_mod.Module), cap);
        errdefer allocator.free(vals);
        for (vals) |*v| v.* = std.atomic.Value(?*const value_mod.Module).init(null);

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

const testing = std.testing;

fn testModule(name: []const u8) value_mod.Module {
    return .{ .name = name, .words = .{} };
}

test "QuotationStampStore: a stamped body resolves to its module" {
    const store = try QuotationStampStore.create(testing.allocator);
    defer store.destroy();

    var alpha = testModule("alpha");
    try store.stamp(0x1000, &alpha);

    try testing.expectEqual(@as(?*const value_mod.Module, &alpha), store.lookup(0x1000));
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "QuotationStampStore: an unstamped key resolves to null" {
    const store = try QuotationStampStore.create(testing.allocator);
    defer store.destroy();

    var alpha = testModule("alpha");
    try store.stamp(0x1000, &alpha);

    try testing.expectEqual(@as(?*const value_mod.Module, null), store.lookup(0x2000));
    try testing.expectEqual(@as(?*const value_mod.Module, null), store.lookup(0));
}

test "QuotationStampStore: the first stamp wins" {
    const store = try QuotationStampStore.create(testing.allocator);
    defer store.destroy();

    var original = testModule("original");
    var reexporter = testModule("reexporter");

    try store.stamp(0x1000, &original);
    try store.stamp(0x1000, &reexporter);

    try testing.expectEqual(@as(?*const value_mod.Module, &original), store.lookup(0x1000));
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "QuotationStampStore: growth preserves every entry" {
    const store = try QuotationStampStore.create(testing.allocator);
    defer store.destroy();

    var even = testModule("even");
    var odd = testModule("odd");

    const entries: usize = 1000;
    var key: usize = 1;
    while (key <= entries) : (key += 1) {
        try store.stamp(key * 8, if (key % 2 == 0) &even else &odd);
    }

    key = 1;
    while (key <= entries) : (key += 1) {
        const expected: *const value_mod.Module = if (key % 2 == 0) &even else &odd;
        try testing.expectEqual(@as(?*const value_mod.Module, expected), store.lookup(key * 8));
    }

    try testing.expectEqual(entries, store.count());
    try testing.expect(store.capacity() > 64);
    try testing.expect(store.retired.items.len > 0);

    // A missing key walks its collision run and falls off the end rather than looping, which is
    // what the load factor's spare slots buy.
    try testing.expectEqual(@as(?*const value_mod.Module, null), store.lookup(0x7fff_ffff));
}

const StampRaceArgs = struct {
    store: *QuotationStampStore,
    /// Alternated by key parity, so a keys/vals index mismatch shows up as a wrong module rather
    /// than passing on a single shared pointer.
    even: *const value_mod.Module,
    odd: *const value_mod.Module,
    entries: usize,
    /// Keys `1..published` have completed their `stamp` call. Readers only assert on those.
    published: *std.atomic.Value(usize),
    /// Set by whichever thread gives up. Every thread watches it, so one failure ends the run
    /// instead of leaving the others spinning until the harness times out.
    failed: *std.atomic.Value(bool),

    fn expected(self: StampRaceArgs, key: usize) *const value_mod.Module {
        return if (key % 2 == 0) self.even else self.odd;
    }
};

fn stampRaceWriter(args: StampRaceArgs) void {
    var key: usize = 1;
    while (key <= args.entries) : (key += 1) {
        args.store.stamp(key * 8, args.expected(key)) catch {
            args.failed.store(true, .release);
            return;
        };
        args.published.store(key, .release);
    }
}

fn stampRaceReader(args: StampRaceArgs) void {
    while (true) {
        if (args.failed.load(.acquire)) return;

        const high = args.published.load(.acquire);
        var key: usize = 1;
        while (key <= high) : (key += 1) {
            if (args.store.lookup(key * 8) != args.expected(key)) {
                args.failed.store(true, .release);
                return;
            }
        }
        if (high >= args.entries) return;
    }
}

test "QuotationStampStore: a published stamp stays visible to readers across a growth" {
    const store = try QuotationStampStore.create(testing.allocator);
    defer store.destroy();

    const entries: usize = 2000;
    var even = testModule("even");
    var odd = testModule("odd");
    var published = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);

    const args: StampRaceArgs = .{
        .store = store,
        .even = &even,
        .odd = &odd,
        .entries = entries,
        .published = &published,
        .failed = &failed,
    };

    var readers: [3]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, stampRaceReader, .{args});
    const writer = try std.Thread.spawn(.{}, stampRaceWriter, .{args});

    writer.join();
    for (readers) |t| t.join();

    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(entries, store.count());
}
