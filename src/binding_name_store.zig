const std = @import("std");
const Allocator = std.mem.Allocator;

/// Process-shared intern table for `;` binding names.
///
/// `;` keys the frame with the slice this store returns, so one copy of a name exists per distinct
/// name rather than per binding. An interned slice is never freed before the root context's
/// teardown, which is what keeps every site that copies a frame key by reference sound: a captured
/// scope, a task's frame clone, a module promotion, a defined marker's name.
///
/// Allocated by the root context, aliased by pointer into every child, and freed only by the root.
/// It carries no lock of its own: the only writer is `Context.defineBinding`, which holds the
/// context's shared write lock for the definition anyway, so the probe rides that acquisition.
pub const BindingNameStore = struct {
    /// Distinct names, keyed by their own owned copy. Guarded by the context's shared write lock.
    names: std.StringHashMapUnmanaged(void) = .{},
    allocator: Allocator,

    pub fn create(allocator: Allocator) error{OutOfMemory}!*BindingNameStore {
        const self = try allocator.create(BindingNameStore);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *BindingNameStore) void {
        const allocator = self.allocator;

        var it = self.names.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.names.deinit(allocator);

        allocator.destroy(self);
    }

    /// The shared slice for `name`, copying it on first sight. Caller holds the shared write lock.
    ///
    /// The name arrives as symbol bytes the caller releases on return, so the store never aliases
    /// them. A definition that fails after the probe leaves the name interned; the next attempt
    /// reuses it.
    pub fn internLocked(self: *BindingNameStore, name: []const u8) error{OutOfMemory}![]const u8 {
        if (self.names.getKey(name)) |existing| return existing;

        const copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(copy);
        try self.names.putNoClobber(self.allocator, copy, {});
        return copy;
    }

    /// Distinct names held. For diagnostics and tests; the caller serializes against writers.
    pub fn count(self: *const BindingNameStore) usize {
        return self.names.count();
    }
};

const testing = std.testing;

test "BindingNameStore: one name interns to one slice" {
    const store = try BindingNameStore.create(testing.allocator);
    defer store.destroy();

    const first = try store.internLocked("x");
    const second = try store.internLocked("x");

    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqualStrings("x", first);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "BindingNameStore: the interned slice is a copy" {
    const store = try BindingNameStore.create(testing.allocator);
    defer store.destroy();

    // A caller-owned buffer the store must not alias, mutated after the intern.
    var buf = "shared-name".*;
    const interned = try store.internLocked(&buf);
    @memset(&buf, 'x');

    try testing.expect(interned.ptr != @as([*]const u8, &buf));
    try testing.expectEqualStrings("shared-name", interned);
}

test "BindingNameStore: distinct names take distinct slices" {
    const store = try BindingNameStore.create(testing.allocator);
    defer store.destroy();

    const a = try store.internLocked("a");
    const b = try store.internLocked("b");
    const c = try store.internLocked("c");

    try testing.expect(a.ptr != b.ptr);
    try testing.expect(b.ptr != c.ptr);
    try testing.expectEqual(@as(usize, 3), store.count());
}

test "BindingNameStore: a failed first-sight insert leaves the table unchanged" {
    // Allocation 0 is the store, 1 is the name copy, 2 is the table's first growth.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    const store = try BindingNameStore.create(failing.allocator());
    defer store.destroy();

    try testing.expectError(error.OutOfMemory, store.internLocked("x"));
    try testing.expectEqual(@as(usize, 0), store.count());
}
