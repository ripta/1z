const std = @import("std");
const Allocator = std.mem.Allocator;
const DispatchEntry = @import("dispatch.zig").DispatchEntry;

pub const max_pic_entries = 4;

/// A single entry in a polymorphic inline cache, caching the result of
/// a dispatch table lookup keyed by type name pointers. Pointer
/// comparison is safe because all type names are stable: string
/// literals for builtins, arena-allocated for user types.
pub const PicEntry = struct {
    type_a: []const u8 = "",
    type_b: []const u8 = "",
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

    pub fn lookup(self: *const PolymorphicCache, a_type: []const u8, b_type: []const u8) ?*const PicEntry {
        for (self.entries[0..self.count]) |*e| {
            if (a_type.ptr == e.type_a.ptr and b_type.ptr == e.type_b.ptr) return e;
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
    try std.testing.expect(cache.lookup("fixnum", "fixnum") == null);
}

test "PolymorphicCache insert and lookup" {
    var cache = PolymorphicCache{};
    const type_a: []const u8 = "fixnum";
    const type_b: []const u8 = "fixnum";
    cache.insert(.{ .type_a = type_a, .type_b = type_b });
    try std.testing.expectEqual(@as(u8, 1), cache.count);

    const result = cache.lookup(type_a, type_b);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.type_a.ptr == type_a.ptr);
}

test "PolymorphicCache holds up to max_pic_entries" {
    var cache = PolymorphicCache{};
    const types = [_][]const u8{ "a", "b", "c", "d" };
    for (types) |t| {
        cache.insert(.{ .type_a = t, .type_b = t });
    }
    try std.testing.expectEqual(@as(u8, max_pic_entries), cache.count);
    try std.testing.expect(!cache.megamorphic);

    for (types) |t| {
        try std.testing.expect(cache.lookup(t, t) != null);
    }
}

test "PolymorphicCache becomes megamorphic on overflow" {
    var cache = PolymorphicCache{};
    const types = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (types) |t| {
        cache.insert(.{ .type_a = t, .type_b = t });
    }
    try std.testing.expectEqual(@as(u8, max_pic_entries), cache.count);
    try std.testing.expect(cache.megamorphic);

    // The 5th type should not be in the cache
    try std.testing.expect(cache.lookup(types[4], types[4]) == null);
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
    entry.insert(.{ .type_a = "fixnum", .type_b = "fixnum" });

    try std.testing.expectEqual(@as(u32, 42), table.entries[1].generation);
    try std.testing.expectEqual(@as(u8, 1), table.entries[1].count);
}

test "PicTable zero-length allocation" {
    const allocator = std.testing.allocator;
    var table = try PicTable.init(allocator, 0);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.entries.len);
}
