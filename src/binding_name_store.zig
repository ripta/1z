const std = @import("std");
const Allocator = std.mem.Allocator;

/// Intern table for `;` binding names, one layer per context that owns its loads.
///
/// `;` keys the frame with the slice this store returns, so one copy of a name exists per distinct
/// name rather than per binding. An interned slice is never freed before the table that holds it,
/// which is what keeps every site that copies a frame key by reference sound: a captured scope, a
/// task's frame clone, a module promotion, a defined marker's name.
///
/// The root context's table lives for the process. A context that owns its loads layers a table of
/// its own over its parent's, so a name first seen there dies with it instead of accumulating in
/// the root. Every other context aliases the table of its nearest load owner. A lookup answers from
/// the layer it asks or any layer above, and only a miss copies the name onto the asking layer.
///
/// It carries no lock of its own: the only writer is `Context.defineBinding`, which holds the
/// context's shared write lock for the definition anyway, and that lock covers every layer.
pub const BindingNameStore = struct {
    /// Distinct names, keyed by their own owned copy. Guarded by the context's shared write lock.
    names: std.StringHashMapUnmanaged(void) = .{},
    allocator: Allocator,
    /// The layer below this one, or null for the root's table. Outlives this layer: a layer is
    /// destroyed with its owning context, which its parent's owner outlives.
    parent: ?*const BindingNameStore = null,

    pub fn create(allocator: Allocator, parent: ?*const BindingNameStore) error{OutOfMemory}!*BindingNameStore {
        const self = try allocator.create(BindingNameStore);
        self.* = .{ .allocator = allocator, .parent = parent };
        return self;
    }

    pub fn destroy(self: *BindingNameStore) void {
        const allocator = self.allocator;

        var it = self.names.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.names.deinit(allocator);

        allocator.destroy(self);
    }

    /// The shared slice for `name`, copying it onto this layer on first sight. A name already
    /// interned on this layer or any layer above answers with that layer's slice. Caller holds the
    /// shared write lock.
    ///
    /// The name arrives as symbol bytes the caller releases on return, so the store never aliases
    /// them. A definition that fails after the probe leaves the name interned; the next attempt
    /// reuses it.
    pub fn internLocked(self: *BindingNameStore, name: []const u8) error{OutOfMemory}![]const u8 {
        var layer: ?*const BindingNameStore = self;
        while (layer) |l| : (layer = l.parent) {
            if (l.names.getKey(name)) |existing| return existing;
        }

        const copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(copy);
        try self.names.putNoClobber(self.allocator, copy, {});
        return copy;
    }

    /// Whether `key` is a slice this layer or any layer above interned, by pointer identity. A
    /// slice with equal bytes that lives elsewhere does not count. Caller holds the shared lock.
    pub fn owns(self: *const BindingNameStore, key: []const u8) bool {
        var layer: ?*const BindingNameStore = self;
        while (layer) |l| : (layer = l.parent) {
            const existing = l.names.getKey(key) orelse continue;
            if (existing.ptr == key.ptr and existing.len == key.len) return true;
        }
        return false;
    }

    /// Distinct names held on this layer alone. For diagnostics and tests; the caller serializes
    /// against writers.
    pub fn count(self: *const BindingNameStore) usize {
        return self.names.count();
    }
};

const testing = std.testing;

test "BindingNameStore: one name interns to one slice" {
    const store = try BindingNameStore.create(testing.allocator, null);
    defer store.destroy();

    const first = try store.internLocked("x");
    const second = try store.internLocked("x");

    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqualStrings("x", first);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "BindingNameStore: the interned slice is a copy" {
    const store = try BindingNameStore.create(testing.allocator, null);
    defer store.destroy();

    // A caller-owned buffer the store must not alias, mutated after the intern.
    var buf = "shared-name".*;
    const interned = try store.internLocked(&buf);
    @memset(&buf, 'x');

    try testing.expect(interned.ptr != @as([*]const u8, &buf));
    try testing.expectEqualStrings("shared-name", interned);
}

test "BindingNameStore: distinct names take distinct slices" {
    const store = try BindingNameStore.create(testing.allocator, null);
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
    const store = try BindingNameStore.create(failing.allocator(), null);
    defer store.destroy();

    try testing.expectError(error.OutOfMemory, store.internLocked("x"));
    try testing.expectEqual(@as(usize, 0), store.count());
}

test "BindingNameStore: a layer reuses a name a lower layer interned" {
    const root = try BindingNameStore.create(testing.allocator, null);
    defer root.destroy();
    const layer = try BindingNameStore.create(testing.allocator, root);
    defer layer.destroy();

    const below = try root.internLocked("shared");
    const above = try layer.internLocked("shared");

    try testing.expectEqual(below.ptr, above.ptr);
    try testing.expectEqual(@as(usize, 0), layer.count());
}

test "BindingNameStore: a new name lands on the asking layer only" {
    const root = try BindingNameStore.create(testing.allocator, null);
    defer root.destroy();
    const layer = try BindingNameStore.create(testing.allocator, root);
    defer layer.destroy();

    const fresh = try layer.internLocked("fresh");

    try testing.expectEqual(@as(usize, 1), layer.count());
    try testing.expectEqual(@as(usize, 0), root.count());
    try testing.expect(layer.owns(fresh));
    try testing.expect(!root.owns(fresh));
}

test "BindingNameStore: owns answers by identity, not by bytes" {
    const store = try BindingNameStore.create(testing.allocator, null);
    defer store.destroy();

    const interned = try store.internLocked("name");
    var elsewhere = "name".*;

    try testing.expect(store.owns(interned));
    try testing.expect(!store.owns(&elsewhere));
}
