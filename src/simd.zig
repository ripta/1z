const std = @import("std");

const chunk_len = 16;
const U8x16 = @Vector(chunk_len, u8);

/// uppercaseAscii ( bytes -- ) - Convert ASCII lowercase to uppercase in-place, 16-byte SIMD chunks
pub fn uppercaseAscii(bytes: []u8) void {
    const lower_a: U8x16 = @splat('a');
    const lower_z: U8x16 = @splat('z');
    const offset: U8x16 = @splat('a' - 'A');

    var i: usize = 0;
    while (i + chunk_len <= bytes.len) : (i += chunk_len) {
        const v: U8x16 = bytes[i..][0..chunk_len].*;
        const is_lower = (v >= lower_a) & (v <= lower_z);
        bytes[i..][0..chunk_len].* = @select(u8, is_lower, v - offset, v);
    }
    for (bytes[i..]) |*b| {
        if (b.* >= 'a' and b.* <= 'z') b.* -= ('a' - 'A');
    }
}

/// lowercaseAscii ( bytes -- ) - Convert ASCII uppercase to lowercase in-place, 16-byte SIMD chunks
pub fn lowercaseAscii(bytes: []u8) void {
    const upper_a: U8x16 = @splat('A');
    const upper_z: U8x16 = @splat('Z');
    const offset: U8x16 = @splat('a' - 'A');

    var i: usize = 0;
    while (i + chunk_len <= bytes.len) : (i += chunk_len) {
        const v: U8x16 = bytes[i..][0..chunk_len].*;
        const is_upper = (v >= upper_a) & (v <= upper_z);
        bytes[i..][0..chunk_len].* = @select(u8, is_upper, v + offset, v);
    }
    for (bytes[i..]) |*b| {
        if (b.* >= 'A' and b.* <= 'Z') b.* += ('a' - 'A');
    }
}

/// indexOfScalar ( haystack needle -- ?usize ) - Find first occurrence of byte, 16-byte SIMD chunks
pub fn indexOfScalar(haystack: []const u8, needle: u8) ?usize {
    const splat_needle: U8x16 = @splat(needle);

    var i: usize = 0;
    while (i + chunk_len <= haystack.len) : (i += chunk_len) {
        const v: U8x16 = haystack[i..][0..chunk_len].*;
        const matches = v == splat_needle;
        const mask: u16 = @bitCast(matches);
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }
    for (haystack[i..], i..) |b, idx| {
        if (b == needle) return idx;
    }
    return null;
}

/// eqlBytes ( a b -- bool ) - Compare byte slices for equality, 16-byte SIMD chunks
pub fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;

    const zero: U8x16 = @splat(0);

    var i: usize = 0;
    while (i + chunk_len <= a.len) : (i += chunk_len) {
        const va: U8x16 = a[i..][0..chunk_len].*;
        const vb: U8x16 = b[i..][0..chunk_len].*;
        const xor = va ^ vb;
        if (@reduce(.Or, xor != zero)) return false;
    }
    return std.mem.eql(u8, a[i..], b[i..]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "uppercaseAscii: empty" {
    var buf = [_]u8{};
    uppercaseAscii(&buf);
}

test "uppercaseAscii: single char" {
    var buf = [_]u8{'a'};
    uppercaseAscii(&buf);
    try testing.expectEqualStrings("A", &buf);
}

test "uppercaseAscii: non-alpha passthrough" {
    var buf = [_]u8{ '1', '!', ' ', 0xFF };
    const expected = [_]u8{ '1', '!', ' ', 0xFF };
    uppercaseAscii(&buf);
    try testing.expectEqualSlices(u8, &expected, &buf);
}

test "uppercaseAscii: 15 bytes (scalar tail only)" {
    var buf = "abcdefghijklmno".*;
    uppercaseAscii(&buf);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNO", &buf);
}

test "uppercaseAscii: 16 bytes (one SIMD chunk, no tail)" {
    var buf = "abcdefghijklmnop".*;
    uppercaseAscii(&buf);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOP", &buf);
}

test "uppercaseAscii: 17 bytes (one chunk + 1-byte tail)" {
    var buf = "abcdefghijklmnopq".*;
    uppercaseAscii(&buf);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOPQ", &buf);
}

test "uppercaseAscii: 32 bytes (two chunks)" {
    var buf = "abcdefghijklmnopqrstuvwxyz012345".*;
    uppercaseAscii(&buf);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", &buf);
}

test "uppercaseAscii: 33 bytes (two chunks + tail)" {
    var buf = "abcdefghijklmnopqrstuvwxyz0123456".*;
    uppercaseAscii(&buf);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456", &buf);
}

test "uppercaseAscii: already uppercase" {
    var buf = "ABCDEFGHIJKLMNOP".*;
    uppercaseAscii(&buf);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOP", &buf);
}

test "uppercaseAscii: high bytes preserved" {
    var buf = [_]u8{ 0x80, 0xC0, 0xFE, 0xFF, 'a', 'z' };
    uppercaseAscii(&buf);
    const expected = [_]u8{ 0x80, 0xC0, 0xFE, 0xFF, 'A', 'Z' };
    try testing.expectEqualSlices(u8, &expected, &buf);
}

test "lowercaseAscii: empty" {
    var buf = [_]u8{};
    lowercaseAscii(&buf);
}

test "lowercaseAscii: single char" {
    var buf = [_]u8{'A'};
    lowercaseAscii(&buf);
    try testing.expectEqualStrings("a", &buf);
}

test "lowercaseAscii: 15 bytes" {
    var buf = "ABCDEFGHIJKLMNO".*;
    lowercaseAscii(&buf);
    try testing.expectEqualStrings("abcdefghijklmno", &buf);
}

test "lowercaseAscii: 16 bytes" {
    var buf = "ABCDEFGHIJKLMNOP".*;
    lowercaseAscii(&buf);
    try testing.expectEqualStrings("abcdefghijklmnop", &buf);
}

test "lowercaseAscii: 17 bytes" {
    var buf = "ABCDEFGHIJKLMNOPQ".*;
    lowercaseAscii(&buf);
    try testing.expectEqualStrings("abcdefghijklmnopq", &buf);
}

test "lowercaseAscii: 33 bytes" {
    var buf = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456".*;
    lowercaseAscii(&buf);
    try testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz0123456", &buf);
}

test "lowercaseAscii: already lowercase" {
    var buf = "abcdefghijklmnop".*;
    lowercaseAscii(&buf);
    try testing.expectEqualStrings("abcdefghijklmnop", &buf);
}

test "indexOfScalar: empty" {
    try testing.expectEqual(null, indexOfScalar("", 'a'));
}

test "indexOfScalar: not found" {
    try testing.expectEqual(null, indexOfScalar("hello world", 'z'));
}

test "indexOfScalar: at position 0" {
    try testing.expectEqual(0, indexOfScalar("abcdef", 'a'));
}

test "indexOfScalar: at position 15 (last byte before chunk boundary)" {
    const hay = "_______________x";
    try testing.expectEqual(15, indexOfScalar(hay, 'x'));
}

test "indexOfScalar: at position 16 (first byte of second chunk / scalar tail)" {
    const hay = "________________x";
    try testing.expectEqual(16, indexOfScalar(hay, 'x'));
}

test "indexOfScalar: at position 17" {
    const hay = "_________________x";
    try testing.expectEqual(17, indexOfScalar(hay, 'x'));
}

test "indexOfScalar: multiple occurrences returns first" {
    try testing.expectEqual(2, indexOfScalar("__x__x__", 'x'));
}

test "indexOfScalar: all bytes match" {
    try testing.expectEqual(0, indexOfScalar("aaaa", 'a'));
}

test "indexOfScalar: 32-byte haystack match in second chunk" {
    const hay = "0123456789abcdef" ++ "GHIJKLMNOPQRSTUV";
    try testing.expectEqual(16, indexOfScalar(hay, 'G'));
}

test "eqlBytes: both empty" {
    try testing.expect(eqlBytes("", ""));
}

test "eqlBytes: different lengths" {
    try testing.expect(!eqlBytes("abc", "ab"));
}

test "eqlBytes: same pointer" {
    const s: []const u8 = "hello";
    try testing.expect(eqlBytes(s, s));
}

test "eqlBytes: equal 1 byte" {
    try testing.expect(eqlBytes("x", "x"));
}

test "eqlBytes: unequal 1 byte" {
    try testing.expect(!eqlBytes("x", "y"));
}

test "eqlBytes: equal 15 bytes" {
    try testing.expect(eqlBytes("abcdefghijklmno", "abcdefghijklmno"));
}

test "eqlBytes: equal 16 bytes" {
    try testing.expect(eqlBytes("abcdefghijklmnop", "abcdefghijklmnop"));
}

test "eqlBytes: equal 17 bytes" {
    try testing.expect(eqlBytes("abcdefghijklmnopq", "abcdefghijklmnopq"));
}

test "eqlBytes: equal 33 bytes" {
    try testing.expect(eqlBytes(
        "abcdefghijklmnopqrstuvwxyz0123456",
        "abcdefghijklmnopqrstuvwxyz0123456",
    ));
}

test "eqlBytes: unequal at first byte" {
    try testing.expect(!eqlBytes("Xbcdefghijklmnop", "abcdefghijklmnop"));
}

test "eqlBytes: unequal at last byte" {
    try testing.expect(!eqlBytes("abcdefghijklmnoP", "abcdefghijklmnop"));
}

test "eqlBytes: unequal at byte 16 (second chunk)" {
    try testing.expect(!eqlBytes(
        "abcdefghijklmnopX",
        "abcdefghijklmnopq",
    ));
}
