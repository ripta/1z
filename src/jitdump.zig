//! Writer for the jitdump format that samply and `perf inject --jit` read.
//!
//! The file is `DIR/jit-<pid>.dump`. It opens with a header and then takes one load record per
//! compiled body, each carrying the code bytes. A load record is timestamped, so a sampler gives
//! an address reused by a later body that body's name from the record onward. Nothing is written
//! when code is unmapped, since unmapped code takes no samples.
//!
//! samply on macOS finds the file by interposing the process's libc `open()` of any `jit-*.dump`,
//! so the open goes through `open` and not `openat`. It sends that path to a separate process, so
//! the path must be absolute and at most `max_samply_path_len` bytes. `perf` on Linux finds the file
//! from an executable mapping of it, so Linux maps the first page `PROT_EXEC` and keeps it mapped.
//!
//! Timestamps are nanoseconds on the clock the sampler compares samples against. On Linux that is
//! `CLOCK_MONOTONIC`. On macOS it is `mach_absolute_time` scaled by `mach_timebase_info`. Raw mach
//! ticks would be off by the timebase ratio on Apple silicon.
//!
//! The mutex is a leaf. Nothing that locks is called while it is held.

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

const header_magic: u32 = 0x4A695444;
const header_version: u32 = 1;
const header_size = 40;
const load_record_size = 56;
const record_load: u32 = 0;
const record_close: u32 = 3;

/// samply's preload keeps the path in a 256-byte message after a 12-byte prefix, and ignores a
/// longer one without any diagnostic.
pub const max_samply_path_len = 256 - 12;

pub const OpenError = error{
    Unsupported,
    PathTooLong,
    DirectoryUnavailable,
    OpenFailed,
    MapFailed,
    HeaderWriteFailed,
    OutOfMemory,
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    fd: posix.fd_t,
    map: ?[]align(std.heap.page_size_min) u8 = null,
    path: []u8,
    pid: u32,
    next_index: u64 = 1,
    /// The file length after the last whole record, which a failed append truncates back to.
    offset: usize = header_size,
    last_timestamp: u64 = 0,
    disabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    warnings: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Create `DIR/jit-<pid>.dump` and write its header. `dir` may be relative. The path handed to
    /// the sampler is made absolute here.
    pub fn open(allocator: std.mem.Allocator, dir: []const u8) OpenError!*Writer {
        if (comptime !supported) return error.Unsupported;

        const real_dir = std.fs.cwd().realpathAlloc(allocator, dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.DirectoryUnavailable,
        };
        defer allocator.free(real_dir);

        const pid: u32 = @intCast(std.c.getpid());
        const path = try std.fmt.allocPrint(allocator, "{s}/jit-{d}.dump", .{ real_dir, pid });
        errdefer allocator.free(path);

        if (builtin.os.tag == .macos and path.len > max_samply_path_len) return error.PathTooLong;

        const fd = posix.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644) catch
            return error.OpenFailed;
        errdefer posix.close(fd);

        const self = try allocator.create(Writer);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .fd = fd, .path = path, .pid = pid };

        if (builtin.os.tag == .linux) {
            self.map = posix.mmap(
                null,
                std.heap.pageSize(),
                posix.PROT.READ | posix.PROT.EXEC,
                .{ .TYPE = .PRIVATE },
                fd,
                0,
            ) catch return error.MapFailed;
        }
        errdefer if (self.map) |m| posix.munmap(m);

        var header: [header_size]u8 = undefined;
        encodeHeader(&header, pid, timestamp());
        writeAll(fd, &header) catch return error.HeaderWriteFailed;

        return self;
    }

    /// Append the close record, then release the file and the mapping.
    pub fn close(self: *Writer) void {
        if (comptime !supported) return;

        if (!self.disabled.load(.acquire)) {
            var rec: [16]u8 = undefined;
            self.mutex.lock();
            encodeRecordHeader(&rec, record_close, rec.len, self.stampLocked());
            self.appendLocked(&.{&rec}) catch {};
            self.mutex.unlock();
        }

        if (self.map) |m| posix.munmap(m);
        posix.close(self.fd);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Append a load record naming the code at `code_ptr[0..size]`.
    ///
    /// A write failure prints one warning and stops the map for the rest of the run.
    pub fn recordLoad(self: *Writer, name: []const u8, code_ptr: *const anyopaque, size: usize) void {
        if (comptime !supported) return;
        if (self.disabled.load(.acquire)) return;

        const code: [*]const u8 = @ptrCast(code_ptr);
        const name_len = name.len + 1;

        var rec: [load_record_size]u8 = undefined;
        const tid: u32 = @truncate(std.Thread.getCurrentId());

        self.mutex.lock();
        defer self.mutex.unlock();

        // The timestamp is taken under the lock so records appear in non-decreasing time order.
        encodeRecordHeader(&rec, record_load, @intCast(load_record_size + name_len + size), self.stampLocked());
        writeInt(&rec, 16, u32, self.pid);
        writeInt(&rec, 20, u32, tid);
        writeInt(&rec, 24, u64, @intFromPtr(code_ptr));
        writeInt(&rec, 32, u64, @intFromPtr(code_ptr));
        writeInt(&rec, 40, u64, size);
        writeInt(&rec, 48, u64, self.next_index);

        self.next_index += 1;

        self.appendLocked(&.{ &rec, name, &[_]u8{0}, code[0..size] }) catch return self.fail();
    }

    /// Append the parts as one record with a single `writev`. A short or failed write is rolled
    /// back by truncating to the record's start, so a reader never meets half a record.
    fn appendLocked(self: *Writer, parts: []const []const u8) posix.WriteError!void {
        var remaining: usize = 0;
        for (parts) |p| remaining += p.len;
        const total = remaining;

        var part: usize = 0;
        var skip: usize = 0;
        var iov: [4]posix.iovec_const = undefined;

        while (remaining != 0) {
            var n: usize = 0;
            for (parts[part..]) |p| {
                const start: usize = if (n == 0) skip else 0;
                const bytes = p[start..];
                if (bytes.len == 0) continue;
                iov[n] = .{ .base = bytes.ptr, .len = bytes.len };
                n += 1;
            }

            const written = posix.writev(self.fd, iov[0..n]) catch |err| {
                _ = std.c.ftruncate(self.fd, @intCast(self.offset));
                return err;
            };

            remaining -= written;
            skip += written;
            while (part < parts.len and skip >= parts[part].len) {
                skip -= parts[part].len;
                part += 1;
            }
        }

        self.offset += total;
    }

    fn stampLocked(self: *Writer) u64 {
        const now = timestamp();
        if (now > self.last_timestamp) self.last_timestamp = now;
        return self.last_timestamp;
    }

    fn fail(self: *Writer) void {
        self.disabled.store(true, .release);
        if (self.warnings.fetchAdd(1, .acq_rel) != 0) return;
        std.debug.print("Warning: writing {s} failed; JIT symbol names stop here for the rest of the run.\n", .{self.path});
    }
};

fn writeInt(buf: []u8, offset: usize, comptime T: type, value: T) void {
    std.mem.writeInt(T, buf[offset..][0..@sizeOf(T)], value, builtin.cpu.arch.endian());
}

fn encodeRecordHeader(buf: []u8, event: u32, size: u32, stamp: u64) void {
    writeInt(buf, 0, u32, event);
    writeInt(buf, 4, u32, size);
    writeInt(buf, 8, u64, stamp);
}

fn elfMachine() u32 {
    return switch (builtin.cpu.arch) {
        .aarch64 => 183,
        .x86_64 => 62,
        .riscv64 => 243,
        else => 0,
    };
}

fn encodeHeader(buf: *[header_size]u8, pid: u32, stamp: u64) void {
    writeInt(buf, 0, u32, header_magic);
    writeInt(buf, 4, u32, header_version);
    writeInt(buf, 8, u32, header_size);
    writeInt(buf, 12, u32, elfMachine());
    writeInt(buf, 16, u32, 0);
    writeInt(buf, 20, u32, pid);
    writeInt(buf, 24, u64, stamp);
    writeInt(buf, 32, u64, 0);
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) posix.WriteError!void {
    var rest = bytes;
    while (rest.len != 0) {
        const n = try posix.write(fd, rest);
        rest = rest[n..];
    }
}

fn timestamp() u64 {
    if (comptime !supported) return 0;

    if (comptime builtin.os.tag == .macos) {
        const info = struct {
            var value: std.c.mach_timebase_info_data = .{ .numer = 0, .denom = 0 };
        };
        if (info.value.denom == 0) {
            var tb: std.c.mach_timebase_info_data = undefined;
            if (std.c.mach_timebase_info(&tb) != 0 or tb.denom == 0) {
                tb = .{ .numer = 1, .denom = 1 };
            }
            info.value = tb;
        }

        const ticks: u128 = std.c.mach_absolute_time();
        return @intCast(ticks * info.value.numer / info.value.denom);
    }

    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const testing = std.testing;

pub const ParsedLoad = struct {
    stamp: u64,
    pid: u32,
    tid: u32,
    vma: u64,
    code_addr: u64,
    code_size: u64,
    index: u64,
    name: []const u8,
    code: []const u8,
};

pub const Parsed = struct {
    header_pid: u32,
    header_stamp: u64,
    loads: std.ArrayListUnmanaged(ParsedLoad) = .{},
    closed: bool = false,

    pub fn deinit(self: *Parsed) void {
        self.loads.deinit(testing.allocator);
    }
};

fn readInt(bytes: []const u8, offset: usize, comptime T: type) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], builtin.cpu.arch.endian());
}

pub fn parseDump(bytes: []const u8) !Parsed {
    try testing.expect(bytes.len >= header_size);
    try testing.expectEqual(header_magic, readInt(bytes, 0, u32));
    try testing.expectEqual(header_version, readInt(bytes, 4, u32));
    try testing.expectEqual(@as(u32, header_size), readInt(bytes, 8, u32));
    try testing.expectEqual(elfMachine(), readInt(bytes, 12, u32));

    var parsed = Parsed{ .header_pid = readInt(bytes, 20, u32), .header_stamp = readInt(bytes, 24, u64) };
    errdefer parsed.deinit();

    var off: usize = header_size;
    while (off < bytes.len) {
        const event = readInt(bytes, off, u32);
        const size = readInt(bytes, off + 4, u32);
        const stamp = readInt(bytes, off + 8, u64);
        try testing.expect(off + size <= bytes.len);

        switch (event) {
            record_load => {
                const code_size = readInt(bytes, off + 40, u64);
                const name_start = off + load_record_size;
                const nul = std.mem.indexOfScalarPos(u8, bytes, name_start, 0).?;
                const code_start = nul + 1;
                try testing.expectEqual(off + size, code_start + code_size);
                try parsed.loads.append(testing.allocator, .{
                    .stamp = stamp,
                    .pid = readInt(bytes, off + 16, u32),
                    .tid = readInt(bytes, off + 20, u32),
                    .vma = readInt(bytes, off + 24, u64),
                    .code_addr = readInt(bytes, off + 32, u64),
                    .code_size = code_size,
                    .index = readInt(bytes, off + 48, u64),
                    .name = bytes[name_start..nul],
                    .code = bytes[code_start..][0..code_size],
                });
            },
            record_close => parsed.closed = true,
            else => return error.TestUnexpectedRecord,
        }
        off += size;
    }
    return parsed;
}

fn readDump(tmp: *std.testing.TmpDir, pid: u32) ![]u8 {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "jit-{d}.dump", .{pid});
    return tmp.dir.readFileAlloc(testing.allocator, name, 1 << 20);
}

fn tmpDirPath(tmp: *std.testing.TmpDir) ![]u8 {
    return tmp.dir.realpathAlloc(testing.allocator, ".");
}

test "header and load records parse back" {
    if (!supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirPath(&tmp);
    defer testing.allocator.free(dir);

    const w = try Writer.open(testing.allocator, dir);
    const pid = w.pid;
    const code_a = [_]u8{ 0x90, 0x91, 0x92, 0x93 };
    const code_b = [_]u8{0xC3};
    w.recordLoad("double", &code_a, code_a.len);
    w.recordLoad("lib/util/helper", &code_b, code_b.len);
    w.close();

    const bytes = try readDump(&tmp, pid);
    defer testing.allocator.free(bytes);
    var parsed = try parseDump(bytes);
    defer parsed.deinit();

    try testing.expectEqual(pid, parsed.header_pid);
    try testing.expect(parsed.closed);
    try testing.expectEqual(@as(usize, 2), parsed.loads.items.len);

    const a = parsed.loads.items[0];
    try testing.expectEqualStrings("double", a.name);
    try testing.expectEqual(@as(u64, @intFromPtr(&code_a)), a.code_addr);
    try testing.expectEqual(a.code_addr, a.vma);
    try testing.expectEqual(@as(u64, 4), a.code_size);
    try testing.expectEqualSlices(u8, &code_a, a.code);
    try testing.expectEqual(pid, a.pid);
    try testing.expectEqual(@as(u64, 1), a.index);

    const b = parsed.loads.items[1];
    try testing.expectEqualStrings("lib/util/helper", b.name);
    try testing.expectEqual(@as(u64, 2), b.index);
    try testing.expect(b.stamp >= a.stamp);
    try testing.expect(a.stamp >= parsed.header_stamp);
}

test "an empty name and empty code still make a whole record" {
    if (!supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirPath(&tmp);
    defer testing.allocator.free(dir);

    const w = try Writer.open(testing.allocator, dir);
    const pid = w.pid;
    const code = [_]u8{0xC3};
    w.recordLoad("", &code, 0);
    w.recordLoad("after", &code, 1);
    w.close();

    const bytes = try readDump(&tmp, pid);
    defer testing.allocator.free(bytes);
    var parsed = try parseDump(bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.loads.items.len);
    try testing.expectEqualStrings("", parsed.loads.items[0].name);
    try testing.expectEqual(@as(usize, 0), parsed.loads.items[0].code.len);
    try testing.expectEqualStrings("after", parsed.loads.items[1].name);
}

test "concurrent writers produce whole records in time order" {
    if (!supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirPath(&tmp);
    defer testing.allocator.free(dir);

    const w = try Writer.open(testing.allocator, dir);
    const pid = w.pid;

    const threads = 4;
    const per_thread = 50;
    const code = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    const Worker = struct {
        fn run(writer: *Writer, id: usize, bytes: []const u8) void {
            var name_buf: [32]u8 = undefined;
            for (0..per_thread) |i| {
                const name = std.fmt.bufPrint(&name_buf, "w{d}-{d}", .{ id, i }) catch unreachable;
                writer.recordLoad(name, bytes.ptr, bytes.len);
            }
        }
    };

    var handles: [threads]std.Thread = undefined;
    for (&handles, 0..) |*h, id| h.* = try std.Thread.spawn(.{}, Worker.run, .{ w, id, @as([]const u8, &code) });
    for (handles) |h| h.join();
    w.close();

    const bytes = try readDump(&tmp, pid);
    defer testing.allocator.free(bytes);
    var parsed = try parseDump(bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, threads * per_thread), parsed.loads.items.len);

    var prev: u64 = 0;
    for (parsed.loads.items, 0..) |rec, i| {
        try testing.expect(rec.stamp >= prev);
        prev = rec.stamp;
        try testing.expectEqual(@as(u64, i + 1), rec.index);
        try testing.expectEqualSlices(u8, &code, rec.code);
        try testing.expect(std.mem.startsWith(u8, rec.name, "w"));
    }
}

test "a write failure warns once and stops the map" {
    if (!supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirPath(&tmp);
    defer testing.allocator.free(dir);

    const w = try Writer.open(testing.allocator, dir);
    const pid = w.pid;
    const code = [_]u8{0xC3};

    w.recordLoad("before", &code, code.len);

    // Closing the descriptor under the writer makes the next write fail.
    const real_fd = w.fd;
    posix.close(real_fd);
    w.fd = -1;

    w.recordLoad("fails", &code, code.len);
    try testing.expect(w.disabled.load(.acquire));
    try testing.expectEqual(@as(u32, 1), w.warnings.load(.acquire));

    w.recordLoad("skipped", &code, code.len);
    try testing.expectEqual(@as(u32, 1), w.warnings.load(.acquire));
    try testing.expectEqual(@as(u64, 3), w.next_index);

    // `close` would close descriptor -1 again, so release the rest by hand.
    if (w.map) |m| posix.munmap(m);
    w.allocator.free(w.path);
    w.allocator.destroy(w);

    const bytes = try readDump(&tmp, pid);
    defer testing.allocator.free(bytes);
    var parsed = try parseDump(bytes);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.loads.items.len);
    try testing.expectEqualStrings("before", parsed.loads.items[0].name);
}

test "a missing directory fails to open" {
    if (!supported) return error.SkipZigTest;

    try testing.expectError(error.DirectoryUnavailable, Writer.open(testing.allocator, "/nonexistent-jitdump-dir-for-test"));
}
