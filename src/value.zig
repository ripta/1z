const std = @import("std");

/// Instruction represents a single operation in a compiled quotation.
pub const Instruction = union(enum) {
    push_literal: Value,
    call_word: []const u8,
};

/// Value represents any value that can be stored on the stack.
pub const Value = union(enum) {
    integer: i64,
    symbol: []const u8,
    quotation: []const Instruction,

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .integer => |i| try writer.print("{d}", .{i}),
            .symbol => |s| try writer.print("{s}:", .{s}),
            .quotation => |instrs| {
                try writer.writeAll("[ ");
                for (instrs) |instr| {
                    switch (instr) {
                        .push_literal => |v| {
                            try v.format(writer);
                            try writer.writeAll(" ");
                        },
                        .call_word => |name| try writer.print("{s} ", .{name}),
                    }
                }
                try writer.writeAll("]");
            },
        }
    }

    pub fn eql(self: Value, other: Value) bool {
        const Tag = std.meta.Tag(Value);
        if (@as(Tag, self) != @as(Tag, other)) {
            return false;
        }

        return switch (self) {
            .integer => |a| a == other.integer,
            .symbol => |a| std.mem.eql(u8, a, other.symbol),
            .quotation => |a| {
                const b = other.quotation;
                if (a.len != b.len) return false;
                for (a, b) |ai, bi| {
                    if (!instructionEql(ai, bi)) return false;
                }
                return true;
            },
        };
    }
};

fn instructionEql(a: Instruction, b: Instruction) bool {
    const Tag = std.meta.Tag(Instruction);
    if (@as(Tag, a) != @as(Tag, b)) return false;
    return switch (a) {
        .push_literal => |va| va.eql(b.push_literal),
        .call_word => |na| std.mem.eql(u8, na, b.call_word),
    };
}

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
