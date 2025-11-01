const std = @import("std");
const File = std.fs.File;

const Context = @import("context.zig").Context;
const StatementProcessor = @import("statement.zig").StatementProcessor;

const build_options = @import("build_options");
pub const version = build_options.version;

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const args = std.process.argsAlloc(allocator) catch return 1;
    defer std.process.argsFree(allocator, args);

    // If a file path is provided, run in batch mode, which executes the file
    // and exits. Errors print to stderr, and cause a non-zero exit code.
    // Otherwise, interactive REPL starts.
    if (args.len > 1) {
        return batch(&ctx, args[1]);
    } else {
        repl(&ctx);
        return 0;
    }
}

fn repl(ctx: *Context) void {
    const stdin_file: File = .stdin();
    const stdout_file: File = .stdout();

    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin = stdin_file.reader(&stdin_buf);
    var stdout = stdout_file.writer(&stdout_buf);

    const writer = &stdout.interface;
    const reader = &stdin.interface;

    writer.print("1z interpreter v{s}\n", .{version}) catch return;
    writer.writeAll("Type '.q' to quit\n\n") catch return;
    writer.flush() catch return;

    var processor: StatementProcessor = .{};
    while (true) {
        // Show continuation prompt if accumulating, otherwise primary prompt
        if (processor.isAccumulating()) {
            writer.writeAll("+ ") catch return;
        } else {
            writer.writeAll("> ") catch return;
        }
        writer.flush() catch return;

        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                writer.writeAll("\nGoodbye!\n") catch {};
                writer.flush() catch {};
                return;
            },
            else => {
                writer.print("\nError reading input: {any}\n", .{err}) catch {};
                writer.flush() catch {};
                continue;
            },
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.eql(u8, trimmed, ".q")) {
            writer.writeAll("Goodbye!\n") catch {};
            writer.flush() catch {};
            break;
        }

        switch (processor.feedLine(ctx.quotationAllocator(), line)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                writer.print("Error: {any}\n", .{err}) catch {};
                writer.flush() catch return;
                processor.reset();
            },
            .complete => |instrs| {
                var had_error = false;
                ctx.executeQuotation(instrs) catch |err| {
                    writer.print("Error: {any}\n", .{err}) catch {};
                    had_error = true;
                };

                if (!had_error) {
                    writer.writeAll("Stack: ") catch return;
                    ctx.stack.dump(writer) catch return;
                    writer.writeAll("\n") catch return;
                }

                writer.flush() catch return;
                processor.reset();
            },
        }
    }
}

fn batch(ctx: *Context, file_path: []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writer(&stderr_buf);
    const err_writer = &stderr.interface;

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        err_writer.print("Error opening file '{s}': {any}\n", .{ file_path, err }) catch {};
        err_writer.flush() catch {};
        return 1;
    };
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    var processor: StatementProcessor = .{};
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Try to execute any remaining buffered content
                switch (processor.flush(ctx.quotationAllocator())) {
                    .needs_more_input => {},
                    .parse_error => |e| {
                        err_writer.print("Error: {any}\n", .{e}) catch {};
                        err_writer.flush() catch {};
                        return 1;
                    },
                    .complete => |instrs| {
                        if (instrs.len > 0) {
                            ctx.executeQuotation(instrs) catch |e| {
                                err_writer.print("Error: {any}\n", .{e}) catch {};
                                err_writer.flush() catch {};
                                return 1;
                            };
                        }
                    },
                }
                break;
            },
            else => {
                err_writer.print("Error reading file: {any}\n", .{err}) catch {};
                err_writer.flush() catch {};
                return 1;
            },
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.eql(u8, trimmed, ".q")) break;

        switch (processor.feedLine(ctx.quotationAllocator(), line)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                err_writer.print("Error: {any}\n", .{err}) catch {};
                err_writer.flush() catch {};
                return 1;
            },
            .complete => |instrs| {
                if (instrs.len > 0) {
                    ctx.executeQuotation(instrs) catch |err| {
                        err_writer.print("Error: {any}\n", .{err}) catch {};
                        err_writer.flush() catch {};
                        return 1;
                    };
                }
                processor.reset();
            },
        }
    }

    return 0;
}

// =============================================================================
// Tests - import other modules to run their tests
// =============================================================================

test {
    _ = @import("value.zig");
    _ = @import("stack.zig");
    _ = @import("context.zig");
    _ = @import("tokenizer.zig");
    _ = @import("dictionary.zig");
    _ = @import("primitives.zig");
    _ = @import("parser.zig");
    _ = @import("statement.zig");
}
