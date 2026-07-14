const std = @import("std");
const BenchmarkStats = @import("benchmark.zig").BenchmarkStats;
const pprof = @import("pprof.zig");

/// Configuration for word-attributed profile mode.
pub const ProfileConfig = struct {
    enabled: bool = false,
    top_n: usize = 20,
    /// When set, `--profile-out=FILE` writes a gzipped pprof profile here in
    /// addition to the human table. Implies `enabled`.
    out_path: ?[]const u8 = null,
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

    /// Per-sample ancestry recovered from interval containment: the caller's
    /// index (null for a root) and the sample's exclusive self-time.
    const Ancestry = struct {
        parents: []?usize,
        self_ns: []i128,
    };

    /// Recover each sample's caller and exclusive self-time from interval containment.
    ///
    /// The `pending_starts` buffer is a push/pop stack, so every child interval nests strictly
    /// inside its caller. That containment makes both the parent link and the self-time exact.
    fn recoverAncestry(self: *const ProfileStats, alloc: std.mem.Allocator) !Ancestry {
        const n = self.samples.items.len;
        const parents = try alloc.alloc(?usize, n);
        const self_ns = try alloc.alloc(i128, n);

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
                parents[top_idx] = i;
                _ = stack.pop();
            }

            self_ns[i] = total_ns - child_sum_ns;
            parents[i] = null;
            try stack.append(alloc, i);
        }

        return .{ .parents = parents, .self_ns = self_ns };
    }

    /// Build a pprof wire model from the recorded samples.
    ///
    /// Every allocation lands on `alloc`, which the caller reaps in one shot from an arena. Each
    /// interval becomes one sample: a leaf-first ancestor chain of locations, an exclusive
    /// self-time in nanoseconds, and a call count of one. pprof derives the cumulative views from
    /// the stacks.
    fn buildProfile(self: *const ProfileStats, alloc: std.mem.Allocator) !pprof.Profile {
        const ancestry = try self.recoverAncestry(alloc);

        var strings: std.ArrayListUnmanaged([]const u8) = .{};
        try strings.append(alloc, "");

        const wall_type: u64 = strings.items.len;
        try strings.append(alloc, "wall");
        const ns_unit: u64 = strings.items.len;
        try strings.append(alloc, "nanoseconds");
        const calls_type: u64 = strings.items.len;
        try strings.append(alloc, "calls");
        const count_unit: u64 = strings.items.len;
        try strings.append(alloc, "count");

        // Intern word names to a 1-based function id. A location mirrors each
        // function one-to-one, so the location id can reuse the function id.
        var name_ids: std.StringHashMapUnmanaged(u64) = .{};
        var functions: std.ArrayListUnmanaged(pprof.Function) = .{};
        var locations: std.ArrayListUnmanaged(pprof.Location) = .{};

        for (self.samples.items) |s| {
            const gop = try name_ids.getOrPut(alloc, s.name);
            if (gop.found_existing) continue;
            const fid: u64 = functions.items.len + 1;
            gop.value_ptr.* = fid;
            const name_idx: u64 = strings.items.len;
            try strings.append(alloc, s.name);
            try functions.append(alloc, .{ .id = fid, .name_idx = name_idx });
            try locations.append(alloc, .{ .id = fid, .function_id = fid });
        }

        var samples: std.ArrayListUnmanaged(pprof.Sample) = .{};
        for (self.samples.items, 0..) |_, i| {
            var chain: std.ArrayListUnmanaged(u64) = .{};
            var cur: ?usize = i;
            while (cur) |c| {
                try chain.append(alloc, name_ids.get(self.samples.items[c].name).?);
                cur = ancestry.parents[c];
            }

            const values = try alloc.alloc(i64, 2);
            values[0] = @intCast(ancestry.self_ns[i]);
            values[1] = 1;

            try samples.append(alloc, .{ .location_ids = chain.items, .values = values });
        }

        const sample_types = try alloc.alloc(pprof.ValueType, 2);
        sample_types[0] = .{ .type_idx = wall_type, .unit_idx = ns_unit };
        sample_types[1] = .{ .type_idx = calls_type, .unit_idx = count_unit };

        return .{
            .sample_types = sample_types,
            .samples = samples.items,
            .locations = locations.items,
            .functions = functions.items,
            .string_table = strings.items,
            .default_sample_type = wall_type,
        };
    }

    /// Encode the recorded samples as a gzipped pprof profile, returning bytes owned by `alloc`.
    ///
    /// The wire model is built in a scratch arena that is freed before returning. Only the
    /// encoded bytes survive.
    pub fn exportPprof(self: *const ProfileStats, alloc: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        const profile = try self.buildProfile(arena.allocator());
        return pprof.encode(alloc, profile);
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

/// Resolve a function's id by looking its name up in the built string table.
fn functionIdByName(profile: pprof.Profile, name: []const u8) u64 {
    for (profile.functions) |f| {
        if (std.mem.eql(u8, profile.string_table[f.name_idx], name)) return f.id;
    }
    unreachable;
}

fn containsString(table: []const []const u8, needle: []const u8) bool {
    for (table) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

test "buildProfile emits functions, leaf-first chains, and self-time values" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);
    // outer [0..100], inner [20..70]; close order is inner then outer.
    try pushSample(&stats, alloc, "inner", 20, 70);
    try pushSample(&stats, alloc, "outer", 0, 100);

    const profile = try stats.buildProfile(a);

    try std.testing.expectEqual(@as(usize, 2), profile.functions.len);
    try std.testing.expectEqual(@as(usize, 2), profile.locations.len);
    try std.testing.expectEqual(@as(usize, 2), profile.sample_types.len);
    // pprof opens on the wall axis, the first sample type.
    try std.testing.expectEqual(profile.sample_types[0].type_idx, profile.default_sample_type);

    const inner_fid = functionIdByName(profile, "inner");
    const outer_fid = functionIdByName(profile, "outer");

    // samples[0] is the inner leaf; its chain is [inner, outer] leaf-first.
    try std.testing.expectEqualSlices(u64, &.{ inner_fid, outer_fid }, profile.samples[0].location_ids);
    // samples[1] is the outer root; its chain is just [outer].
    try std.testing.expectEqualSlices(u64, &.{outer_fid}, profile.samples[1].location_ids);

    // Self-times: inner = 50, outer = 100 - 50 = 50. Each carries one call.
    try std.testing.expectEqual(@as(i64, 50), profile.samples[0].values[0]);
    try std.testing.expectEqual(@as(i64, 1), profile.samples[0].values[1]);
    try std.testing.expectEqual(@as(i64, 50), profile.samples[1].values[0]);
    try std.testing.expectEqual(@as(i64, 1), profile.samples[1].values[1]);
}

test "exportPprof round-trips a nested profile through the wire format" {
    const alloc = std.testing.allocator;

    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);
    try pushSample(&stats, alloc, "inner", 20, 70);
    try pushSample(&stats, alloc, "outer", 0, 100);

    const gz = try stats.exportPprof(alloc);
    defer alloc.free(gz);

    const proto = try pprof.inflateStored(alloc, gz);
    defer alloc.free(proto);

    const fields = try pprof.parseFields(alloc, proto);
    defer alloc.free(fields);

    var strings: std.ArrayListUnmanaged([]const u8) = .{};
    defer strings.deinit(alloc);
    var functions: usize = 0;
    var found_leaf_chain = false;

    for (fields) |f| {
        switch (f.number) {
            5 => functions += 1,
            6 => try strings.append(alloc, f.bytes),
            2 => {
                const inner = try pprof.parseFields(alloc, f.bytes);
                defer alloc.free(inner);
                const loc_ids = try pprof.parsePacked(alloc, inner[0].bytes);
                defer alloc.free(loc_ids);
                // The two-frame sample is the inner leaf. Function ids are
                // interned in sample order, so inner is 1 and outer is 2, and
                // the chain must be leaf-first.
                if (loc_ids.len == 2) {
                    found_leaf_chain = true;
                    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, loc_ids);
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), functions);
    try std.testing.expect(found_leaf_chain);
    try std.testing.expect(containsString(strings.items, "inner"));
    try std.testing.expect(containsString(strings.items, "outer"));
}

test "exportPprof on an empty buffer produces a decodable profile with no samples" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    const gz = try stats.exportPprof(alloc);
    defer alloc.free(gz);

    const proto = try pprof.inflateStored(alloc, gz);
    defer alloc.free(proto);

    const fields = try pprof.parseFields(alloc, proto);
    defer alloc.free(fields);

    var samples: usize = 0;
    for (fields) |f| {
        if (f.number == 2) samples += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), samples);
}
