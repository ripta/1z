const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Task = @import("task.zig").Task;

/// Process-wide lock serializing module loads, so only one load at a time writes the root
/// arena and registries a load targets.
///
/// Ownership is a task identity, with a sentinel for the non-task main thread. The lock is
/// reentrant, since a nested `use` recurses into the load natives on the same task.
///
/// The hold spans scheduler suspension by design: a load can park mid-way, and a plain
/// thread mutex would deadlock because tasks are pinned to a home worker. A contending task
/// is therefore queued here and suspended through the scheduler; a release hands ownership
/// to the first queued waiter directly, and the caller wakes it via `wakeTask`.
///
/// A hold can also be delegated: an owner that transitively awaits a contender is provably
/// parked until that contender finishes, so the contender borrows the hold and `release`
/// restores the suspended hold, LIFO through nested borrows, when the borrow ends.
///
/// This struct is the state machine only. The suspend, wake, and cancellation orchestration,
/// and the wait-chain walk deciding delegation, live with the load natives, mirroring the
/// channel/`channels.zig` split. The internal `mu` guards short critical sections, is never
/// held across suspension, and sits outside the `LockOrderTracker` hierarchy like the
/// scheduler queue mutexes.
pub const LoadLock = struct {
    mu: std.Thread.Mutex = .{},
    owner: ?Owner = null,
    depth: u32 = 0,
    waiters: std.ArrayListUnmanaged(*Task) = .{},
    /// Holds delegated away to a borrower, restored LIFO as each borrow releases. A hold is
    /// delegated only to a task its owner transitively awaits, so the owner is provably
    /// suspended for the borrow's whole duration; see `delegate`.
    suspended_holds: std.ArrayListUnmanaged(Hold) = .{},
    main_waiting: bool = false,
    main_cond: std.Thread.Condition = .{},
    allocator: Allocator,

    const Hold = struct {
        owner: Owner,
        depth: u32,
    };

    pub const ReleaseResult = union(enum) {
        /// Still held at a shallower depth, or freed with nobody to serve.
        none,
        /// Ownership was handed to this waiter; the caller wakes it outside the lock.
        wake: *Task,
        /// A suspended hold was restored. Its owner is still parked and resumes through
        /// whatever it awaits, but a queued waiter it transitively awaits can never be served
        /// by its release, so the caller re-evaluates the queue via `delegateToAwaitedWaiter`.
        restored: Owner,
    };

    pub const Owner = union(enum) {
        task: *Task,
        main,

        fn eql(a: Owner, b: Owner) bool {
            return switch (a) {
                .task => |t| b == .task and b.task == t,
                .main => b == .main,
            };
        }
    };

    pub fn create(allocator: Allocator) !*LoadLock {
        const lock = try allocator.create(LoadLock);
        lock.* = .{ .allocator = allocator };
        return lock;
    }

    pub fn destroy(self: *LoadLock) void {
        self.waiters.deinit(self.allocator);
        self.suspended_holds.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Take the lock or deepen a reentrant hold, returning null. Otherwise return the
    /// current holder without queueing, so the caller can decide whether parking on it is
    /// safe at all before committing to a wait.
    pub fn tryAcquireOrHolder(self: *LoadLock, owner: Owner) ?Owner {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.owner) |cur| {
            if (!cur.eql(owner)) return cur;
            self.depth += 1;
            return null;
        }
        self.owner = owner;
        self.depth = 1;
        return null;
    }

    /// Delegate the hold to `borrower`, but only while `expected` still holds the lock: the
    /// current hold is pushed onto the suspended stack and the borrower becomes the owner at
    /// depth 1. `release` restores the pushed hold when the borrow ends.
    ///
    /// The caller must have proven the current owner cannot resume until the borrower
    /// finishes, which is what keeps the borrow exclusive. A false return means ownership
    /// changed since the caller inspected it; the caller retries from the inspection.
    pub fn delegate(self: *LoadLock, expected: Owner, borrower: Owner) !bool {
        self.mu.lock();
        defer self.mu.unlock();
        const cur = self.owner orelse return false;
        if (!cur.eql(expected)) return false;
        try self.suspended_holds.append(self.allocator, .{ .owner = cur, .depth = self.depth });
        self.owner = borrower;
        self.depth = 1;
        return true;
    }

    /// Queue `task` as a waiter, but only while `expected` still holds the lock. A false
    /// return means ownership changed since the caller inspected it; the caller retries from
    /// the inspection. The held-check and the enqueue share one critical section, so a
    /// release cannot slip between them and leave the task parked on a free lock.
    pub fn enqueueIfHeldBy(self: *LoadLock, expected: Owner, task: *Task) !bool {
        self.mu.lock();
        defer self.mu.unlock();
        const cur = self.owner orelse return false;
        if (!cur.eql(expected)) return false;
        try self.waiters.append(self.allocator, task);
        return true;
    }

    /// Blocking acquire for the non-task main thread, which has no scheduler to park in.
    /// Blocking the OS thread is fine there: main runs no 1z code concurrently with tasks,
    /// so this path is defensive and effectively uncontended.
    pub fn acquireMain(self: *LoadLock) void {
        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            if (self.owner) |cur| {
                if (cur.eql(.main)) {
                    self.depth += 1;
                    self.main_waiting = false;
                    return;
                }
            } else {
                self.owner = .main;
                self.depth = 1;
                self.main_waiting = false;
                return;
            }
            self.main_waiting = true;
            if (builtin.single_threaded) {
                // No other thread exists to release the hold, and the single-threaded
                // Condition stub's wait needs a nanosleep the freestanding wasm target lacks.
                @panic("load lock contended with no other thread to release it");
            } else {
                self.main_cond.wait(&self.mu);
            }
        }
    }

    /// Release one level of the hold. At depth zero the ended borrow's suspended hold is
    /// restored first; otherwise ownership goes to the first queued waiter (FIFO); with
    /// neither, the lock frees and a waiting main thread is signalled.
    pub fn release(self: *LoadLock, owner: Owner) ReleaseResult {
        self.mu.lock();
        defer self.mu.unlock();
        // A silent wrap here would pin the lock forever, so fail loudly in every build mode.
        if (self.owner == null or !self.owner.?.eql(owner) or self.depth == 0) {
            @panic("load lock released by a non-owner");
        }
        self.depth -= 1;
        if (self.depth > 0) return .none;
        if (self.suspended_holds.items.len > 0) {
            const restored = self.suspended_holds.pop().?;
            self.owner = restored.owner;
            self.depth = restored.depth;
            return .{ .restored = restored.owner };
        }
        if (self.waiters.items.len > 0) {
            const next = self.waiters.orderedRemove(0);
            self.owner = .{ .task = next };
            self.depth = 1;
            return .{ .wake = next };
        }
        self.owner = null;
        if (self.main_waiting) self.main_cond.signal();
        return .none;
    }

    /// After a restore, delegate the hold onward to the first queued waiter the restored
    /// owner transitively awaits, per the caller's `awaits` predicate, and return it for the
    /// caller to wake. Such a waiter can never be served by the restored owner's release,
    /// since that owner is parked until the waiter finishes.
    ///
    /// Null when the queue holds no awaited waiter, or when ownership moved on since the
    /// restore; a later release re-evaluates then.
    pub fn delegateToAwaitedWaiter(
        self: *LoadLock,
        restored: Owner,
        awaits: *const fn (Owner, *Task) bool,
    ) !?*Task {
        self.mu.lock();
        defer self.mu.unlock();
        const cur = self.owner orelse return null;
        if (!cur.eql(restored)) return null;
        for (self.waiters.items, 0..) |waiter, i| {
            if (awaits(restored, waiter)) {
                _ = self.waiters.orderedRemove(i);
                try self.suspended_holds.append(self.allocator, .{ .owner = cur, .depth = self.depth });
                self.owner = .{ .task = waiter };
                self.depth = 1;
                return waiter;
            }
        }
        return null;
    }

    /// Remove a cancelled task from the waiter queue, clearing its blocked marker. Callers
    /// gate re-enqueue on the result: a false return means a release already handed the task
    /// ownership and woke it, so re-enqueuing would resume a coroutine that is no longer
    /// suspended.
    pub fn removeWaiter(self: *LoadLock, task: *Task) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var removed = false;
        var i: usize = 0;
        while (i < self.waiters.items.len) {
            if (self.waiters.items[i] == task) {
                _ = self.waiters.orderedRemove(i);
                removed = true;
            } else {
                i += 1;
            }
        }
        task.blocked_on_load_lock = null;
        return removed;
    }

    /// Whether `owner` currently holds the lock. The resume path uses this to distinguish a
    /// handoff from a cancellation wake.
    pub fn isHeldBy(self: *LoadLock, owner: Owner) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.owner != null and self.owner.?.eql(owner);
    }
};

fn testTask() Task {
    var t: Task = undefined;
    t.blocked_on_load_lock = null;
    return t;
}

test "a free lock acquires immediately and reentrantly" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    var t = testTask();
    const owner: LoadLock.Owner = .{ .task = &t };

    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(owner));
    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(owner));
    try std.testing.expectEqual(@as(u32, 2), lock.depth);

    try std.testing.expectEqual(LoadLock.ReleaseResult.none, lock.release(owner));
    try std.testing.expect(lock.isHeldBy(owner));
    try std.testing.expectEqual(LoadLock.ReleaseResult.none, lock.release(owner));
    try std.testing.expect(!lock.isHeldBy(owner));
}

test "a contended inspection reports the holder without queueing" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    var holder = testTask();
    var other = testTask();

    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(.{ .task = &holder }));

    const seen = lock.tryAcquireOrHolder(.{ .task = &other }).?;
    try std.testing.expect(seen.eql(.{ .task = &holder }));
    try std.testing.expectEqual(@as(usize, 0), lock.waiters.items.len);
}

test "enqueueIfHeldBy refuses when ownership changed since the inspection" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    var holder = testTask();
    var waiter = testTask();
    const holder_owner: LoadLock.Owner = .{ .task = &holder };

    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(holder_owner));
    _ = lock.release(holder_owner);

    // The lock freed between the inspection and the enqueue: refuse, never park.
    try std.testing.expect(!try lock.enqueueIfHeldBy(holder_owner, &waiter));
    try std.testing.expectEqual(@as(usize, 0), lock.waiters.items.len);
}

test "main acquires reentrantly alongside the task path" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    lock.acquireMain();
    lock.acquireMain();
    try std.testing.expectEqual(@as(u32, 2), lock.depth);
    try std.testing.expect(lock.isHeldBy(.main));

    _ = lock.release(.main);
    _ = lock.release(.main);
    try std.testing.expect(!lock.isHeldBy(.main));
}

test "release hands off to queued waiters in FIFO order" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    var holder = testTask();
    var w1 = testTask();
    var w2 = testTask();
    const holder_owner: LoadLock.Owner = .{ .task = &holder };

    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(holder_owner));
    try std.testing.expect(try lock.enqueueIfHeldBy(holder_owner, &w1));
    try std.testing.expect(try lock.enqueueIfHeldBy(holder_owner, &w2));

    try std.testing.expectEqual(&w1, lock.release(holder_owner).wake);
    try std.testing.expect(lock.isHeldBy(.{ .task = &w1 }));

    try std.testing.expectEqual(&w2, lock.release(.{ .task = &w1 }).wake);
    try std.testing.expect(lock.isHeldBy(.{ .task = &w2 }));

    try std.testing.expectEqual(LoadLock.ReleaseResult.none, lock.release(.{ .task = &w2 }));
}

test "a delegated hold restores LIFO through nested borrows" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    var a = testTask();
    var c = testTask();
    var d = testTask();
    const a_owner: LoadLock.Owner = .{ .task = &a };
    const c_owner: LoadLock.Owner = .{ .task = &c };
    const d_owner: LoadLock.Owner = .{ .task = &d };

    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(a_owner));
    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(a_owner));

    try std.testing.expect(try lock.delegate(a_owner, c_owner));
    try std.testing.expect(lock.isHeldBy(c_owner));

    try std.testing.expect(try lock.delegate(c_owner, d_owner));
    try std.testing.expect(lock.isHeldBy(d_owner));

    try std.testing.expectEqual(LoadLock.ReleaseResult{ .restored = c_owner }, lock.release(d_owner));
    try std.testing.expect(lock.isHeldBy(c_owner));

    try std.testing.expectEqual(LoadLock.ReleaseResult{ .restored = a_owner }, lock.release(c_owner));
    try std.testing.expect(lock.isHeldBy(a_owner));
    try std.testing.expectEqual(@as(u32, 2), lock.depth);
}

test "delegate refuses when ownership changed since the inspection" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    var a = testTask();
    var c = testTask();
    const a_owner: LoadLock.Owner = .{ .task = &a };

    try std.testing.expect(!try lock.delegate(a_owner, .{ .task = &c }));

    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(a_owner));
    _ = lock.release(a_owner);
    try std.testing.expect(!try lock.delegate(a_owner, .{ .task = &c }));
}

test "a restored hold outranks queued waiters" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    var a = testTask();
    var c = testTask();
    var w = testTask();
    const a_owner: LoadLock.Owner = .{ .task = &a };
    const c_owner: LoadLock.Owner = .{ .task = &c };

    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(a_owner));
    try std.testing.expect(try lock.delegate(a_owner, c_owner));
    try std.testing.expect(try lock.enqueueIfHeldBy(c_owner, &w));

    // The borrow ends: ownership reverts to the suspended hold, not the waiter.
    try std.testing.expectEqual(LoadLock.ReleaseResult{ .restored = a_owner }, lock.release(c_owner));
    try std.testing.expect(lock.isHeldBy(a_owner));

    // The original hold's release serves the waiter normally.
    try std.testing.expectEqual(&w, lock.release(a_owner).wake);
}

fn awaitsAll(_: LoadLock.Owner, _: *Task) bool {
    return true;
}

fn awaitsNone(_: LoadLock.Owner, _: *Task) bool {
    return false;
}

test "a restore delegates onward to an awaited waiter" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    var a = testTask();
    var b = testTask();
    var c = testTask();
    const a_owner: LoadLock.Owner = .{ .task = &a };
    const b_owner: LoadLock.Owner = .{ .task = &b };

    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(a_owner));
    try std.testing.expect(try lock.delegate(a_owner, b_owner));
    try std.testing.expect(try lock.enqueueIfHeldBy(b_owner, &c));

    try std.testing.expectEqual(LoadLock.ReleaseResult{ .restored = a_owner }, lock.release(b_owner));

    // A waiter the restored owner does not await stays queued.
    try std.testing.expectEqual(@as(?*Task, null), try lock.delegateToAwaitedWaiter(a_owner, awaitsNone));
    try std.testing.expect(lock.isHeldBy(a_owner));

    // An awaited waiter borrows the restored hold and unwinds back to it.
    try std.testing.expectEqual(&c, (try lock.delegateToAwaitedWaiter(a_owner, awaitsAll)).?);
    try std.testing.expect(lock.isHeldBy(.{ .task = &c }));
    try std.testing.expectEqual(LoadLock.ReleaseResult{ .restored = a_owner }, lock.release(.{ .task = &c }));
    try std.testing.expectEqual(LoadLock.ReleaseResult.none, lock.release(a_owner));
}

test "removeWaiter is idempotent against a completed handoff" {
    const lock = try LoadLock.create(std.testing.allocator);
    defer lock.destroy();

    var holder = testTask();
    var waiter = testTask();
    const holder_owner: LoadLock.Owner = .{ .task = &holder };

    try std.testing.expectEqual(@as(?LoadLock.Owner, null), lock.tryAcquireOrHolder(holder_owner));
    try std.testing.expect(try lock.enqueueIfHeldBy(holder_owner, &waiter));

    // Still queued: the removal succeeds and gates a re-enqueue.
    try std.testing.expect(lock.removeWaiter(&waiter));
    try std.testing.expect(!lock.removeWaiter(&waiter));

    // Handed off before the cancel arrived: no longer queued, so no re-enqueue.
    try std.testing.expect(try lock.enqueueIfHeldBy(holder_owner, &waiter));
    try std.testing.expectEqual(&waiter, lock.release(holder_owner).wake);
    try std.testing.expect(!lock.removeWaiter(&waiter));
    try std.testing.expect(lock.isHeldBy(.{ .task = &waiter }));
}
