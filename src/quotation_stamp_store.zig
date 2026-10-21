const std = @import("std");

const value_mod = @import("value.zig");
const AtomicSlotMap = @import("atomic_slot_map.zig").AtomicSlotMap;

/// Write-once map, one layer per load owner, from a quotation body's instruction-slice pointer to the module
/// the body was written in.
///
/// A body's defining module is metadata of the body. Bodies live as long as their module, and
/// modules are process-shared through the module cache. So the stamp cannot live in a per-context
/// map. A spawned task runs in a fresh context and would see none of them.
///
/// The lifetime coupling cuts both ways: an entry lasts as long as its layer, so a key must outlive
/// the layer it enters. A body decoded onto a task's arena dies with the task, and stamping it here
/// would leave a key that can falsely match an unrelated later allocation at the same address.
/// Task-lifetime decodes go through the shared `ReifiedDecodeCache` instead, whose slices live on
/// its process-lifetime arena.
///
/// The store is one layer of a `BodyKeyedStores` set. The root's layer is the base, and a context
/// that owns its loads has a layer of its own, linked to its parent's. Every other context aliases
/// the set of its nearest load owner.
///
/// Reads take no lock. Writers serialize on `write_mu` and apply first-stamp-wins across the
/// layers. The first module to stamp a body is its original defining module. That matters because a
/// reexporting module later reprocesses the same instruction-slice pointers.
pub const QuotationStampStore = struct {
    /// Key `0` marks an empty slot in the map and is never a real key: `stampQuotationBodies`
    /// skips zero-length instruction slices, which are the only bodies whose `.ptr` could be a
    /// shared sentinel.
    map: AtomicSlotMap(?*const value_mod.Module),
    write_mu: std.Thread.Mutex = .{},

    /// Small enough that a context which never loads a module wastes nothing worth counting.
    /// `init` allocates the table eagerly at this size, so `lookup` needs no null-table branch.
    const initial_capacity: usize = 64;

    /// A layer over `parent`, or the base layer when `parent` is null.
    pub fn init(allocator: std.mem.Allocator, parent: ?*const QuotationStampStore) error{OutOfMemory}!QuotationStampStore {
        const map = try AtomicSlotMap(?*const value_mod.Module).initLayered(
            allocator,
            initial_capacity,
            if (parent) |p| &p.map else null,
        );
        return .{ .map = map };
    }

    pub fn deinit(self: *QuotationStampStore) void {
        self.map.deinit();
    }

    /// The module `key`'s body was written in, or null if the body was never stamped.
    ///
    /// One acquire load plus one probe, no lock. A stampless body is the common case -- every
    /// entry-file, REPL, and `eval-string` body -- so this must stay cheap.
    pub fn lookup(self: *const QuotationStampStore, key: usize) ?*const value_mod.Module {
        return self.map.lookup(key);
    }

    /// Record `module` as the defining module of the body at `key`, unless the body already
    /// carries a stamp, and report whether this call stamped. A false return means the body and
    /// everything nested under it were already stamped, which is what lets
    /// `stampQuotationBodies` prune its recursion.
    pub fn stamp(self: *QuotationStampStore, key: usize, module: *const value_mod.Module) error{OutOfMemory}!bool {
        std.debug.assert(key != 0);

        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.map.insert(key, module);
    }

    /// Occupied slot count. Diagnostics and tests.
    pub fn count(self: *QuotationStampStore) usize {
        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.map.count();
    }

    /// Published table capacity. Diagnostics and tests; racy against a concurrent growth.
    pub fn capacity(self: *const QuotationStampStore) usize {
        return self.map.capacity();
    }
};

const testing = std.testing;

fn testModule(name: []const u8) value_mod.Module {
    return .{ .name = name, .words = .{} };
}

test "QuotationStampStore: a stamped body resolves to its module" {
    var store = try QuotationStampStore.init(testing.allocator, null);
    defer store.deinit();

    var alpha = testModule("alpha");
    try testing.expect(try store.stamp(0x1000, &alpha));

    try testing.expectEqual(@as(?*const value_mod.Module, &alpha), store.lookup(0x1000));
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "QuotationStampStore: an unstamped key resolves to null" {
    var store = try QuotationStampStore.init(testing.allocator, null);
    defer store.deinit();

    var alpha = testModule("alpha");
    _ = try store.stamp(0x1000, &alpha);

    try testing.expectEqual(@as(?*const value_mod.Module, null), store.lookup(0x2000));
    try testing.expectEqual(@as(?*const value_mod.Module, null), store.lookup(0));
}

test "QuotationStampStore: the first stamp wins" {
    var store = try QuotationStampStore.init(testing.allocator, null);
    defer store.deinit();

    var original = testModule("original");
    var reexporter = testModule("reexporter");

    try testing.expect(try store.stamp(0x1000, &original));
    try testing.expect(!try store.stamp(0x1000, &reexporter));

    try testing.expectEqual(@as(?*const value_mod.Module, &original), store.lookup(0x1000));
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "QuotationStampStore: growth preserves every entry" {
    var store = try QuotationStampStore.init(testing.allocator, null);
    defer store.deinit();

    var even = testModule("even");
    var odd = testModule("odd");

    const entries: usize = 1000;
    var key: usize = 1;
    while (key <= entries) : (key += 1) {
        _ = try store.stamp(key * 8, if (key % 2 == 0) &even else &odd);
    }

    key = 1;
    while (key <= entries) : (key += 1) {
        const expected: *const value_mod.Module = if (key % 2 == 0) &even else &odd;
        try testing.expectEqual(@as(?*const value_mod.Module, expected), store.lookup(key * 8));
    }

    try testing.expectEqual(entries, store.count());
    try testing.expect(store.capacity() > 64);
    try testing.expect(store.map.retired.items.len > 0);

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
        _ = args.store.stamp(key * 8, args.expected(key)) catch {
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
    var store = try QuotationStampStore.init(testing.allocator, null);
    defer store.deinit();

    const entries: usize = 2000;
    var even = testModule("even");
    var odd = testModule("odd");
    var published = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);

    const args: StampRaceArgs = .{
        .store = &store,
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
