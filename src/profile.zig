const std = @import("std");

/// Configuration for word-attributed profile mode.
pub const ProfileConfig = struct {
    enabled: bool = false,
};

/// One recorded word dispatch: the word's name, the start timestamp at
/// dispatch entry, and the end timestamp once execution returned.
pub const ProfileSample = struct {
    name: []const u8,
    start_ns: i128,
    end_ns: i128,
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
};

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
