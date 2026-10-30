const std = @import("std");

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;

/// What the expansion pass learned from one resolution, reduced to facts that compare by value.
pub const Answer = struct {
    kind: Kind,
    body_ptr: usize = 0,
    body_len: usize = 0,
    name_ptr: usize = 0,
    name_len: usize = 0,
    file_ptr: usize = 0,
    file_len: usize = 0,
    slot: usize = 0,

    pub const Kind = enum {
        /// The call names nothing.
        unresolved,

        /// The call names a word the pass leaves alone.
        plain,

        /// The call names an `inline` word with a body of its own.
        body,

        /// A call copied into another file, bound to this dictionary slot.
        bound,

        /// A call copied into another file that no slot can name.
        unbound,
    };
};

/// One question the pass asked while expanding a body, with the answer it got.
///
/// The two phases ask about the same call differently. `resolve` asks which word the call reaches.
/// `relocate` asks which slot a call copied out of another file binds to.
pub const Consult = struct {
    op: Instruction.Op,
    phase: Phase,
    answer: Answer,

    pub const Phase = enum { resolve, relocate };
};

/// An expanded body, with everything its expansion depended on.
///
/// The expansion reads the live dictionary and frames, so a cached body serves a later
/// definition only while every recorded question still gets the answer it got then. The questions
/// are asked again in the order they were recorded. Each depends only on the call it was asked
/// about, so equal answers replay the whole walk.
///
/// An entry is never changed or removed once recorded.
pub const Entry = struct {
    source_len: usize,
    expanded: []const Instruction,
    defining: []u8,
    caller_file: []u8,
    consults: []Consult,

    fn free(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.defining);
        allocator.free(self.caller_file);
        allocator.free(self.consults);
    }
};

/// Expanded bodies by the address of the parsed body they came from, one layer per load owner.
///
/// A key is the address of a body that the arena of the layer's load owner holds, and the expanded
/// body sits on that same arena. So neither outlives the layer, and no dead key can match a
/// recycled address.
///
/// Like the other body-keyed stores, a recorded entry stays, and a layer links to its parent's.
/// The difference is that one key can hold several entries. What the expansion reads from the
/// dictionary can change, and an entry stands for one set of answers. A writer appends an entry
/// only when none of the chain's entries for the key holds, so the count for a key is bounded by
/// the distinct answer sets the program produces. Every access runs under the shared write lock,
/// which is why the table needs no lock of its own and readers are not lock-free.
pub const InlineExpansionCache = struct {
    allocator: std.mem.Allocator,
    parent: ?*const InlineExpansionCache,
    map: std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged(Entry)) = .{},

    pub fn init(allocator: std.mem.Allocator, parent: ?*const InlineExpansionCache) InlineExpansionCache {
        return .{ .allocator = allocator, .parent = parent };
    }

    pub fn deinit(self: *InlineExpansionCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |versions| {
            for (versions.items) |entry| entry.free(self.allocator);
            versions.deinit(self.allocator);
        }
        self.map.deinit(self.allocator);
    }

    /// The newest entry for `key`, in this layer and then each parent, that `matcher.holds`
    /// accepts. The result is valid until the next `put`.
    pub fn firstMatch(self: *const InlineExpansionCache, key: usize, matcher: anytype) ?*const Entry {
        var cur: ?*const InlineExpansionCache = self;
        while (cur) |layer| : (cur = layer.parent) {
            const versions = layer.map.getPtr(key) orelse continue;

            var i = versions.items.len;
            while (i > 0) {
                i -= 1;
                if (matcher.holds(&versions.items[i])) return &versions.items[i];
            }
        }
        return null;
    }

    /// Record an expansion in this layer. Copies the names and the questions.
    pub fn put(
        self: *InlineExpansionCache,
        key: usize,
        source_len: usize,
        expanded: []const Instruction,
        defining: []const u8,
        caller_file: []const u8,
        consults: []const Consult,
    ) error{OutOfMemory}!void {
        const defining_copy = try self.allocator.dupe(u8, defining);
        errdefer self.allocator.free(defining_copy);

        const file_copy = try self.allocator.dupe(u8, caller_file);
        errdefer self.allocator.free(file_copy);

        const consults_copy = try self.allocator.dupe(Consult, consults);
        errdefer self.allocator.free(consults_copy);

        const gop = try self.map.getOrPut(self.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};

        try gop.value_ptr.append(self.allocator, .{
            .source_len = source_len,
            .expanded = expanded,
            .defining = defining_copy,
            .caller_file = file_copy,
            .consults = consults_copy,
        });
    }

    /// The number of keys this layer holds.
    pub fn count(self: *const InlineExpansionCache) usize {
        return self.map.count();
    }

    /// The number of entries this layer holds for `key`.
    pub fn versionCount(self: *const InlineExpansionCache, key: usize) usize {
        const versions = self.map.getPtr(key) orelse return 0;
        return versions.items.len;
    }
};

const testing = std.testing;

const AnyEntry = struct {
    want_len: usize,

    pub fn holds(self: AnyEntry, entry: *const Entry) bool {
        return entry.source_len == self.want_len;
    }
};

test "InlineExpansionCache: a layer reads through its parent and never changes a recorded entry" {
    var base = InlineExpansionCache.init(testing.allocator, null);
    defer base.deinit();

    var layer = InlineExpansionCache.init(testing.allocator, &base);
    defer layer.deinit();

    const body = [_]Instruction{.{ .op = .{ .call_word = "x" }, .line = 1 }};

    try base.put(0x1000, 1, &body, "word", "file.1z", &.{});
    try testing.expect(layer.firstMatch(0x1000, AnyEntry{ .want_len = 1 }) != null);
    try testing.expect(layer.firstMatch(0x1000, AnyEntry{ .want_len = 2 }) == null);
    try testing.expect(layer.firstMatch(0x2000, AnyEntry{ .want_len = 1 }) == null);

    try layer.put(0x1000, 2, &body, "word", "file.1z", &.{});
    try testing.expect(layer.firstMatch(0x1000, AnyEntry{ .want_len = 2 }) != null);
    try testing.expect(base.firstMatch(0x1000, AnyEntry{ .want_len = 2 }) == null);

    try layer.put(0x1000, 3, &body, "word", "file.1z", &.{});
    try testing.expectEqual(@as(usize, 2), layer.versionCount(0x1000));
    try testing.expectEqual(@as(usize, 1), base.versionCount(0x1000));
    try testing.expect(layer.firstMatch(0x1000, AnyEntry{ .want_len = 2 }) != null);
}
