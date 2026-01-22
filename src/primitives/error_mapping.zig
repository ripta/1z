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
        else => error.IOError,
    };
}

/// Map file create errors to interpreter errors.
/// Used when creating new files or truncating existing ones.
pub fn mapFileCreateError(err: anyerror) InterpreterError {
    return switch (err) {
        error.AccessDenied => error.PermissionDenied,
        else => error.IOError,
    };
}

/// Map file write errors to interpreter errors.
pub fn mapFileWriteError(err: anyerror) InterpreterError {
    return switch (err) {
        error.BrokenPipe => error.IOError,
        error.ConnectionResetByPeer => error.IOError,
        error.DiskQuota => error.IOError,
        error.FileTooBig => error.IOError,
        error.InputOutput => error.IOError,
        error.NoSpaceLeft => error.IOError,
        error.AccessDenied => error.PermissionDenied,
        else => error.IOError,
    };
}

/// Map file read errors to interpreter errors.
pub fn mapFileReadError(err: anyerror) InterpreterError {
    return switch (err) {
        error.InputOutput => error.IOError,
        error.BrokenPipe => error.IOError,
        error.ConnectionResetByPeer => error.IOError,
        error.ConnectionTimedOut => error.IOError,
        error.AccessDenied => error.PermissionDenied,
        error.NotOpenForReading => error.PermissionDenied,
        else => error.IOError,
    };
}

/// Map file sync errors to interpreter errors.
pub fn mapFileSyncError(err: anyerror) InterpreterError {
    return switch (err) {
        error.InputOutput => error.IOError,
        error.AccessDenied => error.PermissionDenied,
        else => error.IOError,
    };
}

/// Map seek errors to interpreter errors.
pub fn mapSeekError(err: anyerror) InterpreterError {
    return switch (err) {
        error.Unseekable => error.NotSeekable,
        else => error.IOError,
    };
}

/// Map getPos errors to interpreter errors.
pub fn mapGetPosError(err: anyerror) InterpreterError {
    return switch (err) {
        error.Unseekable => error.NotSeekable,
        else => error.IOError,
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

// =============================================================================
// Tests
// =============================================================================

test "mapFileOpenError" {
    try std.testing.expectEqual(error.FileNotFound, mapFileOpenError(error.FileNotFound));
    try std.testing.expectEqual(error.PermissionDenied, mapFileOpenError(error.AccessDenied));
    try std.testing.expectEqual(error.IOError, mapFileOpenError(error.SystemResources));
}

test "mapFileWriteError" {
    try std.testing.expectEqual(error.IOError, mapFileWriteError(error.BrokenPipe));
    try std.testing.expectEqual(error.IOError, mapFileWriteError(error.NoSpaceLeft));
    try std.testing.expectEqual(error.PermissionDenied, mapFileWriteError(error.AccessDenied));
}

test "mapFileReadError" {
    try std.testing.expectEqual(error.IOError, mapFileReadError(error.InputOutput));
    try std.testing.expectEqual(error.PermissionDenied, mapFileReadError(error.NotOpenForReading));
}

test "mapSeekError" {
    try std.testing.expectEqual(error.NotSeekable, mapSeekError(error.Unseekable));
    try std.testing.expectEqual(error.IOError, mapSeekError(error.SystemResources));
}
