const std = @import("std");
const Context = @import("../context.zig").Context;
const Value = @import("../value.zig").Value;
const HashTable = @import("../value.zig").HashTable;
const helpers = @import("helpers.zig");
const mapFileOpenError = @import("error_mapping.zig").mapFileOpenError;
const mapFileCreateError = @import("error_mapping.zig").mapFileCreateError;
const Primitive = @import("types.zig").Primitive;
const RegistryEntry = @import("types.zig").RegistryEntry;

pub const primitives = [_]Primitive{
    .{ .name = "create-directory", .stack_effect = "path --", .doc = "Create a directory and all parent directories (mkdir -p behavior).", .func = nativeCreateDirectory, .capability = .io_fs },
    .{ .name = "delete-directory", .stack_effect = "path --", .doc = "Delete an empty directory.", .func = nativeDeleteDirectory, .capability = .io_fs },
    .{ .name = "list-directory", .stack_effect = "path -- array", .doc = "List directory entries as an array of { name type-symbol } pairs.", .func = nativeListDirectory, .capability = .io_fs },
    .{ .name = "delete-file", .stack_effect = "path --", .doc = "Delete a file.", .func = nativeDeleteFile, .capability = .io_fs },
    .{ .name = "rename-path", .stack_effect = "old new --", .doc = "Rename or move a path.", .func = nativeRenamePath, .capability = .io_fs },
    .{ .name = "copy-file", .stack_effect = "src dst --", .doc = "Copy a file from src to dst.", .func = nativeCopyFile, .capability = .io_fs },
    .{ .name = "path-exists?", .stack_effect = "path -- bool", .doc = "Return true if the path exists, false otherwise.", .func = nativePathExists, .capability = .io_fs },
    .{ .name = "file-info", .stack_effect = "path -- hash", .doc = "Return a hash with file metadata: size, type, modified, accessed, permissions.", .func = nativeFileInfo, .capability = .io_fs },
    .{ .name = "create-symlink", .stack_effect = "target link-path --", .doc = "Create a symbolic link at link-path pointing to target.", .func = nativeCreateSymlink, .capability = .io_fs },
    .{ .name = "read-symlink", .stack_effect = "path -- target-path", .doc = "Read the target of a symbolic link.", .func = nativeReadSymlink, .capability = .io_fs },
    .{ .name = "set-permissions", .stack_effect = "path mode --", .doc = "Set file or directory permissions (octal mode bits).", .func = nativeSetPermissions, .capability = .io_fs },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "file-info", .func = nativeFileInfo, .capability = .io_fs },
    .{ .name = "list-directory", .func = nativeListDirectory, .capability = .io_fs },
};

/// create-directory ( path -- )
fn nativeCreateDirectory(ctx: *Context) anyerror!void {
    const path = try helpers.popString(ctx);
    std.fs.cwd().makePath(path) catch |err| {
        helpers.setErrorContext(ctx, "create-directory: {s}", .{@errorName(err)});
        return mapFileCreateError(err);
    };
}

/// delete-directory ( path -- )
fn nativeDeleteDirectory(ctx: *Context) anyerror!void {
    const path = try helpers.popString(ctx);
    std.fs.cwd().deleteDir(path) catch |err| {
        helpers.setErrorContext(ctx, "delete-directory: {s}", .{@errorName(err)});
        return mapFileOpenError(err);
    };
}

/// list-directory ( path -- array )
fn nativeListDirectory(ctx: *Context) anyerror!void {
    const path = try helpers.popString(ctx);
    const alloc = ctx.quotationAllocator();

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        helpers.setErrorContext(ctx, "list-directory: {s}", .{@errorName(err)});
        return mapFileOpenError(err);
    };
    defer dir.close();

    var entries: std.ArrayListUnmanaged(Value) = .{};
    var iter = dir.iterate();
    while (iter.next() catch |err| {
        helpers.setErrorContext(ctx, "list-directory: {s}", .{@errorName(err)});
        return error.IOFailed;
    }) |entry| {
        const name = alloc.dupe(u8, entry.name) catch return error.OutOfMemory;
        const type_sym: []const u8 = switch (entry.kind) {
            .file => "file",
            .directory => "directory",
            .sym_link => "symlink",
            else => "unknown",
        };

        const pair = alloc.alloc(Value, 2) catch return error.OutOfMemory;
        pair[0] = .{ .string = name };
        pair[1] = .{ .symbol = type_sym };

        entries.append(alloc, .{ .array = pair }) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .array = entries.toOwnedSlice(alloc) catch return error.OutOfMemory });
}

/// delete-file ( path -- )
fn nativeDeleteFile(ctx: *Context) anyerror!void {
    const path = try helpers.popString(ctx);
    std.fs.cwd().deleteFile(path) catch |err| {
        helpers.setErrorContext(ctx, "delete-file: {s}", .{@errorName(err)});
        return mapFileOpenError(err);
    };
}

/// rename-path ( old new -- )
fn nativeRenamePath(ctx: *Context) anyerror!void {
    const new = try helpers.popString(ctx);
    const old = try helpers.popString(ctx);
    std.fs.cwd().rename(old, new) catch |err| {
        helpers.setErrorContext(ctx, "rename-path: {s}", .{@errorName(err)});
        return mapFileOpenError(err);
    };
}

/// copy-file ( src dst -- )
fn nativeCopyFile(ctx: *Context) anyerror!void {
    const dst = try helpers.popString(ctx);
    const src = try helpers.popString(ctx);
    const cwd = std.fs.cwd();
    cwd.copyFile(src, cwd, dst, .{}) catch |err| {
        helpers.setErrorContext(ctx, "copy-file: {s}", .{@errorName(err)});
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied => error.PermissionDenied,
            else => error.IOFailed,
        };
    };
}

/// path-exists? ( path -- bool )
fn nativePathExists(ctx: *Context) anyerror!void {
    const path = try helpers.popString(ctx);
    std.fs.cwd().access(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try ctx.stack.push(.{ .boolean = false });
            return;
        }
        helpers.setErrorContext(ctx, "path-exists?: {s}", .{@errorName(err)});
        return error.IOFailed;
    };
    try ctx.stack.push(.{ .boolean = true });
}

/// file-info ( path -- hash )
fn nativeFileInfo(ctx: *Context) anyerror!void {
    const path = try helpers.popString(ctx);
    const alloc = ctx.quotationAllocator();

    const stat = std.fs.cwd().statFile(path) catch |err| {
        helpers.setErrorContext(ctx, "file-info: {s}", .{@errorName(err)});
        return mapFileOpenError(err);
    };

    const hash = alloc.create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    // size
    const size_key = alloc.dupe(u8, "size") catch return error.OutOfMemory;
    hash.put(alloc, size_key, .{ .fixnum = @intCast(stat.size) }) catch return error.OutOfMemory;

    // type
    const type_key = alloc.dupe(u8, "type") catch return error.OutOfMemory;
    const type_sym: []const u8 = switch (stat.kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        else => "unknown",
    };
    hash.put(alloc, type_key, .{ .symbol = type_sym }) catch return error.OutOfMemory;

    // modified (epoch seconds from nanoseconds)
    const mod_key = alloc.dupe(u8, "modified") catch return error.OutOfMemory;
    const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
    hash.put(alloc, mod_key, .{ .fixnum = mtime_secs }) catch return error.OutOfMemory;

    // accessed (epoch seconds from nanoseconds)
    const acc_key = alloc.dupe(u8, "accessed") catch return error.OutOfMemory;
    const atime_secs: i64 = @intCast(@divFloor(stat.atime, std.time.ns_per_s));
    hash.put(alloc, acc_key, .{ .fixnum = atime_secs }) catch return error.OutOfMemory;

    // permissions
    const perm_key = alloc.dupe(u8, "permissions") catch return error.OutOfMemory;
    const mode: i64 = @intCast(stat.mode & 0o7777);
    hash.put(alloc, perm_key, .{ .fixnum = mode }) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .hash = hash });
}

/// create-symlink ( target link-path -- )
fn nativeCreateSymlink(ctx: *Context) anyerror!void {
    const link_path = try helpers.popString(ctx);
    const target = try helpers.popString(ctx);
    std.fs.cwd().symLink(target, link_path, .{}) catch |err| {
        helpers.setErrorContext(ctx, "create-symlink: {s}", .{@errorName(err)});
        return mapFileCreateError(err);
    };
}

/// read-symlink ( path -- target-path )
fn nativeReadSymlink(ctx: *Context) anyerror!void {
    const path = try helpers.popString(ctx);
    const alloc = ctx.quotationAllocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.cwd().readLink(path, &buf) catch |err| {
        helpers.setErrorContext(ctx, "read-symlink: {s}", .{@errorName(err)});
        return mapFileOpenError(err);
    };
    const result = alloc.dupe(u8, target) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .string = result });
}

/// set-permissions ( path mode -- )
fn nativeSetPermissions(ctx: *Context) anyerror!void {
    const mode = try helpers.popFixnum(ctx);
    const path = try helpers.popString(ctx);
    std.posix.fchmodat(std.fs.cwd().fd, path, @intCast(mode), 0) catch |err| {
        helpers.setErrorContext(ctx, "set-permissions: {s}", .{@errorName(err)});
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied, error.PermissionDenied => error.PermissionDenied,
            else => error.IOFailed,
        };
    };
}
