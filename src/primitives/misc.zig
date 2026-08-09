const std = @import("std");
const builtin = @import("builtin");
const is_freestanding = builtin.os.tag == .freestanding;
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;
const Instruction = value_mod.Instruction;
const StatementProcessor = @import("../statement.zig").StatementProcessor;
const parser_mod = @import("../parser.zig");

const markers_mod = @import("markers.zig");
const dispatch_helpers = @import("dispatch_helpers.zig");
const helpers = @import("helpers.zig");
const hooks = @import("hooks.zig");
const protocols = @import("protocols.zig");
const Primitive = @import("types.zig").Primitive;
const Capability = @import("types.zig").Capability;
const trace_mod = @import("../trace.zig");
const jit_dump = @import("../jit_dump.zig");
const call_graph_mod = @import("../call_graph.zig");
const ir_codegen = @import("../ir_codegen.zig");
const stack_effect_mod = @import("../stack_effect.zig");
const container_backing = @import("../container_backing.zig");
const dict_mod = @import("../dictionary.zig");
const embedded_stdlib = @import("../embedded_stdlib.zig");
const LoadLock = @import("../load_lock.zig").LoadLock;
const Task = @import("../task.zig").Task;
const TaskScope = @import("../task.zig").TaskScope;

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "import", .stack_effect = "module --", .doc = "Bring module words into the current scope.", .func = nativeImport },
    .{ .name = ">module", .stack_effect = "name hashtable -- module", .doc = "Convert a name string and a hashtable of quotations into a module value suitable for import.", .func = nativeToModule },
    .{ .name = "1array", .stack_effect = "elem -- array", .doc = "Wrap element in a single-element array.", .func = native1Array },
    .{ .name = "command-line-args", .stack_effect = "-- args", .doc = "Push program arguments as an array of strings.", .func = nativeCommandLineArgs, .capability = .system },
    .{ .name = "sys-exit", .stack_effect = "code --", .doc = "Exit the process with the given exit code.", .func = nativeSysExit, .capability = .system, .markers = &.{@constCast(&markers_mod.never_returns_marker)} },
    .{ .name = "add-load-path", .stack_effect = "path --", .doc = "Add a directory to the load path search list.", .func = nativeAddLoadPath },
    .{ .name = "eval-string", .stack_effect = "string --", .doc = "Execute a string as 1z code in the caller's scope.", .func = nativeEvalString, .capability = .eval, .markers = &.{ @constCast(&markers_mod.interpreter_dependent_marker), @constCast(&markers_mod.dynamic_eval_marker) } },
    .{ .name = "export", .stack_effect = "name --", .doc = "Promote an imported word to a public definition in the current scope.", .func = nativeExport },
    .{ .name = "compile!", .stack_effect = "sym --", .doc = "JIT-compile a word for integer arithmetic. Throws if the word is not found or not compilable.", .func = nativeCompile, .markers = &.{ @constCast(&markers_mod.interpreter_dependent_marker), @constCast(&markers_mod.dynamic_compile_marker) } },
    .{ .name = "load-file", .stack_effect = "cache filename -- module", .doc = "Load a 1z source file and store the result in the given M{} cache. An already-cached path returns the cached module without re-executing; use `reload-file` to re-execute. Loads serialize on the process-wide load lock, so any worker may load.", .func = nativeLoadFile, .capability = .io_fs, .markers = &.{ @constCast(&markers_mod.interpreter_dependent_marker), @constCast(&markers_mod.dynamic_load_marker) } },
    .{ .name = "reload-file", .stack_effect = "cache filename -- module", .doc = "Reload a 1z source file, pinned to its original source kind. Reuses the resolved path of an already-cached module instead of re-running the resolver chain, so a module first loaded from the embedded stdlib bundle reloads from the bundle even after a filesystem stdlib becomes available later in the session. Falls back to a fresh resolve when no cached entry exists.", .func = nativeReloadFile, .capability = .io_fs, .markers = &.{ @constCast(&markers_mod.interpreter_dependent_marker), @constCast(&markers_mod.dynamic_load_marker) } },
};

const RegistryEntry = @import("types.zig").RegistryEntry;
pub const registry_entries = [_]RegistryEntry{
    .{ .name = "resolve-load-path", .func = nativeResolveLoadPath, .stack_effect = "filename -- resolved", .capability = .io_fs },
    .{ .name = "module-cache-value", .func = nativeModuleCacheValue, .stack_effect = "-- cache" },
    .{ .name = "cached-module", .func = nativeCachedModule, .stack_effect = "cache resolved -- module/f" },
    .{ .name = "record-import", .func = nativeRecordImport, .stack_effect = "module-path words-or-f resolved-path --" },
    .{ .name = "import-history", .func = nativeImportHistory, .stack_effect = "-- array" },
    .{ .name = "parse-source-loc", .func = nativeParseSrcLoc, .stack_effect = "-- file line column" },
    .{ .name = "module-name", .func = nativeModuleName, .stack_effect = "module -- name" },
    .{ .name = "load-check-file", .func = nativeLoadCheckFile, .stack_effect = "cache filename -- module", .capability = .io_fs },
    .{ .name = "borrow-deps", .func = nativeBorrowDeps, .stack_effect = "source-module target --" },
};

fn nativeToModule(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const ht_val = try ctx.stack.pop();
    defer container_backing.releaseValue(ht_val);
    const name_str = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = name_str });
    const name = name_str.bytes;

    const entries: *std.StringHashMapUnmanaged(Value) = switch (ht_val) {
        .hash => |h| &h.map,
        .mutable_map => |m| &m.map,
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
                try module.deps.put(alloc, entry.key_ptr.*, try ctx.moduleWordFor(alloc, word_def));
            }
        }
    }

    var iter = entries.iterator();
    while (iter.next()) |entry| {
        const val = entry.value_ptr.*;
        const quot = (try helpers.asQuotationStamped(ctx, val)) orelse {
            const type_name = helpers.valueTypeName(val);
            const msg = std.fmt.allocPrint(alloc, ">module: value for key '{s}' must be a quotation, got {s}", .{ entry.key_ptr.*, type_name }) catch ">module: value must be a quotation";
            ctx.pending_error_message = msg;
            return error.TypeMismatch;
        };
        // The module outlives `ht_val`, so a closure body would dangle once the source
        // container drops its reference.
        if (val == .closure) {
            container_backing.retainValue(val);
            errdefer container_backing.releaseValue(val);
            try ctx.retainValueForTeardown(val);
        }
        // The module also outlives the source's keys; dupe each into the
        // module's allocator so freeing the source M{} (or its arena, for the
        // legacy hash variant) does not leave dangling key pointers in
        // `module.words`.
        const key_copy = try alloc.dupe(u8, entry.key_ptr.*);
        try module.words.put(alloc, key_copy, .{
            .stack_effect = if (quot.effect) |eff| eff.* else null,
            .action = .{ .compound = quot.instructions },
        });
    }

    try Context.buildModuleDepsTemplate(module, alloc);

    try ctx.stack.push(.{ .module = module });
}

/// True for a file path (`./`, `../`, `/` prefix, or a `.1z` suffix); otherwise the name is
/// treated as search-mode, including one containing `/` (e.g. "net/tcp"), which is what enables
/// hierarchical module resolution.
fn isPathMode(filename: []const u8) bool {
    return std.mem.startsWith(u8, filename, "./") or
        std.mem.startsWith(u8, filename, "../") or
        std.mem.startsWith(u8, filename, "/") or
        std.mem.endsWith(u8, filename, ".1z");
}

/// Resolve a file in a directory to its absolute path, or null if it doesn't exist.
fn resolveInDir(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    const joined = std.fs.path.join(alloc, &.{ dir, name }) catch return null;
    defer alloc.free(joined);

    const canonical = std.fs.cwd().realpathAlloc(alloc, joined) catch {
        return null;
    };
    return canonical;
}

/// Resolve a load path according to path mode vs search mode rules. Returns the resolved
/// absolute path, or null if not found.
pub fn resolveLoadPath(ctx: *Context, filename: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
    if (comptime is_freestanding) {
        // No filesystem on this target: path-mode names (./foo.1z, absolute paths) can never
        // resolve, so skip straight to the embedded stdlib bundle for search-mode names --
        // the only backing store this target has (build.zig requires -Dembed-stdlib=true here).
        if (isPathMode(filename)) return null;
        if (embedded_stdlib.findEntry(filename) != null) {
            return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
                embedded_stdlib.virtual_prefix, filename, embedded_stdlib.virtual_suffix,
            }) catch return null;
        }
        return null;
    }

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

    // Embedded stdlib fallback. Triggers only after every filesystem source has failed, and only
    // for search-mode names. Virtual paths are diagnostic-only. A path-mode lookup of the value
    // `"<stdlib>/strings.1z" load` keeps failing because path mode goes through realpath, which
    // doesn't know about the bundle.
    if (embedded_stdlib.findEntry(filename) != null) {
        return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
            embedded_stdlib.virtual_prefix, filename, embedded_stdlib.virtual_suffix,
        }) catch return null;
    }

    return null;
}

/// resolve-load-path ( filename -- resolved )
fn nativeResolveLoadPath(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const filename_str = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = filename_str });
    const filename = filename_str.bytes;
    const resolved = resolveLoadPath(ctx, filename, alloc) orelse {
        const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "file-not-found",
            .message = msg,
            .source = ctx.ownedCurrentSource(),
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "resolve-load-path",
        }) catch {};
        return error.FileNotFound;
    };
    try helpers.pushOwnedString(ctx, try ctx.allocator.dupe(u8, resolved));
}

/// Internal representation of a module source resolved by `load-file` et al.
///
/// A `.file` is backed by a filesystem path.
///
/// An `.embedded` is backed by an `@embedFile` byte slice. The virtual `<stdlib>/...` path used as
/// the cache key and in diagnostics.
pub const ResolvedModule = union(enum) {
    file: struct { path: []const u8 },
    embedded: struct { virtual_path: []const u8, source: []const u8 },

    pub fn resolvedPath(self: ResolvedModule) []const u8 {
        return switch (self) {
            .file => |f| f.path,
            .embedded => |e| e.virtual_path,
        };
    }
};

/// Classify a resolved path string into a `ResolvedModule`.
///
/// Returns `null` when the path has the `<stdlib>/<name>.1z` shape but no matching entry exists in
/// the embedded bundle, which the caller then surfaces as `file-not-found`.
///
/// Anything not matching the virtual shape is treated as a filesystem path.
pub fn classifyResolved(resolved: []const u8) ?ResolvedModule {
    if (embedded_stdlib.parseVirtualPath(resolved)) |name| {
        if (embedded_stdlib.findEntry(name)) |entry| {
            return .{ .embedded = .{ .virtual_path = resolved, .source = entry.source } };
        }
        return null;
    }
    return .{ .file = .{ .path = resolved } };
}

/// Map a resolved module to the source-kind label used by `--trace-module-source`.
pub fn moduleSourceKindOf(resolved_module: ResolvedModule) trace_mod.ModuleSourceKind {
    return switch (resolved_module) {
        .file => .filesystem,
        .embedded => .embedded,
    };
}

fn feedOneLine(
    ctx: *Context,
    alloc: std.mem.Allocator,
    processor: *StatementProcessor,
    line: []const u8,
    file_line: usize,
) anyerror!void {
    processor.trackLine(file_line);
    if (processor.start_line > 0) {
        ctx.parse_line_offset = processor.start_line - 1;
    }
    switch (processor.feedLine(alloc, line, ctx)) {
        .needs_more_input => {},
        .parse_error => |err| return parser_mod.raiseParseDiagnostics(ctx, err),
        .complete => |instrs| {
            if (instrs.len > 0 and (!ctx.check_mode or Context.isDefinitionStatement(instrs))) {
                try ctx.executeQuotation(.{ .instructions = instrs });
            }
            processor.reset();
        },
    }
}

fn flushProcessor(
    ctx: *Context,
    alloc: std.mem.Allocator,
    processor: *StatementProcessor,
) anyerror!void {
    switch (processor.flush(alloc, ctx)) {
        .needs_more_input => {},
        .parse_error => |e| return parser_mod.raiseParseDiagnostics(ctx, e),
        .complete => |instrs| {
            if (instrs.len > 0 and (!ctx.check_mode or Context.isDefinitionStatement(instrs))) {
                try ctx.executeQuotation(.{ .instructions = instrs });
            }
        },
    }
}

/// Parse, execute, and cache a resolved module source.
///
/// `filename` is the user-facing string used as `ctx.current_source` for the duration of the
/// load and recorded in import history; `resolved_module` carries the dispatch.
///
/// - A `.file` reads source lines from disk through a buffered reader and sets `ctx.current_source_dir`
///   to the file's parent so relative `use` statements work.
/// - An `.embedded` iterates the in-memory byte slice and clears `current_source_dir` so relative
///   imports out of the bundle are filesystem-only.
///
/// The cache is keyed by the resolved path: either the canonical filesystem path, or the virtual
/// `<stdlib>/...` path -- and is only written on first load. Existing entries are left untouched.
///
/// This word pushes the constructed module onto the stack on success.
pub fn nativeLoadImpl(ctx: *Context, cache: *value_mod.MutableMap, filename: []const u8, alloc: std.mem.Allocator, resolved_module: ResolvedModule) anyerror!void {
    const resolved = resolved_module.resolvedPath();

    if (ctx.trace.trace_modules.lifecycle) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceModuleLoad(&tw, filename, resolved);
    }

    if (ctx.trace.trace_modules.source) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceModuleSourceLoad(&tw, moduleSourceKindOf(resolved_module), filename, resolved);
    }

    var file_handle: ?std.fs.File = null;
    // file_handle is never non-null on freestanding (the .file arm below never runs there), but
    // this is a runtime optional check, so it's comptime-elided too: std.fs.File.close forces
    // std.posix.close to compile, which this target's non-libc posix stub does not provide.
    defer if (comptime !is_freestanding) {
        if (file_handle) |f| f.close();
    };
    switch (resolved_module) {
        .file => |f| {
            // resolveLoadPath never resolves a .file path on this target (no filesystem), so
            // this arm is unreachable there; comptime-elided so std.fs.cwd() need not compile.
            if (comptime is_freestanding) unreachable;
            file_handle = std.fs.cwd().openFile(f.path, .{}) catch {
                const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
                ctx.error_details.append(ctx.allocator, .{
                    .error_type = "file-not-found",
                    .message = msg,
                    .source = ctx.ownedCurrentSource(),
                    .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
                    .word_name = "load",
                }) catch {};
                return error.FileNotFound;
            };
        },
        .embedded => {},
    }

    const old_source = ctx.current_source;
    ctx.current_source = filename;
    defer ctx.current_source = old_source;

    const old_load_file_source = ctx.load_file_source;
    ctx.load_file_source = filename;
    defer ctx.load_file_source = old_load_file_source;

    // Save/restore current_source_dir around file execution. Embedded
    // modules have no meaningful base directory; relative-path imports
    // out of an embedded module remain filesystem-only.
    const old_source_dir = ctx.current_source_dir;
    ctx.current_source_dir = switch (resolved_module) {
        .file => |f| std.fs.path.dirname(f.path),
        .embedded => null,
    };
    defer ctx.current_source_dir = old_source_dir;

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

    // Create the module before executing the file body so method registrations
    // running during the body (via the `;` finalizer calling define-method) can
    // record their defining module. Its words/deps are filled from the frame
    // after the body completes; the pointer is stable across that fill because
    // modules are arena-allocated.
    const module = try alloc.create(Module);
    module.* = .{
        .name = try alloc.dupe(u8, filename),
        .words = .{},
    };

    const old_loading_module = ctx.loading_module;
    ctx.loading_module = module;
    defer ctx.loading_module = old_loading_module;

    const saved_obligations = ctx.protocol_obligations;
    ctx.protocol_obligations = .{};
    defer {
        ctx.protocol_obligations.deinit(ctx.allocator);
        ctx.protocol_obligations = saved_obligations;
    }

    const old_line_offset = ctx.parse_line_offset;
    defer ctx.parse_line_offset = old_line_offset;

    var processor: StatementProcessor = .{};
    switch (resolved_module) {
        .file => {
            if (comptime is_freestanding) unreachable;
            var file_buf: [4096]u8 = undefined;
            var reader = file_handle.?.reader(&file_buf);
            var file_line: usize = 0;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                    error.EndOfStream => {
                        try flushProcessor(ctx, alloc, &processor);
                        break;
                    },
                    else => return error.FileReadFailed,
                };

                file_line += 1;
                try feedOneLine(ctx, alloc, &processor, line, file_line);
            }
        },
        .embedded => |e| {
            var lines = std.mem.splitScalar(u8, e.source, '\n');
            var file_line: usize = 0;
            while (lines.next()) |line| {
                file_line += 1;
                try feedOneLine(ctx, alloc, &processor, line, file_line);
            }
            try flushProcessor(ctx, alloc, &processor);
        },
    }

    // Validate deferred protocol obligations before finalizing the module.
    // Only same-type methods are checked here; cross-type (any) obligations
    // remain runtime-only.
    try protocols.validateObligationsSameType(ctx);

    // Capture definitions from the frame before popping
    const frame_index = ctx.local_frames.items.len - 1;
    const frame = &ctx.local_frames.items[frame_index];

    // Copy definitions from frame to module.
    // Both compound and native words are captured. Native words occur in
    // loaded files when struct/virtual/enum definitions generate native
    // accessors and constructors via the native function registry.
    var iter = frame.iterator();
    while (iter.next()) |entry| {
        const word_def = entry.value_ptr.*;
        const mod_word = try ctx.moduleWordFor(alloc, word_def);
        if (word_def.imported) {
            try module.deps.put(alloc, entry.key_ptr.*, mod_word);

            // A module's own private helpers (defined via `private{ }`) are imported as
            // `<local-scope>` words. Stamp their bodies with this module so their nested
            // branch/loop quotations inherit its defining module and the `.module_deps` visibility
            // filter admits its frame -- where the helper's siblings and imports live. Genuine
            // cross-module imports carry a real origin module and keep their own stamp; do not
            // re-stamp them here.
            if (word_def.source_module) |sm| {
                if (@import("../context.zig").isSyntheticScopeModule(sm)) {
                    switch (word_def.action) {
                        .compound => |instrs| try ctx.stampQuotationBodies(instrs, module),
                        .literal => |v| try ctx.stampValueQuotations(v, module),
                        else => {},
                    }
                }
            }
        } else {
            try module.words.put(alloc, entry.key_ptr.*, mod_word);
            switch (word_def.action) {
                .compound => |instrs| try ctx.stampQuotationBodies(instrs, module),
                .literal => |v| try ctx.stampValueQuotations(v, module),
                else => {},
            }
            if (ctx.trace.trace_modules.define) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.traceModuleDefine(&tw, filename, entry.key_ptr.*, mod_word);
            }
        }
    }

    if (ctx.trace.trace_modules.lifecycle) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceModuleLoadEnd(&tw, filename, module.words.count());
    }

    // Pre-build the deps-and-words frame template now that the module is fully
    // populated. `alloc` is the module's own arena, so the template lives and
    // dies with it.
    try Context.buildModuleDepsTemplate(module, alloc);

    // Only insert if the resolved path is not already in the cache; an overwrite would silently
    // drop the fresh key dupe. The header mutex excludes the resolution scans and cache probes
    // running on other workers.
    cache.header.lock();
    if (!cache.map.contains(resolved)) {
        if (cache.header.allocator.dupe(u8, resolved)) |resolved_owned| {
            cache.map.put(cache.header.allocator, resolved_owned, .{ .module = module }) catch {
                cache.header.allocator.free(resolved_owned);
            };
        } else |_| {}
    }
    cache.header.unlock();
    ctx.popPragmaFrame();
    ctx.popLocalFrame();
    hooks.fireScopedHooks(ctx, "module-loaded-hooks", &.{ value_mod.stringValue(filename), value_mod.stringValue(resolved) });
    try ctx.stack.push(.{ .module = module });
}

pub fn importWord(ctx: *Context, name: []const u8, mod_word: ModuleWord, module: *const Module) !void {
    const has_parse_time = for (mod_word.markers) |mk| {
        if (markers_mod.isParseTimeMarker(mk)) break true;
    } else false;

    // When importing a generic word that already exists in scope as generic,
    // merge dispatch entries under the existing word's dispatch_id so that
    // cross-module field accessors (e.g., y>> from two struct-defining
    // modules) all dispatch through a single word.
    const incoming_generic = for (mod_word.markers) |mk| {
        if (markers_mod.isGenericMarker(mk)) break true;
    } else false;

    var effective_dispatch_id = mod_word.dispatch_id;
    if (incoming_generic) {
        if (ctx.lookupWord(name)) |existing| {
            const existing_generic = for (existing.markers) |mk| {
                if (markers_mod.isGenericMarker(mk)) break true;
            } else false;
            if (existing_generic and existing.dispatch_id != mod_word.dispatch_id) {
                try mergeDispatchEntries(ctx, mod_word.dispatch_id, existing.dispatch_id);
                effective_dispatch_id = existing.dispatch_id;
            }
        }
    }

    try ctx.defineImportedWord(name, .{
        .name = name,
        .parse_time = has_parse_time,
        .imported = true,
        .stack_effect = mod_word.stack_effect,
        .markers = mod_word.markers,
        // A word the module being imported had itself imported (e.g. via
        // `reexport`) already carries its originating module, which is where
        // its body's late-bound dep references resolve. Preserve it; only a
        // word the module defines itself (source_module null) is anchored to
        // the module now being imported. Mirrors the `orelse module` pattern
        // in pushModuleDepsFrame and wordDefFromModuleWord.
        .source_module = mod_word.source_module orelse module,
        .source_file = mod_word.source_file,
        .source_line = mod_word.source_line,
        .source_column = mod_word.source_column,
        .provenance = mod_word.provenance,
        .capability = mod_word.capability,
        .dispatch_id = effective_dispatch_id,
        // An image-loaded module word carries its per-(module, word) compiled id.
        // After a generic dispatch-merge the compiled body would still consult its
        // baked pre-merge dispatch table and miss merged methods, so the merged
        // case stays interpreted.
        .word_id = if (effective_dispatch_id == mod_word.dispatch_id) mod_word.word_id else null,
        .action = switch (mod_word.action) {
            .compound => |instrs| .{ .compound = instrs },
            .native => |func| .{ .native = func },
            .host_callback => |host| .{ .host_callback = host },
        },
    });
    if (ctx.trace.trace_modules.import) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceModuleImport(&tw, ctx.current_source, name, module.name);
    }
}

/// Copy all dispatch entries from one dispatch_id to another, allowing
/// overwrites for entries that already exist under the target ID.
fn mergeDispatchEntries(ctx: *Context, from_id: u32, to_id: u32) !void {
    const dispatch_mod = @import("../dispatch.zig");
    const pairs = try ctx.dispatch.entriesForDispatchId(from_id, ctx.allocator);
    defer ctx.allocator.free(pairs);
    for (pairs) |pair| {
        const new_key = dispatch_mod.DispatchKey{
            .dispatch_id = to_id,
            .type_a = pair.key.type_a,
            .type_b = pair.key.type_b,
        };
        try ctx.registerDispatch(new_key, pair.entry, true);
    }
}

fn addImportError(ctx: *Context, error_type: []const u8, message: []const u8) void {
    addNamedImportError(ctx, error_type, message, "import");
}

fn addNamedImportError(ctx: *Context, error_type: []const u8, message: []const u8, word_name: []const u8) void {
    ctx.error_details.append(ctx.allocator, .{
        .error_type = error_type,
        .message = message,
        .source = ctx.ownedCurrentSource(),
        .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
        .word_name = word_name,
    }) catch {};
}

fn nativeImport(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const top_val = try ctx.stack.pop();
    defer container_backing.releaseValue(top_val);

    switch (top_val) {
        .array => |names_arr| {
            const names = names_arr.items;
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
                // Imported bindings keep the name as a frame key for the context's lifetime.
                const name = switch (name_val) {
                    .symbol, .string => |s| try alloc.dupe(u8, s.bytes),
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
    const name_val = try ctx.stack.pop();
    defer container_backing.releaseValue(name_val);
    const name = switch (name_val) {
        .symbol, .string => |s| s.bytes,
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
            .source = ctx.ownedCurrentSource(),
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "export",
        }) catch {};
        return error.KeyNotFound;
    };

    entry.imported = false;
}

/// borrow-deps ( source-module target -- )
///
/// Imports a module's private `deps` words -- the low-level piece `borrow` and the test runner
/// share, since `import` exposes only `module.words`. A `f` target imports all of `source`'s deps
/// into the live frame; an array target imports a validated named subset; a module target mutates
/// an already-finalized module in place and rebuilds its `deps_template`.
///
/// The module-target arm is the only in-place mutator of a finalized, templated module, following
/// the deps-template escape documented on `buildModuleDepsTemplate`. It is restricted to the
/// primary worker because a cached module's deps map and template are owned by that worker's arena.
fn nativeBorrowDeps(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const target_val = try ctx.stack.pop();
    defer container_backing.releaseValue(target_val);

    const source = helpers.popModule(ctx) catch {
        addNamedImportError(ctx, "type-mismatch", "expected source module, got non-module", "borrow-deps");
        return error.TypeMismatch;
    };
    if (!source.importable) {
        const msg = std.fmt.allocPrint(alloc, "module '{s}' cannot be imported", .{source.name}) catch "module cannot be imported";
        addNamedImportError(ctx, "import-error", msg, "borrow-deps");
        return error.EmptyImport;
    }

    switch (target_val) {
        .boolean => |b| {
            if (b) {
                addNamedImportError(ctx, "type-mismatch", "borrow-deps target must be a module, an array, or f", "borrow-deps");
                return error.TypeMismatch;
            }
            var iter = source.deps.iterator();
            while (iter.next()) |entry| {
                try importWord(ctx, entry.key_ptr.*, entry.value_ptr.*, source);
            }
        },
        .array => |names_arr| {
            for (names_arr.items) |name_val| {
                // The imported binding keeps the name as a frame key, which outlives the
                // released target array.
                const name = switch (name_val) {
                    .symbol, .string => |s| try alloc.dupe(u8, s.bytes),
                    else => {
                        const type_name = helpers.valueTypeName(name_val);
                        const msg = std.fmt.allocPrint(alloc, "expected symbol, got {s}", .{type_name}) catch "expected symbol";
                        addNamedImportError(ctx, "type-mismatch", msg, "borrow-deps");
                        return error.TypeMismatch;
                    },
                };
                const dep_word = source.deps.get(name) orelse {
                    const msg = std.fmt.allocPrint(alloc, "module '{s}' has no private dep '{s}'", .{ source.name, name }) catch "unknown private dep";
                    addNamedImportError(ctx, "import-error", msg, "borrow-deps");
                    return error.KeyNotFound;
                };
                try importWord(ctx, name, dep_word, source);
            }
        },
        .module => |target| {
            if (ctx.scheduler) |sched| {
                if (sched.isBackgroundWorker()) {
                    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                        .error_type = "non-primary-worker",
                        .message = "borrow-deps cannot mutate a finalized module from a non-primary worker",
                    });
                    return error.UserThrown;
                }
            }

            // Copy the ModuleWords verbatim rather than routing through `importWord`, which defines
            // into the live import frame and merges generic dispatch. A finalized module has no
            // frame. `source.deps` may carry generic imports, so a same-named target generic under a
            // different dispatch_id is clobbered rather than merged; the shadow check the `borrow`
            // word and the runner compose governs that collision, so the raw injection stays simple.
            var iter = source.deps.iterator();
            while (iter.next()) |entry| {
                try target.deps.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
            }
            try Context.buildModuleDepsTemplate(target, alloc);
        },
        else => {
            const type_name = helpers.valueTypeName(target_val);
            const msg = std.fmt.allocPrint(alloc, "expected module, array, or f, got {s}", .{type_name}) catch "expected module, array, or f";
            addNamedImportError(ctx, "type-mismatch", msg, "borrow-deps");
            return error.TypeMismatch;
        },
    }
}

/// command-line-args ( -- args )
fn nativeCommandLineArgs(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const args = ctx.program_args;

    const arr = alloc.alloc(Value, args.len) catch return error.OutOfMemory;
    for (args, 0..) |arg, i| {
        arr[i] = value_mod.stringValue(arg);
    }

    try helpers.pushAdoptedArray(ctx, alloc, arr);
}

/// sys-exit ( code -- )
fn nativeSysExit(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "sys-exit");

    const code = try helpers.popFixnum(ctx);
    hooks.fireHooks(ctx, "on:exit", &.{.{ .fixnum = code }});
    std.process.exit(@intCast(code));
}

/// add-load-path ( path -- )
fn nativeAddLoadPath(ctx: *Context) anyerror!void {
    const path_str = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = path_str });
    const duped = ctx.quotationAllocator().dupe(u8, path_str.bytes) catch return error.OutOfMemory;
    ctx.load_paths.append(ctx.allocator, duped) catch return error.OutOfMemory;
}

/// 1array ( elem -- array )
fn native1Array(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const arr = alloc.alloc(Value, 1) catch return error.OutOfMemory;
    arr[0] = elem;

    // `elem` was moved into the array slot, which already owns its reference;
    // the fresh array adopts it and transfers to the stack without re-retaining.
    try helpers.pushAdoptedArray(ctx, alloc, arr);
}

const ResolverState = struct {
    context: *Context,
};

fn hasQuotationParams(effect: stack_effect_mod.StackEffect) bool {
    for (effect.inputs) |param| {
        if (param.quotation_effect != null) return true;
    }
    return false;
}

fn hasNeverReturnsMarker(word_markers: []const *const value_mod.Marker) bool {
    for (word_markers) |mk| {
        if (markers_mod.isNeverReturnsMarker(mk)) return true;
    }
    return false;
}

fn resolveWordForDispatch(name: []const u8, user_data: *anyopaque) ?ir_codegen.ResolvedWord {
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

    // The outputs slice points into dictionary-owned storage, so the by-value effect copy is safe.
    const output_params: ?[]const stack_effect_mod.StackEffectParam =
        if (callee.stack_effect) |eff| eff.outputs else null;
    const input_params: ?[]const stack_effect_mod.StackEffectParam =
        if (callee.stack_effect) |eff| eff.inputs else null;

    switch (callee.action) {
        // A literal has no instruction body (`ResolvedWord.body` stays null),
        // so it resolves exactly like a bodiless compound word from this
        // point on.
        .compound, .literal => {},
        .native => |func| {
            const effect = callee.stack_effect orelse return null;
            if (stack_effect_mod.hasAnyRowVariable(effect)) return null;
            return ir_codegen.ResolvedWord{
                .word_id = 0,
                .input_count = @intCast(effect.inputs.len),
                .output_count = @intCast(effect.outputs.len),
                .is_native = true,
                .native_fn_ptr = @intFromPtr(func),
                .stack_effect_ptr = effect_ptr,
                .never_returns = hasNeverReturnsMarker(callee.markers),
                .dispatch_id = callee.dispatch_id,
                .output_params = output_params,
                .input_params = input_params,
            };
        },
        .host_callback => return null,
    }

    const effect = callee.stack_effect orelse return null;

    const word_id = if (callee.word_id) |id| id else blk: {
        const id = ctx.jit_dispatch.assignId(name) catch return null;
        propagateWordId(ctx, name, id);
        break :blk id;
    };

    const bounded = dispatch_helpers.boundedDispatchFor(&effect, callee.markers, name);

    return ir_codegen.ResolvedWord{
        .word_id = word_id,
        .input_count = @intCast(effect.inputs.len),
        .output_count = @intCast(effect.outputs.len),
        .stack_effect_ptr = effect_ptr,
        .never_returns = hasNeverReturnsMarker(callee.markers),
        .dispatch_id = callee.dispatch_id,
        .bounded_constraint = if (bounded) |b| b.constraint else null,
        .bounded_arity = if (bounded) |b| b.arity else .unary,
        .bounded_trace_name = if (bounded) |b| ctx.boundedConstraintTraceName(b.constraint) else null,
        .output_params = output_params,
        .input_params = input_params,
        .body = if (callee.action == .compound) callee.action.compound else null,
    };
}

/// compile! ( sym -- )
fn nativeCompile(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "compile!");

    const sym_pay = try helpers.popSymbol(ctx);
    defer container_backing.releaseValue(.{ .symbol = sym_pay });
    // The JIT dispatch table stores the word name it is handed.
    const sym = try ctx.quotationAllocator().dupe(u8, sym_pay.bytes);
    const word = ctx.lookupWord(sym) orelse {
        ctx.pending_error_message = "compile!: word not found";
        return error.UnknownWord;
    };

    switch (word.action) {
        .compound => {},
        .native, .host_callback, .literal => {
            ctx.pending_error_message = "compile!: cannot compile native word";
            return error.TypeMismatch;
        },
    }

    if (word.stack_effect == null) {
        ctx.pending_error_message = "compile!: word has no stack effect annotation";
        return error.TypeMismatch;
    }

    // Check for mutual recursion group membership
    const mutual_group = detectMutualGroup(ctx, sym, call_graph_mod);
    if (mutual_group) |members| {
        defer ctx.allocator.free(members);

        // Pre-assign word_ids for all group members so they are stable
        for (members) |member_name| {
            const member_word = ctx.lookupWord(member_name) orelse continue;
            if (member_word.word_id == null) {
                const id = ctx.jit_dispatch.assignId(member_name) catch continue;
                propagateWordId(ctx, member_name, id);
            }
        }

        // Compile all group members with trampoline support
        var all_ok = true;
        for (members) |member_name| {
            compileSingleWord(ctx, member_name, members) catch {
                all_ok = false;
                break;
            };
        }

        if (all_ok) return;

        // If any member failed, fall back to compiling just the requested word
        // without trampoline support
    }

    compileSingleWord(ctx, sym, null) catch {
        ctx.pending_error_message = "compile!: word is not compilable (must use only fixnum literals and integer arithmetic)";
        return error.TypeMismatch;
    };
}

/// Detect mutual recursion groups by scanning word bodies via lookupWord.
/// Builds a local call graph over all reachable words from `sym`, then
/// runs SCC detection and eligibility filtering.
fn detectMutualGroup(ctx: *Context, sym: []const u8, call_graph_ns: anytype) ?[]const []const u8 {
    // Build a mini call graph by walking reachable words from `sym`.
    // Use lookupWord so we find words in local frames, not just the dictionary.
    var graph: call_graph_ns.CallGraph = .{};
    defer {
        var iter = graph.iterator();
        while (iter.next()) |entry| {
            const callees = entry.value_ptr.callees;
            if (callees.len > 0) ctx.allocator.free(callees);
        }
        graph.deinit(ctx.allocator);
    }

    // BFS from sym to discover reachable words
    var queue = std.ArrayListUnmanaged([]const u8){};
    defer queue.deinit(ctx.allocator);
    queue.append(ctx.allocator, sym) catch return null;

    while (queue.items.len > 0) {
        const name = queue.orderedRemove(0);
        if (graph.contains(name)) continue;

        const word_def = ctx.lookupWord(name) orelse continue;
        const instrs = switch (word_def.action) {
            .compound => |i| i,
            .native, .host_callback, .literal => {
                graph.put(ctx.allocator, name, .{ .callees = &.{}, .has_opaque = false }) catch return null;
                continue;
            },
        };

        var callee_set: std.StringHashMapUnmanaged(void) = .{};
        defer callee_set.deinit(ctx.allocator);
        var has_opaque = false;
        call_graph_ns.collectCalleesPublic(instrs, &callee_set, &has_opaque, ctx.allocator) catch return null;

        const callees = sortedKeysFromSet(callee_set, ctx.allocator) catch return null;
        graph.put(ctx.allocator, name, .{ .callees = callees, .has_opaque = has_opaque }) catch return null;

        for (callees) |callee| {
            if (!graph.contains(callee)) {
                queue.append(ctx.allocator, callee) catch return null;
            }
        }
    }

    // Find SCCs and eligible mutual TCO groups
    const sccs = call_graph_ns.findSCCs(&graph, ctx.allocator) catch return null;
    defer {
        for (sccs) |members| ctx.allocator.free(members);
        ctx.allocator.free(sccs);
    }

    for (sccs) |scc| {
        // Check if sym is in this SCC
        var has_sym = false;
        for (scc) |member| {
            if (std.mem.eql(u8, member, sym)) {
                has_sym = true;
                break;
            }
        }
        if (!has_sym) continue;

        // Verify eligibility using lookupWord
        if (isSccEligibleViaLookup(ctx, scc, &graph, call_graph_ns, stack_effect_mod)) {
            return ctx.allocator.dupe([]const u8, scc) catch return null;
        }
    }

    return null;
}

fn sortedKeysFromSet(set: std.StringHashMapUnmanaged(void), allocator: std.mem.Allocator) ![]const []const u8 {
    const count = set.count();
    if (count == 0) return &.{};
    const result = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    var iter = set.iterator();
    while (iter.next()) |entry| {
        result[i] = entry.key_ptr.*;
        i += 1;
    }
    std.mem.sort([]const u8, result, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return result;
}

fn isSccEligibleViaLookup(
    ctx: *Context,
    scc: []const []const u8,
    graph: *const call_graph_mod.CallGraph,
    call_graph_ns: anytype,
    stack_effect_ns: anytype,
) bool {
    var member_set: std.StringHashMapUnmanaged(void) = .{};
    defer member_set.deinit(ctx.allocator);
    for (scc) |name| {
        member_set.put(ctx.allocator, name, {}) catch return false;
    }

    var ref_inputs: ?usize = null;
    var ref_outputs: ?usize = null;

    for (scc) |name| {
        const word_def = ctx.lookupWord(name) orelse return false;

        // Must be compilable
        const instrs = switch (word_def.action) {
            .compound => |i| i,
            .native, .host_callback, .literal => return false,
        };
        _ = instrs;

        const effect = word_def.stack_effect orelse return false;
        for (word_def.markers) |mk| {
            if (markers_mod.isParseTimeOnlyMarker(mk)) return false;
            if (markers_mod.isParseTimeMarker(mk)) return false;
            if (markers_mod.isGenericMarker(mk)) return false;
        }
        if (stack_effect_ns.hasAnyRowVariable(effect)) return false;

        // Arity uniformity
        if (ref_inputs) |ri| {
            if (effect.inputs.len != ri or effect.outputs.len != ref_outputs.?) return false;
        } else {
            ref_inputs = effect.inputs.len;
            ref_outputs = effect.outputs.len;
        }

        // No opaque calls
        const graph_entry = graph.get(name) orelse return false;
        if (graph_entry.has_opaque) return false;

        // Every inter-member edge must be a tail call
        const word_instrs = switch (word_def.action) {
            .compound => |i| i,
            .native, .host_callback, .literal => return false,
        };
        for (graph_entry.callees) |callee| {
            if (member_set.contains(callee)) {
                if (!call_graph_ns.hasTailCallTo(word_instrs, callee)) return false;
            }
        }
    }

    return true;
}

fn compileSingleWord(ctx: *Context, sym: []const u8, mutual_group: ?[]const []const u8) !void {
    const word = ctx.lookupWord(sym) orelse return error.UnknownWord;

    const instrs = switch (word.action) {
        .compound => |i| i,
        .native, .host_callback, .literal => return error.TypeMismatch,
    };

    const effect = word.stack_effect orelse return error.TypeMismatch;

    const input_count: u8 = @intCast(effect.inputs.len);
    const output_count: u8 = @intCast(effect.outputs.len);

    const before_ns = if (ctx.benchmark != null) std.time.nanoTimestamp() else 0;

    var resolver_ctx = ResolverState{ .context = ctx };
    const resolver = ir_codegen.WordResolver{
        .resolve = &resolveWordForDispatch,
        .user_data = @ptrCast(&resolver_ctx),
        .dispatch_table_ptr = @ptrCast(&ctx.jit_dispatch),
    };

    const pic_snapshot = ctx.clonePicSnapshotForInstructions(instrs);
    errdefer if (pic_snapshot) |ps| {
        ps.deinit();
        ctx.allocator.destroy(ps);
    };

    const compiled = ir_codegen.compileWordWithPicSnapshot(instrs, input_count, output_count, resolver, sym, pic_snapshot, ctx, mutual_group, &effect) catch {
        return error.TypeMismatch;
    };

    if (ctx.benchmark) |bm| {
        const after_ns = std.time.nanoTimestamp();
        bm.recordJitCompile(after_ns - before_ns);
    }

    const final_id = if (word.word_id) |existing_id| blk: {
        if (ctx.jit_dispatch.get(existing_id) != null) {
            ctx.jit_dispatch.update(existing_id, compiled.code_ptr, compiled.jit_buf, compiled.peak_stack_depth);
            break :blk existing_id;
        }
        const new_id = ctx.jit_dispatch.assignId(sym) catch {
            compiled.jit_buf.deinit();
            return error.OutOfMemory;
        };
        ctx.jit_dispatch.update(new_id, compiled.code_ptr, compiled.jit_buf, compiled.peak_stack_depth);
        propagateWordId(ctx, sym, new_id);
        break :blk new_id;
    } else blk: {
        const new_id = ctx.jit_dispatch.assignId(sym) catch {
            compiled.jit_buf.deinit();
            return error.OutOfMemory;
        };
        ctx.jit_dispatch.update(new_id, compiled.code_ptr, compiled.jit_buf, compiled.peak_stack_depth);
        propagateWordId(ctx, sym, new_id);
        break :blk new_id;
    };
    ctx.jit_dispatch.replacePicSnapshot(final_id, pic_snapshot);
    if (ctx.trace.trace_jit) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceJitCompile(&tw, sym, final_id);
    }

    const dump_cfg = jit_dump.DumpConfig{ .dump_bytes = ctx.trace.dump_jit_bytes, .bin_dir = ctx.trace.dump_jit_bin_dir };
    if (dump_cfg.enabled() and trace_mod.matchesPattern(sym, ctx.trace.dump_jit_word_pattern))
        jit_dump.dumpJitCode(dump_cfg, sym, final_id, compiled.code_ptr, compiled.jit_buf.size);
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
    if (ctx.dictionary.entries.get(name)) |slot| {
        dict_mod.loadSlot(slot).word_id = word_id;
        return;
    }
    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        // Match `lookupWordLocked`'s bounded ancestor walk: a descendant only
        // resolves an ancestor's stable scope (import frame and below), so back-
        // writing a word_id into an ancestor's transient frame would land where
        // resolution never looks.
        const anc_cap = if (anc.import_frame_index) |idx| idx + 1 else 0;
        var j = anc_cap;
        while (j > 0) {
            j -= 1;
            if (anc.local_frames.items[j].getPtr(name)) |entry| {
                entry.word_id = word_id;
                return;
            }
        }
        if (anc.dictionary.entries.get(name)) |slot| {
            dict_mod.loadSlot(slot).word_id = word_id;
            return;
        }
        ancestor = anc.parent_context;
    }
}

/// The current execution's load-lock identity: the running task, or the main sentinel for
/// the non-task main thread.
fn loadLockOwner(ctx: *Context) LoadLock.Owner {
    if (ctx.scheduler) |sched| {
        if (sched.current_task) |task| return .{ .task = task };
    }
    return .main;
}

/// Acquire the process-wide load lock, serializing this load against every other.
///
/// A nested `use` on the same task passes through the reentrant depth. A contending task
/// whose holder transitively awaits it borrows the hold instead, per `holderAwaitsTask`.
/// Otherwise the contender is queued once and suspended through the scheduler until a
/// release hands it ownership; a spurious wake parks it again without re-queueing.
///
/// Raises a `load-parse-wait` user error for a contended acquire that cannot park, which is
/// any parse-time acquire outside the delegation case.
///
/// A task cancelled while waiting never returns holding the lock. A handoff that raced the
/// cancellation is released, and a still-queued waiter is removed, before the cancellation
/// propagates.
fn acquireLoadLock(ctx: *Context) anyerror!void {
    const lock = ctx.load_lock;
    switch (loadLockOwner(ctx)) {
        .main => lock.acquireMain(),
        .task => |task| try acquireLoadLockAsTask(ctx, lock, task),
    }
}

/// Whether `holder` cannot resume until `contender` finishes, so parking the contender on
/// the holder's lock would deadlock.
///
/// Main qualifies whenever a task is alive at all: 1z code on the main thread and running
/// tasks are mutually exclusive except while main is parked in a scope's run loop, and every
/// live task is under that scope. A task holder qualifies when walking the contender's
/// scope, its waiting task, that task's scope, and so on reaches it.
///
/// The walk reads waiter fields without locks. Each is set before its task parks, and a
/// chain that reaches the holder cannot unwind while the contender is still running, so a
/// true result is stable for as long as the caller needs it.
fn holderAwaitsTask(holder: LoadLock.Owner, contender: *Task) bool {
    const holder_task = switch (holder) {
        .main => return true,
        .task => |t| t,
    };
    var scope: ?*TaskScope = contender.scope;
    while (scope) |s| {
        const waiter = s.waiting_task orelse return false;
        if (waiter == holder_task) return true;
        scope = waiter.scope;
    }
    return false;
}

fn acquireLoadLockAsTask(ctx: *Context, lock: *LoadLock, task: *Task) anyerror!void {
    const sched = ctx.scheduler.?;
    const owner: LoadLock.Owner = .{ .task = task };
    while (true) {
        const holder = lock.tryAcquireOrHolder(owner) orelse return;

        // A holder that transitively awaits this task is provably suspended until this task
        // finishes, so parking would deadlock and borrowing is exclusive: delegate the hold
        // instead. The borrow behaves like a nested `use` across the spawn boundary.
        if (holderAwaitsTask(holder, task)) {
            if (try lock.delegate(holder, owner)) return;
            continue;
        }

        // A contended parse-time acquire runs on the parser coroutine's own stack, where the
        // scheduler cannot suspend this task: minicoro refuses a yield whose stack pointer is
        // outside the task's coroutine stack.
        //
        // The test uses the coro's bounds directly, since the context's stack fields describe
        // the parser stack during a parse. Raising beats spinning on a wait that can never
        // park.
        const sp = @frameAddress();
        const on_task_stack = if (task.coro) |co| blk: {
            const base = @intFromPtr(co.stack_base);
            break :blk sp >= base and sp < base + co.stack_size;
        } else false;
        if (!on_task_stack) {
            ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
                .error_type = "load-parse-wait",
                .message = "cannot wait for the load lock during parse-time execution",
            });
            return error.UserThrown;
        }

        if (!try lock.enqueueIfHeldBy(holder, task)) continue;

        task.blocked_on_load_lock = @ptrCast(lock);
        while (true) {
            sched.suspendCurrentTask();
            helpers.checkCancellation(ctx) catch |err| {
                task.blocked_on_load_lock = null;
                if (lock.isHeldBy(owner)) {
                    releaseLoadLock(ctx);
                } else {
                    _ = lock.removeWaiter(task);
                }
                return err;
            };
            if (lock.isHeldBy(owner)) {
                task.blocked_on_load_lock = null;
                return;
            }
        }
    }
}

/// Release one level of the load-lock hold. A zero-depth release hands ownership to the
/// first queued waiter and wakes it outside the lock's internal mutex, or restores a
/// suspended hold when a borrow ends; a restored hold delegates onward to a queued waiter
/// the restored owner awaits, which its own release could never serve.
///
/// Panics when a waiter must be woken and the releasing context has no scheduler; a queued
/// waiter implies a scheduler ran it.
fn releaseLoadLock(ctx: *Context) void {
    const lock = ctx.load_lock;
    var result = lock.release(loadLockOwner(ctx));
    while (true) {
        const to_wake: *Task = switch (result) {
            .none => return,
            .restored => |restored| blk: {
                const next = lock.delegateToAwaitedWaiter(restored, holderAwaitsTask) catch null;
                break :blk next orelse return;
            },
            .wake => |task| task,
        };
        const sched = ctx.scheduler orelse
            @panic("load-lock waiter queued with no scheduler on the releasing context");
        sched.wakeTask(to_wake) catch {
            // The waiter was made owner but its wake was dropped, so it can never run. Pass
            // the hold on rather than leave a process-wide lock stranded on it.
            result = lock.release(.{ .task = to_wake });
            continue;
        };
        return;
    }
}

/// load-file ( cache filename -- module )
///
/// Any worker may load; loads serialize on the process-wide load lock. An already-cached
/// resolved path returns the cached module without executing; `reload-file` is the path that
/// re-executes.
fn nativeLoadFile(ctx: *Context) anyerror!void {
    try acquireLoadLock(ctx);
    defer releaseLoadLock(ctx);

    // Target root state for the load's duration, so everything the load
    // produces outlives a loading task. Save/restore keeps a nested `use`
    // reentrant.
    const saved_target = ctx.load_target;
    ctx.load_target = ctx.rootContext();
    defer ctx.load_target = saved_target;

    const alloc = ctx.quotationAllocator();

    const filename_pay = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = filename_pay });
    // Loaded definitions keep `source_file` slices of this name for the context's lifetime.
    const filename = try alloc.dupe(u8, filename_pay.bytes);
    const cache_val = try ctx.stack.pop();
    defer container_backing.releaseValue(cache_val);
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
            .source = ctx.ownedCurrentSource(),
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "load-file",
        }) catch {};
        return error.FileNotFound;
    };

    // A load that raced another load of the same path lost the probe-to-lock window: the winner
    // inserted while this caller waited on the load lock. Returning the cached module here keeps
    // the module top-level from executing a second time.
    cache.header.lock();
    const cached = cache.map.get(resolved);
    cache.header.unlock();
    if (cached) |hit| {
        if (hit == .module) {
            try ctx.stack.push(hit);
            return;
        }
    }

    const resolved_module = classifyResolved(resolved) orelse {
        const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "file-not-found",
            .message = msg,
            .source = ctx.ownedCurrentSource(),
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "load-file",
        }) catch {};
        return error.FileNotFound;
    };

    return nativeLoadImpl(ctx, cache, filename, alloc, resolved_module);
}

/// Find the cache entry whose `Module.name` equals `filename`, returning the
/// resolved-path key under which it lives. The returned slice is owned by
/// the cache and remains valid for the lifetime of the entry.
///
/// Used by `reload-file` to pin a reload to the original source kind:
/// the cached key is either a filesystem realpath or a `<stdlib>/...`
/// virtual path, so reusing it preserves the bundle-vs-disk discriminator.
fn findCachedResolvedPath(cache: *value_mod.MutableMap, filename: []const u8) ?[]const u8 {
    cache.header.lock();
    defer cache.header.unlock();
    var iter = cache.map.iterator();
    while (iter.next()) |entry| {
        const cached = switch (entry.value_ptr.*) {
            .module => |m| m,
            else => continue,
        };
        if (std.mem.eql(u8, cached.name, filename)) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

/// reload-file ( cache filename -- module )
fn nativeReloadFile(ctx: *Context) anyerror!void {
    try acquireLoadLock(ctx);
    defer releaseLoadLock(ctx);

    // Target root state for the load's duration; see `nativeLoadFile`.
    const saved_target = ctx.load_target;
    ctx.load_target = ctx.rootContext();
    defer ctx.load_target = saved_target;

    const alloc = ctx.quotationAllocator();

    const filename_pay = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = filename_pay });
    // Loaded definitions keep `source_file` slices of this name for the context's lifetime.
    const filename = try alloc.dupe(u8, filename_pay.bytes);
    const cache_val = try ctx.stack.pop();
    defer container_backing.releaseValue(cache_val);
    const cache: *value_mod.MutableMap = switch (cache_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", cache_val);
            return error.TypeMismatch;
        },
    };

    const resolved = blk: {
        if (findCachedResolvedPath(cache, filename)) |pinned| break :blk pinned;
        break :blk resolveLoadPath(ctx, filename, alloc) orelse {
            const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
            ctx.error_details.append(ctx.allocator, .{
                .error_type = "file-not-found",
                .message = msg,
                .source = ctx.ownedCurrentSource(),
                .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
                .word_name = "reload-file",
            }) catch {};
            return error.FileNotFound;
        };
    };

    const resolved_module = classifyResolved(resolved) orelse {
        const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "file-not-found",
            .message = msg,
            .source = ctx.ownedCurrentSource(),
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "reload-file",
        }) catch {};
        return error.FileNotFound;
    };

    return nativeLoadImpl(ctx, cache, filename, alloc, resolved_module);
}

/// load-check-file ( cache filename -- module )
///
/// Loads in check mode (definitions only). Resolves the filename against the current working
/// directory rather than `current_source_dir`, since linting paths come from the command line,
/// not from `use` statements.
fn nativeLoadCheckFile(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "load-check-file");

    try acquireLoadLock(ctx);
    defer releaseLoadLock(ctx);

    // Target root state for the load's duration; see `nativeLoadFile`.
    const saved_target = ctx.load_target;
    ctx.load_target = ctx.rootContext();
    defer ctx.load_target = saved_target;

    const alloc = ctx.quotationAllocator();

    const filename_pay = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = filename_pay });
    // Loaded definitions keep `source_file` slices of this name for the context's lifetime.
    const filename = try alloc.dupe(u8, filename_pay.bytes);
    const cache_val = try ctx.stack.pop();
    defer container_backing.releaseValue(cache_val);
    const cache: *value_mod.MutableMap = switch (cache_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", cache_val);
            return error.TypeMismatch;
        },
    };

    const resolved = std.fs.cwd().realpathAlloc(alloc, filename) catch {
        const msg = std.fmt.allocPrint(alloc, "path '{s}'", .{filename}) catch "path '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "file-not-found",
            .message = msg,
            .source = ctx.ownedCurrentSource(),
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "load-check-file",
        }) catch {};
        return error.FileNotFound;
    };

    // Return cached module if already loaded, avoiding duplicate side effects
    // such as import-history records from re-executing use statements.
    cache.header.lock();
    const cached = cache.map.get(resolved);
    cache.header.unlock();
    if (cached) |hit| {
        try ctx.stack.push(hit);
        return;
    }

    const prev_check_mode = ctx.check_mode;
    ctx.check_mode = true;
    defer ctx.check_mode = prev_check_mode;
    return nativeLoadImpl(ctx, cache, filename, alloc, .{ .file = .{ .path = resolved } });
}

/// module-cache-value ( -- cache )
fn nativeModuleCacheValue(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
}

/// cached-module ( cache resolved -- module/f )
///
/// Probe the module cache under its header mutex, so a hit taken on one worker cannot observe
/// another worker's insert mid-rehash. Pushes `f` on a miss or when the cached value is not a
/// module.
fn nativeCachedModule(ctx: *Context) anyerror!void {
    const resolved_str = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = resolved_str });
    const cache_val = try ctx.stack.pop();
    defer container_backing.releaseValue(cache_val);
    const cache: *value_mod.MutableMap = switch (cache_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", cache_val);
            return error.TypeMismatch;
        },
    };

    cache.header.lock();
    const cached = cache.map.get(resolved_str.bytes);
    cache.header.unlock();

    if (cached) |hit| {
        if (hit == .module) {
            try ctx.stack.push(hit);
            return;
        }
    }
    try ctx.stack.push(.{ .boolean = false });
}

/// eval-string ( string -- )
fn nativeEvalString(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const code_str = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = code_str });
    const code = code_str.bytes;

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    var start: usize = 0;
    var line_num: usize = 0;
    while (start < code.len) {
        const end = std.mem.indexOfScalarPos(u8, code, start, '\n') orelse code.len;
        const line = code[start..end];
        start = end + 1;
        line_num += 1;
        processor.trackLine(line_num);

        switch (processor.feedLine(alloc, line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| return parser_mod.raiseParseDiagnostics(ctx, err),
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
        .parse_error => |err| return parser_mod.raiseParseDiagnostics(ctx, err),
        .complete => |instrs| {
            if (instrs.len > 0) {
                try ctx.executeQuotation(.{ .instructions = instrs });
            }
        },
    }
}

// ( module-path words-or-f resolved-path -- )
// Append an import record to the context's import history.
// Allowed during parse-time or module loading.
fn nativeRecordImport(ctx: *Context) anyerror!void {
    const resolved_path_str = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = resolved_path_str });
    const resolved_path = resolved_path_str.bytes;
    const words_or_f = try ctx.stack.pop();
    const module_path_str = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = module_path_str });
    const module_path = module_path_str.bytes;

    // Validate words-or-f is an array or false
    switch (words_or_f) {
        .array => {},
        .boolean => |b| if (b) {
            helpers.setTypeMismatchError(ctx, "array or f", words_or_f);
            return error.TypeMismatch;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "array or f", words_or_f);
            container_backing.releaseValue(words_or_f);
            return error.TypeMismatch;
        },
    }

    const arena = ctx.arena.allocator();
    const fields = try arena.alloc(Value, 6);

    // Determine the source file that triggered this import.
    // For runtime imports (e.g., `reexport` called from within a loaded file),
    // load_file_source holds the file being loaded by nativeLoadImpl.
    // For parse-time imports (e.g., `use`), parse_time_source_file holds the
    // file being parsed at the moment the parse-time word was invoked.
    const import_source = ctx.load_file_source orelse ctx.parse_time_source_file;
    fields[0] = value_mod.stringValue(try arena.dupe(u8, import_source));
    fields[1] = .{ .fixnum = @intCast(ctx.parse_time_source_line) };
    fields[2] = .{ .fixnum = @intCast(ctx.parse_time_source_column) };
    fields[3] = value_mod.stringValue(try arena.dupe(u8, module_path));
    // The popped reference transfers into the record and is never released:
    // import history lives for the context. Callers only pass `f` or a
    // parse-time static selection array of symbols, so nothing here can leak.
    fields[4] = words_or_f;
    fields[5] = value_mod.stringValue(try arena.dupe(u8, resolved_path));

    const arr = try value_mod.Array.fromOwnedSlice(arena, fields);
    try ctx.import_history.append(ctx.allocator, .{ .array = arr });
}

// ( -- array )
// Return the accumulated import history as an array of arrays.
fn nativeImportHistory(ctx: *Context) anyerror!void {
    // The history entries stay owned by the context; the result copies them.
    try helpers.pushCopiedArray(ctx, ctx.quotationAllocator(), ctx.import_history.items);
}

// ( -- file line column )
// Push the current parse-time invocation source location.
fn nativeParseSrcLoc(ctx: *Context) anyerror!void {
    if (ctx.parse_tokenizer == null) {
        ctx.pending_error_message = "parse-source-loc can only be called during parsing";
        return error.ParseError;
    }

    try ctx.stack.push(value_mod.stringValue(ctx.current_source));
    try ctx.stack.push(.{ .fixnum = @intCast(ctx.parse_time_source_line) });
    try ctx.stack.push(.{ .fixnum = @intCast(ctx.parse_time_source_column) });
}

// ( module -- name )
// Extract the name from a module value.
fn nativeModuleName(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const module = switch (val) {
        .module => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "module", val);
            return error.TypeMismatch;
        },
    };
    try ctx.stack.push(value_mod.stringValue(module.name));
}

const build_options = @import("build_options");

test "classifyResolved treats non-virtual paths as file" {
    const rm = classifyResolved("/tmp/foo.1z") orelse return error.UnexpectedNull;
    try std.testing.expect(rm == .file);
    try std.testing.expectEqualStrings("/tmp/foo.1z", rm.file.path);
}

test "classifyResolved treats relative paths as file" {
    const rm = classifyResolved("./local.1z") orelse return error.UnexpectedNull;
    try std.testing.expect(rm == .file);
}

test "classifyResolved returns embedded for matching virtual path" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    const rm = classifyResolved("<stdlib>/strings.1z") orelse return error.UnexpectedNull;
    try std.testing.expect(rm == .embedded);
    try std.testing.expectEqualStrings("<stdlib>/strings.1z", rm.embedded.virtual_path);
    try std.testing.expect(rm.embedded.source.len > 0);
}

test "classifyResolved returns null for virtual path with no entry" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?ResolvedModule, null), classifyResolved("<stdlib>/no-such-module.1z"));
}

test "moduleSourceKindOf maps file to filesystem" {
    const rm: ResolvedModule = .{ .file = .{ .path = "/abs/path/lib/strings.1z" } };
    try std.testing.expectEqual(trace_mod.ModuleSourceKind.filesystem, moduleSourceKindOf(rm));
}

test "moduleSourceKindOf maps embedded to embedded" {
    const rm: ResolvedModule = .{ .embedded = .{ .virtual_path = "<stdlib>/strings.1z", .source = "" } };
    try std.testing.expectEqual(trace_mod.ModuleSourceKind.embedded, moduleSourceKindOf(rm));
}

test "importWord: copies an image module word's compiled id" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();
    ctx.import_frame_index = 0;

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    const module: Module = .{ .name = "m", .words = .{} };
    try importWord(&ctx, "probe", .{ .word_id = 17, .action = .{ .native = noop } }, &module);

    const def = ctx.lookupWord("probe") orelse return error.TestExpectedImport;
    try std.testing.expectEqual(@as(?u32, 17), def.word_id);
}

test "importWord: a generic dispatch-merge drops the compiled id" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();
    ctx.import_frame_index = 0;

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    const generic_markers: []const *value_mod.Marker = &.{@constCast(&markers_mod.generic_marker)};

    // An existing generic in scope with a different dispatch_id forces the merge.
    // Raw dictionary put, so definition finalization cannot reassign the id.
    try ctx.dictionary.put("gword", .{
        .name = "gword",
        .markers = generic_markers,
        .dispatch_id = 100,
        .action = .{ .native = noop },
    });

    const module: Module = .{ .name = "m", .words = .{} };
    try importWord(&ctx, "gword", .{
        .markers = generic_markers,
        .dispatch_id = 200,
        .word_id = 17,
        .action = .{ .native = noop },
    }, &module);

    // The imported def dispatches through the merged table, whose entries the
    // baked compiled body would not consult, so the id stays null.
    const def = ctx.lookupWord("gword") orelse return error.TestExpectedImport;
    try std.testing.expectEqual(@as(u32, 100), def.dispatch_id);
    try std.testing.expectEqual(@as(?u32, null), def.word_id);
}

test ">module carries a quotation's attached effect into the word declaration" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    const effect = try alloc.create(stack_effect_mod.StackEffect);
    effect.* = try helpers.makeSimpleEffect(alloc, "a -- r");

    const hash = try value_mod.HashTable.create(alloc);
    try hash.map.put(alloc, "w", .{ .quotation = .{ .instructions = &.{}, .effect = effect } });
    try hash.map.put(alloc, "bare", .{ .quotation = .{ .instructions = &.{} } });

    try ctx.stack.push(value_mod.stringValue("m"));
    try ctx.stack.push(.{ .hash = hash });
    try nativeToModule(&ctx);

    const module_val = try ctx.stack.pop();
    defer container_backing.releaseValue(module_val);
    try std.testing.expect(module_val == .module);
    const with_effect = module_val.module.words.get("w") orelse return error.TestExpectedWord;
    try std.testing.expectEqual(@as(usize, 1), with_effect.stack_effect.?.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), with_effect.stack_effect.?.outputs.len);
    const without = module_val.module.words.get("bare") orelse return error.TestExpectedWord;
    try std.testing.expect(without.stack_effect == null);
}

test "resolveLoadPath falls back to embedded for top-level name" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    const alloc = ctx.quotationAllocator();
    const resolved = resolveLoadPath(&ctx, "strings", alloc) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings("<stdlib>/strings.1z", resolved);
}

test "resolveLoadPath falls back to embedded for nested name" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    const alloc = ctx.quotationAllocator();
    const resolved = resolveLoadPath(&ctx, "math/grid", alloc) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings("<stdlib>/math/grid.1z", resolved);
}

test "resolveLoadPath rejects virtual path under path mode" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    const alloc = ctx.quotationAllocator();
    try std.testing.expectEqual(@as(?[]const u8, null), resolveLoadPath(&ctx, "<stdlib>/strings.1z", alloc));
}

test "resolveLoadPath returns null for search-mode miss with embed enabled" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    const alloc = ctx.quotationAllocator();
    try std.testing.expectEqual(@as(?[]const u8, null), resolveLoadPath(&ctx, "no-such-module-xyz", alloc));
}

test "load-file caches embedded module under virtual path" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
    try ctx.stack.push(value_mod.stringValue("sequences"));
    try nativeLoadFile(&ctx);

    const top = try ctx.stack.pop();
    defer container_backing.releaseValue(top);
    try std.testing.expect(top == .module);
    try std.testing.expectEqualStrings("sequences", top.module.name);

    const entry = ctx.module_cache_value.map.get("<stdlib>/sequences.1z") orelse return error.MissingCacheEntry;
    try std.testing.expect(entry == .module);
    try std.testing.expectEqualStrings("sequences", entry.module.name);
}

test "reload-file pins embedded module across mid-session filesystem availability" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    // Initial load: no filesystem stdlib, fall back to embedded bundle.
    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
    try ctx.stack.push(value_mod.stringValue("sequences"));
    try nativeLoadFile(&ctx);
    {
        const initial = try ctx.stack.pop();
        defer container_backing.releaseValue(initial);
        try std.testing.expect(initial == .module);
    }
    try std.testing.expect(ctx.module_cache_value.map.contains("<stdlib>/sequences.1z"));

    // Stage a same-named file on disk and register its directory as a load
    // path, simulating a filesystem stdlib that became available
    // mid-session after the embedded fallback was already used.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sub_file = try tmp.dir.createFile("sequences.1z", .{});
    sub_file.close();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const tmp_path_owned = try ctx.quotationAllocator().dupe(u8, tmp_path);
    try ctx.load_paths.append(ctx.allocator, tmp_path_owned);

    // Sanity check: a fresh resolveLoadPath now prefers the disk version.
    const fresh = resolveLoadPath(&ctx, "sequences", ctx.quotationAllocator()) orelse return error.UnexpectedNull;
    try std.testing.expect(!std.mem.startsWith(u8, fresh, "<stdlib>/"));

    // Reload: must stay pinned to the embedded virtual path.
    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
    try ctx.stack.push(value_mod.stringValue("sequences"));
    try nativeReloadFile(&ctx);
    const reloaded = try ctx.stack.pop();
    defer container_backing.releaseValue(reloaded);
    try std.testing.expect(reloaded == .module);
    try std.testing.expectEqualStrings("sequences", reloaded.module.name);

    try std.testing.expect(ctx.module_cache_value.map.contains("<stdlib>/sequences.1z"));
    try std.testing.expect(!ctx.module_cache_value.map.contains(fresh));
}

test "reload-file pins filesystem module across mid-session unavailability" {
    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    // Stage a temp lib directory with a minimal module file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sub_file = try tmp.dir.createFile("foo.1z", .{});
    sub_file.close();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const tmp_path_owned = try ctx.quotationAllocator().dupe(u8, tmp_path);
    try ctx.load_paths.append(ctx.allocator, tmp_path_owned);

    // Initial load: resolves to the disk file.
    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
    try ctx.stack.push(value_mod.stringValue("foo"));
    try nativeLoadFile(&ctx);
    {
        const initial = try ctx.stack.pop();
        defer container_backing.releaseValue(initial);
        try std.testing.expect(initial == .module);
    }

    // Capture the disk-path cache key set at first load.
    var disk_key: ?[]const u8 = null;
    var iter = ctx.module_cache_value.map.iterator();
    while (iter.next()) |entry| {
        const cached_mod = switch (entry.value_ptr.*) {
            .module => |m| m,
            else => continue,
        };
        if (std.mem.eql(u8, cached_mod.name, "foo")) {
            disk_key = entry.key_ptr.*;
            break;
        }
    }
    try std.testing.expect(disk_key != null);
    try std.testing.expect(!std.mem.startsWith(u8, disk_key.?, "<stdlib>/"));

    // Reload: still pinned to the disk path, never regresses to embedded.
    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
    try ctx.stack.push(value_mod.stringValue("foo"));
    try nativeReloadFile(&ctx);
    const reloaded = try ctx.stack.pop();
    defer container_backing.releaseValue(reloaded);
    try std.testing.expect(reloaded == .module);
    try std.testing.expectEqualStrings("foo", reloaded.module.name);

    try std.testing.expect(!ctx.module_cache_value.map.contains("<stdlib>/foo.1z"));
}

test "resolveLoadPath prefers configured stdlib_path over embedded" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sub_file = try tmp.dir.createFile("strings.1z", .{});
    sub_file.close();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    ctx.stdlib_path = try ctx.quotationAllocator().dupe(u8, tmp_path);

    const alloc = ctx.quotationAllocator();
    const resolved = resolveLoadPath(&ctx, "strings", alloc) orelse return error.UnexpectedNull;
    try std.testing.expect(!std.mem.startsWith(u8, resolved, "<stdlib>/"));
    try std.testing.expect(std.mem.endsWith(u8, resolved, "strings.1z"));
}

test "resolveLoadPath prefers load_paths over stdlib_path" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    // Two directories each carry a same-named probe module so the only thing
    // distinguishing the resolved path is which slot the resolver picked.
    var first_tmp = std.testing.tmpDir(.{});
    defer first_tmp.cleanup();
    var first_file = try first_tmp.dir.createFile("precedence-probe.1z", .{});
    first_file.close();
    const first_path = try first_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(first_path);

    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();
    var second_file = try second_tmp.dir.createFile("precedence-probe.1z", .{});
    second_file.close();
    const second_path = try second_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(second_path);

    const load_owned = try ctx.quotationAllocator().dupe(u8, first_path);
    try ctx.load_paths.append(ctx.allocator, load_owned);
    ctx.stdlib_path = try ctx.quotationAllocator().dupe(u8, second_path);

    const alloc = ctx.quotationAllocator();
    const resolved = resolveLoadPath(&ctx, "precedence-probe", alloc) orelse return error.UnexpectedNull;
    try std.testing.expect(std.mem.startsWith(u8, resolved, first_path));
}

test "resolveLoadPath prefers load_paths over embedded" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sub_file = try tmp.dir.createFile("strings.1z", .{});
    sub_file.close();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const tmp_owned = try ctx.quotationAllocator().dupe(u8, tmp_path);
    try ctx.load_paths.append(ctx.allocator, tmp_owned);

    const alloc = ctx.quotationAllocator();
    const resolved = resolveLoadPath(&ctx, "strings", alloc) orelse return error.UnexpectedNull;
    try std.testing.expect(!std.mem.startsWith(u8, resolved, "<stdlib>/"));
    try std.testing.expect(std.mem.endsWith(u8, resolved, "strings.1z"));
}

test "resolveLoadPath falls through to embedded when stdlib_path is an empty dir" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    ctx.stdlib_path = try ctx.quotationAllocator().dupe(u8, tmp_path);

    const alloc = ctx.quotationAllocator();
    const resolved = resolveLoadPath(&ctx, "strings", alloc) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings("<stdlib>/strings.1z", resolved);
}

test "resolveLoadPath falls through to embedded when stdlib_path does not exist" {
    if (!build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.load_paths.clearRetainingCapacity();
    ctx.stdlib_path = try ctx.quotationAllocator().dupe(u8, "/no/such/dir/onez-precedence-test");

    const alloc = ctx.quotationAllocator();
    const resolved = resolveLoadPath(&ctx, "strings", alloc) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings("<stdlib>/strings.1z", resolved);
}

test "resolveLoadPath returns null without embed and without stdlib_path" {
    if (build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.stdlib_path = null;
    ctx.load_paths.clearRetainingCapacity();

    const alloc = ctx.quotationAllocator();
    try std.testing.expectEqual(@as(?[]const u8, null), resolveLoadPath(&ctx, "strings", alloc));
}

test "resolveLoadPath returns null without embed when stdlib_path is empty" {
    if (build_options.embed_stdlib) return error.SkipZigTest;

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.load_paths.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    ctx.stdlib_path = try ctx.quotationAllocator().dupe(u8, tmp_path);

    const alloc = ctx.quotationAllocator();
    try std.testing.expectEqual(@as(?[]const u8, null), resolveLoadPath(&ctx, "strings", alloc));
}
