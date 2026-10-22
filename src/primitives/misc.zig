const std = @import("std");
const builtin = @import("builtin");
const is_freestanding = builtin.os.tag == .freestanding;
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;
const Instruction = value_mod.Instruction;
const StatementProcessor = @import("../statement.zig").StatementProcessor;
const parser_mod = @import("../parser.zig");

const markers_mod = @import("markers.zig");
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
const callable_mod = @import("../callable.zig");
const container_backing = @import("../container_backing.zig");
const dict_mod = @import("../dictionary.zig");
const may_define = @import("../may_define.zig");
const embedded_stdlib = @import("../embedded_stdlib.zig");
const LoadLock = @import("../load_lock.zig").LoadLock;
const ModuleLoadRecord = @import("../module_load_record.zig").ModuleLoadRecord;
const task_mod = @import("../task.zig");
const Task = task_mod.Task;
const TaskScope = task_mod.TaskScope;
const Scheduler = @import("../scheduler.zig").Scheduler;

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "import", .stack_effect = "module --", .doc = "Bring module words into the current scope.", .func = nativeImport, .defines_word = true },
    .{ .name = ">module", .stack_effect = "name hashtable -- module", .doc = "Convert a name string and a hashtable of quotations into a module value suitable for import.", .func = nativeToModule },
    .{ .name = "1array", .stack_effect = "elem -- array", .doc = "Wrap element in a single-element array.", .func = native1Array },
    .{ .name = "command-line-args", .stack_effect = "-- args", .doc = "Push program arguments as an array of strings.", .func = nativeCommandLineArgs, .capability = .system },
    .{ .name = "sys-exit", .stack_effect = "code --", .doc = "Exit the process with the given exit code.", .func = nativeSysExit, .capability = .system, .markers = &.{@constCast(&markers_mod.never_returns_marker)} },
    .{ .name = "add-load-path", .stack_effect = "path --", .doc = "Add a directory to the load path search list.", .func = nativeAddLoadPath },
    .{ .name = "eval-string", .stack_effect = "string --", .doc = "Execute a string as 1z code in the caller's scope.", .func = nativeEvalString, .capability = .eval, .defines_word = true, .markers = &.{ @constCast(&markers_mod.interpreter_dependent_marker), @constCast(&markers_mod.dynamic_eval_marker) } },
    .{ .name = "export", .stack_effect = "name --", .doc = "Promote an imported word to a public definition in the current scope.", .func = nativeExport },
    .{ .name = "compile!", .stack_effect = "sym --", .doc = "JIT-compile a word for integer arithmetic. Throws if the word is not found or not compilable.", .func = nativeCompile, .markers = &.{ @constCast(&markers_mod.interpreter_dependent_marker), @constCast(&markers_mod.dynamic_compile_marker) } },
    .{ .name = "load-file", .stack_effect = "cache filename -- module", .doc = "Load a 1z source file and store the result in the given M{} cache. An already-cached path returns the cached module without re-executing; use `reload-file` to re-execute. Loads serialize on the process-wide load lock, so any worker may load.", .func = nativeLoadFile, .capability = .io_fs, .defines_word = true, .markers = &.{ @constCast(&markers_mod.interpreter_dependent_marker), @constCast(&markers_mod.dynamic_load_marker) } },
    .{ .name = "reload-file", .stack_effect = "cache filename -- module", .doc = "Reload a 1z source file, pinned to its original source kind. Reuses the resolved path of an already-cached module instead of re-running the resolver chain, so a module first loaded from the embedded stdlib bundle reloads from the bundle even after a filesystem stdlib becomes available later in the session. Falls back to a fresh resolve when no cached entry exists.", .func = nativeReloadFile, .capability = .io_fs, .defines_word = true, .markers = &.{ @constCast(&markers_mod.interpreter_dependent_marker), @constCast(&markers_mod.dynamic_load_marker) } },
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
    .{ .name = "load-check-file", .func = nativeLoadCheckFile, .stack_effect = "cache filename -- module", .defines_word = true, .capability = .io_fs },
    .{ .name = "borrow-deps", .func = nativeBorrowDeps, .stack_effect = "source-module target --", .defines_word = true },
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
                try module.deps.put(alloc, entry.key_ptr.*, try ctx.moduleWordFor(alloc, entry.key_ptr.*, word_def));
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
        // The effect is copied onto the module's own allocator for the same reason the keys are
        // duped: it belongs to the parse that produced the quotation, whose arena is not the
        // module's.
        const effect = if (quot.effect) |eff| try stack_effect_mod.copyOnto(alloc, eff.*) else null;
        try module.words.put(alloc, key_copy, .{
            .stack_effect = effect,
            .body_owner = callable_mod.ownerClosureOf(val),
            .may_define = may_define.bodyCallsDefiningNative(quot.instructions),
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
            if (instrs.len > 0 and (!ctx.check_mode or Context.isCheckStatement(instrs))) {
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
            if (instrs.len > 0 and (!ctx.check_mode or Context.isCheckStatement(instrs))) {
                try ctx.executeQuotation(.{ .instructions = instrs });
            }
        },
    }
}

/// Append the chain in the form the `circular-dependency` lint rule already prints: every module
/// from the one the chain closed back onto, through to the import that closed it.
///
/// Each module is named as its importer wrote it, since a chain of canonical realpaths is
/// unreadable.
fn appendModuleChain(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    chain: []const ModuleLoadRecord.Entry,
    closing: []const u8,
) !void {
    for (chain) |entry| {
        try out.appendSlice(alloc, entry.filename);
        try out.appendSlice(alloc, " -> ");
    }
    try out.appendSlice(alloc, closing);
}

fn formatCycleChain(
    alloc: std.mem.Allocator,
    chain: []const ModuleLoadRecord.Entry,
    closing: []const u8,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    try out.appendSlice(alloc, "circular dependency: ");
    try appendModuleChain(alloc, &out, chain, closing);
    return out.items;
}

/// Reject a load of a module that is already loading further up the chain.
///
/// `start` is the in-flight entry the load would re-enter, and `closing` is the name this load
/// was asked for.
fn raiseCircularDependency(ctx: *Context, start: usize, closing: []const u8) anyerror {
    const alloc = ctx.quotationAllocator();
    const message = formatCycleChain(alloc, ctx.module_load_record.chainFrom(start), closing) catch
        "circular dependency between modules";
    ctx.thrown_error = try value_mod.boxErrorObject(alloc, .{
        .error_type = "circular-dependency",
        .message = message,
    });
    return error.UserThrown;
}

/// Append a load owner in the form the scheduler's task dump uses, so the two read alike.
fn appendOwnerLabel(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    owner: LoadLock.Owner,
) !void {
    const task = switch (owner) {
        .main => return out.appendSlice(alloc, "main"),
        .task => |t| t,
    };

    var buf: [32]u8 = undefined;
    try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "task[{d}]", .{task.id}));
    if (task.name) |name| {
        try out.appendSlice(alloc, " \"");
        try out.appendSlice(alloc, name);
        try out.appendSlice(alloc, "\"");
    }
}

/// Assemble the re-entry message: the module, the two owners in the order they reached it, and
/// the chain that got there.
fn formatInFlightLoad(
    alloc: std.mem.Allocator,
    chain: []const ModuleLoadRecord.Entry,
    closing: []const u8,
    reentrant: LoadLock.Owner,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    try out.appendSlice(alloc, "load in flight: ");
    try out.appendSlice(alloc, closing);
    try out.appendSlice(alloc, " is loading on ");
    try appendOwnerLabel(alloc, &out, chain[0].owner);
    try out.appendSlice(alloc, ", re-entered on ");
    try appendOwnerLabel(alloc, &out, reentrant);
    try out.appendSlice(alloc, ": ");
    try appendModuleChain(alloc, &out, chain, closing);
    return out.items;
}

/// Reject a load that re-enters a module already loading on a different task.
///
/// It carries its own error type because the fix usually differs from an ordinary cycle's: the
/// load has to move off the task the loader awaits, or above the scope that spawned it. The chain
/// rides along all the same, since this shape is equally reachable as a plain import cycle whose
/// middle load sits inside a `task-scope`.
fn raiseLoadInFlight(ctx: *Context, start: usize, reentrant: LoadLock.Owner, closing: []const u8) anyerror {
    const alloc = ctx.quotationAllocator();
    const message = formatInFlightLoad(alloc, ctx.module_load_record.chainFrom(start), closing, reentrant) catch
        "load already in flight on another task";
    ctx.thrown_error = try value_mod.boxErrorObject(alloc, .{
        .error_type = "load-in-flight",
        .message = message,
    });
    return error.UserThrown;
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

    // The insert below checks again. Refusing here keeps the module's top level from running when
    // its result could not be cached.
    try helpers.beginContainerWrite(ctx, &cache.header);

    // The cache is written only once a body finishes, so a module already loading up the chain is
    // not in it and a circular import would recurse here.
    //
    // This is the choke point all five load entries pass through, and it keys on the same resolved
    // path the cache does, so a cycle spanning two spellings of one module cannot slip past.
    if (ctx.module_load_record.find(resolved)) |start| {
        // The lock admits one owner at a time, so a different owner here can only be a borrowed
        // hold, reached by a task the parked holder awaits. That is worth naming on its own,
        // since the fix for it differs. It is not the other half of a partition: a `task-scope`
        // around a load moves it onto a new task, so a plain import cycle reaches here under a
        // different owner too. Both diagnostics name the chain for that reason.
        const reentrant = loadLockOwner();
        if (!ctx.module_load_record.entryAt(start).owner.eql(reentrant)) {
            return raiseLoadInFlight(ctx, start, reentrant, filename);
        }
        return raiseCircularDependency(ctx, start, filename);
    }
    try ctx.module_load_record.push(.{
        .resolved = resolved,
        .filename = filename,
        .owner = loadLockOwner(),
    });
    defer ctx.module_load_record.pop(resolved);

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

    // A load triggered from inside a parse-time invocation (a `use` in a parsed block) starts a
    // new parse session: the loaded file's own bodies stamp against its `current_source`.
    const old_stamp_source = ctx.parse_stamp_source;
    ctx.parse_stamp_source = null;
    defer ctx.parse_stamp_source = old_stamp_source;

    // The new session is not inside the invoking parse-time word either. The parser reads an
    // installed tokenizer as running inside one, so a loaded file would otherwise skip the check
    // that rejects a `parse-time-only` word in an ordinary body.
    const old_parse_tokenizer = ctx.parse_tokenizer;
    ctx.parse_tokenizer = null;
    defer ctx.parse_tokenizer = old_parse_tokenizer;

    const old_parsing_parse_time_def = ctx.parsing_parse_time_def;
    ctx.parsing_parse_time_def = false;
    defer ctx.parsing_parse_time_def = old_parsing_parse_time_def;

    // A file's bodies are lexical even when an `eval-string` string started the load.
    const old_dynamic_scope = ctx.parse_dynamic_scope;
    ctx.parse_dynamic_scope = false;
    defer ctx.parse_dynamic_scope = old_dynamic_scope;

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

    // XXX(ripta): Hack to set import target frame, which may execute inside
    //             combinator frames like `if`, instead of global or ephemeral
    //             frame. No rugrats for now.
    //
    // `durable_frame_floor` deliberately stays put: this frame is live and other tasks' ancestor
    // walks must not see it.
    const old_import_frame = ctx.import_frame_index;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    defer ctx.import_frame_index = old_import_frame;

    // Declared after the floor's restore so an error pops this frame under the floor its
    // definitions were made against, as the success path does.
    //
    // Popped under the old floor, it reads as transient and decrements the non-empty frame count
    // for a frame never counted.
    errdefer ctx.popLocalFrame();

    try ctx.pushPragmaFrame();
    errdefer ctx.popPragmaFrame();

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
        const mod_word = try ctx.moduleWordFor(alloc, entry.key_ptr.*, word_def);
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

    ctx.stampModuleJitIdentities(module);
    ctx.revokeModuleShadowedLocalReads(module);

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
    try helpers.beginContainerWrite(ctx, &cache.header);
    cache.header.lock();
    ctx.assertWriteAllowed(cache.header.ownerTag());
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

    var definition = dict_mod.WordDefinition{
        .name = name,
        // A module word built outside `moduleWordFor`, such as one an image or a native module
        // registers, may carry only the marker, so either source makes the word parse-time.
        .parse_time = mod_word.parse_time or has_parse_time,
        .imported = true,
        // A word the module being imported had itself imported (e.g. via
        // `reexport`) already carries its originating module, which is where
        // its body's late-bound dep references resolve. Preserve it; only a
        // word the module defines itself (source_module null) is anchored to
        // the module now being imported. Mirrors the `orelse module` pattern
        // in pushModuleDepsFrame and wordDefFromModuleWord.
        .source_module = mod_word.source_module orelse module,
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
            .literal => |lit| .{ .literal = lit.value },
        },
    };

    dict_mod.copySharedFields(&definition, mod_word, &.{ "source_module", "dispatch_id", "word_id", "action", "parse_time" });

    try ctx.defineImportedWord(name, definition);
    if (ctx.trace.trace_modules.import) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceModuleImport(&tw, ctx.current_source, name, module.name);
    }
}

/// Copy all dispatch entries from one dispatch_id to another, allowing
/// overwrites for entries that already exist under the target ID.
///
/// Under check mode the module's arms sit in the check overlay, so the copy reads the overlay over
/// the base table.
fn mergeDispatchEntries(ctx: *Context, from_id: u32, to_id: u32) !void {
    const dispatch_mod = @import("../dispatch.zig");
    const pairs = if (ctx.check_mode)
        try ctx.analysisDispatchEntriesForId(from_id, .by_sequence, ctx.allocator)
    else
        try ctx.dispatch.entriesForDispatchId(from_id, ctx.allocator);
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
    const alloc = ctx.allocator;
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
    const alloc = ctx.allocator;

    const arr = alloc.alloc(Value, 1) catch {
        container_backing.releaseValue(elem);
        return error.OutOfMemory;
    };
    arr[0] = elem;

    // `elem` was moved into the array slot, which already owns its reference;
    // the fresh array adopts it and transfers to the stack without re-retaining.
    try helpers.pushAdoptedArray(ctx, alloc, arr);
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

    if (call_graph_mod.detectMutualGroup(ctx, sym)) |members| {
        defer ctx.allocator.free(members);

        const before_ns = if (ctx.benchmark != null) std.time.nanoTimestamp() else 0;
        const all_ok = try ctx.compileMutualGroup(members);
        if (ctx.benchmark) |bm| bm.recordJitCompile(std.time.nanoTimestamp() - before_ns);

        // A member that did not compile leaves the requested word to compile alone.
        if (all_ok) return;
    }

    compileSingleWord(ctx, sym) catch |err| {
        if (err == error.AnalysisEscape) return err;
        ctx.pending_error_message = "compile!: word is not compilable (must use only fixnum literals and integer arithmetic)";
        return error.TypeMismatch;
    };
}

fn compileSingleWord(ctx: *Context, sym: []const u8) !void {
    const word = ctx.lookupWord(sym) orelse return error.UnknownWord;

    const instrs = switch (word.action) {
        .compound => |i| i,
        .native, .host_callback, .literal => return error.TypeMismatch,
    };

    const effect = word.stack_effect orelse return error.TypeMismatch;

    const before_ns = if (ctx.benchmark != null) std.time.nanoTimestamp() else 0;
    const body = ctx.compileBody(sym, word, instrs, effect, null) orelse return error.TypeMismatch;
    if (ctx.benchmark) |bm| bm.recordJitCompile(std.time.nanoTimestamp() - before_ns);

    try ctx.installCompiledBody(sym, word, instrs, body);
}

/// The current execution's load-lock identity: the running task, or the main sentinel for
/// the non-task main thread.
///
/// Read from the thread, never from a context. A `task-scope` points its caller's
/// `scheduler` at the primary worker for the scope's whole duration, so the handle context
/// an embedder loads through names the primary no matter which worker is asking. A task body
/// runs only inside `coroResume`, so no resumed task here means this thread runs none, and
/// any `current_task` reached through a context would be another worker's.
///
/// Getting it wrong is not a missed optimization. A wrong task identity takes the reentrant
/// branch of an unrelated task's hold, so two loads run at once over the root arena, the
/// module cache, and the in-flight record.
fn loadLockOwner() LoadLock.Owner {
    if (task_mod.resumed_task) |task| return .{ .task = task };
    return .main;
}

/// The scheduler driving this OS thread, or null off any worker.
///
/// Read from the thread for the same reason as `loadLockOwner`, and from the same source. A
/// task is only ever resumed by its home worker, so the resumed task's home is this thread's
/// scheduler.
fn currentScheduler() ?*Scheduler {
    const task = task_mod.resumed_task orelse return null;
    return task.ctx.scheduler;
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
    switch (loadLockOwner()) {
        .main => lock.acquireMain(),
        .task => |task| try acquireLoadLockAsTask(ctx, lock, task, null),
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
        const waiter = s.waiting_slot.peek() orelse return false;
        if (waiter == holder_task) return true;
        scope = waiter.scope;
    }
    return false;
}

/// `host_word` names the host word acquiring for root re-entry, so a parse-time refusal reports the
/// word the user called rather than a load they never started. Null for a load.
fn acquireLoadLockAsTask(ctx: *Context, lock: *LoadLock, task: *Task, host_word: ?[]const u8) anyerror!void {
    const sched = currentScheduler().?;
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
        // scheduler cannot suspend this task. Raising beats spinning on a wait that can never park.
        if (!task_mod.runningOnOwnStack(task)) {
            const alloc = ctx.quotationAllocator();
            const message = if (host_word) |name|
                try std.fmt.allocPrint(
                    alloc,
                    "cannot wait to run host word '{s}' during parse-time execution while another task holds the embedding handle",
                    .{name},
                )
            else
                "cannot wait for the load lock during parse-time execution";

            ctx.thrown_error = try value_mod.boxErrorObject(alloc, .{
                .error_type = "load-parse-wait",
                .message = message,
            });
            return error.UserThrown;
        }

        if (!try lock.enqueueIfHeldBy(holder, task)) continue;

        task.blocked_on_load_lock = @ptrCast(lock);
        while (true) {
            try sched.suspendCurrentTask();
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
/// Panics when a waiter must be woken and no task is resumed on the releasing thread; a
/// queued waiter implies a scheduler ran it.
fn releaseLoadLock(ctx: *Context) void {
    const lock = ctx.load_lock;
    var result = lock.release(loadLockOwner());
    while (true) {
        const to_wake: *Task = switch (result) {
            .none => return,
            .restored => |restored| blk: {
                const next = lock.delegateToAwaitedWaiter(restored, holderAwaitsTask) catch null;
                break :blk next orelse return;
            },
            .wake => |task| task,
        };
        const sched = currentScheduler() orelse
            @panic("load-lock waiter queued with no task resumed on the releasing thread");
        sched.wakeTask(to_wake) catch {
            // The waiter was made owner but its wake was dropped, so it can never run. Pass
            // the hold on rather than leave a process-wide lock stranded on it.
            result = lock.release(.{ .task = to_wake });
            continue;
        };
        return;
    }
}

/// Serialize a host callback's re-entry onto the root handle, returning whether a hold was taken.
/// Pass the result to `releaseHostReentry`.
///
/// A host callback always works on the root context, from whichever worker runs the calling task.
/// Two callbacks on different workers would otherwise push and pop the root's pragma frames and use
/// its stack at once.
///
/// The hold is taken only while a task is resumed on this thread. A host calling in from outside
/// any task cannot overlap a task. That call may also block in `task-scope` while a task's callback
/// re-enters, so it must not hold the lock.
///
/// The hold is the handle's load lock, which is per root. It is reentrant, so a callback's own
/// `use` or nested host word passes through. A contender suspends rather than parking its worker. A
/// task the holder transitively awaits borrows the hold, so a callback that waits on a nested task
/// which re-enters does not deadlock. Being the same lock as module loads, it adds no level and no
/// ordering against them.
pub fn acquireHostReentry(ctx: *Context, host_word: []const u8) anyerror!bool {
    const task = task_mod.resumed_task orelse return false;
    try acquireLoadLockAsTask(ctx, ctx.load_lock, task, host_word);
    return true;
}

pub fn releaseHostReentry(ctx: *Context) void {
    releaseLoadLock(ctx);
}

/// A load's hold on the load lock together with its `load_target` redirect, released as one.
///
/// Every entry into `nativeLoadImpl` runs under one of these. Holding the lock is what makes
/// the shared in-flight load record safe to touch, and the redirect is what puts the load's
/// durable state on the root rather than on whichever context happens to be executing.
pub const LoadGuard = struct {
    ctx: *Context,
    saved_target: ?*Context,

    /// Restore the enclosing load's target and drop one level of the hold.
    ///
    /// The target goes back to what it was rather than to null, which is what keeps a nested
    /// `use` reentrant.
    pub fn end(self: LoadGuard) void {
        self.ctx.load_target = self.saved_target;
        releaseLoadLock(self.ctx);
    }
};

/// Open a load: take the lock, then redirect durable state to the nearest load owner.
///
/// The owner is the root, or the analysis context the load runs under. What the load builds then
/// lives as long as that owner and dies with it.
///
/// Callers must read `ctx.quotationAllocator()` only after this returns. It resolves through
/// `stateTarget`, so an allocator taken beforehand is the executing context's arena and
/// outlives nothing.
pub fn beginLoad(ctx: *Context) anyerror!LoadGuard {
    try acquireLoadLock(ctx);
    const saved_target = ctx.load_target;
    ctx.load_target = ctx.nearestLoadOwner();
    return .{ .ctx = ctx, .saved_target = saved_target };
}

/// The module a load owner reuses from its parent for `resolved`, or null.
///
/// Only the owner's own cache reads through. A cache the caller passed in, such as one a program
/// built, is probed as it is. The parent's cache is read under its mutex and never written.
fn reusedModule(ctx: *Context, cache: *value_mod.MutableMap, resolved: []const u8) ?Value {
    const owner = ctx.nearestLoadOwner();
    if (cache != owner.module_cache_value) return null;

    const parent_cache = owner.reused_module_cache orelse return null;

    parent_cache.header.lock();
    defer parent_cache.header.unlock();

    const hit = parent_cache.map.get(resolved) orelse return null;
    if (hit != .module) return null;

    return hit;
}

/// load-file ( cache filename -- module )
///
/// Any worker may load; loads serialize on the process-wide load lock. An already-cached
/// resolved path returns the cached module without executing; `reload-file` is the path that
/// re-executes.
fn nativeLoadFile(ctx: *Context) anyerror!void {
    const guard = try beginLoad(ctx);
    defer guard.end();

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

    if (reusedModule(ctx, cache, resolved)) |hit| {
        try ctx.stack.push(hit);
        return;
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
    const guard = try beginLoad(ctx);
    defer guard.end();

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

    const guard = try beginLoad(ctx);
    defer guard.end();

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

    if (reusedModule(ctx, cache, resolved)) |hit| {
        try ctx.stack.push(hit);
        return;
    }

    const prev_check_mode = ctx.check_mode;
    ctx.enterCheckMode();
    defer ctx.exitCheckMode(prev_check_mode);
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

    if (reusedModule(ctx, cache, resolved_str.bytes)) |hit| {
        try ctx.stack.push(hit);
        return;
    }

    try ctx.stack.push(.{ .boolean = false });
}

/// eval-string ( string -- )
fn nativeEvalString(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const code_str = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = code_str });
    const code = code_str.bytes;

    // The eval'd string is its own parse session, not part of any file a parse-time invocation
    // is reading.
    const old_stamp_source = ctx.parse_stamp_source;
    ctx.parse_stamp_source = null;
    defer ctx.parse_stamp_source = old_stamp_source;

    // The string runs in its caller's scope, reading and defining into whatever frames are live.
    const old_dynamic_scope = ctx.parse_dynamic_scope;
    ctx.parse_dynamic_scope = true;
    defer ctx.parse_dynamic_scope = old_dynamic_scope;

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

    // The popped reference is released here. The entry holds its own owned copy.
    defer container_backing.releaseValue(words_or_f);

    // Entries live as long as the state target and may be copied into containers that outlive a
    // task, so every field is an owned backing on the shared allocator.
    var builder = try helpers.ArrayBuilder.init(ctx.allocator, 6);
    errdefer builder.deinit();

    // For runtime imports such as `reexport` called from within a loaded file, load_file_source
    // holds the file being loaded. For parse-time imports such as `use`, parse_time_source_file
    // holds the file being parsed when the parse-time word was invoked.
    const import_source = ctx.load_file_source orelse ctx.parse_time_source_file;
    builder.items[0] = try helpers.ownedStringCopy(ctx.allocator, import_source);
    builder.items[1] = .{ .fixnum = @intCast(ctx.parse_time_source_line) };
    builder.items[2] = .{ .fixnum = @intCast(ctx.parse_time_source_column) };
    builder.items[3] = try helpers.ownedStringCopy(ctx.allocator, module_path);
    builder.items[4] = try ownedWordSelection(ctx.allocator, words_or_f);
    builder.items[5] = try helpers.ownedStringCopy(ctx.allocator, resolved_path);

    const entry = try builder.finish();
    ctx.appendImportHistory(entry) catch |e| {
        container_backing.releaseValue(entry);
        return e;
    };
}

/// An owned copy of an import's word selection. `f` passes through. A selection array gets owned
/// symbol and string elements, since the original may borrow parse-time memory.
fn ownedWordSelection(alloc: std.mem.Allocator, words_or_f: Value) !Value {
    const src = switch (words_or_f) {
        .array => |a| a.items,
        else => return words_or_f,
    };

    var builder = try helpers.ArrayBuilder.init(alloc, src.len);
    errdefer builder.deinit();

    for (src, 0..) |item, i| {
        builder.items[i] = switch (item) {
            .symbol => |s| try helpers.ownedSymbolCopy(alloc, s.bytes),
            .string => |s| try helpers.ownedStringCopy(alloc, s.bytes),
            else => blk: {
                container_backing.retainValue(item);
                break :blk item;
            },
        };
    }

    return builder.finish();
}

// ( -- array )
// Return the accumulated import history as an array of arrays. The records of the load owners above
// this context come first, so a root caller sees each record once.
fn nativeImportHistory(ctx: *Context) anyerror!void {
    var records: std.ArrayListUnmanaged(Value) = .{};
    defer records.deinit(ctx.allocator);

    try ctx.importHistoryValues(ctx.allocator, &records);

    // The entries stay owned by their contexts. The result holds retained references to them.
    try helpers.pushCopiedArray(ctx, ctx.allocator, records.items);
}

// ( -- file line column )
// Push the current parse-time invocation source location.
fn nativeParseSrcLoc(ctx: *Context) anyerror!void {
    if (ctx.parse_tokenizer == null) {
        ctx.pending_error_message = "parse-source-loc can only be called during parsing";
        return error.ParseError;
    }

    // The invocation snapshot, not `current_source`: a parse-time word with a compound body runs
    // that body under its own defining file, which would pair the prelude against a user file's
    // line. `executeParseTimeWordForArray` leaves the snapshot unset, so that path still reads the
    // live source.
    const file = if (ctx.parse_time_source_file.len > 0) ctx.parse_time_source_file else ctx.current_source;

    try ctx.stack.push(value_mod.stringValue(file));
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

test "loadLockOwner: a thread running no task is main" {
    try std.testing.expect(loadLockOwner() == .main);
}

test "loadLockOwner: the thread's resumed task names the owner" {
    // Only identity is read, so an uninitialized task stands in for one the scheduler has
    // resumed on this thread.
    var task: Task = undefined;
    task_mod.resumed_task = &task;
    defer task_mod.resumed_task = null;

    const owner = loadLockOwner();
    try std.testing.expect(owner == .task);
    try std.testing.expectEqual(&task, owner.task);
}

test "currentScheduler: a thread running no task drives no scheduler" {
    try std.testing.expectEqual(@as(?*Scheduler, null), currentScheduler());
}

test "currentScheduler: the resumed task's home is the thread's scheduler" {
    var root = Context.init(std.testing.allocator);
    defer root.deinit();

    // A `task-scope` leaves the primary on its caller, and the C embedding API then hands
    // that context to every host callback. The task running here is homed elsewhere, and it
    // is the one `releaseLoadLock` must name: `wakeTask` decides local append versus
    // external queue against it, and the primary would append to another worker's queue.
    var primary = try Scheduler.init(std.testing.allocator);
    defer primary.deinit();
    root.scheduler = &primary;
    defer root.scheduler = null;

    var background = try Scheduler.init(std.testing.allocator);
    defer background.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &root, &background);
    defer task_ctx.deinit();
    var task: Task = undefined;
    task.ctx = &task_ctx;

    task_mod.resumed_task = &task;
    defer task_mod.resumed_task = null;

    try std.testing.expectEqual(&background, currentScheduler().?);
}

fn ownerLabel(alloc: std.mem.Allocator, owner: LoadLock.Owner) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    try appendOwnerLabel(alloc, &out, owner);
    return out.items;
}

test "appendOwnerLabel: the main thread is named, not numbered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("main", try ownerLabel(arena.allocator(), .main));
}

test "appendOwnerLabel: an unnamed task is its id alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var task: Task = undefined;
    task.id = 7;
    task.name = null;

    try std.testing.expectEqualStrings("task[7]", try ownerLabel(arena.allocator(), .{ .task = &task }));
}

test "appendOwnerLabel: a named task carries its name too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var task: Task = undefined;
    task.id = 2;
    task.name = "loader";

    try std.testing.expectEqualStrings("task[2] \"loader\"", try ownerLabel(arena.allocator(), .{ .task = &task }));
}

test "formatInFlightLoad: the module leads, then the two owners in reach order, then the chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var task: Task = undefined;
    task.id = 3;
    task.name = null;

    const chain = [_]ModuleLoadRecord.Entry{
        .{ .resolved = "/outer.1z", .filename = "./outer.1z", .owner = .main },
        .{ .resolved = "/a.1z", .filename = "./a.1z", .owner = .{ .task = &task } },
    };

    const message = try formatInFlightLoad(arena.allocator(), &chain, "./outer.1z", .{ .task = &task });
    try std.testing.expectEqualStrings(
        "load in flight: ./outer.1z is loading on main, re-entered on task[3]: ./outer.1z -> ./a.1z -> ./outer.1z",
        message,
    );
}

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

test "record-import: entries are owned on the shared allocator and released at deinit" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const borrowed = try arena.allocator().dupe(u8, "borrowed");

    const selection = try value_mod.Array.createCopyFrom(std.testing.allocator, &.{ value_mod.symbolValue(borrowed), value_mod.symbolValue(borrowed) }, 0);
    const selection_value: Value = .{ .array = selection };
    defer container_backing.releaseValue(selection_value);

    for (0..2) |_| {
        try ctx.stack.push(value_mod.stringValue(borrowed));
        try ctx.stack.push(selection_value);
        try ctx.stack.push(value_mod.stringValue(borrowed));
        try nativeRecordImport(&ctx);
    }

    try std.testing.expectEqual(@as(usize, 2), ctx.import_history.items.len);

    for (ctx.import_history.items) |entry| {
        const arr = entry.array;
        try std.testing.expect(container_backing.allocatorEql(arr.header.allocator, ctx.allocator));

        for ([_]usize{ 0, 3, 5 }) |i| {
            try std.testing.expect(arr.items[i].string.backing != null);
        }

        const words = arr.items[4].array;
        try std.testing.expect(container_backing.allocatorEql(words.header.allocator, ctx.allocator));
        try std.testing.expectEqual(@as(usize, 2), words.items.len);
        for (words.items) |w| {
            try std.testing.expect(w.symbol.backing != null);
        }
    }

    try nativeImportHistory(&ctx);
    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expect(container_backing.allocatorEql(result.array.header.allocator, ctx.allocator));
    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);
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

    const hash = try value_mod.HashTable.create(alloc, 0);
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

test "beginLoad targets the nearest load owner" {
    var root = Context.init(std.testing.allocator);
    defer root.deinit();

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    var task_under_root = try Context.initChild(std.testing.allocator, &root, .task);
    defer task_under_root.deinit();

    var task_under_analysis = try Context.initChild(std.testing.allocator, &analysis, .task);
    defer task_under_analysis.deinit();

    {
        const guard = try beginLoad(&task_under_root);
        defer guard.end();

        try std.testing.expectEqual(&root, task_under_root.stateTarget());
    }
    try std.testing.expectEqual(@as(?*Context, null), task_under_root.load_target);

    {
        const guard = try beginLoad(&task_under_analysis);
        defer guard.end();

        try std.testing.expectEqual(&analysis, task_under_analysis.stateTarget());
        try std.testing.expectEqual(
            analysis.arena.allocator().ptr,
            task_under_analysis.quotationAllocator().ptr,
        );
    }
    try std.testing.expectEqual(@as(?*Context, null), task_under_analysis.load_target);

    {
        const guard = try beginLoad(&analysis);
        defer guard.end();

        try std.testing.expectEqual(&analysis, analysis.stateTarget());
    }
}

fn writeModuleFile(tmp: *std.testing.TmpDir, name: []const u8, source: []const u8) ![]u8 {
    try tmp.dir.writeFile(.{ .sub_path = name, .data = source });
    return tmp.dir.realpathAlloc(std.testing.allocator, name);
}

fn loadFileThrough(ctx: *Context, path: []const u8) !void {
    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
    try ctx.stack.push(value_mod.stringValue(path));
    try nativeLoadFile(ctx);

    const module = try ctx.stack.pop();
    defer container_backing.releaseValue(module);
    try std.testing.expect(module == .module);
}

test "a load from an analysis child lands its types, protocols, and cache entry on the child" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeModuleFile(&tmp, "shapes.1z", "pt: struct{ x y } ;\nshapely: protocol{ area: } ;\n");
    defer std.testing.allocator.free(path);

    const root_protocols = root.protocol_descriptors.items.len;
    const root_next_id = root.next_protocol_id.load(.monotonic);

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    try loadFileThrough(&analysis, path);

    try std.testing.expect(analysis.struct_types_by_name.contains("pt"));
    try std.testing.expect(root.lookupStructTypeByName("pt") == null);
    try std.testing.expect(analysis.lookupStructTypeByName("pt") != null);

    try std.testing.expectEqual(@as(usize, 1), analysis.protocol_descriptors.items.len);
    try std.testing.expectEqual(root_protocols, root.protocol_descriptors.items.len);
    try std.testing.expectEqual(root_next_id, analysis.protocol_descriptors.items[0].protocol_id);
    try std.testing.expectEqual(root_next_id + 1, root.next_protocol_id.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), analysis.next_protocol_id.load(.monotonic));

    try std.testing.expectEqual(@as(u32, 1), analysis.module_cache_value.map.count());
    try std.testing.expectEqual(@as(u32, 0), root.module_cache_value.map.count());
}

test "a load from a task lands on the context it runs under" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try writeModuleFile(&tmp, "on-root.1z", "gizmo: struct{ a } ;\n");
    defer std.testing.allocator.free(root_path);

    const child_path = try writeModuleFile(&tmp, "on-child.1z", "gadget: struct{ b } ;\n");
    defer std.testing.allocator.free(child_path);

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    const root_types_before = root.struct_type_count;

    {
        var task_ctx = try Context.initChild(std.testing.allocator, &root, .task);
        defer task_ctx.deinit();

        try loadFileThrough(&task_ctx, root_path);
        try std.testing.expectEqual(@as(usize, 0), task_ctx.struct_type_count);
    }

    {
        var task_ctx = try Context.initChild(std.testing.allocator, &analysis, .task);
        defer task_ctx.deinit();

        try loadFileThrough(&task_ctx, child_path);
        try std.testing.expectEqual(@as(u32, 0), task_ctx.struct_types_by_name.count());
        try std.testing.expectEqual(@as(usize, 0), task_ctx.struct_type_count);
    }

    try std.testing.expectEqual(root_types_before + 1, root.struct_type_count);
    try std.testing.expectEqual(@as(usize, 1), analysis.struct_type_count);

    try std.testing.expect(root.struct_types_by_name.contains("gizmo"));
    try std.testing.expect(!analysis.struct_types_by_name.contains("gizmo"));
    try std.testing.expect(analysis.struct_types_by_name.contains("gadget"));
    try std.testing.expect(!root.struct_types_by_name.contains("gadget"));
}

fn putCachedModule(owner: *Context, cache: *value_mod.MutableMap, key: []const u8, name: []const u8) !*Module {
    const module = try owner.arena.allocator().create(Module);
    module.* = .{ .name = name, .words = .{} };

    const cache_alloc = cache.header.allocator;
    try cache.map.put(cache_alloc, try cache_alloc.dupe(u8, key), .{ .module = module });

    return module;
}

fn cachedModuleThrough(ctx: *Context, key: []const u8) !Value {
    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
    try ctx.stack.push(value_mod.stringValue(key));
    try nativeCachedModule(ctx);

    return ctx.stack.pop();
}

test "a cache miss reads through to the parent's modules only on a reusing child" {
    var root = Context.init(std.testing.allocator);
    defer root.deinit();

    const shared = try putCachedModule(&root, root.module_cache_value, "/lib/shared.1z", "shared");

    var reusing = try Context.initChild(std.testing.allocator, &root, .analysis_reusing);
    defer reusing.deinit();

    var isolated = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer isolated.deinit();

    const hit = try cachedModuleThrough(&reusing, "/lib/shared.1z");
    try std.testing.expect(hit == .module);
    try std.testing.expectEqual(shared, hit.module);

    const miss = try cachedModuleThrough(&isolated, "/lib/shared.1z");
    try std.testing.expectEqual(false, miss.boolean);

    const absent = try cachedModuleThrough(&reusing, "/lib/absent.1z");
    try std.testing.expectEqual(false, absent.boolean);

    try std.testing.expectEqual(@as(u32, 0), reusing.module_cache_value.map.count());
    try std.testing.expectEqual(@as(u32, 1), root.module_cache_value.map.count());
}

test "a reusing child loads a missing module itself and never writes the parent's cache" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeModuleFile(&tmp, "fresh.1z", "fresh-point: struct{ x } ;\n");
    defer std.testing.allocator.free(path);

    var reusing = try Context.initChild(std.testing.allocator, &root, .analysis_reusing);
    defer reusing.deinit();

    try loadFileThrough(&reusing, path);

    try std.testing.expectEqual(@as(u32, 1), reusing.module_cache_value.map.count());
    try std.testing.expectEqual(@as(u32, 0), root.module_cache_value.map.count());

    const shared = try putCachedModule(&root, root.module_cache_value, path, "parent-copy");

    // The path is now cached in the parent, so the child's own copy is found first.
    const own = try cachedModuleThrough(&reusing, path);
    try std.testing.expect(own == .module);
    try std.testing.expect(own.module != shared);
}

fn loadThrough(ctx: *Context, comptime native: fn (*Context) anyerror!void, path: []const u8) !Value {
    try ctx.stack.push(.{ .mutable_map = ctx.module_cache_value });
    try ctx.stack.push(value_mod.stringValue(path));
    try native(ctx);

    return ctx.stack.pop();
}

test "load-file and load-check-file reuse the parent's module on a reusing child" {
    var root = Context.init(std.testing.allocator);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeModuleFile(&tmp, "shared.1z", "shared-point: struct{ x } ;\n");
    defer std.testing.allocator.free(path);

    const shared = try putCachedModule(&root, root.module_cache_value, path, "shared");

    var reusing = try Context.initChild(std.testing.allocator, &root, .analysis_reusing);
    defer reusing.deinit();

    const loaded = try loadThrough(&reusing, nativeLoadFile, path);
    try std.testing.expect(loaded == .module);
    try std.testing.expectEqual(shared, loaded.module);

    const checked = try loadThrough(&reusing, nativeLoadCheckFile, path);
    try std.testing.expect(checked == .module);
    try std.testing.expectEqual(shared, checked.module);

    try std.testing.expectEqual(@as(u32, 0), reusing.module_cache_value.map.count());
    try std.testing.expectEqual(@as(u32, 1), root.module_cache_value.map.count());
    try std.testing.expectEqual(@as(u32, 0), reusing.struct_types_by_name.count());
    try std.testing.expectEqual(@as(usize, 0), reusing.struct_type_count);
}

test "load-file and load-check-file load a missing module on an isolated child" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeModuleFile(&tmp, "shared.1z", "iso-point: struct{ x } ;\n");
    defer std.testing.allocator.free(path);

    const shared = try putCachedModule(&root, root.module_cache_value, path, "shared");

    var isolated = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer isolated.deinit();

    const loaded = try loadThrough(&isolated, nativeLoadFile, path);
    try std.testing.expect(loaded == .module);
    try std.testing.expect(loaded.module != shared);
    try std.testing.expectEqual(@as(u32, 1), isolated.module_cache_value.map.count());
}

test "reload-file never reads through to the parent" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeModuleFile(&tmp, "again.1z", "again-point: struct{ x } ;\n");
    defer std.testing.allocator.free(path);

    const shared = try putCachedModule(&root, root.module_cache_value, path, "parent-copy");

    var reusing = try Context.initChild(std.testing.allocator, &root, .analysis_reusing);
    defer reusing.deinit();

    const reloaded = try loadThrough(&reusing, nativeReloadFile, path);
    try std.testing.expect(reloaded == .module);
    try std.testing.expect(reloaded.module != shared);

    try std.testing.expectEqual(@as(u32, 1), reusing.module_cache_value.map.count());
    try std.testing.expectEqual(@as(u32, 1), root.module_cache_value.map.count());
    try std.testing.expectEqual(shared, root.module_cache_value.map.get(path).?.module);
}

fn runSourceLines(ctx: *Context, source: []const u8) !void {
    var processor: StatementProcessor = .{};
    const alloc = ctx.quotationAllocator();

    var number: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        number += 1;
        try feedOneLine(ctx, alloc, &processor, line, number);
    }
    try flushProcessor(ctx, alloc, &processor);
}

fn expectAnalysisEscape(root: *Context, source: []const u8) !void {
    var analysis = try Context.initChild(std.testing.allocator, root, .analysis);
    defer analysis.deinit();

    runSourceLines(&analysis, source) catch |err| {
        if (err == error.AnalysisEscape) {
            while (analysis.stack.depth() > 0) try analysis.stack.popAndRelease();
            return;
        }
        std.debug.print("expected analysis-escape from `{s}`, got {s}\n", .{ source, @errorName(err) });
        return error.TestUnexpectedError;
    };
    std.debug.print("expected analysis-escape from `{s}`, got none\n", .{source});
    return error.TestExpectedError;
}

/// Build a value on the root and bind it under `name` as a literal word. Every call of the word
/// pushes that one container, where a `V{ }` literal in a definition body makes a new one per call.
/// The returned reference is the caller's own, to release.
fn bindHost(root: *Context, name: []const u8, source: []const u8) !Value {
    try runSourceLines(root, source);
    const value = try root.stack.pop();

    container_backing.retainValue(value);
    try root.defineWord(name, .{ .name = name, .action = .{ .literal = value } });
    return value;
}

const host_definitions =
    \\pt: mutable struct{ left right } ;
    \\host-inc: ( n -- n ) [ 1 + ] ;
;

test "a container made under analysis carries the load owner identity" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    var task_under_analysis = try Context.initChild(std.testing.allocator, &analysis, .task);
    defer task_under_analysis.deinit();

    try std.testing.expectEqual(@as(u32, 0), root.containerOwnerTag());
    try std.testing.expect(analysis.containerOwnerTag() != 0);
    try std.testing.expectEqual(analysis.containerOwnerTag(), task_under_analysis.containerOwnerTag());

    var other = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer other.deinit();
    try std.testing.expect(other.containerOwnerTag() != analysis.containerOwnerTag());
}

test "analysis-escape is the symbol of the escape error" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("analysis-escape", @import("errors.zig").pascalToKebabRuntime(@errorName(error.AnalysisEscape), &buf));
}

test "analysis writes to its own containers" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    try runSourceLines(&analysis, "V{ 1 } 2 #push!");
    const grown = try analysis.stack.pop();
    defer container_backing.releaseValue(grown);
    try std.testing.expectEqual(@as(usize, 2), grown.vector.list.items.len);

    try runSourceLines(&analysis, "mine: once ( -- n ) [ 7 ] ;\nmine");
    const forced = try analysis.stack.pop();
    try std.testing.expectEqual(@as(i64, 7), forced.fixnum);
}

/// Run `source` on a fresh analysis child of `root` and return the top of its stack.
///
/// Only an immediate value survives the child's teardown, so a caller asks for a fixnum, float, or
/// boolean.
fn analysisResult(root: *Context, source: []const u8) !Value {
    var analysis = try Context.initChild(std.testing.allocator, root, .analysis);
    defer analysis.deinit();

    try runSourceLines(&analysis, source);
    const result = try analysis.stack.pop();
    while (analysis.stack.depth() > 0) try analysis.stack.popAndRelease();
    return result;
}

const ShadowCase = struct {
    source: []const u8,
    expected: i64,
};

const shadow_cases = [_]ShadowCase{
    .{ .source = "host-vec 4 #push! drop host-vec #len", .expected = 4 },
    .{ .source = "host-vec #pop! drop drop host-vec #len", .expected = 2 },
    .{ .source = "host-vec 0 #unshift! drop host-vec 0 #nth", .expected = 0 },
    .{ .source = "host-vec #shift! drop drop host-vec 0 #nth", .expected = 2 },
    .{ .source = "host-vec 0 9 #nth! drop host-vec 0 #nth", .expected = 9 },
    .{ .source = "host-vec V{ 7 } #append! drop host-vec #len", .expected = 4 },
    .{ .source = "host-vec 1 native.#shrink! drop host-vec #len", .expected = 1 },
    .{ .source = "host-vec 5 0 native.#grow! drop host-vec #len", .expected = 5 },
    .{ .source = "host-ba 0 9 #nth! drop host-ba 0 #nth", .expected = 9 },
    .{ .source = "host-ba 0 9 1 #poke! drop host-ba 0 1 #peek", .expected = 9 },
    .{ .source = "host-ba 0 9 1 2 #fill! drop host-ba 1 1 #peek", .expected = 9 },
    .{ .source = "host-ba 0 host-ba 1 2 #copy! drop host-ba 0 1 #peek", .expected = 2 },
    .{ .source = "host-ba 1 native.#shrink! drop host-ba #len", .expected = 1 },
    .{ .source = "host-ba 6 0 native.#grow! drop host-ba #len", .expected = 6 },
    .{ .source = "host-mm b: 2 @set! drop host-mm b: @get", .expected = 2 },
    .{ .source = "host-mm a: @remove! drop host-mm #len", .expected = 0 },
    .{ .source = "host-mvm 2 \"b\" vmap-set! drop host-mvm #len", .expected = 2 },
    .{ .source = "host-mvm 1 vmap-delete! drop host-mvm #len", .expected = 0 },
    .{ .source = "host-pt 5 >>left drop host-pt left>>", .expected = 5 },
};

test "every mutating word from analysis writes a copy that analysis reads back" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    try runSourceLines(&root, host_definitions);

    const vec = try bindHost(&root, "host-vec", "V{ 1 2 3 }");
    defer container_backing.releaseValue(vec);
    const ba = try bindHost(&root, "host-ba", "B{ 1 2 3 4 }");
    defer container_backing.releaseValue(ba);
    const mm = try bindHost(&root, "host-mm", "[ a: 1 ] make-mutable-map");
    defer container_backing.releaseValue(mm);
    const mvm = try bindHost(&root, "host-mvm", "<mutable-value-map> 1 \"a\" vmap-set!");
    defer container_backing.releaseValue(mvm);
    const pt = try bindHost(&root, "host-pt", "1 2 make-pt");
    defer container_backing.releaseValue(pt);

    const vec_refs = vec.vector.header.refcountValue();

    for (shadow_cases) |case| {
        const result = analysisResult(&root, case.source) catch |err| {
            std.debug.print("`{s}` failed with {s}\n", .{ case.source, @errorName(err) });
            return err;
        };
        std.testing.expectEqual(case.expected, result.fixnum) catch |err| {
            std.debug.print("`{s}` left {d}\n", .{ case.source, result.fixnum });
            return err;
        };
    }

    try std.testing.expectEqual(@as(usize, 3), vec.vector.list.items.len);
    try std.testing.expectEqual(@as(i64, 1), vec.vector.list.items[0].fixnum);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, ba.byte_array.slice());
    try std.testing.expectEqual(@as(u32, 1), mm.mutable_map.map.count());
    try std.testing.expectEqual(@as(i64, 1), mm.mutable_map.map.get("a").?.fixnum);
    try std.testing.expectEqual(@as(usize, 1), mvm.mutable_value_map.map.count());
    try std.testing.expectEqual(@as(i64, 1), pt.struct_instance.fields[0].fixnum);

    try std.testing.expectEqual(vec_refs, vec.vector.header.refcountValue());
}

test "a nested container is copied on its own first write" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    const nested = try bindHost(&root, "host-nested", "V{ } V{ 1 } #push!");
    defer container_backing.releaseValue(nested);

    const grown = try analysisResult(&root, "host-nested 0 #nth 2 #push! drop host-nested 0 #nth #len");
    try std.testing.expectEqual(@as(i64, 2), grown.fixnum);

    const outer_unchanged = try analysisResult(&root, "host-nested 0 #nth 2 #push! drop host-nested #len");
    try std.testing.expectEqual(@as(i64, 1), outer_unchanged.fixnum);

    try std.testing.expectEqual(@as(usize, 1), nested.vector.list.items.len);
    try std.testing.expectEqual(@as(usize, 1), nested.vector.list.items[0].vector.list.items.len);
}

test "an original and its copy are one object to analysis" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    const vec = try bindHost(&root, "host-vec", "V{ 1 2 3 }");
    defer container_backing.releaseValue(vec);

    const same = try analysisResult(&root, "V{ } host-vec #push! host-vec 4 #push! drop 0 #nth host-vec =");
    try std.testing.expect(same.boolean);

    const stale_sees_write = try analysisResult(&root, "V{ } host-vec #push! host-vec 4 #push! drop 0 #nth #len");
    try std.testing.expectEqual(@as(i64, 4), stale_sees_write.fixnum);

    try std.testing.expectEqual(@as(usize, 3), vec.vector.list.items.len);
}

test "a task under analysis shares its load owner's copies" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    const vec = try bindHost(&root, "host-vec", "V{ 1 2 3 }");
    defer container_backing.releaseValue(vec);

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    var task_under_analysis = try Context.initChild(std.testing.allocator, &analysis, .task);
    defer task_under_analysis.deinit();

    try runSourceLines(&analysis, "host-vec 4 #push! drop");

    try runSourceLines(&task_under_analysis, "host-vec #len");
    const seen_by_task = try task_under_analysis.stack.pop();
    try std.testing.expectEqual(@as(i64, 4), seen_by_task.fixnum);

    try runSourceLines(&task_under_analysis, "host-vec 5 #push! drop");

    try runSourceLines(&analysis, "host-vec #len");
    const seen_by_analysis = try analysis.stack.pop();
    try std.testing.expectEqual(@as(i64, 5), seen_by_analysis.fixnum);

    try std.testing.expectEqual(@as(usize, 3), vec.vector.list.items.len);
}

test "two analyses of one host container do not see each other's writes" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    const vec = try bindHost(&root, "host-vec", "V{ 1 2 3 }");
    defer container_backing.releaseValue(vec);

    var first = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer first.deinit();
    var second = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer second.deinit();

    try runSourceLines(&first, "host-vec 4 #push! drop");
    try runSourceLines(&second, "host-vec #len");

    const second_len = try second.stack.pop();
    try std.testing.expectEqual(@as(i64, 3), second_len.fixnum);
}

test "a wrong-typed operand reports a type mismatch before an escape" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    const vec = try bindHost(&root, "host-vec", "V{ 1 2 3 }");
    defer container_backing.releaseValue(vec);
    const mm = try bindHost(&root, "host-mm", "[ a: 1 ] make-mutable-map");
    defer container_backing.releaseValue(mm);

    const statements = [_][]const u8{
        "host-vec b: 2 @set!",
        "host-vec a: @remove!",
        "host-mm 4 #push!",
        "host-mm #pop!",
    };
    for (statements) |statement| {
        var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
        defer analysis.deinit();

        try std.testing.expectError(error.TypeMismatch, runSourceLines(&analysis, statement));
        while (analysis.stack.depth() > 0) try analysis.stack.popAndRelease();
    }
}

const host_typed_definitions =
    \\vector(float): M{ inner-type: vector element-type: float define: [ define-parameterized-type ] } ;
    \\mutable-map(float): M{ inner-type: mutable-map element-type: float define: [ define-parameterized-type ] } ;
    \\mutable-value-map(float): M{ inner-type: mutable-value-map element-type: float define: [ define-parameterized-type ] } ;
;

test "a copy of a borrowed byte array keeps the borrowed buffer's fixed length" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var backing = [_]u8{ 1, 2, 3, 4 };
    const ba = try value_mod.makeBorrowedByteArray(std.testing.allocator, &backing, 0);
    defer container_backing.releaseValue(.{ .byte_array = ba });

    container_backing.retainValue(.{ .byte_array = ba });
    try root.defineWord("host-borrowed", .{ .name = "host-borrowed", .action = .{ .literal = .{ .byte_array = ba } } });

    const written = try analysisResult(&root, "host-borrowed 0 9 #nth! drop host-borrowed 0 #nth");
    try std.testing.expectEqual(@as(i64, 9), written.fixnum);

    const still_borrowed = try analysisResult(&root, "host-borrowed 0 9 #nth! drop host-borrowed borrowed?");
    try std.testing.expect(still_borrowed.boolean);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &backing);

    var grower = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer grower.deinit();
    try std.testing.expectError(error.InvalidArgument, runSourceLines(&grower, "host-borrowed 8 0 native.#grow!"));

    var shrinker = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer shrinker.deinit();
    try std.testing.expectError(error.InvalidArgument, runSourceLines(&shrinker, "host-borrowed 2 native.#shrink!"));
}

const RaceWorker = struct {
    ctx: *Context,
    failed: bool = false,

    fn run(self: *RaceWorker) void {
        self.ctx.setStackBoundsFromCurrentThread();

        var round: usize = 0;
        while (round < 40) : (round += 1) {
            runSourceLines(self.ctx, "host-vec 1 #push! drop host-vec #len") catch {
                self.failed = true;
                return;
            };
            const len = self.ctx.stack.pop() catch {
                self.failed = true;
                return;
            };
            if (len.fixnum < 4) self.failed = true;
        }
    }
};

test "tasks under one analysis owner race to copy and read one host container" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    const vec = try bindHost(&root, "host-vec", "V{ 1 2 3 }");
    defer container_backing.releaseValue(vec);

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    const worker_count = 4;
    var tasks: [worker_count]Context = undefined;
    var workers: [worker_count]RaceWorker = undefined;
    var threads: [worker_count]std.Thread = undefined;

    var built: usize = 0;
    defer for (tasks[0..built]) |*task| task.deinit();

    while (built < worker_count) : (built += 1) {
        tasks[built] = try Context.initChild(std.testing.allocator, &analysis, .task);
        workers[built] = .{ .ctx = &tasks[built] };
    }

    for (&threads, &workers) |*thread, *worker| thread.* = try std.Thread.spawn(.{}, RaceWorker.run, .{worker});
    for (threads) |thread| thread.join();

    for (workers) |worker| try std.testing.expect(!worker.failed);

    try runSourceLines(&analysis, "host-vec #len");
    const total = try analysis.stack.pop();
    try std.testing.expectEqual(@as(i64, 3 + worker_count * 40), total.fixnum);

    try std.testing.expectEqual(@as(usize, 3), vec.vector.list.items.len);
}

test "analysis interprets a quotation that has compiled code" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    const instrs = [_]value_mod.Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 1 },
    };
    const compiled = try ir_codegen.compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer compiled.jit_buf.deinit();
    const quotation: value_mod.Quotation = .{ .instructions = &instrs, .code_ptr = compiled.code_ptr };

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    const before_root = context_mod.compiled_quotation_entries_for_test;
    try root.executeQuotationWithFrame(quotation, null);
    try std.testing.expectEqual(@as(i64, 7), (try root.stack.pop()).fixnum);
    try std.testing.expect(context_mod.compiled_quotation_entries_for_test > before_root);

    const before_barred = context_mod.compiled_quotation_entries_for_test;
    try analysis.executeQuotationWithFrame(quotation, null);
    try std.testing.expectEqual(@as(i64, 7), (try analysis.stack.pop()).fixnum);
    try std.testing.expectEqual(before_barred, context_mod.compiled_quotation_entries_for_test);

    context_mod.compiled_code_bar_off_for_test = true;
    defer context_mod.compiled_code_bar_off_for_test = false;

    const before_open = context_mod.compiled_quotation_entries_for_test;
    try analysis.executeQuotationWithFrame(quotation, null);
    try std.testing.expectEqual(@as(i64, 7), (try analysis.stack.pop()).fixnum);
    try std.testing.expect(context_mod.compiled_quotation_entries_for_test > before_open);
}

test "analysis interprets a host word that has compiled code" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    try runSourceLines(&root, host_definitions);
    try runSourceLines(&root, "host-inc: compile!");
    try std.testing.expect(root.lookupWord("host-inc").?.word_id != null);

    const before_root = ir_codegen.compiled_entries_for_test;
    try runSourceLines(&root, "3 host-inc");
    try std.testing.expect(ir_codegen.compiled_entries_for_test > before_root);
    try root.stack.popAndRelease();

    const before_barred = ir_codegen.compiled_entries_for_test;
    const barred = try analysisResult(&root, "3 host-inc");
    try std.testing.expectEqual(@as(i64, 4), barred.fixnum);
    try std.testing.expectEqual(before_barred, ir_codegen.compiled_entries_for_test);

    context_mod.compiled_code_bar_off_for_test = true;
    defer context_mod.compiled_code_bar_off_for_test = false;

    const before_open = ir_codegen.compiled_entries_for_test;
    const open = try analysisResult(&root, "3 host-inc");
    try std.testing.expectEqual(@as(i64, 4), open.fixnum);
    try std.testing.expect(ir_codegen.compiled_entries_for_test > before_open);
}

test "a typed wrap from analysis promotes the elements of a copy" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    try runSourceLines(&root, host_typed_definitions);

    const vec = try bindHost(&root, "host-vec", "V{ 1 2 }");
    defer container_backing.releaseValue(vec);
    const mm = try bindHost(&root, "host-mm", "[ a: 1 ] make-mutable-map");
    defer container_backing.releaseValue(mm);
    const mvm = try bindHost(&root, "host-mvm", "<mutable-value-map> \"a\" 1 vmap-set!");
    defer container_backing.releaseValue(mvm);

    const vec_promoted = try analysisResult(&root, "host-vec >vector(float) drop host-vec 0 #nth");
    try std.testing.expectEqual(@as(f64, 1.0), vec_promoted.float);

    const mm_promoted = try analysisResult(&root, "host-mm >mutable-map(float) drop host-mm a: @get");
    try std.testing.expectEqual(@as(f64, 1.0), mm_promoted.float);

    const mvm_promoted = try analysisResult(&root, "host-mvm >mutable-value-map(float) drop host-mvm \"a\" vmap-get");
    try std.testing.expectEqual(@as(f64, 1.0), mvm_promoted.float);

    try std.testing.expectEqual(@as(i64, 1), vec.vector.list.items[0].fixnum);
    try std.testing.expectEqual(@as(i64, 1), mm.mutable_map.map.get("a").?.fixnum);
    try std.testing.expectEqual(@as(i64, 1), mvm.mutable_value_map.map.values()[0].fixnum);
}

test "a typed wrap that promotes nothing makes no copy" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    try runSourceLines(&root, host_typed_definitions);

    const vec = try bindHost(&root, "host-vec", "V{ 1.5 2.5 }");
    defer container_backing.releaseValue(vec);

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    try runSourceLines(&analysis, "host-vec >vector(float) drop");
    try std.testing.expect(analysis.stack.shadows.?.lookup(vec) == null);
}

test "load-file from analysis into a host cache raises and leaves the cache alone" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    const cache = try bindHost(&root, "host-cache", "[ ] make-mutable-map");
    defer container_backing.releaseValue(cache);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeModuleFile(&tmp, "barrier.1z", "barrier-word: [ 1 ] ;\n");
    defer std.testing.allocator.free(path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "host-cache \"{s}\" load-file", .{path});
    defer std.testing.allocator.free(source);

    try expectAnalysisEscape(&root, source);
    try std.testing.expectEqual(@as(u32, 0), cache.mutable_map.map.count());

    const failing_path = try writeModuleFile(&tmp, "barrier-runs.1z", "1 0 /\n");
    defer std.testing.allocator.free(failing_path);

    const failing_source = try std.fmt.allocPrint(std.testing.allocator, "host-cache \"{s}\" load-file", .{failing_path});
    defer std.testing.allocator.free(failing_source);

    try expectAnalysisEscape(&root, failing_source);
}

test "compile! of a host word from analysis raises and leaves the host word's id unset" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    try runSourceLines(&root, host_definitions);
    try std.testing.expect(root.lookupWord("host-inc").?.word_id == null);

    try expectAnalysisEscape(&root, "host-inc: compile!");

    try std.testing.expect(root.lookupWord("host-inc").?.word_id == null);
}

test "compile! of a host mutual group from analysis raises and installs no member" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    try runSourceLines(&root,
        \\host-even?: ( n -- b ) [ dup 0 = [ drop t ] [ 1 - host-odd? ] if ] ;
        \\host-odd?: ( n -- b ) [ dup 0 = [ drop f ] [ 1 - host-even? ] if ] ;
        \\host-even?: compile!
    );

    const even_id = root.lookupWord("host-even?").?.word_id;
    const odd_id = root.lookupWord("host-odd?").?.word_id;
    try std.testing.expect(even_id != null);
    try std.testing.expect(odd_id != null);

    try expectAnalysisEscape(&root, "host-odd?: compile!");

    try std.testing.expectEqual(even_id, root.lookupWord("host-even?").?.word_id);
    try std.testing.expectEqual(odd_id, root.lookupWord("host-odd?").?.word_id);
}

const host_once_definitions =
    \\host-once: once ( -- n ) [ 42 ] ;
    \\host-once-vec: once ( -- v ) [ V{ 1 } ] ;
;

test "forcing a host once word from analysis publishes into the load owner and leaves the cell cold" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    try runSourceLines(&root, host_once_definitions);

    const forced = try analysisResult(&root, "host-once");
    try std.testing.expectEqual(@as(i64, 42), forced.fixnum);

    const computed_once = try analysisResult(&root, "host-once-vec 2 #push! drop host-once-vec #len");
    try std.testing.expectEqual(@as(i64, 2), computed_once.fixnum);

    try runSourceLines(&root, "host-once-vec #len");
    const host_len = try root.stack.pop();
    try std.testing.expectEqual(@as(i64, 1), host_len.fixnum);
}

test "analysis reads a host once cell the host already forced as it stands" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    try runSourceLines(&root, host_once_definitions);
    try runSourceLines(&root, "host-once-vec drop");

    const written = try analysisResult(&root, "host-once-vec 9 #push! drop host-once-vec #len");
    try std.testing.expectEqual(@as(i64, 2), written.fixnum);

    try runSourceLines(&root, "host-once-vec #len");
    const host_len = try root.stack.pop();
    try std.testing.expectEqual(@as(i64, 1), host_len.fixnum);
}

test "naming a host marker from analysis raises and leaves it anonymous" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var marker: value_mod.Marker = .{ .name = "" };
    try root.defineWord("host-anon-marker", .{
        .name = "host-anon-marker",
        .parse_time = true,
        .action = .{ .literal = .{ .marker = &marker } },
    });

    try expectAnalysisEscape(&root, "alias: host-anon-marker ;");
    try std.testing.expectEqualStrings("", marker.name);
}

test "analysis names a marker it made" {
    var root = Context.initWithPrelude(std.testing.allocator);
    defer root.deinit();

    var analysis = try Context.initChild(std.testing.allocator, &root, .analysis);
    defer analysis.deinit();

    try runSourceLines(&analysis, "mine: marker ;");
    try std.testing.expect(analysis.lookupWord("mine") != null);
}

test "a cache the program built is probed as it is" {
    var root = Context.init(std.testing.allocator);
    defer root.deinit();

    _ = try putCachedModule(&root, root.module_cache_value, "/lib/shared.1z", "shared");

    var reusing = try Context.initChild(std.testing.allocator, &root, .analysis_reusing);
    defer reusing.deinit();

    const other = try value_mod.MutableMap.create(std.testing.allocator, 0);
    defer container_backing.releaseValue(.{ .mutable_map = other });

    try reusing.stack.push(.{ .mutable_map = other });
    try reusing.stack.push(value_mod.stringValue("/lib/shared.1z"));
    try nativeCachedModule(&reusing);

    const result = try reusing.stack.pop();
    try std.testing.expectEqual(false, result.boolean);
}
