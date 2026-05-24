//! Tree sweep for the consumer-native refcount tripwire.
//!
//! Walks a directory of Zig sources (default `src/primitives`), runs the pure
//! `scanSource` heuristic on each `.zig` file, prints any violation as
//! `path:line: refcount-audit: ...`, and exits non-zero if any are found. Wired
//! into the `test` build step (and `make refcount-check`) so the audited tree is
//! checked on every test run; the directory walk auto-covers newly added files.

const std = @import("std");
const audit = @import("refcount_audit.zig");

const MAX_FILE_BYTES = 16 * 1024 * 1024;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    const dir_path = if (args.len > 1) args[1] else "src/primitives";

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("refcount-audit: cannot open '{s}': {s}\n", .{ dir_path, @errorName(err) });
        std.process.exit(2);
    };
    defer dir.close();

    // Collect and sort file names so output ordering is deterministic across
    // platforms.
    var names: std.ArrayListUnmanaged([]const u8) = .{};
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanName);

    var err_buffer: [4096]u8 = undefined;
    var err = std.fs.File.stderr().writer(&err_buffer);
    const w = &err.interface;

    var total: usize = 0;
    for (names.items) |name| {
        const display = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, name });
        const source = try dir.readFileAlloc(arena, name, MAX_FILE_BYTES);
        const violations = try audit.scanSource(arena, display, source);
        for (violations) |v| {
            try w.print(
                "{s}:{d}: refcount-audit: native pops '{s}' without a matching release\n",
                .{ v.file, v.line, v.name },
            );
            total += 1;
        }
    }

    if (total > 0) {
        try w.print("refcount-audit: {d} violation(s) found in {s}\n", .{ total, dir_path });
        try w.flush();
        std.process.exit(1);
    }

    try w.print("refcount-audit: {d} files clean in {s}\n", .{ names.items.len, dir_path });
    try w.flush();
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
