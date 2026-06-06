const std = @import("std");
const data = @import("embedded_stdlib_data");

pub const Entry = data.Entry;
pub const entries: []const Entry = data.entries;

test "embedded stdlib table is importable" {
    for (entries) |entry| {
        try std.testing.expect(entry.name.len > 0);
    }
}
