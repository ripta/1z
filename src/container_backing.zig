const std = @import("std");
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

/// Memoized answer to "is this backing safe to share across task boundaries?".
///
/// `.unknown` means no scan has run yet. The memo is never invalidated:
/// it is only written for containers whose contents cannot change after
/// construction, so a scanned state holds for the backing's lifetime.
pub const Shareable = enum(u8) {
    unknown,
    shareable,
    not_shareable,
};

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
///   - a tri-state `shareable` memo recording whether the backing is
///     safe to share across task boundaries, populated lazily by
///     `memoShareable`
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
///   - `shareable` uses `.monotonic` loads and stores. Concurrent writers
///     race benignly: the memo is a pure function of contents that are
///     immutable once the value is visible to more than one thread, so
///     every writer stores the same state.
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
    shareable: std.atomic.Value(Shareable),

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
            .shareable = std.atomic.Value(Shareable).init(.unknown),
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

    /// Whether the caller holds the only live reference. The acquire load pairs with the
    /// releasing decrement of every former holder, so a true result also publishes their prior
    /// writes to the caller, the same guarantee `release` relies on before destroying. Gates
    /// sole-owner fast paths that read or mutate the backing without taking the mutex.
    pub fn isSoleOwner(self: *const ContainerHeader) bool {
        return self.refcount.load(.acquire) == 1;
    }

    /// Current state of the share-safety memo.
    pub fn shareableState(self: *const ContainerHeader) Shareable {
        return self.shareable.load(.monotonic);
    }

    /// Record the share-safety memo. Concurrent stores race
    /// benignly; see the ordering notes on the header doc comment.
    pub fn setShareable(self: *ContainerHeader, state: Shareable) void {
        self.shareable.store(state, .monotonic);
    }
};

/// Per-variant retain dispatch.
///
/// The header-backed variants (i.e., `array`, `vector`, `mutable_map`, `hash`, `set`, `iterator`)
/// carry a refcounted backing and route through `header.retain()`. Their contents are accounted
/// only at `destroy`, so we don't recurse into them here.
///
/// The headerless composite `error_value` owns a reference to the value carried in its `data`
/// field, so a stack slot holding one must retain that embedded value recursively.
///
/// A `struct_instance` is either form. A runtime-created instance carries a header and routes
/// through it, so the instance is the single owner of its field set and the field setter can
/// replace a field without unbalancing other copies. A headerless instance uses the recursive
/// per-copy claims, which is only balanced while the fields never change.
///
/// A `tagged` is either form the same way: a backed wrapper routes through its `TaggedBacking`
/// header, whose destroy releases the inner value once, while a null-backed wrapper is an arena
/// box whose slot claims the inner value's backings recursively.
///
/// `byte_array` carries a refcounted backing like `vector` and `mutable_map`; its bytes are not Values,
/// so there is nothing to recurse into.
///
/// `string` and `symbol` retain their optional `StringBacking`; a null backing means borrowed
/// bytes that outlive the value, so retain and release are no-ops there.
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
        .hash => |h| h.header.retain(),
        .set => |s| s.header.retain(),
        .array => |arr| arr.header.retain(),
        .tagged => |t| if (t.backing) |b| b.header.retain() else retainValue(t.inner.*),
        .struct_instance => |si| if (si.header) |h| h.retain() else retainValues(si.fields),
        .error_value => |err| if (err.data) |data| retainValue(data.*),
        .iterator => |it| it.header.retain(),
        .string, .symbol => |s| if (s.backing) |b| b.header.retain(),
        .bignum => |b| if (b.backing) |bk| bk.header.retain(),
        .closure => |c| c.header.retain(),
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
        .hash => |h| h.header.release(),
        .set => |s| s.header.release(),
        .array => |arr| arr.header.release(),
        .tagged => |t| if (t.backing) |b| b.header.release() else releaseValue(t.inner.*),
        .struct_instance => |si| if (si.header) |h| h.release() else releaseValues(si.fields),
        .error_value => |err| if (err.data) |data| releaseValue(data.*),
        .iterator => |it| it.header.release(),
        .string, .symbol => |s| if (s.backing) |b| b.header.release(),
        .bignum => |b| if (b.backing) |bk| bk.header.release(),
        .closure => |c| c.header.release(),
        else => {},
    }
}

/// Whether `retainValue`/`releaseValue` would touch a refcounted backing for
/// this value, directly or through a composite. Used at codegen time to decide
/// whether a `push_literal` needs a paired retain emission: scalars and
/// backing-free composites skip it. Mirrors the recursion of `retainValue`;
/// `.iterator` is treated conservatively as carrying a backing.
pub fn valueCarriesBacking(v: Value) bool {
    return switch (v) {
        .vector, .mutable_map, .byte_array, .hash, .set, .array => true,
        .tagged => |t| t.backing != null or valueCarriesBacking(t.inner.*),
        .struct_instance => |si| si.header != null or valuesCarryBacking(si.fields),
        .error_value => |err| if (err.data) |data| valueCarriesBacking(data.*) else false,
        .iterator => true,
        .string, .symbol => |s| s.backing != null,
        .bignum => |b| b.backing != null,
        .closure => true,
        else => false,
    };
}

fn valuesCarryBacking(items: []const Value) bool {
    for (items) |item| {
        if (valueCarriesBacking(item)) return true;
    }
    return false;
}

/// Whether two allocators are the same instance. Sharing requires the backing to live on the
/// process-lifetime allocator, and every `Context` inherits one shared allocator identity, so an
/// identity comparison is an O(1) provenance check.
pub fn allocatorEql(a: std.mem.Allocator, b: std.mem.Allocator) bool {
    return a.ptr == b.ptr and a.vtable == b.vtable;
}

/// Whether a value tree is safe to share across a task boundary in place of a deep copy.
///
/// Deep immutability alone is not enough: sharing also requires that no reachable byte dies with
/// the creating task's arena. What qualifies is payload-in-`Value` scalars, the backed leaves
/// (`string`, `symbol`, `bignum`) whose backing was created on `longlived` (the process-lifetime
/// allocator), a backed `tagged` whose inner value recursively qualifies, and headered
/// `array`/`hash`/`set` whose backing passes the same identity check and whose contents
/// recursively qualify. Hash keys are byte slices duped onto the backing's own allocator at every
/// insert path, so the backing identity check covers them.
///
/// A null backing is never shareable: source text parsed onto a task arena also produces one, and
/// a `Value` records no allocator identity for it. `freeze` promotes null-backed string and
/// symbol leaves into heap backings, so a literal-bearing frozen container qualifies.
/// Static-storage arrays live on instruction memory and fail the backing identity check.
///
/// Coverage can widen later without changing callers.
pub fn valueShareable(v: Value, longlived: std.mem.Allocator) bool {
    return switch (v) {
        .fixnum,
        .float,
        .boolean,
        .unit,
        => true,
        .string, .symbol => |s| if (s.backing) |b| allocatorEql(b.header.allocator, longlived) else false,
        .bignum => |b| if (b.backing) |bk| allocatorEql(bk.header.allocator, longlived) else false,
        .tagged => |t| if (t.backing) |b| memoShareable(&b.header, v, longlived) else false,
        .array => |arr| memoShareable(&arr.header, v, longlived),
        .hash => |h| memoShareable(&h.header, v, longlived),
        .set => |s| memoShareable(&s.header, v, longlived),
        else => false,
    };
}

/// Scan a headered container's backing and contents for share-safety, without consulting the
/// memo. `valueShareable` on the elements re-enters the memo path for nested containers, so inner
/// memos are populated as a side effect of scanning an outer container.
fn scanShareable(v: Value, longlived: std.mem.Allocator) bool {
    return switch (v) {
        .array => |arr| blk: {
            if (arr.storage != .owned) break :blk false;
            if (!allocatorEql(arr.header.allocator, longlived)) break :blk false;
            for (arr.items) |item| {
                if (!valueShareable(item, longlived)) break :blk false;
            }
            break :blk true;
        },
        .hash => |h| blk: {
            if (!allocatorEql(h.header.allocator, longlived)) break :blk false;
            var iter = h.map.iterator();
            while (iter.next()) |entry| {
                if (!valueShareable(entry.value_ptr.*, longlived)) break :blk false;
            }
            break :blk true;
        },
        .set => |s| blk: {
            if (!allocatorEql(s.header.allocator, longlived)) break :blk false;
            for (s.map.keys()) |key| {
                if (!valueShareable(key, longlived)) break :blk false;
            }
            break :blk true;
        },
        // Only a backed wrapper reaches here, through its backing's memo. The inner value is
        // embedded in the backing and immutable post-construction, so the memo stays sound.
        .tagged => |t| blk: {
            const b = t.backing orelse break :blk false;
            if (!allocatorEql(b.header.allocator, longlived)) break :blk false;
            break :blk valueShareable(t.inner.*, longlived);
        },
        else => false,
    };
}

/// Memoized share-safety check for a headered container. Scans the backing and `contents` once on
/// the first call and records the result in the header's `shareable` state; repeat calls are O(1).
///
/// Sound only for containers whose contents cannot change after construction, since the memo is
/// never invalidated. The verdict is also independent of the `longlived` argument in practice:
/// every `Context` shares one process-wide allocator identity, so all callers pass the same
/// allocator.
pub fn memoShareable(header: *ContainerHeader, contents: Value, longlived: std.mem.Allocator) bool {
    switch (header.shareableState()) {
        .shareable => return true,
        .not_shareable => return false,
        .unknown => {},
    }

    const ok = scanShareable(contents, longlived);
    header.setShareable(if (ok) .shareable else .not_shareable);
    return ok;
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
            .call_word, .call_word_direct, .call_word_module => {},
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
            .call_word, .call_word_direct, .call_word_module => {},
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
        .vector, .mutable_map, .byte_array, .hash, .set, .array, .iterator, .closure => true,
        .string, .symbol => |s| s.backing != null,
        .bignum => |b| b.backing != null,
        .tagged => |t| t.backing != null or valueHoldsRefcountedBacking(t.inner.*),
        .struct_instance => |si| {
            if (si.header != null) return true;
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
            .call_word, .call_word_direct, .call_word_module => {},
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

test "retainValue/releaseValue: array dispatch exercises the header" {
    // The vector's construction reference transfers into the array slot;
    // retain an observation reference so the refcount stays inspectable
    // across the array's destroy.
    const vec = try value_mod.Vector.create(testing.allocator);
    vec.header.retain();

    const items = try testing.allocator.alloc(Value, 1);
    items[0] = .{ .vector = vec };
    const arr = try value_mod.Array.fromOwnedSlice(testing.allocator, items);
    try testing.expectEqual(@as(u32, 1), arr.header.refcountValue());

    retainValue(.{ .array = arr });
    try testing.expectEqual(@as(u32, 2), arr.header.refcountValue());
    // Elements are accounted at destroy, not per stack slot.
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .array = arr });
    releaseValue(.{ .array = arr });
    // The array's destroy released its element reference.
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

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

test "retainValue/releaseValue: backed tagged routes through the backing header, not the inner" {
    const vec = try value_mod.Vector.create(testing.allocator);
    var dummy_vt: value_mod.VirtualType = undefined;
    const val = try value_mod.ownedTaggedValue(testing.allocator, &dummy_vt, .{ .vector = vec });
    try testing.expect(valueHoldsRefcountedBacking(val));

    retainValue(val);
    try testing.expectEqual(@as(u32, 2), val.tagged.backing.?.header.refcountValue());
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    releaseValue(val);
    try testing.expectEqual(@as(u32, 1), val.tagged.backing.?.header.refcountValue());

    // The last release destroys the backing, which releases the inner vector.
    releaseValue(val);
}

test "retainValue/releaseValue: headerless struct_instance propagates to field vector" {
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

test "retainValue/releaseValue: headered struct_instance routes through the header, not the fields" {
    var st = value_mod.StructType{ .name = "box", .fields = &.{"data"} };
    const vec = try value_mod.Vector.create(testing.allocator);
    const fields = try testing.allocator.alloc(Value, 1);
    fields[0] = .{ .vector = vec };
    const inst = try value_mod.createStructInstance(testing.allocator, &st, fields);

    retainValue(.{ .struct_instance = inst });
    // The header absorbs the new owner; the field's own refcount is untouched.
    try testing.expectEqual(@as(u32, 2), inst.header.?.refcountValue());
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    releaseValue(.{ .struct_instance = inst });
    try testing.expectEqual(@as(u32, 1), inst.header.?.refcountValue());

    // The last release destroys the instance, which releases and frees the
    // vector; testing.allocator verifies nothing leaks or double-frees.
    releaseValue(.{ .struct_instance = inst });
}

test "headered struct_instance: setter-shape field replacement stays balanced across copies" {
    var st = value_mod.StructType{ .name = "box", .fields = &.{"data"} };
    const fields = try testing.allocator.alloc(Value, 1);
    fields[0] = .{ .fixnum = 0 };
    const inst = try value_mod.createStructInstance(testing.allocator, &st, fields);

    // A second live copy of the instance value, the shape a top-level binding
    // holds while the setter runs against a stack copy.
    retainValue(.{ .struct_instance = inst });

    // The generated field setter's replacement sequence: release the old
    // owning reference, move the new value into the slot.
    const vec = try value_mod.Vector.create(testing.allocator);
    releaseValue(inst.fields[0]);
    inst.fields[0] = .{ .vector = vec };

    // Dropping one copy must not free the vector out from under the other.
    // Under the headerless per-copy-claims model this released the vector to
    // zero while the field still pointed at it -- the original crash.
    releaseValue(.{ .struct_instance = inst });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    releaseValue(.{ .struct_instance = inst });
}

test "retainValue/releaseValue: hash dispatch exercises the header" {
    const h = try value_mod.HashTable.create(testing.allocator);
    try testing.expectEqual(@as(u32, 1), h.header.refcountValue());

    retainValue(.{ .hash = h });
    try testing.expectEqual(@as(u32, 2), h.header.refcountValue());

    releaseValue(.{ .hash = h });
    try testing.expectEqual(@as(u32, 1), h.header.refcountValue());

    releaseValue(.{ .hash = h });
    // Final release destroys the backing; no further refcount inspection.
}

test "HashTable: destroy releases stored values and frees keys" {
    // The vector's construction reference transfers into the hash slot;
    // retain an observation reference so the refcount stays inspectable
    // across the hash's destroy.
    const vec = try value_mod.Vector.create(testing.allocator);
    vec.header.retain();

    const h = try value_mod.HashTable.create(testing.allocator);
    const key = try h.header.allocator.dupe(u8, "k");
    try h.map.put(h.header.allocator, key, .{ .vector = vec });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .hash = h });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    vec.header.release();
}

test "retainValue/releaseValue: set dispatch exercises the header" {
    const s = try value_mod.Set.create(testing.allocator);
    try testing.expectEqual(@as(u32, 1), s.header.refcountValue());

    retainValue(.{ .set = s });
    try testing.expectEqual(@as(u32, 2), s.header.refcountValue());

    releaseValue(.{ .set = s });
    try testing.expectEqual(@as(u32, 1), s.header.refcountValue());

    releaseValue(.{ .set = s });
    // Final release destroys the backing; no further refcount inspection.
}

test "Set: destroy releases member values" {
    // The vector's construction reference transfers into the set slot;
    // retain an observation reference so the refcount stays inspectable
    // across the set's destroy.
    const vec = try value_mod.Vector.create(testing.allocator);
    vec.header.retain();

    const s = try value_mod.Set.create(testing.allocator);
    try s.map.put(s.header.allocator, .{ .vector = vec }, {});
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .set = s });
    try testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    vec.header.release();
}

test "retainValue/releaseValue: static array release never frees the backing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = try alloc.alloc(Value, 2);
    items[0] = .{ .fixnum = 1 };
    items[1] = .{ .fixnum = 2 };
    const arr = try value_mod.Array.createStatic(alloc, items);

    retainValue(.{ .array = arr });
    releaseValue(.{ .array = arr });
    // Dropping the construction reference runs the no-op destroy; the
    // backing stays readable until the owning arena is torn down.
    releaseValue(.{ .array = arr });
    try testing.expectEqual(@as(i64, 1), arr.items[0].fixnum);
}

test "retainValue/releaseValue: iterator header owns its materialized backing" {
    const vec = try value_mod.Vector.create(testing.allocator);
    const items = try testing.allocator.alloc(Value, 1);
    items[0] = .{ .vector = vec };
    // The iterator's backing owns one reference per element.
    vec.header.retain();
    const it = try Iterator.create(testing.allocator, .{ .array = .{ .items = items, .index = 0 } });

    // A stack slot bumps the iterator's own header, not the captured elements.
    retainValue(.{ .iterator = it });
    try testing.expectEqual(@as(u32, 2), it.header.refcountValue());
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    releaseValue(.{ .iterator = it });
    try testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    // Dropping the creation reference destroys the iterator, releasing the element and freeing
    // the slice.
    releaseValue(.{ .iterator = it });
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

test "Shareable: header initializes to unknown and accessors roundtrip" {
    const backing = try createTestBacking(testing.allocator, 8);
    defer backing.header.release();

    try testing.expectEqual(Shareable.unknown, backing.header.shareableState());

    backing.header.setShareable(.shareable);
    try testing.expectEqual(Shareable.shareable, backing.header.shareableState());

    backing.header.setShareable(.not_shareable);
    try testing.expectEqual(Shareable.not_shareable, backing.header.shareableState());
}

test "valueShareable: scalar leaves qualify" {
    const cases = [_]Value{
        .{ .fixnum = 1 },
        .{ .float = 2.5 },
        .{ .boolean = false },
        .unit,
    };
    for (cases) |v| try testing.expect(valueShareable(v, testing.allocator));
}

test "valueShareable: immutable arena-payload leaves do not qualify" {
    const segments = [_]value_mod.TemplateSegment{.{ .literal = "hi" }};
    var big = try value_mod.BigIntManaged.initSet(testing.allocator, 42);
    defer big.deinit();

    const cases = [_]Value{
        value_mod.stringValue("s"),
        value_mod.symbolValue("sym"),
        .{ .doc_string = "doc" },
        .{ .bignum = .{ .big = &big } },
        .{ .template = &segments },
        .{ .stack_effect = .{ .inputs = &.{}, .outputs = &.{} } },
    };
    for (cases) |v| try testing.expect(!valueShareable(v, testing.allocator));
}

test "valueShareable: mutable containers, composites, and code values do not qualify" {
    const vec = try value_mod.Vector.create(testing.allocator);
    defer vec.header.release();
    const mm = try value_mod.MutableMap.create(testing.allocator);
    defer mm.header.release();
    const ba = try value_mod.ByteArray.create(testing.allocator);
    defer ba.header.release();

    try testing.expect(!valueShareable(.{ .vector = vec }, testing.allocator));
    try testing.expect(!valueShareable(.{ .mutable_map = mm }, testing.allocator));
    try testing.expect(!valueShareable(.{ .byte_array = ba }, testing.allocator));

    var dummy_vt: value_mod.VirtualType = undefined;
    var imm_inner: Value = .{ .fixnum = 4 };
    try testing.expect(!valueShareable(.{ .tagged = .{ .tag = &dummy_vt, .inner = &imm_inner } }, testing.allocator));

    var fields = [_]Value{.{ .fixnum = 1 }};
    var st = value_mod.StructType{ .name = "box", .fields = &.{"data"} };
    var inst = value_mod.StructInstance{ .struct_type = &st, .fields = &fields };
    try testing.expect(!valueShareable(.{ .struct_instance = &inst }, testing.allocator));

    const quot = value_mod.Quotation{
        .instructions = &.{},
        .effect = null,
        .code_ptr = null,
    };
    try testing.expect(!valueShareable(.{ .quotation = quot }, testing.allocator));

    var items = [_]Value{.{ .fixnum = 1 }};
    var it = Iterator{ .header = undefined, .kind = .{ .array = .{ .items = &items, .index = 0 } } };
    try testing.expect(!valueShareable(.{ .iterator = &it }, testing.allocator));
}

test "valueShareable: heap-backed leaves qualify and off-allocator backings do not" {
    const s = try value_mod.ownedStringValue(testing.allocator, try testing.allocator.dupe(u8, "s"));
    defer releaseValue(s);
    try testing.expect(valueShareable(s, testing.allocator));

    const sym = try value_mod.ownedSymbolValue(testing.allocator, try testing.allocator.dupe(u8, "sym"));
    defer releaseValue(sym);
    try testing.expect(valueShareable(sym, testing.allocator));

    const big = try value_mod.BigIntManaged.initSet(testing.allocator, 42);
    const bn = try value_mod.ownedBignumValue(testing.allocator, big);
    defer releaseValue(bn);
    try testing.expect(valueShareable(bn, testing.allocator));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const foreign = try value_mod.ownedStringValue(arena.allocator(), try arena.allocator().dupe(u8, "f"));
    try testing.expect(!valueShareable(foreign, testing.allocator));
    releaseValue(foreign);
}

test "valueShareable: backed tagged follows its inner value and memoizes" {
    var dummy_vt: value_mod.VirtualType = undefined;

    const ok = try value_mod.ownedTaggedValue(testing.allocator, &dummy_vt, .{ .fixnum = 4 });
    defer releaseValue(ok);
    try testing.expectEqual(Shareable.unknown, ok.tagged.backing.?.header.shareableState());
    try testing.expect(valueShareable(ok, testing.allocator));
    try testing.expectEqual(Shareable.shareable, ok.tagged.backing.?.header.shareableState());

    const blocked = try value_mod.ownedTaggedValue(testing.allocator, &dummy_vt, value_mod.stringValue("s"));
    defer releaseValue(blocked);
    try testing.expect(!valueShareable(blocked, testing.allocator));
    try testing.expectEqual(Shareable.not_shareable, blocked.tagged.backing.?.header.shareableState());
}

test "valueShareable: heap-backed string elements allow array sharing" {
    const items = try testing.allocator.alloc(Value, 1);
    items[0] = try value_mod.ownedStringValue(testing.allocator, try testing.allocator.dupe(u8, "s"));
    const arr = try value_mod.Array.fromOwnedSlice(testing.allocator, items);
    defer releaseValue(.{ .array = arr });

    try testing.expect(valueShareable(.{ .array = arr }, testing.allocator));
    try testing.expectEqual(Shareable.shareable, arr.header.shareableState());
}

test "valueShareable: owned array of scalars qualifies and memoizes" {
    const inner_items = try testing.allocator.alloc(Value, 1);
    inner_items[0] = .{ .fixnum = 7 };
    const inner = try value_mod.Array.fromOwnedSlice(testing.allocator, inner_items);

    const items = try testing.allocator.alloc(Value, 2);
    items[0] = .{ .float = 2.0 };
    // The outer slot takes the inner's creation reference.
    items[1] = .{ .array = inner };
    const arr = try value_mod.Array.fromOwnedSlice(testing.allocator, items);
    defer releaseValue(.{ .array = arr });

    try testing.expectEqual(Shareable.unknown, inner.header.shareableState());
    try testing.expect(valueShareable(.{ .array = arr }, testing.allocator));
    try testing.expectEqual(Shareable.shareable, arr.header.shareableState());
    try testing.expectEqual(Shareable.shareable, inner.header.shareableState());
}

test "valueShareable: string elements and off-allocator backing block array sharing" {
    const items = try testing.allocator.alloc(Value, 1);
    items[0] = value_mod.stringValue("s");
    const arr = try value_mod.Array.fromOwnedSlice(testing.allocator, items);
    defer releaseValue(.{ .array = arr });
    try testing.expect(!valueShareable(.{ .array = arr }, testing.allocator));
    try testing.expectEqual(Shareable.not_shareable, arr.header.shareableState());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arena_items = try arena.allocator().alloc(Value, 1);
    arena_items[0] = .{ .fixnum = 1 };
    const arena_arr = try value_mod.Array.fromOwnedSlice(arena.allocator(), arena_items);
    try testing.expect(!valueShareable(.{ .array = arena_arr }, testing.allocator));
    releaseValue(.{ .array = arena_arr });
}

test "valueShareable: static arrays classify not-shareable even on the long-lived allocator" {
    const items = try testing.allocator.alloc(Value, 1);
    items[0] = .{ .fixnum = 1 };
    const arr = try value_mod.Array.createStatic(testing.allocator, items);
    // Static destroy is a no-op, so the test owns the memory.
    defer testing.allocator.destroy(arr);
    defer testing.allocator.free(items);

    try testing.expect(!valueShareable(.{ .array = arr }, testing.allocator));
    try testing.expectEqual(Shareable.not_shareable, arr.header.shareableState());
}

test "valueShareable: hash and set of scalars qualify" {
    const h = try value_mod.HashTable.create(testing.allocator);
    defer releaseValue(.{ .hash = h });
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), .{ .fixnum = 1 });
    try testing.expect(valueShareable(.{ .hash = h }, testing.allocator));

    const s = try value_mod.Set.create(testing.allocator);
    defer releaseValue(.{ .set = s });
    try s.map.put(s.header.allocator, .{ .fixnum = 3 }, {});
    try testing.expect(valueShareable(.{ .set = s }, testing.allocator));
}

test "valueShareable: string values and mutable elements block sharing" {
    const h = try value_mod.HashTable.create(testing.allocator);
    defer releaseValue(.{ .hash = h });
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), value_mod.stringValue("v"));
    try testing.expect(!valueShareable(.{ .hash = h }, testing.allocator));

    const vec = try value_mod.Vector.create(testing.allocator);
    defer vec.header.release();

    const h2 = try value_mod.HashTable.create(testing.allocator);
    defer releaseValue(.{ .hash = h2 });
    // The hash slot owns its own reference; destroy releases it.
    retainValue(.{ .vector = vec });
    try h2.map.put(h2.header.allocator, try h2.header.allocator.dupe(u8, "m"), .{ .vector = vec });
    try testing.expect(!valueShareable(.{ .hash = h2 }, testing.allocator));

    const s = try value_mod.Set.create(testing.allocator);
    defer releaseValue(.{ .set = s });
    try s.map.put(s.header.allocator, value_mod.stringValue("member"), {});
    try testing.expect(!valueShareable(.{ .set = s }, testing.allocator));
}

test "valueShareable: nested hash recursion populates the inner memo" {
    const inner = try value_mod.HashTable.create(testing.allocator);
    const inner_alloc = inner.header.allocator;
    try inner.map.put(inner_alloc, try inner_alloc.dupe(u8, "n"), .{ .fixnum = 2 });

    const outer = try value_mod.HashTable.create(testing.allocator);
    defer releaseValue(.{ .hash = outer });
    const outer_alloc = outer.header.allocator;
    // The outer slot takes the inner's creation reference.
    try outer.map.put(outer_alloc, try outer_alloc.dupe(u8, "inner"), .{ .hash = inner });

    try testing.expectEqual(Shareable.unknown, inner.header.shareableState());
    try testing.expect(valueShareable(.{ .hash = outer }, testing.allocator));
    try testing.expectEqual(Shareable.shareable, inner.header.shareableState());
    try testing.expectEqual(Shareable.shareable, outer.header.shareableState());
}

test "valueShareable: backing off the long-lived allocator does not share" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const h = try value_mod.HashTable.create(arena.allocator());
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), .{ .fixnum = 1 });

    try testing.expect(!valueShareable(.{ .hash = h }, testing.allocator));
    try testing.expectEqual(Shareable.not_shareable, h.header.shareableState());
    releaseValue(.{ .hash = h });
}

test "memoShareable: scans once and memoizes in the header" {
    const h = try value_mod.HashTable.create(testing.allocator);
    defer releaseValue(.{ .hash = h });
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), .{ .fixnum = 1 });

    try testing.expectEqual(Shareable.unknown, h.header.shareableState());
    try testing.expect(memoShareable(&h.header, .{ .hash = h }, testing.allocator));
    try testing.expectEqual(Shareable.shareable, h.header.shareableState());

    // Repeat calls answer from the memo, not a rescan: contents made
    // contradictory after the state is recorded do not change the answer.
    // Test-only mutation; real hashes are immutable after construction.
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "s"), value_mod.stringValue("v"));
    try testing.expect(memoShareable(&h.header, .{ .hash = h }, testing.allocator));
}

test "memoShareable: records a not-shareable verdict" {
    const h = try value_mod.HashTable.create(testing.allocator);
    defer releaseValue(.{ .hash = h });
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), value_mod.stringValue("v"));

    try testing.expect(!memoShareable(&h.header, .{ .hash = h }, testing.allocator));
    try testing.expectEqual(Shareable.not_shareable, h.header.shareableState());
    try testing.expect(!memoShareable(&h.header, .{ .hash = h }, testing.allocator));
}

const MemoWorkerArgs = struct {
    hash: *value_mod.HashTable,
    iters: u32,
};

fn memoWorker(args: MemoWorkerArgs) void {
    var i: u32 = 0;
    while (i < args.iters) : (i += 1) {
        std.debug.assert(memoShareable(&args.hash.header, .{ .hash = args.hash }, testing.allocator));
    }
}

test "memoShareable: concurrent callers converge on one state" {
    const h = try value_mod.HashTable.create(testing.allocator);
    defer releaseValue(.{ .hash = h });
    const h_alloc = h.header.allocator;
    try h.map.put(h_alloc, try h_alloc.dupe(u8, "k"), .{ .fixnum = 1 });

    const thread_count: u32 = 4;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, memoWorker, .{MemoWorkerArgs{
            .hash = h,
            .iters = 1_000,
        }});
    }
    for (threads) |t| t.join();

    try testing.expectEqual(Shareable.shareable, h.header.shareableState());
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
