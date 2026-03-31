const std = @import("std");
const Allocator = std.mem.Allocator;
const DispatchEntry = @import("dispatch.zig").DispatchEntry;
const value_mod = @import("value.zig");
const TypeValue = value_mod.TypeValue;

pub const max_pic_entries = 4;

/// A single entry in a polymorphic inline cache, caching the result of
/// a dispatch table lookup keyed by TypeValue pointers. Pointer
/// comparison is safe because TypeValue objects have stable identity.
pub const PicEntry = struct {
    type_a: *const TypeValue = undefined,
    type_b: *const TypeValue = undefined,
    entry: DispatchEntry = undefined,
    unwrap_a: bool = false,
    unwrap_b: bool = false,
};

/// Polymorphic inline cache for a single call site.
///
/// Holds up to `max_pic_entries` cached type pairs. When a new type
/// pair would exceed capacity, the cache transitions to a sticky
/// megamorphic state that permanently bypasses the cache.
pub const PolymorphicCache = struct {
    entries: [max_pic_entries]PicEntry = [_]PicEntry{.{}} ** max_pic_entries,
    count: u8 = 0,
    generation: u32 = 0,
    megamorphic: bool = false,

    pub fn lookup(self: *const PolymorphicCache, a_type: *const TypeValue, b_type: *const TypeValue) ?*const PicEntry {
        for (self.entries[0..self.count]) |*e| {
            if (a_type == e.type_a and b_type == e.type_b) return e;
        }
        return null;
    }

    pub fn insert(self: *PolymorphicCache, pe: PicEntry) void {
        if (self.count < max_pic_entries) {
            self.entries[self.count] = pe;
            self.count += 1;
        } else {
            self.megamorphic = true;
        }
    }
};

/// Per-word PIC table, with one PolymorphicCache slot per instruction.
///
/// Only `call_word` instructions use their slot; other instruction
/// slots remain empty (count=0).
pub const PicTable = struct {
    entries: []PolymorphicCache,
    allocator: Allocator,

    pub fn init(allocator: Allocator, num_instructions: usize) !PicTable {
        const entries = try allocator.alloc(PolymorphicCache, num_instructions);
        @memset(entries, PolymorphicCache{});
        return .{
            .entries = entries,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PicTable) void {
        self.allocator.free(self.entries);
    }

    /// Get a pointer to the cache for a given instruction index.
    pub fn get(self: *PicTable, idx: usize) *PolymorphicCache {
        return &self.entries[idx];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "PolymorphicCache defaults to empty" {
    const cache = PolymorphicCache{};
    try std.testing.expectEqual(@as(u8, 0), cache.count);
    try std.testing.expect(!cache.megamorphic);
    try std.testing.expectEqual(@as(u32, 0), cache.generation);
}

test "PolymorphicCache lookup returns null when empty" {
    const cache = PolymorphicCache{};
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    try std.testing.expect(cache.lookup(&fixnum_tv, &fixnum_tv) == null);
}

test "PolymorphicCache insert and lookup" {
    var cache = PolymorphicCache{};
    var type_a_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var type_b_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    cache.insert(.{ .type_a = &type_a_tv, .type_b = &type_b_tv });
    try std.testing.expectEqual(@as(u8, 1), cache.count);

    const result = cache.lookup(&type_a_tv, &type_b_tv);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.type_a == &type_a_tv);
}

test "PolymorphicCache holds up to max_pic_entries" {
    var cache = PolymorphicCache{};
    var tvs = [_]TypeValue{
        .{ .name = "a", .descriptor = null },
        .{ .name = "b", .descriptor = null },
        .{ .name = "c", .descriptor = null },
        .{ .name = "d", .descriptor = null },
    };
    for (&tvs) |*tv| {
        cache.insert(.{ .type_a = tv, .type_b = tv });
    }
    try std.testing.expectEqual(@as(u8, max_pic_entries), cache.count);
    try std.testing.expect(!cache.megamorphic);

    for (&tvs) |*tv| {
        try std.testing.expect(cache.lookup(tv, tv) != null);
    }
}

test "PolymorphicCache becomes megamorphic on overflow" {
    var cache = PolymorphicCache{};
    var tvs = [_]TypeValue{
        .{ .name = "a", .descriptor = null },
        .{ .name = "b", .descriptor = null },
        .{ .name = "c", .descriptor = null },
        .{ .name = "d", .descriptor = null },
        .{ .name = "e", .descriptor = null },
    };
    for (&tvs) |*tv| {
        cache.insert(.{ .type_a = tv, .type_b = tv });
    }
    try std.testing.expectEqual(@as(u8, max_pic_entries), cache.count);
    try std.testing.expect(cache.megamorphic);

    // The 5th type should not be in the cache
    try std.testing.expect(cache.lookup(&tvs[4], &tvs[4]) == null);
}

test "PicTable init creates entries with correct count" {
    const allocator = std.testing.allocator;
    var table = try PicTable.init(allocator, 5);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 5), table.entries.len);
    for (table.entries) |entry| {
        try std.testing.expectEqual(@as(u8, 0), entry.count);
    }
}

test "PicTable get returns mutable pointer to entry" {
    const allocator = std.testing.allocator;
    var table = try PicTable.init(allocator, 3);
    defer table.deinit();

    const entry = table.get(1);
    try std.testing.expectEqual(@as(u8, 0), entry.count);

    entry.generation = 42;
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    entry.insert(.{ .type_a = &fixnum_tv, .type_b = &fixnum_tv });

    try std.testing.expectEqual(@as(u32, 42), table.entries[1].generation);
    try std.testing.expectEqual(@as(u8, 1), table.entries[1].count);
}

test "PicTable zero-length allocation" {
    const allocator = std.testing.allocator;
    var table = try PicTable.init(allocator, 0);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.entries.len);
}
