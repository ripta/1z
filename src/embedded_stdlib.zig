const std = @import("std");
const build_options = @import("build_options");
const data = @import("embedded_stdlib_data");

pub const Entry = data.Entry;
pub const entries: []const Entry = data.entries;

fn findEntry(name: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
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
