const std = @import("std");
const Allocator = std.mem.Allocator;

const LoadLock = @import("load_lock.zig").LoadLock;

/// The modules whose load is in flight, outermost first.
///
/// A module reaches the cache only after its body finishes, so a circular `use` would otherwise
/// re-enter the loader for a file that is already loading and recurse until the memory limit
/// fires. The load lock does not catch it either: it is reentrant on task identity, so a nested
/// load passes straight through.
///
/// The loader pushes an entry on the way into a load and pops it on the way out, so a hit on
/// entry is a cycle and the entries from that hit onward are the chain to name.
///
/// The record is allocated by the root context, aliased by pointer into every child, and freed
/// only by the root.
///
/// Access is serialized by the load lock rather than by a mutex of its own.
pub const ModuleLoadRecord = struct {
    /// One load in flight. Both slices are borrowed from the loader's own call frame, which
    /// outlives the push and pop pair, so neither is duped here.
    pub const Entry = struct {
        /// The resolved path the module cache is keyed on: a filesystem realpath, or a virtual
        /// `<stdlib>/...` path for an embedded-bundle module. Two spellings of one module share
        /// this, which is why it is what membership tests.
        resolved: []const u8,

        /// The name as written at the import site, which is what a diagnostic prints. A chain of
        /// realpaths is unreadable.
        filename: []const u8,

        /// The task identity this load runs on.
        owner: LoadLock.Owner,
    };

    entries: std.ArrayListUnmanaged(Entry) = .{},
    allocator: Allocator,

    pub fn create(allocator: Allocator) error{OutOfMemory}!*ModuleLoadRecord {
        const self = try allocator.create(ModuleLoadRecord);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *ModuleLoadRecord) void {
        const allocator = self.allocator;
        self.entries.deinit(allocator);
        allocator.destroy(self);
    }

    /// Index of the in-flight entry for `resolved`, or null when no load of it is running.
    ///
    /// A linear scan, whose length is the import nesting depth.
    pub fn find(self: *const ModuleLoadRecord, resolved: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.resolved, resolved)) return i;
        }
        return null;
    }

    pub fn push(self: *ModuleLoadRecord, entry: Entry) error{OutOfMemory}!void {
        try self.entries.append(self.allocator, entry);
    }

    /// Drop the innermost entry, which must be the one `resolved` was pushed under.
    ///
    /// The loader pushes and pops within one call's extent and loads serialize on the load lock,
    /// so entries nest strictly and the innermost is always the caller's own. A delegated hold
    /// keeps that property: the borrower's entries sit above the parked owner's and unwind
    /// first.
    pub fn pop(self: *ModuleLoadRecord, resolved: []const u8) void {
        const dropped = self.entries.pop().?;
        std.debug.assert(std.mem.eql(u8, dropped.resolved, resolved));
    }

    /// The entries from `start` to the innermost, which is the cycle a `find` hit at `start`
    /// closed.
    pub fn chainFrom(self: *const ModuleLoadRecord, start: usize) []const Entry {
        return self.entries.items[start..];
    }
};

const testing = std.testing;

fn testEntry(resolved: []const u8, filename: []const u8) ModuleLoadRecord.Entry {
    return .{ .resolved = resolved, .filename = filename, .owner = .main };
}

test "ModuleLoadRecord: a pushed path is found and a popped one is not" {
    const record = try ModuleLoadRecord.create(testing.allocator);
    defer record.destroy();

    try testing.expectEqual(@as(?usize, null), record.find("/a.1z"));

    try record.push(testEntry("/a.1z", "./a.1z"));
    try testing.expectEqual(@as(?usize, 0), record.find("/a.1z"));
    try testing.expectEqual(@as(?usize, null), record.find("/b.1z"));

    record.pop("/a.1z");
    try testing.expectEqual(@as(?usize, null), record.find("/a.1z"));
}

test "ModuleLoadRecord: nested loads unwind to the enclosing one" {
    const record = try ModuleLoadRecord.create(testing.allocator);
    defer record.destroy();

    try record.push(testEntry("/a.1z", "a"));
    try record.push(testEntry("/b.1z", "./b.1z"));
    try record.push(testEntry("/c.1z", "./c.1z"));

    try testing.expectEqual(@as(?usize, 0), record.find("/a.1z"));
    try testing.expectEqual(@as(?usize, 2), record.find("/c.1z"));

    record.pop("/c.1z");
    try testing.expectEqual(@as(?usize, null), record.find("/c.1z"));
    try testing.expectEqual(@as(?usize, 1), record.find("/b.1z"));

    record.pop("/b.1z");
    record.pop("/a.1z");
    try testing.expectEqual(@as(usize, 0), record.entries.items.len);
}

test "ModuleLoadRecord: two spellings of one module share an entry" {
    const record = try ModuleLoadRecord.create(testing.allocator);
    defer record.destroy();

    try record.push(testEntry("/dir/a.1z", "a"));
    try record.push(testEntry("/dir/b.1z", "./b.1z"));

    // What the importer wrote differs; the resolved path is what decides.
    try testing.expectEqual(@as(?usize, 0), record.find("/dir/a.1z"));
}

test "ModuleLoadRecord: the chain runs from the repeated entry to the innermost" {
    const record = try ModuleLoadRecord.create(testing.allocator);
    defer record.destroy();

    try record.push(testEntry("/root.1z", "root"));
    try record.push(testEntry("/a.1z", "./a.1z"));
    try record.push(testEntry("/b.1z", "./b.1z"));

    const chain = record.chainFrom(record.find("/a.1z").?);
    try testing.expectEqual(@as(usize, 2), chain.len);
    try testing.expectEqualStrings("./a.1z", chain[0].filename);
    try testing.expectEqualStrings("./b.1z", chain[1].filename);
}
