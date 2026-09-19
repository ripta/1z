const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Closure = value_mod.Closure;
const Quotation = value_mod.Quotation;
const Value = value_mod.Value;

const task_mod = @import("task.zig");
const Task = task_mod.Task;

/// The compute-once state of a `once`-marked word, allocated alongside its definition and read
/// by the two-instruction body `;` installs in place of the source body.
///
/// The cell lives on the arena a module load redirects to, so its lifetime is the root
/// context's and a `reload` builds a new one. `value` is an owning reference the dictionary's
/// teardown releases.
///
/// This struct is the state machine only. The suspend, wake, and cancellation orchestration
/// lives with the `once` natives, mirroring the channel/`channels.zig` and
/// load-lock/`misc.zig` splits.
pub const OnceCell = struct {
    /// The source body, moved here so the stored body can be the guard instead.
    body: Quotation,

    /// The closure `body` came out of, for a body it owns. Borrowed on the same terms as
    /// `Parameter.default_owner`: it carries the body's captured scope and defining module to
    /// each attempt to force. Null for a plain quotation body.
    owner: ?*const Closure = null,

    /// Whether `body` calls a defining native at its top level, so forcing runs it in a
    /// transient lexical frame. Computed from the source body, since the stored body's own
    /// `may_define` describes the guard rather than what the guard runs.
    may_define: bool = false,

    /// The word's own name, for the cycle diagnostic. Duped onto the cell's own arena.
    name: []const u8 = "",

    /// Read without the mutex on every reference, so a hit costs a load and a branch. The
    /// release-store that publishes pairs with the acquire-load that reads it, which is what
    /// makes `value` visible to a reader that never takes `mu`.
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.cold),

    /// Published on a successful force, and null while the cell is cold. A body that throws or
    /// leaves other than one value leaves the cell cold, so the next call runs it again.
    ///
    /// Written before the release-store to `.forced` and never written again, so a reader that
    /// saw `.forced` may read it without the mutex.
    value: ?Value = null,

    /// Guards `state`'s slow-path transitions, `waiters`, `forcing_task`, and `forcing_parent`.
    ///
    /// The mutex is a leaf: nothing that locks is called while it is held, and the body runs
    /// only after it is released. It sits outside the `LockOrderTracker` hierarchy on the same
    /// terms `LoadLock.mu` and the `reified_decode_cache` mutexes do, which is the accepted
    /// shape for a leaf that carries a prose ordering note instead of a declared level.
    mu: std.Thread.Mutex = .{},

    /// Readers parked until the force publishes or fails. Each entry lives on its own reader's
    /// native stack, the way a `select` waiter's `SelectContext` does, so a failure can be
    /// stamped per waiter with no allocation.
    waiters: std.ArrayListUnmanaged(*Waiter) = .{},

    /// Valid only while `state` is `.forcing`: the task running the body, or null when no task
    /// is, which `task_mod.resumed_task` answers.
    ///
    /// A `?*Task` needs no separate main sentinel, because the one thread that runs 1z code
    /// outside a task is main. A second host thread calling in through the C embedding API
    /// would present as that same identity, which is the exposure `LoadLock`'s `.main` already
    /// accepts: one handle across two host threads is out of contract.
    forcing_task: ?*Task = null,

    /// The cell the same execution was already forcing when this force began, so a cycle can
    /// name the whole chain rather than only its two ends.
    forcing_parent: ?*OnceCell = null,

    /// For `waiters`. Cross-worker, so never an arena: a reader on any worker appends here.
    allocator: Allocator,

    /// Explicitly `u8`, because `std.atomic.Value` needs an extern-compatible payload and the
    /// default tag type for three variants is `u2`.
    pub const State = enum(u8) { cold, forcing, forced };

    /// A parked reader's slot, on that reader's own native stack.
    ///
    /// A failing force stamps the error it raised into every waiter before waking it. The
    /// strings are inline, so the failure path allocates nothing and there is no cross-thread
    /// ownership to unwind. Anything longer than its buffer is truncated with a trailing
    /// ellipsis, as the scheduler's task dump truncates a failed task's error.
    pub const Waiter = struct {
        task: *Task,
        failed: bool = false,
        type_buf: [64]u8 = undefined,
        type_len: usize = 0,
        msg_buf: [192]u8 = undefined,
        msg_len: usize = 0,

        pub fn errorType(self: *const Waiter) []const u8 {
            return self.type_buf[0..self.type_len];
        }

        pub fn message(self: *const Waiter) []const u8 {
            return self.msg_buf[0..self.msg_len];
        }

        /// Record `error_type` and `message` as this waiter's failure, truncating each to its
        /// buffer.
        pub fn stamp(self: *Waiter, error_type: []const u8, message_text: []const u8) void {
            self.type_len = copyTruncated(&self.type_buf, error_type);
            self.msg_len = copyTruncated(&self.msg_buf, message_text);
            self.failed = true;
        }
    };

    /// What a reader must do, decided in one critical section so a publish cannot slip between
    /// reading the state and acting on it.
    pub const Arrival = enum {
        /// The value is published; read it without the mutex.
        forced,
        /// This reader now owns the force and must run the body.
        begun,
        /// This execution is already forcing this cell, so the body depends on itself.
        cycle,
        /// Another execution is forcing; this reader must park.
        wait,
    };

    /// Claim the force, or report what the caller must do instead.
    ///
    /// `task` is the caller's execution identity: the task this OS thread is resumed into, or
    /// null for the non-task main thread. `parent` is the cell that identity was already
    /// forcing, recorded so a cycle can be spelled out.
    pub fn arrive(self: *OnceCell, task: ?*Task, parent: ?*OnceCell) Arrival {
        self.mu.lock();
        defer self.mu.unlock();
        switch (self.state.load(.acquire)) {
            .forced => return .forced,
            .forcing => return if (self.forcing_task == task) .cycle else .wait,
            .cold => {
                self.state.store(.forcing, .monotonic);
                self.forcing_task = task;
                self.forcing_parent = parent;
                return .begun;
            },
        }
    }

    /// Queue `waiter`, but only while the cell is still `forcing`.
    ///
    /// A false return means the state moved on since `arrive` reported `.wait`, and the caller
    /// arrives again.
    ///
    /// The state check and the append share one critical section, so a publish cannot slip
    /// between them and leave the reader parked on a settled cell.
    pub fn enqueueIfForcing(self: *OnceCell, waiter: *Waiter) !bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.state.load(.acquire) != .forcing) return false;
        try self.waiters.append(self.allocator, waiter);
        return true;
    }

    /// Publish `val` and hand back the waiters for the caller to wake outside the mutex.
    ///
    /// `val` must already carry the cell's own owning reference. The returned list is the
    /// caller's to `deinit`.
    pub fn publish(self: *OnceCell, val: Value) std.ArrayListUnmanaged(*Waiter) {
        self.mu.lock();
        defer self.mu.unlock();
        self.value = val;
        self.state.store(.forced, .release);
        self.forcing_task = null;
        self.forcing_parent = null;
        return self.drainLocked();
    }

    /// Return the cell to cold and hand back the waiters, which the caller stamps and wakes.
    ///
    /// Nothing but the caller can wake a drained waiter, so stamping after the mutex is
    /// released is safe and keeps the allocation-free copy out of the critical section.
    pub fn fail(self: *OnceCell) std.ArrayListUnmanaged(*Waiter) {
        self.mu.lock();
        defer self.mu.unlock();
        self.state.store(.cold, .release);
        self.forcing_task = null;
        self.forcing_parent = null;
        return self.drainLocked();
    }

    fn drainLocked(self: *OnceCell) std.ArrayListUnmanaged(*Waiter) {
        const drained = self.waiters;
        self.waiters = .{};
        return drained;
    }

    /// Put a drained waiter back after its wake was dropped.
    ///
    /// A drained entry is reachable from nowhere else, so without this the task would stay
    /// suspended with no route back to a run queue. Listed again, a cancellation's
    /// `removeWaiter` reports it as still parked and reroutes it.
    ///
    /// Best effort: the append can fail for the same reason the wake did, and the task then
    /// keeps its blocked marker, which is what the deadlock gate reads.
    pub fn requeueWaiter(self: *OnceCell, waiter: *Waiter) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.waiters.append(self.allocator, waiter) catch {};
    }

    /// Remove a cancelled task's waiter entry, clearing its blocked marker.
    ///
    /// Callers gate re-enqueue on the result. A false return means a publish or a failure
    /// already drained the entry and woke the task, so re-enqueuing would resume a coroutine
    /// that is no longer suspended.
    pub fn removeWaiter(self: *OnceCell, task: *Task) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var removed = false;
        var i: usize = 0;
        while (i < self.waiters.items.len) {
            if (self.waiters.items[i].task == task) {
                _ = self.waiters.orderedRemove(i);
                removed = true;
            } else {
                i += 1;
            }
        }
        task.blocked_on_once_cell = null;
        return removed;
    }

    /// Release the waiter list's backing. The cell itself belongs to an arena and is not freed.
    pub fn deinit(self: *OnceCell) void {
        self.waiters.deinit(self.allocator);
    }
};

/// Copy as much of `src` into `dst` as fits, ending a truncated copy with an ellipsis, and
/// return how many bytes were written.
fn copyTruncated(dst: []u8, src: []const u8) usize {
    if (src.len <= dst.len) {
        @memcpy(dst[0..src.len], src);
        return src.len;
    }
    const ellipsis = "...";
    const keep = dst.len - ellipsis.len;
    @memcpy(dst[0..keep], src[0..keep]);
    @memcpy(dst[keep..dst.len], ellipsis);
    return dst.len;
}

const testing = std.testing;

fn testCell() OnceCell {
    return .{ .body = .{ .instructions = &.{} }, .allocator = testing.allocator };
}

fn testTask() Task {
    var t: Task = undefined;
    t.blocked_on_once_cell = null;
    return t;
}

test "a cold cell hands the force to its first arrival" {
    var cell = testCell();
    defer cell.deinit();

    var t = testTask();
    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&t, null));
    try testing.expectEqual(OnceCell.State.forcing, cell.state.load(.acquire));
    try testing.expectEqual(@as(?*Task, &t), cell.forcing_task);
}

test "a forcing cell tells a re-entry from a contender by execution identity" {
    var cell = testCell();
    defer cell.deinit();

    var holder = testTask();
    var other = testTask();

    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&holder, null));
    try testing.expectEqual(OnceCell.Arrival.cycle, cell.arrive(&holder, null));
    try testing.expectEqual(OnceCell.Arrival.wait, cell.arrive(&other, null));

    // The non-task main thread is its own identity, so it neither collides with a task nor
    // needs a sentinel of its own.
    try testing.expectEqual(OnceCell.Arrival.wait, cell.arrive(null, null));
}

test "the main thread's own force reads as a cycle on re-entry" {
    var cell = testCell();
    defer cell.deinit();

    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(null, null));
    try testing.expectEqual(OnceCell.Arrival.cycle, cell.arrive(null, null));
}

test "a forced cell answers every arrival from the cache" {
    var cell = testCell();
    defer cell.deinit();

    var t = testTask();
    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&t, null));
    var woken = cell.publish(.{ .fixnum = 7 });
    woken.deinit(testing.allocator);

    try testing.expectEqual(OnceCell.Arrival.forced, cell.arrive(&t, null));
    try testing.expectEqual(OnceCell.Arrival.forced, cell.arrive(null, null));
    try testing.expectEqual(@as(i64, 7), cell.value.?.fixnum);
    try testing.expectEqual(@as(?*Task, null), cell.forcing_task);
}

test "enqueueIfForcing refuses once the force has settled" {
    var cell = testCell();
    defer cell.deinit();

    var holder = testTask();
    var contender = testTask();
    var waiter = OnceCell.Waiter{ .task = &contender };

    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&holder, null));
    var woken = cell.publish(.{ .fixnum = 1 });
    woken.deinit(testing.allocator);

    // The force published between the arrival and the enqueue: refuse, never park.
    try testing.expect(!try cell.enqueueIfForcing(&waiter));
    try testing.expectEqual(@as(usize, 0), cell.waiters.items.len);
}

test "a publish drains every waiter and leaves none stamped" {
    var cell = testCell();
    defer cell.deinit();

    var holder = testTask();
    var a = testTask();
    var b = testTask();
    var wa = OnceCell.Waiter{ .task = &a };
    var wb = OnceCell.Waiter{ .task = &b };

    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&holder, null));
    try testing.expect(try cell.enqueueIfForcing(&wa));
    try testing.expect(try cell.enqueueIfForcing(&wb));

    var woken = cell.publish(.{ .fixnum = 42 });
    defer woken.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), woken.items.len);
    try testing.expectEqual(@as(usize, 0), cell.waiters.items.len);
    try testing.expect(!wa.failed);
    try testing.expect(!wb.failed);
}

test "a failure returns the cell to cold and its waiters take the stamp" {
    var cell = testCell();
    defer cell.deinit();

    var holder = testTask();
    var a = testTask();
    var wa = OnceCell.Waiter{ .task = &a };

    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&holder, null));
    try testing.expect(try cell.enqueueIfForcing(&wa));

    var woken = cell.fail();
    defer woken.deinit(testing.allocator);

    try testing.expectEqual(OnceCell.State.cold, cell.state.load(.acquire));
    try testing.expect(cell.value == null);
    try testing.expectEqual(@as(usize, 1), woken.items.len);

    woken.items[0].stamp("user-thrown", "not ready");
    try testing.expect(wa.failed);
    try testing.expectEqualStrings("user-thrown", wa.errorType());
    try testing.expectEqualStrings("not ready", wa.message());

    // Cold again, so the next arrival runs the body rather than parking on a dead force.
    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&holder, null));
}

test "a stamp longer than its buffer is truncated with an ellipsis" {
    var t = testTask();
    var waiter = OnceCell.Waiter{ .task = &t };

    const long = "x" ** 300;
    waiter.stamp(long, long);

    try testing.expectEqual(@as(usize, 64), waiter.errorType().len);
    try testing.expectEqual(@as(usize, 192), waiter.message().len);
    try testing.expect(std.mem.endsWith(u8, waiter.errorType(), "..."));
    try testing.expect(std.mem.endsWith(u8, waiter.message(), "..."));
}

test "a requeued waiter is discoverable again after its wake was dropped" {
    var cell = testCell();
    defer cell.deinit();

    var holder = testTask();
    var contender = testTask();
    var waiter = OnceCell.Waiter{ .task = &contender };

    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&holder, null));
    try testing.expect(try cell.enqueueIfForcing(&waiter));

    var woken = cell.publish(.{ .fixnum = 1 });
    woken.deinit(testing.allocator);

    // Drained, so a cancellation would find nothing to reroute and the task would never run.
    try testing.expect(!cell.removeWaiter(&contender));

    cell.requeueWaiter(&waiter);
    try testing.expect(cell.removeWaiter(&contender));
}

test "removeWaiter is idempotent against a completed drain" {
    var cell = testCell();
    defer cell.deinit();

    var holder = testTask();
    var contender = testTask();
    var waiter = OnceCell.Waiter{ .task = &contender };

    try testing.expectEqual(OnceCell.Arrival.begun, cell.arrive(&holder, null));
    try testing.expect(try cell.enqueueIfForcing(&waiter));

    // Still queued: the removal succeeds and gates a re-enqueue.
    try testing.expect(cell.removeWaiter(&contender));
    try testing.expect(!cell.removeWaiter(&contender));

    // Drained by a publish before the cancel arrived: no longer queued, so no re-enqueue.
    try testing.expect(try cell.enqueueIfForcing(&waiter));
    var woken = cell.publish(.{ .fixnum = 1 });
    woken.deinit(testing.allocator);
    try testing.expect(!cell.removeWaiter(&contender));
}
