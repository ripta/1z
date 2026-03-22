const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;
const StatementProcessor = @import("../statement.zig").StatementProcessor;

const markers_mod = @import("markers.zig");
const helpers = @import("helpers.zig");
const protocols = @import("protocols.zig");
const Primitive = @import("types.zig").Primitive;
const Capability = @import("types.zig").Capability;
const trace_mod = @import("../trace.zig");

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "import", .stack_effect = "module --", .doc = "Bring module words into the current scope.", .func = nativeImport },
    .{ .name = ">module", .stack_effect = "name hashtable -- module", .doc = "Convert a name string and a hashtable of quotations into a module value suitable for import.", .func = nativeToModule },
    .{ .name = "1array", .stack_effect = "elem -- array", .doc = "Wrap element in a single-element array.", .func = native1Array },
    .{ .name = "command-line-args", .stack_effect = "-- args", .doc = "Push program arguments as an array of strings.", .func = nativeCommandLineArgs, .capability = .system },
    .{ .name = "sys-exit", .stack_effect = "code --", .doc = "Exit the process with the given exit code.", .func = nativeSysExit, .capability = .system },
    .{ .name = "add-load-path", .stack_effect = "path --", .doc = "Add a directory to the load path search list.", .func = nativeAddLoadPath },
    .{ .name = "(trampoline)", .stack_effect = "*unsafe-fn-ptr* --", .doc = "Call a native function via pointer. Internal use only.", .func = nativeTrampoline },
    .{ .name = "eval-string", .stack_effect = "string --", .doc = "Execute a string as 1z code in the caller's scope.", .func = nativeEvalString, .capability = .eval },
    .{ .name = "export", .stack_effect = "name --", .doc = "Promote an imported word to a public definition in the current scope.", .func = nativeExport },
    .{ .name = "compile!", .stack_effect = "sym --", .doc = "JIT-compile a word for integer arithmetic. Throws if the word is not found or not compilable.", .func = nativeCompile },
    .{ .name = "load-file", .stack_effect = "cache filename -- module", .doc = "Load a 1z source file unconditionally (no cache check) and store the result in the given M{} cache.", .func = nativeLoadFile, .capability = .io_fs },
    .{ .name = "module-cache-value", .stack_effect = "-- cache", .doc = "Push the current module cache M{} onto the stack.", .func = nativeModuleCacheValue },
};

const RegistryEntry = @import("types.zig").RegistryEntry;
pub const registry_entries = [_]RegistryEntry{
    .{ .name = "resolve-load-path", .func = nativeResolveLoadPath, .stack_effect = "filename -- resolved", .capability = .io_fs },
};

fn nativeToModule(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const ht_val = try ctx.stack.pop();
    const name = try popString(ctx);

    const entries: *std.StringHashMapUnmanaged(Value) = switch (ht_val) {
        .hash => |h| h,
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "hashtable", ht_val);
            return error.TypeMismatch;
        },
    };

    const module = try alloc.create(Module);
    module.* = .{
        .name = try alloc.dupe(u8, name),
        .words = .{},
    };

    // Capture imported words from the current local frames into the module's
    // deps so the module is self-contained. Without this, quotations stored
    // in the module that reference imported symbols (e.g., ffi-call from
    // use "ffi") would fail under tail-call optimization, because TCO pops
    // the calling module's deps frame before the callee executes.
    // Iterate outermost-first so innermost-scope entries take precedence.
    for (ctx.local_frames.items) |*frame| {
        var frame_iter = frame.iterator();
        while (frame_iter.next()) |entry| {
            const word_def = entry.value_ptr.*;
            if (word_def.imported) {
                try module.deps.put(alloc, entry.key_ptr.*, .{
                    .stack_effect = word_def.stack_effect,
                    .markers = word_def.markers,
                    .source_module = word_def.source_module,
                    .action = switch (word_def.action) {
                        .compound => |instrs| .{ .compound = instrs },
                        .native => |func| .{ .native = func },
                    },
                });
            }
        }
    }

    var iter = entries.iterator();
    while (iter.next()) |entry| {
        const val = entry.value_ptr.*;
        const quot = switch (val) {
            .quotation => |q| q,
            else => {
                const type_name = helpers.valueTypeName(val);
                const msg = std.fmt.allocPrint(alloc, ">module: value for key '{s}' must be a quotation, got {s}", .{ entry.key_ptr.*, type_name }) catch ">module: value must be a quotation";
                ctx.pending_error_message = msg;
                return error.TypeMismatch;
            },
        };
        try module.words.put(alloc, entry.key_ptr.*, .{
            .stack_effect = if (quot.effect) |eff| eff.* else null,
            .action = .{ .compound = quot.instructions },
        });
    }

    try ctx.stack.push(.{ .module = module });
}

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

/// resolve-load-path ( filename -- resolved ) - Resolve a filename to its canonical path
fn nativeResolveLoadPath(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const filename = try popString(ctx);
    const resolved = resolveLoadPath(ctx, filename, alloc) orelse {
        const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "file-not-found",
            .message = msg,
            .source = ctx.current_source,
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "resolve-load-path",
        }) catch {};
        return error.FileNotFound;
    };
    try ctx.stack.push(.{ .string = resolved });
}

fn nativeLoadImpl(ctx: *Context, cache: *value_mod.MutableMap, filename: []const u8, alloc: std.mem.Allocator, resolved: []const u8) anyerror!void {
    if (ctx.trace.trace_modules) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceModuleLoad(&tw, filename, resolved);
    }

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

    try ctx.pushPragmaFrame();
    errdefer ctx.popPragmaFrame();

    // XXX(ripta): Hack to set import target frame, which may execute inside
    //             combinator frames like `if`, instead of global or ephemeral
    //             frame. No rugrats for now.
    const old_import_frame = ctx.import_frame_index;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    defer ctx.import_frame_index = old_import_frame;

    const was_in_module_load = ctx.in_module_load;
    ctx.in_module_load = true;
    defer ctx.in_module_load = was_in_module_load;

    const saved_obligations = ctx.protocol_obligations;
    ctx.protocol_obligations = .{};
    defer {
        ctx.protocol_obligations.deinit(ctx.allocator);
        ctx.protocol_obligations = saved_obligations;
    }

    var processor: StatementProcessor = .{};
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                switch (processor.flush(alloc, ctx)) {
                    .needs_more_input => {},
                    .parse_error => |e| return e,
                    .complete => |instrs| {
                        if (instrs.len > 0 and (!ctx.check_mode or Context.isDefinitionStatement(instrs))) {
                            try ctx.executeQuotation(.{ .instructions = instrs });
                        }
                    },
                }
                break;
            },
            else => return error.FileReadFailed,
        };

        switch (processor.feedLine(alloc, line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| return err,
            .complete => |instrs| {
                if (instrs.len > 0 and (!ctx.check_mode or Context.isDefinitionStatement(instrs))) {
                    try ctx.executeQuotation(.{ .instructions = instrs });
                }
                processor.reset();
            },
        }
    }

    // Validate deferred protocol obligations before finalizing the module.
    // Only same-type methods are checked here; cross-type (any) obligations
    // remain runtime-only.
    try protocols.validateObligationsSameType(ctx);

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
            .source_module = word_def.source_module,
            .action = switch (word_def.action) {
                .compound => |instrs| .{ .compound = instrs },
                .native => |func| .{ .native = func },
            },
        };
        if (word_def.imported) {
            try module.deps.put(alloc, entry.key_ptr.*, mod_word);
        } else {
            try module.words.put(alloc, entry.key_ptr.*, mod_word);
            if (ctx.trace.trace_modules) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.traceModuleDefine(&tw, filename, entry.key_ptr.*, mod_word);
            }
        }
    }

    if (ctx.trace.trace_modules) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceModuleLoadEnd(&tw, filename, module.words.count());
    }

    cache.put(alloc, resolved, .{ .module = module }) catch {};
    ctx.popPragmaFrame();
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
        .capability = mod_word.capability,
        .action = switch (mod_word.action) {
            .compound => |instrs| .{ .compound = instrs },
            .native => |func| .{ .native = func },
        },
    });
    if (ctx.trace.trace_modules) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceModuleImport(&tw, ctx.current_source, name, module.name);
    }
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

fn nativeExport(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const name = switch (try ctx.stack.pop()) {
        .symbol, .string => |s| s,
        else => |v| {
            helpers.setTypeMismatchError(ctx, "string or symbol", v);
            return error.TypeMismatch;
        },
    };

    const idx = ctx.import_frame_index orelse unreachable;
    const frame = &ctx.local_frames.items[idx];

    const entry = frame.getPtr(name) orelse {
        const msg = std.fmt.allocPrint(alloc, "key '{s}'", .{name}) catch "key '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "key-not-found",
            .message = msg,
            .source = ctx.current_source,
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "export",
        }) catch {};
        return error.KeyNotFound;
    };

    entry.imported = false;
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

const ResolverState = struct {
    context: *Context,
};

fn hasQuotationParams(effect: @import("../stack_effect.zig").StackEffect) bool {
    for (effect.inputs) |param| {
        if (param.quotation_effect != null) return true;
    }
    return false;
}

fn resolveWordForDispatch(name: []const u8, user_data: *anyopaque) ?@import("../ir_codegen.zig").ResolvedWord {
    const ir_codegen = @import("../ir_codegen.zig");
    const stack_effect_mod = @import("../stack_effect.zig");
    const state: *ResolverState = @ptrCast(@alignCast(user_data));
    const ctx = state.context;
    const callee = ctx.lookupWord(name) orelse return null;

    const effect_ptr: ?usize = if (callee.stack_effect) |eff| blk: {
        if (hasQuotationParams(eff)) {
            const ptr = ctx.lookupWordStackEffectPtr(name) orelse break :blk @as(?usize, null);
            break :blk @intFromPtr(ptr);
        }
        break :blk null;
    } else null;

    switch (callee.action) {
        .compound => {},
        .native => |func| {
            const effect = callee.stack_effect orelse return null;
            if (stack_effect_mod.hasAnyRowVariable(effect)) return null;
            return ir_codegen.ResolvedWord{
                .word_id = 0,
                .input_count = @intCast(effect.inputs.len),
                .output_count = @intCast(effect.outputs.len),
                .native_fn_ptr = @intFromPtr(func),
                .stack_effect_ptr = effect_ptr,
            };
        },
    }

    const effect = callee.stack_effect orelse return null;

    const word_id = if (callee.word_id) |id| id else blk: {
        const id = ctx.jit_dispatch.assignId(name) catch return null;
        propagateWordId(ctx, name, id);
        break :blk id;
    };

    return ir_codegen.ResolvedWord{
        .word_id = word_id,
        .input_count = @intCast(effect.inputs.len),
        .output_count = @intCast(effect.outputs.len),
        .stack_effect_ptr = effect_ptr,
    };
}

/// compile! ( sym -- ) - JIT-compile a word for integer arithmetic
fn nativeCompile(ctx: *Context) anyerror!void {
    const ir_codegen = @import("../ir_codegen.zig");

    const sym = try helpers.popSymbol(ctx);
    const word = ctx.lookupWord(sym) orelse {
        ctx.pending_error_message = "compile!: word not found";
        return error.UnknownWord;
    };

    const instrs = switch (word.action) {
        .compound => |i| i,
        .native => {
            ctx.pending_error_message = "compile!: cannot compile native word";
            return error.TypeMismatch;
        },
    };

    const effect = word.stack_effect orelse {
        ctx.pending_error_message = "compile!: word has no stack effect annotation";
        return error.TypeMismatch;
    };

    const input_count: u8 = @intCast(effect.inputs.len);
    const output_count: u8 = @intCast(effect.outputs.len);

    const before_ns = if (ctx.benchmark != null) std.time.nanoTimestamp() else 0;

    // Build a resolver that maps word names to dispatch table IDs.
    // This does lazy word_id assignment: if the callee exists and has
    // a compound body, it gets a dispatch table slot (even if not yet compiled).
    var resolver_ctx = ResolverState{ .context = ctx };
    const resolver = ir_codegen.WordResolver{
        .resolve = &resolveWordForDispatch,
        .user_data = @ptrCast(&resolver_ctx),
        .dispatch_table_ptr = @ptrCast(&ctx.jit_dispatch),
    };

    const compiled = ir_codegen.compileWord(instrs, input_count, output_count, resolver, sym, ctx) catch {
        ctx.pending_error_message = "compile!: word is not compilable (must use only fixnum literals and integer arithmetic)";
        return error.TypeMismatch;
    };

    if (ctx.benchmark) |bm| {
        const after_ns = std.time.nanoTimestamp();
        bm.recordJitCompile(after_ns - before_ns);
    }

    const final_id = if (word.word_id) |existing_id| blk: {
        if (ctx.jit_dispatch.get(existing_id) != null) {
            ctx.jit_dispatch.update(existing_id, compiled.code_ptr, compiled.jit_buf);
            break :blk existing_id;
        }
        const new_id = ctx.jit_dispatch.assignId(sym) catch {
            compiled.jit_buf.deinit();
            return error.OutOfMemory;
        };
        ctx.jit_dispatch.update(new_id, compiled.code_ptr, compiled.jit_buf);
        propagateWordId(ctx, sym, new_id);
        break :blk new_id;
    } else blk: {
        const new_id = ctx.jit_dispatch.assignId(sym) catch {
            compiled.jit_buf.deinit();
            return error.OutOfMemory;
        };
        ctx.jit_dispatch.update(new_id, compiled.code_ptr, compiled.jit_buf);
        propagateWordId(ctx, sym, new_id);
        break :blk new_id;
    };
    if (ctx.trace.trace_jit) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceJitCompile(&tw, sym, final_id);
    }
}

/// Write word_id to whichever scope lookupWord would find the word in:
/// local frames (innermost first), then dictionary, then parent contexts.
fn propagateWordId(ctx: *Context, name: []const u8, word_id: u32) void {
    var i = ctx.local_frames.items.len;
    while (i > 0) {
        i -= 1;
        if (ctx.local_frames.items[i].getPtr(name)) |entry| {
            entry.word_id = word_id;
            return;
        }
    }
    if (ctx.dictionary.entries.getPtr(name)) |entry| {
        entry.word_id = word_id;
        return;
    }
    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        var j = anc.local_frames.items.len;
        while (j > 0) {
            j -= 1;
            if (anc.local_frames.items[j].getPtr(name)) |entry| {
                entry.word_id = word_id;
                return;
            }
        }
        if (anc.dictionary.entries.getPtr(name)) |entry| {
            entry.word_id = word_id;
            return;
        }
        ancestor = anc.parent_context;
    }
}

/// load-file ( cache filename -- module ) - Load a file unconditionally into the given cache
fn nativeLoadFile(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const filename = try popString(ctx);
    const cache_val = try ctx.stack.pop();
    const cache: *value_mod.MutableMap = switch (cache_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", cache_val);
            return error.TypeMismatch;
        },
    };

    const resolved = resolveLoadPath(ctx, filename, alloc) orelse {
        const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "file-not-found",
            .message = msg,
            .source = ctx.current_source,
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "load-file",
        }) catch {};
        return error.FileNotFound;
    };

    return nativeLoadImpl(ctx, cache, filename, alloc, resolved);
}

/// module-cache-value ( -- cache ) - Push the current module cache M{}
fn nativeModuleCacheValue(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
}

/// eval-string ( string -- ) - Execute a string as 1z code in the caller's scope
fn nativeEvalString(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const code = try popString(ctx);

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    var start: usize = 0;
    while (start < code.len) {
        const end = std.mem.indexOfScalarPos(u8, code, start, '\n') orelse code.len;
        const line = code[start..end];
        start = end + 1;

        switch (processor.feedLine(alloc, line, ctx)) {
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

    switch (processor.flush(alloc, ctx)) {
        .needs_more_input => {},
        .parse_error => |err| return err,
        .complete => |instrs| {
            if (instrs.len > 0) {
                try ctx.executeQuotation(.{ .instructions = instrs });
            }
        },
    }
}
