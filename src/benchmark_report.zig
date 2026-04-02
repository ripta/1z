const std = @import("std");

pub const BenchmarkReportHandle = opaque {};

pub fn BenchmarkReportEntry(comptime T: type) type {
    return struct {
        label: []const u8,
        results: *std.StringHashMapUnmanaged(T),
    };
}

pub fn BenchmarkReport(comptime T: type) type {
    const Entry = BenchmarkReportEntry(T);

    return struct {
        entries: std.ArrayListUnmanaged(Entry) = .{},
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{ .allocator = alloc };
        }

        pub fn addEntry(self: *Self, label: []const u8, results: *std.StringHashMapUnmanaged(T)) !void {
            try self.entries.append(self.allocator, .{ .label = label, .results = results });
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |*entry| {
                entry.results.deinit(self.allocator);
            }
            self.entries.deinit(self.allocator);
        }
    };
}
