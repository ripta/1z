const std = @import("std");
const Allocator = std.mem.Allocator;
const JitBuffer = @import("ffi/ir.zig").JitBuffer;

pub const JitEntry = struct {
    code_ptr: ?*const anyopaque,
    jit_buf: ?JitBuffer,
    word_name: []const u8,
    call_count: u32 = 0,
    uncompilable: bool = false,
};

pub const JitDispatchTable = struct {
    entries: std.ArrayListUnmanaged(JitEntry),
    allocator: Allocator,

    pub fn init(allocator: Allocator) JitDispatchTable {
        return .{
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JitDispatchTable) void {
        for (self.entries.items) |*entry| {
            if (entry.jit_buf) |buf| {
                buf.deinit();
            }
        }
        self.entries.deinit(self.allocator);
    }

    /// Allocate a new word ID and return it. Entry starts with null code_ptr.
    pub fn assignId(self: *JitDispatchTable, word_name: []const u8) !u32 {
        const id: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, .{
            .code_ptr = null,
            .jit_buf = null,
            .word_name = word_name,
        });
        return id;
    }

    /// Get entry by word ID.
    pub fn get(self: *const JitDispatchTable, word_id: u32) ?JitEntry {
        if (word_id >= self.entries.items.len) return null;
        return self.entries.items[word_id];
    }

    /// Get mutable pointer to entry by word ID.
    pub fn getMut(self: *JitDispatchTable, word_id: u32) ?*JitEntry {
        if (word_id >= self.entries.items.len) return null;
        return &self.entries.items[word_id];
    }

    /// Mark a word as permanently uncompilable.
    pub fn markUncompilable(self: *JitDispatchTable, word_id: u32) void {
        if (word_id < self.entries.items.len) {
            self.entries.items[word_id].uncompilable = true;
        }
    }

    /// Update the code pointer and JitBuffer for a word ID.
    /// Frees the old JitBuffer if one exists.
    pub fn update(self: *JitDispatchTable, word_id: u32, code_ptr: *const anyopaque, buf: JitBuffer) void {
        if (self.entries.items[word_id].jit_buf) |old_buf| {
            old_buf.deinit();
        }
        self.entries.items[word_id].code_ptr = code_ptr;
        self.entries.items[word_id].jit_buf = buf;
    }

    /// Clear the code pointer for a word ID. Frees the JitBuffer.
    /// Also resets call count and uncompilable flag so the word can be
    /// recompiled after module reload.
    pub fn invalidate(self: *JitDispatchTable, word_id: u32) void {
        if (self.entries.items[word_id].jit_buf) |buf| {
            buf.deinit();
        }
        self.entries.items[word_id].code_ptr = null;
        self.entries.items[word_id].jit_buf = null;
        self.entries.items[word_id].call_count = 0;
        self.entries.items[word_id].uncompilable = false;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "assignId returns sequential IDs starting from 0" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id0 = try table.assignId("foo");
    const id1 = try table.assignId("bar");
    const id2 = try table.assignId("baz");

    try std.testing.expectEqual(@as(u32, 0), id0);
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);
}

test "get returns null code_ptr for newly assigned ID" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("foo");
    const entry = table.get(id);

    try std.testing.expect(entry != null);
    try std.testing.expectEqual(null, entry.?.code_ptr);
    try std.testing.expectEqual(null, entry.?.jit_buf);
    try std.testing.expectEqualStrings("foo", entry.?.word_name);
}

test "get returns null for out-of-bounds ID" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expectEqual(null, table.get(0));
    try std.testing.expectEqual(null, table.get(42));
}

test "update sets code_ptr and jit_buf" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("foo");

    // Simulate a compiled code pointer (use a stack variable address for testing)
    var dummy: u8 = 0;
    const fake_ptr: *const anyopaque = &dummy;
    const fake_buf = JitBuffer{ .code = @constCast(fake_ptr), .size = 0 };

    table.update(id, fake_ptr, fake_buf);

    const entry = table.get(id).?;
    try std.testing.expectEqual(fake_ptr, entry.code_ptr.?);
    try std.testing.expect(entry.jit_buf != null);
}

test "invalidate clears code_ptr and jit_buf" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("foo");

    var dummy: u8 = 0;
    const fake_ptr: *const anyopaque = &dummy;
    const fake_buf = JitBuffer{ .code = @constCast(fake_ptr), .size = 0 };

    table.update(id, fake_ptr, fake_buf);
    table.invalidate(id);

    const entry = table.get(id).?;
    try std.testing.expectEqual(null, entry.code_ptr);
    try std.testing.expectEqual(null, entry.jit_buf);
}

test "getMut returns mutable pointer" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("foo");
    const entry = table.getMut(id).?;

    try std.testing.expectEqual(@as(u32, 0), entry.call_count);
    entry.call_count += 1;
    try std.testing.expectEqual(@as(u32, 1), table.get(id).?.call_count);
}

test "getMut returns null for out-of-bounds ID" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expectEqual(null, table.getMut(0));
    try std.testing.expectEqual(null, table.getMut(42));
}

test "markUncompilable sets flag" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("foo");
    try std.testing.expect(!table.get(id).?.uncompilable);

    table.markUncompilable(id);
    try std.testing.expect(table.get(id).?.uncompilable);
}

test "invalidate resets call_count and uncompilable" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("foo");
    table.getMut(id).?.call_count = 50;
    table.markUncompilable(id);

    table.invalidate(id);

    const entry = table.get(id).?;
    try std.testing.expectEqual(@as(u32, 0), entry.call_count);
    try std.testing.expect(!entry.uncompilable);
}

test "new entries have zero call_count and uncompilable false" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("foo");
    const entry = table.get(id).?;

    try std.testing.expectEqual(@as(u32, 0), entry.call_count);
    try std.testing.expect(!entry.uncompilable);
}

test "multiple IDs coexist independently" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id0 = try table.assignId("alpha");
    const id1 = try table.assignId("beta");

    var dummy0: u8 = 0;
    const ptr0: *const anyopaque = &dummy0;
    const buf0 = JitBuffer{ .code = @constCast(ptr0), .size = 0 };
    table.update(id0, ptr0, buf0);

    // id1 remains uncompiled
    const entry0 = table.get(id0).?;
    const entry1 = table.get(id1).?;

    try std.testing.expectEqual(ptr0, entry0.code_ptr.?);
    try std.testing.expectEqual(null, entry1.code_ptr);
    try std.testing.expectEqualStrings("alpha", entry0.word_name);
    try std.testing.expectEqualStrings("beta", entry1.word_name);
}
