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

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "load", .stack_effect = "filename -- module", .doc = "Load a 1z source file and return a module with its definitions.", .func = nativeLoad },
    .{ .name = "import", .stack_effect = "module --", .doc = "Bring module words into the current scope.", .func = nativeImport },
    .{ .name = "1array", .stack_effect = "elem -- array", .doc = "Wrap element in a single-element array.", .func = native1Array },
    .{ .name = "command-line-args", .stack_effect = "-- args", .doc = "Push program arguments as an array of strings.", .func = nativeCommandLineArgs },
    .{ .name = "sys-exit", .stack_effect = "code --", .doc = "Exit the process with the given exit code.", .func = nativeSysExit },
    .{ .name = "add-load-path", .stack_effect = "path --", .doc = "Add a directory to the load path search list.", .func = nativeAddLoadPath },
    .{ .name = "(trampoline)", .stack_effect = "*unsafe-fn-ptr* --", .doc = "Call a native function via pointer. Internal use only.", .func = nativeTrampoline },
};

/// Check for if input refers to a file (contains '/' or ends with '.1z'),
/// or if it is a bare name to search for in load paths.
fn isPathMode(filename: []const u8) bool {
    return std.mem.indexOfScalar(u8, filename, '/') != null or
        std.mem.endsWith(u8, filename, ".1z");
}

/// Try to resolve a file in a given directory. Returns the absolute path if the file
/// exists, or null otherwise.
fn resolveInDir(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    const joined = std.fs.path.join(alloc, &.{ dir, name }) catch return null;
    defer alloc.free(joined);

    const canonical = std.fs.cwd().realpathAlloc(alloc, joined) catch {
        return null;
    };
    return canonical;
}

/// Resolve a load path according to path mode vs search mode rules.
///
/// Returns the resolved absolute path, or null if not found.
/// Auto-append .1z, search configured paths only.
/// Use path mode ("./foo.1z") for relative imports.
fn resolveLoadPath(ctx: *Context, filename: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
    if (isPathMode(filename)) {
        if (std.fs.path.isAbsolute(filename)) {
            return std.fs.cwd().realpathAlloc(alloc, filename) catch null;
        }

        const base_dir = ctx.current_source_dir orelse ".";
        return resolveInDir(alloc, base_dir, filename);
    }

    const name_with_ext = std.fmt.allocPrint(alloc, "{s}.1z", .{filename}) catch return null;
    defer alloc.free(name_with_ext);

    for (ctx.load_paths.items) |lp| {
        if (resolveInDir(alloc, lp, name_with_ext)) |resolved| {
            return resolved;
        }
    }

    if (ctx.stdlib_path) |sp| {
        if (resolveInDir(alloc, sp, name_with_ext)) |resolved| {
            return resolved;
        }
    }

    return null;
}

/// load ( filename -- module ) - Load a 1z source file and return a module with its definitions
///
/// Caches loaded modules by canonical file path to avoid redundant loads, so that
/// multiple `load` calls for the same file return the same module instance.
fn nativeLoad(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const filename = try popString(ctx);
    const resolved = resolveLoadPath(ctx, filename, alloc) orelse {
        const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "file-not-found",
            .message = msg,
            .source = ctx.current_source,
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "load",
        }) catch {};

        return error.FileNotFound;
    };

    // XXX(ripta): Module cache hit - side-effects won't run again.
    //             Is this okay? It better be.
    if (ctx.module_cache.get(resolved)) |cached_module| {
        return try ctx.stack.push(.{ .module = cached_module });
    }

    return nativeLoadImpl(ctx, filename, alloc, resolved);
}

fn nativeLoadImpl(ctx: *Context, filename: []const u8, alloc: std.mem.Allocator, resolved: []const u8) anyerror!void {
    const file = std.fs.cwd().openFile(resolved, .{}) catch {
        // Add error context for FileNotFound
        const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "file-not-found",
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

    // Save/restore current_source_dir around file execution
    const old_source_dir = ctx.current_source_dir;
    ctx.current_source_dir = std.fs.path.dirname(resolved);
    defer ctx.current_source_dir = old_source_dir;

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
                return error.FileReadFailed;
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

    // Copy definitions from frame to module.
    // Both compound and native words are captured. Native words occur in
    // loaded files when struct/virtual/enum definitions generate native
    // accessors and constructors via the native function registry.
    var iter = frame.iterator();
    while (iter.next()) |entry| {
        const word_def = entry.value_ptr.*;
        const mod_word: value_mod.ModuleWord = .{
            .stack_effect = word_def.stack_effect,
            .markers = word_def.markers,
            .source_module = if (word_def.imported) word_def.source_module else null,
            .action = switch (word_def.action) {
                .compound => |instrs| .{ .compound = instrs },
                .native => |func| .{ .native = func },
            },
        };
        if (word_def.imported) {
            try module.deps.put(alloc, entry.key_ptr.*, mod_word);
        } else {
            try module.words.put(alloc, entry.key_ptr.*, mod_word);
        }
    }

    ctx.module_cache.put(alloc, resolved, module) catch {};
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
        .action = switch (mod_word.action) {
            .compound => |instrs| .{ .compound = instrs },
            .native => |func| .{ .native = func },
        },
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
                addImportError(ctx, "empty-import", "cannot import empty array");
                return error.EmptyImport;
            }

            const module = helpers.popModule(ctx) catch {
                addImportError(ctx, "type-mismatch", "expected module, got non-module");
                return error.TypeMismatch;
            };
            if (!module.importable) {
                const msg = std.fmt.allocPrint(alloc, "module '{s}' cannot be imported", .{module.name}) catch "module cannot be imported";
                addImportError(ctx, "import-error", msg);
                return error.EmptyImport;
            }
            for (names) |name_val| {
                const name = switch (name_val) {
                    .symbol, .string => |s| s,
                    else => {
                        const type_name = helpers.valueTypeName(name_val);
                        const msg = std.fmt.allocPrint(alloc, "expected symbol, got {s}", .{type_name}) catch "expected symbol";
                        addImportError(ctx, "type-mismatch", msg);
                        return error.TypeMismatch;
                    },
                };
                const mod_word = module.words.get(name) orelse {
                    const msg = std.fmt.allocPrint(alloc, "key '{s}'", .{name}) catch "key '<unknown>'";
                    addImportError(ctx, "key-not-found", msg);
                    return error.KeyNotFound;
                };
                try importWord(ctx, name, mod_word, module);
            }
        },
        .module => |module| {
            if (!module.importable) {
                const msg = std.fmt.allocPrint(alloc, "module '{s}' cannot be imported", .{module.name}) catch "module cannot be imported";
                addImportError(ctx, "import-error", msg);
                return error.EmptyImport;
            }
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
            addImportError(ctx, "type-mismatch", msg);
            return error.TypeMismatch;
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
    const code = try helpers.popFixnum(ctx);
    std.process.exit(@intCast(code));
}

/// add-load-path ( path -- ) - Add a directory to the load path search list
fn nativeAddLoadPath(ctx: *Context) anyerror!void {
    const path = try popString(ctx);
    const duped = ctx.quotationAllocator().dupe(u8, path) catch return error.OutOfMemory;
    ctx.load_paths.append(ctx.allocator, duped) catch return error.OutOfMemory;
}

/// (trampoline) deprecated ( *unsafe-fn-ptr* -- ) - Call a native function via pointer
///
/// Dead code, kept for backward compatibility. All callsites were migrated to
/// the native function registry (the native.* virtual module).
///
/// Bridge primitive: pops a function pointer as a fixnum from the stack and calls it.
/// Used by auto-generated struct/virtual words to invoke their backing native helpers.
///
/// WARNING: This is inherently unsafe! The function pointer must be valid and
///          must conform to the expected signature (fn (*Context) anyerror!void), or
///          else the runtime will likely crash. - This is an experiment.
fn nativeTrampoline(ctx: *Context) anyerror!void {
    const ptr_val = try helpers.popFixnum(ctx);
    if (ptr_val <= 0) {
        ctx.pending_error_message = "(trampoline): null or negative function pointer";
        return error.InvalidFunctionPointer;
    }
    const addr: usize = @intCast(ptr_val);
    const alignment = @alignOf(fn (*Context) anyerror!void);
    if (addr % alignment != 0) {
        ctx.pending_error_message = "(trampoline): function pointer is not properly aligned";
        return error.InvalidFunctionPointer;
    }
    const func: *const fn (*Context) anyerror!void = @ptrFromInt(addr);
    try func(ctx);
}

/// 1array ( elem -- array ) - Wrap element in single-element array
fn native1Array(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const arr = alloc.alloc(Value, 1) catch return error.OutOfMemory;
    arr[0] = elem;

    try ctx.stack.push(.{ .array = arr });
}
