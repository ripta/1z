const std = @import("std");

/// Value represents any value that can be stored on the stack, which we'll
/// extend to support floats, booleans, strings, symbols, arrays, quotations.
pub const Value = union(enum) {
    integer: i64,

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .integer => |i| try writer.print("{d}", .{i}),
        }
    }

    pub fn eql(self: Value, other: Value) bool {
        const Tag = std.meta.Tag(Value);
        if (@as(Tag, self) != @as(Tag, other)) {
            return false;
        }

        return switch (self) {
            .integer => |a| a == other.integer,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "integer format" {
    const val = Value{ .integer = 42 };
    var buf: [32]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{val});
    try std.testing.expectEqualStrings("42", result);
}

test "negative integer format" {
    const val = Value{ .integer = -123 };
    var buf: [32]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{val});
    try std.testing.expectEqualStrings("-123", result);
}

test "integer equality" {
    const a = Value{ .integer = 42 };
    const b = Value{ .integer = 42 };
    const c = Value{ .integer = 100 };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}
