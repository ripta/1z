const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const lock_order = @import("lock_order.zig");
const LockOrderTracker = lock_order.LockOrderTracker;
const value_mod = @import("value.zig");

/// A protocol obligation deferred until a load ends.
///
/// The constraint pointer is the handle to the obligation. Resolving the type's `TypeValue` happens
/// at validation time. A bare protocol bound carries a `ProtocolDescriptor`. A combinator bound
/// (`comparable & stringable`, `fixnum | comparable`) carries a `ConstraintCombinator`.
pub const Obligation = struct {
    type_name: []const u8,
    constraint: Constraint,

    pub const Constraint = union(enum) {
        protocol: *const value_mod.ProtocolDescriptor,
        combination: *const value_mod.ConstraintCombinator,
    };
};

/// The deferred protocol obligations of one load.
///
/// The load holds one reference. Any other context that records into the sink holds its own, so a
/// holder that outlives the load can still read that the sink is closed.
///
/// The sink owns every type name it holds, copied from the shared allocator. Names and list nodes
/// are allocated before the lock is taken, because the allocator takes its own mutex and nothing
/// may be acquired under the sink's lock. The list is intrusive for the same reason: a link under
/// the lock never allocates.
///
/// Taking the pending items and closing the sink happen in one critical section. An append that
/// finds the sink closed returns false, and its caller validates eagerly. Validation takes the
/// context `shared_lock`, so it always runs after the sink's lock is released.
///
/// The refcount is atomic because holders may release on different threads.
pub const ObligationSink = struct {
    refcount: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    allocator: Allocator,
    tracker: *LockOrderTracker,
    mutex: std.Thread.Mutex = .{},
    open: bool = true,
    head: ?*Entry = null,
    tail: ?*Entry = null,

    pub const Entry = struct {
        next: ?*Entry,
        obligation: Obligation,
    };

    /// The items taken from a sink at close. The holder frees them with `deinit`.
    pub const Pending = struct {
        allocator: Allocator,
        head: ?*Entry,

        /// Free every remaining entry and its type name.
        pub fn deinit(self: *Pending) void {
            var cursor = self.head;
            self.head = null;

            while (cursor) |entry| {
                cursor = entry.next;
                self.allocator.free(entry.obligation.type_name);
                self.allocator.destroy(entry);
            }
        }
    };

    pub fn create(allocator: Allocator, tracker: *LockOrderTracker) !*ObligationSink {
        const sink = try allocator.create(ObligationSink);
        sink.* = .{ .allocator = allocator, .tracker = tracker };
        return sink;
    }

    pub fn retain(self: *ObligationSink) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    /// Drop one reference. The last drop frees anything still pending and the sink.
    ///
    /// `.acq_rel` on the decrement makes every other holder's reads happen before the free.
    pub fn release(self: *ObligationSink) void {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        std.debug.assert(prev != 0);
        if (prev != 1) return;

        var pending: Pending = .{ .allocator = self.allocator, .head = self.head };
        pending.deinit();
        self.allocator.destroy(self);
    }

    fn lock(self: *ObligationSink) void {
        self.tracker.acquire(.obligation_sink);
        self.mutex.lock();
    }

    fn unlock(self: *ObligationSink) void {
        self.mutex.unlock();
        self.tracker.release(.obligation_sink);
    }

    /// Record an obligation for the load's drain. Returns false when the sink is closed, and the
    /// caller then validates eagerly. `type_name` is borrowed. The sink keeps its own copy.
    pub fn append(self: *ObligationSink, type_name: []const u8, constraint: Obligation.Constraint) !bool {
        const name = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(name);

        const entry = try self.allocator.create(Entry);
        entry.* = .{ .next = null, .obligation = .{ .type_name = name, .constraint = constraint } };

        self.lock();
        const linked = self.open;
        if (linked) {
            if (self.tail) |tail| {
                tail.next = entry;
            } else {
                self.head = entry;
            }
            self.tail = entry;
        }
        self.unlock();

        if (!linked) {
            self.allocator.free(name);
            self.allocator.destroy(entry);
        }

        return linked;
    }

    pub fn isOpen(self: *ObligationSink) bool {
        self.lock();
        defer self.unlock();

        return self.open;
    }

    /// Take every pending item and close the sink in one critical section. A second call yields
    /// nothing.
    pub fn takeAndClose(self: *ObligationSink) Pending {
        self.lock();
        defer self.unlock();

        const head = self.head;
        self.head = null;
        self.tail = null;
        self.open = false;
        return .{ .allocator = self.allocator, .head = head };
    }

    /// Close the sink and free whatever was pending, unvalidated.
    pub fn discard(self: *ObligationSink) void {
        var pending = self.takeAndClose();
        pending.deinit();
    }

    /// Debug-only check that the sink is closed and holds nothing. It fires only if an entry was
    /// linked after the sink closed, which `append` refuses to do. Call it right after a drain, so
    /// that it checks the drain and not a later discard. A failed load legitimately leaves entries
    /// pending, so it must not call this before discarding.
    pub fn assertClosedAndEmpty(self: *ObligationSink) void {
        if (comptime builtin.mode != .Debug) return;

        self.lock();
        defer self.unlock();

        std.debug.assert(!self.open);
        std.debug.assert(self.head == null and self.tail == null);
    }
};

const testing = std.testing;

fn testDescriptor() value_mod.ProtocolDescriptor {
    return .{ .name = "p", .methods = &.{}, .protocol_id = 0, .durable = true };
}

test "append keeps order and take-and-close yields every item" {
    var tracker = LockOrderTracker{};
    const sink = try ObligationSink.create(testing.allocator, &tracker);
    defer sink.release();

    const desc = testDescriptor();
    try testing.expect(try sink.append("first", .{ .protocol = &desc }));
    try testing.expect(try sink.append("second", .{ .protocol = &desc }));
    try testing.expect(sink.isOpen());

    var pending = sink.takeAndClose();
    defer pending.deinit();

    try testing.expect(!sink.isOpen());
    const first = pending.head.?;
    try testing.expectEqualStrings("first", first.obligation.type_name);
    try testing.expectEqualStrings("second", first.next.?.obligation.type_name);
    try testing.expect(first.next.?.next == null);
    sink.assertClosedAndEmpty();
}

test "append after close returns false and keeps nothing" {
    var tracker = LockOrderTracker{};
    const sink = try ObligationSink.create(testing.allocator, &tracker);
    defer sink.release();

    const desc = testDescriptor();
    var pending = sink.takeAndClose();
    defer pending.deinit();

    try testing.expect(!(try sink.append("late", .{ .protocol = &desc })));
    sink.assertClosedAndEmpty();
}

test "append to a closed sink from another thread frees its copies" {
    var tracker = LockOrderTracker{};
    const sink = try ObligationSink.create(testing.allocator, &tracker);
    defer sink.release();

    sink.discard();

    const desc = testDescriptor();
    const Worker = struct {
        fn run(s: *ObligationSink, d: *const value_mod.ProtocolDescriptor, refused: *std.atomic.Value(u32)) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const ok = s.append("late", .{ .protocol = d }) catch return;
                if (!ok) _ = refused.fetchAdd(1, .monotonic);
            }
        }
    };

    var refused = std.atomic.Value(u32).init(0);
    const t = try std.Thread.spawn(.{}, Worker.run, .{ sink, &desc, &refused });
    t.join();

    try testing.expectEqual(@as(u32, 100), refused.load(.monotonic));
    sink.assertClosedAndEmpty();
}

test "discard frees pending names" {
    var tracker = LockOrderTracker{};
    const sink = try ObligationSink.create(testing.allocator, &tracker);
    defer sink.release();

    const desc = testDescriptor();
    try testing.expect(try sink.append("pending", .{ .protocol = &desc }));
    sink.discard();
    sink.assertClosedAndEmpty();
}

test "the last release frees names still pending" {
    var tracker = LockOrderTracker{};
    const sink = try ObligationSink.create(testing.allocator, &tracker);
    sink.retain();

    const desc = testDescriptor();
    try testing.expect(try sink.append("pending", .{ .protocol = &desc }));

    sink.release();
    try testing.expectEqual(@as(u32, 1), sink.refcount.load(.monotonic));
    sink.release();
}

test "a reference held past the drain still reads closed" {
    var tracker = LockOrderTracker{};
    const sink = try ObligationSink.create(testing.allocator, &tracker);
    sink.retain();
    defer sink.release();

    sink.discard();
    sink.release();

    try testing.expect(!sink.isOpen());
}

test "concurrent appends and a drain account for every item" {
    var tracker = LockOrderTracker{};
    const sink = try ObligationSink.create(testing.allocator, &tracker);
    defer sink.release();

    const desc = testDescriptor();
    const Worker = struct {
        fn run(s: *ObligationSink, d: *const value_mod.ProtocolDescriptor, accepted: *std.atomic.Value(u32)) void {
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                const ok = s.append("name", .{ .protocol = d }) catch return;
                if (ok) _ = accepted.fetchAdd(1, .monotonic);
            }
        }
    };

    var accepted = std.atomic.Value(u32).init(0);
    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ sink, &desc, &accepted });

    var pending = sink.takeAndClose();
    for (threads) |t| t.join();

    var taken: u32 = 0;
    var cursor = pending.head;
    while (cursor) |entry| : (cursor = entry.next) taken += 1;
    pending.deinit();

    try testing.expectEqual(accepted.load(.monotonic), taken);
    sink.assertClosedAndEmpty();
}
