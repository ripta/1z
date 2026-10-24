const std = @import("std");

/// Lock hierarchy levels for debug assertion checking.
///
/// The ordering invariant is: a thread may only acquire a lock at a level
/// strictly greater than any lock it currently holds, with the exception of
/// same-level channel peers (address-ordered).
///
/// Level 1: Module-load lock (global, task-owned; see below)
/// Level 2: Context shared_lock (RwLock) -- shared registries
/// Level 3: Channel mutex (per-channel Mutex, address-ordered among peers)
/// Level 4: Container mutex (per-container Mutex on refcounted backings)
/// Level 5: tz_mutex (leaf-only Mutex in time.zig)
/// Level 6: analysis shadow table lock (leaf-only RwLock in analysis_shadow.zig)
///
/// Level 7: load path list mutex (leaf-only Mutex on each context)
///
/// Level 8: obligation sink lock (leaf-only Mutex on each load's obligation sink)
///
/// The load path mutex is held only around an append or a copy of the list's slice, never across a
/// filesystem probe. It sits above every other level except the obligation sink lock, so that it
/// can be taken from inside any other critical section.
///
/// The obligation sink lock is held only around a link into the sink's list or the take of that
/// list, never around an allocation or a validation. Nothing is acquired under it, so it sits above
/// every level and can be taken from inside any other critical section.
///
/// The shadow table lock is held only around a map probe or insert. It is never held while a
/// container mutex is held, because a copy is made before the lock is taken. Pops of an ancestor's
/// container take it shared from any level, including inside a container or channel critical
/// section, so it sits above them.
///
/// Channels lock the channel mutex and may call `deepCopyValue`, which
/// locks the source container's mutex while iterating; container therefore
/// sits above channel in the order.
///
/// The module-load lock sits at the bottom because a load's critical section
/// acquires and releases the context RwLock many times. Its level is declared
/// but never run through the tracker: ownership is a task identity held
/// across scheduler suspension, while the tracker's state is threadlocal per
/// worker, so another task running on the holder's worker between suspend and
/// resume would observe bogus held state.
///
/// Atomics (Task.status, TaskScope counters) are outside the hierarchy.
pub const LockLevel = enum(u8) {
    none = 0,
    module_load = 1,
    context_rw = 2,
    channel = 3,
    container = 4,
    tz = 5,
    shadow_table = 6,
    load_paths = 7,
    obligation_sink = 8,
};

/// One run of held locks at a single level. Only channel peers repeat a level, so a select over
/// any number of channels is one run.
const HeldRun = struct {
    level: LockLevel,
    count: u32,
};

/// Deepest run stack the tracker records. Levels ascend strictly across runs, so the depth is
/// bounded by the number of levels and not by how many peers one run holds.
const max_runs = @typeInfo(LockLevel).@"enum".fields.len;

// Per-thread lock-ordering state. Each OS thread keeps its own stack of held runs so
// multi-threaded schedulers can run concurrent locks without false-positive ordering violations.
//
// `held_level` mirrors the top run, and `held_count` totals every lock held. Releasing a nested
// lock restores the level of the lock still held beneath it.
threadlocal var held_runs: [max_runs]HeldRun = undefined;
threadlocal var held_run_count: u32 = 0;
threadlocal var held_level: LockLevel = .none;
threadlocal var held_count: u32 = 0;

/// Tracks the highest lock level currently held by *this thread*,
/// asserting that new acquisitions respect the ordering hierarchy.
/// Guarded by `std.debug.runtime_safety` so all checks compile out in
/// release builds. The struct holds no per-instance state; it is a
/// stable handle so contexts can share a single `*LockOrderTracker`
/// pointer across tasks while each thread checks its own state.
pub const LockOrderTracker = struct {
    pub fn acquire(_: *LockOrderTracker, level: LockLevel) void {
        if (comptime @import("builtin").mode != .Debug) return;

        const new = @intFromEnum(level);
        const cur = @intFromEnum(held_level);

        if (held_count > 0) {
            // Same-level re-entry is allowed for channel peers (address-ordered).
            const peer = new == cur and level == .channel;

            if (new <= cur and !peer) {
                std.debug.panic(
                    "Lock ordering violation: acquiring level {d} ({s}) while holding level {d} ({s})",
                    .{ new, @tagName(level), cur, @tagName(held_level) },
                );
            }
        }

        if (held_count > 0 and new == cur) {
            held_runs[held_run_count - 1].count += 1;
        } else {
            std.debug.assert(held_run_count < max_runs);
            held_runs[held_run_count] = .{ .level = level, .count = 1 };
            held_run_count += 1;
        }

        held_count += 1;
        held_level = level;
    }

    pub fn release(_: *LockOrderTracker, level: LockLevel) void {
        if (comptime @import("builtin").mode != .Debug) return;

        if (held_count == 0) {
            std.debug.panic("Lock order release with no locks held", .{});
        }

        const rel = @intFromEnum(level);
        const cur = @intFromEnum(held_level);

        if (rel != cur) {
            std.debug.panic(
                "Lock order release mismatch: releasing level {d} ({s}) but held level is {d} ({s})",
                .{ rel, @tagName(level), cur, @tagName(held_level) },
            );
        }

        held_count -= 1;

        const top = &held_runs[held_run_count - 1];
        top.count -= 1;
        if (top.count == 0) {
            held_run_count -= 1;
            held_level = if (held_run_count == 0) .none else held_runs[held_run_count - 1].level;
        }
    }
};

test "ascending lock order is allowed" {
    var tracker = LockOrderTracker{};

    tracker.acquire(.context_rw);
    std.testing.expectEqual(LockLevel.context_rw, held_level) catch unreachable;
    std.testing.expectEqual(@as(u32, 1), held_count) catch unreachable;

    tracker.release(.context_rw);
    std.testing.expectEqual(LockLevel.none, held_level) catch unreachable;
    std.testing.expectEqual(@as(u32, 0), held_count) catch unreachable;

    // Now acquire at a higher level
    tracker.acquire(.channel);
    std.testing.expectEqual(LockLevel.channel, held_level) catch unreachable;

    tracker.release(.channel);
    std.testing.expectEqual(LockLevel.none, held_level) catch unreachable;
}

test "same-level channel re-entry is allowed" {
    var tracker = LockOrderTracker{};

    tracker.acquire(.channel);
    std.testing.expectEqual(@as(u32, 1), held_count) catch unreachable;

    tracker.acquire(.channel);
    std.testing.expectEqual(@as(u32, 2), held_count) catch unreachable;

    tracker.release(.channel);
    std.testing.expectEqual(@as(u32, 1), held_count) catch unreachable;
    std.testing.expectEqual(LockLevel.channel, held_level) catch unreachable;

    tracker.release(.channel);
    std.testing.expectEqual(@as(u32, 0), held_count) catch unreachable;
    std.testing.expectEqual(LockLevel.none, held_level) catch unreachable;
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

    std.testing.expectEqual(LockLevel.none, held_level) catch unreachable;
    std.testing.expectEqual(@as(u32, 0), held_count) catch unreachable;
}

test "releasing a nested lock restores the outer level" {
    var tracker = LockOrderTracker{};

    tracker.acquire(.context_rw);
    tracker.acquire(.load_paths);
    std.testing.expectEqual(LockLevel.load_paths, held_level) catch unreachable;

    tracker.release(.load_paths);
    std.testing.expectEqual(LockLevel.context_rw, held_level) catch unreachable;
    std.testing.expectEqual(@as(u32, 1), held_count) catch unreachable;

    tracker.release(.context_rw);
    std.testing.expectEqual(LockLevel.none, held_level) catch unreachable;
    std.testing.expectEqual(@as(u32, 0), held_count) catch unreachable;
}

test "a three-deep nest unwinds one level at a time" {
    var tracker = LockOrderTracker{};

    tracker.acquire(.channel);
    tracker.acquire(.container);
    tracker.acquire(.obligation_sink);

    tracker.release(.obligation_sink);
    std.testing.expectEqual(LockLevel.container, held_level) catch unreachable;

    tracker.release(.container);
    std.testing.expectEqual(LockLevel.channel, held_level) catch unreachable;

    tracker.release(.channel);
    std.testing.expectEqual(LockLevel.none, held_level) catch unreachable;
}

test "many channel peers form one run and unwind cleanly" {
    var tracker = LockOrderTracker{};

    tracker.acquire(.context_rw);
    for (0..200) |_| tracker.acquire(.channel);
    tracker.acquire(.container);
    std.testing.expectEqual(@as(u32, 202), held_count) catch unreachable;

    tracker.release(.container);
    std.testing.expectEqual(LockLevel.channel, held_level) catch unreachable;

    for (0..200) |_| tracker.release(.channel);
    std.testing.expectEqual(LockLevel.context_rw, held_level) catch unreachable;

    tracker.release(.context_rw);
    std.testing.expectEqual(@as(u32, 0), held_count) catch unreachable;
    std.testing.expectEqual(@as(u32, 0), held_run_count) catch unreachable;
}

test "channel peers nested under a lower lock unwind in order" {
    var tracker = LockOrderTracker{};

    tracker.acquire(.context_rw);
    tracker.acquire(.channel);
    tracker.acquire(.channel);
    tracker.acquire(.obligation_sink);

    tracker.release(.obligation_sink);
    tracker.release(.channel);
    std.testing.expectEqual(LockLevel.channel, held_level) catch unreachable;

    tracker.release(.channel);
    std.testing.expectEqual(LockLevel.context_rw, held_level) catch unreachable;

    tracker.release(.context_rw);
    std.testing.expectEqual(@as(u32, 0), held_count) catch unreachable;
}
