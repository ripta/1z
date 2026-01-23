const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const StatementProcessor = @import("../statement.zig").StatementProcessor;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popSymbol = helpers.popSymbol;
const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "help", .stack_effect = "name --", .func = nativeHelp },
    .{ .name = "load", .stack_effect = "filename --", .func = nativeLoad },
    .{ .name = "1array", .stack_effect = "elem -- array", .func = native1Array },
};

/// help ( symbol -- ) - Display help for a word
fn nativeHelp(ctx: *Context) anyerror!void {
    const name = try popSymbol(ctx);

    const stdout_file: std.fs.File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
    const writer = &stdout.interface;

    if (ctx.lookupWord(name)) |word| {
        try writer.print("{s}", .{word.name});
        if (word.stack_effect) |effect| {
            try writer.writeAll(" ");
            try effect.write(writer);
        }

        switch (word.action) {
            .native => try writer.writeAll(" \\native\n"),
            .compound => try writer.writeAll(" [compound]\n"),
        }
    } else {
        try writer.print("{s}: no such word\n", .{name});
    }

    try stdout.interface.flush();
}

/// load ( filename -- ) - Load and execute a 1z source file
fn nativeLoad(ctx: *Context) anyerror!void {
    const filename = try popString(ctx);

    const file = std.fs.cwd().openFile(filename, .{}) catch {
        return error.FileNotFound;
    };
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    var processor: StatementProcessor = .{};

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Try to execute any remaining buffered content
                switch (processor.flush(ctx.quotationAllocator(), ctx)) {
                    .needs_more_input => {},
                    .parse_error => |e| return e,
                    .complete => |instrs| {
                        if (instrs.len > 0) {
                            try ctx.executeQuotation(.{ .instructions = instrs });
                        }
                    },
                }
                break;
            },
            else => return error.FileReadError,
        };

        switch (processor.feedLine(ctx.quotationAllocator(), line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| return err,
            .complete => |instrs| {
                if (instrs.len > 0) {
                    try ctx.executeQuotation(.{ .instructions = instrs });
                }
                processor.reset();
            },
        }
    }
}

/// 1array ( elem -- array ) - Wrap element in single-element array
fn native1Array(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const arr = alloc.alloc(Value, 1) catch return error.OutOfMemory;
    arr[0] = elem;

    try ctx.stack.push(.{ .array = arr });
}
