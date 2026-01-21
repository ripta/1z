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

/// Context for hashing and comparing Values in hash-based containers.
pub const ValueContext = struct {
    pub fn hash(self: @This(), key: Value) u32 {
        _ = self;
        // Truncate 64-bit hash to 32-bit as required by ArrayHashMap
        return @truncate(key.hashValue());
    }

    pub fn eql(self: @This(), a: Value, b: Value, index: usize) bool {
        _ = self;
        _ = index;
        return a.eql(b);
    }
};

/// Set type for S{ } literals - immutable collections of unique values.
/// Uses hash-based storage for O(1) average-case membership testing.
pub const Set = std.ArrayHashMapUnmanaged(Value, void, ValueContext, true);

/// MutableMap type for M{ } literals - mutable key-value store.
pub const MutableMap = std.StringHashMapUnmanaged(Value);

/// StreamMode indicates how a stream was opened.
pub const StreamMode = enum {
    read,
    write,
    append,
    read_write,

    pub fn toString(self: StreamMode) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .append => "append",
            .read_write => "read-write",
        };
    }
};

/// BufferingMode indicates how a stream is buffered.
pub const BufferingMode = enum {
    none,
    line,
    block,

    pub fn toSymbol(self: BufferingMode) []const u8 {
        return switch (self) {
            .none => "none",
            .line => "line",
            .block => "block",
        };
    }
};

/// Stream wraps a file handle for I/O operations.
pub const Stream = struct {
    file: std.fs.File,
    mode: StreamMode,
    closed: bool = false,
    name: []const u8, // For display: "stdout", "stderr", file path
    buffering: BufferingMode = .none,
};

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
    set: *Set,
    mutable_map: *MutableMap,
    stream: *Stream,
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
            .set => |s| {
                try writer.writeAll("S{ ");
                for (s.keys()) |key| {
                    try key.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .mutable_map => |m| {
                try writer.writeAll("M{ ");
                var iter = m.iterator();
                while (iter.next()) |entry| {
                    try writer.print("{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .stream => |s| {
                if (s.closed) {
                    try writer.print("<stream {s} (closed)>", .{s.name});
                } else {
                    try writer.print("<stream {s} {s}>", .{ s.name, s.mode.toString() });
                }
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
            // Sets use order-independent equality: two sets are equal if they
            // contain the same elements regardless of iteration order.
            .set => |a| {
                const b = other.set;
                if (a.count() != b.count()) return false;
                // Check that every element in a exists in b (O(n) with O(1) lookups)
                for (a.keys()) |key| {
                    if (!b.contains(key)) return false;
                }
                return true;
            },
            .mutable_map => |a| {
                const b = other.mutable_map;
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
            // Streams are equal if they refer to the same underlying file handle
            .stream => |a| a == other.stream,
            .stack_effect => |a| a.eql(other.stack_effect),
            .parse_time_marker => true, // All parse_time_markers are equal
            .error_value => |a| a.eql(other.error_value),
        };
    }

    /// Compute a hash value for this Value.
    /// Used by hash-based containers like Set.
    pub fn hashValue(self: Value) u64 {
        const Hasher = std.hash.Wyhash;
        var hasher = Hasher.init(0);

        // Hash the tag first to distinguish types
        const tag = @intFromEnum(self);
        hasher.update(std.mem.asBytes(&tag));

        switch (self) {
            .integer => |i| hasher.update(std.mem.asBytes(&i)),
            .boolean => |b| hasher.update(std.mem.asBytes(&b)),
            .string, .symbol => |s| hasher.update(s),
            .array => |arr| {
                for (arr) |elem| {
                    const elem_hash = elem.hashValue();
                    hasher.update(std.mem.asBytes(&elem_hash));
                }
            },
            .quotation => |quot| {
                for (quot.instructions) |instr| {
                    const line_hash = instr.line;
                    hasher.update(std.mem.asBytes(&line_hash));
                    switch (instr.op) {
                        .push_literal => |v| {
                            const v_hash = v.hashValue();
                            hasher.update(std.mem.asBytes(&v_hash));
                        },
                        .call_word => |name| hasher.update(name),
                    }
                }
            },
            .hash => |h| {
                // Order-independent hash using XOR
                var combined: u64 = 0;
                var iter = h.iterator();
                while (iter.next()) |entry| {
                    var pair_hasher = Hasher.init(0);
                    pair_hasher.update(entry.key_ptr.*);
                    const val_hash = entry.value_ptr.hashValue();
                    pair_hasher.update(std.mem.asBytes(&val_hash));
                    combined ^= pair_hasher.final();
                }
                hasher.update(std.mem.asBytes(&combined));
            },
            .vector => |v| {
                for (v.items) |elem| {
                    const elem_hash = elem.hashValue();
                    hasher.update(std.mem.asBytes(&elem_hash));
                }
            },
            .byte_array => |b| hasher.update(b.items),
            .set => |s| {
                // Order-independent hash using XOR
                var combined: u64 = 0;
                for (s.keys()) |key| {
                    combined ^= key.hashValue();
                }
                hasher.update(std.mem.asBytes(&combined));
            },
            .mutable_map => |m| {
                // Order-independent hash using XOR (same as immutable hash)
                var combined: u64 = 0;
                var iter = m.iterator();
                while (iter.next()) |entry| {
                    var pair_hasher = Hasher.init(0);
                    pair_hasher.update(entry.key_ptr.*);
                    const val_hash = entry.value_ptr.hashValue();
                    pair_hasher.update(std.mem.asBytes(&val_hash));
                    combined ^= pair_hasher.final();
                }
                hasher.update(std.mem.asBytes(&combined));
            },
            // Streams hash by pointer identity (same as equality)
            .stream => |s| {
                const ptr_val = @intFromPtr(s);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .stack_effect => |effect| {
                for (effect.inputs) |param| {
                    hasher.update(param.name);
                }
                hasher.update("--");
                for (effect.outputs) |param| {
                    hasher.update(param.name);
                }
            },
            .parse_time_marker => {
                // All parse_time_markers hash the same
                hasher.update("parse_time_marker");
            },
            .error_value => |err| {
                hasher.update(err.error_type);
                hasher.update(err.message);
            },
        }

        return hasher.final();
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
