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

/// Hash table type for H{ } literals.
pub const HashTable = std.StringHashMapUnmanaged(Value);

/// Vector type for V{ } literals - mutable, dynamically-sized sequences.
pub const Vector = std.ArrayListUnmanaged(Value);

/// ByteArray type for B{ } literals - mutable, dynamically-sized byte sequences.
pub const ByteArray = std.ArrayListUnmanaged(u8);

/// StackFrame represents a single frame in a stack trace.
pub const StackFrame = struct {
    word_name: []const u8,
    line: usize,
};

/// ErrorObject represents a structured error with type, message, and optional stack trace.
pub const ErrorObject = struct {
    error_type: []const u8,
    message: []const u8,
    stack_trace: ?[]const StackFrame,

    pub fn write(self: ErrorObject, writer: anytype) !void {
        try writer.print("<error {s}: {s}", .{ self.error_type, self.message });
        if (self.stack_trace) |trace| {
            try writer.writeAll(" [");
            for (trace, 0..) |frame, i| {
                if (i > 0) try writer.writeAll(" <- ");
                try writer.print("{s}:{d}", .{ frame.word_name, frame.line });
            }
            try writer.writeAll("]");
        }
        try writer.writeAll(">");
    }

    pub fn eql(self: ErrorObject, other: ErrorObject) bool {
        if (!std.mem.eql(u8, self.error_type, other.error_type)) return false;
        if (!std.mem.eql(u8, self.message, other.message)) return false;

        // Compare stack traces
        if (self.stack_trace == null and other.stack_trace == null) return true;
        if (self.stack_trace == null or other.stack_trace == null) return false;

        const a = self.stack_trace.?;
        const b = other.stack_trace.?;
        if (a.len != b.len) return false;
        for (a, b) |fa, fb| {
            if (!std.mem.eql(u8, fa.word_name, fb.word_name)) return false;
            if (fa.line != fb.line) return false;
        }
        return true;
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

/// Quotation represents executable code with optional stack effect annotation.
pub const Quotation = struct {
    instructions: []const Instruction,
    /// If non-null, the expected stack effect for this quotation.
    /// Used for validation when the quotation is executed.
    effect: ?*const StackEffect = null,

    pub fn eql(self: Quotation, other: Quotation) bool {
        if (self.instructions.len != other.instructions.len) return false;
        for (self.instructions, other.instructions) |ai, bi| {
            if (!instructionEql(ai, bi)) return false;
        }
        // Compare effects
        if (self.effect == null and other.effect == null) return true;
        if (self.effect == null or other.effect == null) return false;
        return self.effect.?.eql(other.effect.?.*);
    }
};

/// Value represents any value that can be stored on the stack.
pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    symbol: []const u8,
    array: []const Value,
    quotation: Quotation,
    hash: *HashTable,
    vector: *Vector,
    byte_array: *ByteArray,
    stack_effect: StackEffect,
    parse_time_marker: void, // Marker for parse-time word definitions
    error_value: ErrorObject,

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
            .quotation => |quot| {
                try writer.writeAll("[ ");
                for (quot.instructions) |instr| {
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
            // TODO(ripta): This is currently tightly-coupled to the internal
            // representation of HashTable, despite H{ } being a non-native
            // implementation in the prelude.
            .hash => |h| {
                try writer.writeAll("H{ ");
                var iter = h.iterator();
                while (iter.next()) |entry| {
                    try writer.print("{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .vector => |v| {
                try writer.writeAll("V{ ");
                for (v.items) |item| {
                    try item.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .byte_array => |b| {
                try writer.writeAll("B{ ");
                for (b.items) |byte| {
                    try writer.print("0x{X:0>2} ", .{byte});
                }
                try writer.writeAll("}");
            },
            .stack_effect => |effect| try effect.write(writer),
            .parse_time_marker => try writer.writeAll("parse-time"),
            .error_value => |err| try err.write(writer),
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
            .quotation => |a| a.eql(other.quotation),
            // TODO(ripta): This is currently tightly-coupled to the internal
            // representation of HashTable, despite H{ } being a non-native
            // implementation in the prelude.
            .hash => |a| {
                const b = other.hash;
                if (a.count() != b.count()) return false;
                var iter = a.iterator();
                while (iter.next()) |entry| {
                    if (b.get(entry.key_ptr.*)) |bval| {
                        if (!entry.value_ptr.eql(bval)) return false;
                    } else {
                        return false;
                    }
                }
                return true;
            },
            .vector => |a| {
                const b = other.vector;
                if (a.items.len != b.items.len) return false;
                for (a.items, b.items) |ai, bi| {
                    if (!ai.eql(bi)) return false;
                }
                return true;
            },
            .byte_array => |a| {
                const b = other.byte_array;
                return std.mem.eql(u8, a.items, b.items);
            },
            .stack_effect => |a| a.eql(other.stack_effect),
            .parse_time_marker => true, // All parse_time_markers are equal
            .error_value => |a| a.eql(other.error_value),
        };
    }
};

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
