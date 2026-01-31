const std = @import("std");
const Value = @import("value.zig").Value;

/// Output format for benchmark CLI reporting
pub const BenchmarkOutput = enum { none, human, json };

/// Configuration for benchmark mode
pub const BenchmarkConfig = struct {
    enabled: bool = false,
    output: BenchmarkOutput = .none,
};

/// Benchmark statistics collected during execution
pub const BenchmarkStats = struct {
    // Timing (nanoseconds)
    start_time: i128 = 0,
    prelude_end_time: i128 = 0,
    end_time: i128 = 0,

    // Instruction counts
    push_literal_count: u64 = 0,
    call_word_count: u64 = 0,

    // Stack metrics
    peak_stack_depth: usize = 0,

    // Memory stats (populated at end from GPA)
    total_allocations: usize = 0,
    total_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    current_live_bytes: usize = 0,

    /// Start the benchmark timer
    pub fn start(self: *BenchmarkStats) void {
        self.start_time = std.time.nanoTimestamp();
    }

    /// Mark the end of prelude loading
    pub fn markPreludeEnd(self: *BenchmarkStats) void {
        self.prelude_end_time = std.time.nanoTimestamp();
    }

    /// Stop the benchmark timer
    pub fn stop(self: *BenchmarkStats) void {
        self.end_time = std.time.nanoTimestamp();
    }

    /// Record a push_literal instruction
    pub fn recordPushLiteral(self: *BenchmarkStats) void {
        self.push_literal_count += 1;
    }

    /// Record a call_word instruction
    pub fn recordCallWord(self: *BenchmarkStats) void {
        self.call_word_count += 1;
    }

    /// Update peak stack depth if current depth is higher
    pub fn updatePeakStackDepth(self: *BenchmarkStats, depth: usize) void {
        if (depth > self.peak_stack_depth) {
            self.peak_stack_depth = depth;
        }
    }

    /// Get total instruction count
    pub fn totalInstructions(self: *const BenchmarkStats) u64 {
        return self.push_literal_count + self.call_word_count;
    }

    /// Get prelude time in nanoseconds
    pub fn preludeTimeNs(self: *const BenchmarkStats) i128 {
        return self.prelude_end_time - self.start_time;
    }

    /// Get user code time in nanoseconds
    pub fn userTimeNs(self: *const BenchmarkStats) i128 {
        return self.end_time - self.prelude_end_time;
    }

    /// Get total time in nanoseconds
    pub fn totalTimeNs(self: *const BenchmarkStats) i128 {
        return self.end_time - self.start_time;
    }

    /// Format time in human-readable form (ms or us)
    pub fn formatTime(writer: anytype, ns: i128) !void {
        if (ns < 0) {
            try writer.writeAll("N/A");
            return;
        }
        const ns_u: u64 = @intCast(ns);
        if (ns_u >= 1_000_000) {
            // Milliseconds
            const ms = ns_u / 1_000_000;
            const frac = (ns_u % 1_000_000) / 1_000;
            try writer.print("{d}.{d:0>3} ms", .{ ms, frac });
        } else if (ns_u >= 1_000) {
            // Microseconds
            const us = ns_u / 1_000;
            const frac = ns_u % 1_000;
            try writer.print("{d}.{d:0>3} us", .{ us, frac });
        } else {
            try writer.print("{d} ns", .{ns_u});
        }
    }

    /// Format bytes in human-readable form
    pub fn formatBytes(writer: anytype, bytes: usize) !void {
        if (bytes >= 1_048_576) {
            const mb = bytes / 1_048_576;
            const frac = (bytes % 1_048_576) * 100 / 1_048_576;
            try writer.print("{d}.{d:0>2} MB", .{ mb, frac });
        } else if (bytes >= 1_024) {
            const kb = bytes / 1_024;
            const frac = (bytes % 1_024) * 100 / 1_024;
            try writer.print("{d}.{d:0>2} KB", .{ kb, frac });
        } else {
            try writer.print("{d} B", .{bytes});
        }
    }

    /// Format number with thousands separators
    pub fn formatNumber(writer: anytype, n: u64) !void {
        if (n == 0) {
            try writer.writeAll("0");
            return;
        }

        var buf: [32]u8 = undefined;
        var pos: usize = buf.len;
        var val = n;
        var digit_count: usize = 0;

        while (val > 0) {
            if (digit_count > 0 and digit_count % 3 == 0) {
                pos -= 1;
                buf[pos] = ',';
            }
            pos -= 1;
            buf[pos] = '0' + @as(u8, @intCast(val % 10));
            val /= 10;
            digit_count += 1;
        }

        try writer.writeAll(buf[pos..]);
    }

    /// Output benchmark results in human-readable format
    pub fn formatHuman(self: *const BenchmarkStats, writer: anytype) !void {
        try writer.writeAll("\n=== Benchmark Results ===\n");

        // Timing section
        try writer.writeAll("Timing:\n");
        try writer.writeAll("  Prelude load:    ");
        try formatTime(writer, self.preludeTimeNs());
        try writer.writeAll("\n");
        try writer.writeAll("  User code:       ");
        try formatTime(writer, self.userTimeNs());
        try writer.writeAll("\n");
        try writer.writeAll("  Total:           ");
        try formatTime(writer, self.totalTimeNs());
        try writer.writeAll("\n");

        // Instructions section
        try writer.writeAll("\nInstructions:\n");
        try writer.writeAll("  push_literal:    ");
        try formatNumber(writer, self.push_literal_count);
        try writer.writeAll("\n");
        try writer.writeAll("  call_word:       ");
        try formatNumber(writer, self.call_word_count);
        try writer.writeAll("\n");
        try writer.writeAll("  Total:           ");
        try formatNumber(writer, self.totalInstructions());
        try writer.writeAll("\n");

        // Stack section
        try writer.writeAll("\nStack:\n");
        try writer.writeAll("  Peak depth:      ");
        try writer.print("{d}", .{self.peak_stack_depth});
        try writer.writeAll("\n");

        // Memory section
        try writer.writeAll("\nMemory:\n");
        try writer.writeAll("  Allocations:     ");
        try formatNumber(writer, self.total_allocations);
        try writer.writeAll("\n");
        try writer.writeAll("  Total bytes:     ");
        try formatBytes(writer, self.total_bytes);
        try writer.writeAll("\n");
        try writer.writeAll("  Peak live:       ");
        try formatBytes(writer, self.peak_live_bytes);
        try writer.writeAll("\n");
    }

    /// Output benchmark results in JSON format
    pub fn formatJson(self: *const BenchmarkStats, writer: anytype) !void {
        try writer.print(
            \\{{"timing":{{"prelude_ns":{d},"user_ns":{d},"total_ns":{d}}},"instructions":{{"push_literal":{d},"call_word":{d},"total":{d}}},"stack":{{"peak_depth":{d}}},"memory":{{"allocations":{d},"bytes":{d},"peak_live_bytes":{d}}}}}
        , .{
            @as(i64, @intCast(self.preludeTimeNs())),
            @as(i64, @intCast(self.userTimeNs())),
            @as(i64, @intCast(self.totalTimeNs())),
            self.push_literal_count,
            self.call_word_count,
            self.totalInstructions(),
            self.peak_stack_depth,
            self.total_allocations,
            self.total_bytes,
            self.peak_live_bytes,
        });
        try writer.writeAll("\n");
    }
};

/// A single entry in a benchmark report.
pub const BenchmarkReportEntry = struct {
    label: []const u8,
    results: *std.StringHashMapUnmanaged(Value),
};

/// A benchmark report collecting multiple benchmark entries for reporting later.
pub const BenchmarkReport = struct {
    entries: std.ArrayListUnmanaged(BenchmarkReportEntry) = .{},
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) BenchmarkReport {
        return .{ .allocator = alloc };
    }

    pub fn addEntry(self: *BenchmarkReport, label: []const u8, results: *std.StringHashMapUnmanaged(Value)) !void {
        try self.entries.append(self.allocator, .{ .label = label, .results = results });
    }
};

/// An allocator wrapper that counts allocations and bytes for benchmarking with minimal overhead.
pub const CountingAllocator = struct {
    backing_allocator: std.mem.Allocator,
    stats: *BenchmarkStats,

    pub fn init(backing: std.mem.Allocator, stats: *BenchmarkStats) CountingAllocator {
        return .{
            .backing_allocator = backing,
            .stats = stats,
        };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        const result = self.backing_allocator.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.stats.total_allocations += 1;
            self.stats.total_bytes += len;
            self.stats.current_live_bytes += len;
            if (self.stats.current_live_bytes > self.stats.peak_live_bytes) {
                self.stats.peak_live_bytes = self.stats.current_live_bytes;
            }
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        const old_len = memory.len;
        const success = self.backing_allocator.rawResize(memory, alignment, new_len, ret_addr);
        if (success) {
            if (new_len > old_len) {
                const delta = new_len - old_len;
                self.stats.total_bytes += delta;
                self.stats.current_live_bytes += delta;
                if (self.stats.current_live_bytes > self.stats.peak_live_bytes) {
                    self.stats.peak_live_bytes = self.stats.current_live_bytes;
                }
            } else if (new_len < old_len) {
                self.stats.current_live_bytes -= (old_len - new_len);
            }
        }
        return success;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        const old_len = memory.len;
        const result = self.backing_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len > old_len) {
                const delta = new_len - old_len;
                self.stats.total_bytes += delta;
                self.stats.current_live_bytes += delta;
                if (self.stats.current_live_bytes > self.stats.peak_live_bytes) {
                    self.stats.peak_live_bytes = self.stats.current_live_bytes;
                }
            } else if (new_len < old_len) {
                self.stats.current_live_bytes -= (old_len - new_len);
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        self.stats.current_live_bytes -= memory.len;
        self.backing_allocator.rawFree(memory, alignment, ret_addr);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "CountingAllocator tracks allocations" {
    var stats = BenchmarkStats{};
    var counting = CountingAllocator.init(std.testing.allocator, &stats);
    const alloc = counting.allocator();

    // Allocate some memory
    const mem1 = try alloc.alloc(u8, 100);
    defer alloc.free(mem1);

    try std.testing.expectEqual(@as(usize, 1), stats.total_allocations);
    try std.testing.expectEqual(@as(usize, 100), stats.total_bytes);

    // Allocate more
    const mem2 = try alloc.alloc(u8, 200);
    defer alloc.free(mem2);

    try std.testing.expectEqual(@as(usize, 2), stats.total_allocations);
    try std.testing.expectEqual(@as(usize, 300), stats.total_bytes);
}

test "BenchmarkStats initialization" {
    const stats = BenchmarkStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.push_literal_count);
    try std.testing.expectEqual(@as(u64, 0), stats.call_word_count);
    try std.testing.expectEqual(@as(usize, 0), stats.peak_stack_depth);
}

test "BenchmarkStats instruction counting" {
    var stats = BenchmarkStats{};
    stats.recordPushLiteral();
    stats.recordPushLiteral();
    stats.recordCallWord();

    try std.testing.expectEqual(@as(u64, 2), stats.push_literal_count);
    try std.testing.expectEqual(@as(u64, 1), stats.call_word_count);
    try std.testing.expectEqual(@as(u64, 3), stats.totalInstructions());
}

test "BenchmarkStats peak stack depth" {
    var stats = BenchmarkStats{};
    stats.updatePeakStackDepth(5);
    try std.testing.expectEqual(@as(usize, 5), stats.peak_stack_depth);

    stats.updatePeakStackDepth(3);
    try std.testing.expectEqual(@as(usize, 5), stats.peak_stack_depth);

    stats.updatePeakStackDepth(10);
    try std.testing.expectEqual(@as(usize, 10), stats.peak_stack_depth);
}

test "formatNumber with separators" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try BenchmarkStats.formatNumber(writer, 1234567);
    try std.testing.expectEqualStrings("1,234,567", stream.getWritten());
}

test "CountingAllocator tracks peak live bytes" {
    var stats = BenchmarkStats{};
    var counting = CountingAllocator.init(std.testing.allocator, &stats);
    const alloc = counting.allocator();

    // Allocate 100 bytes -> live=100, peak=100
    const mem1 = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), stats.current_live_bytes);
    try std.testing.expectEqual(@as(usize, 100), stats.peak_live_bytes);

    // Allocate 200 more -> live=300, peak=300
    const mem2 = try alloc.alloc(u8, 200);
    try std.testing.expectEqual(@as(usize, 300), stats.current_live_bytes);
    try std.testing.expectEqual(@as(usize, 300), stats.peak_live_bytes);

    // Free first -> live=200, peak still 300
    alloc.free(mem1);
    try std.testing.expectEqual(@as(usize, 200), stats.current_live_bytes);
    try std.testing.expectEqual(@as(usize, 300), stats.peak_live_bytes);

    // Allocate 50 -> live=250, peak still 300
    const mem3 = try alloc.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 250), stats.current_live_bytes);
    try std.testing.expectEqual(@as(usize, 300), stats.peak_live_bytes);

    // Allocate 100 -> live=350, peak=350 (new high)
    const mem4 = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 350), stats.current_live_bytes);
    try std.testing.expectEqual(@as(usize, 350), stats.peak_live_bytes);

    // Total bytes should be cumulative: 100+200+50+100 = 450
    try std.testing.expectEqual(@as(usize, 450), stats.total_bytes);

    alloc.free(mem2);
    alloc.free(mem3);
    alloc.free(mem4);

    // After freeing all, live=0, peak unchanged
    try std.testing.expectEqual(@as(usize, 0), stats.current_live_bytes);
    try std.testing.expectEqual(@as(usize, 350), stats.peak_live_bytes);
}

test "formatBytes" {
    var buf: [64]u8 = undefined;

    {
        var stream = std.io.fixedBufferStream(&buf);
        try BenchmarkStats.formatBytes(stream.writer(), 500);
        try std.testing.expectEqualStrings("500 B", stream.getWritten());
    }

    {
        var stream = std.io.fixedBufferStream(&buf);
        try BenchmarkStats.formatBytes(stream.writer(), 2048);
        try std.testing.expectEqualStrings("2.00 KB", stream.getWritten());
    }

    {
        var stream = std.io.fixedBufferStream(&buf);
        try BenchmarkStats.formatBytes(stream.writer(), 1_048_576);
        try std.testing.expectEqualStrings("1.00 MB", stream.getWritten());
    }
}
