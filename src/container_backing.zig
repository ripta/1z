const std = @import("std");
const freestanding_compat = @import("freestanding_compat.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const Iterator = @import("iterator.zig").Iterator;

/// Live-backing accounting for the `--benchmark` "Live backings" metric.
///
/// `bench_enabled` is written once at startup, before any container is
/// created, and read-only thereafter; non-benchmark and AOT runs pay only a
/// cheap, well-predicted branch on the two accounting sites and never touch
/// the global counters. Only `--benchmark` runs incur the global atomics.
var bench_enabled = std.atomic.Value(bool).init(false);
var live_backings = std.atomic.Value(usize).init(0);
var peak_backings = std.atomic.Value(usize).init(0);

/// Enable live-backing accounting. Called once at startup, before any
/// container is created, when `--benchmark` is active.
pub fn setBenchEnabled(on: bool) void {
    bench_enabled.store(on, .monotonic);
}

/// Current count of live container backings. Meaningful only when accounting
/// is enabled.
pub fn liveBackingCount() usize {
    return live_backings.load(.monotonic);
}

/// Peak concurrent live container backings observed. Meaningful only when
/// accounting is enabled.
pub fn peakBackingCount() usize {
    return peak_backings.load(.monotonic);
}

fn accountBackingCreated() void {
    if (!bench_enabled.load(.monotonic)) return;
    const new = live_backings.fetchAdd(1, .monotonic) + 1;
    var cur = peak_backings.load(.monotonic);
    while (new > cur) {
        cur = peak_backings.cmpxchgWeak(cur, new, .monotonic, .monotonic) orelse break;
    }
}

fn accountBackingDestroyed() void {
    if (!bench_enabled.load(.monotonic)) return;
    _ = live_backings.fetchSub(1, .monotonic);
}

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
    mutex: freestanding_compat.Mutex,
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
        accountBackingCreated();
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
            accountBackingDestroyed();
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

/// Per-variant retain dispatch.
///
/// The header-backed variants (i.e., `vector`, `mutable_map`) carry a refcounted backing and route through
/// `header.retain()`. Their contents are accounted only at `destroy`, so we don't recurse into them here.
///
/// The headerless composites (i.e., `array`, `hash`, `set`, `tagged`, `struct_instance`, `error_value`,
/// `iterator`) own a reference to each refcounted value they embed, so a stack slot holding one must
/// retain those embedded values recursively. An `error_value` owns the value carried in its `data` field.
///
/// `byte_array` carries a refcounted backing like `vector` and `mutable_map`; its bytes are not Values,
/// so there is nothing to recurse into.
///
/// Non-container variants are noöps by construction.
///
/// Storage-boundary call sites (stack push, container insertion, dictionary entry, task result) route
/// through this single entry point so the dispatch is consistent across migrations.
pub fn retainValue(v: Value) void {
    switch (v) {
        .vector => |vec| vec.header.retain(),
        .mutable_map => |mm| mm.header.retain(),
        .byte_array => |ba| ba.header.retain(),
        .array => |items| retainValues(items),
        .hash => |h| {
            var iter = h.iterator();
            while (iter.next()) |entry| retainValue(entry.value_ptr.*);
        },
        .set => |s| retainValues(s.keys()),
        .tagged => |t| retainValue(t.inner.*),
        .struct_instance => |si| retainValues(si.fields),
        .error_value => |err| if (err.data) |data| retainValue(data.*),
        .iterator => |it| retainIteratorBacking(it),
        else => {},
    }
}

/// Per-variant release dispatch.
///
/// Header-backed variants call `header.release()`, destroying the backing on last drop.
///
/// Headerless composites recurse into their embedded values so the inner backings drop exactly once per
/// owning slot.
///
/// `byte_array` releases its header like `vector` and `mutable_map`, destroying the backing on last drop.
pub fn releaseValue(v: Value) void {
    switch (v) {
        .vector => |vec| vec.header.release(),
        .mutable_map => |mm| mm.header.release(),
        .byte_array => |ba| ba.header.release(),
        .array => |items| releaseValues(items),
        .hash => |h| {
            var iter = h.iterator();
            while (iter.next()) |entry| releaseValue(entry.value_ptr.*);
        },
        .set => |s| releaseValues(s.keys()),
        .tagged => |t| releaseValue(t.inner.*),
        .struct_instance => |si| releaseValues(si.fields),
        .error_value => |err| if (err.data) |data| releaseValue(data.*),
        .iterator => |it| releaseIteratorBacking(it),
        else => {},
    }
}

/// Retain the refcounted backing an iterator captures.
///
/// `array` iterators hold a slice of element Values.
///
/// The chained iterators (`map`, `filter`, `take`, `drop`) forward to their inner iterator.
///
/// `range` captures no Values.
///
/// `callback` captures only quotations whose container literals are tracked by the per-arena release
/// list, so both are no-ops.
///
/// This backing ownership is distinct from the per-element ownership that `Iterator.next` hands out,
/// where `next` yields an owning reference for every iterator kind, which the consumer releases once
/// it has consumed the value.
///
/// The backing retained here keeps the source elements alive for the iterator's lifetime; the
/// per-yield retain is balanced separately by the consumer.
pub fn retainIteratorBacking(it: *Iterator) void {
    switch (it.kind) {
        .array => |ai| retainValues(ai.items),
        .map => |m| retainIteratorBacking(m.inner),
        .filter => |fi| retainIteratorBacking(fi.inner),
        .take => |t| retainIteratorBacking(t.inner),
        .drop => |d| retainIteratorBacking(d.inner),
        .range, .callback => {},
    }
}

/// Release the refcounted backing an iterator captures.
pub fn releaseIteratorBacking(it: *Iterator) void {
    switch (it.kind) {
        .array => |ai| releaseValues(ai.items),
        .map => |m| releaseIteratorBacking(m.inner),
        .filter => |fi| releaseIteratorBacking(fi.inner),
        .take => |t| releaseIteratorBacking(t.inner),
        .drop => |d| releaseIteratorBacking(d.inner),
        .range, .callback => {},
    }
}

/// Whether `retainValue`/`releaseValue` would touch a refcounted backing for
/// this value, directly or through a composite. Used at codegen time to decide
/// whether a `push_literal` needs a paired retain emission: scalars and
/// backing-free composites skip it. Mirrors the recursion of `retainValue`;
/// `.iterator` is treated conservatively as carrying a backing.
pub fn valueCarriesBacking(v: Value) bool {
    return switch (v) {
        .vector, .mutable_map, .byte_array => true,
        .array => |items| valuesCarryBacking(items),
        .hash => |h| blk: {
            var iter = h.iterator();
            while (iter.next()) |entry| {
                if (valueCarriesBacking(entry.value_ptr.*)) break :blk true;
            }
            break :blk false;
        },
        .set => |s| valuesCarryBacking(s.keys()),
        .tagged => |t| valueCarriesBacking(t.inner.*),
        .struct_instance => |si| valuesCarryBacking(si.fields),
        .error_value => |err| if (err.data) |data| valueCarriesBacking(data.*) else false,
        .iterator => true,
        else => false,
    };
}

fn valuesCarryBacking(items: []const Value) bool {
    for (items) |item| {
        if (valueCarriesBacking(item)) return true;
    }
    return false;
}

/// Retain every value in a slice. Used by container builders that copy a
/// source's elements into a freshly created vector: a value stored in a
/// vector's backing list is an owning reference, so each copied element must
/// be retained to balance the release performed when the vector is destroyed.
pub fn retainValues(items: []const Value) void {
    for (items) |item| retainValue(item);
}

/// Release every value in a slice. Mirror of `retainValues`.
pub fn releaseValues(items: []const Value) void {
    for (items) |item| releaseValue(item);
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
            .call_word, .call_word_direct => {},
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
            .call_word, .call_word_direct => {},
        }
    }
}

/// Returns `true` if `val` carries a refcounted backing, either directly (a header-backed variant) or
/// transitively through a composite that embeds one.
///
/// Used to decide whether an instruction's `push_literal` operand holds an owning reference that must
/// be released at teardown.
pub fn valueHoldsRefcountedBacking(val: Value) bool {
    return switch (val) {
        .vector, .mutable_map, .byte_array => true,
        .array => |items| {
            for (items) |item| {
                if (valueHoldsRefcountedBacking(item)) return true;
            }
            return false;
        },
        .hash => |h| {
            var iter = h.iterator();
            while (iter.next()) |entry| {
                if (valueHoldsRefcountedBacking(entry.value_ptr.*)) return true;
            }
            return false;
        },
        .set => |s| {
            for (s.keys()) |key| {
                if (valueHoldsRefcountedBacking(key)) return true;
            }
            return false;
        },
        .tagged => |t| valueHoldsRefcountedBacking(t.inner.*),
        .struct_instance => |si| {
            for (si.fields) |field| {
                if (valueHoldsRefcountedBacking(field)) return true;
            }
            return false;
        },
        .error_value => |err| if (err.data) |data| valueHoldsRefcountedBacking(data.*) else false,
        else => false,
    };
}

/// Returns `true` if any instruction in the slice is a `push_literal` carrying a refcounted backing,
/// directly or transitively through a composite literal.
///
/// Used at construction sites to decide whether a quotation needs to be registered on its owning
/// allocator's container release list.
pub fn instructionsHaveContainerLiteral(instructions: []const Instruction) bool {
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                if (valueHoldsRefcountedBacking(val)) return true;
            },
            .call_word, .call_word_direct => {},
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

test "live-backing accounting tracks create and destroy under bench guard" {
    setBenchEnabled(true);
    defer {
        setBenchEnabled(false);
        live_backings.store(0, .monotonic);
        peak_backings.store(0, .monotonic);
    }
    live_backings.store(0, .monotonic);
    peak_backings.store(0, .monotonic);

    const vec = try value_mod.Vector.create(testing.allocator);
    const mm = try value_mod.MutableMap.create(testing.allocator);
    const ba = try value_mod.ByteArray.create(testing.allocator);
    try testing.expectEqual(@as(usize, 3), liveBackingCount());
    try testing.expectEqual(@as(usize, 3), peakBackingCount());

    vec.header.release();
    mm.header.release();
    try testing.expectEqual(@as(usize, 1), liveBackingCount());
    // Peak holds the high-water mark after backings drop.
    try testing.expectEqual(@as(usize, 3), peakBackingCount());

    ba.header.release();
    try testing.expectEqual(@as(usize, 0), liveBackingCount());
    try testing.expectEqual(@as(usize, 3), peakBackingCount());
}

test "live-backing accounting is inert when bench guard is off" {
    setBenchEnabled(false);
    live_backings.store(0, .monotonic);
    peak_backings.store(0, .monotonic);

    const vec = try value_mod.Vector.create(testing.allocator);
    try testing.expectEqual(@as(usize, 0), liveBackingCount());
    try testing.expectEqual(@as(usize, 0), peakBackingCount());
    vec.header.release();
    try testing.expectEqual(@as(usize, 0), liveBackingCount());
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

test "retainValue/releaseValue: byte_array dispatch exercises the header" {
    const ba = try value_mod.ByteArray.create(testing.allocator);
    try testing.expectEqual(@as(u32, 1), ba.header.refcountValue());

    retainValue(.{ .byte_array = ba });
    try testing.expectEqual(@as(u32, 2), ba.header.refcountValue());

    releaseValue(.{ .byte_array = ba });
    try testing.expectEqual(@as(u32, 1), ba.header.refcountValue());

    releaseValue(.{ .byte_array = ba });
    // Final release destroys the backing; no further refcount inspection.
}

test "retainValue/releaseValue: array propagates to embedded vector" {
    const vec = try value_mod.Vector.create(testing.allocator);
    var items = [_]Value{.{ .vector = vec }};
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    retainValue(.{ .array = &items });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .array = &items });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    // Drop the baseline reference; destroys the backing.
    vec.header.release();
}

test "retainValue/releaseValue: tagged propagates to inner vector" {
    const vec = try value_mod.Vector.create(testing.allocator);
    var inner: Value = .{ .vector = vec };
    var dummy_vt: value_mod.VirtualType = undefined;

    retainValue(.{ .tagged = .{ .tag = &dummy_vt, .inner = &inner } });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .tagged = .{ .tag = &dummy_vt, .inner = &inner } });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    vec.header.release();
}

test "retainValue/releaseValue: struct_instance propagates to field vector" {
    const vec = try value_mod.Vector.create(testing.allocator);
    var fields = [_]Value{.{ .vector = vec }};
    var st = value_mod.StructType{ .name = "box", .fields = &.{"data"} };
    var inst = value_mod.StructInstance{ .struct_type = &st, .fields = &fields };

    retainValue(.{ .struct_instance = &inst });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .struct_instance = &inst });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    vec.header.release();
}

test "retainValue/releaseValue: hash propagates to stored vector value" {
    const vec = try value_mod.Vector.create(testing.allocator);
    var h = value_mod.HashTable{};
    defer h.deinit(testing.allocator);
    try h.put(testing.allocator, "k", .{ .vector = vec });

    retainValue(.{ .hash = &h });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .hash = &h });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    vec.header.release();
}

test "retainValue/releaseValue: set propagates to member vector" {
    const vec = try value_mod.Vector.create(testing.allocator);
    var s = value_mod.Set{};
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, .{ .vector = vec }, {});

    retainValue(.{ .set = &s });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .set = &s });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    vec.header.release();
}

test "retainValue/releaseValue: nested array recurses to depth" {
    const vec = try value_mod.Vector.create(testing.allocator);
    var inner = [_]Value{.{ .vector = vec }};
    var outer = [_]Value{.{ .array = &inner }};

    retainValue(.{ .array = &outer });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .array = &outer });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    vec.header.release();
}

test "retainValue/releaseValue: array iterator propagates to captured vector" {
    const vec = try value_mod.Vector.create(testing.allocator);
    var items = [_]Value{.{ .vector = vec }};
    var it = Iterator{ .kind = .{ .array = .{ .items = &items, .index = 0 } } };

    retainValue(.{ .iterator = &it });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .iterator = &it });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    vec.header.release();
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
