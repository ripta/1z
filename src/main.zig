const std = @import("std");
const File = std.fs.File;

const context = @import("context.zig");
const Context = context.Context;
const ErrorDetail = context.ErrorDetail;
const StatementProcessor = @import("statement.zig").StatementProcessor;
const formatter = @import("formatter.zig");

const build_options = @import("build_options");
pub const version = build_options.version;

/// Print error details from the context's error stack.
fn printErrorDetails(ctx: *Context, writer: anytype, err: anyerror) void {
    writer.print("Error: {any}\n", .{err}) catch return;

    // Print error details in reverse order (most recent first is the innermost error)
    const details = ctx.error_details.items;
    if (details.len > 0) {
        for (details) |detail| {
            if (detail.line > 0) {
                writer.print("  at line {d}: {s}\n", .{ detail.line, detail.word_name orelse detail.message }) catch return;
            } else {
                writer.print("  in: {s}\n", .{detail.word_name orelse detail.message}) catch return;
            }
        }
    }
    ctx.clearErrorDetails();
}

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch return 1;
    defer std.process.argsFree(allocator, args);

    // Check for fmt subcommand first
    if (args.len > 1 and std.mem.eql(u8, args[1], "fmt")) {
        return handleFmt(allocator, args[2..]);
    }

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // If a file path is provided, run in batch mode, which executes the file
    // and exits. Errors print to stderr, and cause a non-zero exit code.
    // Otherwise, interactive REPL starts.
    var show_stack = false;
    var file_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--show-stack")) {
            show_stack = true;
        } else {
            file_path = arg;
        }
    }
    if (file_path) |path| {
        return batch(&ctx, path, show_stack);
    } else {
        repl(&ctx);
        return 0;
    }
}

fn handleFmt(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writer(&stderr_buf);
    const err_writer = &stderr.interface;

    var check_only = false;
    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer paths.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else {
            paths.append(allocator, arg) catch {
                err_writer.writeAll("Error: out of memory\n") catch {};
                err_writer.flush() catch {};
                return 1;
            };
        }
    }

    if (paths.items.len == 0) {
        err_writer.writeAll("Usage: 1z fmt [--check] <file...>\n") catch {};
        err_writer.writeAll("       1z fmt [--check] .\n") catch {};
        err_writer.flush() catch {};
        return 1;
    }

    var any_changes = false;
    var any_errors = false;

    for (paths.items) |path| {
        // Check if path is a directory
        const stat = std.fs.cwd().statFile(path) catch |err| {
            err_writer.print("Error accessing '{s}': {any}\n", .{ path, err }) catch {};
            any_errors = true;
            continue;
        };

        if (stat.kind == .directory) {
            const result = formatDirectory(allocator, path, check_only, err_writer);
            if (result.had_errors) any_errors = true;
            if (result.had_changes) any_changes = true;
        } else {
            const result = formatSingleFile(allocator, path, check_only, err_writer);
            if (result.had_errors) any_errors = true;
            if (result.had_changes) any_changes = true;
        }
    }

    err_writer.flush() catch {};

    if (any_errors) return 1;
    if (check_only and any_changes) return 1;
    return 0;
}

const FormatResult = struct {
    had_errors: bool,
    had_changes: bool,
};

fn formatSingleFile(allocator: std.mem.Allocator, path: []const u8, check_only: bool, err_writer: anytype) FormatResult {
    if (check_only) {
        const is_formatted = formatter.checkFile(allocator, path) catch |err| {
            err_writer.print("Error checking '{s}': {any}\n", .{ path, err }) catch {};
            return .{ .had_errors = true, .had_changes = false };
        };
        if (!is_formatted) {
            err_writer.print("{s} needs formatting\n", .{path}) catch {};
            return .{ .had_errors = false, .had_changes = true };
        }
        return .{ .had_errors = false, .had_changes = false };
    } else {
        formatter.formatFile(allocator, path) catch |err| {
            err_writer.print("Error formatting '{s}': {any}\n", .{ path, err }) catch {};
            return .{ .had_errors = true, .had_changes = false };
        };
        return .{ .had_errors = false, .had_changes = false };
    }
}

fn formatDirectory(allocator: std.mem.Allocator, dir_path: []const u8, check_only: bool, err_writer: anytype) FormatResult {
    var result = FormatResult{ .had_errors = false, .had_changes = false };

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        err_writer.print("Error opening directory '{s}': {any}\n", .{ dir_path, err }) catch {};
        return .{ .had_errors = true, .had_changes = false };
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".1z")) continue;

        // Build full path
        const full_path = if (std.mem.eql(u8, dir_path, "."))
            allocator.dupe(u8, entry.name) catch {
                result.had_errors = true;
                continue;
            }
        else
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch {
                result.had_errors = true;
                continue;
            };
        defer allocator.free(full_path);

        const file_result = formatSingleFile(allocator, full_path, check_only, err_writer);
        if (file_result.had_errors) result.had_errors = true;
        if (file_result.had_changes) result.had_changes = true;
    }

    return result;
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
    writer.writeAll("Press ^D to quit\n\n") catch return;
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
                    printErrorDetails(ctx, writer, err);
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

fn batch(ctx: *Context, file_path: []const u8, show_stack: bool) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writer(&stderr_buf);
    const err_writer = &stderr.interface;

    // For --show-stack, prepare stdout writer
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
    const out_writer = &stdout.interface;

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        err_writer.print("Error opening file '{s}': {any}\n", .{ file_path, err }) catch {};
        err_writer.flush() catch {};
        return 1;
    };
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    var processor: StatementProcessor = .{};
    var file_line: usize = 0;
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
                            // Adjust line numbers in instructions based on file position
                            adjustInstructionLines(instrs, processor.start_line);
                            ctx.executeQuotation(instrs) catch |e| {
                                printErrorDetails(ctx, err_writer, e);
                                err_writer.flush() catch {};
                                return 1;
                            };
                            if (show_stack) {
                                out_writer.writeAll("Stack: ") catch {};
                                ctx.stack.dump(out_writer) catch {};
                                out_writer.writeAll("\n") catch {};
                                out_writer.flush() catch {};
                            }
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

        file_line += 1;
        processor.trackLine(file_line);

        switch (processor.feedLine(ctx.quotationAllocator(), line)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                err_writer.print("Error at line {d}: {any}\n", .{ file_line, err }) catch {};
                err_writer.flush() catch {};
                return 1;
            },
            .complete => |instrs| {
                if (instrs.len > 0) {
                    // Adjust line numbers in instructions based on file position
                    adjustInstructionLines(instrs, processor.start_line);
                    ctx.executeQuotation(instrs) catch |err| {
                        printErrorDetails(ctx, err_writer, err);
                        err_writer.flush() catch {};
                        return 1;
                    };
                    if (show_stack) {
                        out_writer.writeAll("Stack: ") catch {};
                        ctx.stack.dump(out_writer) catch {};
                        out_writer.writeAll("\n") catch {};
                        out_writer.flush() catch {};
                    }
                }
                processor.reset();
            },
        }
    }

    return 0;
}

/// Adjust line numbers in instructions by adding an offset.
fn adjustInstructionLines(instrs: []const @import("value.zig").Instruction, line_offset: usize) void {
    if (line_offset == 0) return;
    for (instrs) |*instr| {
        const ptr = @constCast(instr);
        ptr.line += line_offset - 1; // -1 because tokenizer starts at line 1
        // Recursively adjust nested quotations
        switch (instr.op) {
            .push_literal => |val| {
                switch (val) {
                    .quotation => |nested| adjustInstructionLines(nested, line_offset),
                    else => {},
                }
            },
            else => {},
        }
    }
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
    _ = @import("formatter.zig");
}
