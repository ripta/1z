const std = @import("std");
const Allocator = std.mem.Allocator;
const JitBuffer = @import("ffi/ir.zig").JitBuffer;
const pic_mod = @import("pic.zig");
const PicTable = pic_mod.PicTable;
const PolymorphicCache = pic_mod.PolymorphicCache;
const dictionary_mod = @import("dictionary.zig");
const StackEffect = @import("stack_effect.zig").StackEffect;

/// Cached per-word data letting `jitNativeWordCall` dispatch a hosted-AOT
/// native word with zero dictionary lookups. Populated exactly once, at
/// process startup, by `capi.registerNativeLeaf` resolving the word's
/// dictionary slot; thereafter `jitNativeWordCall` reads it as a pure
/// word_id-indexed pointer dereference.
pub const NativeLeafData = struct {
    fn_ptr: dictionary_mod.NativeFn,
    /// Mirrors `WordDefinition.dispatch_id`; passed to `tryDispatchGenericById`.
    dispatch_id: u32,
    /// Borrowed from the definition this leaf was resolved from. The definition boxes its own
    /// effect on a context arena, so the pointer is valid for the process's lifetime whether the
    /// leaf came from the dictionary or from a module's word map.
    stack_effect: ?*const StackEffect,
    source_file: ?[]const u8,
};

pub const JitEntry = struct {
    code_ptr: ?*const anyopaque,
    jit_buf: ?JitBuffer,
    word_name: []const u8,
    /// The module segment of this word's compiled identity, or null for a
    /// module-less word. Set only by AOT registration, borrowing the binary's
    /// static `onez_word_modules[]` string. Resolution keys stay bare:
    /// `word_name` is the lookup key, the module scopes it.
    module: ?[]const u8 = null,
    /// The composed `<module>/<word>` display name, or null when the word has
    /// no module. Composed once at AOT registration and owned by the table;
    /// `deinit` frees it.
    qualified_name: ?[]const u8 = null,
    call_count: u32 = 0,
    uncompilable: bool = false,
    /// Peak stack slots used above the current stack pointer during
    /// compiled execution. Used to ensure the value stack has enough
    /// capacity before entering compiled code.
    peak_stack_depth: u32 = 0,
    /// Snapshot of the interpreter's PIC table at compilation time.
    /// Captured so compiled code can benefit from type profiles
    /// observed during interpretation.
    pic_snapshot: ?*PicTable = null,
    /// Per-word PIC for generic dispatch consulted on the generic-marker
    /// paths of both `jitInterpretedCall` (compound fallback) and
    /// `jitNativeWordCall` (native dispatch). Lazily allocated on first
    /// call for a generic word. Caches dispatch table lookups so repeated
    /// calls avoid the full lookup.
    dispatch_pic: ?*PolymorphicCache = null,
    /// Present only when this word_id is a hosted-AOT native primitive.
    /// See `NativeLeafData`.
    native: ?*NativeLeafData = null,

    /// The name traces, profiles, and error frames display for this word.
    pub fn displayName(self: JitEntry) []const u8 {
        return self.qualified_name orelse self.word_name;
    }
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
            if (entry.pic_snapshot) |ps| {
                ps.deinit();
                self.allocator.destroy(ps);
            }
            if (entry.dispatch_pic) |dp| {
                self.allocator.destroy(dp);
            }
            if (entry.native) |n| {
                self.allocator.destroy(n);
            }
            if (entry.qualified_name) |q| {
                self.allocator.free(q);
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
    pub fn update(self: *JitDispatchTable, word_id: u32, code_ptr: *const anyopaque, buf: JitBuffer, peak: u32) void {
        if (self.entries.items[word_id].jit_buf) |old_buf| {
            old_buf.deinit();
        }
        self.entries.items[word_id].code_ptr = code_ptr;
        self.entries.items[word_id].jit_buf = buf;
        self.entries.items[word_id].peak_stack_depth = peak;
    }

    /// Clear the code pointer for a word ID. Frees the JitBuffer.
    /// Also resets call count and uncompilable flag so the word can be
    /// recompiled after module reload.
    pub fn invalidate(self: *JitDispatchTable, word_id: u32) void {
        if (self.entries.items[word_id].jit_buf) |buf| {
            buf.deinit();
        }
        if (self.entries.items[word_id].pic_snapshot) |ps| {
            ps.deinit();
            self.allocator.destroy(ps);
        }
        if (self.entries.items[word_id].dispatch_pic) |dp| {
            self.allocator.destroy(dp);
        }
        self.entries.items[word_id].code_ptr = null;
        self.entries.items[word_id].jit_buf = null;
        self.entries.items[word_id].call_count = 0;
        self.entries.items[word_id].uncompilable = false;
        self.entries.items[word_id].pic_snapshot = null;
        self.entries.items[word_id].dispatch_pic = null;
    }

    pub fn replacePicSnapshot(self: *JitDispatchTable, word_id: u32, pic_snapshot: ?*PicTable) void {
        if (self.entries.items[word_id].pic_snapshot) |old_ps| {
            old_ps.deinit();
            self.allocator.destroy(old_ps);
        }
        self.entries.items[word_id].pic_snapshot = pic_snapshot;
    }

    /// Grow the entries array to at least `count` slots, filling new slots
    /// with null placeholders. Used by AOT to pre-allocate the dispatch table.
    pub fn ensureCapacity(self: *JitDispatchTable, count: u32) !void {
        while (self.entries.items.len < count) {
            try self.entries.append(self.allocator, .{
                .code_ptr = null,
                .jit_buf = null,
                .word_name = "",
            });
        }
    }

    /// Set the code pointer for a word ID without a JitBuffer. Used by AOT
    /// where compiled code lives in the executable's text segment.
    pub fn setCodePtr(self: *JitDispatchTable, word_id: u32, code_ptr: *const anyopaque) void {
        self.entries.items[word_id].code_ptr = code_ptr;
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

    table.update(id, fake_ptr, fake_buf, 0);

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

    table.update(id, fake_ptr, fake_buf, 0);
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
    try std.testing.expectEqual(null, entry.pic_snapshot);
}

test "invalidate frees and nulls pic_snapshot" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("foo");

    var dummy: u8 = 0;
    const fake_ptr: *const anyopaque = &dummy;
    const fake_buf = JitBuffer{ .code = @constCast(fake_ptr), .size = 0 };
    table.update(id, fake_ptr, fake_buf, 0);

    // Attach a real PicTable snapshot
    const ps = try std.testing.allocator.create(PicTable);
    ps.* = try PicTable.init(std.testing.allocator, 3);
    table.getMut(id).?.pic_snapshot = ps;

    table.invalidate(id);

    const entry = table.get(id).?;
    try std.testing.expectEqual(null, entry.pic_snapshot);
}

test "invalidate frees and nulls dispatch_pic" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("foo");

    // Attach a heap-allocated PolymorphicCache
    const dp = try std.testing.allocator.create(PolymorphicCache);
    dp.* = .{};
    table.getMut(id).?.dispatch_pic = dp;

    table.invalidate(id);

    const entry = table.get(id).?;
    try std.testing.expectEqual(null, entry.dispatch_pic);
}

test "multiple IDs coexist independently" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id0 = try table.assignId("alpha");
    const id1 = try table.assignId("beta");

    var dummy0: u8 = 0;
    const ptr0: *const anyopaque = &dummy0;
    const buf0 = JitBuffer{ .code = @constCast(ptr0), .size = 0 };
    table.update(id0, ptr0, buf0, 0);

    // id1 remains uncompiled
    const entry0 = table.get(id0).?;
    const entry1 = table.get(id1).?;

    try std.testing.expectEqual(ptr0, entry0.code_ptr.?);
    try std.testing.expectEqual(null, entry1.code_ptr);
    try std.testing.expectEqualStrings("alpha", entry0.word_name);
    try std.testing.expectEqualStrings("beta", entry1.word_name);
}

test "ensureCapacity grows table to requested size" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    try table.ensureCapacity(5);
    try std.testing.expectEqual(@as(usize, 5), table.entries.items.len);

    for (0..5) |i| {
        const entry = table.get(@intCast(i)).?;
        try std.testing.expectEqual(null, entry.code_ptr);
    }
}

test "ensureCapacity is no-op when already large enough" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.assignId("foo");
    _ = try table.assignId("bar");
    _ = try table.assignId("baz");

    try table.ensureCapacity(2);
    try std.testing.expectEqual(@as(usize, 3), table.entries.items.len);
}

test "displayName prefers qualified_name and falls back to word_name" {
    const bare = JitEntry{ .code_ptr = null, .jit_buf = null, .word_name = "encode" };
    try std.testing.expectEqualStrings("encode", bare.displayName());

    const qualified = JitEntry{
        .code_ptr = null,
        .jit_buf = null,
        .word_name = "encode",
        .module = "data/url",
        .qualified_name = "data/url/encode",
    };
    try std.testing.expectEqualStrings("data/url/encode", qualified.displayName());
}

test "deinit frees an owned qualified_name" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.assignId("encode");
    const q = try std.testing.allocator.dupe(u8, "data/url/encode");
    table.getMut(id).?.qualified_name = q;
}

test "setCodePtr sets pointer without JitBuffer" {
    var table = JitDispatchTable.init(std.testing.allocator);
    defer table.deinit();

    try table.ensureCapacity(3);

    var dummy: u8 = 0;
    const fake_ptr: *const anyopaque = &dummy;
    table.setCodePtr(1, fake_ptr);

    try std.testing.expectEqual(null, table.get(0).?.code_ptr);
    try std.testing.expectEqual(fake_ptr, table.get(1).?.code_ptr.?);
    try std.testing.expectEqual(null, table.get(1).?.jit_buf);
    try std.testing.expectEqual(null, table.get(2).?.code_ptr);
}
