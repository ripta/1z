const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Vector = value_mod.Vector;
const ByteArray = value_mod.ByteArray;
const Set = value_mod.Set;
const container_backing = @import("../container_backing.zig");

// =============================================================================
// UTF-8 Helpers
// =============================================================================

/// Get the byte slice for a codepoint at the given codepoint index.
/// Assumes valid UTF-8 (strings are valid by construction).
pub fn utf8NthCodepoint(s: []const u8, n: usize) ?[]const u8 {
    const utf8 = std.unicode.Utf8View.initUnchecked(s);
    var iter = utf8.iterator();
    var idx: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        if (idx == n) return slice;
        idx += 1;
    }
    return null; // Index out of bounds
}

/// Get byte range for codepoint slice [start, end).
/// Assumes valid UTF-8 (strings are valid by construction).
pub fn utf8SliceByCodepoints(s: []const u8, start: usize, end: usize) ?struct { start_byte: usize, end_byte: usize } {
    const utf8 = std.unicode.Utf8View.initUnchecked(s);
    var iter = utf8.iterator();
    var cp_idx: usize = 0;
    var byte_pos: usize = 0;

    if (start == end) {
        while (iter.nextCodepointSlice()) |slice| {
            if (cp_idx == start) return .{ .start_byte = byte_pos, .end_byte = byte_pos };
            byte_pos += slice.len;
            cp_idx += 1;
        }

        if (cp_idx == start) return .{ .start_byte = byte_pos, .end_byte = byte_pos };
        return null;
    }

    var start_byte: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        if (cp_idx == start) start_byte = byte_pos;
        byte_pos += slice.len;
        if (cp_idx + 1 == end) {
            return .{ .start_byte = start_byte, .end_byte = byte_pos };
        }
        cp_idx += 1;
    }

    if (cp_idx == end) {
        return .{ .start_byte = start_byte, .end_byte = byte_pos };
    }

    // Invalid range
    return null;
}

/// Count codepoints in a UTF-8 string.
/// Assumes valid UTF-8 (strings are valid by construction).
pub fn utf8CodepointCount(s: []const u8) usize {
    const utf8 = std.unicode.Utf8View.initUnchecked(s);
    var iter = utf8.iterator();
    var count: usize = 0;
    while (iter.nextCodepointSlice()) |_| {
        count += 1;
    }
    return count;
}

// =============================================================================
// Sequence Type Classification
// =============================================================================

pub const SequenceKind = enum {
    string,
    array,
    vector,
    byte_array,
    set,
};

/// Determine the sequence kind from a Value, or return null if not a sequence.
pub fn classifySequence(val: Value) ?SequenceKind {
    return switch (val) {
        .string => .string,
        .array => .array,
        .vector => .vector,
        .byte_array => .byte_array,
        .set => .set,
        else => null,
    };
}

// =============================================================================
// Sequence Length
// =============================================================================

/// Get the length of a sequence value.
/// Returns null if the value is not a sequence type.
pub fn sequenceLength(val: Value) ?usize {
    return switch (val) {
        .string => |s| utf8CodepointCount(s.bytes),
        .array => |a| a.items.len,
        .vector => |v| v.list.items.len,
        .byte_array => |b| b.slice().len,
        .set => |s| s.map.count(),
        else => null,
    };
}

// =============================================================================
// Sequence Iterator
// =============================================================================

/// Unified iterator over sequence types.
/// Yields Value elements one at a time.
pub const SequenceIterator = struct {
    kind: SequenceKind,
    allocator: Allocator,
    /// Interned single-character strings (ASCII 0..127) for the `.string` kind.
    /// When set, a single-byte codepoint yields the shared slice instead of a
    /// fresh per-codepoint allocation. Defaults to empty, so callers that do
    /// not thread the Context's table keep the duping behavior unchanged.
    single_char_cache: []const []const u8 = &.{},
    // State for each sequence type
    state: union {
        string: struct {
            data: []const u8,
            byte_index: usize,
        },
        array: struct {
            items: []const Value,
            index: usize,
        },
        vector: struct {
            items: []const Value,
            index: usize,
        },
        byte_array: struct {
            items: []const u8,
            index: usize,
        },
        set: struct {
            keys: []const Value,
            index: usize,
        },
    },

    /// Initialize a sequence iterator from a Value.
    /// Returns null if the value is not a sequence type.
    pub fn init(val: Value, allocator: Allocator) ?SequenceIterator {
        return switch (val) {
            .string => |s| SequenceIterator{
                .kind = .string,
                .allocator = allocator,
                .state = .{ .string = .{ .data = s.bytes, .byte_index = 0 } },
            },
            .array => |a| SequenceIterator{
                .kind = .array,
                .allocator = allocator,
                .state = .{ .array = .{ .items = a.items, .index = 0 } },
            },
            .vector => |v| SequenceIterator{
                .kind = .vector,
                .allocator = allocator,
                .state = .{ .vector = .{ .items = v.list.items, .index = 0 } },
            },
            .byte_array => |b| SequenceIterator{
                .kind = .byte_array,
                .allocator = allocator,
                .state = .{ .byte_array = .{ .items = b.slice(), .index = 0 } },
            },
            .set => |s| SequenceIterator{
                .kind = .set,
                .allocator = allocator,
                .state = .{ .set = .{ .keys = s.map.keys(), .index = 0 } },
            },
            else => null,
        };
    }

    /// Get the next element as a Value.
    /// For strings, allocates a new string for each codepoint.
    pub fn next(self: *SequenceIterator) !?Value {
        switch (self.kind) {
            .string => {
                const data = self.state.string.data;
                if (self.state.string.byte_index >= data.len) return null;

                // Decode one codepoint from the current position
                const remaining = data[self.state.string.byte_index..];
                const cp_len = std.unicode.utf8ByteSequenceLength(remaining[0]) catch return null;
                if (self.state.string.byte_index + cp_len > data.len) return null;

                const cp_slice = remaining[0..cp_len];
                self.state.string.byte_index += cp_len;

                if (cp_len == 1 and cp_slice[0] < self.single_char_cache.len) {
                    return value_mod.stringValue(self.single_char_cache[cp_slice[0]]);
                }
                const char_str = self.allocator.dupe(u8, cp_slice) catch return error.OutOfMemory;
                return value_mod.stringValue(char_str);
            },
            .array => {
                if (self.state.array.index < self.state.array.items.len) {
                    const elem = self.state.array.items[self.state.array.index];
                    self.state.array.index += 1;
                    return elem;
                }
                return null;
            },
            .vector => {
                if (self.state.vector.index < self.state.vector.items.len) {
                    const elem = self.state.vector.items[self.state.vector.index];
                    self.state.vector.index += 1;
                    return elem;
                }
                return null;
            },
            .byte_array => {
                if (self.state.byte_array.index < self.state.byte_array.items.len) {
                    const byte = self.state.byte_array.items[self.state.byte_array.index];
                    self.state.byte_array.index += 1;
                    return Value{ .fixnum = byte };
                }
                return null;
            },
            .set => {
                if (self.state.set.index < self.state.set.keys.len) {
                    const elem = self.state.set.keys[self.state.set.index];
                    self.state.set.index += 1;
                    return elem;
                }
                return null;
            },
        }
    }

    /// Reset the iterator to the beginning.
    pub fn reset(self: *SequenceIterator) void {
        switch (self.kind) {
            .string => self.state.string.byte_index = 0,
            .array => self.state.array.index = 0,
            .vector => self.state.vector.index = 0,
            .byte_array => self.state.byte_array.index = 0,
            .set => self.state.set.index = 0,
        }
    }
};

// =============================================================================
// Sequence Builder
// =============================================================================

/// Builds a result sequence of the same type as the input.
/// Used for type-preserving operations like #map and #filter.
pub const SequenceBuilder = struct {
    kind: SequenceKind,
    allocator: Allocator,
    state: union {
        string: std.ArrayListUnmanaged(u8),
        array: std.ArrayListUnmanaged(Value),
        vector: *Vector,
        byte_array: *ByteArray,
        set: *Set,
    },

    /// Initialize a builder for the given sequence kind.
    pub fn init(kind: SequenceKind, allocator: Allocator) !SequenceBuilder {
        return switch (kind) {
            .string => SequenceBuilder{
                .kind = kind,
                .allocator = allocator,
                .state = .{ .string = .{} },
            },
            .array => SequenceBuilder{
                .kind = kind,
                .allocator = allocator,
                .state = .{ .array = .{} },
            },
            .vector => blk: {
                const vec = Vector.create(allocator) catch return error.OutOfMemory;
                break :blk SequenceBuilder{
                    .kind = kind,
                    .allocator = allocator,
                    .state = .{ .vector = vec },
                };
            },
            .byte_array => blk: {
                const ba = ByteArray.create(allocator) catch return error.OutOfMemory;
                break :blk SequenceBuilder{
                    .kind = kind,
                    .allocator = allocator,
                    .state = .{ .byte_array = ba },
                };
            },
            .set => blk: {
                const s = Set.create(allocator) catch return error.OutOfMemory;
                break :blk SequenceBuilder{
                    .kind = kind,
                    .allocator = allocator,
                    .state = .{ .set = s },
                };
            },
        };
    }

    /// Initialize a builder with a capacity hint.
    pub fn initWithCapacity(kind: SequenceKind, allocator: Allocator, capacity: usize) !SequenceBuilder {
        var builder = try init(kind, allocator);
        switch (kind) {
            .string => builder.state.string.ensureTotalCapacity(allocator, capacity) catch return error.OutOfMemory,
            .array => builder.state.array.ensureTotalCapacity(allocator, capacity) catch return error.OutOfMemory,
            .vector => builder.state.vector.list.ensureTotalCapacity(allocator, capacity) catch return error.OutOfMemory,
            .byte_array => builder.state.byte_array.ensureTotalCapacity(allocator, capacity) catch return error.OutOfMemory,
            .set => {}, // Sets don't have ensureCapacity
        }
        return builder;
    }

    /// Append a Value to the builder.
    /// For strings, the value must be a string (appends the bytes).
    /// For byte arrays, the value must be a fixnum 0-255.
    pub fn append(self: *SequenceBuilder, val: Value) !void {
        switch (self.kind) {
            .string => {
                // Expect string value, append its bytes
                const s = val.string.bytes;
                self.state.string.appendSlice(self.allocator, s) catch return error.OutOfMemory;
            },
            .array => {
                self.state.array.append(self.allocator, val) catch return error.OutOfMemory;
            },
            .vector => {
                self.state.vector.list.append(self.allocator, val) catch return error.OutOfMemory;
            },
            .byte_array => {
                // Expect fixnum value 0-255
                const byte: u8 = @intCast(val.fixnum);
                self.state.byte_array.append(self.allocator, byte) catch return error.OutOfMemory;
            },
            .set => {
                // A duplicate member keeps its existing owning reference;
                // release the redundant one this append carried in.
                const gop = self.state.set.map.getOrPut(self.allocator, val) catch return error.OutOfMemory;
                if (gop.found_existing) {
                    container_backing.releaseValue(val);
                }
            },
        }
    }

    /// Finalize and return the built sequence as a Value.
    pub fn toValue(self: *SequenceBuilder) !Value {
        return switch (self.kind) {
            .string => value_mod.stringValue(self.state.string.toOwnedSlice(self.allocator) catch return error.OutOfMemory),
            .array => blk: {
                const items = self.state.array.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                const arr = value_mod.Array.fromOwnedSlice(self.allocator, items) catch |e| {
                    self.allocator.free(items);
                    return e;
                };
                break :blk Value{ .array = arr };
            },
            .vector => Value{ .vector = self.state.vector },
            .byte_array => Value{ .byte_array = self.state.byte_array },
            .set => Value{ .set = self.state.set },
        };
    }
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Convert a sequence to an array of Values.
/// Useful for operations that need random access.
pub fn sequenceToValues(val: Value, allocator: Allocator) ![]Value {
    return sequenceToValuesScratch(val, allocator, allocator);
}

/// Convert a sequence to an array of Values, splitting the slice from the element allocations.
///
/// The `[]Value` lands on `slice_alloc` so a caller using it as scratch can free it when done.
/// Per-codepoint strings duped for a string source land on `elem_alloc`; those may escape into the
/// caller's result, so a scratch caller passes the arena there.
pub fn sequenceToValuesScratch(val: Value, slice_alloc: Allocator, elem_alloc: Allocator) ![]Value {
    const len = sequenceLength(val) orelse return error.TypeMismatch;
    const result = slice_alloc.alloc(Value, len) catch return error.OutOfMemory;
    errdefer slice_alloc.free(result);

    var iter = SequenceIterator.init(val, elem_alloc) orelse return error.TypeMismatch;
    var i: usize = 0;
    while (try iter.next()) |elem| {
        result[i] = elem;
        i += 1;
    }

    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "sequenceToValuesScratch splits slice and element allocators" {
    var elem_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer elem_arena.deinit();

    // The leak detector pins the split: codepoint dupes on the slice allocator would leak once
    // only the slice is freed.
    const items = try sequenceToValuesScratch(value_mod.stringValue("héllo"), std.testing.allocator, elem_arena.allocator());
    defer std.testing.allocator.free(items);

    try std.testing.expectEqual(@as(usize, 5), items.len);
    try std.testing.expectEqualStrings("h", items[0].string.bytes);
    try std.testing.expectEqualStrings("é", items[1].string.bytes);
    try std.testing.expectEqualStrings("o", items[4].string.bytes);
}

test "utf8CodepointCount" {
    try std.testing.expectEqual(@as(usize, 5), utf8CodepointCount("hello"));
    try std.testing.expectEqual(@as(usize, 4), utf8CodepointCount("café"));
    try std.testing.expectEqual(@as(usize, 3), utf8CodepointCount("日本語"));
    try std.testing.expectEqual(@as(usize, 0), utf8CodepointCount(""));
}

test "utf8NthCodepoint" {
    const s = "café";
    try std.testing.expectEqualStrings("c", utf8NthCodepoint(s, 0).?);
    try std.testing.expectEqualStrings("a", utf8NthCodepoint(s, 1).?);
    try std.testing.expectEqualStrings("f", utf8NthCodepoint(s, 2).?);
    try std.testing.expectEqualStrings("é", utf8NthCodepoint(s, 3).?);
    try std.testing.expect(utf8NthCodepoint(s, 4) == null);
}

test "utf8SliceByCodepoints" {
    const s = "café";
    const bounds = utf8SliceByCodepoints(s, 1, 3).?;
    try std.testing.expectEqualStrings("af", s[bounds.start_byte..bounds.end_byte]);
}

test "sequenceLength" {
    try std.testing.expectEqual(@as(?usize, 5), sequenceLength(value_mod.stringValue("hello")));
    try std.testing.expectEqual(@as(?usize, 4), sequenceLength(value_mod.stringValue("café")));

    var arr = value_mod.Array{
        .header = undefined,
        .items = &[_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } },
        .storage = .static,
    };
    try std.testing.expectEqual(@as(?usize, 2), sequenceLength(.{ .array = &arr }));
}

test "SequenceIterator over array" {
    const allocator = std.testing.allocator;
    var arr = value_mod.Array{
        .header = undefined,
        .items = &[_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 }, .{ .fixnum = 3 } },
        .storage = .static,
    };
    var iter = SequenceIterator.init(.{ .array = &arr }, allocator).?;

    try std.testing.expectEqual(@as(i64, 1), (try iter.next()).?.fixnum);
    try std.testing.expectEqual(@as(i64, 2), (try iter.next()).?.fixnum);
    try std.testing.expectEqual(@as(i64, 3), (try iter.next()).?.fixnum);
    try std.testing.expect((try iter.next()) == null);
}

test "SequenceIterator over string" {
    const allocator = std.testing.allocator;
    var iter = SequenceIterator.init(value_mod.stringValue("ab"), allocator).?;

    const a = (try iter.next()).?;
    defer allocator.free(a.string.bytes);
    try std.testing.expectEqualStrings("a", a.string.bytes);

    const b = (try iter.next()).?;
    defer allocator.free(b.string.bytes);
    try std.testing.expectEqualStrings("b", b.string.bytes);

    try std.testing.expect((try iter.next()) == null);
}

test "SequenceBuilder for array" {
    const allocator = std.testing.allocator;
    var builder = try SequenceBuilder.init(.array, allocator);

    try builder.append(.{ .fixnum = 1 });
    try builder.append(.{ .fixnum = 2 });

    const result = try builder.toValue();
    defer container_backing.releaseValue(result);

    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), result.array.items[0].fixnum);
    try std.testing.expectEqual(@as(i64, 2), result.array.items[1].fixnum);
}
