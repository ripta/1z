const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

/// An allocator wrapper that enforces a hard cap on live memory usage.
/// Tracks current live bytes (incremented on alloc/resize/remap, decremented on free).
/// When the cap is exceeded, aborts the process with an error message to stderr.
/// A max_bytes of 0 means unlimited (no cap enforced).
///
/// Thread-safe: `current_bytes` is an atomic counter so concurrent allocations /
/// frees from multiple worker threads under the M:N scheduler don't race. The cap
/// check is still TOCTOU but a single concurrent allocation can at most push the
/// total slightly past the cap before `abortWithMessage` exits the process anyway.
pub const MemoryLimitAllocator = struct {
    backing_allocator: std.mem.Allocator,
    current_bytes: std.atomic.Value(usize),
    max_bytes: usize,

    pub fn init(backing: std.mem.Allocator, max_bytes: usize) MemoryLimitAllocator {
        return .{
            .backing_allocator = backing,
            .current_bytes = std.atomic.Value(usize).init(0),
            .max_bytes = max_bytes,
        };
    }

    pub fn currentBytes(self: *const MemoryLimitAllocator) usize {
        return self.current_bytes.load(.monotonic);
    }

    pub fn allocator(self: *MemoryLimitAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MemoryLimitAllocator = @ptrCast(@alignCast(ctx));

        if (self.max_bytes > 0 and self.current_bytes.load(.monotonic) + len > self.max_bytes) {
            abortWithMessage(self.max_bytes, len);
        }

        const result = self.backing_allocator.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            _ = self.current_bytes.fetchAdd(len, .monotonic);
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *MemoryLimitAllocator = @ptrCast(@alignCast(ctx));

        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            if (self.max_bytes > 0 and self.current_bytes.load(.monotonic) + delta > self.max_bytes) {
                abortWithMessage(self.max_bytes, delta);
            }
        }

        const old_len = memory.len;
        const success = self.backing_allocator.rawResize(memory, alignment, new_len, ret_addr);
        if (success) {
            if (new_len > old_len) {
                _ = self.current_bytes.fetchAdd(new_len - old_len, .monotonic);
            } else {
                _ = self.current_bytes.fetchSub(old_len - new_len, .monotonic);
            }
        }
        return success;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MemoryLimitAllocator = @ptrCast(@alignCast(ctx));

        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            if (self.max_bytes > 0 and self.current_bytes.load(.monotonic) + delta > self.max_bytes) {
                abortWithMessage(self.max_bytes, delta);
            }
        }

        const old_len = memory.len;
        const result = self.backing_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len > old_len) {
                _ = self.current_bytes.fetchAdd(new_len - old_len, .monotonic);
            } else {
                _ = self.current_bytes.fetchSub(old_len - new_len, .monotonic);
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MemoryLimitAllocator = @ptrCast(@alignCast(ctx));
        self.backing_allocator.rawFree(memory, alignment, ret_addr);
        _ = self.current_bytes.fetchSub(memory.len, .monotonic);
    }

    fn abortWithMessage(limit: usize, attempted: usize) noreturn {
        // Format the message without allocating. Use a stack buffer.
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: memory limit exceeded (limit: {s}, attempted allocation: {} bytes)\n", .{
            formatBytesStatic(limit),
            attempted,
        }) catch "Error: memory limit exceeded\n";

        writeMessageToStderr(msg);
        exitProcess(1);
    }

    const exitProcess = if (is_freestanding) hangForever else processExitHosted;

    fn hangForever(code: u8) noreturn {
        _ = code;
        while (true) {}
    }

    fn processExitHosted(code: u8) noreturn {
        std.process.exit(code);
    }

    const writeMessageToStderr = if (is_freestanding) writeMessageToStderrFreestanding else writeMessageToStderrHosted;

    fn writeMessageToStderrFreestanding(msg: []const u8) void {
        _ = msg;
    }

    fn writeMessageToStderrHosted(msg: []const u8) void {
        var written: usize = 0;
        while (written < msg.len) {
            written += std.posix.write(std.posix.STDERR_FILENO, msg[written..]) catch break;
        }
    }

    pub fn formatBytesStatic(bytes: usize) []const u8 {
        const Static = struct {
            var format_buf: [64]u8 = undefined;
        };

        if (bytes == 0) return "unlimited";

        const gb = 1024 * 1024 * 1024;
        const mb = 1024 * 1024;
        const kb = 1024;

        const result = if (bytes >= gb and bytes % gb == 0)
            std.fmt.bufPrint(&Static.format_buf, "{} GB", .{bytes / gb})
        else if (bytes >= mb and bytes % mb == 0)
            std.fmt.bufPrint(&Static.format_buf, "{} MB", .{bytes / mb})
        else if (bytes >= kb and bytes % kb == 0)
            std.fmt.bufPrint(&Static.format_buf, "{} KB", .{bytes / kb})
        else
            std.fmt.bufPrint(&Static.format_buf, "{} bytes", .{bytes});

        return result catch "???";
    }
};

/// Parse a human-readable size string into bytes.
/// Supports: "256M", "1G", "512K", raw byte count, "unlimited" or "0".
/// Case-insensitive suffix. Returns null on invalid input.
pub fn parseSize(input: []const u8) ?usize {
    if (input.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(input, "unlimited")) return 0;

    // Try to parse as plain number first (raw bytes or "0" for unlimited)
    if (std.fmt.parseInt(usize, input, 10)) |val| {
        return val;
    } else |_| {}

    // Check for suffix
    if (input.len < 2) return null;

    const suffix = input[input.len - 1];
    const num_part = input[0 .. input.len - 1];

    const number = std.fmt.parseInt(usize, num_part, 10) catch return null;

    return switch (suffix) {
        'k', 'K' => number *| 1024,
        'm', 'M' => number *| (1024 * 1024),
        'g', 'G' => number *| (1024 * 1024 * 1024),
        else => null,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "parseSize: plain numbers" {
    try std.testing.expectEqual(@as(?usize, 0), parseSize("0"));
    try std.testing.expectEqual(@as(?usize, 1024), parseSize("1024"));
    try std.testing.expectEqual(@as(?usize, 999999), parseSize("999999"));
}

test "parseSize: unlimited" {
    try std.testing.expectEqual(@as(?usize, 0), parseSize("unlimited"));
    try std.testing.expectEqual(@as(?usize, 0), parseSize("UNLIMITED"));
    try std.testing.expectEqual(@as(?usize, 0), parseSize("Unlimited"));
}

test "parseSize: kilobyte suffix" {
    try std.testing.expectEqual(@as(?usize, 512 * 1024), parseSize("512K"));
    try std.testing.expectEqual(@as(?usize, 512 * 1024), parseSize("512k"));
    try std.testing.expectEqual(@as(?usize, 1024), parseSize("1K"));
}

test "parseSize: megabyte suffix" {
    try std.testing.expectEqual(@as(?usize, 256 * 1024 * 1024), parseSize("256M"));
    try std.testing.expectEqual(@as(?usize, 256 * 1024 * 1024), parseSize("256m"));
    try std.testing.expectEqual(@as(?usize, 1024 * 1024), parseSize("1M"));
}

test "parseSize: gigabyte suffix" {
    try std.testing.expectEqual(@as(?usize, 1024 * 1024 * 1024), parseSize("1G"));
    try std.testing.expectEqual(@as(?usize, 1024 * 1024 * 1024), parseSize("1g"));
    try std.testing.expectEqual(@as(?usize, 2 * 1024 * 1024 * 1024), parseSize("2G"));
}

test "parseSize: invalid input" {
    try std.testing.expectEqual(@as(?usize, null), parseSize(""));
    try std.testing.expectEqual(@as(?usize, null), parseSize("abc"));
    try std.testing.expectEqual(@as(?usize, null), parseSize("M"));
    try std.testing.expectEqual(@as(?usize, null), parseSize("256X"));
    try std.testing.expectEqual(@as(?usize, null), parseSize("-1M"));
}

test "MemoryLimitAllocator: tracks allocations and frees" {
    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    const alloc = mem_limit.allocator();

    const mem1 = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), mem_limit.currentBytes());

    const mem2 = try alloc.alloc(u8, 200);
    try std.testing.expectEqual(@as(usize, 300), mem_limit.currentBytes());

    alloc.free(mem1);
    try std.testing.expectEqual(@as(usize, 200), mem_limit.currentBytes());

    alloc.free(mem2);
    try std.testing.expectEqual(@as(usize, 0), mem_limit.currentBytes());
}

test "MemoryLimitAllocator: unlimited allows any allocation" {
    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    const alloc = mem_limit.allocator();

    const mem = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(mem);

    try std.testing.expectEqual(@as(usize, 1024 * 1024), mem_limit.currentBytes());
}
