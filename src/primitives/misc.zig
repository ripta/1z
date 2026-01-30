const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;
const StatementProcessor = @import("../statement.zig").StatementProcessor;

const markers_mod = @import("markers.zig");
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
    .{ .name = "command-line-args", .stack_effect = "-- args", .func = nativeCommandLineArgs },
    .{ .name = "sys-exit", .stack_effect = "code --", .func = nativeSysExit },
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
///
/// Caches loaded modules by canonical file path to avoid redundant loads, so that
/// multiple `load` calls for the same file return the same module instance.
fn nativeLoad(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const filename = try popString(ctx);
    const canon = std.fs.cwd().realpathAlloc(alloc, filename) catch {
        return nativeLoadImpl(ctx, filename, alloc, filename);
    };

    // XXX(ripta): Module cache hit - side-effects won't run again.
    //             Is this okay? It better be.
    if (ctx.module_cache.get(canon)) |cached_module| {
        return try ctx.stack.push(.{ .module = cached_module });
    }

    return nativeLoadImpl(ctx, filename, alloc, canon);
}

fn nativeLoadImpl(ctx: *Context, filename: []const u8, alloc: std.mem.Allocator, canon: []const u8) anyerror!void {
    const file = std.fs.cwd().openFile(filename, .{}) catch {
        // Add error context for FileNotFound
        const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "FileNotFound",
            .message = msg,
            .source = ctx.current_source,
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "load",
        }) catch {};
        return error.FileNotFound;
    };
    defer file.close();

    const old_source = ctx.current_source;
    ctx.current_source = filename;
    defer ctx.current_source = old_source;

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    try ctx.pushLocalFrame();
    errdefer ctx.popLocalFrame();

    // XXX(ripta): Hack to set import target frame, which may execute inside
    //             combinator frames like `if`, instead of global or ephemeral
    //             frame. No rugrats for now.
    const old_import_frame = ctx.import_frame_index;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    defer ctx.import_frame_index = old_import_frame;

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
                const mod_word = ModuleWord{
                    .stack_effect = word_def.stack_effect,
                    .instructions = instrs,
                    .markers = word_def.markers,
                };
                if (word_def.imported) {
                    // Imported words go to deps (not part of public API,
                    // but needed at runtime for late-binding resolution)
                    try module.deps.put(alloc, entry.key_ptr.*, mod_word);
                } else {
                    try module.words.put(alloc, entry.key_ptr.*, mod_word);
                }
            },
            .native => {}, // Skip native words (shouldn't happen in loaded files)
        }
    }

    ctx.module_cache.put(alloc, canon, module) catch {};
    ctx.popLocalFrame();
    try ctx.stack.push(.{ .module = module });
}

fn importWord(ctx: *Context, name: []const u8, mod_word: ModuleWord, module: *const Module) !void {
    const has_parse_time = for (mod_word.markers) |mk| {
        if (markers_mod.isParseTimeMarker(mk)) break true;
    } else false;
    try ctx.defineImportedWord(name, .{
        .name = name,
        .parse_time = has_parse_time,
        .imported = true,
        .stack_effect = mod_word.stack_effect,
        .markers = mod_word.markers,
        .source_module = module,
        .action = .{ .compound = mod_word.instructions },
    });
}

fn addImportError(ctx: *Context, error_type: []const u8, message: []const u8) void {
    ctx.error_details.append(ctx.allocator, .{
        .error_type = error_type,
        .message = message,
        .source = ctx.current_source,
        .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
        .word_name = "import",
    }) catch {};
}

fn nativeImport(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const top_val = try ctx.stack.pop();

    switch (top_val) {
        .array => |names| {
            if (names.len == 0) {
                addImportError(ctx, "EmptyImport", "cannot import empty array");
                return error.EmptyImport;
            }

            const module = helpers.popModule(ctx) catch {
                addImportError(ctx, "TypeError", "expected module, got non-module");
                return error.TypeError;
            };
            for (names) |name_val| {
                const name = switch (name_val) {
                    .symbol, .string => |s| s,
                    else => {
                        const type_name = helpers.valueTypeName(name_val);
                        const msg = std.fmt.allocPrint(alloc, "expected symbol, got {s}", .{type_name}) catch "expected symbol";
                        addImportError(ctx, "TypeError", msg);
                        return error.TypeError;
                    },
                };
                const mod_word = module.words.get(name) orelse {
                    const msg = std.fmt.allocPrint(alloc, "key '{s}'", .{name}) catch "key '<unknown>'";
                    addImportError(ctx, "KeyNotFound", msg);
                    return error.KeyNotFound;
                };
                try importWord(ctx, name, mod_word, module);
            }
        },
        .module => |module| {
            // XXX(ripta): Consider better visibility control in the future? For
            //             now, all non-dep words are considered public API.
            //             Each imported word carries a source_module reference
            //             so that late-bound references to deps can be resolved
            //             at runtime.
            var iter = module.words.iterator();
            while (iter.next()) |entry| {
                try importWord(ctx, entry.key_ptr.*, entry.value_ptr.*, module);
            }
        },
        else => {
            const type_name = helpers.valueTypeName(top_val);
            const msg = std.fmt.allocPrint(alloc, "expected module, got {s}", .{type_name}) catch "expected module";
            addImportError(ctx, "TypeError", msg);
            return error.TypeError;
        },
    }
}

/// command-line-args ( -- args ) - Push program arguments as an array of strings
fn nativeCommandLineArgs(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const args = ctx.program_args;

    const arr = alloc.alloc(Value, args.len) catch return error.OutOfMemory;
    for (args, 0..) |arg, i| {
        arr[i] = .{ .string = arg };
    }

    try ctx.stack.push(.{ .array = arr });
}

/// sys-exit ( code -- ) - Exit the process with the given exit code
fn nativeSysExit(ctx: *Context) anyerror!void {
    const code = try helpers.popInteger(ctx);
    std.process.exit(@intCast(code));
}

/// 1array ( elem -- array ) - Wrap element in single-element array
fn native1Array(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const arr = alloc.alloc(Value, 1) catch return error.OutOfMemory;
    arr[0] = elem;

    try ctx.stack.push(.{ .array = arr });
}
