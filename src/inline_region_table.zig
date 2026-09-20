const std = @import("std");
const builtin = @import("builtin");

const AtomicSlotMap = @import("atomic_slot_map.zig").AtomicSlotMap;

/// A run of instructions in an expanded body that was copied out of another word, and the word it
/// came from.
///
/// `body_source` is the file that code was written in, which is not the expanded body's own file
/// once a word is inlined across a module boundary. `call_line` and `call_column` locate the call
/// this run replaced, in the coordinates of whatever body held that call.
///
/// No declared effect rides here. An entry is permanent while a frame-held callee's boxed effect
/// is not. Nothing is lost, because the effect renders on the innermost error row only, and a
/// synthesized frame never is one.
pub const InlineRegion = struct {
    start: u32,
    end: u32,
    word_name: []const u8,
    body_source: []const u8,
    call_line: u32,
    call_column: u32,

    pub fn contains(self: InlineRegion, index: usize) bool {
        return index >= self.start and index < self.end;
    }

    /// Whether `self` covers every index `inner` covers. The recorded order relies on it.
    pub fn encloses(self: InlineRegion, inner: InlineRegion) bool {
        return self.start <= inner.start and self.end >= inner.end;
    }
};

/// One error-chain row an inlined run stands in for.
pub const Frame = struct {
    /// The word whose code the failing instruction belongs to.
    word_name: []const u8,

    /// The file that word's code was written in. A line inside the run is a line in this file,
    /// not in the file of the body the run was copied into.
    body_source: []const u8,

    /// Where the call this run replaced sat, and the file that call site's line belongs to.
    call_source: []const u8,
    call_line: u32,
    call_column: u32,
};

/// The inlined runs of one expanded body, innermost first for any index they share.
///
/// Boxed so the map's atomic slot holds one pointer.
pub const InlineRegionSet = struct {
    regions: []const InlineRegion,

    /// The rows an error at `index` needs, innermost first.
    ///
    /// `body_file` is the file of the body these runs were copied into, which is where the
    /// outermost run's own call site sits.
    pub fn framesAt(self: InlineRegionSet, index: usize, body_file: []const u8) FrameIterator {
        return .{ .set = self, .index = index, .body_file = body_file };
    }

    pub const FrameIterator = struct {
        set: InlineRegionSet,
        index: usize,
        body_file: []const u8,
        at: usize = 0,

        pub fn next(self: *FrameIterator) ?Frame {
            while (self.at < self.set.regions.len) {
                const r = self.set.regions[self.at];
                self.at += 1;
                if (!r.contains(self.index)) continue;

                return .{
                    .word_name = r.word_name,
                    .body_source = r.body_source,
                    .call_source = self.enclosingFile(),
                    .call_line = r.call_line,
                    .call_column = r.call_column,
                };
            }
            return null;
        }

        /// The file the run at `at - 1` was called from: the next run out, or the body itself.
        ///
        /// Two runs covering one index are always nested, because a run is either one
        /// instruction's whole expansion or a range translated out of the body being copied. The
        /// recording order then puts the inner one first, so the next covering run is the
        /// enclosing one.
        fn enclosingFile(self: FrameIterator) []const u8 {
            for (self.set.regions[self.at..]) |outer| {
                if (outer.contains(self.index)) return outer.body_source;
            }
            return self.body_file;
        }
    };
};

/// Process-shared map from an expanded body's instruction-slice pointer to the runs inside it that
/// were copied out of `inline`-marked words.
///
/// Expansion erases a call, so the callee's frame no longer exists to be pushed and its row
/// vanishes from every trace. This table is what puts the row back: the error path looks up the
/// failing instruction's index, and synthesizes one frame per run covering it. Nothing reads the
/// table while a program is running normally.
///
/// Only the expansion pass fills it, so a body no `inline` word reached has no entry, and the
/// overwhelming majority of programs leave the table empty.
///
/// Entries are permanent, so only process-lifetime keys may enter: a body built on a task or
/// scoped-eval arena dies with it and would leave a key that a later unrelated allocation at the
/// same address falsely matches. `Context.recordInlineRegions` applies that gate.
///
/// The table is allocated by the root context, aliased by pointer into every child, and freed only
/// by the root.
///
/// Reads take no lock. Writers serialize on `write_mu` and apply first-record-wins, which is what
/// a repeated expansion of the same slice would write anyway.
pub const InlineRegionTable = struct {
    /// Key `0` marks an empty slot in the map and is never a real key:
    /// `Context.recordInlineRegions` skips zero-length instruction slices, which are the only
    /// bodies whose `.ptr` could be a shared sentinel.
    map: AtomicSlotMap(?*const InlineRegionSet),

    /// Owns every published region list, its box, and the names and file paths inside it. A
    /// callee's name can belong to a local frame and a file path to a module load's caller, so
    /// neither may be aliased. Entries are never removed, so the whole arena is released at
    /// `destroy`. Only valid under `write_mu`: an arena is not thread-safe.
    arena: std.heap.ArenaAllocator,

    write_mu: std.Thread.Mutex = .{},

    /// Only an expanded body takes a slot, which is a handful per program that uses the marker at
    /// all, so this starts far below the every-parsed-body tables beside it.
    const initial_capacity: usize = 64;

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*InlineRegionTable {
        var map = try AtomicSlotMap(?*const InlineRegionSet).init(allocator, initial_capacity);
        errdefer map.deinit();

        const self = try allocator.create(InlineRegionTable);
        self.* = .{
            .map = map,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *InlineRegionTable) void {
        const allocator = self.map.allocator;
        self.map.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// The inlined runs of the body at `key`, or null when the body has none recorded.
    ///
    /// One acquire load plus one probe, no lock. This runs on the error path only.
    pub fn lookup(self: *const InlineRegionTable, key: usize) ?InlineRegionSet {
        const set = self.map.lookup(key) orelse return null;
        return set.*;
    }

    /// Record `regions` at `key`, unless the body already carries a set.
    ///
    /// The regions are copied, along with the strings they point at.
    pub fn record(self: *InlineRegionTable, key: usize, regions: []const InlineRegion) error{OutOfMemory}!void {
        std.debug.assert(key != 0);
        if (regions.len == 0) return;

        self.write_mu.lock();
        defer self.write_mu.unlock();

        if (self.map.lookup(key) != null) return;

        assertNested(regions);

        const alloc = self.arena.allocator();
        const owned = try alloc.alloc(InlineRegion, regions.len);
        for (regions, owned) |src, *dst| {
            dst.* = src;
            dst.word_name = try alloc.dupe(u8, src.word_name);
            dst.body_source = try alloc.dupe(u8, src.body_source);
        }

        const set = try alloc.create(InlineRegionSet);
        set.* = .{ .regions = owned };
        _ = try self.map.insert(key, set);
    }

    /// Occupied slot count. Diagnostics and tests.
    pub fn count(self: *InlineRegionTable) usize {
        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.map.count();
    }

    /// Published table capacity. Diagnostics and tests; racy against a concurrent growth.
    pub fn capacity(self: *const InlineRegionTable) usize {
        return self.map.capacity();
    }
};

/// Every pair of overlapping runs is nested, with the inner one first.
///
/// `FrameIterator` reads a list in order and takes the next covering run as the enclosing one, so
/// a list that broke this would report a frame's call site against the wrong file. The choke point
/// is `record`, the one place a set is published; the expander's recording order is what has to
/// hold it, in `Expander.appendBody` and `Expander.recordRegion`.
fn assertNested(regions: []const InlineRegion) void {
    if (comptime builtin.mode != .Debug) return;

    for (regions, 0..) |inner, i| {
        for (regions[i + 1 ..]) |outer| {
            if (outer.end <= inner.start or outer.start >= inner.end) continue;
            std.debug.assert(outer.encloses(inner));
        }
    }
}

const testing = std.testing;

fn region(start: u32, end: u32, name: []const u8, source: []const u8, line: u32) InlineRegion {
    return .{
        .start = start,
        .end = end,
        .word_name = name,
        .body_source = source,
        .call_line = line,
        .call_column = 0,
    };
}

test "InlineRegionTable: a recorded body resolves and an unrecorded one misses" {
    const table = try InlineRegionTable.create(testing.allocator);
    defer table.destroy();

    try testing.expect(table.lookup(0x1000) == null);

    try table.record(0x1000, &.{region(0, 2, "doubled", "a.1z", 7)});

    const set = table.lookup(0x1000) orelse return error.TestExpectedEntry;
    try testing.expectEqual(@as(usize, 1), set.regions.len);
    try testing.expectEqualStrings("doubled", set.regions[0].word_name);
    try testing.expectEqualStrings("a.1z", set.regions[0].body_source);
    try testing.expectEqual(@as(u32, 7), set.regions[0].call_line);

    try testing.expect(table.lookup(0x2000) == null);
    try testing.expect(table.lookup(0) == null);
    try testing.expectEqual(@as(usize, 1), table.count());
}

test "InlineRegionTable: an empty region list takes no slot" {
    const table = try InlineRegionTable.create(testing.allocator);
    defer table.destroy();

    try table.record(0x1000, &.{});

    try testing.expect(table.lookup(0x1000) == null);
    try testing.expectEqual(@as(usize, 0), table.count());
}

test "InlineRegionTable: the names and paths are copied, not aliased" {
    const table = try InlineRegionTable.create(testing.allocator);
    defer table.destroy();

    // A callee's name can belong to a local frame, and a file path to the caller of a module
    // load. Both are overwritten here to stand in for that.
    var name = "doubled".*;
    var source = "a.1z".*;
    try table.record(0x1000, &.{region(0, 2, &name, &source, 7)});
    @memset(&name, 'x');
    @memset(&source, 'x');

    const set = table.lookup(0x1000) orelse return error.TestExpectedEntry;
    try testing.expectEqualStrings("doubled", set.regions[0].word_name);
    try testing.expectEqualStrings("a.1z", set.regions[0].body_source);
}

test "InlineRegionTable: the first record wins" {
    const table = try InlineRegionTable.create(testing.allocator);
    defer table.destroy();

    try table.record(0x1000, &.{region(0, 2, "first", "a.1z", 1)});
    try table.record(0x1000, &.{region(0, 2, "second", "a.1z", 2)});

    const set = table.lookup(0x1000) orelse return error.TestExpectedEntry;
    try testing.expectEqualStrings("first", set.regions[0].word_name);
    try testing.expectEqual(@as(usize, 1), table.count());
}

test "InlineRegionTable: growth preserves every entry" {
    const table = try InlineRegionTable.create(testing.allocator);
    defer table.destroy();

    const entries: usize = 500;
    var key: usize = 1;
    while (key <= entries) : (key += 1) {
        try table.record(key * 8, &.{region(0, 1, if (key % 2 == 0) "even" else "odd", "a.1z", 1)});
    }

    key = 1;
    while (key <= entries) : (key += 1) {
        const expected: []const u8 = if (key % 2 == 0) "even" else "odd";
        const set = table.lookup(key * 8) orelse return error.TestExpectedEntry;
        try testing.expectEqualStrings(expected, set.regions[0].word_name);
    }

    try testing.expectEqual(entries, table.count());
    try testing.expect(table.capacity() > InlineRegionTable.initial_capacity);

    // A missing key walks its collision run and falls off the end rather than looping, which is
    // what the load factor's spare slots buy.
    try testing.expect(table.lookup(0x7fff_ffff) == null);
}

test "InlineRegionSet: framesAt yields the nested runs innermost first" {
    const set: InlineRegionSet = .{ .regions = &.{
        region(0, 1, "one", "one.1z", 2),
        region(0, 1, "two", "two.1z", 3),
        region(1, 3, "other", "other.1z", 4),
    } };

    var at_zero = set.framesAt(0, "caller.1z");

    const inner = at_zero.next() orelse return error.TestExpectedFrame;
    try testing.expectEqualStrings("one", inner.word_name);
    try testing.expectEqualStrings("one.1z", inner.body_source);
    try testing.expectEqual(@as(u32, 2), inner.call_line);

    // `one`'s call sits inside `two`'s code, so its row names `two`'s file.
    try testing.expectEqualStrings("two.1z", inner.call_source);

    const outer = at_zero.next() orelse return error.TestExpectedFrame;
    try testing.expectEqualStrings("two", outer.word_name);
    try testing.expectEqualStrings("two.1z", outer.body_source);

    // Nothing encloses the outermost run, so its call sits in the body itself.
    try testing.expectEqualStrings("caller.1z", outer.call_source);

    try testing.expect(at_zero.next() == null);
}

test "InlineRegionSet: framesAt skips a run that does not cover the index" {
    const set: InlineRegionSet = .{ .regions = &.{
        region(0, 1, "one", "one.1z", 2),
        region(1, 3, "other", "other.1z", 4),
    } };

    var at_two = set.framesAt(2, "caller.1z");
    const only = at_two.next() orelse return error.TestExpectedFrame;
    try testing.expectEqualStrings("other", only.word_name);
    try testing.expectEqualStrings("caller.1z", only.call_source);
    try testing.expect(at_two.next() == null);

    var at_nine = set.framesAt(9, "caller.1z");
    try testing.expect(at_nine.next() == null);
}
