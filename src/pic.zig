const std = @import("std");
const Allocator = std.mem.Allocator;
const DispatchEntry = @import("dispatch.zig").DispatchEntry;
const value_mod = @import("value.zig");
const TypeDescriptor = value_mod.TypeDescriptor;

pub const max_pic_entries = 4;

/// A single entry in a polymorphic inline cache, caching the result of
/// a dispatch table lookup keyed by descriptor pointers.
pub const PicEntry = struct {
    type_a: *const TypeDescriptor = undefined,
    type_b: *const TypeDescriptor = undefined,
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

    pub fn lookup(self: *const PolymorphicCache, a_type: *const TypeDescriptor, b_type: *const TypeDescriptor) ?*const PicEntry {
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

    /// Create an independent copy of this PicTable. The clone owns its
    /// own entries slice and can be freed independently.
    pub fn clone(self: *const PicTable, allocator: Allocator) !PicTable {
        const entries = try allocator.alloc(PolymorphicCache, self.entries.len);
        @memcpy(entries, self.entries);
        return .{ .entries = entries, .allocator = allocator };
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
    const fixnum_desc = try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);
    try std.testing.expect(cache.lookup(fixnum_desc, fixnum_desc) == null);
}

test "PolymorphicCache insert and lookup" {
    var cache = PolymorphicCache{};
    const type_a_desc = try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, type_a_desc);
    const type_b_desc = try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, type_b_desc);
    cache.insert(.{ .type_a = type_a_desc, .type_b = type_b_desc });
    try std.testing.expectEqual(@as(u8, 1), cache.count);

    const result = cache.lookup(type_a_desc, type_b_desc);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.type_a == type_a_desc);
}

test "PolymorphicCache holds up to max_pic_entries" {
    var cache = PolymorphicCache{};
    const descs = [_]*value_mod.TypeDescriptor{
        try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{}),
        try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{}),
        try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{}),
        try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{}),
    };
    defer {
        for (descs) |desc| value_mod.destroyTypeDescriptor(std.testing.allocator, desc);
    }
    for (descs) |desc| {
        cache.insert(.{ .type_a = desc, .type_b = desc });
    }
    try std.testing.expectEqual(@as(u8, max_pic_entries), cache.count);
    try std.testing.expect(!cache.megamorphic);

    for (descs) |desc| {
        try std.testing.expect(cache.lookup(desc, desc) != null);
    }
}

test "PolymorphicCache becomes megamorphic on overflow" {
    var cache = PolymorphicCache{};
    const descs = [_]*value_mod.TypeDescriptor{
        try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{}),
        try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{}),
        try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{}),
        try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{}),
        try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{}),
    };
    defer {
        for (descs) |desc| value_mod.destroyTypeDescriptor(std.testing.allocator, desc);
    }
    for (descs) |desc| {
        cache.insert(.{ .type_a = desc, .type_b = desc });
    }
    try std.testing.expectEqual(@as(u8, max_pic_entries), cache.count);
    try std.testing.expect(cache.megamorphic);

    // The 5th type should not be in the cache
    try std.testing.expect(cache.lookup(descs[4], descs[4]) == null);
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
    const fixnum_desc = try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);
    entry.insert(.{ .type_a = fixnum_desc, .type_b = fixnum_desc });

    try std.testing.expectEqual(@as(u32, 42), table.entries[1].generation);
    try std.testing.expectEqual(@as(u8, 1), table.entries[1].count);
}

test "PicTable zero-length allocation" {
    const allocator = std.testing.allocator;
    var table = try PicTable.init(allocator, 0);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.entries.len);
}

test "PicTable clone produces independent copy" {
    const allocator = std.testing.allocator;
    var original = try PicTable.init(allocator, 3);
    defer original.deinit();

    const desc = try value_mod.createBuiltinTypeDescriptor(allocator, .{});
    defer value_mod.destroyTypeDescriptor(allocator, desc);

    original.get(1).insert(.{ .type_a = desc, .type_b = desc });
    original.get(1).generation = 42;

    var cloned = try original.clone(allocator);
    defer cloned.deinit();

    try std.testing.expectEqual(@as(usize, 3), cloned.entries.len);
    try std.testing.expectEqual(@as(u8, 1), cloned.entries[1].count);
    try std.testing.expectEqual(@as(u32, 42), cloned.entries[1].generation);
    try std.testing.expect(cloned.entries[1].lookup(desc, desc) != null);

    // Mutating clone does not affect original
    cloned.get(1).generation = 99;
    try std.testing.expectEqual(@as(u32, 42), original.entries[1].generation);
}
