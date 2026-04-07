const std = @import("std");
const Value = @import("value.zig").Value;

pub const Iterator = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        array: ArrayIter,
    };

    pub fn next(self: *Iterator) ?Value {
        return switch (self.kind) {
            .array => |*it| it.next(),
        };
    }

    pub fn kindName(self: *const Iterator) []const u8 {
        return switch (self.kind) {
            .array => "array",
        };
    }

    pub fn progressDisplay(self: *const Iterator, writer: anytype) !void {
        switch (self.kind) {
            .array => |it| try writer.print("{d}/{d}", .{ it.index, it.items.len }),
        }
    }
};

pub const ArrayIter = struct {
    items: []const Value,
    index: usize,

    pub fn next(self: *ArrayIter) ?Value {
        if (self.index >= self.items.len) return null;
        const val = self.items[self.index];
        self.index += 1;
        return val;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ArrayIter advances through elements" {
    const items = &[_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } };
    var iter = Iterator{ .kind = .{ .array = .{ .items = items, .index = 0 } } };

    try std.testing.expectEqual(@as(i64, 10), iter.next().?.integer);
    try std.testing.expectEqual(@as(i64, 20), iter.next().?.integer);
    try std.testing.expectEqual(@as(i64, 30), iter.next().?.integer);
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.next() == null);
}

test "ArrayIter on empty array returns null immediately" {
    var iter = Iterator{ .kind = .{ .array = .{ .items = &.{}, .index = 0 } } };
    try std.testing.expect(iter.next() == null);
}

test "Iterator kindName returns correct name" {
    const iter = Iterator{ .kind = .{ .array = .{ .items = &.{}, .index = 0 } } };
    try std.testing.expectEqualStrings("array", iter.kindName());
}
