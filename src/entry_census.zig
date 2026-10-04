const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.entry_census;

/// How an interpreted body entry came to be on the native stack.
///
/// A tail call to a compound word never appears. It replaces the body on the frame its trampoline
/// already holds, so it adds no entry, and the class it would have had is the census's control.
pub const Class = enum {
    /// No classifying word call above it: the top level, an iterator, a signal handler.
    other,
    /// A compound word called from a non-tail position.
    nontail_compound,
    /// A native in tail position running a quotation, such as an `if` arm.
    tail_native,
    /// A native in non-tail position running a quotation, such as `dip`.
    nontail_native,
    /// The body a non-tail native's arm left as a pending tail call, run after the arm returned.
    propagated,
};

/// The class and word name an entry is attributed to. `executeResolvedWord` sets it around each
/// call that can enter a body, and `executeInstructions` reads it at entry.
pub const Tag = struct {
    class: Class = .other,
    name: []const u8 = "",
};

/// What a caller holds across a call to restore the attribution after it. Void when the census is
/// compiled out, so a disabled build carries no local for it in the interpreter's frames.
pub const Saved = if (enabled) Tag else void;

const max_depth = 4096;
const name_capacity = 48;

const LiveEntry = struct {
    tag: Tag,
    frame: usize,
};

const SnapshotEntry = struct {
    class: Class,
    name: [name_capacity]u8,
    name_len: u8,
    frame: usize,
};

/// The live interpreted body entries of one native stack, and a copy of the deepest set seen.
///
/// The copy is taken whenever the live depth exceeds every earlier depth, so at exit it holds the
/// entries that were live at the deepest point of the run. The bytes an entry costs are the
/// distance from the frame of the entry below it, which covers every native frame between the two.
pub const EntryCensus = struct {
    /// The one context whose entries are recorded. A frame address is only comparable with others
    /// on the same native stack, so entries made by any other context are ignored.
    owner: if (enabled) ?*const anyopaque else void = if (enabled) null else {},
    current: if (enabled) Tag else void = if (enabled) .{} else {},
    live: if (enabled) [max_depth]LiveEntry else void = undefined,
    depth: if (enabled) usize else void = if (enabled) 0 else {},
    overflow: if (enabled) u64 else void = if (enabled) 0 else {},
    deepest: if (enabled) [max_depth]SnapshotEntry else void = undefined,
    deepest_len: if (enabled) usize else void = if (enabled) 0 else {},

    /// Attributes the next entries to `tag`, and answers the tag to restore afterward.
    pub inline fn enter(self: *EntryCensus, tag: Tag) Tag {
        const saved = self.current;
        self.current = tag;
        return saved;
    }

    pub inline fn restore(self: *EntryCensus, saved: Tag) void {
        self.current = saved;
    }

    /// Records one body entry at native frame address `frame`. Every push is paired with a `pop`.
    ///
    /// The attribution resets to `other` for the body's own run, so an entry made from inside it
    /// without a classifying call reads as `other` rather than inheriting this entry's class. The
    /// matching `pop` puts the tag back, which is what lets a trampoline's later iterations carry the
    /// class of the entry that created their frame.
    pub fn push(self: *EntryCensus, frame: usize) void {
        if (!enabled) return;

        if (self.depth >= max_depth) {
            self.overflow += 1;
            self.depth += 1;
            return;
        }

        self.live[self.depth] = .{ .tag = self.current, .frame = frame };
        self.depth += 1;
        self.current = .{};

        if (self.depth > self.deepest_len) self.takeSnapshot();
    }

    pub fn pop(self: *EntryCensus) void {
        if (!enabled) return;

        self.depth -= 1;
        if (self.depth < max_depth) self.current = self.live[self.depth].tag;
    }

    /// Copies the whole live set, since entries below the old deepest point may have been popped
    /// and replaced since. A copy per new depth is quadratic in the deepest depth, which a
    /// measurement build can afford. The names are copied because a word's name can be freed
    /// before the dump runs at exit.
    fn takeSnapshot(self: *EntryCensus) void {
        for (self.live[0..self.depth], 0..) |entry, i| {
            const len = @min(entry.tag.name.len, name_capacity);
            var slot: SnapshotEntry = .{ .class = entry.tag.class, .name = undefined, .name_len = @intCast(len), .frame = entry.frame };
            @memcpy(slot.name[0..len], entry.tag.name[0..len]);
            self.deepest[i] = slot;
        }

        self.deepest_len = self.depth;
    }

    /// Writes the deepest snapshot to stderr, one entry per line from the bottom of the stack.
    ///
    /// Each line is `entry INDEX CLASS BYTES NAME`, and `scripts/entry-census.py` parses that form.
    /// The first entry's bytes are zero, since there is no entry below it to measure from.
    pub fn dump(self: *const EntryCensus) void {
        if (!enabled) return;

        const stderr_file: std.fs.File = .stderr();
        var buf: [256]u8 = undefined;

        _ = stderr_file.write("\n=== ENTRY CENSUS ===\n") catch return;

        var totals = [_]struct { count: usize = 0, bytes: usize = 0 }{.{}} ** @typeInfo(Class).@"enum".fields.len;

        for (self.deepest[0..self.deepest_len], 0..) |entry, i| {
            const bytes: usize = if (i == 0) 0 else self.deepest[i - 1].frame -| entry.frame;
            totals[@intFromEnum(entry.class)].count += 1;
            totals[@intFromEnum(entry.class)].bytes += bytes;

            const line = std.fmt.bufPrint(&buf, "entry {d} {s} {d} {s}\n", .{ i, @tagName(entry.class), bytes, entry.name[0..entry.name_len] }) catch continue;
            _ = stderr_file.write(line) catch return;
        }

        for (totals, 0..) |t, c| {
            const line = std.fmt.bufPrint(&buf, "total {s} {d} {d}\n", .{ @tagName(@as(Class, @enumFromInt(c))), t.count, t.bytes }) catch continue;
            _ = stderr_file.write(line) catch return;
        }

        const line = std.fmt.bufPrint(&buf, "overflow {d}\n", .{self.overflow}) catch return;
        _ = stderr_file.write(line) catch return;

        _ = stderr_file.write("=== END ENTRY CENSUS ===\n") catch return;
    }
};

/// The process's census. It lives here rather than on the context so that a build without it
/// leaves the context's layout, and so the interpreter's frames, exactly as they were.
pub var global: if (enabled) ?*EntryCensus else void = if (enabled) null else {};

/// The census recording `ctx`'s entries, or null when `ctx` is not its owner.
pub inline fn forContext(ctx: *const anyopaque) ?*EntryCensus {
    const census = global orelse return null;
    return if (census.owner == ctx) census else null;
}

/// Starts recording the entries of `ctx`. Fails silently, since the census is a measurement aid.
pub fn start(ctx: *const anyopaque) void {
    if (!enabled) return;
    const census = std.heap.page_allocator.create(EntryCensus) catch return;
    census.* = .{ .owner = ctx };
    global = census;
}

/// Writes the deepest snapshot to stderr and releases the census.
pub fn finish() void {
    if (!enabled) return;
    const census = global orelse return;
    census.dump();
    global = null;
    std.heap.page_allocator.destroy(census);
}

test "entry census keeps the deepest live set" {
    if (!enabled) return error.SkipZigTest;

    const census = try std.testing.allocator.create(EntryCensus);
    defer std.testing.allocator.destroy(census);
    census.* = .{};

    census.push(9000);
    const saved = census.enter(.{ .class = .nontail_compound, .name = "outer" });
    census.push(8000);
    census.pop();
    census.restore(saved);

    _ = census.enter(.{ .class = .tail_native, .name = "if" });
    census.push(7000);
    census.push(6000);
    census.pop();
    census.pop();
    census.pop();

    try std.testing.expectEqual(@as(usize, 0), census.depth);
    try std.testing.expectEqual(@as(usize, 3), census.deepest_len);
    try std.testing.expectEqual(Class.other, census.deepest[0].class);
    try std.testing.expectEqual(Class.tail_native, census.deepest[1].class);
    try std.testing.expectEqual(@as(usize, 7000), census.deepest[1].frame);
    try std.testing.expectEqualStrings("if", census.deepest[2].name[0..census.deepest[2].name_len]);
}
