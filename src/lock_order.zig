const std = @import("std");

/// Lock hierarchy levels for debug assertion checking.
///
/// The ordering invariant is: a thread may only acquire a lock at a level
/// strictly greater than any lock it currently holds, with the exception of
/// same-level channel peers (address-ordered).
///
/// Level 1: Context shared_lock (RwLock) -- shared registries
/// Level 2: Channel mutex (per-channel Mutex, address-ordered among peers)
/// Level 3: tz_mutex (leaf-only Mutex in time.zig)
///
/// Atomics (Task.status, TaskScope counters) are outside the hierarchy.
pub const LockLevel = enum(u8) {
    none = 0,
    context_rw = 1,
    channel = 2,
    tz = 3,
};

/// Tracks the highest lock level currently held by a context, asserting
/// that new acquisitions respect the ordering hierarchy. Guarded by
/// `std.debug.runtime_safety` so all checks compile out in release builds.
pub const LockOrderTracker = struct {
    held_level: LockLevel = .none,
    held_count: u32 = 0,

    pub fn acquire(self: *LockOrderTracker, level: LockLevel) void {
        if (comptime @import("builtin").mode != .Debug) return;

        const new = @intFromEnum(level);
        const cur = @intFromEnum(self.held_level);

        if (self.held_count == 0) {
            // No locks held -- any level is fine.
            self.held_level = level;
            self.held_count = 1;
            return;
        }

        // Same-level re-entry is allowed for channel peers (address-ordered).
        if (new == cur and level == .channel) {
            self.held_count += 1;
            return;
        }

        if (new <= cur) {
            std.debug.panic(
                "Lock ordering violation: acquiring level {d} ({s}) while holding level {d} ({s})",
                .{ new, @tagName(level), cur, @tagName(self.held_level) },
            );
        }

        self.held_level = level;
        self.held_count += 1;
    }

    pub fn release(self: *LockOrderTracker, level: LockLevel) void {
        if (comptime @import("builtin").mode != .Debug) return;

        if (self.held_count == 0) {
            std.debug.panic("Lock order release with no locks held", .{});
        }

        const rel = @intFromEnum(level);
        const cur = @intFromEnum(self.held_level);

        if (rel != cur) {
            std.debug.panic(
                "Lock order release mismatch: releasing level {d} ({s}) but held level is {d} ({s})",
                .{ rel, @tagName(level), cur, @tagName(self.held_level) },
            );
        }

        self.held_count -= 1;
        if (self.held_count == 0) {
            self.held_level = .none;
        }
    }
};

test "ascending lock order is allowed" {
    var tracker = LockOrderTracker{};

    tracker.acquire(.context_rw);
    std.testing.expectEqual(LockLevel.context_rw, tracker.held_level) catch unreachable;
    std.testing.expectEqual(@as(u32, 1), tracker.held_count) catch unreachable;

    tracker.release(.context_rw);
    std.testing.expectEqual(LockLevel.none, tracker.held_level) catch unreachable;
    std.testing.expectEqual(@as(u32, 0), tracker.held_count) catch unreachable;

    // Now acquire at a higher level
    tracker.acquire(.channel);
    std.testing.expectEqual(LockLevel.channel, tracker.held_level) catch unreachable;

    tracker.release(.channel);
    std.testing.expectEqual(LockLevel.none, tracker.held_level) catch unreachable;
}

test "same-level channel re-entry is allowed" {
    var tracker = LockOrderTracker{};

    tracker.acquire(.channel);
    std.testing.expectEqual(@as(u32, 1), tracker.held_count) catch unreachable;

    tracker.acquire(.channel);
    std.testing.expectEqual(@as(u32, 2), tracker.held_count) catch unreachable;

    tracker.release(.channel);
    std.testing.expectEqual(@as(u32, 1), tracker.held_count) catch unreachable;
    std.testing.expectEqual(LockLevel.channel, tracker.held_level) catch unreachable;

    tracker.release(.channel);
    std.testing.expectEqual(@as(u32, 0), tracker.held_count) catch unreachable;
    std.testing.expectEqual(LockLevel.none, tracker.held_level) catch unreachable;
}

test "reset after full release" {
    var tracker = LockOrderTracker{};

    tracker.acquire(.context_rw);
    tracker.release(.context_rw);

    // After full release, can acquire any level again (even lower)
    tracker.acquire(.tz);
    tracker.release(.tz);

    tracker.acquire(.context_rw);
    tracker.release(.context_rw);

    std.testing.expectEqual(LockLevel.none, tracker.held_level) catch unreachable;
    std.testing.expectEqual(@as(u32, 0), tracker.held_count) catch unreachable;
}
