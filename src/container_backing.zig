const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;

/// Refcounted, mutex-guarded header for mutable container backings.
///
/// `ContainerHeader` is the foundation for the cross-worker safe lifecycle
/// model that replaces the program-wide container arena. Each mutable
/// container heap struct (`Vector`, `MutableMap`, mutable `ByteArray`) is
/// intended to embed this header as its first field. The header carries:
///
///   - an atomic refcount tracking live owning references
///   - a per-container mutex guarding mutations across worker threads
///   - generic `len` / `capacity` / `storage` slots whose meaning is
///     finalized when each variant migrates
///   - the allocator the backing was created on, so `release()` can free
///     without callers threading one in
///   - a `destroy_fn` callback the variant supplies to free its
///     storage-specific resources and the header itself
///   - a reserved `flags` word for future cycle-handling work; the
///     layout is intentionally undefined here
///
/// Atomic ordering:
///
///   - `retain` uses `.monotonic` fetchAdd because the caller already
///     holds a live reference and cannot race against destruction.
///   - `release` uses `.acq_rel` fetchSub so the decrement publishes all
///     prior writes to whichever thread observes the last drop, and the
///     observing thread's read of the resulting refcount happens-after
///     every other thread's mutations. This matches the codebase pattern
///     in `scheduler.zig` / `task.zig` for similar count-down-and-act
///     decrements.
///
/// The per-container mutex is a plain `std.Thread.Mutex`. Integration
/// with `LockOrderTracker` (a new container lock level) lands alongside
/// the first real call site; the helpers below wrap the raw mutex.
pub const ContainerHeader = struct {
    refcount: std.atomic.Value(u32),
    mutex: std.Thread.Mutex,
    len: usize,
    capacity: usize,
    storage: ?*anyopaque,
    allocator: std.mem.Allocator,
    destroy_fn: *const fn (*ContainerHeader) void,
    flags: u64,

    /// Initialize a header in-place with refcount=1, an unlocked mutex,
    /// zeroed `len`/`capacity`/`storage`, and a zeroed `flags` word.
    ///
    /// The caller owns the storage layout; this entry point only sets up
    /// the bookkeeping fields. Use `init` immediately after the host
    /// struct is created on `allocator`, before any other thread can
    /// observe it.
    pub fn init(
        self: *ContainerHeader,
        allocator: std.mem.Allocator,
        destroy_fn: *const fn (*ContainerHeader) void,
    ) void {
        self.* = .{
            .refcount = std.atomic.Value(u32).init(1),
            .mutex = .{},
            .len = 0,
            .capacity = 0,
            .storage = null,
            .allocator = allocator,
            .destroy_fn = destroy_fn,
            .flags = 0,
        };
    }

    /// Increment the refcount. Cheap, monotonic; safe to call from any
    /// thread that already holds a live reference.
    pub fn retain(self: *ContainerHeader) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    /// Decrement the refcount. On the last drop, invoke `destroy_fn` to
    /// free the host struct's storage and the header itself.
    ///
    /// `.acq_rel` ordering on the decrement gives release semantics to
    /// any preceding writes the dropping thread made, and acquire
    /// semantics on the returned previous value so the destroy callback
    /// observes every other holder's prior mutations.
    pub fn release(self: *ContainerHeader) void {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        std.debug.assert(prev != 0);
        if (prev == 1) {
            self.destroy_fn(self);
        }
    }

    /// Acquire the per-container mutex. Mutations of the backing's
    /// `len` / `capacity` / `storage` must occur under this lock.
    pub fn lock(self: *ContainerHeader) void {
        self.mutex.lock();
    }

    /// Release the per-container mutex.
    pub fn unlock(self: *ContainerHeader) void {
        self.mutex.unlock();
    }

    /// Snapshot the current refcount. For diagnostics and tests only;
    /// the value is racy in the presence of other holders.
    pub fn refcountValue(self: *const ContainerHeader) u32 {
        return self.refcount.load(.monotonic);
    }
};

/// Per-variant retain dispatch. Vector and mutable_map carry refcounted
/// backing and route through `header.retain()`. byte_array remains a
/// no-op stub until its backing migrates. Non-container variants are
/// no-ops by construction.
///
/// Storage-boundary call sites (stack push, container insertion,
/// dictionary entry, task result) route through this single entry point
/// so the dispatch is consistent across migrations.
pub fn retainValue(v: Value) void {
    switch (v) {
        .vector => |vec| vec.header.retain(),
        .mutable_map => |mm| mm.header.retain(),
        .byte_array => |_| {},
        else => {},
    }
}

/// Per-variant release dispatch. Mirror of `retainValue`; vector and
/// mutable_map call `header.release()` (destroying the backing on last
/// drop); byte_array remains a no-op stub until its backing migrates.
pub fn releaseValue(v: Value) void {
    switch (v) {
        .vector => |vec| vec.header.release(),
        .mutable_map => |mm| mm.header.release(),
        .byte_array => |_| {},
        else => {},
    }
}

/// Release container-variant `push_literal` operands embedded in an instruction slice.
/// The walk is shallow: nested quotation literals are not recursed into, because each
/// quotation is registered separately on its owning allocator's release list at
/// construction time and will be released independently.
///
/// Used by the per-arena and per-dictionary container release lists at teardown,
/// before the instruction memory itself is freed.
pub fn releaseInstructionsContainerLiterals(instructions: []const Instruction) void {
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| releaseValue(val),
            .call_word => {},
        }
    }
}

/// Retain container-variant `push_literal` operands in `instructions`. Used by quotation-
/// building primitives (`curry`, `compose`) when copying instructions out of a source
/// quotation into a freshly allocated slice that will itself be registered for release:
/// each copied container literal becomes a second owning reference and must be retained
/// to balance the extra release at teardown.
pub fn retainInstructionsContainerLiterals(instructions: []const Instruction) void {
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| retainValue(val),
            .call_word => {},
        }
    }
}

/// Returns `true` if any instruction in the slice is a `push_literal` carrying a
/// container variant. Used at construction sites to decide whether a quotation needs to
/// be registered on its owning allocators's container release list.
pub fn instructionsHaveContainerLiteral(instructions: []const Instruction) bool {
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| switch (val) {
                .vector, .mutable_map, .byte_array => return true,
                else => {},
            },
            .call_word => {},
        }
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Synthetic backing used by the unit tests. Mirrors the layout real
/// variants will adopt when they migrate: header at the top, storage
/// owned by the host struct, freed in `destroy_fn`.
const TestBacking = struct {
    header: ContainerHeader,
    counter: std.atomic.Value(u64),
    payload: []u8,
};

/// Tracks whether the test backing's destroy callback has run. The
/// pointer lives outside the backing so the test can observe the
/// destroy after-the-fact.
const DestroyTracker = struct {
    fired: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

threadlocal var destroy_tracker_ptr: ?*DestroyTracker = null;

fn destroyTestBacking(header: *ContainerHeader) void {
    const backing: *TestBacking = @fieldParentPtr("header", header);
    if (destroy_tracker_ptr) |tr| {
        _ = tr.fired.fetchAdd(1, .acq_rel);
    }
    header.allocator.free(backing.payload);
    header.allocator.destroy(backing);
}

fn createTestBacking(allocator: std.mem.Allocator, payload_size: usize) !*TestBacking {
    const backing = try allocator.create(TestBacking);
    errdefer allocator.destroy(backing);
    const payload = try allocator.alloc(u8, payload_size);
    errdefer allocator.free(payload);

    backing.header.init(allocator, destroyTestBacking);
    backing.counter = std.atomic.Value(u64).init(0);
    backing.payload = payload;
    return backing;
}

test "ContainerHeader: single-thread lifecycle" {
    var tracker = DestroyTracker{};
    destroy_tracker_ptr = &tracker;
    defer destroy_tracker_ptr = null;

    const backing = try createTestBacking(testing.allocator, 16);
    try testing.expectEqual(@as(u32, 1), backing.header.refcountValue());

    backing.header.retain();
    try testing.expectEqual(@as(u32, 2), backing.header.refcountValue());

    backing.header.release();
    try testing.expectEqual(@as(u32, 1), backing.header.refcountValue());
    try testing.expectEqual(@as(u32, 0), tracker.fired.load(.acquire));

    backing.header.release();
    try testing.expectEqual(@as(u32, 1), tracker.fired.load(.acquire));
}

const MutexWorkerArgs = struct {
    backing: *TestBacking,
    iters: u32,
};

fn mutexWorker(args: MutexWorkerArgs) void {
    var i: u32 = 0;
    while (i < args.iters) : (i += 1) {
        args.backing.header.lock();
        const cur = args.backing.counter.load(.monotonic);
        args.backing.counter.store(cur + 1, .monotonic);
        args.backing.header.unlock();
    }
}

test "ContainerHeader: mutex enforces mutual exclusion" {
    var tracker = DestroyTracker{};
    destroy_tracker_ptr = &tracker;
    defer destroy_tracker_ptr = null;

    const backing = try createTestBacking(testing.allocator, 16);

    const thread_count: u32 = 4;
    const iters_per_thread: u32 = 5_000;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, mutexWorker, .{MutexWorkerArgs{
            .backing = backing,
            .iters = iters_per_thread,
        }});
    }
    for (threads) |t| t.join();

    try testing.expectEqual(
        @as(u64, thread_count * iters_per_thread),
        backing.counter.load(.monotonic),
    );

    backing.header.release();
    try testing.expectEqual(@as(u32, 1), tracker.fired.load(.acquire));
}

const RefcountWorkerArgs = struct {
    backing: *TestBacking,
    iters: u32,
    tracker: *DestroyTracker,
};

fn refcountWorker(args: RefcountWorkerArgs) void {
    destroy_tracker_ptr = args.tracker;
    defer destroy_tracker_ptr = null;

    var i: u32 = 0;
    while (i < args.iters) : (i += 1) {
        args.backing.header.retain();
        // While we hold this transient reference the baseline reference
        // is also live, so destroy must not have run.
        std.debug.assert(args.tracker.fired.load(.monotonic) == 0);
        args.backing.header.release();
    }
}

test "ContainerHeader: refcount survives concurrent retain/release" {
    var tracker = DestroyTracker{};
    destroy_tracker_ptr = &tracker;
    defer destroy_tracker_ptr = null;

    const backing = try createTestBacking(testing.allocator, 16);

    const thread_count: u32 = 4;
    const iters_per_thread: u32 = 10_000;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, refcountWorker, .{RefcountWorkerArgs{
            .backing = backing,
            .iters = iters_per_thread,
            .tracker = &tracker,
        }});
    }
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 1), backing.header.refcountValue());
    try testing.expectEqual(@as(u32, 0), tracker.fired.load(.acquire));

    backing.header.release();
    try testing.expectEqual(@as(u32, 1), tracker.fired.load(.acquire));
}

const PublishArgs = struct {
    backing: *TestBacking,
    sentinel: u64,
    started: *std.atomic.Value(bool),
};

fn publishProducer(args: PublishArgs) void {
    while (!args.started.load(.acquire)) std.Thread.yield() catch {};

    args.backing.header.lock();
    args.backing.counter.store(args.sentinel, .monotonic);
    args.backing.header.unlock();
}

test "ContainerHeader: lock orders published writes across threads" {
    var tracker = DestroyTracker{};
    destroy_tracker_ptr = &tracker;
    defer destroy_tracker_ptr = null;

    const backing = try createTestBacking(testing.allocator, 16);
    const sentinel: u64 = 0xCAFEBABE_DEADBEEF;

    var started = std.atomic.Value(bool).init(false);

    const producer = try std.Thread.spawn(.{}, publishProducer, .{PublishArgs{
        .backing = backing,
        .sentinel = sentinel,
        .started = &started,
    }});

    started.store(true, .release);

    producer.join();

    backing.header.lock();
    const seen = backing.counter.load(.monotonic);
    backing.header.unlock();
    try testing.expectEqual(sentinel, seen);

    backing.header.release();
    try testing.expectEqual(@as(u32, 1), tracker.fired.load(.acquire));
}

test "retainValue/releaseValue: scalar dispatch is a no-op" {
    // Scalar variants must traverse the dispatch without allocation or
    // panic. Container arms grow real coverage as each variant migrates.
    const cases = [_]Value{
        .{ .fixnum = 42 },
        .{ .boolean = true },
        .unit,
    };
    for (cases) |v| {
        retainValue(v);
        releaseValue(v);
    }
}

test "retainValue/releaseValue: vector dispatch exercises the header" {
    const vec = try value_mod.Vector.create(testing.allocator);
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    retainValue(.{ .vector = vec });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .vector = vec });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    releaseValue(.{ .vector = vec });
    // Final release destroys the backing; no further refcount inspection.
}

test "retainValue/releaseValue: mutable_map dispatch exercises the header" {
    const mm = try value_mod.MutableMap.create(testing.allocator);
    try testing.expectEqual(@as(u32, 1), mm.header.refcountValue());

    retainValue(.{ .mutable_map = mm });
    try testing.expectEqual(@as(u32, 2), mm.header.refcountValue());

    releaseValue(.{ .mutable_map = mm });
    try testing.expectEqual(@as(u32, 1), mm.header.refcountValue());

    releaseValue(.{ .mutable_map = mm });
    // Final release destroys the backing; no further refcount inspection.
}

test "instructionsHaveContainerLiteral: detects container push_literal operands" {
    const empty: []const Instruction = &.{};
    try testing.expect(!instructionsHaveContainerLiteral(empty));

    const scalars = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 },
        .{ .op = .{ .call_word = "noop" }, .line = 0 },
        .{ .op = .{ .push_literal = .unit }, .line = 0 },
    };
    try testing.expect(!instructionsHaveContainerLiteral(&scalars));

    // Build a one-off Vector pointer so we can construct a container Value
    // for the scan. The dispatch is no-op today so the underlying pointer
    // is never dereferenced.
    const dummy_vec = try value_mod.Vector.create(testing.allocator);
    defer dummy_vec.header.release();
    const with_vector = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .vector = dummy_vec } }, .line = 0 },
    };
    try testing.expect(instructionsHaveContainerLiteral(&with_vector));
}

test "releaseInstructionsContainerLiterals: shallow walk over push_literal operands" {
    // Asserts the walk does not crash on any mix of literal variants,
    // including nested quotation literals (which must not be recursed
    // into). Walks the outer slice, which contains one container
    // push_literal that will be released; bump the refcount so the
    // C-local can still observe state afterwards.
    const dummy_vec = try value_mod.Vector.create(testing.allocator);
    dummy_vec.header.retain();
    defer dummy_vec.header.release();
    var inner_instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .vector = dummy_vec } }, .line = 0 },
    };
    const inner_quot = value_mod.Quotation{
        .instructions = &inner_instrs,
        .effect = null,
        .code_ptr = null,
    };
    const outer = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .quotation = inner_quot } }, .line = 0 },
        .{ .op = .{ .call_word = "call" }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .vector = dummy_vec } }, .line = 0 },
    };
    releaseInstructionsContainerLiterals(&outer);
}
