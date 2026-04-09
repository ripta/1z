const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Stream = value_mod.Stream;
const StreamMode = value_mod.StreamMode;
const BufferingMode = value_mod.BufferingMode;
const ByteArray = value_mod.ByteArray;

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const error_mapping = @import("error_mapping.zig");

const popInteger = helpers.popInteger;
const popSymbol = helpers.popSymbol;
const popString = helpers.popString;
const popStream = helpers.popStream;

const mapFileOpenError = error_mapping.mapFileOpenError;
const mapFileCreateError = error_mapping.mapFileCreateError;
const mapFileWriteError = error_mapping.mapFileWriteError;
const mapFileReadError = error_mapping.mapFileReadError;
const mapFileSyncError = error_mapping.mapFileSyncError;
const mapSeekError = error_mapping.mapSeekError;
const mapGetPosError = error_mapping.mapGetPosError;
const ensureStreamOpen = error_mapping.ensureStreamOpen;

pub const primitives = [_]Primitive{
    .{ .name = "stdin", .stack_effect = "-- stream", .doc = "Push standard input stream.", .func = nativeStdin },
    .{ .name = "stdout", .stack_effect = "-- stream", .doc = "Push standard output stream.", .func = nativeStdout },
    .{ .name = "stderr", .stack_effect = "-- stream", .doc = "Push standard error stream.", .func = nativeStderr },
    .{ .name = "stream-open", .stack_effect = "path mode -- stream", .doc = "Open a file stream with mode (read:, write:, append:, read-write:).", .func = nativeStreamOpen },
    .{ .name = "stream-close", .stack_effect = "stream --", .doc = "Close a stream.", .func = nativeStreamClose },
    .{ .name = "stream-write", .stack_effect = "stream bytes -- n", .doc = "Write bytes to stream, return count written.", .func = nativeStreamWrite },
    .{ .name = "stream-flush", .stack_effect = "stream --", .doc = "Flush stream buffer.", .func = nativeStreamFlush },
    .{ .name = "stream-read", .stack_effect = "stream n -- bytes", .doc = "Read up to n bytes from stream.", .func = nativeStreamRead },
    .{ .name = "stream-read-line", .stack_effect = "stream -- str/f", .doc = "Read one line (no newline), or f at EOF.", .func = nativeStreamReadLine },
    .{ .name = "stream-read-all", .stack_effect = "stream -- bytes", .doc = "Read all remaining content from stream.", .func = nativeStreamReadAll },
    .{ .name = "stream-tell", .stack_effect = "stream -- pos", .doc = "Get current stream position.", .func = nativeStreamTell },
    .{ .name = "stream-seek", .stack_effect = "stream pos --", .doc = "Seek to absolute position in stream.", .func = nativeStreamSeek },
    .{ .name = "stream-seek-end", .stack_effect = "stream offset --", .doc = "Seek relative to end of stream.", .func = nativeStreamSeekEnd },
    .{ .name = "buffering-mode", .stack_effect = "stream -- symbol", .doc = "Get stream buffering mode.", .func = nativeBufferingMode },
    .{ .name = "set-buffering-mode", .stack_effect = "stream symbol --", .doc = "Set stream buffering mode (none:, line:, block:).", .func = nativeSetBufferingMode },
    .{ .name = "stream>fd", .stack_effect = "stream -- int", .doc = "Get file descriptor from stream (Unix only).", .func = nativeStreamToFd },
    .{ .name = "fd>stream", .stack_effect = "fd -- stream", .doc = "Create stream from file descriptor (Unix only). Opens in read-write mode.", .func = nativeFdToStream },
    .{ .name = "<pipe>", .stack_effect = "-- rd wr", .doc = "Create a Unix pipe, returning read-end and write-end streams.", .func = nativePipe },
    .{ .name = ">char", .stack_effect = "codepoint -- str", .doc = "Convert Unicode codepoint to single-character string.", .func = nativeChr },
    .{ .name = ">codepoint", .stack_effect = "str -- int", .doc = "Convert single-character string to Unicode codepoint.", .func = nativeToCodepoint },
};

// =============================================================================
// Standard streams
// =============================================================================

/// stdin ( -- stream ) - Push standard input stream
pub fn nativeStdin(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = std.fs.File.stdin(),
        .mode = .read,
        .name = "stdin",
        .buffering = .line,
    };
    try ctx.stack.push(.{ .stream = stream });
}

/// stdout ( -- stream ) - Push standard output stream
pub fn nativeStdout(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = std.fs.File.stdout(),
        .mode = .write,
        .name = "stdout",
        .buffering = .line,
    };
    try ctx.stack.push(.{ .stream = stream });
}

/// stderr ( -- stream ) - Push standard error stream
pub fn nativeStderr(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = std.fs.File.stderr(),
        .mode = .write,
        .name = "stderr",
        .buffering = .line,
    };
    try ctx.stack.push(.{ .stream = stream });
}

// =============================================================================
// Stream open/close
// =============================================================================

/// stream-open ( path mode -- stream ) - Open a file stream
/// Mode symbols: read: write: append: read-write:
pub fn nativeStreamOpen(ctx: *Context) anyerror!void {
    const mode_sym = try popSymbol(ctx);
    const path = try popString(ctx);
    const alloc = ctx.quotationAllocator();

    // Parse mode symbol
    const mode: StreamMode = if (std.mem.eql(u8, mode_sym, "read"))
        .read
    else if (std.mem.eql(u8, mode_sym, "write"))
        .write
    else if (std.mem.eql(u8, mode_sym, "append"))
        .append
    else if (std.mem.eql(u8, mode_sym, "read-write"))
        .read_write
    else
        return error.TypeMismatch;

    // Open file based on mode
    const file = switch (mode) {
        .read => std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
            return mapFileOpenError(err);
        },
        .write => std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
            return mapFileCreateError(err);
        },
        .append => blk: {
            const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |open_err| {
                // File doesn't exist, create it
                if (open_err == error.FileNotFound) {
                    break :blk std.fs.cwd().createFile(path, .{}) catch |err| {
                        return mapFileCreateError(err);
                    };
                }
                return mapFileOpenError(open_err);
            };
            // Seek to end for append mode
            f.seekFromEnd(0) catch return error.IOFailed;
            break :blk f;
        },
        .read_write => blk: {
            break :blk std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
                // Try creating if doesn't exist
                if (err == error.FileNotFound) {
                    break :blk std.fs.cwd().createFile(path, .{ .read = true }) catch |create_err| {
                        return mapFileCreateError(create_err);
                    };
                }
                return mapFileOpenError(err);
            };
        },
    };

    // Create stream object
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    const name_copy = alloc.dupe(u8, path) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = file,
        .mode = mode,
        .name = name_copy,
    };
    try ctx.stack.push(.{ .stream = stream });
}

/// stream-close ( stream -- ) - Close a stream
pub fn nativeStreamClose(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    restoreBlocking(stream);

    // Don't actually close stdin/stdout/stderr
    if (std.mem.eql(u8, stream.name, "stdin") or
        std.mem.eql(u8, stream.name, "stdout") or
        std.mem.eql(u8, stream.name, "stderr"))
    {
        stream.closed = true;
        return;
    }

    stream.file.close();
    stream.closed = true;
}

// =============================================================================
// Stream writing primitives
// =============================================================================

/// stream-write ( stream bytes -- n ) - Write bytes to stream, return count written
pub fn nativeStreamWrite(ctx: *Context) anyerror!void {
    const bytes_val = try ctx.stack.pop();
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    // Get bytes to write - accept byte arrays or strings
    const bytes: []const u8 = switch (bytes_val) {
        .byte_array => |ba| ba.items,
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const written = asyncWrite(stream, bytes, ctx) catch |err| {
        return mapFileWriteError(err);
    };

    try ctx.stack.push(.{ .integer = @intCast(written) });
}

/// stream-flush ( stream -- ) - Flush stream buffer
pub fn nativeStreamFlush(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    // NOTE(ripta): The standard streams and fd-based streams, e.g., sockets and pipes,
    //              are unbuffered at the zig file level, so sync is a no-op or unsupported.
    if (std.mem.eql(u8, stream.name, "stdin") or
        std.mem.eql(u8, stream.name, "stdout") or
        std.mem.eql(u8, stream.name, "stderr") or
        std.mem.eql(u8, stream.name, "fd") or
        std.mem.eql(u8, stream.name, "pipe"))
    {
        return;
    }

    stream.file.sync() catch |err| {
        return mapFileSyncError(err);
    };
}

// =============================================================================
// Stream reading primitives
// =============================================================================

/// stream-read ( stream n -- bytes ) - Read up to n bytes from stream
pub fn nativeStreamRead(ctx: *Context) anyerror!void {
    const n = try popInteger(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    if (n < 0) {
        return error.InvalidArgument;
    }

    const alloc = ctx.quotationAllocator();
    const buffer = alloc.alloc(u8, @intCast(n)) catch return error.OutOfMemory;
    defer alloc.free(buffer);

    const bytes_read = asyncRead(stream, buffer, ctx) catch |err| {
        return mapFileReadError(err);
    };

    const ba = alloc.create(ByteArray) catch return error.OutOfMemory;
    ba.* = ByteArray{};
    ba.ensureTotalCapacity(alloc, bytes_read) catch return error.OutOfMemory;
    for (buffer[0..bytes_read]) |byte| {
        ba.appendAssumeCapacity(byte);
    }

    try ctx.stack.push(.{ .byte_array = ba });
}

/// stream-read-line ( stream -- str/f ) - Read line (no newline), f at EOF
pub fn nativeStreamReadLine(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const alloc = ctx.quotationAllocator();
    var line_buf: std.ArrayListUnmanaged(u8) = .{};
    defer line_buf.deinit(alloc);

    while (true) {
        var byte_buf: [1]u8 = undefined;
        const bytes_read = asyncRead(stream, &byte_buf, ctx) catch |err| {
            return mapFileReadError(err);
        };

        if (bytes_read == 0) {
            // No data read at all, return false for EOF
            if (line_buf.items.len == 0) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            // Return what we have; last line without newline
            break;
        }

        const byte = byte_buf[0];
        if (byte == '\n') {
            // End of line, sans newline
            break;
        }

        // Handle \r\n by skipping \r if followed by \n
        if (byte == '\r') {
            var peek_buf: [1]u8 = undefined;
            const peek_read = asyncRead(stream, &peek_buf, ctx) catch |err| {
                return mapFileReadError(err);
            };
            if (peek_read > 0 and peek_buf[0] == '\n') {
                break;
            }
            line_buf.append(alloc, '\r') catch return error.OutOfMemory;
            if (peek_read > 0) {
                if (peek_buf[0] == '\n') {
                    break;
                }
                line_buf.append(alloc, peek_buf[0]) catch return error.OutOfMemory;
            }
            continue;
        }

        line_buf.append(alloc, byte) catch return error.OutOfMemory;
    }

    const result = alloc.dupe(u8, line_buf.items) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .string = result });
}

/// stream-read-all ( stream -- bytes ) - Read all remaining content
pub fn nativeStreamReadAll(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const alloc = ctx.quotationAllocator();

    // TODO(ripta): 10 MB seems reasonable, right?
    const max_size: usize = 10 * 1024 * 1024;
    var content: std.ArrayListUnmanaged(u8) = .{};
    defer content.deinit(alloc);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = asyncRead(stream, &buffer, ctx) catch |err| {
            return mapFileReadError(err);
        };

        // EOF?
        if (bytes_read == 0) {
            break;
        }

        if (content.items.len + bytes_read > max_size) {
            return error.OutOfMemory;
        }

        content.appendSlice(alloc, buffer[0..bytes_read]) catch return error.OutOfMemory;
    }

    const ba = alloc.create(ByteArray) catch return error.OutOfMemory;
    ba.* = ByteArray{};
    ba.ensureTotalCapacity(alloc, content.items.len) catch return error.OutOfMemory;
    for (content.items) |byte| {
        ba.appendAssumeCapacity(byte);
    }

    try ctx.stack.push(.{ .byte_array = ba });
}

// =============================================================================
// Stream positioning primitives
// =============================================================================

/// stream-tell ( stream -- pos ) - Get current stream position
pub fn nativeStreamTell(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const pos = stream.file.getPos() catch |err| {
        return mapGetPosError(err);
    };

    try ctx.stack.push(.{ .integer = @intCast(pos) });
}

/// stream-seek ( stream pos -- ) - Seek to absolute position
pub fn nativeStreamSeek(ctx: *Context) anyerror!void {
    const pos = try popInteger(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    if (pos < 0) {
        return error.InvalidArgument;
    }

    stream.file.seekTo(@intCast(pos)) catch |err| {
        return mapSeekError(err);
    };
}

/// stream-seek-end ( stream offset -- ) - Seek relative to end of stream
pub fn nativeStreamSeekEnd(ctx: *Context) anyerror!void {
    const offset = try popInteger(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    stream.file.seekFromEnd(offset) catch |err| {
        return mapSeekError(err);
    };
}

// =============================================================================
// Buffering control primitives
// =============================================================================

/// buffering-mode ( stream -- symbol ) - Get stream buffering mode
pub fn nativeBufferingMode(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    try ctx.stack.push(.{ .symbol = stream.buffering.toSymbol() });
}

/// set-buffering-mode ( stream symbol -- ) - Set stream buffering mode
pub fn nativeSetBufferingMode(ctx: *Context) anyerror!void {
    const mode_sym = try popSymbol(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const mode: BufferingMode = if (std.mem.eql(u8, mode_sym, "none"))
        .none
    else if (std.mem.eql(u8, mode_sym, "line"))
        .line
    else if (std.mem.eql(u8, mode_sym, "block"))
        .block
    else
        return error.InvalidArgument;

    stream.buffering = mode;
}

// =============================================================================
// Unix interop primitives
// =============================================================================

/// stream>fd ( stream -- int ) - Get file descriptor from stream (Unix only)
pub fn nativeStreamToFd(ctx: *Context) anyerror!void {
    if (native_os == .windows) {
        return error.UnsupportedOperation;
    }

    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const fd: i64 = @intCast(stream.file.handle);
    try ctx.stack.push(.{ .integer = fd });
}

/// fd>stream ( fd -- stream ) - Create stream from file descriptor (Unix only)
///
/// Always opens in read-write mode, since we don't have access to the original
/// mode and Unix fds are generally more flexible than zig's File.
///
/// If the fd is invalid or negative, returns an error.
///
/// The resulting stream won't have a meaningful name, so it's just "fd". 😬
pub fn nativeFdToStream(ctx: *Context) anyerror!void {
    if (native_os == .windows) {
        return error.UnsupportedOperation;
    }

    const fd_val = try popInteger(ctx);

    if (fd_val < 0) {
        return error.InvalidArgument;
    }

    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = std.fs.File{ .handle = @intCast(fd_val) },
        .mode = .read_write,
        .name = "fd",
    };
    try ctx.stack.push(.{ .stream = stream });
}

/// <pipe> ( -- rd wr ) - Create a Unix pipe, returning read-end and write-end streams
fn nativePipe(ctx: *Context) anyerror!void {
    if (native_os == .windows) {
        return error.UnsupportedOperation;
    }

    const fds = std.posix.pipe() catch return error.SystemError;
    const alloc = ctx.quotationAllocator();

    const rd = alloc.create(Stream) catch return error.OutOfMemory;
    rd.* = Stream{
        .file = std.fs.File{ .handle = fds[0] },
        .mode = .read,
        .name = "pipe(rd)",
    };

    const wr = alloc.create(Stream) catch return error.OutOfMemory;
    wr.* = Stream{
        .file = std.fs.File{ .handle = fds[1] },
        .mode = .write,
        .name = "pipe(wr)",
    };

    try ctx.stack.push(.{ .stream = rd });
    try ctx.stack.push(.{ .stream = wr });
}

// =============================================================================
// Character conversion primitives
// =============================================================================

/// >char ( codepoint -- str ) - Convert Unicode codepoint to single-character string
pub fn nativeChr(ctx: *Context) anyerror!void {
    const codepoint_val = try popInteger(ctx);
    if (codepoint_val < 0 or codepoint_val > 0x10FFFF) {
        return error.InvalidArgument;
    }

    const codepoint: u21 = @intCast(codepoint_val);
    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
        return error.InvalidArgument;
    }

    const alloc = ctx.quotationAllocator();
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidArgument;

    const str = alloc.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .string = str });
}

/// >codepoint ( str -- int ) - Convert single-character string to Unicode codepoint
pub fn nativeToCodepoint(ctx: *Context) anyerror!void {
    const str = try popString(ctx);
    var iter = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
    const first_codepoint = iter.nextCodepoint() orelse {
        return error.InvalidArgument;
    };

    if (iter.nextCodepoint() != null) {
        return error.InvalidArgument;
    }

    try ctx.stack.push(.{ .integer = @intCast(first_codepoint) });
}

// =============================================================================
// Async I/O helpers
// =============================================================================

/// Set O_NONBLOCK on the stream's fd.
fn setNonBlocking(stream: *Stream) void {
    if (stream.nonblocking_set) return;

    const fd = stream.file.handle;
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return;

    var flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
    stream.nonblocking_set = true;
}

/// Clear O_NONBLOCK on the stream's fd, restoring blocking mode.
fn restoreBlocking(stream: *Stream) void {
    if (!stream.nonblocking_set) return;

    const fd = stream.file.handle;
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return;

    var flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = false;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
    stream.nonblocking_set = false;
}

/// Read from a stream, yielding to the scheduler on WouldBlock.
///
/// When no scheduler is active and WouldBlock occurs (leftover O_NONBLOCK),
/// restores blocking mode and retries.
fn asyncRead(stream: *Stream, buffer: []u8, ctx: *Context) anyerror!usize {
    if (ctx.scheduler != null and !stream.nonblocking_set) {
        setNonBlocking(stream);
    }

    while (true) {
        return stream.file.read(buffer) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(stream.file.handle, .read);
                    continue;
                }

                restoreBlocking(stream);
                continue;
            }
            return err;
        };
    }
}

/// Write to a stream, yielding to the scheduler on WouldBlock.
///
fn asyncWrite(stream: *Stream, bytes: []const u8, ctx: *Context) anyerror!usize {
    if (ctx.scheduler != null and !stream.nonblocking_set) {
        setNonBlocking(stream);
    }

    while (true) {
        return stream.file.write(bytes) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(stream.file.handle, .write);
                    continue;
                }
                restoreBlocking(stream);
                continue;
            }
            return err;
        };
    }
}
