const std = @import("std");
const Context = @import("context.zig").Context;
const File = std.fs.File;
const Io = std.io;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try repl(&ctx);
}

fn repl(ctx: *Context) !void {
    const stdin_file: File = .stdin();
    const stdout_file: File = .stdout();

    // Buffers for buffered I/O
    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin = stdin_file.reader(&stdin_buf);
    var stdout = stdout_file.writer(&stdout_buf);

    // Get the interfaces
    const writer = &stdout.interface;
    const reader = &stdin.interface;

    try writer.writeAll("1z interpreter\n");
    try writer.writeAll("Type '.q' to quit\n\n");
    try writer.flush();

    while (true) {
        // Print prompt
        try writer.writeAll("> ");
        try writer.flush();

        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                try writer.writeAll("\nGoodbye!\n");
                try writer.flush();
                return;
            },
            else => {
                try writer.print("\nError reading input: {any}\n", .{err});
                try writer.flush();
                continue;
            },
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (std.mem.eql(u8, trimmed, ".q") or std.mem.eql(u8, trimmed, "quit")) {
            try writer.writeAll("Goodbye!\n");
            try writer.flush();
            break;
        }

        if (trimmed.len == 0) {
            continue;
        }

        // TODO(ripta): parse and interpret the input line
        try writer.print("Input: {s}\n", .{trimmed});
        try writer.writeAll("Stack: ");
        try ctx.stack.dump(writer);
        try writer.writeAll("\n");
        try writer.flush();
    }
}

// =============================================================================
// Tests - import other modules to run their tests
// =============================================================================

test {
    _ = @import("value.zig");
    _ = @import("stack.zig");
    _ = @import("context.zig");
}
