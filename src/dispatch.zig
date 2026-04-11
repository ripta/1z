const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;

/// Sentinel for "any type" in dispatch keys.
pub const any_sentinel = "*";

/// Sentinel for unary dispatch (no second operand).
pub const unary_sentinel = "";

/// Returns the dispatch type name for a value.
///
/// TODO(ripta): Combine with `nativeTypeOf`? This mirrors it so dispatch names
///              are consistent with `type-of`.
pub fn dispatchTypeName(val: Value) []const u8 {
    return switch (val) {
        .tagged => |t| t.tag.name,
        .struct_instance => |si| si.struct_type.name,
        .fixnum => "fixnum",
        .float => "float",
        .boolean => "boolean",
        .string => "string",
        .symbol => "symbol",
        .array => "array",
        .quotation => "quotation",
        .hash => "hash",
        .vector => "vector",
        .byte_array => "byte-array",
        .set => "set",
        .mutable_map => "mutable-map",
        .stream => "stream",
        .parameter => "parameter",
        .module => "module",
        .marker => "marker",
        .struct_type => "struct-type",
        .template => "template",
        .benchmark_report => "benchmark-report",
        .stack_effect => "stack-effect",
        .error_value => "error",
        .task => "task",
        .channel => "channel",
        .iterator => "iterator",
        .doc_string => "doc-string",
    };
}

/// Returns the enum name for a tagged value that is an enum variant,
/// or null for everything else.
pub fn dispatchEnumName(val: Value) ?[]const u8 {
    return switch (val) {
        .tagged => |t| t.tag.enum_name,
        else => null,
    };
}

/// Returns true for `.tagged` and `.struct_instance`.
/// The types that trigger dispatch lookups. Native ops only attempt dispatch when
/// at least one operand satisfies this.
pub fn isUserType(val: Value) bool {
    return switch (val) {
        .tagged, .struct_instance => true,
        else => false,
    };
}

/// Key for dispatch table lookups: (word_name, type_a, type_b).
/// For unary dispatch, type_b is `unary_sentinel`.
pub const DispatchKey = struct {
    word_name: []const u8,
    type_a: []const u8,
    type_b: []const u8,
};

/// HashMap context for DispatchKey: hashes and compares all three string fields.
pub const DispatchKeyContext = struct {
    pub fn hash(_: @This(), key: DispatchKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.word_name);
        h.update(&.{0}); // separator
        h.update(key.type_a);
        h.update(&.{0}); // separator
        h.update(key.type_b);
        return h.final();
    }

    pub fn eql(_: @This(), a: DispatchKey, b: DispatchKey) bool {
        return std.mem.eql(u8, a.word_name, b.word_name) and
            std.mem.eql(u8, a.type_a, b.type_a) and
            std.mem.eql(u8, a.type_b, b.type_b);
    }
};

/// A registered method body for a dispatch entry.
pub const DispatchEntry = struct {
    body: []const Instruction,
};

/// Dispatch table mapping (word_name, type_a, type_b) to method bodies.
pub const DispatchTable = struct {
    entries: std.HashMapUnmanaged(DispatchKey, DispatchEntry, DispatchKeyContext, 80),
    allocator: Allocator,

    pub fn init(allocator: Allocator) DispatchTable {
        return .{
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DispatchTable) void {
        self.entries.deinit(self.allocator);
    }

    /// Register a method. Returns error.DuplicateMethod if the key exists
    /// and allow_overwrite is false.
    pub fn register(self: *DispatchTable, key: DispatchKey, entry: DispatchEntry, allow_overwrite: bool) !void {
        const gop = try self.entries.getOrPut(self.allocator, key);
        if (gop.found_existing and !allow_overwrite) {
            return error.DuplicateMethod;
        }
        gop.value_ptr.* = entry;
    }

    /// Look up a binary dispatch entry. Tries in precedence order:
    ///
    /// 1. (word, type_a, type_b) exact
    /// 2. (word, type_a, "*") wildcard on second
    /// 3. (word, "*", type_b) wildcard on first
    /// 4. (word, "*", "*") both wildcards
    pub fn lookupBinary(self: *const DispatchTable, word_name: []const u8, type_a: []const u8, type_b: []const u8) ?DispatchEntry {
        if (self.entries.get(.{ .word_name = word_name, .type_a = type_a, .type_b = type_b })) |entry| {
            return entry;
        }
        if (self.entries.get(.{ .word_name = word_name, .type_a = type_a, .type_b = any_sentinel })) |entry| {
            return entry;
        }
        if (self.entries.get(.{ .word_name = word_name, .type_a = any_sentinel, .type_b = type_b })) |entry| {
            return entry;
        }
        if (self.entries.get(.{ .word_name = word_name, .type_a = any_sentinel, .type_b = any_sentinel })) |entry| {
            return entry;
        }
        return null;
    }

    /// Look up a unary dispatch entry. Tries:
    ///
    /// 1. (word, type_a, "") exact
    /// 2. (word, "*", "") wildcard
    pub fn lookupUnary(self: *const DispatchTable, word_name: []const u8, type_a: []const u8) ?DispatchEntry {
        if (self.entries.get(.{ .word_name = word_name, .type_a = type_a, .type_b = unary_sentinel })) |entry| {
            return entry;
        }
        if (self.entries.get(.{ .word_name = word_name, .type_a = any_sentinel, .type_b = unary_sentinel })) |entry| {
            return entry;
        }
        return null;
    }

    /// Collect all dispatch keys registered for a given word name.
    /// Caller owns the returned slice.
    pub fn keysForWord(self: *const DispatchTable, word_name: []const u8, alloc: Allocator) ![]DispatchKey {
        var results: std.ArrayListUnmanaged(DispatchKey) = .{};
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.word_name, word_name)) {
                try results.append(alloc, entry.key_ptr.*);
            }
        }
        return results.toOwnedSlice(alloc);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "dispatchTypeName returns correct name for native types" {
    try std.testing.expectEqualStrings("fixnum", dispatchTypeName(.{ .fixnum = 42 }));
    try std.testing.expectEqualStrings("boolean", dispatchTypeName(.{ .boolean = true }));
    try std.testing.expectEqualStrings("string", dispatchTypeName(.{ .string = "hello" }));
    try std.testing.expectEqualStrings("symbol", dispatchTypeName(.{ .symbol = "foo" }));
    try std.testing.expectEqualStrings("array", dispatchTypeName(.{ .array = &.{} }));
}

test "dispatchTypeName returns virtual type name for tagged values" {
    const vt = value_mod.VirtualType{ .name = "duration", .inner_type = "fixnum" };
    const inner = Value{ .fixnum = 42 };
    const tagged = Value{ .tagged = .{ .tag = &vt, .inner = &inner } };
    try std.testing.expectEqualStrings("duration", dispatchTypeName(tagged));
}

test "dispatchTypeName returns struct type name for struct instances" {
    const st = value_mod.StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &.{} };
    try std.testing.expectEqualStrings("point", dispatchTypeName(.{ .struct_instance = &si }));
}

test "isUserType returns true for tagged and struct_instance" {
    const vt = value_mod.VirtualType{ .name = "duration", .inner_type = "fixnum" };
    const inner = Value{ .fixnum = 42 };
    const tagged = Value{ .tagged = .{ .tag = &vt, .inner = &inner } };
    try std.testing.expect(isUserType(tagged));

    const st = value_mod.StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &.{} };
    try std.testing.expect(isUserType(.{ .struct_instance = &si }));
}

test "isUserType returns false for native types" {
    try std.testing.expect(!isUserType(.{ .fixnum = 42 }));
    try std.testing.expect(!isUserType(.{ .boolean = true }));
    try std.testing.expect(!isUserType(.{ .string = "hello" }));
    try std.testing.expect(!isUserType(.{ .symbol = "foo" }));
}

test "register and lookupBinary exact match" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 0 }};
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = body },
        false,
    );

    const result = table.lookupBinary("+", "duration", "duration");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.body.len);
}

test "lookupBinary returns null when no match" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const result = table.lookupBinary("+", "duration", "duration");
    try std.testing.expect(result == null);
}

test "lookupBinary wildcard precedence" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const exact_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    const wild_b_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 }};
    const wild_a_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 0 }};
    const wild_both_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 4 } }, .line = 0 }};

    // Register in reverse precedence order to ensure lookup logic is correct
    try table.register(
        .{ .word_name = "+", .type_a = any_sentinel, .type_b = any_sentinel },
        .{ .body = wild_both_body },
        false,
    );
    try table.register(
        .{ .word_name = "+", .type_a = any_sentinel, .type_b = "fixnum" },
        .{ .body = wild_a_body },
        false,
    );
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = any_sentinel },
        .{ .body = wild_b_body },
        false,
    );
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = exact_body },
        false,
    );

    // Exact match should win
    const r1 = table.lookupBinary("+", "duration", "duration").?;
    try std.testing.expectEqual(@as(i64, 1), r1.body[0].op.push_literal.fixnum);

    // Wildcard on second: (duration, fixnum) matches (duration, *)
    const r2 = table.lookupBinary("+", "duration", "fixnum").?;
    try std.testing.expectEqual(@as(i64, 2), r2.body[0].op.push_literal.fixnum);

    // Wildcard on first: (string, fixnum) matches (*, fixnum)
    const r3 = table.lookupBinary("+", "string", "fixnum").?;
    try std.testing.expectEqual(@as(i64, 3), r3.body[0].op.push_literal.fixnum);

    // Both wildcards: (string, string) matches (*, *)
    const r4 = table.lookupBinary("+", "string", "string").?;
    try std.testing.expectEqual(@as(i64, 4), r4.body[0].op.push_literal.fixnum);
}

test "lookupUnary exact and wildcard" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const exact_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 0 }};
    const wild_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 0 }};

    try table.register(
        .{ .word_name = "serialize", .type_a = "duration", .type_b = unary_sentinel },
        .{ .body = exact_body },
        false,
    );
    try table.register(
        .{ .word_name = "serialize", .type_a = any_sentinel, .type_b = unary_sentinel },
        .{ .body = wild_body },
        false,
    );

    // Exact match
    const r1 = table.lookupUnary("serialize", "duration").?;
    try std.testing.expectEqual(@as(i64, 10), r1.body[0].op.push_literal.fixnum);

    // Wildcard fallback
    const r2 = table.lookupUnary("serialize", "point").?;
    try std.testing.expectEqual(@as(i64, 20), r2.body[0].op.push_literal.fixnum);

    // No match for different word
    try std.testing.expect(table.lookupUnary("other-word", "duration") == null);
}

test "register duplicate key errors without allow_overwrite" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = body },
        false,
    );

    const result = table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = body },
        false,
    );
    try std.testing.expectError(error.DuplicateMethod, result);
}

test "register duplicate key succeeds with allow_overwrite" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const body1 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    const body2 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 }};

    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = body1 },
        false,
    );
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = body2 },
        true,
    );

    // Shoulda gotten the overwritten body
    const result = table.lookupBinary("+", "duration", "duration").?;
    try std.testing.expectEqual(@as(i64, 2), result.body[0].op.push_literal.fixnum);
}
