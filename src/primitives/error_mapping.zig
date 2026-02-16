const std = @import("std");

const InterpreterError = @import("types.zig").InterpreterError;

// =============================================================================
// Error Mapping for File/Stream Operations
// =============================================================================

/// Map file open errors to interpreter errors.
/// Used when opening existing files for reading.
pub fn mapFileOpenError(err: anyerror) InterpreterError {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.PermissionDenied,
        else => error.IOFailed,
    };
}

/// Map file create errors to interpreter errors.
/// Used when creating new files or truncating existing ones.
pub fn mapFileCreateError(err: anyerror) InterpreterError {
    return switch (err) {
        error.AccessDenied => error.PermissionDenied,
        else => error.IOFailed,
    };
}

/// Map file write errors to interpreter errors.
pub fn mapFileWriteError(err: anyerror) InterpreterError {
    return switch (err) {
        error.BrokenPipe => error.IOFailed,
        error.ConnectionResetByPeer => error.IOFailed,
        error.DiskQuota => error.IOFailed,
        error.FileTooBig => error.IOFailed,
        error.InputOutput => error.IOFailed,
        error.NoSpaceLeft => error.IOFailed,
        error.AccessDenied => error.PermissionDenied,
        else => error.IOFailed,
    };
}

/// Map file read errors to interpreter errors.
pub fn mapFileReadError(err: anyerror) InterpreterError {
    return switch (err) {
        error.InputOutput => error.IOFailed,
        error.BrokenPipe => error.IOFailed,
        error.ConnectionResetByPeer => error.IOFailed,
        error.ConnectionTimedOut => error.IOFailed,
        error.AccessDenied => error.PermissionDenied,
        error.NotOpenForReading => error.PermissionDenied,
        else => error.IOFailed,
    };
}

/// Map file sync errors to interpreter errors.
pub fn mapFileSyncError(err: anyerror) InterpreterError {
    return switch (err) {
        error.InputOutput => error.IOFailed,
        error.AccessDenied => error.PermissionDenied,
        else => error.IOFailed,
    };
}

/// Map seek errors to interpreter errors.
pub fn mapSeekError(err: anyerror) InterpreterError {
    return switch (err) {
        error.Unseekable => error.NotSeekable,
        else => error.IOFailed,
    };
}

/// Map getPos errors to interpreter errors.
pub fn mapGetPosError(err: anyerror) InterpreterError {
    return switch (err) {
        error.Unseekable => error.NotSeekable,
        else => error.IOFailed,
    };
}

// =============================================================================
// Stream State Helpers
// =============================================================================

const Stream = @import("../value.zig").Stream;

/// Check that a stream is open, returning ClosedStream error if not.
pub fn ensureStreamOpen(stream: *const Stream) InterpreterError!void {
    if (stream.closed) {
        return error.ClosedStream;
    }
}

const Resource = @import("../value.zig").Resource;

/// Check that a resource is open, returning UseAfterClose error if closed.
pub fn ensureResourceOpen(resource: *const Resource) InterpreterError!void {
    if (resource.closed) {
        return error.UseAfterClose;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "mapFileOpenError" {
    try std.testing.expectEqual(error.FileNotFound, mapFileOpenError(error.FileNotFound));
    try std.testing.expectEqual(error.PermissionDenied, mapFileOpenError(error.AccessDenied));
    try std.testing.expectEqual(error.IOFailed, mapFileOpenError(error.SystemResources));
}

test "mapFileWriteError" {
    try std.testing.expectEqual(error.IOFailed, mapFileWriteError(error.BrokenPipe));
    try std.testing.expectEqual(error.IOFailed, mapFileWriteError(error.NoSpaceLeft));
    try std.testing.expectEqual(error.PermissionDenied, mapFileWriteError(error.AccessDenied));
}

test "mapFileReadError" {
    try std.testing.expectEqual(error.IOFailed, mapFileReadError(error.InputOutput));
    try std.testing.expectEqual(error.PermissionDenied, mapFileReadError(error.NotOpenForReading));
}

test "mapSeekError" {
    try std.testing.expectEqual(error.NotSeekable, mapSeekError(error.Unseekable));
    try std.testing.expectEqual(error.IOFailed, mapSeekError(error.SystemResources));
}

test "ensureResourceOpen returns UseAfterClose when closed" {
    const r = Resource{ .type_name = "test", .closed = true };
    try std.testing.expectError(error.UseAfterClose, ensureResourceOpen(&r));
}

test "ensureResourceOpen passes when open" {
    const r = Resource{ .type_name = "test", .closed = false };
    try ensureResourceOpen(&r);
}
