//! Replacing a file's contents by writing a temporary beside it and renaming that over the
//! target, so a concurrent reader observes either the old file or the new one and never a
//! half-written state.
//!
//! The rename itself is the caller's. `replace:` closes its descriptor through the stream vtable
//! well before `stream-close` renames, and the formatter closes its own just before, so a shared
//! wrapper here would have to either double-close or say nothing about the ordering. What it
//! would gain is one line.
//!
//! A failed rename leaves the target untouched either way. What becomes of the temporary is the
//! caller's call, and the two answer differently. `replace:` keeps it, because the bytes a
//! program streamed out may not be reproducible. The formatter deletes it, because it can always
//! format the file again and a tree-wide run would otherwise leave one behind per failure.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Leading characters of a replacement's temporary, followed by sixteen hex digits. It must not
/// end in `.1z`: the formatter's own sweep is `find . -name '*.1z'`, and a temporary matching
/// that would be handed back to the formatter as an input. The dot makes a leftover from an
/// abandoned replacement ignorable through the `.1z-replace-*` entry in `.gitignore`.
pub const temp_prefix = ".1z-replace-";

/// What a stat of the replacement's target found.
///
/// `path` is the target with symlinks resolved, so the rename lands on the file a link points at
/// rather than on the link itself. It borrows the buffer `inspect` was handed, except when the
/// target does not exist, where it is the caller's own path.
pub const Target = struct {
    path: []const u8,
    exists: bool,
    is_dir: bool,
    link_count: u64,

    /// The target's own permission bits, or null when there is no target to carry them from.
    mode: ?std.fs.File.Mode,
};

/// Resolve and stat the file a replacement will land on. `buf` backs the resolved path.
///
/// A missing target is not a failure: a replacement creates one, and the umask then supplies the
/// mode that would otherwise have been carried.
pub fn inspect(path: []const u8, buf: *[std.fs.max_path_bytes]u8) !Target {
    const resolved = std.fs.cwd().realpath(path, buf) catch |err| switch (err) {
        error.FileNotFound => return .{
            .path = path,
            .exists = false,
            .is_dir = false,
            .link_count = 0,
            .mode = null,
        },
        else => return err,
    };

    // The tree's other stat sites use `statFile`, whose `File.Stat` carries no link count.
    const stat = try std.posix.fstatat(std.fs.cwd().fd, resolved, 0);

    return .{
        .path = resolved,
        .exists = true,
        .is_dir = std.posix.S.ISDIR(@intCast(stat.mode)),
        .link_count = stat.nlink,
        .mode = @intCast(stat.mode & 0o7777),
    };
}

/// A created temporary. `path` is allocated from the allocator `createTemp` was handed.
pub const Temp = struct {
    file: std.fs.File,
    path: []const u8,
};

/// Which step `createTemp` was on when it returned. A caller that distinguishes the two in its
/// message passes a pointer; one that renders the error name alone passes null.
pub const Step = enum { create, carry_mode };

/// Create the exclusive temporary a replacement writes to, beside the file the rename will move
/// it onto. `carried_mode` is the target's own mode, or null when there is no target yet.
///
/// Every allocation happens ahead of the create that succeeds, so nothing can still fail for want
/// of memory once the temporary exists on disk.
pub fn createTemp(
    alloc: Allocator,
    target_path: []const u8,
    carried_mode: ?std.fs.File.Mode,
    step: ?*Step,
) !Temp {
    if (step) |s| s.* = .create;

    const dir_path = std.fs.path.dirname(target_path);
    const mode = carried_mode orelse std.fs.File.default_mode;

    // Exclusive creation is what closes the collision between two concurrent runs. A
    // unique-looking name does not. Retrying on a taken name mirrors `std.fs.AtomicFile.init`.
    const file, const temp_path = while (true) {
        var name_buf: [temp_prefix.len + 16]u8 = undefined;
        const hex = std.fmt.hex(std.crypto.random.int(u64));
        const temp_name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ temp_prefix, &hex }) catch unreachable;

        const candidate = if (dir_path) |dir|
            try std.fs.path.join(alloc, &.{ dir, temp_name })
        else
            try alloc.dupe(u8, temp_name);

        // A name that loses the race and a create that fails outright both leave `candidate`
        // behind. The callers' allocators differ, and one of them reports a leak.
        const opened = std.fs.cwd().createFile(candidate, .{ .mode = mode, .exclusive = true }) catch |err| {
            alloc.free(candidate);
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        break .{ opened, candidate };
    };

    // `createFile` applies the umask, which would silently drop a bit the target had. A target
    // that did not exist has nothing to carry, and there the umask is the right answer.
    if (carried_mode) |exact| {
        if (step) |s| s.* = .carry_mode;
        std.posix.fchmod(file.handle, exact) catch |err| {
            file.close();
            discard(temp_path);
            alloc.free(temp_path);
            return err;
        };
    }

    return .{ .file = file, .path = temp_path };
}

/// Remove a temporary that will not be committed. The caller has already closed its descriptor.
pub fn discard(temp_path: []const u8) void {
    std.fs.cwd().deleteFile(temp_path) catch {};
}

// =============================================================================
// Tests
// =============================================================================

test "createTemp names a temporary the tree's own tooling steps over" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(target);

    const target_path = try std.fs.path.join(std.testing.allocator, &.{ target, "target.1z" });
    defer std.testing.allocator.free(target_path);

    const temp = try createTemp(std.testing.allocator, target_path, null, null);
    defer std.testing.allocator.free(temp.path);
    defer discard(temp.path);
    temp.file.close();

    const name = std.fs.path.basename(temp.path);
    try std.testing.expect(std.mem.startsWith(u8, name, temp_prefix));
    try std.testing.expect(!std.mem.endsWith(u8, name, ".1z"));
    try std.testing.expectEqualStrings(target, std.fs.path.dirname(temp.path).?);
}

test "createTemp carries an exact mode past the umask" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    const target_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "target.txt" });
    defer std.testing.allocator.free(target_path);

    // Group-write is what makes this bite: the ordinary 022 umask clears it, so a temporary that
    // only passed the mode to the create would come back 0o640.
    const temp = try createTemp(std.testing.allocator, target_path, 0o660, null);
    defer std.testing.allocator.free(temp.path);
    defer discard(temp.path);
    temp.file.close();

    const stat = try std.fs.cwd().statFile(temp.path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o660), stat.mode & 0o7777);
}
