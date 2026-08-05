//! JIT native-code byte dumps for `--dump-jit-bytes` and `--dump-jit-bin-dir`.
//!
//! Dumps the raw machine code a runtime JIT word emitted, either as an xxd-compatible hex block
//! on stderr or as one binary file per word. This is a portable inspection path that links no
//! disassembler. A dump failure is a non-fatal stderr diagnostic and never changes program
//! semantics.

const std = @import("std");

/// Which dump sinks are enabled, mirroring the `--dump-jit-bytes` and `--dump-jit-bin-dir` flags.
pub const DumpConfig = struct {
    dump_bytes: bool = false,
    bin_dir: ?[]const u8 = null,

    pub fn enabled(self: DumpConfig) bool {
        return self.dump_bytes or self.bin_dir != null;
    }
};

/// Dump a freshly-compiled word's emitted bytes to whichever sinks `cfg` enables. Routed through
/// one helper taking word id, name, code pointer, and size so a future on-demand dump command can
/// reuse it.
pub fn dumpJitCode(cfg: DumpConfig, name: []const u8, word_id: u32, code_ptr: *const anyopaque, size: usize) void {
    const bytes = @as([*]const u8, @ptrCast(code_ptr))[0..size];

    if (cfg.dump_bytes) {
        writeTextDump(name, word_id, @intFromPtr(code_ptr), bytes);
    }

    if (cfg.bin_dir) |dir| {
        writeBinToDir(dir, name, word_id, bytes);
    }
}

/// Format an xxd-compatible hex block. A header line names the word, then each body line carries
/// an eight-digit offset and sixteen bytes in two-byte groups. No ASCII column; `xxd -r` reverses
/// this exactly.
fn formatHexDump(w: anytype, name: []const u8, word_id: u32, ptr_addr: usize, bytes: []const u8) !void {
    try w.print("JIT bytes {s} (wid={d}, ptr=0x{x}, size={d})\n", .{ name, word_id, ptr_addr, bytes.len });

    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 16) {
        try w.print("{x:0>8}:", .{offset});

        const line_end = @min(offset + 16, bytes.len);
        var i = offset;
        while (i < line_end) : (i += 1) {
            if ((i - offset) % 2 == 0) try w.writeByte(' ');
            try w.print("{x:0>2}", .{bytes[i]});
        }

        try w.writeByte('\n');
    }
}

fn writeTextDump(name: []const u8, word_id: u32, ptr_addr: usize, bytes: []const u8) void {
    var buf: [4096]u8 = undefined;
    // Streaming, not positional: a positional writer starts at offset 0 and would overwrite
    // the previous dump when stderr is a regular file.
    var fw = std.fs.File.stderr().writerStreaming(&buf);
    formatHexDump(&fw.interface, name, word_id, ptr_addr, bytes) catch return;
    fw.interface.flush() catch return;
}

/// Copy `name` into `out`, keeping ASCII alphanumerics, `_`, `.`, and `-` and replacing every
/// other byte with `_`. Truncates to `out`'s length.
fn sanitizeName(name: []const u8, out: []u8) []u8 {
    const n = @min(name.len, out.len);
    for (name[0..n], 0..) |c, i| {
        out[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-' => c,
            else => '_',
        };
    }
    return out[0..n];
}

fn writeBinFileTo(dir: std.fs.Dir, name: []const u8, word_id: u32, bytes: []const u8) !void {
    var name_buf: [512]u8 = undefined;
    const sanitized = sanitizeName(name, &name_buf);

    var path_buf: [640]u8 = undefined;
    const filename = try std.fmt.bufPrint(&path_buf, "{d:0>6}-{s}.bin", .{ word_id, sanitized });

    const file = try dir.createFile(filename, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn writeBinToDir(dir_path: []const u8, name: []const u8, word_id: u32, bytes: []const u8) void {
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch |err| {
        reportFailure(name, word_id, err);
        return;
    };
    defer dir.close();

    writeBinFileTo(dir, name, word_id, bytes) catch |err| reportFailure(name, word_id, err);
}

fn reportFailure(name: []const u8, word_id: u32, err: anyerror) void {
    var buf: [256]u8 = undefined;
    var fw = std.fs.File.stderr().writerStreaming(&buf);
    fw.interface.print(
        "Warning: failed to dump JIT bytes for {s} (wid={d}): {s}\n",
        .{ name, word_id, @errorName(err) },
    ) catch return;
    fw.interface.flush() catch return;
}

test "formatHexDump: header and xxd body for known bytes" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const bytes = [_]u8{ 0x55, 0x48, 0x89, 0xe5 };
    try formatHexDump(&w, "double", 7, 0x1000, &bytes);

    try std.testing.expectEqualStrings(
        "JIT bytes double (wid=7, ptr=0x1000, size=4)\n" ++
            "00000000: 5548 89e5\n",
        w.buffered(),
    );
}

test "formatHexDump: wraps at sixteen bytes per line" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    var bytes: [18]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i);
    try formatHexDump(&w, "w", 1, 0x2000, &bytes);

    try std.testing.expectEqualStrings(
        "JIT bytes w (wid=1, ptr=0x2000, size=18)\n" ++
            "00000000: 0001 0203 0405 0607 0809 0a0b 0c0d 0e0f\n" ++
            "00000010: 1011\n",
        w.buffered(),
    );
}

test "sanitizeName: keeps allowlist, replaces others" {
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a_b.c-d_9", sanitizeName("a/b.c-d 9", &out));
    try std.testing.expectEqualStrings("_float", sanitizeName(">float", &out));
}

test "writeBinFileTo: writes named nonempty file with exact bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    try writeBinFileTo(tmp.dir, "double", 123, &bytes);

    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "000123-double.bin", 64);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualSlices(u8, &bytes, contents);
}

test "writeBinToDir: missing directory is non-fatal" {
    const bytes = [_]u8{0x90};
    // A path guaranteed not to exist. The call must return without propagating,
    // proving a dump failure never forces interpreter execution or a crash.
    writeBinToDir("does-not-exist-9d2f/nested", "w", 1, &bytes);
}
