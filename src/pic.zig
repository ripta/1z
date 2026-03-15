const std = @import("std");
const Allocator = std.mem.Allocator;
const DispatchEntry = @import("dispatch.zig").DispatchEntry;

/// Monomorphic inline cache entry for a single call site.
///
/// Caches the result of a dispatch table lookup keyed by type name
/// pointers. Pointer comparison is safe because all type names are
/// stable: string literals for builtins, arena-allocated for user types.
pub const MonomorphicCache = struct {
    /// Cached type name pointers (compared by pointer identity).
    type_a: []const u8 = "",
    type_b: []const u8 = "",
    /// Cached dispatch result.
    entry: DispatchEntry = undefined,
    unwrap_a: bool = false,
    unwrap_b: bool = false,
    /// Generation counter from DispatchTable at the time of caching.
    generation: u32 = 0,
    /// Whether this cache entry contains valid data.
    valid: bool = false,
};

/// Per-word PIC table, with one MonomorphicCache slot per instruction.
///
/// Only `call_word` instructions use their slot; other instruction
/// slots remain empty (valid=false).
pub const PicTable = struct {
    entries: []MonomorphicCache,
    allocator: Allocator,

    pub fn init(allocator: Allocator, num_instructions: usize) !PicTable {
        const entries = try allocator.alloc(MonomorphicCache, num_instructions);
        @memset(entries, MonomorphicCache{});
        return .{
            .entries = entries,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PicTable) void {
        self.allocator.free(self.entries);
    }

    /// Get a pointer to the cache entry for a given instruction index.
    pub fn get(self: *PicTable, idx: usize) *MonomorphicCache {
        return &self.entries[idx];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MonomorphicCache defaults to invalid" {
    const cache = MonomorphicCache{};
    try std.testing.expect(!cache.valid);
    try std.testing.expectEqual(@as(u32, 0), cache.generation);
}

test "PicTable init creates entries with correct count" {
    const allocator = std.testing.allocator;
    var table = try PicTable.init(allocator, 5);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 5), table.entries.len);
    for (table.entries) |entry| {
        try std.testing.expect(!entry.valid);
    }
}

test "PicTable get returns mutable pointer to entry" {
    const allocator = std.testing.allocator;
    var table = try PicTable.init(allocator, 3);
    defer table.deinit();

    const entry = table.get(1);
    try std.testing.expect(!entry.valid);

    entry.valid = true;
    entry.generation = 42;

    try std.testing.expect(table.entries[1].valid);
    try std.testing.expectEqual(@as(u32, 42), table.entries[1].generation);
}

test "PicTable zero-length allocation" {
    const allocator = std.testing.allocator;
    var table = try PicTable.init(allocator, 0);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.entries.len);
}
