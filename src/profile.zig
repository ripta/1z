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

/// One task's drained profile: the task's samples with their word names copied
/// onto a longer-lived allocator, plus the labels captured at drain time.
///
/// The reaping worker frees the task Context and the dictionary/arena bytes that
/// back a `ProfileSample.name`, so the drain owns duplicated copies here.
pub const TaskProfile = struct {
    samples: std.ArrayListUnmanaged(ProfileSample) = .{},
    task_id: u64 = 0,
    task_name: ?[]const u8 = null,
    worker_id: usize = 0,

    pub fn deinit(self: *TaskProfile, alloc: std.mem.Allocator) void {
        for (self.samples.items) |s| alloc.free(s.name);
        if (self.task_name) |n| alloc.free(n);
        self.samples.deinit(alloc);
    }
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
    /// Buffers drained from reaped task Contexts, one per task, kept separable so
    /// each is aggregated within its own timeline. Only the main context's buffer
    /// accumulates these; task buffers leave it empty.
    task_profiles: std.ArrayListUnmanaged(TaskProfile) = .{},

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
        for (self.task_profiles.items) |*tp| tp.deinit(alloc);
        self.task_profiles.deinit(alloc);
    }

    /// True when any word dispatch was recorded, across the main-context buffer
    /// and every drained task buffer.
    pub fn hasSamples(self: *const ProfileStats) bool {
        if (self.samples.items.len > 0) return true;
        for (self.task_profiles.items) |tp| {
            if (tp.samples.items.len > 0) return true;
        }
        return false;
    }

    /// Run one containment pass over `samples` and fold the per-word counters
    /// into `map`.
    ///
    /// Self-time is the per-call duration minus the sum of direct child
    /// durations. Samples are appended at dispatch end, so a parent always
    /// appears after all its descendants; the parent's direct children are the
    /// contiguous suffix of the stack whose `[start_ns, end_ns]` falls inside the
    /// parent's window. The stack is local to this pass, so each buffer must be
    /// aggregated on its own: containment only holds within one task's timeline.
    fn aggregateInto(
        map: *std.StringHashMapUnmanaged(WordAggregate),
        alloc: std.mem.Allocator,
        samples: []const ProfileSample,
    ) !void {
        // Stack of indices into `samples` that have not yet been claimed
        // as a child of a later parent sample.
        var stack: std.ArrayListUnmanaged(usize) = .{};
        defer stack.deinit(alloc);

        for (samples, 0..) |s, i| {
            const total_ns = s.end_ns - s.start_ns;
            var child_sum_ns: i128 = 0;

            while (stack.items.len > 0) {
                const top_idx = stack.items[stack.items.len - 1];
                const top = samples[top_idx];
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
    }

    /// Aggregate per-word counters over the main-context buffer.
    /// Caller owns the returned map and must call `deinit` on it.
    pub fn aggregate(
        self: *const ProfileStats,
        alloc: std.mem.Allocator,
    ) !std.StringHashMapUnmanaged(WordAggregate) {
        var map: std.StringHashMapUnmanaged(WordAggregate) = .{};
        errdefer map.deinit(alloc);
        try aggregateInto(&map, alloc, self.samples.items);
        return map;
    }

    /// Aggregate the main-context buffer together with every drained task buffer.
    /// Each buffer contributes its own containment pass; the per-word counters
    /// sum across all of them, keyed by word name. Caller owns the returned map.
    pub fn aggregateWholeProgram(
        self: *const ProfileStats,
        alloc: std.mem.Allocator,
    ) !std.StringHashMapUnmanaged(WordAggregate) {
        var map: std.StringHashMapUnmanaged(WordAggregate) = .{};
        errdefer map.deinit(alloc);
        try aggregateInto(&map, alloc, self.samples.items);
        for (self.task_profiles.items) |tp| {
            try aggregateInto(&map, alloc, tp.samples.items);
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
        if (!self.hasSamples()) return;

        var map = try self.aggregateWholeProgram(alloc);
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
    /// Containment only holds within one buffer's timeline, so each buffer is recovered on its own.
    fn recoverAncestry(alloc: std.mem.Allocator, samples: []const ProfileSample) !Ancestry {
        const n = samples.len;
        const parents = try alloc.alloc(?usize, n);
        const self_ns = try alloc.alloc(i128, n);

        var stack: std.ArrayListUnmanaged(usize) = .{};
        defer stack.deinit(alloc);

        for (samples, 0..) |s, i| {
            const total_ns = s.end_ns - s.start_ns;
            var child_sum_ns: i128 = 0;

            while (stack.items.len > 0) {
                const top_idx = stack.items[stack.items.len - 1];
                const top = samples[top_idx];
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

    /// Intern each new word name in `samples` into `strings` and give it a 1-based function id,
    /// with a location mirroring the function one-to-one. Interning across every buffer keeps a
    /// word shared between the main context and a task mapped to a single function.
    fn internNames(
        alloc: std.mem.Allocator,
        name_ids: *std.StringHashMapUnmanaged(u64),
        functions: *std.ArrayListUnmanaged(pprof.Function),
        locations: *std.ArrayListUnmanaged(pprof.Location),
        strings: *std.ArrayListUnmanaged([]const u8),
        samples: []const ProfileSample,
    ) !void {
        for (samples) |s| {
            const gop = try name_ids.getOrPut(alloc, s.name);
            if (gop.found_existing) continue;
            const fid: u64 = functions.items.len + 1;
            gop.value_ptr.* = fid;
            const name_idx: u64 = strings.items.len;
            try strings.append(alloc, s.name);
            try functions.append(alloc, .{ .id = fid, .name_idx = name_idx });
            try locations.append(alloc, .{ .id = fid, .function_id = fid });
        }
    }

    /// Emit one pprof sample per recorded interval in `samples`, each carrying `labels`.
    ///
    /// Ancestry is recovered over this buffer alone, so the leaf-first location chain and the
    /// exclusive self-time stay valid for one task's timeline. All samples in a buffer share the
    /// same task labels, so `labels` is pointed at rather than copied.
    fn appendBufferSamples(
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(pprof.Sample),
        name_ids: *std.StringHashMapUnmanaged(u64),
        samples: []const ProfileSample,
        labels: []const pprof.Label,
    ) !void {
        const ancestry = try recoverAncestry(alloc, samples);

        for (samples, 0..) |_, i| {
            var chain: std.ArrayListUnmanaged(u64) = .{};
            var cur: ?usize = i;
            while (cur) |c| {
                try chain.append(alloc, name_ids.get(samples[c].name).?);
                cur = ancestry.parents[c];
            }

            const values = try alloc.alloc(i64, 2);
            values[0] = @intCast(ancestry.self_ns[i]);
            values[1] = 1;

            try out.append(alloc, .{ .location_ids = chain.items, .values = values, .labels = labels });
        }
    }

    /// Build a pprof wire model from the recorded samples.
    ///
    /// Every allocation lands on `alloc`, which the caller reaps in one shot from an arena. The
    /// main context and every drained task buffer contribute their samples to one profile. Each
    /// interval becomes one sample: a leaf-first ancestor chain of locations, an exclusive
    /// self-time in nanoseconds, and a call count of one. pprof derives the cumulative views from
    /// the stacks.
    ///
    /// Every sample carries `task`, `task_name`, and `worker` labels so pprof can filter and group
    /// by task. The main context is labeled task 0 named "main"; task ids start at 1, so 0 is an
    /// unambiguous main bucket. A task buffer carries its own id and worker, plus its `spawn-named`
    /// name when it has one.
    fn buildProfile(self: *const ProfileStats, alloc: std.mem.Allocator) !pprof.Profile {
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

        const task_key: u64 = strings.items.len;
        try strings.append(alloc, "task");
        const task_name_key: u64 = strings.items.len;
        try strings.append(alloc, "task_name");
        const worker_key: u64 = strings.items.len;
        try strings.append(alloc, "worker");
        const main_name: u64 = strings.items.len;
        try strings.append(alloc, "main");

        // Intern word names to a 1-based function id. A location mirrors each
        // function one-to-one, so the location id can reuse the function id.
        var name_ids: std.StringHashMapUnmanaged(u64) = .{};
        var functions: std.ArrayListUnmanaged(pprof.Function) = .{};
        var locations: std.ArrayListUnmanaged(pprof.Location) = .{};

        try internNames(alloc, &name_ids, &functions, &locations, &strings, self.samples.items);
        for (self.task_profiles.items) |tp| {
            try internNames(alloc, &name_ids, &functions, &locations, &strings, tp.samples.items);
        }

        var samples: std.ArrayListUnmanaged(pprof.Sample) = .{};

        const main_labels = try alloc.alloc(pprof.Label, 3);
        main_labels[0] = .{ .key_idx = task_key, .value = .{ .num = 0 } };
        main_labels[1] = .{ .key_idx = task_name_key, .value = .{ .str = main_name } };
        main_labels[2] = .{ .key_idx = worker_key, .value = .{ .num = 0 } };
        try appendBufferSamples(alloc, &samples, &name_ids, self.samples.items, main_labels);

        for (self.task_profiles.items) |tp| {
            var labels: std.ArrayListUnmanaged(pprof.Label) = .{};
            try labels.append(alloc, .{ .key_idx = task_key, .value = .{ .num = @intCast(tp.task_id) } });
            if (tp.task_name) |name| {
                const name_idx: u64 = strings.items.len;
                try strings.append(alloc, name);
                try labels.append(alloc, .{ .key_idx = task_name_key, .value = .{ .str = name_idx } });
            }
            try labels.append(alloc, .{ .key_idx = worker_key, .value = .{ .num = @intCast(tp.worker_id) } });
            try appendBufferSamples(alloc, &samples, &name_ids, tp.samples.items, labels.items);
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

// Helper for task-buffer tests: append a sample whose name is owned by `alloc`,
// mirroring how the drain dupes borrowed names onto a longer-lived allocator.
fn addTaskSample(tp: *TaskProfile, alloc: std.mem.Allocator, name: []const u8, start_ns: i128, end_ns: i128) !void {
    const owned = try alloc.dupe(u8, name);
    try tp.samples.append(alloc, .{ .name = owned, .start_ns = start_ns, .end_ns = end_ns });
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

test "aggregateWholeProgram sums main and task buffers by word" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    // The main context ran `+` once.
    try pushSample(&stats, alloc, "+", 0, 100);

    // A drained task ran `+` again and `dup` once.
    var tp: TaskProfile = .{ .task_id = 7, .worker_id = 1 };
    tp.task_name = try alloc.dupe(u8, "worker");
    try addTaskSample(&tp, alloc, "+", 200, 260);
    try addTaskSample(&tp, alloc, "dup", 300, 320);
    try stats.task_profiles.append(alloc, tp);

    var map = try stats.aggregateWholeProgram(alloc);
    defer map.deinit(alloc);

    const plus = map.get("+") orelse unreachable;
    try std.testing.expectEqual(@as(u64, 2), plus.calls);
    try std.testing.expectEqual(@as(i128, 160), plus.total_ns);

    const d = map.get("dup") orelse unreachable;
    try std.testing.expectEqual(@as(u64, 1), d.calls);
    try std.testing.expectEqual(@as(i128, 20), d.total_ns);
}

test "formatHuman renders a word that only ran in a task buffer" {
    const alloc = std.testing.allocator;
    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    // The main context recorded nothing; only a task did.
    var tp: TaskProfile = .{ .task_id = 3 };
    try addTaskSample(&tp, alloc, "handler", 0, 1_000_000);
    try stats.task_profiles.append(alloc, tp);

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try stats.formatHuman(alloc, stream.writer(), 20);
    const out = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, out, "=== Word Profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "handler") != null);
}

test "TaskProfile.deinit frees duped names and task name" {
    const alloc = std.testing.allocator;
    var tp: TaskProfile = .{ .task_id = 1, .worker_id = 2 };
    tp.task_name = try alloc.dupe(u8, "t1");
    try addTaskSample(&tp, alloc, "+", 0, 10);
    try addTaskSample(&tp, alloc, "dup", 20, 30);
    tp.deinit(alloc);
    // The testing allocator asserts no leak when the test ends.
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

/// Find the string-table index of `needle`, or null when it is absent.
fn stringIndexOf(table: []const []const u8, needle: []const u8) ?u64 {
    for (table, 0..) |s, i| {
        if (std.mem.eql(u8, s, needle)) return @intCast(i);
    }
    return null;
}

/// The sample whose leaf frame is `leaf_name`. Locations mirror functions one-to-one, so the
/// leaf location id equals the leaf function id.
fn sampleForLeaf(profile: pprof.Profile, leaf_name: []const u8) pprof.Sample {
    const fid = functionIdByName(profile, leaf_name);
    for (profile.samples) |s| {
        if (s.location_ids.len > 0 and s.location_ids[0] == fid) return s;
    }
    unreachable;
}

/// The label on `sample` whose key resolves to `key`, or null when absent.
fn labelByKey(profile: pprof.Profile, sample: pprof.Sample, key: []const u8) ?pprof.Label {
    const key_idx = stringIndexOf(profile.string_table, key) orelse return null;
    for (sample.labels) |lbl| {
        if (lbl.key_idx == key_idx) return lbl;
    }
    return null;
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

test "buildProfile labels main as task 0 and tasks by id, name, and worker" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    // The main context ran `accept`.
    try pushSample(&stats, alloc, "accept", 0, 100);

    // A named task ran `handler`.
    var named: TaskProfile = .{ .task_id = 5, .worker_id = 2 };
    named.task_name = try alloc.dupe(u8, "handler");
    try addTaskSample(&named, alloc, "handler", 0, 200);
    try stats.task_profiles.append(alloc, named);

    // An unnamed task ran `work`.
    var unnamed: TaskProfile = .{ .task_id = 6, .worker_id = 3 };
    try addTaskSample(&unnamed, alloc, "work", 0, 50);
    try stats.task_profiles.append(alloc, unnamed);

    const profile = try stats.buildProfile(a);

    const main = sampleForLeaf(profile, "accept");
    try std.testing.expectEqual(@as(i64, 0), (labelByKey(profile, main, "task").?).value.num);
    const main_name = labelByKey(profile, main, "task_name").?;
    try std.testing.expectEqualStrings("main", profile.string_table[main_name.value.str]);
    try std.testing.expectEqual(@as(i64, 0), (labelByKey(profile, main, "worker").?).value.num);

    const handler = sampleForLeaf(profile, "handler");
    try std.testing.expectEqual(@as(i64, 5), (labelByKey(profile, handler, "task").?).value.num);
    const handler_name = labelByKey(profile, handler, "task_name").?;
    try std.testing.expectEqualStrings("handler", profile.string_table[handler_name.value.str]);
    try std.testing.expectEqual(@as(i64, 2), (labelByKey(profile, handler, "worker").?).value.num);

    const work = sampleForLeaf(profile, "work");
    try std.testing.expectEqual(@as(i64, 6), (labelByKey(profile, work, "task").?).value.num);
    try std.testing.expectEqual(@as(i64, 3), (labelByKey(profile, work, "worker").?).value.num);
    // An unnamed task carries no task_name label.
    try std.testing.expect(labelByKey(profile, work, "task_name") == null);
}

test "exportPprof round-trips a handler task's name label through the wire format" {
    const alloc = std.testing.allocator;

    var stats: ProfileStats = .{};
    defer stats.deinit(alloc);

    // Server-shaped: the main context runs the accept loop, a task runs the handler.
    try pushSample(&stats, alloc, "accept", 0, 100);
    var tp: TaskProfile = .{ .task_id = 9, .worker_id = 1 };
    tp.task_name = try alloc.dupe(u8, "handler");
    try addTaskSample(&tp, alloc, "handler", 0, 500);
    try stats.task_profiles.append(alloc, tp);

    const gz = try stats.exportPprof(alloc);
    defer alloc.free(gz);

    const proto = try pprof.inflateStored(alloc, gz);
    defer alloc.free(proto);

    const fields = try pprof.parseFields(alloc, proto);
    defer alloc.free(fields);

    // The string table is encoded in table order, so index i names strings.items[i].
    var strings: std.ArrayListUnmanaged([]const u8) = .{};
    defer strings.deinit(alloc);
    for (fields) |f| {
        if (f.number == 6) try strings.append(alloc, f.bytes);
    }

    try std.testing.expect(containsString(strings.items, "handler"));

    // Some sample carries a string label whose value resolves to "handler".
    var found_handler_label = false;
    for (fields) |f| {
        if (f.number != 2) continue;
        const inner = try pprof.parseFields(alloc, f.bytes);
        defer alloc.free(inner);
        for (inner) |sub| {
            if (sub.number != 3) continue; // Sample.label
            const label = try pprof.parseFields(alloc, sub.bytes);
            defer alloc.free(label);
            if (label.len >= 2 and label[1].number == 2) {
                const str_idx = label[1].varint;
                if (str_idx < strings.items.len and std.mem.eql(u8, strings.items[str_idx], "handler")) {
                    found_handler_label = true;
                }
            }
        }
    }
    try std.testing.expect(found_handler_label);
}
