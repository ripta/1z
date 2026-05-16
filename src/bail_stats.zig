const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.bail_stats;

/// Bail frequency counter. When enabled via `-Dbail-stats=true`, records
/// every bail event (word ID + word name) and prints a summary to stderr
/// on `dump()`. When disabled, all operations are no-ops eliminated at
/// comptime.
pub const BailStats = struct {
    /// Per-word bail counts keyed by word ID.
    word_bails: if (enabled) std.AutoHashMapUnmanaged(u32, Entry) else void,
    /// Total quotation bails (no word ID available).
    quotation_bails: if (enabled) u64 else void,
    /// Total interpreter-dispatch callback invocations recorded via
    /// `recordInterpretedCall`. Covers both `jitInterpretedCall` (compound
    /// fallback) and `jitNativeWordCall` (native dispatch); the field name
    /// is kept for stability.
    interpreted_calls: if (enabled) u64 else void,
    allocator: if (enabled) std.mem.Allocator else void,

    const Entry = struct {
        count: u64,
        name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) BailStats {
        if (enabled) {
            return .{
                .word_bails = .{},
                .quotation_bails = 0,
                .interpreted_calls = 0,
                .allocator = allocator,
            };
        } else {
            return .{
                .word_bails = {},
                .quotation_bails = {},
                .interpreted_calls = {},
                .allocator = {},
            };
        }
    }

    pub fn deinit(self: *BailStats) void {
        if (enabled) {
            self.word_bails.deinit(self.allocator);
        }
    }

    pub fn recordBail(self: *BailStats, word_id: u32, word_name: []const u8) void {
        if (enabled) {
            const gop = self.word_bails.getOrPut(self.allocator, word_id) catch return;
            if (gop.found_existing) {
                gop.value_ptr.count += 1;
            } else {
                gop.value_ptr.* = .{ .count = 1, .name = word_name };
            }
        }
    }

    pub fn recordQuotationBail(self: *BailStats) void {
        if (enabled) {
            self.quotation_bails += 1;
        }
    }

    pub fn recordInterpretedCall(self: *BailStats, word_id: u32, word_name: []const u8) void {
        if (enabled) {
            _ = word_id;
            _ = word_name;
            self.interpreted_calls += 1;
        }
    }

    pub fn dump(self: *const BailStats) void {
        if (!enabled) return;

        const stderr_file: std.fs.File = .stderr();
        var buf: [512]u8 = undefined;

        _ = stderr_file.write("\n=== BAIL STATS ===\n") catch return;

        var len = std.fmt.bufPrint(&buf, "Total interpreter fallback calls: {d}\n", .{self.interpreted_calls}) catch return;
        _ = stderr_file.write(len) catch return;

        len = std.fmt.bufPrint(&buf, "Total quotation bails: {d}\n", .{self.quotation_bails}) catch return;
        _ = stderr_file.write(len) catch return;

        var total_word_bails: u64 = 0;
        var iter = self.word_bails.iterator();
        while (iter.next()) |kv| {
            total_word_bails += kv.value_ptr.count;
        }
        len = std.fmt.bufPrint(&buf, "Total word bails: {d}\n", .{total_word_bails}) catch return;
        _ = stderr_file.write(len) catch return;

        if (total_word_bails > 0) {
            _ = stderr_file.write("\nPer-word bail counts:\n") catch return;

            const entries = self.allocator.alloc(SortEntry, self.word_bails.count()) catch return;
            defer self.allocator.free(entries);
            var i: usize = 0;
            var iter2 = self.word_bails.iterator();
            while (iter2.next()) |kv| {
                entries[i] = .{ .word_id = kv.key_ptr.*, .name = kv.value_ptr.name, .count = kv.value_ptr.count };
                i += 1;
            }

            std.mem.sort(SortEntry, entries[0..i], {}, struct {
                fn lessThan(_: void, a: SortEntry, b: SortEntry) bool {
                    return a.count > b.count;
                }
            }.lessThan);

            for (entries[0..i]) |e| {
                len = std.fmt.bufPrint(&buf, "  {s} (id={d}): {d} bails\n", .{ e.name, e.word_id, e.count }) catch continue;
                _ = stderr_file.write(len) catch continue;
            }
        }

        _ = stderr_file.write("=== END BAIL STATS ===\n") catch return;
    }

    const SortEntry = struct {
        word_id: u32,
        name: []const u8,
        count: u64,
    };
};

/// Global instance, accessible from ir_codegen and context.
pub var global: BailStats = BailStats.init(std.heap.page_allocator);

pub fn initGlobal(allocator: std.mem.Allocator) void {
    if (enabled) {
        global = BailStats.init(allocator);
    }
}

pub fn deinitGlobal() void {
    if (enabled) {
        global.dump();
        global.deinit();
    }
}
