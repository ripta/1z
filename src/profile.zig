const std = @import("std");
const BenchmarkStats = @import("benchmark.zig").BenchmarkStats;

/// Configuration for word-attributed profile mode.
pub const ProfileConfig = struct {
    enabled: bool = false,
    top_n: usize = 20,
};

/// One recorded word dispatch: the word's name, the start timestamp at
/// dispatch entry, and the end timestamp once execution returned.
pub const ProfileSample = struct {
    name: []const u8,
    start_ns: i128,
    end_ns: i128,
};

/// Aggregate counters for a single word across all dispatches.
pub const WordAggregate = struct {
    calls: u64 = 0,
    /// Inclusive time: total wall time spent in dispatches of this word,
    /// including time inside callees. Sum of (end_ns - start_ns) across
    /// every recorded sample. Recursive words can exceed wall time here.
    total_ns: i128 = 0,
    /// Exclusive time: total wall time minus the time spent inside direct
    /// callees. Computed per-call as (end-start) minus the sum of direct
    /// child sample durations, then summed across all dispatches.
    self_ns: i128 = 0,
};

/// Per-context profile state. Holds raw begin/end timestamp pairs for every
/// word dispatch when `--profile` is set.
pub const ProfileStats = struct {
    samples: std.ArrayListUnmanaged(ProfileSample) = .{},
    pending_starts: std.ArrayListUnmanaged(i128) = .{},

    /// Push a start timestamp onto the pending stack. Called from the
    /// `call_word` instrumentation point in `executeInstructions`.
    pub fn recordWordStart(self: *ProfileStats, alloc: std.mem.Allocator) void {
        const now = std.time.nanoTimestamp();
        self.pending_starts.append(alloc, now) catch {};
    }

    /// Pop the matching start and emit a completed sample. Called from
    /// `wordSuccessCleanup`, `wordErrorCleanup`, and the JIT/tail-call
    /// completion paths in `executeInstructions`.
    pub fn recordWordEnd(self: *ProfileStats, alloc: std.mem.Allocator, name: []const u8) void {
        if (self.pending_starts.items.len == 0) return;
        const start_ns = self.pending_starts.pop() orelse return;
        const end_ns = std.time.nanoTimestamp();
        self.samples.append(alloc, .{
            .name = name,
            .start_ns = start_ns,
            .end_ns = end_ns,
        }) catch {};
    }

    pub fn deinit(self: *ProfileStats, alloc: std.mem.Allocator) void {
        self.samples.deinit(alloc);
        self.pending_starts.deinit(alloc);
    }

    /// Walk the close-order sample buffer and aggregate per-word counters.
    /// Caller owns the returned map and must call `deinit` on it.
    ///
    /// Self-time is the per-call duration minus the sum of direct child
    /// durations, computed by a single forward pass with an "available
    /// siblings" stack. Samples are appended at dispatch end, so a parent
    /// always appears after all its descendants in the buffer; the parent's
    /// direct children are the contiguous suffix of the stack whose
    /// `[start_ns, end_ns]` falls inside the parent's window.
    pub fn aggregate(
        self: *const ProfileStats,
        alloc: std.mem.Allocator,
    ) !std.StringHashMapUnmanaged(WordAggregate) {
        var map: std.StringHashMapUnmanaged(WordAggregate) = .{};
        errdefer map.deinit(alloc);

        // Stack of indices into `samples` that have not yet been claimed
        // as a child of a later parent sample.
        var stack: std.ArrayListUnmanaged(usize) = .{};
        defer stack.deinit(alloc);

        for (self.samples.items, 0..) |s, i| {
            const total_ns = s.end_ns - s.start_ns;
            var child_sum_ns: i128 = 0;

            while (stack.items.len > 0) {
                const top_idx = stack.items[stack.items.len - 1];
                const top = self.samples.items[top_idx];
                const contained = top.start_ns >= s.start_ns and top.end_ns <= s.end_ns;
                if (!contained) break;
                child_sum_ns += top.end_ns - top.start_ns;
                _ = stack.pop();
            }

            const self_ns = total_ns - child_sum_ns;

            const gop = try map.getOrPut(alloc, s.name);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.calls += 1;
            gop.value_ptr.total_ns += total_ns;
            gop.value_ptr.self_ns += self_ns;

            try stack.append(alloc, i);
        }

        return map;
    }

    /// One row in the formatted output, paired with its sort key.
    const Row = struct {
        name: []const u8,
        agg: WordAggregate,
    };

    fn rowLessThan(_: void, a: Row, b: Row) bool {
        return a.agg.total_ns > b.agg.total_ns;
    }

    /// Render a flat top-N table sorted by total time descending. Writes
    /// nothing when no samples were recorded. Mirrors the visual style of
    /// `BenchmarkStats.formatHuman` so `--benchmark` and `--profile`
    /// outputs read consistently when both flags are set.
    pub fn formatHuman(
        self: *const ProfileStats,
        alloc: std.mem.Allocator,
        writer: anytype,
        top_n: usize,
    ) !void {
        if (self.samples.items.len == 0) return;

        var map = try self.aggregate(alloc);
        defer map.deinit(alloc);

        var rows: std.ArrayListUnmanaged(Row) = .{};
        defer rows.deinit(alloc);
        try rows.ensureTotalCapacity(alloc, map.count());

        var iter = map.iterator();
        while (iter.next()) |e| {
            rows.appendAssumeCapacity(.{ .name = e.key_ptr.*, .agg = e.value_ptr.* });
        }

        std.mem.sort(Row, rows.items, {}, rowLessThan);

        const display_count = @min(rows.items.len, top_n);

        try writer.print(
            "\n=== Word Profile (top {d} by total time) ===\n",
            .{display_count},
        );
        try writer.writeAll("  Word                   Calls    Total time     Self time   Time/call\n");

        for (rows.items[0..display_count]) |row| {
            try writer.print("  {s:<22} ", .{row.name});
            try BenchmarkStats.formatNumber(writer, row.agg.calls);
            // Pad calls column to a stable width.
            const calls_width: usize = countDigitsWithCommas(row.agg.calls);
            const calls_pad: usize = if (calls_width < 8) 8 - calls_width else 0;
            try writeSpaces(writer, calls_pad + 2);

            try formatTimeFixed(writer, row.agg.total_ns, 13);
            try writer.writeAll("  ");
            try formatTimeFixed(writer, row.agg.self_ns, 12);
            try writer.writeAll("  ");
            const per_call_ns: i128 = if (row.agg.calls > 0)
                @divTrunc(row.agg.total_ns, @as(i128, @intCast(row.agg.calls)))
            else
                0;
            try formatTimeFixed(writer, per_call_ns, 10);
            try writer.writeAll("\n");
        }
    }
};

fn writeSpaces(writer: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try writer.writeByte(' ');
}

fn countDigitsWithCommas(n: u64) usize {
    if (n == 0) return 1;
    var digits: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) digits += 1;
    const commas = if (digits > 3) (digits - 1) / 3 else 0;
    return digits + commas;
}

/// Right-align a `formatTime` rendering into a fixed-width column.
fn formatTimeFixed(writer: anytype, ns: i128, width: usize) !void {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try BenchmarkStats.formatTime(stream.writer(), ns);
    const text = stream.getWritten();
    if (text.len < width) try writeSpaces(writer, width - text.len);
    try writer.writeAll(text);
}

test "recordWordStart and recordWordEnd produce one paired sample" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    stats.recordWordStart(alloc);
    stats.recordWordEnd(alloc, "+");

    try std.testing.expectEqual(@as(usize, 1), stats.samples.items.len);
    try std.testing.expectEqual(@as(usize, 0), stats.pending_starts.items.len);
    try std.testing.expectEqualStrings("+", stats.samples.items[0].name);
    try std.testing.expect(stats.samples.items[0].end_ns >= stats.samples.items[0].start_ns);
}

test "nested word dispatches produce stacked samples in close-order" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    stats.recordWordStart(alloc); // outer
    stats.recordWordStart(alloc); // inner
    stats.recordWordEnd(alloc, "inner");
    stats.recordWordEnd(alloc, "outer");

    try std.testing.expectEqual(@as(usize, 2), stats.samples.items.len);
    try std.testing.expectEqualStrings("inner", stats.samples.items[0].name);
    try std.testing.expectEqualStrings("outer", stats.samples.items[1].name);
    try std.testing.expect(stats.samples.items[1].start_ns <= stats.samples.items[0].start_ns);
    try std.testing.expect(stats.samples.items[1].end_ns >= stats.samples.items[0].end_ns);
}

test "recordWordEnd without a matching start is a no-op" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    stats.recordWordEnd(alloc, "orphan");

    try std.testing.expectEqual(@as(usize, 0), stats.samples.items.len);
}

// Helper for aggregation tests: append a synthetic sample directly.
fn pushSample(stats: *ProfileStats, alloc: std.mem.Allocator, name: []const u8, start_ns: i128, end_ns: i128) !void {
    try stats.samples.append(alloc, .{ .name = name, .start_ns = start_ns, .end_ns = end_ns });
}

test "aggregate over empty buffer returns empty map" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    var map = try stats.aggregate(alloc);
    defer map.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 0), map.count());
}

test "aggregate of a single sample yields total == self" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);
    try pushSample(&stats, alloc, "+", 100, 200);

    var map = try stats.aggregate(alloc);
    defer map.deinit(alloc);
    const a = map.get("+") orelse unreachable;
    try std.testing.expectEqual(@as(u64, 1), a.calls);
    try std.testing.expectEqual(@as(i128, 100), a.total_ns);
    try std.testing.expectEqual(@as(i128, 100), a.self_ns);
}

test "aggregate sums two siblings independently" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);
    // Two non-overlapping calls to `dup`.
    try pushSample(&stats, alloc, "dup", 0, 50);
    try pushSample(&stats, alloc, "dup", 60, 130);

    var map = try stats.aggregate(alloc);
    defer map.deinit(alloc);
    const a = map.get("dup") orelse unreachable;
    try std.testing.expectEqual(@as(u64, 2), a.calls);
    try std.testing.expectEqual(@as(i128, 50 + 70), a.total_ns);
    try std.testing.expectEqual(@as(i128, 50 + 70), a.self_ns);
}

test "aggregate parent + child nets child time out of parent self_ns" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);
    // outer [0..100], inner [20..70] -> outer.self = 100 - 50 = 50.
    try pushSample(&stats, alloc, "inner", 20, 70);
    try pushSample(&stats, alloc, "outer", 0, 100);

    var map = try stats.aggregate(alloc);
    defer map.deinit(alloc);
    const inner = map.get("inner") orelse unreachable;
    const outer = map.get("outer") orelse unreachable;
    try std.testing.expectEqual(@as(i128, 50), inner.total_ns);
    try std.testing.expectEqual(@as(i128, 50), inner.self_ns);
    try std.testing.expectEqual(@as(i128, 100), outer.total_ns);
    try std.testing.expectEqual(@as(i128, 50), outer.self_ns);
}

test "aggregate parent with two direct children sums both child durations" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);
    // outer [0..100]; child a [10..30] (20 ns); child b [40..80] (40 ns).
    try pushSample(&stats, alloc, "a", 10, 30);
    try pushSample(&stats, alloc, "b", 40, 80);
    try pushSample(&stats, alloc, "outer", 0, 100);

    var map = try stats.aggregate(alloc);
    defer map.deinit(alloc);
    const outer = map.get("outer") orelse unreachable;
    try std.testing.expectEqual(@as(i128, 100), outer.total_ns);
    try std.testing.expectEqual(@as(i128, 100 - 20 - 40), outer.self_ns);
}

test "aggregate handles recursion by accumulating each call independently" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);
    // f calls f recursively: outer [0..100], inner [20..80].
    // outer.total=100, outer.self=100-60=40
    // inner.total=60, inner.self=60-0=60
    // aggregate "f": calls=2, total=160, self=100
    try pushSample(&stats, alloc, "f", 20, 80);
    try pushSample(&stats, alloc, "f", 0, 100);

    var map = try stats.aggregate(alloc);
    defer map.deinit(alloc);
    const a = map.get("f") orelse unreachable;
    try std.testing.expectEqual(@as(u64, 2), a.calls);
    try std.testing.expectEqual(@as(i128, 160), a.total_ns);
    try std.testing.expectEqual(@as(i128, 100), a.self_ns);
}

test "formatHuman on empty buffer writes nothing" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try stats.formatHuman(alloc, stream.writer(), 20);
    try std.testing.expectEqual(@as(usize, 0), stream.getWritten().len);
}

test "formatHuman emits header, columns, and rows in total-time order" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);
    // slow takes 1ms, fast takes 100us, faster takes 10us.
    try pushSample(&stats, alloc, "fast", 0, 100_000);
    try pushSample(&stats, alloc, "faster", 200_000, 210_000);
    try pushSample(&stats, alloc, "slow", 300_000, 1_300_000);

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try stats.formatHuman(alloc, stream.writer(), 20);
    const out = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, out, "=== Word Profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Total time") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Self time") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Time/call") != null);

    const slow_pos = std.mem.indexOf(u8, out, "slow") orelse unreachable;
    const fast_pos = std.mem.indexOf(u8, out, "fast") orelse unreachable;
    const faster_pos = std.mem.indexOf(u8, out, "faster") orelse unreachable;
    try std.testing.expect(slow_pos < fast_pos);
    try std.testing.expect(fast_pos < faster_pos);
}

test "formatHuman top_n caps the number of rows" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);
    try pushSample(&stats, alloc, "a", 0, 1000);
    try pushSample(&stats, alloc, "b", 1000, 1500);
    try pushSample(&stats, alloc, "c", 1500, 1700);

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try stats.formatHuman(alloc, stream.writer(), 2);
    const out = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, out, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b") != null);
    // "c" is the smallest by total_ns, so it should not appear when top_n=2.
    try std.testing.expect(std.mem.indexOf(u8, out, " c ") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(top 2 by total time)") != null);
}
