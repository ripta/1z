const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Stream = value_mod.Stream;
const StreamMode = value_mod.StreamMode;
const StreamVTable = value_mod.StreamVTable;
const BufferingMode = value_mod.BufferingMode;
const ByteArray = value_mod.ByteArray;

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;
const Capability = types_mod.Capability;
const helpers = @import("helpers.zig");
const error_mapping = @import("error_mapping.zig");
const container_backing = @import("../container_backing.zig");

const popFixnum = helpers.popFixnum;
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

fn mapStreamReadError(err: anyerror) anyerror {
    if (err == error.UserThrown) return err;
    return mapFileReadError(err);
}

fn mapStreamWriteError(err: anyerror) anyerror {
    if (err == error.UserThrown) return err;
    return mapFileWriteError(err);
}

pub const primitives = [_]Primitive{
    .{ .name = "stdin", .stack_effect = "-- stream", .doc = "Push standard input stream.", .func = nativeStdin, .capability = .io },
    .{ .name = "stdout", .stack_effect = "-- stream", .doc = "Push standard output stream.", .func = nativeStdout, .capability = .io },
    .{ .name = "stderr", .stack_effect = "-- stream", .doc = "Push standard error stream.", .func = nativeStderr, .capability = .io },
    .{ .name = "stream-open", .stack_effect = "path mode -- stream", .doc = "Open a file stream with mode (read:, write:, append:, read-write:).", .func = nativeStreamOpen, .capability = .io_fs },
    .{ .name = "stream-close", .stack_effect = "stream --", .doc = "Close a stream.", .func = nativeStreamClose, .capability = .io },
    .{ .name = "stream-write", .stack_effect = "stream bytes -- n", .doc = "Write bytes to stream, return count written.", .func = nativeStreamWrite, .capability = .io },
    .{ .name = "stream-flush", .stack_effect = "stream --", .doc = "Flush stream buffer.", .func = nativeStreamFlush, .capability = .io },
    .{ .name = "stream-read", .stack_effect = "stream n -- bytes", .doc = "Read up to n bytes from stream. A single call may return fewer than n bytes for reasons other than EOF (a short pipe wake, a syscall returning early); EOF is signaled by a return of zero bytes. Callers that need exactly n bytes should loop, or use stream-read(exact) which loops until n bytes or EOF.", .func = nativeStreamRead, .capability = .io },
    .{ .name = "stream-read-line", .stack_effect = "stream -- str/f", .doc = "Read one line (no newline), or f at EOF.", .func = nativeStreamReadLine, .capability = .io },
    .{ .name = "stream-read-all", .stack_effect = "stream -- bytes", .doc = "Read all remaining content from stream.", .func = nativeStreamReadAll, .capability = .io },
    .{ .name = "stream-tell", .stack_effect = "stream -- pos", .doc = "Get current stream position.", .func = nativeStreamTell, .capability = .io },
    .{ .name = "stream-seek", .stack_effect = "stream pos --", .doc = "Seek to absolute position in stream.", .func = nativeStreamSeek, .capability = .io },
    .{ .name = "stream-seek-end", .stack_effect = "stream offset --", .doc = "Seek relative to end of stream.", .func = nativeStreamSeekEnd, .capability = .io },
    .{ .name = "buffering-mode", .stack_effect = "stream -- symbol", .doc = "Get stream buffering mode.", .func = nativeBufferingMode, .capability = .io },
    .{ .name = "set-buffering-mode", .stack_effect = "stream symbol --", .doc = "Set stream buffering mode (none:, line:, block:).", .func = nativeSetBufferingMode, .capability = .io },
    .{ .name = "stream>fd", .stack_effect = "stream -- int", .doc = "Get file descriptor from stream (Unix only).", .func = nativeStreamToFd, .capability = .io },
    .{ .name = "fd>stream", .stack_effect = "fd -- stream", .doc = "Create stream from file descriptor (Unix only). Opens in read-write mode.", .func = nativeFdToStream, .capability = .io },
    .{ .name = "<pipe>", .stack_effect = "-- rd wr", .doc = "Create a Unix pipe, returning read-end and write-end streams.", .func = nativePipe, .capability = .io },
    .{ .name = "<string-stream>", .stack_effect = "n -- stream", .doc = "Create a write-only in-memory stream with initial capacity n.", .func = nativeStringStream, .capability = .io },
    .{ .name = ">char", .stack_effect = "codepoint -- str", .doc = "Convert Unicode codepoint to single-character string.", .func = nativeChr },
    .{ .name = ">codepoint", .stack_effect = "str -- int", .doc = "Convert single-character string to Unicode codepoint.", .func = nativeToCodepoint },
};

/// Internal natives reached via `native.` and wrapped by the prelude generics
/// `>string!` / `>bytes!`; deliberately kept out of the global dictionary.
pub const registry_entries = [_]RegistryEntry{
    .{ .name = "string-stream>bytes!", .func = nativeStringStreamToBytes, .stack_effect = "stream -- bytes", .capability = .io },
    .{ .name = "string-stream>string!", .func = nativeStringStreamToString, .stack_effect = "stream -- str", .capability = .io },
};

// =============================================================================
// Base file vtable
// =============================================================================

pub const file_vtable = StreamVTable{
    .read = fileRead,
    .write = fileWrite,
    .close = fileClose,
    .flush = fileFlush,
};

/// Read from the underlying fd, yielding to the scheduler on WouldBlock.
fn fileRead(stream: *Stream, buffer: []u8, ctx: *Context) anyerror!usize {
    if (ctx.scheduler != null and !stream.nonblocking_set) {
        setNonBlocking(stream);
    }

    const file = std.fs.File{ .handle = stream.fd };
    while (true) {
        return file.read(buffer) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(stream.fd, .read);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                restoreBlocking(stream);
                continue;
            }
            return err;
        };
    }
}

/// Write to the underlying fd, yielding to the scheduler on WouldBlock.
fn fileWrite(stream: *Stream, bytes: []const u8, ctx: *Context) anyerror!usize {
    if (ctx.scheduler != null and !stream.nonblocking_set) {
        setNonBlocking(stream);
    }

    const file = std.fs.File{ .handle = stream.fd };
    while (true) {
        return file.write(bytes) catch |err| {
            if (err == error.WouldBlock) {
                if (ctx.scheduler) |sched| {
                    sched.ioSuspendCurrentTask(stream.fd, .write);
                    try helpers.checkCancellation(ctx);
                    continue;
                }
                restoreBlocking(stream);
                continue;
            }
            return err;
        };
    }
}

/// Close the base fd. Guards stdin/stdout/stderr from actual close.
fn fileClose(stream: *Stream) void {
    restoreBlocking(stream);

    if (isStandardStream(stream.name)) {
        return;
    }

    const file = std.fs.File{ .handle = stream.fd };
    file.close();
}

/// Flush the base fd. No-op for standard streams, sockets, and pipes.
///
/// NOTE(ripta): The standard streams and fd-based streams, e.g., sockets and pipes,
///              are unbuffered at the zig file level, so sync is a no-op or unsupported.
fn fileFlush(stream: *Stream) anyerror!void {
    if (isStandardStream(stream.name) or
        std.mem.eql(u8, stream.name, "fd") or
        std.mem.startsWith(u8, stream.name, "pipe"))
    {
        return;
    }

    const file = std.fs.File{ .handle = stream.fd };
    file.sync() catch |err| {
        return mapFileSyncError(err);
    };
}

fn isStandardStream(name: []const u8) bool {
    return std.mem.eql(u8, name, "stdin") or
        std.mem.eql(u8, name, "stdout") or
        std.mem.eql(u8, name, "stderr");
}

/// Create a base file stream from a fd with the given mode and name.
pub fn createFileStream(fd: std.posix.fd_t, mode: StreamMode, name: []const u8) Stream {
    return Stream{
        .vtable = &file_vtable,
        .fd = fd,
        .mode = mode,
        .name = name,
    };
}

// =============================================================================
// In-memory stream vtable
// =============================================================================

/// Growable byte buffer behind an in-memory stream, held in `Stream.impl`.
/// Backed by the general-purpose allocator so geometric growth frees old
/// buffers immediately and the buffer can later be moved into a refcounted
/// byte-array on a zero-copy drain.
const MemBuffer = struct {
    list: std.ArrayListUnmanaged(u8) = .{},
    allocator: std.mem.Allocator,
};

pub const in_memory_vtable = StreamVTable{
    .read = memRead,
    .write = memWrite,
    .close = memClose,
    .flush = memFlush,
};

/// Append to the in-memory buffer. Pure synchronous append; never touches the
/// scheduler or fd.
fn memWrite(stream: *Stream, bytes: []const u8, _: *Context) anyerror!usize {
    const buf: *MemBuffer = @ptrCast(@alignCast(stream.impl.?));
    try buf.list.appendSlice(buf.allocator, bytes);
    return bytes.len;
}

/// Reads error: the in-memory stream is a write-only sink.
fn memRead(_: *Stream, _: []u8, _: *Context) anyerror!usize {
    return error.NotOpenForReading;
}

/// Release the buffer. The `closed` flag is set by the caller.
fn memClose(stream: *Stream) void {
    const buf: *MemBuffer = @ptrCast(@alignCast(stream.impl.?));
    buf.list.deinit(buf.allocator);
    buf.allocator.destroy(buf);
    stream.impl = null;
}

fn memFlush(_: *Stream) anyerror!void {}

/// <string-stream> ( n -- stream ) - Create a write-only in-memory stream
/// with initial capacity n.
pub fn nativeStringStream(ctx: *Context) anyerror!void {
    const n = try popFixnum(ctx);
    if (n < 0) {
        return error.InvalidArgument;
    }

    // Buffer is GPA-backed; the Stream object lives in the quotation arena like
    // every other stream value.
    const buf = ctx.allocator.create(MemBuffer) catch return error.OutOfMemory;
    buf.* = .{ .allocator = ctx.allocator };
    buf.list.ensureTotalCapacity(ctx.allocator, @intCast(n)) catch {
        ctx.allocator.destroy(buf);
        return error.OutOfMemory;
    };

    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = Stream{
        .vtable = &in_memory_vtable,
        // Invalid fd sentinel: an in-memory stream has no OS resource. The
        // fd-based positioning words guard against a negative fd and error.
        .fd = -1,
        .mode = .write,
        .name = "string-stream",
        .impl = buf,
    };
    // The .io capability tracks the write path (stream-write / print already
    // require .io), not an intrinsic need to construct an in-memory stream.
    // Revisit if the write path stops requiring .io.
    try ctx.stack.push(.{ .stream = stream });
}

/// Reject any stream that is not an in-memory string-stream, leaving its
/// reference on the stack untouched for the caller's error handling.
fn requireMemStream(ctx: *Context, stream: *Stream) !void {
    if (stream.vtable != &in_memory_vtable) {
        helpers.setTypeMismatchError(ctx, "in-memory string-builder stream", .{ .stream = stream });
        return error.TypeMismatch;
    }
}

/// string-stream>bytes! ( stream -- bytes ) - Drain an in-memory stream into a
/// byte-array and close it. Zero-copy: the buffer's growable list is moved into
/// the refcounted byte-array, so the geometric capacity slack rides along and
/// is freed through the byte-array's header allocator. A later write throws
/// ClosedStream.
pub fn nativeStringStreamToBytes(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);
    try requireMemStream(ctx, stream);

    const buf: *MemBuffer = @ptrCast(@alignCast(stream.impl.?));
    // Header allocator is the GPA that backs the buffer, so destroyByteArray
    // frees the moved allocation correctly.
    const ba = ByteArray.create(buf.allocator) catch return error.OutOfMemory;
    ba.owned_items = buf.list;
    ba.refreshOwnedView();
    // Empty the buffer's view so close releases nothing the byte-array now owns.
    buf.list = .{};

    stream.vtable.close(stream);
    stream.closed = true;
    // create gives one owning reference; transfer it to the stack slot rather
    // than retaining a second.
    try ctx.stack.pushMoved(.{ .byte_array = ba });
}

/// string-stream>string! ( stream -- str ) - Drain an in-memory stream into a
/// string and close it. The live bytes are copied into the quotation arena
/// because 1z strings are never freed individually, and the GPA buffer is
/// released. A later write throws ClosedStream.
pub fn nativeStringStreamToString(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);
    try requireMemStream(ctx, stream);

    const buf: *MemBuffer = @ptrCast(@alignCast(stream.impl.?));
    const out = ctx.quotationAllocator().dupe(u8, buf.list.items) catch return error.OutOfMemory;

    stream.vtable.close(stream);
    stream.closed = true;
    try ctx.stack.push(.{ .string = out });
}

// =============================================================================
// Standard streams
// =============================================================================

/// stdin ( -- stream ) - Push standard input stream
pub fn nativeStdin(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = createFileStream(std.posix.STDIN_FILENO, .read, "stdin");
    stream.buffering = .line;
    try ctx.stack.push(.{ .stream = stream });
}

/// stdout ( -- stream ) - Push standard output stream
pub fn nativeStdout(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = createFileStream(std.posix.STDOUT_FILENO, .write, "stdout");
    stream.buffering = .line;
    try ctx.stack.push(.{ .stream = stream });
}

/// stderr ( -- stream ) - Push standard error stream
pub fn nativeStderr(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = createFileStream(std.posix.STDERR_FILENO, .write, "stderr");
    stream.buffering = .line;
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
    else {
        helpers.setErrorContext(ctx, "stream-open mode must be read:, write:, append:, or read-write:, got {s}:", .{mode_sym});
        return error.TypeMismatch;
    };

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
    stream.* = createFileStream(file.handle, mode, name_copy);
    try ctx.stack.push(.{ .stream = stream });
}

/// stream-close ( stream -- ) - Close a stream
pub fn nativeStreamClose(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    stream.vtable.close(stream);
    stream.closed = true;
}

// =============================================================================
// Stream writing primitives
// =============================================================================

/// stream-write ( stream bytes -- n ) - Write bytes to stream, return count written
pub fn nativeStreamWrite(ctx: *Context) anyerror!void {
    const bytes_val = try ctx.stack.pop();
    defer container_backing.releaseValue(bytes_val);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    // Get bytes to write - accept byte arrays or strings
    const bytes: []const u8 = switch (bytes_val) {
        .byte_array => |ba| ba.slice(),
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string or byte-array", bytes_val);
            return error.TypeMismatch;
        },
    };

    const written = stream.vtable.write(stream, bytes, ctx) catch |err| {
        return mapStreamWriteError(err);
    };

    try ctx.stack.push(.{ .fixnum = @intCast(written) });
}

/// stream-flush ( stream -- ) - Flush stream buffer
pub fn nativeStreamFlush(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    try stream.vtable.flush(stream);
}

// =============================================================================
// Stream reading primitives
// =============================================================================

/// stream-read ( stream n -- bytes ) - Read up to n bytes from stream
pub fn nativeStreamRead(ctx: *Context) anyerror!void {
    const n = try popFixnum(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    if (n < 0) {
        return error.InvalidArgument;
    }

    const alloc = ctx.quotationAllocator();
    const buffer = alloc.alloc(u8, @intCast(n)) catch return error.OutOfMemory;
    defer alloc.free(buffer);

    const bytes_read = stream.vtable.read(stream, buffer, ctx) catch |err| {
        return mapStreamReadError(err);
    };

    const ba = ByteArray.create(alloc) catch return error.OutOfMemory;
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
        const bytes_read = stream.vtable.read(stream, &byte_buf, ctx) catch |err| {
            return mapStreamReadError(err);
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
            const peek_read = stream.vtable.read(stream, &peek_buf, ctx) catch |err| {
                return mapStreamReadError(err);
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
        const bytes_read = stream.vtable.read(stream, &buffer, ctx) catch |err| {
            return mapStreamReadError(err);
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

    const ba = ByteArray.create(alloc) catch return error.OutOfMemory;
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
    if (stream.fd < 0) return error.NotSeekable;

    const file = std.fs.File{ .handle = stream.fd };
    const pos = file.getPos() catch |err| {
        return mapGetPosError(err);
    };

    try ctx.stack.push(.{ .fixnum = @intCast(pos) });
}

/// stream-seek ( stream pos -- ) - Seek to absolute position
pub fn nativeStreamSeek(ctx: *Context) anyerror!void {
    const pos = try popFixnum(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);
    if (stream.fd < 0) return error.NotSeekable;

    if (pos < 0) {
        return error.InvalidArgument;
    }

    const file = std.fs.File{ .handle = stream.fd };
    file.seekTo(@intCast(pos)) catch |err| {
        return mapSeekError(err);
    };
}

/// stream-seek-end ( stream offset -- ) - Seek relative to end of stream
pub fn nativeStreamSeekEnd(ctx: *Context) anyerror!void {
    const offset = try popFixnum(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);
    if (stream.fd < 0) return error.NotSeekable;

    const file = std.fs.File{ .handle = stream.fd };
    file.seekFromEnd(offset) catch |err| {
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

    const fd: i64 = @intCast(stream.fd);
    try ctx.stack.push(.{ .fixnum = fd });
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

    const fd_val = try popFixnum(ctx);

    if (fd_val < 0) {
        return error.InvalidArgument;
    }

    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = createFileStream(@intCast(fd_val), .read_write, "fd");
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
    rd.* = createFileStream(fds[0], .read, "pipe(rd)");

    const wr = alloc.create(Stream) catch return error.OutOfMemory;
    wr.* = createFileStream(fds[1], .write, "pipe(wr)");

    try ctx.stack.push(.{ .stream = rd });
    try ctx.stack.push(.{ .stream = wr });
}

// =============================================================================
// Character conversion primitives
// =============================================================================

/// >char ( codepoint -- str ) - Convert Unicode codepoint to single-character string
pub fn nativeChr(ctx: *Context) anyerror!void {
    const codepoint_val = try popFixnum(ctx);
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

    try ctx.stack.push(.{ .fixnum = @intCast(first_codepoint) });
}

// =============================================================================
// Non-blocking helpers (used by base file vtable and TLS handshake)
// =============================================================================

/// Set O_NONBLOCK on the stream's fd.
pub fn setNonBlocking(stream: *Stream) void {
    if (stream.nonblocking_set) return;
    setNonBlockingFd(stream.fd);
    stream.nonblocking_set = true;
}

/// Clear O_NONBLOCK on the stream's fd, restoring blocking mode.
pub fn restoreBlocking(stream: *Stream) void {
    if (!stream.nonblocking_set) return;
    clearNonBlockingFd(stream.fd);
    stream.nonblocking_set = false;
}

pub fn setNonBlockingFd(fd: std.posix.fd_t) void {
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
}

pub fn clearNonBlockingFd(fd: std.posix.fd_t) void {
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = false;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
}
