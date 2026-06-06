const std = @import("std");
const build_options = @import("build_options");
const data = @import("embedded_stdlib_data");

pub const Entry = data.Entry;
pub const entries: []const Entry = data.entries;

pub const virtual_prefix = "<stdlib>/";
pub const virtual_suffix = ".1z";

pub fn findEntry(name: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Return the module name encoded in a `<stdlib>/<name>.1z` virtual path,
/// or null if `resolved` is not a virtual stdlib path or has an empty name.
pub fn parseVirtualPath(resolved: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, resolved, virtual_prefix)) return null;
    if (!std.mem.endsWith(u8, resolved, virtual_suffix)) return null;
    const name = resolved[virtual_prefix.len .. resolved.len - virtual_suffix.len];
    if (name.len == 0) return null;
    return name;
}

test "embedded stdlib table is importable" {
    for (entries) |entry| {
        try std.testing.expect(entry.name.len > 0);
    }
}

test "embedded stdlib contains representative entries" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    const top_level = findEntry("strings") orelse return error.MissingEntry;
    try std.testing.expect(top_level.source.len > 0);

    const nested = findEntry("math/grid") orelse return error.MissingEntry;
    try std.testing.expect(nested.source.len > 0);
}

test "parseVirtualPath extracts top-level name" {
    const name = parseVirtualPath("<stdlib>/strings.1z") orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings("strings", name);
}

test "parseVirtualPath extracts nested name" {
    const name = parseVirtualPath("<stdlib>/math/grid.1z") orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings("math/grid", name);
}

test "parseVirtualPath rejects missing prefix" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseVirtualPath("strings.1z"));
    try std.testing.expectEqual(@as(?[]const u8, null), parseVirtualPath("/abs/strings.1z"));
}

test "parseVirtualPath rejects missing suffix" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseVirtualPath("<stdlib>/strings"));
}

test "parseVirtualPath rejects empty inner name" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseVirtualPath("<stdlib>/.1z"));
}

test "parseVirtualPath rejects empty input" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseVirtualPath(""));
}
