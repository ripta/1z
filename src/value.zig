const std = @import("std");
const StackEffect = @import("stack_effect.zig").StackEffect;

/// Instruction represents a single operation in a compiled quotation.
pub const Instruction = struct {
    op: Op,
    line: usize, // 1-based line number from source

    pub const Op = union(enum) {
        push_literal: Value,
        call_word: []const u8,
    };
};

/// Value represents any value that can be stored on the stack.
pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    symbol: []const u8,
    array: []const Value,
    quotation: []const Instruction,
    stack_effect: StackEffect,
    error_value: []const u8,

    pub fn write(self: Value, writer: anytype) anyerror!void {
        switch (self) {
            .integer => |i| try writer.print("{d}", .{i}),
            .boolean => |b| try writer.writeAll(if (b) "t" else "f"),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .symbol => |s| try writer.print("{s}:", .{s}),
            .array => |items| {
                try writer.writeAll("{ ");
                for (items) |item| {
                    try item.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .quotation => |instrs| {
                try writer.writeAll("[ ");
                for (instrs) |instr| {
                    switch (instr.op) {
                        .push_literal => |v| {
                            try v.write(writer);
                            try writer.writeAll(" ");
                        },
                        .call_word => |name| try writer.print("{s} ", .{name}),
                    }
                }
                try writer.writeAll("]");
            },
            .stack_effect => |effect| try effect.write(writer),
            .error_value => |msg| try writer.print("<error: {s}>", .{msg}),
        }
    }

    pub fn eql(self: Value, other: Value) bool {
        const Tag = std.meta.Tag(Value);
        if (@as(Tag, self) != @as(Tag, other)) {
            return false;
        }

        return switch (self) {
            .integer => |a| a == other.integer,
            .boolean => |a| a == other.boolean,
            .string => |a| std.mem.eql(u8, a, other.string),
            .symbol => |a| std.mem.eql(u8, a, other.symbol),
            .array => |a| {
                const b = other.array;
                if (a.len != b.len) return false;
                for (a, b) |ai, bi| {
                    if (!ai.eql(bi)) return false;
                }
                return true;
            },
            .quotation => |a| {
                const b = other.quotation;
                if (a.len != b.len) return false;
                for (a, b) |ai, bi| {
                    if (!instructionEql(ai, bi)) return false;
                }
                return true;
            },
            .stack_effect => |a| a.eql(other.stack_effect),
            .error_value => |a| std.mem.eql(u8, a, other.error_value),
        };
    }
};

fn instructionEql(a: Instruction, b: Instruction) bool {
    const Tag = std.meta.Tag(Instruction.Op);
    if (@as(Tag, a.op) != @as(Tag, b.op)) return false;
    return switch (a.op) {
        .push_literal => |va| va.eql(b.op.push_literal),
        .call_word => |na| std.mem.eql(u8, na, b.op.call_word),
    };
}

// =============================================================================
// Tests
// =============================================================================

test "integer format" {
    const val = Value{ .integer = 42 };
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("42", fbs.getWritten());
}

test "negative integer format" {
    const val = Value{ .integer = -123 };
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("-123", fbs.getWritten());
}

test "integer equality" {
    const a = Value{ .integer = 42 };
    const b = Value{ .integer = 42 };
    const c = Value{ .integer = 100 };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "stack effect format" {
    const StackEffectParam = @import("stack_effect.zig").StackEffectParam;
    const val = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("( n -- n )", fbs.getWritten());
}

test "stack effect equality" {
    const StackEffectParam = @import("stack_effect.zig").StackEffectParam;
    const a = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    const b = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    const c = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{ .{ .name = "a" }, .{ .name = "b" } },
        .outputs = &[_]StackEffectParam{.{ .name = "c" }},
    } };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "stack effect not equal to other types" {
    const StackEffectParam = @import("stack_effect.zig").StackEffectParam;
    const effect = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    const str = Value{ .string = "n -- n" };
    const sym = Value{ .symbol = "n -- n" };

    try std.testing.expect(!effect.eql(str));
    try std.testing.expect(!effect.eql(sym));
}
