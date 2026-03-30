const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const NativeFn = @import("dictionary.zig").NativeFn;

/// Sentinel for "any type" in dispatch keys.
pub const any_sentinel = "*";

/// Sentinel for unary dispatch (no second operand).
pub const unary_sentinel = "";

/// Returns the dispatch type name for a value. Also used by `type-of`.
pub fn dispatchTypeName(val: Value) []const u8 {
    return switch (val) {
        .tagged => |t| t.tag.name,
        .struct_instance => |si| si.struct_type.name,
        .fixnum => "fixnum",
        .float => "float",
        .bignum => "bignum",
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
        .resource => |r| r.type_name,
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
        .type_val => "type",
        .sandbox_spec => "sandbox-spec",
        .unit => "unit",
    };
}

/// Returns the canonical type name for a Value discriminant tag.
/// For the three dynamic variants (.tagged, .struct_instance, .resource),
/// returns the base type name used in the prelude's define-builtin-type.
pub fn builtinTypeName(comptime tag: std.meta.Tag(Value)) []const u8 {
    return switch (tag) {
        .fixnum => "fixnum",
        .float => "float",
        .bignum => "bignum",
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
        .resource => "resource",
        .parameter => "parameter",
        .module => "module",
        .marker => "marker",
        .struct_type => "struct-type",
        .struct_instance => "struct-instance",
        .tagged => "tagged",
        .template => "template",
        .benchmark_report => "benchmark-report",
        .stack_effect => "stack-effect",
        .error_value => "error",
        .task => "task",
        .channel => "channel",
        .iterator => "iterator",
        .doc_string => "doc-string",
        .type_val => "type",
        .sandbox_spec => "sandbox-spec",
        .unit => "unit",
    };
}

/// Returns the enum name for a tagged value that is an enum variant,
/// or null for everything else.
pub fn dispatchEnumName(val: Value) ?[]const u8 {
    return switch (val) {
        .tagged => |t| if (t.tag.parent_type) |pt| pt.name else null,
        else => null,
    };
}

/// Returns the base type name for a parameterized tagged value,
/// or null for everything else.
pub fn dispatchBaseTypeName(val: Value) ?[]const u8 {
    return switch (val) {
        .tagged => |t| if (t.tag.base_type) |bt| bt.name else null,
        else => null,
    };
}

/// If a value is a tagged parameterized type with a base_type, unwrap to
/// the inner value so operations can work on the raw container.
pub fn unwrapBaseType(val: Value) Value {
    if (val == .tagged) {
        if (val.tagged.tag.base_type != null) {
            return val.tagged.inner.*;
        }
    }
    return val;
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

/// Provenance metadata for a dispatch entry: which generator created it and why.
pub const DispatchProvenance = struct {
    generator: []const u8,
    parent: []const u8,
    role: []const u8,
    field: []const u8,
};

/// Tagged union for dispatch entry bodies: either a user-defined quotation
/// or a native function pointer.
pub const DispatchBody = union(enum) {
    quotation: []const Instruction,
    native_fn: NativeFn,
};

/// A registered method body for a dispatch entry.
pub const DispatchEntry = struct {
    body: DispatchBody,
    provenance: ?DispatchProvenance = null,
};

/// Dispatch table mapping (word_name, type_a, type_b) to method bodies.
pub const DispatchTable = struct {
    entries: std.HashMapUnmanaged(DispatchKey, DispatchEntry, DispatchKeyContext, 80),
    native_entries: std.HashMapUnmanaged(DispatchKey, DispatchEntry, DispatchKeyContext, 80),
    allocator: Allocator,
    /// Incremented on every method registration, used for PIC invalidation.
    generation: u32 = 0,

    pub fn init(allocator: Allocator) DispatchTable {
        return .{
            .entries = .{},
            .native_entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DispatchTable) void {
        self.entries.deinit(self.allocator);
        self.native_entries.deinit(self.allocator);
    }

    /// Register a method. Returns error.DuplicateMethod if the key exists
    /// and allow_overwrite is false.
    pub fn register(self: *DispatchTable, key: DispatchKey, entry: DispatchEntry, allow_overwrite: bool) !void {
        const gop = try self.entries.getOrPut(self.allocator, key);
        if (gop.found_existing and !allow_overwrite) {
            return error.DuplicateMethod;
        }
        gop.value_ptr.* = entry;
        self.generation +%= 1;
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

    pub const KeyEntryPair = struct {
        key: DispatchKey,
        entry: DispatchEntry,
    };

    /// Register a native function dispatch entry with "native" provenance.
    pub fn registerNative(
        self: *DispatchTable,
        word_name: []const u8,
        type_a: []const u8,
        type_b: []const u8,
        func: NativeFn,
    ) !void {
        const key = DispatchKey{ .word_name = word_name, .type_a = type_a, .type_b = type_b };
        const entry = DispatchEntry{
            .body = .{ .native_fn = func },
            .provenance = .{ .generator = "native", .parent = "", .role = "", .field = "" },
        };
        try self.register(key, entry, false);
        try self.native_entries.put(self.allocator, key, entry);
    }

    /// Look up a binary dispatch entry in the native-only shadow table.
    pub fn lookupNativeBinary(self: *const DispatchTable, word_name: []const u8, type_a: []const u8, type_b: []const u8) ?DispatchEntry {
        if (self.native_entries.get(.{ .word_name = word_name, .type_a = type_a, .type_b = type_b })) |entry| {
            return entry;
        }
        if (self.native_entries.get(.{ .word_name = word_name, .type_a = type_a, .type_b = any_sentinel })) |entry| {
            return entry;
        }
        if (self.native_entries.get(.{ .word_name = word_name, .type_a = any_sentinel, .type_b = type_b })) |entry| {
            return entry;
        }
        if (self.native_entries.get(.{ .word_name = word_name, .type_a = any_sentinel, .type_b = any_sentinel })) |entry| {
            return entry;
        }
        return null;
    }

    /// Look up a unary dispatch entry in the native-only shadow table.
    pub fn lookupNativeUnary(self: *const DispatchTable, word_name: []const u8, type_a: []const u8) ?DispatchEntry {
        if (self.native_entries.get(.{ .word_name = word_name, .type_a = type_a, .type_b = unary_sentinel })) |entry| {
            return entry;
        }
        if (self.native_entries.get(.{ .word_name = word_name, .type_a = any_sentinel, .type_b = unary_sentinel })) |entry| {
            return entry;
        }
        return null;
    }

    /// Collect all dispatch keys and entries registered for a given word name.
    /// Caller owns the returned slice.
    pub fn entriesForWord(self: *const DispatchTable, word_name: []const u8, alloc: Allocator) ![]KeyEntryPair {
        var results: std.ArrayListUnmanaged(KeyEntryPair) = .{};
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.word_name, word_name)) {
                try results.append(alloc, .{ .key = entry.key_ptr.*, .entry = entry.value_ptr.* });
            }
        }
        return results.toOwnedSlice(alloc);
    }
};

/// A scoped frame of dispatch entries, used by `with-isolation` to layer
/// registrations that can be discarded on scope exit.
pub const DispatchFrame = struct {
    entries: std.HashMapUnmanaged(DispatchKey, DispatchEntry, DispatchKeyContext, 80) = .{},

    pub fn deinit(self: *DispatchFrame, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }
};

const EntriesMap = std.HashMapUnmanaged(DispatchKey, DispatchEntry, DispatchKeyContext, 80);

/// Look up a binary dispatch entry in a single entries map, following the
/// 4-step precedence: exact, wildcard-b, wildcard-a, both-wildcards.
pub fn lookupBinaryInEntries(entries: *const EntriesMap, word_name: []const u8, type_a: []const u8, type_b: []const u8) ?DispatchEntry {
    if (entries.get(.{ .word_name = word_name, .type_a = type_a, .type_b = type_b })) |entry| {
        return entry;
    }
    if (entries.get(.{ .word_name = word_name, .type_a = type_a, .type_b = any_sentinel })) |entry| {
        return entry;
    }
    if (entries.get(.{ .word_name = word_name, .type_a = any_sentinel, .type_b = type_b })) |entry| {
        return entry;
    }
    if (entries.get(.{ .word_name = word_name, .type_a = any_sentinel, .type_b = any_sentinel })) |entry| {
        return entry;
    }
    return null;
}

/// Look up a unary dispatch entry in a single entries map, following the
/// 2-step precedence: exact, wildcard.
pub fn lookupUnaryInEntries(entries: *const EntriesMap, word_name: []const u8, type_a: []const u8) ?DispatchEntry {
    if (entries.get(.{ .word_name = word_name, .type_a = type_a, .type_b = unary_sentinel })) |entry| {
        return entry;
    }
    if (entries.get(.{ .word_name = word_name, .type_a = any_sentinel, .type_b = unary_sentinel })) |entry| {
        return entry;
    }
    return null;
}

/// Collect dispatch keys from an entries map for a given word, appending to results.
pub fn collectKeysForWord(entries: *const EntriesMap, word_name: []const u8, results: *std.ArrayListUnmanaged(DispatchKey), alloc: Allocator) !void {
    var iter = entries.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.word_name, word_name)) {
            try results.append(alloc, entry.key_ptr.*);
        }
    }
}

/// Collect dispatch key-entry pairs from an entries map for a given word, appending to results.
pub fn collectEntriesForWord(entries: *const EntriesMap, word_name: []const u8, results: *std.ArrayListUnmanaged(DispatchTable.KeyEntryPair), alloc: Allocator) !void {
    var iter = entries.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.word_name, word_name)) {
            try results.append(alloc, .{ .key = entry.key_ptr.*, .entry = entry.value_ptr.* });
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

fn dummyNativeFn(_: *@import("context.zig").Context) anyerror!void {}

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

test "register and lookupBinary exact match" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 0 }};
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = .{ .quotation = body } },
        false,
    );

    const result = table.lookupBinary("+", "duration", "duration");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.body.quotation.len);
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
        .{ .body = .{ .quotation = wild_both_body } },
        false,
    );
    try table.register(
        .{ .word_name = "+", .type_a = any_sentinel, .type_b = "fixnum" },
        .{ .body = .{ .quotation = wild_a_body } },
        false,
    );
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = any_sentinel },
        .{ .body = .{ .quotation = wild_b_body } },
        false,
    );
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = .{ .quotation = exact_body } },
        false,
    );

    // Exact match should win
    const r1 = table.lookupBinary("+", "duration", "duration").?;
    try std.testing.expectEqual(@as(i64, 1), r1.body.quotation[0].op.push_literal.fixnum);

    // Wildcard on second: (duration, fixnum) matches (duration, *)
    const r2 = table.lookupBinary("+", "duration", "fixnum").?;
    try std.testing.expectEqual(@as(i64, 2), r2.body.quotation[0].op.push_literal.fixnum);

    // Wildcard on first: (string, fixnum) matches (*, fixnum)
    const r3 = table.lookupBinary("+", "string", "fixnum").?;
    try std.testing.expectEqual(@as(i64, 3), r3.body.quotation[0].op.push_literal.fixnum);

    // Both wildcards: (string, string) matches (*, *)
    const r4 = table.lookupBinary("+", "string", "string").?;
    try std.testing.expectEqual(@as(i64, 4), r4.body.quotation[0].op.push_literal.fixnum);
}

test "lookupUnary exact and wildcard" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const exact_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 0 }};
    const wild_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 0 }};

    try table.register(
        .{ .word_name = "serialize", .type_a = "duration", .type_b = unary_sentinel },
        .{ .body = .{ .quotation = exact_body } },
        false,
    );
    try table.register(
        .{ .word_name = "serialize", .type_a = any_sentinel, .type_b = unary_sentinel },
        .{ .body = .{ .quotation = wild_body } },
        false,
    );

    // Exact match
    const r1 = table.lookupUnary("serialize", "duration").?;
    try std.testing.expectEqual(@as(i64, 10), r1.body.quotation[0].op.push_literal.fixnum);

    // Wildcard fallback
    const r2 = table.lookupUnary("serialize", "point").?;
    try std.testing.expectEqual(@as(i64, 20), r2.body.quotation[0].op.push_literal.fixnum);

    // No match for different word
    try std.testing.expect(table.lookupUnary("other-word", "duration") == null);
}

test "register duplicate key errors without allow_overwrite" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = .{ .quotation = body } },
        false,
    );

    const result = table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = .{ .quotation = body } },
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
        .{ .body = .{ .quotation = body1 } },
        false,
    );
    try table.register(
        .{ .word_name = "+", .type_a = "duration", .type_b = "duration" },
        .{ .body = .{ .quotation = body2 } },
        true,
    );

    // Shoulda gotten the overwritten body
    const result = table.lookupBinary("+", "duration", "duration").?;
    try std.testing.expectEqual(@as(i64, 2), result.body.quotation[0].op.push_literal.fixnum);
}

test "registerNative creates retrievable entry with native_fn body" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    try table.registerNative("+", "fixnum", "fixnum", dummyNativeFn);

    const result = table.lookupBinary("+", "fixnum", "fixnum");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.body == .native_fn);
    try std.testing.expectEqualStrings("native", result.?.provenance.?.generator);
}

test "registerNative unary entry is retrievable via lookupUnary" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    try table.registerNative("abs", "fixnum", unary_sentinel, dummyNativeFn);

    const result = table.lookupUnary("abs", "fixnum");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.body == .native_fn);
}

test "registerNative duplicate returns DuplicateMethod" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    try table.registerNative("+", "fixnum", "fixnum", dummyNativeFn);
    const result = table.registerNative("+", "fixnum", "fixnum", dummyNativeFn);
    try std.testing.expectError(error.DuplicateMethod, result);
}

test "register increments generation counter" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expectEqual(@as(u32, 0), table.generation);

    const body = &[_]value_mod.Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    try table.register(
        .{ .word_name = "+", .type_a = "fixnum", .type_b = "fixnum" },
        .{ .body = .{ .quotation = body } },
        false,
    );
    try std.testing.expectEqual(@as(u32, 1), table.generation);

    try table.register(
        .{ .word_name = "+", .type_a = "fixnum", .type_b = "fixnum" },
        .{ .body = .{ .quotation = body } },
        true,
    );
    try std.testing.expectEqual(@as(u32, 2), table.generation);
}

test "builtinTypeName matches dispatchTypeName for static variants" {
    // Verify all non-dynamic variants produce the same name via both functions.
    const num_variants = comptime @typeInfo(Value).@"union".fields.len;
    inline for (0..num_variants) |i| {
        const tag: std.meta.Tag(Value) = @enumFromInt(i);
        const comptime_name = builtinTypeName(tag);

        // Skip dynamic variants where dispatchTypeName reads from the value.
        if (tag == .tagged or tag == .struct_instance or tag == .resource) continue;

        // Construct a zero-initialized value with this discriminant.
        const val: Value = switch (tag) {
            .fixnum => .{ .fixnum = 0 },
            .float => .{ .float = 0.0 },
            .boolean => .{ .boolean = false },
            .string => .{ .string = "" },
            .symbol => .{ .symbol = "" },
            .array => .{ .array = &.{} },
            .doc_string => .{ .doc_string = "" },
            .unit => .{ .unit = {} },
            // For pointer-based variants, skip runtime check (would need valid allocations).
            // The comptime name matching is sufficient for these.
            else => continue,
        };

        const runtime_name = dispatchTypeName(val);
        try std.testing.expectEqualStrings(comptime_name, runtime_name);
    }
}
