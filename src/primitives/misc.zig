const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;
const StatementProcessor = @import("../statement.zig").StatementProcessor;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const WordDefinition = @import("../dictionary.zig").WordDefinition;

const popSymbol = helpers.popSymbol;
const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "help", .stack_effect = "name --", .func = nativeHelp },
    .{ .name = "load", .stack_effect = "filename -- module", .func = nativeLoad },
    .{ .name = "import", .stack_effect = "module --", .func = nativeImport },
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

/// load ( filename -- module ) - Load a 1z source file and return a module with its definitions
fn nativeLoad(ctx: *Context) anyerror!void {
    const filename = try popString(ctx);
    const alloc = ctx.quotationAllocator();

    const file = std.fs.cwd().openFile(filename, .{}) catch {
        return error.FileNotFound;
    };
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    try ctx.pushLocalFrame();
    errdefer ctx.popLocalFrame();

    var processor: StatementProcessor = .{};

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Try to execute any remaining buffered content
                switch (processor.flush(alloc, ctx)) {
                    .needs_more_input => {},
                    .parse_error => |e| {
                        ctx.popLocalFrame();
                        return e;
                    },
                    .complete => |instrs| {
                        if (instrs.len > 0) {
                            ctx.executeQuotation(.{ .instructions = instrs }) catch |e| {
                                ctx.popLocalFrame();
                                return e;
                            };
                        }
                    },
                }
                break;
            },
            else => {
                ctx.popLocalFrame();
                return error.FileReadError;
            },
        };

        switch (processor.feedLine(alloc, line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                ctx.popLocalFrame();
                return err;
            },
            .complete => |instrs| {
                if (instrs.len > 0) {
                    ctx.executeQuotation(.{ .instructions = instrs }) catch |e| {
                        ctx.popLocalFrame();
                        return e;
                    };
                }
                processor.reset();
            },
        }
    }

    // Capture definitions from the frame before popping
    const frame_index = ctx.local_frames.items.len - 1;
    const frame = &ctx.local_frames.items[frame_index];

    // Create module
    const module = try alloc.create(Module);
    module.* = .{
        .name = try alloc.dupe(u8, filename),
        .words = .{},
    };

    // Copy definitions from frame to module
    var iter = frame.iterator();
    while (iter.next()) |entry| {
        const word_def = entry.value_ptr.*;
        // Only capture compound words (user-defined), not natives
        switch (word_def.action) {
            .compound => |instrs| {
                try module.words.put(alloc, entry.key_ptr.*, .{
                    .stack_effect = word_def.stack_effect,
                    .instructions = instrs,
                });
            },
            .native => {}, // Skip native words (shouldn't happen in loaded files)
        }
    }

    ctx.popLocalFrame();
    try ctx.stack.push(.{ .module = module });
}

fn importWord(ctx: *Context, name: []const u8, mod_word: ModuleWord) !void {
    try ctx.dictionary.put(name, .{
        .name = name,
        .stack_effect = mod_word.stack_effect,
        .action = .{ .compound = mod_word.instructions },
    });
}

fn nativeImport(ctx: *Context) anyerror!void {
    const top_val = try ctx.stack.pop();

    switch (top_val) {
        .array => |names| {
            if (names.len == 0) return error.EmptyImport;

            const module = try helpers.popModule(ctx);
            for (names) |name_val| {
                const name = switch (name_val) {
                    .symbol, .string => |s| s,
                    else => return error.TypeError,
                };
                const mod_word = module.words.get(name) orelse return error.KeyNotFound;
                try importWord(ctx, name, mod_word);
            }
        },
        .module => |module| {
            var iter = module.words.iterator();
            while (iter.next()) |entry| {
                try importWord(ctx, entry.key_ptr.*, entry.value_ptr.*);
            }
        },
        else => return error.TypeError,
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
