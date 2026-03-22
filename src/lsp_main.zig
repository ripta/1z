const std = @import("std");
const File = std.fs.File;
const Context = @import("context.zig").Context;
const lsp = @import("lsp/mod.zig");

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Resolve stdlib path relative to the binary, matching the interpreter's logic
    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExeDirPath(&self_exe_buf)) |exe_dir| {
        const default_lib = std.fs.path.join(ctx.quotationAllocator(), &.{ exe_dir, "../lib" }) catch null;
        if (default_lib) |lib_path| {
            var real_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fs.cwd().realpath(lib_path, &real_buf)) |real| {
                ctx.stdlib_path = ctx.quotationAllocator().dupe(u8, real) catch null;
            } else |_| {}
        }
    } else |_| {}

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
    var server = lsp.Server.init(allocator, &transport, &ctx);

    return server.run();
}
