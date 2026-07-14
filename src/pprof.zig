//! pprof profile exporter. Hand-encodes the `profile.proto` wire format and wraps it in a gzip
//! container, so the interpreter's per-word sample data can be consumed by `go tool pprof` and the
//! wider pprof ecosystem.
//!
//! The encoder is pure formatting over an already-built wire-level model. The caller supplies the
//! string table, functions, locations, and samples; this module serializes them. Building that
//! model from the `--profile` sample buffer lives elsewhere.
//!
//! The gzip container uses uncompressed (stored) DEFLATE blocks. Zig 0.15.2's `std.compress.flate`
//! compressor does not compile (upstream ziglang/zig #25406), so the container is emitted by hand.
//! A stored gzip is a valid `.pb.gz` that every pprof tool reads.

const std = @import("std");

/// A `(type, unit)` pair naming one sample axis. Both are indices into the string table, per
/// `profile.proto` ValueType.
pub const ValueType = struct {
    type_idx: u64,
    unit_idx: u64,
};

/// A symbolized function. `id` must be unique and nonzero. `name_idx` indexes the string table.
pub const Function = struct {
    id: u64,
    name_idx: u64,
};

/// A program location mapping to a single function. `id` must be unique and nonzero. The line
/// number is omitted; pprof accepts a location whose function line carries no number.
pub const Location = struct {
    id: u64,
    function_id: u64,
};

/// One profile sample: a leaf-first location chain and one value per sample axis. `values` must
/// have the same length as `Profile.sample_types`.
pub const Sample = struct {
    location_ids: []const u64,
    values: []const i64,
};

/// A minimal pprof profile: enough of `profile.proto` to carry word-attributed samples with
/// function/location symbolization.
pub const Profile = struct {
    sample_types: []const ValueType,
    samples: []const Sample,
    locations: []const Location,
    functions: []const Function,

    /// The pprof string table. Index 0 must be the empty string.
    string_table: []const []const u8,

    /// String-table index naming the preferred sample-value type. pprof opens on this axis. Zero
    /// leaves it unset.
    default_sample_type: u64 = 0,
};

/// Protobuf wire types. Only the two the encoder emits are named.
const WireType = enum(u3) {
    varint = 0,
    len = 2,
};

const Bytes = std.ArrayListUnmanaged(u8);

fn appendVarint(list: *Bytes, alloc: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7f);
        v >>= 7;
        if (v == 0) {
            try list.append(alloc, byte);
            break;
        }
        try list.append(alloc, byte | 0x80);
    }
}

fn appendTag(list: *Bytes, alloc: std.mem.Allocator, field: u32, wire: WireType) !void {
    try appendVarint(list, alloc, (@as(u64, field) << 3) | @intFromEnum(wire));
}

fn appendVarintField(list: *Bytes, alloc: std.mem.Allocator, field: u32, value: u64) !void {
    try appendTag(list, alloc, field, .varint);
    try appendVarint(list, alloc, value);
}

fn appendLenField(list: *Bytes, alloc: std.mem.Allocator, field: u32, bytes: []const u8) !void {
    try appendTag(list, alloc, field, .len);
    try appendVarint(list, alloc, bytes.len);
    try list.appendSlice(alloc, bytes);
}

/// Serialize a repeated scalar field as a single packed length-delimited run of varints, the
/// encoding pprof uses for `location_id` and `value`.
fn appendPackedVarints(list: *Bytes, alloc: std.mem.Allocator, field: u32, values: anytype) !void {
    var packed_bytes: Bytes = .empty;
    defer packed_bytes.deinit(alloc);

    for (values) |v| {
        // protobuf int64 encodes as the two's-complement reinterpreted as a varint; uint64 encodes
        // directly. The signedness is comptime-known, so only the matching branch is analyzed.
        const bits: u64 = if (@typeInfo(@TypeOf(v)).int.signedness == .signed)
            @bitCast(@as(i64, v))
        else
            @as(u64, v);
        try appendVarint(&packed_bytes, alloc, bits);
    }

    try appendLenField(list, alloc, field, packed_bytes.items);
}

/// Encode `profile` into uncompressed `profile.proto` wire bytes. Caller owns the returned slice.
fn encodeProfile(alloc: std.mem.Allocator, profile: Profile) ![]u8 {
    var out: Bytes = .empty;
    errdefer out.deinit(alloc);

    var sub: Bytes = .empty;
    defer sub.deinit(alloc);

    for (profile.sample_types) |st| {
        sub.clearRetainingCapacity();
        try appendVarintField(&sub, alloc, 1, st.type_idx);
        try appendVarintField(&sub, alloc, 2, st.unit_idx);
        try appendLenField(&out, alloc, 1, sub.items);
    }

    for (profile.samples) |s| {
        sub.clearRetainingCapacity();
        try appendPackedVarints(&sub, alloc, 1, s.location_ids);
        try appendPackedVarints(&sub, alloc, 2, s.values);
        try appendLenField(&out, alloc, 2, sub.items);
    }

    for (profile.locations) |loc| {
        sub.clearRetainingCapacity();
        try appendVarintField(&sub, alloc, 1, loc.id);

        // A Location holds a repeated Line; each Line names its function.
        var line: Bytes = .empty;
        defer line.deinit(alloc);
        try appendVarintField(&line, alloc, 1, loc.function_id);
        try appendLenField(&sub, alloc, 4, line.items);

        try appendLenField(&out, alloc, 4, sub.items);
    }

    for (profile.functions) |fun| {
        sub.clearRetainingCapacity();
        try appendVarintField(&sub, alloc, 1, fun.id);
        try appendVarintField(&sub, alloc, 2, fun.name_idx);
        try appendLenField(&out, alloc, 5, sub.items);
    }

    for (profile.string_table) |str| {
        try appendLenField(&out, alloc, 6, str);
    }

    if (profile.default_sample_type != 0) {
        try appendVarintField(&out, alloc, 14, profile.default_sample_type);
    }

    return out.toOwnedSlice(alloc);
}

/// The largest payload a single stored DEFLATE block can carry. RFC 1951 stores the length in a u16.
const max_stored_block = 65535;

/// Wrap `data` in a gzip container built from uncompressed (stored) DEFLATE blocks. Caller owns the
/// returned slice.
fn gzipStored(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: Bytes = .empty;
    errdefer out.deinit(alloc);

    // RFC 1952 10-byte gzip header: magic 1f 8b, method 8 (deflate), no flags, zero mtime, no extra
    // flags, OS 3 (Unix).
    try out.appendSlice(alloc, &.{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 });

    var offset: usize = 0;
    while (true) {
        const remaining = data.len - offset;
        const chunk_len: u16 = @intCast(@min(remaining, max_stored_block));
        const is_final = offset + chunk_len >= data.len;

        // Stored block header: BFINAL bit then BTYPE 00, byte-aligned. LEN and its one's-complement
        // NLEN follow as little-endian u16s.
        try out.append(alloc, if (is_final) 0x01 else 0x00);
        try appendU16Le(&out, alloc, chunk_len);
        try appendU16Le(&out, alloc, ~chunk_len);
        try out.appendSlice(alloc, data[offset .. offset + chunk_len]);

        offset += chunk_len;
        if (is_final) break;
    }

    // RFC 1952 8-byte footer: CRC32 then input size, both mod 2^32, little-endian.
    try appendU32Le(&out, alloc, std.hash.Crc32.hash(data));
    try appendU32Le(&out, alloc, @truncate(data.len));

    return out.toOwnedSlice(alloc);
}

fn appendU16Le(list: *Bytes, alloc: std.mem.Allocator, value: u16) !void {
    try list.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, value)));
}

fn appendU32Le(list: *Bytes, alloc: std.mem.Allocator, value: u32) !void {
    try list.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
}

/// Encode `profile` as a gzipped `profile.proto` file. Caller owns the returned
/// slice.
pub fn encode(alloc: std.mem.Allocator, profile: Profile) ![]u8 {
    const proto = try encodeProfile(alloc, profile);
    defer alloc.free(proto);
    return gzipStored(alloc, proto);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Decode one LEB128 varint from `bytes` at `pos`, advancing `pos` past it.
fn readVarint(bytes: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= bytes.len) return error.Truncated;
        const byte = bytes[pos.*];
        pos.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

/// Inflate the stored-block gzip `gzipStored` emits and verify its footer. Only the exact container
/// this module produces is handled.
pub fn inflateStored(alloc: std.mem.Allocator, gz: []const u8) ![]u8 {
    try testing.expect(gz.len >= 18);
    try testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try testing.expectEqual(@as(u8, 0x8b), gz[1]);
    try testing.expectEqual(@as(u8, 0x08), gz[2]);
    try testing.expectEqual(@as(u8, 0x00), gz[3]); // no flags

    var out: Bytes = .empty;
    errdefer out.deinit(alloc);

    var pos: usize = 10;
    while (true) {
        const header = gz[pos];
        pos += 1;
        const is_final = header & 0x01 == 1;
        try testing.expectEqual(@as(u8, 0), (header >> 1) & 0x03); // BTYPE 00 (stored)

        const len = std.mem.readInt(u16, gz[pos..][0..2], .little);
        const nlen = std.mem.readInt(u16, gz[pos + 2 ..][0..2], .little);
        try testing.expectEqual(len, ~nlen);
        pos += 4;

        try out.appendSlice(alloc, gz[pos .. pos + len]);
        pos += len;
        if (is_final) break;
    }

    const crc = std.mem.readInt(u32, gz[pos..][0..4], .little);
    const input_size = std.mem.readInt(u32, gz[pos + 4 ..][0..4], .little);
    try testing.expectEqual(std.hash.Crc32.hash(out.items), crc);
    try testing.expectEqual(@as(u32, @truncate(out.items.len)), input_size);

    return out.toOwnedSlice(alloc);
}

/// A field parsed from a protobuf message: its number plus either a scalar varint or a
/// length-delimited slice.
pub const Field = struct {
    number: u32,
    varint: u64 = 0,
    bytes: []const u8 = &.{},
};

/// Walk every top-level field of a protobuf message. Only varint and length-delimited wire types
/// appear in `profile.proto`.
pub fn parseFields(alloc: std.mem.Allocator, msg: []const u8) ![]Field {
    var fields: std.ArrayListUnmanaged(Field) = .empty;
    errdefer fields.deinit(alloc);

    var pos: usize = 0;
    while (pos < msg.len) {
        const tag = try readVarint(msg, &pos);
        const number: u32 = @intCast(tag >> 3);
        const wire: u3 = @intCast(tag & 0x7);
        switch (wire) {
            0 => {
                const v = try readVarint(msg, &pos);
                try fields.append(alloc, .{ .number = number, .varint = v });
            },
            2 => {
                const len = try readVarint(msg, &pos);
                const slice = msg[pos .. pos + len];
                pos += len;
                try fields.append(alloc, .{ .number = number, .bytes = slice });
            },
            else => return error.UnexpectedWireType,
        }
    }

    return fields.toOwnedSlice(alloc);
}

/// Collect the packed varints in a length-delimited field body.
pub fn parsePacked(alloc: std.mem.Allocator, body: []const u8) ![]u64 {
    var out: std.ArrayListUnmanaged(u64) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    while (pos < body.len) {
        try out.append(alloc, try readVarint(body, &pos));
    }
    return out.toOwnedSlice(alloc);
}

test "appendVarint / readVarint round-trip across boundaries" {
    const alloc = testing.allocator;
    const cases = [_]u64{ 0, 1, 127, 128, 300, 16383, 16384, 0xffffffff, 0xffffffffffffffff };
    for (cases) |c| {
        var list: Bytes = .empty;
        defer list.deinit(alloc);
        try appendVarint(&list, alloc, c);
        var pos: usize = 0;
        try testing.expectEqual(c, try readVarint(list.items, &pos));
        try testing.expectEqual(list.items.len, pos);
    }
}

test "encodeProfile emits sample types, functions, locations, and string table" {
    const alloc = testing.allocator;

    const profile: Profile = .{
        .sample_types = &.{.{ .type_idx = 1, .unit_idx = 2 }},
        .functions = &.{.{ .id = 1, .name_idx = 3 }},
        .locations = &.{.{ .id = 1, .function_id = 1 }},
        .samples = &.{.{ .location_ids = &.{1}, .values = &.{42} }},
        .string_table = &.{ "", "wall", "nanoseconds", "double" },
        .default_sample_type = 1,
    };

    const proto = try encodeProfile(alloc, profile);
    defer alloc.free(proto);

    const fields = try parseFields(alloc, proto);
    defer alloc.free(fields);

    var saw_sample_type = false;
    var saw_function = false;
    var saw_location = false;
    var string_count: usize = 0;
    var default_type: u64 = 0;

    for (fields) |f| {
        switch (f.number) {
            1 => {
                saw_sample_type = true;
                const inner = try parseFields(alloc, f.bytes);
                defer alloc.free(inner);
                try testing.expectEqual(@as(u64, 1), inner[0].varint);
                try testing.expectEqual(@as(u64, 2), inner[1].varint);
            },
            5 => {
                saw_function = true;
                const inner = try parseFields(alloc, f.bytes);
                defer alloc.free(inner);
                try testing.expectEqual(@as(u64, 1), inner[0].varint); // id
                try testing.expectEqual(@as(u64, 3), inner[1].varint); // name_idx
            },
            4 => {
                saw_location = true;
                const inner = try parseFields(alloc, f.bytes);
                defer alloc.free(inner);
                try testing.expectEqual(@as(u64, 1), inner[0].varint); // id
                // Nested Line names function 1.
                const line = try parseFields(alloc, inner[1].bytes);
                defer alloc.free(line);
                try testing.expectEqual(@as(u64, 1), line[0].varint);
            },
            6 => string_count += 1,
            14 => default_type = f.varint,
            else => {},
        }
    }

    try testing.expect(saw_sample_type);
    try testing.expect(saw_function);
    try testing.expect(saw_location);
    try testing.expectEqual(@as(usize, 4), string_count);
    try testing.expectEqual(@as(u64, 1), default_type);
}

test "gzipStored round-trips arbitrary bytes and validates the footer" {
    const alloc = testing.allocator;
    const inputs = [_][]const u8{ "", "x", "hello pprof profile bytes" };
    for (inputs) |input| {
        const gz = try gzipStored(alloc, input);
        defer alloc.free(gz);
        const plain = try inflateStored(alloc, gz);
        defer alloc.free(plain);
        try testing.expectEqualSlices(u8, input, plain);
    }
}

test "gzipStored chunks payloads larger than one stored block" {
    const alloc = testing.allocator;
    const big = try alloc.alloc(u8, max_stored_block * 2 + 7);
    defer alloc.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);

    const gz = try gzipStored(alloc, big);
    defer alloc.free(gz);
    const plain = try inflateStored(alloc, gz);
    defer alloc.free(plain);
    try testing.expectEqualSlices(u8, big, plain);
}

test "encode: a known two-frame nested sample round-trips" {
    const alloc = testing.allocator;

    // string_table: "", "outer", "inner", "wall", "nanoseconds", "calls", "count".
    const profile: Profile = .{
        .sample_types = &.{
            .{ .type_idx = 3, .unit_idx = 4 },
            .{ .type_idx = 5, .unit_idx = 6 },
        },
        .functions = &.{
            .{ .id = 1, .name_idx = 1 }, // outer
            .{ .id = 2, .name_idx = 2 }, // inner
        },
        .locations = &.{
            .{ .id = 1, .function_id = 1 },
            .{ .id = 2, .function_id = 2 },
        },
        // Leaf-first chain: inner (loc 2) then outer (loc 1).
        .samples = &.{.{ .location_ids = &.{ 2, 1 }, .values = &.{ 60, 1 } }},
        .string_table = &.{ "", "outer", "inner", "wall", "nanoseconds", "calls", "count" },
        .default_sample_type = 3,
    };

    const gz = try encode(alloc, profile);
    defer alloc.free(gz);

    const proto = try inflateStored(alloc, gz);
    defer alloc.free(proto);

    const fields = try parseFields(alloc, proto);
    defer alloc.free(fields);

    var sample_types: usize = 0;
    var functions: usize = 0;
    var locations: usize = 0;
    var strings: usize = 0;
    var checked_sample = false;

    for (fields) |f| {
        switch (f.number) {
            1 => sample_types += 1,
            5 => functions += 1,
            4 => locations += 1,
            6 => strings += 1,
            2 => {
                checked_sample = true;
                const inner = try parseFields(alloc, f.bytes);
                defer alloc.free(inner);

                const loc_ids = try parsePacked(alloc, inner[0].bytes);
                defer alloc.free(loc_ids);
                try testing.expectEqualSlices(u64, &.{ 2, 1 }, loc_ids);

                const values = try parsePacked(alloc, inner[1].bytes);
                defer alloc.free(values);
                try testing.expectEqualSlices(u64, &.{ 60, 1 }, values);
            },
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 2), sample_types);
    try testing.expectEqual(@as(usize, 2), functions);
    try testing.expectEqual(@as(usize, 2), locations);
    try testing.expectEqual(@as(usize, 7), strings);
    try testing.expect(checked_sample);
}
