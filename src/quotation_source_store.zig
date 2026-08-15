const std = @import("std");

const AtomicSlotMap = @import("atomic_slot_map.zig").AtomicSlotMap;

/// An owned copy of a source file name, shared by every body parsed from that file.
pub const SourceName = struct {
    text: []const u8,
};

/// Process-shared, write-once map from a body's instruction-slice pointer to the source file the
/// body was written in.
///
/// A call frame records where a call happened: `instr.line` is a line in the body currently
/// executing, so the frame's source must be that body's file. `current_source` tracks the defining
/// file of the innermost executing word instead, which is the same file for a word body and a
/// different one the moment a quotation written in one file runs under a word defined in another.
/// This store is what closes that gap: the parser knows a body's file exactly, and records it here.
///
/// The store is separate from `QuotationStampStore` rather than an extra field on it. That store
/// holds a body's defining *module* and is deliberately empty for entry-file, REPL, and prelude
/// bodies, which are exactly the bodies error attribution needs. It also stamps at module
/// finalization, which runs after parsing, so one write-once slot cannot serve both.
///
/// Entries are permanent, so only process-lifetime keys may enter: a body parsed onto a task or
/// scoped-eval arena dies with it and would leave a key that a later unrelated allocation at the
/// same address falsely matches. `Context.stampQuotationBodySource` applies that gate.
///
/// The store is allocated by the root context, aliased by pointer into every child, and freed only
/// by the root.
///
/// Reads take no lock. Writers serialize on `write_mu` and apply first-stamp-wins, which is what a
/// repeated parse of the same slice would write anyway.
pub const QuotationSourceStore = struct {
    /// Key `0` marks an empty slot in the map and is never a real key: `stampQuotationBodySource`
    /// skips zero-length instruction slices, which are the only bodies whose `.ptr` could be a
    /// shared sentinel.
    map: AtomicSlotMap(?*const SourceName),

    /// Distinct source names, keyed by their own owned text. Guarded by `write_mu`.
    ///
    /// A source name reaches `stamp` as `ctx.current_source`, which a module load points at a
    /// caller-owned `filename` for the load's duration only. The store cannot alias that, and one
    /// copy per body would be one copy per quotation in the program, so names are interned.
    interned: std.StringHashMapUnmanaged(*SourceName) = .{},

    write_mu: std.Thread.Mutex = .{},

    /// Every parsed body takes a slot, unlike the module stamps. The prelude alone contributes one
    /// per quotation plus one per top-level statement, which is upwards of a thousand before a
    /// program parses a line of its own. Sizing for that keeps growth, whose displaced tables stay
    /// allocated until teardown, off the common path.
    const initial_capacity: usize = 4096;

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*QuotationSourceStore {
        var map = try AtomicSlotMap(?*const SourceName).init(allocator, initial_capacity);
        errdefer map.deinit();

        const self = try allocator.create(QuotationSourceStore);
        self.* = .{ .map = map };
        return self;
    }

    pub fn destroy(self: *QuotationSourceStore) void {
        const allocator = self.map.allocator;

        var it = self.interned.valueIterator();
        while (it.next()) |name| {
            allocator.free(name.*.text);
            allocator.destroy(name.*);
        }
        self.interned.deinit(allocator);

        self.map.deinit();
        allocator.destroy(self);
    }

    /// The source file the body at `key` was written in, or null if the body was never stamped.
    ///
    /// One acquire load plus one probe, no lock. This runs on every quotation-body entry, so it
    /// must stay cheap.
    pub fn lookup(self: *const QuotationSourceStore, key: usize) ?[]const u8 {
        const name = self.map.lookup(key) orelse return null;
        return name.text;
    }

    /// Record `source` as the file the body at `key` was written in, unless the body already
    /// carries a stamp.
    pub fn stamp(self: *QuotationSourceStore, key: usize, source: []const u8) error{OutOfMemory}!void {
        std.debug.assert(key != 0);

        self.write_mu.lock();
        defer self.write_mu.unlock();

        if (self.map.lookup(key) != null) return;

        const name = try self.intern(source);
        _ = try self.map.insert(key, name);
    }

    /// Occupied slot count. Diagnostics and tests.
    pub fn count(self: *QuotationSourceStore) usize {
        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.map.count();
    }

    /// Distinct source names held. Diagnostics and tests.
    pub fn sourceCount(self: *QuotationSourceStore) usize {
        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.interned.count();
    }

    /// Published table capacity. Diagnostics and tests; racy against a concurrent growth.
    pub fn capacity(self: *const QuotationSourceStore) usize {
        return self.map.capacity();
    }

    /// The shared name for `source`, allocating one on first sight. Caller holds `write_mu`.
    ///
    /// The hash map is keyed by the owned copy, so a key outlives the caller's slice.
    fn intern(self: *QuotationSourceStore, source: []const u8) error{OutOfMemory}!*const SourceName {
        if (self.interned.get(source)) |existing| return existing;

        const allocator = self.map.allocator;

        const text = try allocator.dupe(u8, source);
        errdefer allocator.free(text);

        const name = try allocator.create(SourceName);
        errdefer allocator.destroy(name);
        name.* = .{ .text = text };

        try self.interned.put(allocator, text, name);
        return name;
    }
};

const testing = std.testing;

test "QuotationSourceStore: a stamped body resolves to its source" {
    const store = try QuotationSourceStore.create(testing.allocator);
    defer store.destroy();

    try store.stamp(0x1000, "src/prelude.1z");

    try testing.expectEqualStrings("src/prelude.1z", store.lookup(0x1000).?);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "QuotationSourceStore: an unstamped key resolves to null" {
    const store = try QuotationSourceStore.create(testing.allocator);
    defer store.destroy();

    try store.stamp(0x1000, "src/prelude.1z");

    try testing.expectEqual(@as(?[]const u8, null), store.lookup(0x2000));
    try testing.expectEqual(@as(?[]const u8, null), store.lookup(0));
}

test "QuotationSourceStore: the first stamp wins" {
    const store = try QuotationSourceStore.create(testing.allocator);
    defer store.destroy();

    try store.stamp(0x1000, "first.1z");
    try store.stamp(0x1000, "second.1z");

    try testing.expectEqualStrings("first.1z", store.lookup(0x1000).?);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "QuotationSourceStore: bodies from one file share a single owned name" {
    const store = try QuotationSourceStore.create(testing.allocator);
    defer store.destroy();

    // A caller-owned buffer the store must not alias, mutated after both stamps.
    var buf = "shared.1z".*;
    try store.stamp(0x1000, &buf);
    try store.stamp(0x2000, &buf);
    try store.stamp(0x3000, "other.1z");
    @memset(&buf, 'x');

    try testing.expectEqualStrings("shared.1z", store.lookup(0x1000).?);
    try testing.expectEqual(store.lookup(0x1000).?.ptr, store.lookup(0x2000).?.ptr);
    try testing.expectEqual(@as(usize, 3), store.count());
    try testing.expectEqual(@as(usize, 2), store.sourceCount());
}

test "QuotationSourceStore: growth preserves every entry" {
    const store = try QuotationSourceStore.create(testing.allocator);
    defer store.destroy();

    const entries: usize = 8000;
    var key: usize = 1;
    while (key <= entries) : (key += 1) {
        try store.stamp(key * 8, if (key % 2 == 0) "even.1z" else "odd.1z");
    }

    key = 1;
    while (key <= entries) : (key += 1) {
        const expected: []const u8 = if (key % 2 == 0) "even.1z" else "odd.1z";
        try testing.expectEqualStrings(expected, store.lookup(key * 8).?);
    }

    try testing.expectEqual(entries, store.count());
    try testing.expectEqual(@as(usize, 2), store.sourceCount());
    try testing.expect(store.capacity() > 4096);

    // A missing key walks its collision run and falls off the end rather than looping, which is
    // what the load factor's spare slots buy.
    try testing.expectEqual(@as(?[]const u8, null), store.lookup(0x7fff_ffff));
}
