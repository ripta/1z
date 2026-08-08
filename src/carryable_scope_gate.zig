const std = @import("std");

const AtomicSlotMap = @import("atomic_slot_map.zig").AtomicSlotMap;

/// Process-shared set of quotation body instruction-slice pointers that have ever had a carryable
/// captured scope installed in some context's map. A carryable scope is one with at least one
/// lexical frame, which is the predicate `findCapturedScopeForBody` already tests.
///
/// The walk that reaches a scope recorded in an ancestor locks each ancestor's map mutex before it
/// knows whether that ancestor holds anything. Every spawned task shares one parent, so those
/// acquisitions all land on one mutex. This answers the only question the walk has on the
/// overwhelming majority of first visits: could any ancestor hold a carryable scope for this body?
/// Absent means no, and the walk is skipped.
///
/// The set is monotone. Entries are added and never removed, so a mark that outlives the capture it
/// recorded costs one walk that returns null. That makes every error direction the cheap one, and
/// it makes a recycled body pointer safe here, where in `QuotationStampStore` it would be a wrong
/// binding.
///
/// Every writer that installs a carryable scope must mark the key before publishing its entry, so
/// the mark is visible to a descendant's walk no later than the entry is. A writer that publishes
/// without marking silently loses that capture in a descendant task.
///
/// The gate is allocated by the root context, aliased by pointer into every child, and freed only
/// by the root.
///
/// Reads take no lock. Writers serialize on `write_mu`, which is a leaf: every writer marks before
/// taking its own map mutex, so this is never held while another lock is.
pub const CarryableScopeGate = struct {
    /// `AtomicSlotMap` carries a nullable pointer value, and this set has no value to carry. Every
    /// present key maps to `&present`, so membership reads as a non-null lookup.
    map: AtomicSlotMap(?*const anyopaque),
    write_mu: std.Thread.Mutex = .{},

    /// The stored value is never dereferenced. Only its address, which is distinct from null,
    /// carries the membership bit.
    const present: u8 = 0;

    /// Matches the stamp store, whose keys are a superset of these: only a body that captured a
    /// lexical local is marked here.
    const initial_capacity: usize = 64;

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*CarryableScopeGate {
        var map = try AtomicSlotMap(?*const anyopaque).init(allocator, initial_capacity);
        errdefer map.deinit();

        const self = try allocator.create(CarryableScopeGate);
        self.* = .{ .map = map };
        return self;
    }

    pub fn destroy(self: *CarryableScopeGate) void {
        const allocator = self.map.allocator;
        self.map.deinit();
        allocator.destroy(self);
    }

    /// Whether any context has ever installed a carryable scope for the body at `key`.
    ///
    /// One acquire load plus one probe, no lock. An unmarked body is the common case -- every body
    /// that closes over no lexical local -- so this must stay cheap.
    pub fn isMarked(self: *const CarryableScopeGate, key: usize) bool {
        return self.map.lookup(key) != null;
    }

    /// Record that the body at `key` carries a scope, and report whether this call marked it.
    pub fn mark(self: *CarryableScopeGate, key: usize) error{OutOfMemory}!bool {
        std.debug.assert(key != 0);

        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.map.insert(key, &present);
    }

    /// Marked key count. Diagnostics and tests.
    pub fn count(self: *CarryableScopeGate) usize {
        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.map.count();
    }

    /// Published table capacity. Diagnostics and tests; racy against a concurrent growth.
    pub fn capacity(self: *const CarryableScopeGate) usize {
        return self.map.capacity();
    }
};

const testing = std.testing;

test "CarryableScopeGate: a marked body reports present and an unmarked one does not" {
    const gate = try CarryableScopeGate.create(testing.allocator);
    defer gate.destroy();

    try testing.expect(try gate.mark(0x1000));

    try testing.expect(gate.isMarked(0x1000));
    try testing.expect(!gate.isMarked(0x2000));
    try testing.expect(!gate.isMarked(0));
    try testing.expectEqual(@as(usize, 1), gate.count());
}

test "CarryableScopeGate: a repeat mark reports not-marked and leaves the key present" {
    const gate = try CarryableScopeGate.create(testing.allocator);
    defer gate.destroy();

    try testing.expect(try gate.mark(0x1000));
    try testing.expect(!try gate.mark(0x1000));

    try testing.expect(gate.isMarked(0x1000));
    try testing.expectEqual(@as(usize, 1), gate.count());
}

test "CarryableScopeGate: growth preserves every mark" {
    const gate = try CarryableScopeGate.create(testing.allocator);
    defer gate.destroy();

    const entries: usize = 1000;
    var key: usize = 1;
    while (key <= entries) : (key += 1) {
        _ = try gate.mark(key * 8);
    }

    key = 1;
    while (key <= entries) : (key += 1) {
        try testing.expect(gate.isMarked(key * 8));
    }

    try testing.expectEqual(entries, gate.count());
    try testing.expect(gate.capacity() > 64);
    try testing.expect(gate.map.retired.items.len > 0);

    // An unmarked key walks its collision run and falls off the end rather than looping, which is
    // what the load factor's spare slots buy.
    try testing.expect(!gate.isMarked(0x7fff_ffff));
}

const MarkRaceArgs = struct {
    gate: *CarryableScopeGate,
    entries: usize,
    /// Keys `1..published` have completed their `mark` call. Readers only assert on those.
    published: *std.atomic.Value(usize),
    /// Set by whichever thread gives up. Every thread watches it, so one failure ends the run
    /// instead of leaving the others spinning until the harness times out.
    failed: *std.atomic.Value(bool),
};

fn markRaceWriter(args: MarkRaceArgs) void {
    var key: usize = 1;
    while (key <= args.entries) : (key += 1) {
        _ = args.gate.mark(key * 8) catch {
            args.failed.store(true, .release);
            return;
        };
        args.published.store(key, .release);
    }
}

fn markRaceReader(args: MarkRaceArgs) void {
    while (true) {
        if (args.failed.load(.acquire)) return;

        const high = args.published.load(.acquire);
        var key: usize = 1;
        while (key <= high) : (key += 1) {
            if (!args.gate.isMarked(key * 8)) {
                args.failed.store(true, .release);
                return;
            }
        }
        if (high >= args.entries) return;
    }
}

test "CarryableScopeGate: a published mark stays visible to readers across a growth" {
    const gate = try CarryableScopeGate.create(testing.allocator);
    defer gate.destroy();

    const entries: usize = 2000;
    var published = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);

    const args: MarkRaceArgs = .{
        .gate = gate,
        .entries = entries,
        .published = &published,
        .failed = &failed,
    };

    var readers: [3]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, markRaceReader, .{args});
    const writer = try std.Thread.spawn(.{}, markRaceWriter, .{args});

    writer.join();
    for (readers) |t| t.join();

    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(entries, gate.count());
}
