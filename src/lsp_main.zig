const std = @import("std");
const File = std.fs.File;
const Context = @import("context.zig").Context;
const lsp = @import("lsp/mod.zig");
const formatter = @import("formatter.zig");

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    ctx.stdlib_path = resolveStdlibPath(&ctx);

    ctx.loadPrelude(null) catch |err| {
        std.debug.panic("Failed to load prelude: {any}", .{err});
    };

    const stdin_file: File = .stdin();
    var stdin_buf: [4096]u8 = undefined;
    var stdin = stdin_file.reader(&stdin_buf);

    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);

    var transport = lsp.Transport.init(allocator, &stdin.interface, &stdout.interface);
    var server = lsp.Server.init(allocator, &transport, &ctx, resolveFmtEngine());

    return server.run();
}

/// Where the standard library lives, on the interpreter's own precedence: `ONEZ_STDLIB` first,
/// then `../lib` beside the binary. Null when neither answers, which leaves module resolution to
/// whatever fallback the build has.
fn resolveStdlibPath(ctx: *Context) ?[]const u8 {
    if (std.posix.getenv("ONEZ_STDLIB")) |env_val| {
        return ctx.quotationAllocator().dupe(u8, env_val) catch null;
    }

    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&self_exe_buf) catch return null;
    const default_lib = std.fs.path.join(ctx.quotationAllocator(), &.{ exe_dir, "../lib" }) catch return null;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.fs.cwd().realpath(default_lib, &real_buf) catch return null;
    return ctx.quotationAllocator().dupe(u8, real) catch null;
}

/// The formatter `ONEZ_FMT_ENGINE` selects, matching what `1z fmt` reads from the same variable.
///
/// A value naming neither engine is reported and ignored rather than fatal: stdout carries the
/// protocol, so there is nowhere to fail usefully, and the default keeps the session working.
fn resolveFmtEngine() formatter.Engine {
    const value = std.posix.getenv("ONEZ_FMT_ENGINE") orelse return .zig;
    return formatter.parseEngine(value) orelse {
        std.debug.print("Warning: invalid ONEZ_FMT_ENGINE '{s}' (want zig or 1z); using zig\n", .{value});
        return .zig;
    };
}
